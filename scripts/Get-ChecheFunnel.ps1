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
    .\Get-ChecheFunnel.ps1 -Days 7 -ExcludePhone 254722117885 -Html
    Last 7 days, plus a visual HTML report with daily and cumulative charts.

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
    [switch]$Html,                         # also write a visual HTML report (charts) and open it
    [string]$HtmlFile,
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

# ── Visual HTML report ──
if ($Html -or $HtmlFile) {
    Add-Type -AssemblyName System.Web
    function Esc([string]$t) { [System.Web.HttpUtility]::HtmlEncode($t) }
    $ColGreen='#007A3D'; $ColGold='#F4A51C'; $INK='#1A1A2E'; $GREY='#6B7280'

    # daily series, zero-filled across the whole range
    $dayList=@(); $d=$From.Date; while ($d -le $To.Date) { $dayList += $d.ToString('yyyy-MM-dd'); $d=$d.AddDays(1) }
    $visByDay=@{}; foreach ($g in ($events | Group-Object { DayOf $_.Ts })) { $visByDay[$g.Name]=@($g.Group.Client | Sort-Object -Unique).Count }
    $paidByDay=@{}; foreach ($p in $paidInRange) { $k=DayOf $p.Paid; $paidByDay[$k]=1+[int]$paidByDay[$k] }
    $vis=@($dayList | ForEach-Object { [int]$visByDay[$_] }); $pay=@($dayList | ForEach-Object { [int]$paidByDay[$_] })
    $cv=@(); $cp=@(); $a=0; $b=0; for ($i=0;$i -lt $dayList.Count;$i++){ $a+=$vis[$i]; $b+=$pay[$i]; $cv+=$a; $cp+=$b }
    $labels=@($dayList | ForEach-Object { ([datetime]$_).ToString('d MMM') })
    $step=[math]::Max(1,[math]::Ceiling($dayList.Count/12))

    function Axis($W,$H,$L,$T,$R,$B,$max,$sb) {
        $n=4; for ($i=0;$i -le $n;$i++){ $v=[math]::Round($max*$i/$n); $y=$T+($H-$T-$B)*(1-$i/$n)
            [void]$sb.Append("<line x1='$L' y1='$y' x2='$($W-$R)' y2='$y' stroke='#E5E7EB'/><text x='$($L-8)' y='$($y+4)' font-size='11' text-anchor='end' fill='$GREY'>$v</text>") }
    }
    function Bars($a1,$a2,$n1,$n2) {
        $W=900;$H=320;$L=44;$T=20;$R=16;$B=48; $max=[math]::Max(1,(($a1+$a2)|Measure-Object -Maximum).Maximum); $max=[math]::Max(4,[math]::Ceiling($max*1.1/4)*4)
        $sb=New-Object System.Text.StringBuilder; [void]$sb.Append("<svg viewBox='0 0 $W $H' width='100%' role='img'>")
        Axis $W $H $L $T $R $B $max $sb
        $cw=($W-$L-$R)/$dayList.Count; $bw=[math]::Max(2,$cw*0.34)
        for ($i=0;$i -lt $dayList.Count;$i++){ $x=$L+$i*$cw+$cw*0.14
            foreach ($pair in @(@($a1[$i],$ColGreen,0),@($a2[$i],$ColGold,1))) { $barH=($H-$T-$B)*$pair[0]/$max; $y=$H-$B-$barH; $xx=$x+$pair[2]*($bw+2)
                [void]$sb.Append("<rect x='$xx' y='$y' width='$bw' height='$barH' rx='2' fill='$($pair[1])'><title>$($labels[$i]): $($pair[0])</title></rect>") }
            if ($i % $step -eq 0) { [void]$sb.Append("<text x='$($L+$i*$cw+$cw/2)' y='$($H-$B+18)' font-size='11' text-anchor='middle' fill='$GREY'>$($labels[$i])</text>") } }
        [void]$sb.Append("</svg>"); $sb.ToString()
    }
    function Lines($a1,$a2) {
        $W=900;$H=320;$L=44;$T=20;$R=16;$B=48; $max=[math]::Max(1,(($a1+$a2)|Measure-Object -Maximum).Maximum); $max=[math]::Max(4,[math]::Ceiling($max*1.1/4)*4)
        $sb=New-Object System.Text.StringBuilder; [void]$sb.Append("<svg viewBox='0 0 $W $H' width='100%' role='img'>")
        Axis $W $H $L $T $R $B $max $sb
        $n=[math]::Max(1,$dayList.Count-1); $px={ param($i) $L+($W-$L-$R)*$i/$n }; $py={ param($v) $H-$B-($H-$T-$B)*$v/$max }
        foreach ($ser in @(@($a1,$ColGreen),@($a2,$ColGold))) { $pts=@(); for ($i=0;$i -lt $dayList.Count;$i++){ $pts+=('{0:0.#},{1:0.#}' -f (& $px $i),(& $py $ser[0][$i])) }
            [void]$sb.Append("<polyline points='$($pts -join ' ')' fill='none' stroke='$($ser[1])' stroke-width='3' stroke-linejoin='round'/>")
            $last=$dayList.Count-1; [void]$sb.Append("<circle cx='$(& $px $last)' cy='$(& $py $ser[0][$last])' r='4' fill='$($ser[1])'/><text x='$((& $px $last)-6)' y='$((& $py $ser[0][$last])-9)' font-size='12' font-weight='700' text-anchor='end' fill='$($ser[1])'>$($ser[0][$last])</text>") }
        for ($i=0;$i -lt $dayList.Count;$i+=$step){ [void]$sb.Append("<text x='$(& $px $i)' y='$($H-$B+18)' font-size='11' text-anchor='middle' fill='$GREY'>$($labels[$i])</text>") }
        [void]$sb.Append("</svg>"); $sb.ToString()
    }

    $top2=[math]::Max(1,[int]$steps[0][1])
    $funnel=($steps | ForEach-Object { $n=[int]$_[1]; $w=[math]::Max(1,[math]::Round(100*$n/$top2)); $pc=[math]::Round(100*$n/$top2)
        "<div class='frow'><div class='flab'>$(Esc $_[0])</div><div class='fbar'><div style='width:$w%'></div></div><div class='fnum'>$n <span>$pc%</span></div></div>" }) -join "`n"
    $devRows=($visitors | Group-Object Device | Sort-Object Count -Descending | ForEach-Object { $pd=@($_.Group | Where-Object Paid).Count; "<tr><td>$(Esc $_.Name)</td><td>$($_.Count)</td><td>$pd</td></tr>" }) -join ''
    $srcRows=($visitors | Group-Object Source | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { $pd=@($_.Group | Where-Object Paid).Count; "<tr><td>$(Esc $_.Name)</td><td>$($_.Count)</td><td>$pd</td></tr>" }) -join ''
    $conv = if ($top2) { [math]::Round(100*$paidInRange.Count/$top2,1) } else { 0 }
    $gen=(Get-Date).ToString('yyyy-MM-dd HH:mm')
    $rng="{0:d MMM yyyy} – {1:d MMM yyyy}" -f $From,$To
    $css=@'
*{box-sizing:border-box}body{margin:0;font-family:Segoe UI,Inter,Arial,sans-serif;background:#F6F7F4;color:#1A1A2E}
header{background:#007A3D;color:#fff;padding:22px 28px}header h1{margin:0;font-size:22px}header p{margin:4px 0 0;opacity:.85;font-size:13px}
main{max-width:980px;margin:0 auto;padding:22px}
.kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:18px}
.kpi{background:#fff;border:1px solid #E5E7EB;border-radius:12px;padding:14px 16px}.kpi b{display:block;font-size:26px;color:#007A3D}.kpi span{font-size:12px;color:#6B7280}
.card{background:#fff;border:1px solid #E5E7EB;border-radius:12px;padding:16px 18px;margin-bottom:18px}.card h2{font-size:15px;margin:0 0 10px}
.legend{font-size:12px;color:#6B7280;margin-bottom:6px}.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin:0 5px 0 12px;vertical-align:middle}
.frow{display:grid;grid-template-columns:190px 1fr 90px;align-items:center;gap:10px;margin:6px 0;font-size:13px}
.fbar{background:#EEF2EE;border-radius:6px;height:18px}.fbar div{background:#007A3D;height:100%;border-radius:6px}.fnum{font-weight:700}.fnum span{color:#6B7280;font-weight:400;font-size:12px}
.two{display:grid;grid-template-columns:1fr 1fr;gap:18px}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:6px 4px;border-bottom:1px solid #F0F0F0}th{color:#6B7280;font-weight:600}
.note{font-size:12px;color:#6B7280}@media(max-width:700px){.kpis{grid-template-columns:1fr 1fr}.two{grid-template-columns:1fr}.frow{grid-template-columns:120px 1fr 70px}}
'@
    $page=@"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Cheche funnel report</title><style>$css</style></head><body>
<header><h1>Cheche funnel report</h1><p>$rng (Nairobi time) · generated $gen</p></header><main>
<div class="kpis">
<div class="kpi"><b>$top2</b><span>Visitors</span></div>
<div class="kpi"><b>$($paidInRange.Count)</b><span>Paying customers</span></div>
<div class="kpi"><b>KES $('{0:N0}' -f $revenue)</b><span>Revenue</span></div>
<div class="kpi"><b>$conv%</b><span>Visitor → paid</span></div></div>
<div class="card"><h2>Daily visitors and paid customers</h2><div class="legend"><i style="background:$ColGreen"></i>Visitors<i style="background:$ColGold"></i>Paid</div>$(Bars $vis $pay)</div>
<div class="card"><h2>Cumulative (running total)</h2><div class="legend"><i style="background:$ColGreen"></i>Visitors<i style="background:$ColGold"></i>Paying customers</div>$(Lines $cv $cp)</div>
<div class="card"><h2>Funnel (unique visitors)</h2>$funnel</div>
<div class="two"><div class="card"><h2>Devices</h2><table><tr><th>Device</th><th>Visitors</th><th>Paid</th></tr>$devRows</table></div>
<div class="card"><h2>Traffic sources</h2><table><tr><th>Source</th><th>Visitors</th><th>Paid</th></tr>$srcRows</table></div></div>
<p class="note">Excluded $($excluded.Count) test visitor id(s). Anonymous usage data only — no statement contents or phone numbers in this report.</p>
</main></body></html>
"@
    if (-not $HtmlFile) { $HtmlFile = Join-Path (Get-Location) ("cheche-funnel_{0:yyyy-MM-dd}_{1:yyyy-MM-dd}.html" -f $From,$To) }
    [System.IO.File]::WriteAllText($HtmlFile,$page,(New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("Visual report written to {0}" -f $HtmlFile) -ForegroundColor Green
    try { Start-Process $HtmlFile } catch { }
}

