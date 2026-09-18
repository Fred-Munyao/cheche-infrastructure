# Cheche — Go-Live Runbook (Paybill day)

Order matters. Lambda code + config via CLI **before** `terraform apply`, and `plan` must show
`cheche-payments` as **update in-place**, never destroy/create.

## 0. Prereqs
- Paybill shortcode in hand
- Daraja Go Live completed at developer.safaricom.co.ke → production consumer key, secret, passkey
- Repo `cheche-infrastructure` pulled; drop in `analytics.tf`, replace `payments.tf`, merge `variables_snippet.tf` into `variables.tf`
- Add to `.gitignore`: `terraform.tfvars`, `*.zip`

## 1. Lambda — code, handler, env (CLI first)
```powershell
cd D:\Cheche\lambda-callback
Compress-Archive -Path cheche_callback_lambda.py -DestinationPath cheche_callback.zip -Force

aws lambda update-function-code --function-name cheche-payment-callback --zip-file fileb://cheche_callback.zip
aws lambda wait function-updated --function-name cheche-payment-callback

aws lambda update-function-configuration --function-name cheche-payment-callback `
  --handler cheche_callback_lambda.lambda_handler `
  --environment "Variables={DARAJA_CONSUMER_KEY=<prod_key>,DARAJA_CONSUMER_SECRET=<prod_secret>,DARAJA_SHORTCODE=<paybill>,DARAJA_PASSKEY=<prod_passkey>,DARAJA_ENV=production,DARAJA_CALLBACK_URL=https://jkv6ay89l0.execute-api.us-east-1.amazonaws.com/prod/callback,PAYMENTS_TABLE=cheche-payments,ANALYTICS_TABLE=cheche-analytics}"
aws lambda wait function-updated --function-name cheche-payment-callback
```
Smoke test credentials (expects `"env": "production"` and a token prefix):
```powershell
curl https://jkv6ay89l0.execute-api.us-east-1.amazonaws.com/prod/token
```
Note: `/track` will return `ok:false` until step 2 creates the analytics table — expected.

## 2. Terraform — tables, GSI, TTL, scoped IAM, /track route
Copy the same `cheche_callback.zip` into the Terraform module folder, then:
```powershell
terraform fmt
terraform validate
terraform plan -out=golive.tfplan
```
**Check the plan before applying:**
- `aws_dynamodb_table.cheche_payments` → `~ update in-place` (GSI + TTL). If it says `-/+` or `destroy`, STOP.
- `aws_dynamodb_table.cheche_analytics` → create
- `aws_iam_role_policy_attachment.lambda_dynamodb` → destroy (FullAccess going away)
- `aws_iam_role_policy.lambda_dynamodb` → create
- `aws_api_gateway_*track*` → create; `aws_api_gateway_deployment.payments_prod` → replace (create_before_destroy)
```powershell
terraform apply golive.tfplan
```
Verify `/track` now works (expects `{"ok":true}`):
```powershell
curl -X POST https://jkv6ay89l0.execute-api.us-east-1.amazonaws.com/prod/track -H "Content-Type: text/plain" -d "{\"client_id\":\"runbooktest01\",\"event\":\"page_view\"}"
```

## 3. Real-phone payment test (paywall still off)
From the browser console on chechetech.co.ke/converter.html:
```js
fetch('https://jkv6ay89l0.execute-api.us-east-1.amazonaws.com/prod/stkpush',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({phone:'2547XXXXXXXX',plan:'payg',client_id:'runbooktest01'})}).then(r=>r.json()).then(console.log)
```
Expect STK prompt for **KES 299**. Approve, then poll:
```powershell
aws dynamodb get-item --table-name cheche-payments --key "{\"checkout_request_id\":{\"S\":\"<CheckoutRequestID>\"}}"
```
Expect `status: PAID`, `mpesa_receipt` set, **no `ttl` attribute**. Also confirm a rejected plan is refused:
`plan:'pro'` → 400 "This plan is not available yet".

## 4. Frontend — paywall on, deploy all four pages
In `site\converter.html` replace
```js
function _hasUsedFree(){ return false; /* PAYWALL DISABLED FOR TESTING */ }
```
with
```js
function _hasUsedFree(){ try{ return localStorage.getItem(CHECHE_KEY)==='true'; }catch(e){ return false; } }
```
```powershell
cd D:\Cheche\site
foreach ($f in "index.html","converter.html","terms.html","privacy.html") {
  aws s3 cp $f s3://cheche-converter-app-dev/$f --content-type "text/html" --endpoint-url https://s3.amazonaws.com
}
aws cloudfront create-invalidation --distribution-id EYD38S1N9UN3R --paths "/index.html" "/converter.html" "/terms.html" "/privacy.html"
```

## 5. End-to-end as a customer
Fresh browser profile → convert (free) → download workbook → convert again → paywall → pay 299 → conversion runs → download.
Then confirm in `cheche-analytics` (event-index) that `page_view`, `convert_start`, `convert_success`, `download_success`, `paywall_shown`, `stk_initiated` all landed with the same `client_id`, and that the PAID record in `cheche-payments` carries that `client_id`.

## 6. Commit
```powershell
git add analytics.tf payments.tf variables.tf cheche_callback_lambda.py
git commit -m "feat: analytics table + /track, phone GSI, per-item TTL, scoped IAM, server-side pricing, prod Daraja"
```
Separate commit in `cheche-converter` for the four HTML files.

## Useful queries afterwards
All payments from one MSISDN:
```powershell
aws dynamodb query --table-name cheche-payments --index-name phone-index --key-condition-expression "phone = :p" --expression-attribute-values "{\":p\":{\"S\":\"2547XXXXXXXX\"}}" --scan-index-forward false
```
Conversions today (epoch ms since midnight EAT):
```powershell
aws dynamodb query --table-name cheche-analytics --index-name event-index --key-condition-expression "event = :e AND ts > :t" --expression-attribute-values "{\":e\":{\"S\":\"convert_success\"},\":t\":{\"N\":\"<epoch_ms>\"}}" --select COUNT
```
