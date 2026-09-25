<#
.SYNOPSIS
    Exports Cheche M-Pesa payments from DynamoDB to a CSV for Excel.

.DESCRIPTION
    Reads the cheche-payments table and writes one row per payment with readable
    Nairobi-time dates. By default it exports real sales only: PAID records,
    with sandbox test records excluded. Prints a summary (count and total) when done.

.EXAMPLE
    .\Export-ChechePayments.ps1
    All real sales to date.

.EXAMPLE
    .\Export-ChechePayments.ps1 -Month 2026-10
    Real sales for October 2026 (for monthly reconciliation / KRA records).

.EXAMPLE
    .\Export-ChechePayments.ps1 -From 2026-10-01 -To 2026-10-15 -Status ALL
    Every attempt (paid, failed, pending) in the first half of October.

.EXAMPLE
    .\Export-ChechePayments.ps1 -Status FAILED -IncludeSandbox
    All failed attempts, including pre-go-live tests.
#>
[CmdletBinding()]
param(
    [string]$Month,                                   # yyyy-MM, e.g. 2026-10
    [datetime]$From,                                  # inclusive, Nairobi time
    [datetime]$To,                                    # inclusive (whole day), Nairobi time
    [ValidateSet('PAID', 'FAILED', 'PENDING', 'ALL')]
    [string]$Status = 'PAID',
    [switch]$IncludeSandbox,
    [string]$OutFile,
    [string]$Table  = 'cheche-payments',
    [string]$Region = 'us-east-1'
)

$ErrorActionPreference = 'Stop'
$EAT = [TimeSpan]::FromHours(3)

# ── Date range ──
if ($Month) {
    $From = [datetime]::ParseExact($Month, 'yyyy-MM', $null)
    $To   = $From.AddMonths(1).AddDays(-1)
}
$fromUtc = $null; $toUtc = $null
if ($From) { $fromUtc = [DateTimeOffset]::new($From.Date, $EAT).ToUnixTimeSeconds() }
if ($To)   { $toUtc   = [DateTimeOffset]::new($To.Date.AddDays(1), $EAT).ToUnixTimeSeconds() - 1 }

if (-not $OutFile) {
    $label = if ($Month) { $Month } elseif ($From -or $To) { 'range' } else { 'all' }
    $OutFile = Join-Path (Get-Location) ("cheche-payments_{0}_{1}_{2}.csv" -f $label, $Status.ToLower(), (Get-Date -Format 'yyyyMMdd-HHmm'))
}

# ── Helpers ──
function Get-Attr($item, [string]$name) {
    $a = $item.PSObject.Properties[$name]
    if (-not $a) { return $null }
    $v = $a.Value
    if ($v.PSObject.Properties['S']) { return [string]$v.S }
    if ($v.PSObject.Properties['N']) { return [decimal]$v.N }
    if ($v.PSObject.Properties['BOOL']) { return [bool]$v.BOOL }
    return $null
}
function Format-EAT($epoch) {
    if ($null -eq $epoch -or $epoch -eq '') { return '' }
    return [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch).ToOffset($EAT).ToString('yyyy-MM-dd HH:mm:ss')
}
function Format-Phone([string]$p) {
    # +254 722 117 885 stays as text in Excel (plain 254722117885 turns into 2.54E+11)
    if ($p -match '^254(\d{3})(\d{3})(\d{3})$') { return "+254 $($Matches[1]) $($Matches[2]) $($Matches[3])" }
    return $p
}

# ── Fetch (the CLI follows pagination automatically) ──
Write-Host "Reading $Table ..." -ForegroundColor Cyan
$json = aws dynamodb scan --table-name $Table --region $Region --output json | Out-String
if ($LASTEXITCODE -ne 0) { throw "aws dynamodb scan failed (exit $LASTEXITCODE). Check your AWS credentials." }
$items = ($json | ConvertFrom-Json).Items

# ── Shape + filter ──
$rows = foreach ($it in $items) {
    $st      = Get-Attr $it 'status'
    $env     = Get-Attr $it 'environment'
    $created = Get-Attr $it 'created_at'
    $paid    = Get-Attr $it 'paid_at'
    $when    = if ($paid) { $paid } else { $created }     # sales are dated by payment time

    if ($Status -ne 'ALL' -and $st -ne $Status) { continue }
    if (-not $IncludeSandbox -and $env -eq 'sandbox') { continue }
    if ($fromUtc -and $when -lt $fromUtc) { continue }
    if ($toUtc   -and $when -gt $toUtc)   { continue }

    $amountPaid = Get-Attr $it 'amount_paid'
    [pscustomobject][ordered]@{
        'Date (EAT)'        = Format-EAT $when
        'Status'            = $st
        'M-Pesa Receipt'    = Get-Attr $it 'mpesa_receipt'
        'Amount (KES)'      = Get-Attr $it 'amount'
        'Amount Paid (KES)' = $amountPaid
        'Plan'              = Get-Attr $it 'plan'
        'Phone'             = Format-Phone (Get-Attr $it 'phone')
        'Confirmed Via'     = Get-Attr $it 'confirmed_via'
        'Consent Version'   = Get-Attr $it 'consent_version'
        'Fail Reason'       = Get-Attr $it 'fail_reason'
        'Environment'       = if ($env) { $env } else { 'production' }
        'Created (EAT)'     = Format-EAT $created
        'Checkout ID'       = Get-Attr $it 'checkout_request_id'
        '_sort'             = [long]$when
    }
}

$rows = @($rows | Sort-Object _sort | Select-Object * -ExcludeProperty _sort)

if ($rows.Count -eq 0) {
    Write-Host "No payments match those filters." -ForegroundColor Yellow
    return
}

$rows | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8

# ── Summary ──
$paidRows = @($rows | Where-Object { $_.Status -eq 'PAID' })
$total    = ($paidRows | Measure-Object -Property 'Amount Paid (KES)' -Sum).Sum
if (-not $total) { $total = 0 }
$noReceipt = @($paidRows | Where-Object { -not $_.'M-Pesa Receipt' }).Count

Write-Host ""
Write-Host ("Exported {0} record(s) to {1}" -f $rows.Count, $OutFile) -ForegroundColor Green
Write-Host ("  Paid: {0}   Total received: KES {1:N0}" -f $paidRows.Count, $total)
if ($Status -eq 'ALL') {
    $failed  = @($rows | Where-Object { $_.Status -eq 'FAILED' }).Count
    $pending = @($rows | Where-Object { $_.Status -eq 'PENDING' }).Count
    Write-Host ("  Failed: {0}   Pending: {1}" -f $failed, $pending)
}
if ($noReceipt -gt 0) {
    Write-Host ("  Note: {0} paid record(s) have no receipt yet (confirmed by STK query; the callback normally fills it in)." -f $noReceipt) -ForegroundColor Yellow
}
