# Cheche - Server-Side Payment Gate Runbook

**What this ships:** the formatter only builds a workbook for a real, PAID M-Pesa payment.
One payment = up to **3 workbooks within 24 hours** (covers a failed download, a filtered +
unfiltered copy, a re-download). A failed build never uses up a paid download.
Also fixes a bug: after paying, the workbook now downloads automatically.

**Repos:** `D:\Backed_up\Cheche\cheche-infrastructure` and `D:\Backed_up\Cheche\cheche-converter`
Paste one line at a time (Ctrl+V).

---

## 0. Place the files

| File | Goes to |
|---|---|
| `lambda_function.py` | `cheche-infrastructure\lambda\excel-formatter\` (create the folders) |
| `build_formatter.ps1`, `mint_pass.ps1`, `lambda.tf`, `RUNBOOK_payment_gate.md` | `cheche-infrastructure\` (lambda.tf replaces the current one) |
| `converter.html` | `cheche-converter\` (replaces the current one) |

```powershell
cd D:\Backed_up\Cheche\cheche-infrastructure; New-Item -ItemType Directory -Force lambda\excel-formatter | Out-Null; Move-Item "$env:USERPROFILE\Downloads\lambda_function.py" .\lambda\excel-formatter\ -Force; foreach ($f in 'build_formatter.ps1','mint_pass.ps1','lambda.tf','RUNBOOK_payment_gate.md') { Move-Item "$env:USERPROFILE\Downloads\$f" .\ -Force; Unblock-File ".\$f" }; Move-Item "$env:USERPROFILE\Downloads\converter.html" D:\Backed_up\Cheche\cheche-converter\ -Force
```

## 1. Build the formatter package

First run reads the exact library versions and fonts from the live package in your snapshot:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; .\build_formatter.ps1 -Init
```
Expect `requirements.txt` listing openpyxl, et_xmlfile, pillow (versions pinned), fonts copied,
and **`lambda_function.zip ready ... payment gate present, fonts present`**.
If pip is not installed or fails: `.\build_formatter.ps1 -FromLivePackage`

## 2. Deploy the page FIRST

The new page only *adds* a field the current formatter ignores, so it is safe to ship before the Lambda.
The reverse order would briefly block every download.
```powershell
aws s3 cp D:\Backed_up\Cheche\cheche-converter\converter.html s3://cheche-converter-app-dev/converter.html --content-type "text/html" --endpoint-url https://s3.amazonaws.com
```
```powershell
aws cloudfront create-invalidation --distribution-id EYD38S1N9UN3R --paths "/converter.html" --query "Invalidation.Status" --output text
```
Also keep the deploy folder in sync:
```powershell
Copy-Item D:\Backed_up\Cheche\cheche-converter\converter.html D:\Backed_up\Cheche\site\converter.html -Force
```

## 3. Deploy the formatter with Terraform

New window? Load the Daraja values first (runbook step 3 of the state recovery).
```powershell
terraform plan -out gate.tfplan -no-color | Tee-Object -FilePath plan.txt
```
**Safe plan:** `Plan: 0 to add, 1 to change, 0 to destroy` - only `aws_lambda_function.excel_formatter`
(`source_code_hash` + 3 new environment variables). Anything else: stop and paste it.
```powershell
terraform apply gate.tfplan
```

## 4. Test the gate (sandbox)

**4a. No payment -> refused**
```powershell
try { Invoke-RestMethod -Method Post -Uri "https://vtfoxobw6l.execute-api.us-east-1.amazonaws.com/prod/format" -ContentType "application/json" -Body '{"excel":"eA=="}' } catch { $_.ErrorDetails.Message }
```
Expect `402` body with `"code": "payment_required"`.

**4b. Used payment -> refused**
```powershell
.\mint_pass.ps1 -Id test_gate_used -MaxDownloads 1 -DownloadCount 1
```
```powershell
try { Invoke-RestMethod -Method Post -Uri "https://vtfoxobw6l.execute-api.us-east-1.amazonaws.com/prod/format" -ContentType "application/json" -Body '{"excel":"eA==","checkout_id":"test_gate_used"}' } catch { $_.ErrorDetails.Message }
```
Expect `"code": "payment_used"`.

**4c. Pending payment -> "still confirming"**
```powershell
.\mint_pass.ps1 -Id test_gate_pending -Status PENDING
```
```powershell
try { Invoke-RestMethod -Method Post -Uri "https://vtfoxobw6l.execute-api.us-east-1.amazonaws.com/prod/format" -ContentType "application/json" -Body '{"excel":"eA==","checkout_id":"test_gate_pending"}' } catch { $_.ErrorDetails.Message }
```
Expect `"code": "payment_pending"`.

**4d. Failed build does not use up the payment**
```powershell
.\mint_pass.ps1 -Id test_gate_release -MaxDownloads 1
```
```powershell
try { Invoke-RestMethod -Method Post -Uri "https://vtfoxobw6l.execute-api.us-east-1.amazonaws.com/prod/format" -ContentType "application/json" -Body '{"excel":"eA==","checkout_id":"test_gate_release"}' } catch { $_.ErrorDetails.Message }
```
```powershell
aws dynamodb get-item --table-name cheche-payments --key '{\"checkout_request_id\":{\"S\":\"test_gate_release\"}}' --query "Item.download_count.N" --output text
```
The POST fails with *"Your payment has not been used"* (eA== is not a real workbook) and the count reads **0**.

**4e. Real download in the browser (paid path + auto-download fix)**
```powershell
.\mint_pass.ps1 -Id test_gate_ui -MaxDownloads 2
```
Open chechetech.co.ke/converter.html, convert a statement, press F12 -> Console, run:
`_checkoutId='test_gate_ui'; _paidForCurrent=true;`
Click Download: workbook downloads. Click again: downloads (2 of 2). Click a third time: the page
shows *"This payment has already been used"* and opens the paywall.

Optional full M-Pesa sandbox run: click Download without the console lines, pay with sandbox test
number `708374149`; after the callback the workbook should download **automatically**.

**4f. Clean up** (they would also self-delete via TTL)
```powershell
foreach ($i in 'test_gate_used','test_gate_pending','test_gate_release','test_gate_ui') { aws dynamodb delete-item --table-name cheche-payments --key "{\`"checkout_request_id\`":{\`"S\`":\`"$i\`"}}" }
```

## 5. Commit both repos

```powershell
cd D:\Backed_up\Cheche\cheche-infrastructure; git add lambda\excel-formatter build_formatter.ps1 mint_pass.ps1 lambda.tf RUNBOOK_payment_gate.md; git status
```
Staged: `lambda/excel-formatter/` (lambda_function.py, requirements.txt, fonts/), the two scripts, lambda.tf, runbook.
No `lambda_function.zip`, no `gate.tfplan`.
```powershell
git commit -m "formatter: source in repo + reproducible build; server-side payment gate (3 workbooks / 24h per PAID checkout)"; git push
```
```powershell
cd D:\Backed_up\Cheche\cheche-converter; git add converter.html; git commit -m "converter: send checkout_id to formatter, handle 402 gate responses, fix auto-download after payment"; git push
```

## 6. Check formatter durations against the 30 s API limit

```powershell
aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Duration --dimensions Name=FunctionName,Value=cheche-excel-formatter --start-time (Get-Date).AddDays(-30).ToUniversalTime().ToString('s') --end-time (Get-Date).ToUniversalTime().ToString('s') --period 2592000 --statistics Average Maximum --query "Datapoints[].[Average,Maximum]" --output text
```
Values are milliseconds. A maximum above ~25000 means large statements risk the 30-second cutoff.

---

## Demo recordings (after this ships)
The demo build now needs a pass, like a customer. Mint one for a week:
```powershell
.\mint_pass.ps1 -Id demo_2026_09 -MaxDownloads 50 -WindowHours 168
```
The demo page must send it: apply the same one-line `checkout_id: _checkoutId` change to
`demo/converter_demo.html` and set `_checkoutId='demo_2026_09'` in its DEMO block.
The pass expires by itself; only someone with your AWS credentials can mint one.

## Tuning
`MAX_DOWNLOADS_PER_PAYMENT` and `DOWNLOAD_WINDOW_HOURS` live in `lambda.tf`. Stricter = `1` / `2`.
Change, plan, apply - no code change needed.
