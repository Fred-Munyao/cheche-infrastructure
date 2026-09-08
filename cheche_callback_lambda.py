"""
cheche-payment-callback
Handles:
  - POST /stkpush   → initiate M-Pesa STK Push (price set server-side from plan)
  - GET  /status    → poll payment status
  - POST /callback  → Daraja confirmation webhook
  - POST /track     → anonymous usage analytics (client_id + event, no statement data)
  - GET  /token     → credential smoke test

Retention:
  cheche-payments   PENDING/FAILED expire 30 days after creation; PAID kept indefinitely
  cheche-analytics  every event expires 18 months after it is written
"""

import json, os, re, time, base64, urllib.request, boto3
from datetime import datetime

dynamodb  = boto3.resource('dynamodb', region_name='us-east-1')
payments  = dynamodb.Table(os.environ.get('PAYMENTS_TABLE', 'cheche-payments'))
analytics = dynamodb.Table(os.environ.get('ANALYTICS_TABLE', 'cheche-analytics'))

# ── Config — no defaults for anything that would silently point at sandbox ──
def _require(name):
    v = os.environ.get(name, '').strip()
    if not v:
        raise RuntimeError(f'Missing required environment variable: {name}')
    return v

CONSUMER_KEY    = os.environ.get('DARAJA_CONSUMER_KEY', '')
CONSUMER_SECRET = os.environ.get('DARAJA_CONSUMER_SECRET', '')
SHORTCODE       = os.environ.get('DARAJA_SHORTCODE', '')
PASSKEY         = os.environ.get('DARAJA_PASSKEY', '')
CALLBACK_URL    = os.environ.get('DARAJA_CALLBACK_URL', '')
ENVIRONMENT     = os.environ.get('DARAJA_ENV', 'production')
BASE_URL = 'https://sandbox.safaricom.co.ke' if ENVIRONMENT == 'sandbox' else 'https://api.safaricom.co.ke'

# ── Pricing — the browser never decides the amount ──
PLAN_PRICES = {'payg': 299}                       # pro / business added once accounts ship
PLAN_DESC   = {'payg': 'Cheche Converter - 1 Statement'}

PENDING_TTL_SECONDS   = 30 * 24 * 3600            # 30 days
ANALYTICS_TTL_SECONDS = 548 * 24 * 3600           # ~18 months

# ── Analytics allowlists ──
ALLOWED_EVENTS = {
    'page_view', 'convert_start', 'convert_success', 'convert_fail',
    'download_success', 'download_fail', 'paywall_shown', 'stk_initiated',
}
ALLOWED_META = {'txns', 'months', 'file_kb', 'method', 'filtered', 'ref', 'utm_source', 'utm_campaign', 'reason'}
CLIENT_ID_RE = re.compile(r'^[A-Za-z0-9_-]{8,64}$')

CORS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
}

def respond(status, body):
    return {'statusCode': status, 'headers': {**CORS, 'Content-Type': 'application/json'}, 'body': json.dumps(body)}

def _device(ua):
    ua = (ua or '').lower()
    if 'mobile' in ua or 'android' in ua or 'iphone' in ua:
        return 'mobile'
    return 'desktop' if ua else 'unknown'

def _parse_body(event):
    body = event.get('body') or '{}'
    if event.get('isBase64Encoded'):
        body = base64.b64decode(body).decode('utf-8')
    return json.loads(body)

def get_token():
    key, secret = _require('DARAJA_CONSUMER_KEY'), _require('DARAJA_CONSUMER_SECRET')
    creds = base64.b64encode(f'{key}:{secret}'.encode()).decode()
    req = urllib.request.Request(f'{BASE_URL}/oauth/v1/generate?grant_type=client_credentials', headers={'Authorization': f'Basic {creds}'})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())['access_token']

def initiate_stk(phone, amount, account_ref, description):
    shortcode, passkey, callback = _require('DARAJA_SHORTCODE'), _require('DARAJA_PASSKEY'), _require('DARAJA_CALLBACK_URL')
    token = get_token()
    timestamp = datetime.now().strftime('%Y%m%d%H%M%S')
    password = base64.b64encode(f'{shortcode}{passkey}{timestamp}'.encode()).decode()
    payload = {
        'BusinessShortCode': shortcode, 'Password': password, 'Timestamp': timestamp,
        'TransactionType': 'CustomerPayBillOnline', 'Amount': int(amount),
        'PartyA': phone, 'PartyB': shortcode, 'PhoneNumber': phone,
        'CallBackURL': callback, 'AccountReference': account_ref, 'TransactionDesc': description,
    }
    req = urllib.request.Request(
        f'{BASE_URL}/mpesa/stkpush/v1/processrequest',
        data=json.dumps(payload).encode(),
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())

def lambda_handler(event, context):
    method = event.get('httpMethod', 'POST')
    path   = event.get('path', '/')

    if method == 'OPTIONS':
        return respond(200, {})

    # GET /token — credential smoke test
    if method == 'GET' and '/token' in path:
        try:
            token = get_token()
            return respond(200, {'token': token[:20] + '...', 'env': ENVIRONMENT})
        except Exception as e:
            return respond(500, {'error': str(e)})

    # POST /track — anonymous usage event
    if method == 'POST' and '/track' in path:
        try:
            body      = _parse_body(event)
            client_id = str(body.get('client_id', ''))
            ev        = str(body.get('event', ''))
            if not CLIENT_ID_RE.match(client_id) or ev not in ALLOWED_EVENTS:
                return respond(400, {'error': 'Invalid event'})
            meta_in = body.get('meta') or {}
            meta = {}
            if isinstance(meta_in, dict):
                for k in ALLOWED_META:
                    if k in meta_in and meta_in[k] is not None:
                        v = meta_in[k]
                        if isinstance(v, bool):      meta[k] = v
                        elif isinstance(v, (int, float)): meta[k] = int(round(v))   # DynamoDB rejects Python floats
                        else:                        meta[k] = str(v)[:120]
            now_ms = int(time.time() * 1000)
            ua = (event.get('headers') or {}).get('User-Agent') or (event.get('headers') or {}).get('user-agent')
            analytics.put_item(Item={
                'client_id': client_id,
                'sk':        f'{now_ms}#{ev}',
                'event':     ev,
                'ts':        now_ms,
                'device':    _device(ua),
                'meta':      meta,
                'ttl':       int(time.time()) + ANALYTICS_TTL_SECONDS,
            })
            return respond(200, {'ok': True})
        except Exception as e:
            print(f'[track] {e}')
            return respond(200, {'ok': False})   # never let analytics break the client

    # POST /stkpush
    if method == 'POST' and '/stkpush' in path:
        try:
            body      = _parse_body(event)
            phone     = str(body.get('phone', ''))
            plan      = str(body.get('plan', 'payg')).lower()
            client_id = str(body.get('client_id', ''))
            if not phone.startswith('254') or len(phone) != 12 or not phone.isdigit():
                return respond(400, {'error': 'Invalid phone. Use 254XXXXXXXXX'})
            if plan not in PLAN_PRICES:
                return respond(400, {'error': 'This plan is not available yet'})
            amount      = PLAN_PRICES[plan]                 # ignore any amount sent by the browser
            account_ref = f'CHECHE-{plan.upper()}'
            result      = initiate_stk(phone, amount, account_ref, PLAN_DESC[plan])
            checkout_id = result.get('CheckoutRequestID', '')
            if result.get('ResponseCode', '1') != '0' or not checkout_id:
                return respond(400, {'error': result.get('ResponseDescription', 'STK Push failed'), 'raw': result})
            now = int(time.time())
            item = {
                'checkout_request_id': checkout_id,
                'merchant_request_id': result.get('MerchantRequestID', ''),
                'phone': phone, 'amount': amount, 'plan': plan,
                'status': 'PENDING', 'created_at': now,
                'ttl': now + PENDING_TTL_SECONDS,           # removed on PAID
            }
            if CLIENT_ID_RE.match(client_id):
                item['client_id'] = client_id
            payments.put_item(Item=item)
            return respond(200, {'success': True, 'checkout_request_id': checkout_id, 'amount': amount,
                                 'message': result.get('CustomerMessage', 'STK Push sent')})
        except Exception as e:
            print(f'[stkpush] {e}')
            return respond(500, {'error': str(e)})

    # GET /status
    if method == 'GET' and '/status' in path:
        try:
            checkout_id = (event.get('queryStringParameters') or {}).get('id', '')
            if not checkout_id:
                return respond(400, {'error': 'Missing id'})
            item = payments.get_item(Key={'checkout_request_id': checkout_id}).get('Item')
            if not item:
                return respond(404, {'error': 'Payment not found'})
            return respond(200, {'status': item.get('status', 'PENDING'), 'plan': item.get('plan', 'payg'),
                                 'amount': int(item.get('amount', 0))})
        except Exception as e:
            return respond(500, {'error': str(e)})

    # POST /callback — Daraja confirmation
    if method == 'POST' and '/callback' in path:
        try:
            body        = _parse_body(event)
            stk         = body.get('Body', {}).get('stkCallback', {})
            checkout_id = stk.get('CheckoutRequestID', '')
            result_code = stk.get('ResultCode', 1)
            result_desc = stk.get('ResultDesc', '')
            if not checkout_id:
                return respond(400, {'error': 'Missing CheckoutRequestID'})
            if result_code == 0:
                items = stk.get('CallbackMetadata', {}).get('Item', [])
                meta  = {i['Name']: i.get('Value') for i in items if 'Name' in i}
                payments.update_item(
                    Key={'checkout_request_id': checkout_id},
                    UpdateExpression='SET #s=:s, paid_at=:t, mpesa_receipt=:r, amount_paid=:a REMOVE #ttl',
                    ExpressionAttributeNames={'#s': 'status', '#ttl': 'ttl'},
                    ExpressionAttributeValues={':s': 'PAID', ':t': int(time.time()),
                                               ':r': meta.get('MpesaReceiptNumber', ''),
                                               ':a': int(meta.get('Amount', 0) or 0)}
                )
            else:
                payments.update_item(
                    Key={'checkout_request_id': checkout_id},
                    UpdateExpression='SET #s=:s, fail_reason=:r',
                    ExpressionAttributeNames={'#s': 'status'},
                    ExpressionAttributeValues={':s': 'FAILED', ':r': result_desc}
                )
            return respond(200, {'ResultCode': 0, 'ResultDesc': 'Accepted'})
        except Exception as e:
            print(f'[callback] {e}')
            return respond(500, {'error': str(e)})

    return respond(404, {'error': 'Not found'})
