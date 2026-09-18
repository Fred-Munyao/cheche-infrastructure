# ============================================================
#  prepare_state_recovery.ps1
#  Run ONCE from D:\Backed_up\Cheche\cheche-infrastructure
#  after copying backend.tf, imports.tf, lambda.tf into the repo.
#  - creates the Terraform state bucket (versioned, private)
#  - builds the two Lambda zips Terraform expects
#  - makes two surgical edits to payments.tf
#  - updates .gitignore
#  Changes NOTHING in the live application.
# ============================================================
$ErrorActionPreference = 'Stop'
if (-not (Test-Path .\payments.tf) -or -not (Test-Path .\imports.tf)) {
  Write-Host "Run this from the cheche-infrastructure repo, after copying the new .tf files in." -ForegroundColor Red; exit 1 }

$bucket = 'cheche-tf-state-507629158424'

# 1. Backups of files we edit
New-Item -ItemType Directory -Force .\_pre_import_backup | Out-Null
Copy-Item .\payments.tf .\_pre_import_backup\payments.tf -Force
git show HEAD:lambda.tf | Out-File .\_pre_import_backup\lambda.tf.original -Encoding utf8
Write-Host "[1] Backups saved to _pre_import_backup\" -ForegroundColor Green

# 2. State bucket
$exists = $true
try { aws s3api head-bucket --bucket $bucket 2>$null; if ($LASTEXITCODE -ne 0) { $exists = $false } } catch { $exists = $false }
if (-not $exists) {
  aws s3api create-bucket --bucket $bucket --region us-east-1 | Out-Null
  aws s3api put-bucket-versioning --bucket $bucket --versioning-configuration Status=Enabled
  aws s3api put-public-access-block --bucket $bucket --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  Write-Host "[2] Created state bucket $bucket (versioned, private, SSE-S3 by default)" -ForegroundColor Green
} else { Write-Host "[2] State bucket $bucket already exists" -ForegroundColor Yellow }

# 3a. Formatter zip = exactly what is live (Terraform re-uploads it; no code change)
$url = aws lambda get-function --function-name cheche-excel-formatter --query 'Code.Location' --output text
Invoke-WebRequest -Uri $url -OutFile .\lambda_function.zip -UseBasicParsing
Write-Host "[3a] lambda_function.zip = live formatter code ($([math]::Round((Get-Item .\lambda_function.zip).Length/1MB,1)) MB)" -ForegroundColor Green

# 3b. Callback zip = the NEW code from the repo (analytics + server-side pricing)
$tmp = Join-Path $env:TEMP 'cheche_cb_build'; New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item .\cheche_callback_lambda.py "$tmp\lambda_function.py" -Force
Compress-Archive -Path "$tmp\lambda_function.py" -DestinationPath .\cheche_callback.zip -Force
Write-Host "[3b] cheche_callback.zip built from cheche_callback_lambda.py (as lambda_function.py)" -ForegroundColor Green

# 4. Surgical edits to payments.tf
$p = [IO.File]::ReadAllText((Resolve-Path .\payments.tf))
$orig = $p
# 4a. permission statement id -> match live, so it's imported instead of replaced
$p = $p -replace 'statement_id\s*=\s*"AllowPaymentsAPIGatewayInvoke"', 'statement_id  = "apigateway-invoke"'
# 4b. redeploy trigger so /track actually goes live on the prod stage
if ($p -notmatch 'resource\s+"aws_api_gateway_deployment"\s+"payments_prod"\s*\{[^}]*triggers') {
  $trig = "`r`n`r`n  triggers = {`r`n    redeployment = sha1(jsonencode([`r`n      aws_api_gateway_integration.stkpush_post.id,`r`n      aws_api_gateway_integration.callback_post.id,`r`n      aws_api_gateway_integration.status_get.id,`r`n      aws_api_gateway_resource.track.id,`r`n      aws_api_gateway_method.track_post.id,`r`n      aws_api_gateway_integration.track_post.id,`r`n      aws_api_gateway_method.track_options.id,`r`n      aws_api_gateway_integration.track_options.id,`r`n    ]))`r`n  }"
  $p = $p -replace '(resource\s+"aws_api_gateway_deployment"\s+"payments_prod"\s*\{\s*\r?\n\s*rest_api_id\s*=\s*aws_api_gateway_rest_api\.payments_api\.id)', ('$1' + $trig)
}
[IO.File]::WriteAllText((Resolve-Path .\payments.tf), $p)
$okId  = Select-String -Path .\payments.tf -Pattern '"apigateway-invoke"' -Quiet
$okTrg = Select-String -Path .\payments.tf -Pattern 'redeployment = sha1' -Quiet
Write-Host ("[4] payments.tf  statement_id fixed: {0}   deployment trigger added: {1}" -f $okId, $okTrg) -ForegroundColor $(if ($okId -and $okTrg) {'Green'} else {'Red'})
if (-not ($okId -and $okTrg)) { Write-Host "    One edit did not apply - paste payments.tf so it can be fixed by hand." -ForegroundColor Red }

# 5. .gitignore
$ignore = @('*.zip', '.terraform/', '*.tfstate', '*.tfstate.*', '*.tfplan', 'plan.txt', 'import_ids.txt', 'v2_ids.txt', '_pre_import_backup/')
$current = if (Test-Path .\.gitignore) { Get-Content .\.gitignore } else { @() }
$ignore | Where-Object { $current -notcontains $_ } | Add-Content .\.gitignore
Write-Host "[5] .gitignore updated" -ForegroundColor Green

Write-Host "`nPreparation complete. Continue with RUNBOOK step 2." -ForegroundColor Cyan
