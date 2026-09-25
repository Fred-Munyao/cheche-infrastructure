<#
.SYNOPSIS
    Cheche funnel report: who visited, how far they got, where they dropped off, and who paid.

.DESCRIPTION
    Reads the anonymous events in cheche-analytics plus the payments in cheche-payments,
    and prints the full picture for a date range:
      - Funnel by unique visitor: visited -> uploaded -> converted -> paywall -> STK -> paid -> downloaded
      - Drop-off at every step, overall conversion, revenue
      - Failures (conversion and download) with reasons
      - Devices, traffic sources, statement sizes, and visitors per day
    Optionally writes one row per visitor to a CSV.

    Your own testing is excluded automatically: sandbox payment records, and any visitor linked
    to a phone passed in -ExcludePhone (use your own number). Use -IncludeTestTraffic to see everything.

.EXAMPLE
    .\Get-ChecheFunnel.ps1 -ExcludePhone 254722117885
    Last 30 days, your own traffic excluded.

.EXAMPLE
    .\Get-ChecheFunnel.ps1 -Month 2026-10 -ExcludePhone 254722117885 -OutFile .\funnel-oct.csv
    October, with a per-visitor CSV.

.EXAMPLE
    .\Get-ChecheFunnel.ps1 -Days 7
    Last 7 days.
#>
[CmdletBinding()]
param(
    [int]$Days = 30,
    [string]$Month,                        # yyyy-MM (overrides -Days)
    [datetime]$From,                       # Nairobi time (overrides -Days)
    [datetime]$To,
    [string[]]$ExcludePhone = @(),         # e.g. your own 2547XXXXXXXX
    [string[]]$ExcludeClient = @(),        # specific anonymous client_ids to ignore
    [switch]$IncludeTestTraffic,
    [string]$OutFile,
    [string]$Region = 'us-east-1'
)

$ErrorActionPreference = 'Stop'
$EAT = [TimeSpan]::FromHours(3)

# ── Date range (EAT) → epoch seconds ──
$nowEat = [DateTimeOffset]::UtcNow.ToOffset($EAT)
if ($Month) {
    $From = [datetime]::ParseExact($Month, 'yyyy-MM', $null)
    $To   = $From.AddMonths(1).AddDays(-1)
} elseif (-not $From -and -not $To) {
    $To   = $nowEat.Date
    $From = $To.AddDays(-($Days - 1))
}
if (-not $From) { $From = [datetime]'2026-01-01' }
if (-not $To)   { $To   = $nowEat.Date }
$fromS = [DateTimeOffset]::new($From.Date, $EAT).ToUnixTimeSeconds()
$toS   = [DateTimeOffset]::new($To.Date.AddDays(1), $EAT).ToUnixTimeSeconds() - 1

# ── Helpers ──
function A($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]; if (-not $p) { return $null }
    $v = $p.Value
    if ($v.PSObject.Properties['S'])    { return [string]$v.S }
    if ($v.PSObject.Properties['N'])    { return [decimal]$v.N }
    if ($v.PSObject.Properties['BOOL']) { return [bool]$v.BOOL }
    if ($v.PSObject.Properties['M'])    { return $v.M }
    return $null
}
function DayOf([long]$epochS) { [DateTimeOffset]::FromUnixTimeSeconds($epochS).ToOffset($EAT).ToString('yyyy-MM-dd') }
function WhenOf([long]$epochS) { [DateTimeOffset]::FromUnixTimeSeconds($epochS).ToOffset($EAT).ToString('yyyy-MM-dd HH:mm') }
function Pct($n, $d) { if (-not $d) { return '   -' }; return ('{0,4:N0}%' -f (100.0 * $n / $d)) }
function Median($vals) {
    $s = @($vals | Where-Object { $_ -ne $null } | Sort-Object)
    if ($s.Count -eq 0) { return $null }
    if ($s.Count % 2) { return $s[[int][math]::Floor($s.Count / 2)] }
    return ($s[$s.Count / 2 - 1] + $s[$s.Count / 2]) / 2
}
function Scan([string]$table) {
    $json = aws dynamodb scan --table-name $table --region $Region --output json | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Scan of $table failed (exit $LASTEXITCODE). Check AWS credentials." }
    return @(($json | ConvertFrom-Json).Items)
}
function Section([string]$t) { Write-Host ""; Write-Host $t -ForegroundColor Cyan; Write-Host ('-' * $t.Length) -ForegroundColor DarkGray }

Write-Host ("Cheche funnel report  |  {0:yyyy-MM-dd} to {1:yyyy-MM-dd} (Nairobi time)" -f $From, $To) -ForegroundColor Green
Write-Host "Reading cheche-analytics and cheche-payments ..." -ForegroundColor DarkGray

# ── Payments ──
$payments = foreach ($p in (Scan 'cheche-payments')) {
    [pscustomobject]@{
        Id      = A $p 'checkout_request_id'
        Status  = A $p 'status'
        Client  = A $p 'client_id'
        Phone   = A $p 'phone'
        Env     = A $p 'environment'
        Amount  = A $p 'amount_paid'
        Created = A $p 'created_at'
        Paid    = A $p 'paid_at'
    }
}

# ── Test-traffic exclusion ──
$excluded = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($c in $ExcludeClient) { [void]$excluded.Add($c) }
if (-not $IncludeTestTraffic) {
    foreach ($p in $payments) {
        if ($p.Client -and ($p.Env -eq 'sandbox' -or $ExcludePhone -contains $p.Phone)) { [void]$excluded.Add($p.Client) }
    }
}
function IsTestPayment($p) {
    if ($IncludeTestTraffic) { return $false }
    return ($p.Env -eq 'sandbox' -or ($ExcludePhone -contains $p.Phone) -or ($p.Client -and $excluded.Contains($p.Client)))
}

# ── Analytics events in range ──
$events = foreach ($e in (Scan 'cheche-analytics')) {
    $client = A $e 'client_id'
    $ts = [long]((A $e 'ts') / 1000)
    if ($ts -lt $fromS -or $ts -gt $toS) { continue }
    if ($excluded.Contains($client)) { continue }
    $meta = A $e 'meta'
    [pscustomobject]@{
        Client = $client; Event = A $e 'event'; Ts = $ts; Device = A $e 'device'
        Ref    = A $meta 'ref';    Utm = A $meta 'utm_source'; Campaign = A $meta 'utm_campaign'
        Txns   = A $meta 'txns';   Months = A $meta 'months'; FileKb = A $meta 'file_kb'
        Method = A $meta 'method'; Reason = A $meta 'reason'
    }
}
$events = @($events)

# ── Paid payments in range (production, non-test) ──
$paidInRange = @($payments | Where-Object {
    $_.Status -eq 'PAID' -and -not (IsTestPayment $_) -and $_.Paid -ge $fromS -and $_.Paid -le $toS })
$stkInRange = @($payments | Where-Object {
    -not (IsTestPayment $_) -and $_.Created -ge $fromS -and $_.Created -le $toS })

# ── Per-visitor view ──
$byClient = $events | Group-Object Client
$paidClients = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($p in $paidInRange) { if ($p.Client) { [void]$paidClients.Add($p.Client) } }

$visitors = foreach ($g in $byClient) {
    $ev = @($g.Group | Sort-Object Ts)
    $names = $ev.Event
    $first = $ev[0]
    $src = ($ev | Where-Object { $_.Utm -or $_.Ref } | Select-Object -First 1)
    $source = 'direct / unknown'
    if ($src) { if ($src.Utm) { $source = $src.Utm } else { $source = $src.Ref } }
    $conv = $ev | Where-Object { $_.Event -eq 'convert_success' } | Select-Object -First 1
    $myPaid = @($paidInRange | Where-Object { $_.Client -eq $g.Name })
    [pscustomobject][ordered]@{
        'Visitor'          = $g.Name
        'First Seen (EAT)' = WhenOf $first.Ts
        'Last Seen (EAT)'  = WhenOf $ev[-1].Ts
        'Device'           = $first.Device
        'Source'           = $source
        'Visited'          = $true                     # any recorded activity means they reached the converter
        'Uploaded'         = [bool]($names -contains 'convert_start')
        'Converted'        = [bool]($names -contains 'convert_success')
        'Convert Failed'   = [bool]($names -contains 'convert_fail')
        'Saw Paywall'      = [bool]($names -contains 'paywall_shown')
        'Sent STK'         = [bool]($names -contains 'stk_initiated')
        'Paid'             = $paidClients.Contains($g.Name)
        'Downloaded'       = [bool]($names -contains 'download_success')
        'Revenue (KES)'    = ($myPaid | Measure-Object Amount -Sum).Sum
        'Transactions'     = if ($conv) { $conv.Txns } else { $null }
        'Months'           = if ($conv) { $conv.Months } else { $null }
        'Events'           = $ev.Count
    }
}
$visitors = @($visitors)

if ($visitors.Count -eq 0 -and $paidInRange.Count -eq 0) {
    Write-Host "No visitor activity in this range." -ForegroundColor Yellow
    return
}

# ── Funnel ──
Section 'FUNNEL (unique visitors)'
$steps = @(
    @('Visited the converter', @($visitors | Where-Object Visited).Count),
    @('Uploaded a statement',  @($visitors | Where-Object Uploaded).Count),
    @('Converted successfully',@($visitors | Where-Object Converted).Count),
    @('Opened the paywall',    @($visitors | Where-Object 'Saw Paywall').Count),
    @('Sent M-Pesa prompt',    @($visitors | Where-Object 'Sent STK').Count),
    @('Paid',                  @($visitors | Where-Object Paid).Count),
    @('Downloaded workbook',   @($visitors | Where-Object Downloaded).Count)
)
$top = [int]$steps[0][1]; if (-not $top) { $top = ($visitors.Count) }
Write-Host ('{0,-26}{1,8}{2,12}{3,14}' -f 'Step', 'People', 'of prev.', 'of visitors') -ForegroundColor DarkGray
$prev = $null
foreach ($s in $steps) {
    $n = [int]$s[1]
    $ofPrev = if ($null -eq $prev) { '' } else { Pct $n $prev }
    $bar = '#' * [int][math]::Round(30.0 * $n / [math]::Max(1, $top))
    Write-Host ('{0,-26}{1,8}{2,12}{3,14}  {4}' -f $s[0], $n, $ofPrev, (Pct $n $top), $bar)
    $prev = $n
}

# Biggest drop
$worst = $null; $worstLoss = -1
for ($i = 1; $i -lt $steps.Count - 1; $i++) {
    $a = [int]$steps[$i - 1][1]; $b = [int]$steps[$i][1]
    if ($a -gt 0 -and ($a - $b) / $a -gt $worstLoss) { $worstLoss = ($a - $b) / $a; $worst = "$($steps[$i-1][0]) -> $($steps[$i][0])" }
}
if ($worst) { Write-Host ("Biggest drop-off: {0} ({1:N0}% lost)" -f $worst, (100 * $worstLoss)) -ForegroundColor Yellow }

# ── Revenue & payments ──
Section 'PAYMENTS'
$revenue = ($paidInRange | Measure-Object Amount -Sum).Sum; if (-not $revenue) { $revenue = 0 }
$failed  = @($stkInRange | Where-Object Status -eq 'FAILED').Count
$pending = @($stkInRange | Where-Object Status -eq 'PENDING').Count
Write-Host ("Paid: {0}   Revenue: KES {1:N0}   Failed attempts: {2}   Still pending: {3}" -f $paidInRange.Count, $revenue, $failed, $pending)
$noClient = @($paidInRange | Where-Object { -not $_.Client }).Count
if ($noClient) { Write-Host ("  ({0} paid record(s) have no visitor id, so they count in revenue but not in the funnel)" -f $noClient) -ForegroundColor DarkGray }
if ($top) { Write-Host ("Revenue per visitor: KES {0:N1}" -f ($revenue / $top)) }

# ── Failures ──
$cf = @($events | Where-Object Event -eq 'convert_fail')
$df = @($events | Where-Object Event -eq 'download_fail')
if ($cf.Count -or $df.Count) {
    Section 'FAILURES'
    Write-Host ("Conversion failures: {0}   Download failures: {1}" -f $cf.Count, $df.Count)
    $reasons = @($cf + $df) | Group-Object { if ($_.Reason) { "$($_.Event): $($_.Reason)" } else { "$($_.Event): (no reason recorded)" } } |
        Sort-Object Count -Descending | Select-Object -First 8
    foreach ($r in $reasons) { Write-Host ('  {0,4}  {1}' -f $r.Count, $r.Name) }
}

# ── Devices & sources ──
Section 'DEVICES'
$visitors | Group-Object Device | Sort-Object Count -Descending | ForEach-Object {
    $paidHere = @($_.Group | Where-Object Paid).Count
    Write-Host ('  {0,-10}{1,6} visitors  {2,4} paid  ({3} convert to paid)' -f $_.Name, $_.Count, $paidHere, (Pct $paidHere $_.Count).Trim())
}

Section 'TRAFFIC SOURCES'
$visitors | Group-Object Source | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
    $paidHere = @($_.Group | Where-Object Paid).Count
    Write-Host ('  {0,-28}{1,6} visitors  {2,4} paid' -f $_.Name, $_.Count, $paidHere)
}

# ── Statements ──
$conv = @($events | Where-Object { $_.Event -eq 'convert_success' })
if ($conv.Count) {
    Section 'STATEMENTS CONVERTED'
    Write-Host ("Conversions: {0}   Median transactions: {1}   Median months: {2}   Median file: {3} KB" -f `
        $conv.Count, (Median $conv.Txns), (Median $conv.Months), $(if ($null -ne (Median $conv.FileKb)) { Median $conv.FileKb } else { '-' }))
    $big = @($conv | Where-Object { $_.Months -ge 12 }).Count
    Write-Host ("12+ month statements: {0} ({1})" -f $big, (Pct $big $conv.Count).Trim())
}

# ── Daily ──
Section 'VISITORS PER DAY'
$daily = @($events | Group-Object { DayOf $_.Ts } | Sort-Object Name)
$paidDaily = @{}
foreach ($p in $paidInRange) { $d = DayOf $p.Paid; $paidDaily[$d] = 1 + [int]$paidDaily[$d] }
$maxDay = ($daily | ForEach-Object { @($_.Group.Client | Sort-Object -Unique).Count } | Measure-Object -Maximum).Maximum
foreach ($d in $daily) {
    $u = @($d.Group.Client | Sort-Object -Unique).Count
    $bar = '#' * [int][math]::Round(30.0 * $u / [math]::Max(1, $maxDay))
    Write-Host ('  {0}  {1,5} visitors  {2,3} paid  {3}' -f $d.Name, $u, [int]$paidDaily[$d.Name], $bar)
}

if ($excluded.Count -and -not $IncludeTestTraffic) {
    Write-Host ""
    Write-Host ("Excluded {0} test visitor id(s) (sandbox payments / -ExcludePhone)." -f $excluded.Count) -ForegroundColor DarkGray
}

# ── Per-visitor CSV ──
if ($OutFile) {
    $visitors | Sort-Object 'First Seen (EAT)' | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
    Write-Host ("Per-visitor detail written to {0}" -f $OutFile) -ForegroundColor Green
}
