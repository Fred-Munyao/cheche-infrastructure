# collect_import_ids.ps1 — READ-ONLY. Gathers what's needed to write imports.tf.
# Run from D:\Backed_up\Cheche\cheche-infrastructure :  .\collect_import_ids.ps1
# Output: import_ids.txt in the same folder. Contains NO secrets.

$out = '.\import_ids.txt'
Remove-Item $out -ErrorAction SilentlyContinue
function W($t) { $t | Out-String -Width 300 | Add-Content $out }

W '=== 1. RESOURCE ADDRESSES IN REPO ==='
Get-ChildItem *.tf | ForEach-Object {
  $f = $_.Name
  Select-String -Path $_.FullName -Pattern '^\s*(resource|data)\s+"(\S+)"\s+"(\S+)"' | ForEach-Object {
    "{0,-18} {1}.{2}" -f $f, $_.Matches[0].Groups[2].Value, $_.Matches[0].Groups[3].Value
  }
} | ForEach-Object { W $_ }

W '=== 2. PROVIDER / MAIN.TF ==='
W (Get-Content .\main.tf -ErrorAction SilentlyContinue)

W '=== 3. API GATEWAYS (all REST APIs in account) ==='
W (aws apigateway get-rest-apis --query "items[].[id,name,createdDate]" --output text)
$apiIds = (aws apigateway get-rest-apis --query "items[].id" --output text) -split '\s+' | Where-Object { $_ }
foreach ($api in $apiIds) {
  W "--- $api resources [id path] ---";  W (aws apigateway get-resources  --rest-api-id $api --query "items[].[id,path]" --output text)
  W "--- $api methods [path methods] ---"; W (aws apigateway get-resources --rest-api-id $api --query "items[?resourceMethods].[path, join(',', keys(resourceMethods))]" --output text)
  W "--- $api deployments ---"; W (aws apigateway get-deployments --rest-api-id $api --query "items[].[id,createdDate]" --output text)
  W "--- $api stages ---";      W (aws apigateway get-stages      --rest-api-id $api --query "item[].[stageName,deploymentId]" --output text)
}
W '--- HTTP APIs (v2) ---'
W (aws apigatewayv2 get-apis --query "Items[].[ApiId,Name,ProtocolType]" --output text)

W '=== 3b. API URLS CALLED BY THE LIVE SITE ==='
aws s3 cp s3://cheche-converter-app-dev/converter.html "$env:TEMP\live_conv.html" --endpoint-url https://s3.amazonaws.com --only-show-errors
Select-String -Path "$env:TEMP\live_conv.html" -Pattern 'https://[a-z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com/[A-Za-z0-9/_-]*' -AllMatches |
  ForEach-Object { $_.Matches.Value } | Sort-Object -Unique | ForEach-Object { W $_ }

W '=== 4. CLOUDFRONT ==='
W (aws cloudfront get-distribution --id EYD38S1N9UN3R --query "Distribution.DistributionConfig.[Aliases.Items, ViewerCertificate.ACMCertificateArn, Origins.Items[].[Id,DomainName,OriginAccessControlId]]" --output text)
W '--- OACs ---'
W (aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[].[Id,Name]" --output text)

W '=== 5. ACM (us-east-1) ==='
W (aws acm list-certificates --region us-east-1 --query "CertificateSummaryList[].[DomainName,CertificateArn,Status]" --output text)

W '=== 6. S3 BUCKETS ==='
W (aws s3api list-buckets --query "Buckets[].Name" --output text)

W '=== 7. BUDGETS ==='
W (aws budgets describe-budgets --account-id 507629158424 --query "Budgets[].BudgetName" --output text)

W '=== 8. IAM ROLE ATTACHMENTS ==='
W (aws iam list-attached-role-policies --role-name cheche-lambda-role --query "AttachedPolicies[].PolicyArn" --output text)
W (aws iam list-role-policies --role-name cheche-lambda-role --query "PolicyNames" --output text)

W '=== 9. LAMBDA PERMISSIONS (statement ids) ==='
foreach ($fn in 'cheche-excel-formatter','cheche-payment-callback') {
  W "--- $fn ---"
  W (aws lambda get-policy --function-name $fn --query Policy --output text 2>$null)
}

Write-Host "Done. Open import_ids.txt and paste its contents." -ForegroundColor Green
