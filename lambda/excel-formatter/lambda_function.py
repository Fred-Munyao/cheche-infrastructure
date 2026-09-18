"""
cheche-excel-formatter  (async)

Flow
  1. POST /jobs {checkout_id, filename}
       payment gate checked (read-only) -> job created -> returns a one-time,
       10-minute S3 upload form (max 25 MB) for the raw workbook
  2. Browser uploads the raw workbook straight to S3  (no API Gateway size/time limit)
  3. S3 event -> this Lambda (async, up to 120 s):
       reserve a paid download slot -> build workbook -> save result -> delete input
       any failure releases the slot, so a failed build never costs the customer
  4. GET /jobs/{id}  -> pending | done (+10-minute download link) | error
       asking again for a finished job re-issues a link and costs nothing
  POST /format is the old synchronous path, kept only until the new page is live.

Data handling
  Raw input is deleted as soon as it is processed. Results live in a private,
  encrypted bucket and are deleted automatically by a 1-day lifecycle rule.

Payment rules (unchanged)
  One PAID checkout = MAX_DOWNLOADS_PER_PAYMENT builds within DOWNLOAD_WINDOW_HOURS.
  A record may override both with max_downloads / window_hours (demo passes).
"""
import json
import base64
import io
import math
import os
import re
import time
import uuid
from urllib.parse import unquote_plus

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

PAYMENTS_TABLE = os.environ.get('PAYMENTS_TABLE', 'cheche-payments')
JOBS_BUCKET    = os.environ.get('JOBS_BUCKET', '')
MAX_DOWNLOADS  = int(os.environ.get('MAX_DOWNLOADS_PER_PAYMENT', '3'))
WINDOW_HOURS   = int(os.environ.get('DOWNLOAD_WINDOW_HOURS', '24'))
MAX_UPLOAD     = 25 * 1024 * 1024
LINK_SECONDS   = 600
XLSX_MIME      = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
CHECKOUT_RE    = re.compile(r'^[A-Za-z0-9_-]{6,80}$')
JOB_RE         = re.compile(r'^[a-f0-9]{32}$')

_payments = boto3.resource('dynamodb', region_name='us-east-1').Table(PAYMENTS_TABLE)
_s3 = boto3.client('s3', region_name='us-east-1',
                   config=Config(signature_version='s3v4', s3={'addressing_style': 'virtual'}))


# ─────────────────────────── payment gate ───────────────────────────
class PaymentRejected(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def _check_payment(checkout_id):
    """Read-only gate. Returns the payment item if a download slot is available."""
    if not checkout_id or not CHECKOUT_RE.match(checkout_id):
        raise PaymentRejected('payment_required', 'A completed M-Pesa payment is required to download the workbook.')
    item = _payments.get_item(Key={'checkout_request_id': checkout_id}, ConsistentRead=True).get('Item')
    if not item:
        raise PaymentRejected('payment_required', 'We could not find that payment. Please pay to unlock your workbook.')
    status = item.get('status', 'PENDING')
    if status == 'PENDING':
        raise PaymentRejected('payment_pending', 'Your payment is still being confirmed by M-Pesa. Please try again in a few seconds.')
    if status != 'PAID':
        raise PaymentRejected('payment_required', 'That payment did not complete. Please pay to unlock your workbook.')
    max_dl  = int(item.get('max_downloads', MAX_DOWNLOADS))
    window  = int(item.get('window_hours', WINDOW_HOURS)) * 3600
    paid_at = int(item.get('paid_at', 0))
    if paid_at and time.time() > paid_at + window:
        raise PaymentRejected('payment_used', 'This payment has expired. A new payment unlocks your next workbook.')
    if int(item.get('download_count', 0)) >= max_dl:
        raise PaymentRejected('payment_used', 'This payment has already been used. A new payment unlocks your next workbook.')
    return item


def _reserve_download(checkout_id):
    """Atomically take one download slot. Returns the new count."""
    item = _check_payment(checkout_id)
    try:
        if 'download_count' in item:
            cond, vals = 'download_count = :expected', {':expected': int(item['download_count'])}
        else:
            cond, vals = 'attribute_not_exists(download_count)', {}
        vals.update({':one': 1, ':zero': 0, ':now': int(time.time())})
        res = _payments.update_item(
            Key={'checkout_request_id': checkout_id},
            UpdateExpression='SET download_count = if_not_exists(download_count, :zero) + :one, last_download_at = :now',
            ConditionExpression=cond,
            ExpressionAttributeValues=vals,
            ReturnValues='UPDATED_NEW',
        )
        return int(res['Attributes']['download_count'])
    except ClientError as e:
        if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
            raise PaymentRejected('payment_used', 'This payment is being used in another download. Please try again.')
        raise


def _release_download(checkout_id):
    try:
        _payments.update_item(
            Key={'checkout_request_id': checkout_id},
            UpdateExpression='SET download_count = download_count - :one',
            ConditionExpression='download_count > :zero',
            ExpressionAttributeValues={':one': 1, ':zero': 0},
        )
    except Exception as e:
        print(f'[release] could not release slot: {e}')


# ─────────────────────────── helpers ───────────────────────────
def cors_response(status, body):
    return {
        'statusCode': status,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Headers': 'Content-Type',
            'Access-Control-Allow-Methods': 'GET,POST,OPTIONS'
        },
        'body': body if isinstance(body, str) else json.dumps(body)
    }


def _body(event):
    body = event.get('body') or ''
    if event.get('isBase64Encoded'):
        body = base64.b64decode(body).decode('utf-8')
    return json.loads(body or '{}')


def _safe_filename(name):
    name = re.sub(r'[^A-Za-z0-9._-]+', '_', str(name or 'mpesa_statement'))[:120]
    name = name[:-5] if name.lower().endswith('.xlsx') else name
    return (name or 'mpesa_statement') + '_formatted.xlsx'


def _get_json(key):
    try:
        return json.loads(_s3.get_object(Bucket=JOBS_BUCKET, Key=key)['Body'].read())
    except ClientError as e:
        if e.response['Error']['Code'] in ('NoSuchKey', '404', '403', 'AccessDenied'):
            return None
        raise


def _exists(key):
    try:
        _s3.head_object(Bucket=JOBS_BUCKET, Key=key)
        return True
    except ClientError as e:
        if e.response['Error']['Code'] in ('404', 'NoSuchKey', 'NotFound', '403'):
            return False
        raise


def _put_json(key, data):
    _s3.put_object(Bucket=JOBS_BUCKET, Key=key, Body=json.dumps(data).encode(),
                   ContentType='application/json', ServerSideEncryption='AES256')


# ─────────────────────────── routes ───────────────────────────
def _create_job(event):
    try:
        data = _body(event)
    except Exception:
        return cors_response(400, {'error': 'Invalid request body'})
    checkout_id = str(data.get('checkout_id') or '')
    try:
        _check_payment(checkout_id)           # fail fast; the slot is taken when the build runs
    except PaymentRejected as p:
        print(f'[gate] rejected at job create: {p.code}')
        return cors_response(402, {'error': p.message, 'code': p.code})

    job_id = uuid.uuid4().hex
    _put_json(f'jobs/{job_id}.json', {
        'checkout_id': checkout_id,
        'filename': _safe_filename(data.get('filename')),
        'created_at': int(time.time()),
    })
    post = _s3.generate_presigned_post(
        Bucket=JOBS_BUCKET, Key=f'in/{job_id}.xlsx',
        Fields={'Content-Type': XLSX_MIME, 'x-amz-server-side-encryption': 'AES256'},
        Conditions=[
            ['content-length-range', 1, MAX_UPLOAD],
            {'Content-Type': XLSX_MIME},
            {'x-amz-server-side-encryption': 'AES256'},
        ],
        ExpiresIn=LINK_SECONDS,
    )
    print(f'[job] created {job_id}')
    return cors_response(200, {'job_id': job_id, 'upload': post})


def _job_status(event):
    job_id = ((event.get('pathParameters') or {}).get('id') or '').lower()
    if not JOB_RE.match(job_id):
        return cors_response(400, {'error': 'Invalid job id'})
    meta = _get_json(f'jobs/{job_id}.json')
    if not meta:
        return cors_response(404, {'status': 'error', 'code': 'not_found', 'error': 'This download has expired. Please try again.'})
    if _exists(f'out/{job_id}.xlsx'):
        url = _s3.generate_presigned_url('get_object', Params={
            'Bucket': JOBS_BUCKET, 'Key': f'out/{job_id}.xlsx',
            'ResponseContentDisposition': f'attachment; filename="{meta["filename"]}"',
            'ResponseContentType': XLSX_MIME,
        }, ExpiresIn=LINK_SECONDS)
        return cors_response(200, {'status': 'done', 'url': url, 'filename': meta['filename']})
    err = _get_json(f'err/{job_id}.json')
    if err:
        return cors_response(200, {'status': 'error', 'code': err.get('code', 'build_failed'), 'error': err.get('message', '')})
    return cors_response(200, {'status': 'pending'})


def _process_upload(record):
    key = unquote_plus(record['s3']['object']['key'])
    m = re.match(r'^in/([a-f0-9]{32})\.xlsx$', key)
    if not m:
        return
    job_id = m.group(1)
    meta = _get_json(f'jobs/{job_id}.json')
    if not meta:
        print(f'[job] {job_id} has no metadata - discarding upload')
        _s3.delete_object(Bucket=JOBS_BUCKET, Key=key)
        return
    checkout_id = meta['checkout_id']

    try:
        used = _reserve_download(checkout_id)
    except PaymentRejected as p:
        print(f'[gate] rejected at build: {p.code}')
        _put_json(f'err/{job_id}.json', {'code': p.code, 'message': p.message})
        _s3.delete_object(Bucket=JOBS_BUCKET, Key=key)
        return

    try:
        raw = _s3.get_object(Bucket=JOBS_BUCKET, Key=key)['Body'].read()
        out = format_excel(io.BytesIO(raw))
        _s3.put_object(Bucket=JOBS_BUCKET, Key=f'out/{job_id}.xlsx', Body=out.getvalue(),
                       ContentType=XLSX_MIME, ServerSideEncryption='AES256')
        print(f'[job] {job_id} built - download {used} served')
    except Exception as e:
        _release_download(checkout_id)
        print(f'[job] {job_id} failed: {e}')
        import traceback
        traceback.print_exc()
        _put_json(f'err/{job_id}.json', {'code': 'build_failed',
                  'message': 'We could not build the workbook. Your payment has not been used - please try again.'})
    finally:
        try:
            _s3.delete_object(Bucket=JOBS_BUCKET, Key=key)      # raw statement data never lingers
        except Exception as e:
            print(f'[job] could not delete input: {e}')


def _legacy_format(event):
    """Old synchronous path - kept only until every browser has the new page."""
    try:
        data = _body(event)
    except Exception:
        return cors_response(400, {'error': 'Invalid request body'})
    checkout_id = str(data.get('checkout_id') or '')
    try:
        used = _reserve_download(checkout_id)
    except PaymentRejected as p:
        print(f'[gate] rejected: {p.code}')
        return cors_response(402, {'error': p.message, 'code': p.code})
    if not data.get('excel'):
        _release_download(checkout_id)
        return cors_response(400, {'error': 'No Excel data provided'})
    try:
        out = format_excel(io.BytesIO(base64.b64decode(data['excel'])))
        print(f'[gate] download {used} served (legacy)')
        return cors_response(200, {'excel': base64.b64encode(out.getvalue()).decode('utf-8'),
                                   'filename': _safe_filename(data.get('filename'))})
    except Exception as e:
        _release_download(checkout_id)
        print(f'Error: {e}')
        return cors_response(500, {'error': 'We could not build the workbook. Your payment has not been used.'})


def lambda_handler(event, context):
    if 'Records' in event:                                    # S3 upload event
        for record in event['Records']:
            _process_upload(record)
        return {'ok': True}

    route = event.get('routeKey', '')
    if route == 'POST /jobs':
        return _create_job(event)
    if route == 'GET /jobs/{id}':
        return _job_status(event)
    method = event.get('httpMethod') or ((event.get('requestContext') or {}).get('http') or {}).get('method')
    if method == 'OPTIONS':
        return cors_response(200, '')
    return _legacy_format(event)


# ─────────────────────────── workbook formatting (unchanged) ───────────────────────────
def format_excel(excel_buffer):
    from openpyxl import load_workbook
    from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
    from openpyxl.utils import get_column_letter
    from openpyxl.drawing.image import Image as XLImage
    from PIL import Image, ImageDraw, ImageFont

    wb = load_workbook(excel_buffer, data_only=True)

    # ── STYLES ──
    BLUE_FILL  = PatternFill("solid", start_color="1F3864", end_color="1F3864")
    GREEN_FILL = PatternFill("solid", start_color="007A3D", end_color="007A3D")
    LGGREEN    = PatternFill("solid", start_color="E8F5E9", end_color="E8F5E9")
    LBLUE      = PatternFill("solid", start_color="E3F2FD", end_color="E3F2FD")
    ALT_FILL   = PatternFill("solid", start_color="F2F9F5", end_color="F2F9F5")
    WHT_FILL   = PatternFill("solid", start_color="FFFFFF", end_color="FFFFFF")
    AMBER_FILL = PatternFill("solid", start_color="FFF8E1", end_color="FFF8E1")
    LGREY_FILL = PatternFill("solid", start_color="F5F5F5", end_color="F5F5F5")
    RED_BG     = PatternFill("solid", start_color="FFF5F5", end_color="FFF5F5")
    GREEN_BG   = PatternFill("solid", start_color="F0FFF4", end_color="F0FFF4")

    WHITE_BOLD = Font(name="Arial", bold=True, color="FFFFFF", size=11)
    GREEN_BOLD = Font(name="Arial", bold=True, color="007A3D", size=10)
    GREEN_LG   = Font(name="Arial", bold=True, color="007A3D", size=14)
    RED_BOLD   = Font(name="Arial", bold=True, color="C62828", size=10)
    RED_LG     = Font(name="Arial", bold=True, color="C62828", size=14)
    BLUE_BOLD  = Font(name="Arial", bold=True, color="1565C0", size=10)
    DARK_BOLD  = Font(name="Arial", bold=True, color="1F3864", size=10)
    NORM       = Font(name="Arial", size=10)
    NORM_BOLD  = Font(name="Arial", bold=True, size=10)
    NOTE_FONT  = Font(name="Arial", size=9, italic=True, color="888888")
    SEC_FONT   = Font(name="Arial", bold=True, color="FFFFFF", size=11)
    TITLE_W    = Font(name="Arial", bold=True, color="FFFFFF", size=15)
    TITLE_G    = Font(name="Arial", bold=True, color="FFFFFF", size=13)

    thin = Side(style='thin', color='CCCCCC')
    brd  = Border(left=thin, right=thin, top=thin, bottom=thin)
    CENTER = Alignment(horizontal="center", vertical="center", wrap_text=True)
    RIGHT  = Alignment(horizontal="right",  vertical="center")
    LEFT   = Alignment(horizontal="left",   vertical="center", wrap_text=True)

    def header_row(ws, row, ncols, fill=None):
        for col in range(1, ncols+1):
            c = ws.cell(row, col)
            c.fill = fill or BLUE_FILL
            c.font = WHITE_BOLD
            c.alignment = CENTER
            c.border = brd
        ws.row_dimensions[row].height = 24

    def title_row(ws, row, ncols, text, fill, font):
        ws.merge_cells(start_row=row, start_column=1, end_row=row, end_column=ncols)
        c = ws.cell(row, 1)
        c.value = text; c.font = font; c.fill = fill
        c.alignment = CENTER
        ws.row_dimensions[row].height = 30

    def note_row(ws, row, ncols):
        for col in range(1, ncols+1):
            c = ws.cell(row, col)
            c.fill = AMBER_FILL; c.font = NOTE_FONT
            c.alignment = LEFT; c.border = brd
        ws.row_dimensions[row].height = 16

    def alt_fill(row):
        return ALT_FILL if row % 2 == 0 else WHT_FILL

    # ── READ DATA FOR DASHBOARD ──
    total_in = total_out = net = 0
    txn_count = 0
    fuliza_awarded = 0.0
    fuliza_recovered = 0.0
    monthly_fuliza = {}

    # Extract Fuliza before any insert_rows
    txn_sheet = 'Filtered Transactions' if 'Filtered Transactions' in wb.sheetnames else 'All Transactions'
    if txn_sheet in wb.sheetnames:
        ws_txn = wb[txn_sheet]
        cat_col = paid_in_col = wdl_col = date_col = None
        for r in ws_txn.iter_rows(min_row=1, max_row=5, values_only=True):
            hdrs = [str(v or '').lower().strip() for v in r]
            if any('category' in h for h in hdrs):
                try:
                    cat_col     = next(i for i,h in enumerate(hdrs) if 'category' in h)
                    paid_in_col = next(i for i,h in enumerate(hdrs) if 'paid in' in h)
                    wdl_col     = next(i for i,h in enumerate(hdrs) if 'withdrawn' in h)
                    date_col    = next(i for i,h in enumerate(hdrs) if 'date' in h)
                except StopIteration:
                    pass
                break
        if cat_col is not None:
            for row in ws_txn.iter_rows(min_row=1, values_only=True):
                if row[cat_col] is None: continue
                cat  = str(row[cat_col]).strip()
                date = str(row[date_col] or '')[:7]
                if cat == 'Fuliza / Overdraft Credit':
                    v = row[paid_in_col]
                    if isinstance(v,(int,float)):
                        fuliza_awarded += abs(v)
                        if date not in monthly_fuliza: monthly_fuliza[date]={'awarded':0.0,'recovered':0.0}
                        monthly_fuliza[date]['awarded'] += abs(v)
                elif cat == 'Loan Repayment':
                    v = row[wdl_col]
                    if isinstance(v,(int,float)):
                        fuliza_recovered += abs(v)
                        if date not in monthly_fuliza: monthly_fuliza[date]={'awarded':0.0,'recovered':0.0}
                        monthly_fuliza[date]['recovered'] += abs(v)

    if 'Summary' in wb.sheetnames:
        ws_s = wb['Summary']
        for row in range(1, ws_s.max_row+1):
            a = str(ws_s.cell(row,1).value or '')
            b = ws_s.cell(row,2).value
            if 'Paid In' in a and isinstance(b,(int,float)): total_in = b
            if 'Withdrawn' in a and isinstance(b,(int,float)): total_out = b
            if 'Net Cash' in a and isinstance(b,(int,float)): net = b
            if 'Total Transactions' in a and isinstance(b,(int,float)): txn_count = int(b)

    # Clean totals (Fuliza excluded)
    clean_in        = total_in  - fuliza_awarded
    clean_out       = abs(total_out) - fuliza_recovered
    fuliza_net_cost = fuliza_awarded - fuliza_recovered

    categories = []
    if 'Category Breakdown' in wb.sheetnames:
        ws_c = wb['Category Breakdown']
        for row in ws_c.iter_rows(min_row=2, values_only=True):
            if row[0] and row[1] and 'Note' not in str(row[0]) and isinstance(row[1],(int,float)):
                categories.append({'name':str(row[0]),'amount':float(row[1]),'pct':str(row[2] or '0%')})

    payees = []
    if 'Payee Analysis' in wb.sheetnames:
        ws_p = wb['Payee Analysis']
        for row in ws_p.iter_rows(min_row=2, values_only=True):
            if row[0] and isinstance(row[0],int) and row[3] and isinstance(row[3],(int,float)):
                payees.append({'rank':row[0],'name':str(row[1]),'amount':float(row[3])})

    months = []
    if 'Monthly Summary' in wb.sheetnames:
        ws_m = wb['Monthly Summary']
        for row in ws_m.iter_rows(min_row=2, values_only=True):
            if row[0] and str(row[0]) not in ['TOTAL','*Actual spend excludes loan repayments and transaction charges']:
                try:
                    mk = str(row[0])
                    # Same Fuliza adjustment the Monthly Summary sheet gets, so chart bars match the cells
                    mf = monthly_fuliza.get(mk, {'awarded':0.0,'recovered':0.0})
                    months.append({'month':mk,
                                   'in':    max(0.0, float(row[1] or 0) - mf['awarded']),
                                   'out':   max(0.0, float(row[2] or 0) - mf['recovered']),
                                   'spend': float(row[3] or 0)})
                except: pass

    # ── BUILD DASHBOARD IMAGE ──
    def hex2rgb(h): h=h.lstrip('#'); return tuple(int(h[i:i+2],16) for i in (0,2,4))
    def fmt(n): return f"KES {abs(n):,.2f}"

    W,H = 1400,920
    img = Image.new('RGB',(W,H),color='#FFFFFF')
    draw = ImageDraw.Draw(img)

    # Try fonts — Lambda has limited fonts, fall back gracefully
    try:
        fB  = ImageFont.truetype("/var/task/fonts/DejaVuSans-Bold.ttf", 22)
        fB2 = ImageFont.truetype("/var/task/fonts/DejaVuSans-Bold.ttf", 15)
        fN  = ImageFont.truetype("/var/task/fonts/DejaVuSans.ttf", 12)
        fS  = ImageFont.truetype("/var/task/fonts/DejaVuSans.ttf", 10)
        fKP = ImageFont.truetype("/var/task/fonts/DejaVuSans-Bold.ttf", 17)
        fKS = ImageFont.truetype("/var/task/fonts/DejaVuSans.ttf", 11)
    except:
        try:
            fB=fB2=ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",18)
            fN=fS=fKS=ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",11)
            fKP=fB
        except:
            fB=fB2=fN=fS=fKP=fKS=ImageFont.load_default()

    GREEN  = hex2rgb('#007A3D')
    RED    = hex2rgb('#C62828')
    BLUE   = hex2rgb('#1565C0')
    DBLUE  = hex2rgb('#1F3864')
    GREY   = hex2rgb('#555555')
    WHITE  = hex2rgb('#FFFFFF')
    CAT_COLORS = ['#007A3D','#C62828','#1565C0','#F57C00','#6A1B9A','#00838F']

    # Header bar
    draw.rectangle([0,0,W,72], fill=GREEN)
    draw.text((20,12), "Cheche Technologies", font=fB, fill=WHITE)
    draw.text((20,44), "M-Pesa Statement Financial Analysis  ·  Loans & transaction charges excluded from expenditure analysis", font=fS, fill=(200,255,220))

    # KPI cards (Fuliza excluded)
    kpis = [
        ("Total Received",  fmt(clean_in),              GREEN,                              '#E8F5E9'),
        ("Total Withdrawn", fmt(clean_out),              RED,                                '#FFF5F5'),
        ("Net Cash Flow",   fmt(clean_in - clean_out),  GREEN if (clean_in-clean_out)>=0 else RED, '#F0FFF4' if (clean_in-clean_out)>=0 else '#FFF5F5'),
        ("Transactions",    f"{int(txn_count):,}",      BLUE,                               '#E3F2FD'),
    ]
    cw = (W-60)//4
    for i,(lbl,val,col,bg) in enumerate(kpis):
        x = 20+i*(cw+8)
        draw.rectangle([x,86,x+cw,168], fill=hex2rgb(bg), outline=(210,210,210))
        draw.rectangle([x,86,x+4,168], fill=col)
        draw.text((x+14,96), lbl, font=fKS, fill=GREY)
        draw.text((x+14,116), val[:22], font=fKP, fill=col)

    # Pie chart
    draw.rectangle([20,188,680,520], fill=hex2rgb('#FAFAFA'), outline=(220,220,220))
    draw.text((30,198), "SPENDING BY CATEGORY", font=fB2, fill=DBLUE)
    draw.line([30,220,670,220], fill=(210,210,210), width=1)
    cx,cy,r = 155,365,110
    grand = sum(c['amount'] for c in categories[:6])
    cum = -90
    for i,cat in enumerate(categories[:6]):
        if grand == 0: break
        sweep = (cat['amount']/grand)*360
        color = hex2rgb(CAT_COLORS[i])
        pts = [(cx,cy)]
        steps = max(4,int(sweep/2))
        for s in range(steps+1):
            a = math.radians(cum+s*(sweep/steps))
            pts.append((cx+r*math.cos(a), cy+r*math.sin(a)))
        if len(pts)>=3: draw.polygon(pts, fill=color, outline=WHITE)
        cum += sweep
    lx = 295
    for i,cat in enumerate(categories[:6]):
        ly = 235+i*44
        draw.rectangle([lx,ly+2,lx+14,ly+16], fill=hex2rgb(CAT_COLORS[i]))
        draw.text((lx+20,ly), cat['name'], font=fN, fill=GREY)
        draw.text((lx+20,ly+17), fmt(cat['amount'])+'  ('+cat['pct']+')', font=fS, fill=hex2rgb(CAT_COLORS[i]))

    # Bar chart
    draw.rectangle([700,188,W-20,520], fill=hex2rgb('#FAFAFA'), outline=(220,220,220))
    draw.text((710,198), "TOP PAYEES BY SPEND", font=fB2, fill=DBLUE)
    draw.line([710,220,W-30,220], fill=(210,210,210), width=1)
    max_p = payees[0]['amount'] if payees else 1
    bar_w = W-20-700-180
    for i,p in enumerate(payees[:8]):
        by = 235+i*34
        blen = int((p['amount']/max_p)*bar_w*0.72)
        col = hex2rgb(CAT_COLORS[i] if i<len(CAT_COLORS) else '#555555')
        name = (p['name'][:24]+'...') if len(p['name'])>24 else p['name']
        draw.text((710,by), name, font=fS, fill=GREY)
        draw.rectangle([710,by+13,710+max(4,blen),by+24], fill=col)
        draw.text((710+max(4,blen)+6,by+13), fmt(p['amount']), font=fS, fill=col)

    # Monthly trend
    draw.rectangle([20,535,W-20,880], fill=hex2rgb('#FAFAFA'), outline=(220,220,220))
    draw.text((30,545), "MONTHLY CASH FLOW TREND", font=fB2, fill=DBLUE)
    draw.rectangle([260,547,274,560], fill=GREEN)
    draw.text((278,547), "Received", font=fS, fill=GREEN)
    draw.rectangle([360,547,374,560], fill=RED)
    draw.text((378,547), "Spent", font=fS, fill=RED)
    draw.rectangle([430,547,444,560], fill=BLUE)
    draw.text((448,547), "Actual Spend", font=fS, fill=BLUE)
    draw.line([30,568,W-30,568], fill=(210,210,210), width=1)
    if months:
        CH=240; CT=585; ml=60
        mw=(W-ml*2)//max(1,len(months))
        max_m=max(max(m['in'],m['out']) for m in months) or 1
        for i,m in enumerate(months):
            mx=ml+i*mw
            ih=int((m['in']/max_m)*CH); oh=int((m['out']/max_m)*CH); sh=int((m['spend']/max_m)*CH)
            bw=mw//4-2
            draw.rectangle([mx,CT+CH-ih,mx+bw,CT+CH], fill=GREEN)
            draw.rectangle([mx+bw+2,CT+CH-oh,mx+bw*2+2,CT+CH], fill=RED)
            draw.rectangle([mx+bw*2+4,CT+CH-sh,mx+bw*3+4,CT+CH], fill=BLUE)
            draw.text((mx+2,CT+CH+6), m['month'][5:], font=fS, fill=GREY)
            if ih>20: draw.text((mx,CT+CH-ih-14), f"{m['in']/1000:.0f}K", font=fS, fill=GREEN)
            if oh>20: draw.text((mx+bw+2,CT+CH-oh-14), f"{m['out']/1000:.0f}K", font=fS, fill=RED)
            if sh>20: draw.text((mx+bw*2+4,CT+CH-sh-14), f"{m['spend']/1000:.0f}K", font=fS, fill=BLUE)

    # Footer
    draw.rectangle([0,880,W,920], fill=hex2rgb('#F0F0F0'))
    draw.text((20,892), "Generated by Cheche Technologies M-Pesa Converter v4.0  ·  chechetech.co.ke  ·  Data processed privately", font=fS, fill=GREY)

    img_buf = io.BytesIO()
    img.save(img_buf, format='PNG', dpi=(150,150))
    img_buf.seek(0)

    # ── FORMAT ALL SHEETS ──
    # All Transactions
    sheet_name = 'Filtered Transactions' if 'Filtered Transactions' in wb.sheetnames else 'All Transactions'
    if sheet_name in wb.sheetnames:
        ws1 = wb[sheet_name]
        ws1.insert_rows(1)
        title_row(ws1,1,9,f"M-PESA STATEMENT — {sheet_name.upper()}  |  Cheche Technologies v4.0",LGGREEN,Font(name="Arial",bold=True,size=13,color="007A3D"))
        header_row(ws1,2,9)
        for row in range(3,ws1.max_row+1):
            f=alt_fill(row)
            for col in range(1,10):
                c=ws1.cell(row,col)
                c.fill=f; c.border=brd; c.font=NORM; c.alignment=LEFT
                if col==1: c.alignment=CENTER; c.font=NORM_BOLD
                elif col==7 and isinstance(c.value,(int,float)) and c.value>0:
                    c.font=GREEN_BOLD; c.fill=GREEN_BG; c.alignment=RIGHT; c.number_format='#,##0.00'
                elif col==8 and isinstance(c.value,(int,float)) and c.value<0:
                    c.font=RED_BOLD; c.fill=RED_BG; c.alignment=RIGHT; c.number_format='#,##0.00'
                elif col==9 and isinstance(c.value,(int,float)):
                    c.alignment=RIGHT; c.number_format='#,##0.00'
        for i,w in enumerate([5,14,20,48,25,22,16,16,16],1):
            ws1.column_dimensions[get_column_letter(i)].width=w
        ws1.freeze_panes='A3'

    # Summary
    ORANGE_HDR = PatternFill("solid", start_color="E65100", end_color="E65100")
    if 'Summary' in wb.sheetnames:
        ws2=wb['Summary']
        ws2.insert_rows(1,2)
        title_row(ws2,1,2,"M-PESA STATEMENT FINANCIAL ANALYSIS  —  Cheche Technologies v4.0",GREEN_FILL,TITLE_W)
        ws2.merge_cells('A2:B2')
        ws2['A2'].value="Actual cash flow excludes Fuliza loans & repayments  ·  All amounts in KES"
        ws2['A2'].font=NOTE_FONT; ws2['A2'].fill=LGGREEN; ws2['A2'].alignment=CENTER
        ws2.row_dimensions[2].height=18
        for row in range(3,ws2.max_row+1):
            a=str(ws2.cell(row,1).value or ''); b=ws2.cell(row,2).value
            if not a and not b: ws2.row_dimensions[row].height=8; continue
            if 'M-PESA STATEMENT FINANCIAL' in a:
                ws2.merge_cells(start_row=row,start_column=1,end_row=row,end_column=2)
                c=ws2.cell(row,1); c.fill=LGGREEN; c.font=Font(name="Arial",bold=True,size=11,color="007A3D"); c.alignment=CENTER; c.border=brd; continue
            if 'CASH FLOW SUMMARY' in a:
                ws2.merge_cells(start_row=row,start_column=1,end_row=row,end_column=2)
                c=ws2.cell(row,1); c.fill=BLUE_FILL; c.font=WHITE_BOLD; c.alignment=CENTER; c.border=brd; ws2.row_dimensions[row].height=24; continue
            if a=='NOTE':
                for col in range(1,3): c=ws2.cell(row,col); c.fill=AMBER_FILL; c.font=NOTE_FONT; c.alignment=LEFT; c.border=brd
                continue
            if 'Total Paid In' in a or 'Total Withdrawn' in a or 'Net Cash Flow' in a:
                lc=ws2.cell(row,1); vc=ws2.cell(row,2)
                vc.border=brd; vc.alignment=RIGHT; vc.number_format='#,##0.00'; ws2.row_dimensions[row].height=32
                if 'Paid In' in a:
                    vc.value=clean_in
                    lc.fill=GREEN_BG; lc.font=Font(name="Arial",bold=True,size=11,color="007A3D"); lc.alignment=LEFT; lc.border=brd
                    vc.fill=GREEN_BG; vc.font=GREEN_LG
                elif 'Withdrawn' in a:
                    vc.value=clean_out
                    lc.fill=RED_BG; lc.font=Font(name="Arial",bold=True,size=11,color="C62828"); lc.alignment=LEFT; lc.border=brd
                    vc.fill=RED_BG; vc.font=RED_LG
                elif 'Net' in a:
                    nv=clean_in-clean_out; vc.value=nv
                    ch="007A3D" if nv>=0 else "C62828"; bh="F0FFF4" if nv>=0 else "FFF5F5"
                    bf=PatternFill("solid",start_color=bh,end_color=bh)
                    lc.fill=bf; lc.font=Font(name="Arial",bold=True,size=11,color=ch); lc.alignment=LEFT; lc.border=brd
                    vc.fill=bf; vc.font=Font(name="Arial",bold=True,size=14,color=ch)
                continue
            for col in range(1,3):
                c=ws2.cell(row,col); c.fill=LGREY_FILL if col==1 else WHT_FILL
                c.font=DARK_BOLD if col==1 else NORM; c.alignment=LEFT; c.border=brd
            ws2.row_dimensions[row].height=20
        # Fuliza block below
        last=ws2.max_row+1
        ws2.row_dimensions[last].height=8; last+=1
        ws2.merge_cells(start_row=last,start_column=1,end_row=last,end_column=2)
        c=ws2.cell(last,1); c.value="FULIZA / OVERDRAFT SUMMARY"
        c.fill=ORANGE_HDR; c.font=Font(name="Arial",bold=True,color="FFFFFF",size=11); c.alignment=CENTER; c.border=brd
        ws2.row_dimensions[last].height=24; last+=1
        ws2.merge_cells(start_row=last,start_column=1,end_row=last,end_column=2)
        c=ws2.cell(last,1); c.value="Fuliza figures are excluded from the cash flow totals above and shown separately below"
        c.font=NOTE_FONT; c.fill=AMBER_FILL; c.alignment=LEFT; c.border=brd
        ws2.row_dimensions[last].height=16; last+=1
        for lbl,val,col,bg in [
            ("Total Fuliza Awarded",   fuliza_awarded,   "F57C00","FFF3E0"),
            ("Total Fuliza Recovered", fuliza_recovered, "007A3D","E8F5E9"),
            ("Net Fuliza Cost",        fuliza_net_cost,  "C62828","FFF5F5"),
        ]:
            bf=PatternFill("solid",start_color=bg,end_color=bg)
            lc=ws2.cell(last,1); vc=ws2.cell(last,2)
            lc.value=lbl; vc.value=val
            lc.fill=bf; lc.font=Font(name="Arial",bold=True,size=11,color=col); lc.alignment=LEFT; lc.border=brd
            vc.fill=bf; vc.font=Font(name="Arial",bold=True,size=14,color=col)
            vc.border=brd; vc.alignment=RIGHT; vc.number_format='#,##0.00'
            ws2.row_dimensions[last].height=32; last+=1
        ws2.column_dimensions['A'].width=40; ws2.column_dimensions['B'].width=58

    # Payee Analysis
    if 'Payee Analysis' in wb.sheetnames:
        ws3=wb['Payee Analysis']
        ws3.insert_rows(1)
        title_row(ws3,1,6,"PAYEE ANALYSIS — Largest to Smallest Expenditure  |  Loans & Charges Excluded",GREEN_FILL,TITLE_G)
        header_row(ws3,2,6)
        note_row(ws3,3,6)
        for row in range(4,ws3.max_row+1):
            f=alt_fill(row)
            for col in range(1,7):
                c=ws3.cell(row,col); v=c.value
                c.fill=f; c.border=brd; c.font=NORM; c.alignment=LEFT
                if col==1: c.alignment=CENTER; c.font=NORM_BOLD
                elif col==2: c.font=NORM_BOLD
                elif col==4 and isinstance(v,(int,float)): c.font=RED_BOLD; c.alignment=RIGHT; c.number_format='#,##0.00'; c.fill=RED_BG
                elif col==5: c.alignment=CENTER
                elif col==6 and isinstance(v,(int,float)): c.alignment=RIGHT; c.number_format='#,##0.00'
        for i,w in enumerate([6,32,22,18,14,22],1): ws3.column_dimensions[get_column_letter(i)].width=w
        ws3.freeze_panes='A4'

    # Category Breakdown
    if 'Category Breakdown' in wb.sheetnames:
        ws4=wb['Category Breakdown']
        ws4.insert_rows(1)
        title_row(ws4,1,4,"CATEGORY BREAKDOWN — Actual Expenditure Analysis  |  Loans & Charges Excluded",BLUE_FILL,TITLE_G)
        header_row(ws4,2,4)
        note_row(ws4,3,4)
        cat_clrs={'Send Money':'FFF3E0','Bill Payment':'E3F2FD','Shopping & Merchants':'F3E5F5',
                  'Airtime & Data':'E8F5E9','Utilities':'FFF9C4','Education':'E0F7FA',
                  'Food & Dining':'FCE4EC','Fuel & Transport':'E8EAF6','Other':'FAFAFA'}
        for row in range(4,ws4.max_row+1):
            cv=str(ws4.cell(row,1).value or '')
            rc=cat_clrs.get(cv,'FFFFFF')
            rf=PatternFill("solid",start_color=rc,end_color=rc)
            for col in range(1,5):
                c=ws4.cell(row,col); v=c.value
                c.fill=rf; c.border=brd; c.font=NORM; c.alignment=LEFT
                if col==1: c.font=NORM_BOLD
                elif col==2 and isinstance(v,(int,float)): c.font=RED_BOLD; c.alignment=RIGHT; c.number_format='#,##0.00'
                elif col==3: c.alignment=CENTER; c.font=DARK_BOLD
                elif col==4: c.alignment=CENTER
            ws4.row_dimensions[row].height=22
        for i,w in enumerate([28,18,14,14],1): ws4.column_dimensions[get_column_letter(i)].width=w

    # Top Transactions
    if 'Top Transactions' in wb.sheetnames:
        ws5=wb['Top Transactions']
        ws5.insert_rows(1)
        title_row(ws5,1,5,"TOP TRANSACTIONS ANALYSIS  —  Loans & Transaction Charges Excluded",GREEN_FILL,TITLE_G)
        sec_titles=['TOP 10 LARGEST SINGLE EXPENDITURES','TOP 10 LARGEST RECEIPTS','MOST FREQUENT PAYEES']
        col_hdrs={'Rank','Receipt','Date','Payee / Merchant','Amount (KES)','Source','No. of Transactions'}
        current_sec=None; alt_n=0
        for row in range(2,ws5.max_row+1):
            vals=[ws5.cell(row,c).value for c in range(1,6)]
            first=str(vals[0] or '')
            is_blank=not any(v for v in vals if v is not None)
            if is_blank: ws5.row_dimensions[row].height=8; alt_n=0; continue
            is_sec=any(first.startswith(s) for s in sec_titles)
            is_hdr=first in col_hdrs
            if is_sec:
                current_sec=first; alt_n=0
                ws5.merge_cells(start_row=row,start_column=1,end_row=row,end_column=5)
                c=ws5.cell(row,1); c.fill=GREEN_FILL; c.font=SEC_FONT; c.alignment=LEFT; c.border=brd; ws5.row_dimensions[row].height=24
            elif is_hdr:
                header_row(ws5,row,5)
            else:
                alt_n+=1; f=alt_fill(alt_n)
                for col in range(1,6):
                    c=ws5.cell(row,col); v=c.value
                    c.fill=f; c.border=brd; c.font=NORM; c.alignment=LEFT
                    if col==1: c.alignment=CENTER; c.font=NORM_BOLD
                    elif col==2: c.font=Font(name="Arial",size=9,color="555555")
                    elif col==3: c.alignment=CENTER
                    elif col==4: c.font=NORM_BOLD
                    elif col==5 and isinstance(v,(int,float)):
                        c.alignment=RIGHT; c.number_format='#,##0.00'
                        if current_sec and 'EXPENDITURE' in current_sec: c.font=RED_BOLD; c.fill=RED_BG
                        elif current_sec and 'RECEIPT' in current_sec: c.font=GREEN_BOLD; c.fill=GREEN_BG
                        else: c.font=BLUE_BOLD; c.alignment=CENTER
                ws5.row_dimensions[row].height=20
        for i,w in enumerate([6,14,12,36,18],1): ws5.column_dimensions[get_column_letter(i)].width=w
        ws5.freeze_panes='A2'

    # Monthly Summary
    if 'Monthly Summary' in wb.sheetnames:
        ws6=wb['Monthly Summary']
        ws6.insert_rows(1)
        title_row(ws6,1,6,"MONTHLY CASH FLOW SUMMARY  |  Fuliza Excluded from Actual Received & Withdrawn",BLUE_FILL,TITLE_G)
        header_row(ws6,2,6)
        note_row(ws6,3,6)
        for row in range(4,ws6.max_row+1):
            month_key = str(ws6.cell(row,1).value or '')
            is_tot = month_key.upper()=='TOTAL'
            f=PatternFill("solid",start_color="C8E6C9",end_color="C8E6C9") if is_tot else alt_fill(row)
            # Per-month Fuliza adjustment
            mf = monthly_fuliza.get(month_key, {'awarded':0.0,'recovered':0.0}) if not is_tot else {'awarded':fuliza_awarded,'recovered':fuliza_recovered}
            for col in range(1,7):
                c=ws6.cell(row,col); v=c.value
                c.fill=f; c.border=brd; c.alignment=LEFT
                c.font=NORM_BOLD if is_tot else NORM
                if col==1: c.font=NORM_BOLD; c.alignment=CENTER
                elif col==2 and isinstance(v,(int,float)):
                    c.value = round(v - mf['awarded'], 2)
                    c.font=Font(name="Arial",color="007A3D",size=10,bold=is_tot); c.alignment=RIGHT; c.number_format='#,##0.00'
                elif col==3 and isinstance(v,(int,float)):
                    c.value = round(v - mf['recovered'], 2)
                    c.font=Font(name="Arial",color="C62828",size=10,bold=is_tot); c.alignment=RIGHT; c.number_format='#,##0.00'
                elif col==4 and isinstance(v,(int,float)):
                    c.font=Font(name="Arial",color="1565C0",size=10,bold=is_tot)
                    if not is_tot: c.fill=PatternFill("solid",start_color="E3F2FD",end_color="E3F2FD")
                    c.alignment=RIGHT; c.number_format='#,##0.00'
                elif col==5 and isinstance(v,(int,float)):
                    nv=v; ch="007A3D" if nv>=0 else "C62828"
                    c.font=Font(name="Arial",color=ch,size=10,bold=is_tot); c.alignment=RIGHT; c.number_format='#,##0.00'
                    if not is_tot: c.fill=PatternFill("solid",start_color="F0FFF4" if nv>=0 else "FFF5F5",end_color="F0FFF4" if nv>=0 else "FFF5F5")
                elif col==6: c.alignment=CENTER
            ws6.row_dimensions[row].height=22
        # Fuliza monthly block
        last6=ws6.max_row+1
        ws6.row_dimensions[last6].height=8; last6+=1
        ws6.merge_cells(start_row=last6,start_column=1,end_row=last6,end_column=6)
        c=ws6.cell(last6,1); c.value="FULIZA / OVERDRAFT MONTHLY DETAIL"
        c.fill=ORANGE_HDR; c.font=Font(name="Arial",bold=True,color="FFFFFF",size=11); c.alignment=CENTER; c.border=brd
        ws6.row_dimensions[last6].height=24; last6+=1
        for ci,hdr in enumerate(["Month","Fuliza Awarded","Fuliza Recovered","Net Cost","",""],1):
            c=ws6.cell(last6,ci); c.value=hdr
            c.fill=BLUE_FILL; c.font=WHITE_BOLD; c.alignment=CENTER; c.border=brd
        ws6.row_dimensions[last6].height=22; last6+=1
        total_fa=total_fr=0.0
        for mk in sorted(monthly_fuliza.keys()):
            if not mk or len(mk)<7: continue
            fa=monthly_fuliza[mk]['awarded']; fr=monthly_fuliza[mk]['recovered']; fc=fa-fr
            total_fa+=fa; total_fr+=fr
            f=alt_fill(last6)
            for ci,val in enumerate([mk,fa,fr,fc,None,None],1):
                c=ws6.cell(last6,ci); c.fill=f; c.border=brd; c.alignment=CENTER
                if val is None: continue
                c.value=val
                if ci==1: c.font=NORM_BOLD
                elif ci==2: c.font=Font(name="Arial",color="F57C00",size=10); c.alignment=RIGHT; c.number_format='#,##0.00'
                elif ci==3: c.font=Font(name="Arial",color="007A3D",size=10); c.alignment=RIGHT; c.number_format='#,##0.00'
                elif ci==4:
                    col4="C62828" if fc>0 else "007A3D"
                    c.font=Font(name="Arial",color=col4,size=10,bold=True); c.alignment=RIGHT; c.number_format='#,##0.00'
            ws6.row_dimensions[last6].height=20; last6+=1
        tot_cost=total_fa-total_fr
        tf=PatternFill("solid",start_color="C8E6C9",end_color="C8E6C9")
        for ci,val in enumerate(["TOTAL",total_fa,total_fr,tot_cost,None,None],1):
            c=ws6.cell(last6,ci); c.fill=tf; c.border=brd; c.alignment=CENTER
            if val is None: continue
            c.value=val
            if ci==1: c.font=NORM_BOLD
            elif ci==2: c.font=Font(name="Arial",color="F57C00",size=10,bold=True); c.alignment=RIGHT; c.number_format='#,##0.00'
            elif ci==3: c.font=Font(name="Arial",color="007A3D",size=10,bold=True); c.alignment=RIGHT; c.number_format='#,##0.00'
            elif ci==4:
                col4="C62828" if tot_cost>0 else "007A3D"
                c.font=Font(name="Arial",color=col4,size=10,bold=True); c.alignment=RIGHT; c.number_format='#,##0.00'
        ws6.row_dimensions[last6].height=24
        for i,w in enumerate([12,22,22,22,16,14],1): ws6.column_dimensions[get_column_letter(i)].width=w
        ws6.freeze_panes='A4'

    # ── DASHBOARD SHEET AS SHEET 1 ──
    if 'Dashboard' in wb.sheetnames:
        del wb['Dashboard']
    ws_dash = wb.create_sheet("Dashboard", 0)
    ws_dash.sheet_view.showGridLines = False
    ws_dash.column_dimensions['A'].width = 140
    ws_dash['A1'] = "Cheche Technologies — M-Pesa Statement Financial Analysis Dashboard"
    ws_dash['A1'].font = Font(name="Arial", bold=True, size=16, color="007A3D")
    ws_dash['A1'].fill = LGGREEN
    ws_dash.row_dimensions[1].height = 32
    ws_dash['A2'] = "Visual analysis below · For detailed data see: All Transactions · Summary · Payee Analysis · Category Breakdown · Top Transactions · Monthly Summary"
    ws_dash['A2'].font = NOTE_FONT
    ws_dash['A2'].fill = LGGREEN
    ws_dash.row_dimensions[2].height = 18
    ws_dash.row_dimensions[3].height = 10
    xl_img = XLImage(img_buf)
    xl_img.anchor = 'A4'
    xl_img.width  = 1050
    xl_img.height = 690
    ws_dash.add_image(xl_img)

    # Save to buffer
    out_buf = io.BytesIO()
    wb.save(out_buf)
    out_buf.seek(0)
    return out_buf