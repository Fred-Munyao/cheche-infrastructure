# Cheche — Terraform State Recovery & Analytics Deploy Runbook

**Goal:** bring every live Cheche resource back under Terraform (import, not recreate), move state to a
versioned S3 backend, then ship the pending analytics / server-side-pricing release.
**Folder:** `D:\Backed_up\Cheche\cheche-infrastructure`  ·  **Account:** 507629158424  ·  **Region:** us-east-1

> Run every command from a single PowerShell window. Paste one line at a time (Ctrl+V) — multi-line pastes
> have been reversing in this console.

---

## 0. Put the new files in the repo

Copy into `cheche-infrastructure`, replacing when asked:
`backend.tf` (new) · `imports.tf` (new) · `lambda.tf` (replaces old) · `prepare_state_recovery.ps1` (new)

The new `lambda.tf` models the formatter as the **HTTP API it actually is** (v2). The old REST-API blocks
never existed in AWS, so removing them destroys nothing.

## 1. Prepare (state bucket, zips, payments.tf edits, .gitignore)

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; Unblock-File .\prepare_state_recovery.ps1; .\prepare_state_recovery.ps1
```

All five steps should print green. If step 4 prints red, stop and paste `payments.tf`.

## 2. Ship the new callback code first (runbook rule: code before apply)

```powershell
aws lambda update-function-code --function-name cheche-payment-callback --zip-file fileb://cheche_callback.zip --query "[LastModified,CodeSize]" --output text
```
```powershell
aws lambda wait function-updated --function-name cheche-payment-callback
```

Safe while in sandbox: `/stkpush`, `/status`, `/callback` keep working; `/track` still 404s until step 6.
Quick health check — should return **404 `Payment not found`** (JSON), which proves the Lambda runs:

```powershell
try { Invoke-RestMethod "https://jkv6ay89l0.execute-api.us-east-1.amazonaws.com/prod/status?id=healthcheck" } catch { $_.ErrorDetails.Message }
```

## 3. Load Daraja values from the live Lambda (session only, never written to disk)

```powershell
$v = aws lambda get-function-configuration --function-name cheche-payment-callback --query "Environment.Variables" --output json | ConvertFrom-Json; $env:TF_VAR_daraja_consumer_key = $v.DARAJA_CONSUMER_KEY; $env:TF_VAR_daraja_consumer_secret = $v.DARAJA_CONSUMER_SECRET; $env:TF_VAR_daraja_shortcode = $v.DARAJA_SHORTCODE; $env:TF_VAR_daraja_passkey = $v.DARAJA_PASSKEY; $env:TF_VAR_daraja_env = $v.DARAJA_ENV
```

## 4. Initialise and validate

```powershell
terraform init
```
```powershell
terraform validate
```

`init` should say *Successfully configured the backend "s3"*. `validate` must say *Success*.

## 5. Plan — and read it before anything else

```powershell
terraform plan -out cheche.tfplan -no-color | Tee-Object -FilePath plan.txt
```

### What a SAFE plan looks like

| Line | Expected |
|---|---|
| Summary | **Plan: 35 to import, ~8 to add, N to change, 1 to destroy** |
| to add (8) | `aws_iam_role_policy.lambda_dynamodb`, `aws_dynamodb_table.cheche_analytics`, 5 × `/track` pieces, 1 new `aws_api_gateway_deployment.payments_prod` |
| to destroy (1) | only the **old** `aws_api_gateway_deployment.payments_prod` (23u4ov), replaced *after* the new one exists |
| to change | tags, Lambda `filename`/env vars, TTL on `cheche-payments`, CORS/stage details — all `~ update in-place` |

A budget replacement (1 more add + 1 more destroy on `aws_budgets_budget.monthly_limit`) is also
acceptable — it only means the name in `budget.tf` differs from the live `cheche-monthly-budget`.

### STOP and paste plan.txt if you see any of these
- `must be replaced` / `-/+` on: `cheche-payments`, the S3 bucket, CloudFront, either Lambda, `payments_api`, `formatter_api`
- `+ create` for anything that already exists (bucket, distribution, table, Lambdas, APIs)
- any destroy other than the payments deployment (and the budget case above)
- `Error:` of any kind

## 6. Apply the reviewed plan

```powershell
terraform apply cheche.tfplan
```

Applying a saved plan runs exactly what you reviewed — nothing more.

## 7. Verify

```powershell
terraform plan
```
Must end with **No changes. Your infrastructure matches the configuration.**

```powershell
aws apigateway get-resources --rest-api-id jkv6ay89l0 --query "items[].path" --output text
```
Should now include `/track`.

```powershell
try { Invoke-RestMethod -Method Post -Uri "https://jkv6ay89l0.execute-api.us-east-1.amazonaws.com/prod/track" -ContentType "application/json" -Body '{"client_id":"runbook_check_01","event":"page_view"}' } catch { $_.ErrorDetails.Message }
```
```powershell
aws dynamodb scan --table-name cheche-analytics --select COUNT --query Count
```
Count should be ≥ 1. Then open chechetech.co.ke, run one conversion and one formatted download
to confirm the formatter API and site are untouched.

## 8. Least privilege — remove DynamoDB FullAccess

First confirm the new scoped policy covers both tables:
```powershell
aws iam get-role-policy --role-name cheche-lambda-role --policy-name (aws iam list-role-policies --role-name cheche-lambda-role --query "PolicyNames[0]" --output text) --query "PolicyDocument.Statement[].Resource"
```
Both `cheche-payments` and `cheche-analytics` ARNs must appear. Then:
```powershell
aws iam detach-role-policy --role-name cheche-lambda-role --policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess
```
Re-run the `/status` health check (step 2) and the `/track` test (step 7). Both must still work.
FullAccess was never in Terraform, so `terraform plan` stays clean.

## 9. Commit

```powershell
git add backend.tf imports.tf lambda.tf payments.tf .gitignore prepare_state_recovery.ps1 RUNBOOK_state_recovery.md
```
```powershell
git commit -m "infra: recover lost state via import, S3 backend, formatter as HTTP API, deploy analytics + /track, drop DynamoDBFullAccess"
```
```powershell
git push
```

Zips, plan files and state are git-ignored. Optionally delete `imports.tf` in a follow-up commit.

## 10. Snapshot

Run `cheche_snapshot.ps1` — it now captures a fully reconciled estate.

---

### Notes worth knowing
- **Formatter timeout:** the HTTP API has a hard **30-second** integration limit, while the Lambda allows 120 s.
  A formatting call that runs past 30 s returns 503 to the browser even if the Lambda finishes. Track formatter
  duration in CloudWatch; if large statements approach 30 s, the fix is async (S3 upload + poll), not a setting.
- **Formatter source:** the Python for `cheche-excel-formatter` is still not in the repo (only the live zip).
  Next small task: extract it into `lambda/excel-formatter/` with a `requirements.txt` (openpyxl, Pillow).
- **State is now safe:** versioned S3 bucket = every apply is recoverable. Never delete `cheche-tf-state-507629158424`.
- **Go-live later:** production Daraja values are supplied through the same `TF_VAR_` variables, then `plan` → `apply`.
