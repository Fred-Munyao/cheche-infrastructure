# Cheche - Async Formatter Runbook

**Why:** a 6,720-row statement produced a 3.7 MB upload. Sent as one request through the formatter
API it can exceed the gateway's 30-second window on a normal connection (you saw 408), and large
results approach Lambda's ~6 MB response limit.

**What changes**
1. Browser asks `POST /jobs` - payment checked first, then it gets a 10-minute signed upload form.
2. Browser uploads the raw workbook **straight to a private, encrypted S3 bucket** (up to 25 MB).
3. The upload triggers the formatter (up to 120 s). It takes the paid slot, builds, saves the result,
   and **deletes the raw upload immediately**. A failed build gives the slot back.
4. Browser polls `GET /jobs/{id}` and downloads through a 10-minute private link.
   Clicking Download again for the same statement re-downloads the same file **free**.
5. Everything in the bucket is deleted automatically after 1 day.

The old `POST /format` path keeps working, so browsers holding the old page are not broken.

Paste one line at a time (Ctrl+V). If you open a new window, reload the Daraja values first
(state-recovery runbook, step 3).

---

## 0. Place the files

| File | Goes to |
|---|---|
| `lambda_function.py` | `cheche-infrastructure\lambda\excel-formatter\` (replaces) |
| `lambda.tf`, `formatter_jobs.tf`, `RUNBOOK_async_formatter.md` | `cheche-infrastructure\` |
| `converter.html` | `cheche-converter\` (replaces) |

```powershell
cd D:\Backed_up\Cheche\cheche-infrastructure; Move-Item "$env:USERPROFILE\Downloads\lambda_function.py" .\lambda\excel-formatter\ -Force; foreach ($f in 'lambda.tf','formatter_jobs.tf','RUNBOOK_async_formatter.md') { Move-Item "$env:USERPROFILE\Downloads\$f" .\ -Force }; Move-Item "$env:USERPROFILE\Downloads\converter.html" D:\Backed_up\Cheche\cheche-converter\ -Force
```
If a move fails, the browser renamed a duplicate (e.g. `lambda (1).tf`) - move the newest by its exact name.

## 1. Build the package

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; .\build_formatter.ps1
```
Expect `lambda_function.zip ready ... payment gate present, fonts present`.
(Add `-FromLivePackage` if pip is unavailable.)

## 2. Plan - backend goes FIRST this time

The new Lambda serves both the old and new page, so shipping it first breaks nothing.
```powershell
terraform plan -out async.tfplan -no-color | Tee-Object -FilePath plan.txt
```
**Safe plan:** `Plan: 11 to add, 2 to change, 0 to destroy`
- add: the jobs bucket + public-access block, encryption, lifecycle, CORS; the S3 IAM policy;
  the S3->Lambda permission and notification; the no-retry invoke config; routes `POST /jobs` and `GET /jobs/{id}`
- change: `aws_lambda_function.excel_formatter` (code + `JOBS_BUCKET`) and
  `aws_apigatewayv2_api.formatter_api` (CORS adds GET)
- **Stop and paste** if anything is destroyed or replaced.

## 3. Apply

```powershell
terraform apply async.tfplan
```

## 4. Check the new API refuses unpaid requests

```powershell
try { Invoke-RestMethod -Method Post -Uri "https://vtfoxobw6l.execute-api.us-east-1.amazonaws.com/prod/jobs" -ContentType "application/json" -Body '{"filename":"x"}' } catch { $_.ErrorDetails.Message }
```
Expect `"code": "payment_required"`.

## 5. Deploy the page

```powershell
aws s3 cp D:\Backed_up\Cheche\cheche-converter\converter.html s3://cheche-converter-app-dev/converter.html --content-type "text/html" --endpoint-url https://s3.amazonaws.com
```
```powershell
aws cloudfront create-invalidation --distribution-id EYD38S1N9UN3R --paths "/converter.html" --query "Invalidation.Status" --output text
```
```powershell
Copy-Item D:\Backed_up\Cheche\cheche-converter\converter.html D:\Backed_up\Cheche\site\converter.html -Force
```

## 6. Browser test with your 6,720-row statement

```powershell
.\mint_pass.ps1 -Id test_async_ui -MaxDownloads 2
```
1. Chrome: open chechetech.co.ke/converter.html, press **Ctrl + F5**, convert the big statement.
2. **Ctrl + Shift + J**, paste, Enter:  `_checkoutId='test_async_ui'; _paidForCurrent=true;`
3. Click **Download**. The button shows *Preparing -> Uploading securely -> Building* and the workbook downloads.
4. Click **Download again** - it downloads instantly (same file, **no charge**).
5. Check the count - expect **1**:
```powershell
aws dynamodb get-item --table-name cheche-payments --key '{\"checkout_request_id\":{\"S\":\"test_async_ui\"}}' --query "Item.download_count.N" --output text
```
6. Click **Convert another statement**, convert it again, re-run the console line, Download -> builds a new file (count **2**).
7. Convert once more, console line, Download -> *"This payment has already been used"* + paywall.

## 7. Verify data handling

```powershell
aws s3 ls s3://cheche-formatter-jobs-507629158424 --recursive
```
Expect **no `in/` objects** (raw uploads deleted after each build); `out/` and `jobs/` files remain
until the 1-day lifecycle removes them.

Build times:
```powershell
aws logs tail /aws/lambda/cheche-excel-formatter --since 30m --format short | Select-String -Pattern '\[job\]|\[gate\]|REPORT'
```

## 8. Clean up test records

```powershell
aws dynamodb delete-item --table-name cheche-payments --key '{\"checkout_request_id\":{\"S\":\"test_async_ui\"}}'
```

## 9. Commit both repos

```powershell
cd D:\Backed_up\Cheche\cheche-infrastructure; git add lambda\excel-formatter lambda.tf formatter_jobs.tf build_formatter.ps1 mint_pass.ps1 RUNBOOK_payment_gate.md RUNBOOK_async_formatter.md; git status
```
Nothing ending in `.zip` or `.tfplan` may be staged. Then:
```powershell
git commit -m "formatter: async jobs via private S3 (upload/trigger/poll/download), payment gate, reproducible build"; git push
```
```powershell
cd D:\Backed_up\Cheche\cheche-converter; git add converter.html; git commit -m "converter: async workbook build (S3 upload + polling), free re-download, 402 gate handling, auto-download fix"; git push
```

---

## Follow-ups
- **Privacy policy wording.** Statement data is no longer only "processed and discarded": the raw
  upload exists for seconds, the finished workbook for up to 24 hours, private and encrypted.
  Update `privacy.html` to say so before go-live - the trust claim must match what the system does.
- **Retire `POST /format`** about a week after the new page is live: remove the legacy route and
  `_legacy_format()`, so every build goes through the async path.
- **Demo recordings:** mint a pass (`.\mint_pass.ps1 -Id demo_2026_09 -MaxDownloads 50 -WindowHours 168`)
  and port this page's download code into `demo/converter_demo.html`.
