# ============================================================
#  mint_pass.ps1  -  create a payment record by hand (admin only, needs AWS creds)
#  Uses:
#   - demo pass for video recordings:  .\mint_pass.ps1 -Id demo_2026_09 -MaxDownloads 50 -WindowHours 168
#   - gate tests:                       .\mint_pass.ps1 -Id test_gate_used -MaxDownloads 1 -DownloadCount 1
#                                       .\mint_pass.ps1 -Id test_gate_pending -Status PENDING
#  Every minted record carries a ttl, so DynamoDB deletes it automatically after the window.
#  Never overwrites an existing record (real payments are safe).
# ============================================================
param(
  [Parameter(Mandatory)][ValidatePattern('^(demo|test)_[A-Za-z0-9_-]{3,60}$')][string]$Id,
  [int]$MaxDownloads = 3,
  [int]$WindowHours = 24,
  [int]$DownloadCount = 0,
  [ValidateSet('PAID','PENDING','FAILED')][string]$Status = 'PAID'
)
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$item = @{
  checkout_request_id = @{ S = $Id }
  status              = @{ S = $Status }
  plan                = @{ S = $(if ($Id -like 'demo_*') { 'demo' } else { 'test' }) }
  phone               = @{ S = '254000000000' }
  amount              = @{ N = '0' }
  created_at          = @{ N = "$now" }
  max_downloads       = @{ N = "$MaxDownloads" }
  window_hours        = @{ N = "$WindowHours" }
  download_count      = @{ N = "$DownloadCount" }
  ttl                 = @{ N = "$($now + $WindowHours * 3600 + 86400)" }
}
if ($Status -eq 'PAID') { $item.paid_at = @{ N = "$now" } }
$file = Join-Path $env:TEMP "mint_$Id.json"
$item | ConvertTo-Json -Depth 5 | Set-Content $file -Encoding ascii
aws dynamodb put-item --table-name cheche-payments --item "file://$file" --condition-expression "attribute_not_exists(checkout_request_id)"
if ($LASTEXITCODE -eq 0) { Write-Host "Minted $Id  status=$Status  max=$MaxDownloads  window=${WindowHours}h  used=$DownloadCount" -ForegroundColor Green }
Remove-Item $file -Force
