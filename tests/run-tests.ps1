<#
  run-tests.ps1 - offline tests for src\fetch-wms.ps1 (never contacts the real WMS, never reads the real .env)
    Part A: parser  - tests\fixtures\report-sample.html (+ broken variants) via -HtmlFile
            (+ src\web\data\screenshot.local.json and any samples\*.html if present on this computer)
    Part B: live flow against tests\mock-wms.ps1 on localhost (fake user testuser / test-pass)
    Part C: page 2 logic in Edge headless + files that must not reach the repo
    Part D: P2-D truck list - server.ps1 GET /api/trucks (sample mode + -Live against the mock WMS, random ports, never 8787)
            + P2-E summary card on the page (S1-S4) ; C5 = summary() vs an independent sum
  Run:  powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
  Everything is written to a temp folder that is deleted at the end.
#>
$ErrorActionPreference = 'Stop'
$root    = Split-Path $PSScriptRoot -Parent
$fetch   = Join-Path $root 'src\fetch-wms.ps1'
$fixture = Join-Path $PSScriptRoot 'fixtures\report-sample.html'
$tmp     = Join-Path $env:TEMP ('wms-rt-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$script:pass = 0; $script:fail = 0; $script:servers = @()

function Check([string]$name, [bool]$cond, [string]$detail = '') {
  if ($cond) { $script:pass++; Write-Host "  PASS  $name" -ForegroundColor Green }
  else { $script:fail++; Write-Host "  FAIL  $name  $detail" -ForegroundColor Red }
}
function Run-Fetch([string[]]$a) {
  if ($a -notcontains '-LogDir') { $a += @('-LogDir', (Join-Path $tmp 'logs')) }
  & powershell -NoProfile -ExecutionPolicy Bypass -File $fetch @a *> (Join-Path $tmp 'last-run.txt')
  return $LASTEXITCODE
}
function Read-Out([string]$p) { [IO.File]::ReadAllText($p, $utf8) | ConvertFrom-Json }
function Same-Rows($a, $b) {
  if (@($a).Count -ne @($b).Count) { return $false }
  $fields = 'workloadPct','weightKg','completeKg','remainingKg','completePct','truckCheckIn','truckOutbound','truckComplete','truckRemaining','truckCompletePct'
  for ($i = 0; $i -lt @($a).Count; $i++) {
    if ($a[$i].period -ne $b[$i].period) { return $false }
    foreach ($f in $fields) { if ([decimal]$a[$i].$f -ne [decimal]$b[$i].$f) { return $false } }
  }
  return $true
}

try {
  # ------------------------------------------------------------------ Part A
  Write-Host 'Part A - parser (-HtmlFile, no network)' -ForegroundColor Cyan
  $sample = Read-Out (Join-Path $root 'src\web\data\sample.json')
  $o = Join-Path $tmp 'a1.json'
  $code = Run-Fetch @('-HtmlFile', $fixture, '-OutFile', $o)
  $j = Read-Out $o
  Check 'A1 fixture parses: exit 0, status ok' ($code -eq 0 -and $j.status -eq 'ok')
  Check 'A1 17 rows equal sample.json rows' (Same-Rows $j.rows $sample.rows)
  Check 'A1 total equals sample.json total' ([decimal]$j.total.weightKg -eq [decimal]$sample.total.weightKg -and $j.total.truckRemaining -eq $sample.total.truckRemaining)
  Check 'A1 source wms, schemaVersion 1, lastSuccessAt set' ($j.source -eq 'wms' -and $j.schemaVersion -eq 1 -and $j.lastSuccessAt)

  $shot = Join-Path $root 'src\web\data\screenshot.local.json'
  if (Test-Path $shot) {
    $h = Join-Path $tmp 'screenshot.html'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'make-fixture.ps1') -Source $shot -Out $h | Out-Null
    $o = Join-Path $tmp 'a2.json'
    $code = Run-Fetch @('-HtmlFile', $h, '-OutFile', $o)
    $j = Read-Out $o
    Check 'A2 screenshot numbers (local only) parse and pass all cross-checks' ($code -eq 0 -and (Same-Rows $j.rows (Read-Out $shot).rows)) (Get-Content (Join-Path $tmp 'last-run.txt') -Raw)
  } else { Write-Host '  SKIP  A2 (no screenshot.local.json)' }

  $base = [IO.File]::ReadAllText($fixture, $utf8)
  function Line-Edit([string]$html, [string]$period, [scriptblock]$edit) {
    $lines = $html -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -like "*>$period น.<*") { $lines[$i] = & $edit $lines[$i] } }
    return ($lines -join "`n")
  }
  $broken = [ordered]@{
    'title missing'           = $base.Replace('Outbound the amount of work each day', 'Inbound summary')
    'header changed'          = $base.Replace('<th>Check in</th>', '<th>Arrived</th>')
    'row has 10 columns'      = Line-Edit $base '12:01 - 13:00' { param($l) $l -replace '<td class="text-right">[^<]*</td>\s*$', '' }
    'row missing (16 rows)'   = Line-Edit $base '15:01 - 16:00' { param($l) '' }
    'cell not a number'       = Line-Edit $base '10:01 - 11:00' { param($l) $l -replace '(<td class="text-right">)[^<]*(</td>)', '$1N/A$2' }
    'Total weight mismatch'   = $base.Replace('<td class="text-right">2,317,052.550</td>', '<td class="text-right">2,317,000.000</td>')
    'remaining not cumulative'= Line-Edit $base '11:01 - 12:00' { param($l) $l.Replace('626,530.100', '600,000.000') }
    'periods out of order'    = $base.Replace('>09:01 - 10:00 น.<', '>XX<').Replace('>10:01 - 11:00 น.<', '>09:01 - 10:00 น.<').Replace('>XX<', '>10:01 - 11:00 น.<')
    'no table (empty page)'   = '<html><body>Outbound the amount of work each day<p>no data</p></body></html>'
    'login page instead'      = '<html><body><form action="/wms/user/login"><input name="txtUserName"><input type="password" name="txtPassword"></form></body></html>'
  }
  $k = 0
  foreach ($name in $broken.Keys) {
    $k++
    $h = Join-Path $tmp "broken$k.html"; [IO.File]::WriteAllText($h, $broken[$name], $utf8)
    $o = Join-Path $tmp "broken$k.json"
    $code = Run-Fetch @('-HtmlFile', $h, '-OutFile', $o)
    $j = Read-Out $o
    Check ("A3 parse_error: $name  -> " + $j.message) ($code -eq 3 -and $j.status -eq 'parse_error' -and @($j.rows).Count -eq 0)
  }

  # real WMS layout (seen 2026-10-30): title <h4> sits inside a layout table, the data table follows it,
  # and an Inbound table comes after. The parser must pick the Outbound data table.
  $dataTable = [regex]::Match($base, '(?s)<table class="table.*?</table>').Value
  $inbound = $dataTable.Replace('class="table', 'class="table inbound').Replace('312,450.500', '999,999.999')
  $layout = $base.Replace('<h4><b>Outbound the amount of work each day</b></h4>',
      '<table class="layout" width="100%"><tr><td><h4><b>Outbound the amount of work each day</b></h4></td><td>&nbsp;</td></tr></table>')
  $layout = $layout.Replace($dataTable, $dataTable + "`n    <h4><b>Inbound the amount of work each day</b></h4>`n    " + $inbound)
  $h = Join-Path $tmp 'layout.html'; [IO.File]::WriteAllText($h, $layout, $utf8)
  $o = Join-Path $tmp 'layout.json'
  $code = Run-Fetch @('-HtmlFile', $h, '-OutFile', $o)
  $j = Read-Out $o
  Check 'A5 title in layout table + data table next + Inbound table after -> picks Outbound table' ($code -eq 0 -and (Same-Rows $j.rows $sample.rows)) ($j.message)

  # ---- page 2: Gate Tracking parser (fictional fixture, same structure as the real page)
  $tfix = Join-Path $PSScriptRoot 'fixtures\tracking-sample.html'
  $o = Join-Path $tmp 't1.json'
  $code = Run-Fetch @('-HtmlFile', $tfix, '-OutFile', $o)
  $j = Read-Out $o
  $sumP = 0; $sumL = 0; foreach ($q in $j.points) { $sumP += $q.plan; $sumL += $q.loading }
  Check 'T1 tracking fixture (auto-detected) parses: exit 0, status ok, kind tracking' ($code -eq 0 -and $j.status -eq 'ok' -and $j.kind -eq 'tracking')
  Check 'T1 28 points, Plan 31, loading 14 (fixture numbers)' (@($j.points).Count -eq 28 -and $sumP -eq 31 -and $sumL -eq 14) "got $(@($j.points).Count) / $sumP / $sumL"
  $byName = @{}; foreach ($q in $j.points) { $byName[$q.name] = $q }
  Check 'T1 2-per-row card: H7 = Plan 3, loading 1, zone H' ($byName['H7'].plan -eq 3 -and $byName['H7'].loading -eq 1 -and $byName['H7'].zone -eq 'H')
  Check 'T1 numeric names kept as text: 01 = 3/1, 21 = 1/0' ($byName['01'].plan -eq 3 -and $byName['01'].loading -eq 1 -and $byName['21'].plan -eq 1)
  Check 'T1 Weight Incoming: final 3 (shown), header 37' ($j.weightIncoming.final -eq 3 -and $j.weightIncoming.header -eq 37)
  $fixFlat = ([IO.File]::ReadAllText($tfix, $utf8)) -replace '[\r\n]', ' '
  $fixIds = @{}; foreach ($m in [regex]::Matches($fixFlat, 'class="tbBorder"\s+id="(\d+)"><tr>\s*<td[^>]*class="column1">([^<]*)</td>')) { $fixIds[$m.Groups[2].Value] = [int]$m.Groups[1].Value }
  $gBad = @($j.points | Where-Object { $_.gateId -isnot [int] -or $fixIds[$_.name] -ne $_.gateId })
  Check 'T1 P2-D: every point has gateId = id of its table.tbBorder (independent regex, 28 ids)' ($fixIds.Count -eq 28 -and $gBad.Count -eq 0) "regex $($fixIds.Count), mismatched $($gBad.Count)"
  $noTb = Join-Path $tmp 't1-notb.html'; [IO.File]::WriteAllText($noTb, ([IO.File]::ReadAllText($tfix, $utf8)).Replace('class="tbBorder" id="117"', 'class="tbBorder"'), $utf8)
  $o3 = Join-Path $tmp 't1-notb.json'; $code = Run-Fetch @('-HtmlFile', $noTb, '-OutFile', $o3); $j3 = Read-Out $o3
  $h7 = @($j3.points | Where-Object { $_.name -eq 'H7' })[0]
  Check 'T1 P2-D: a table without id -> that point gateId null, page still ok (numbers unaffected)' ($code -eq 0 -and $null -eq $h7.gateId -and @($j3.points | Where-Object { $_.gateId -is [int] }).Count -eq 27)
  Check 'T1 sample tracking.sample.json = fixture points' ((Read-Out (Join-Path $root 'src\web\data\tracking.sample.json')).points.Count -eq 28)
  $o2 = Join-Path $tmp 't1b.json'
  $code = Run-Fetch @('-HtmlFile', $tfix, '-OutFile', $o2, '-Page', 'report')
  Check 'T1 -Page report on the Tracking page -> parse_error (no guessing)' ($code -eq 3)

  $tbase = [IO.File]::ReadAllText($tfix, $utf8)
  $angularOnly = [regex]::Replace($tbase, '(?s)<div style="margin-left: 250px">.*?</ul>\s*</div>', '')
  $tbroken = [ordered]@{
    'no "Gate Tracking" heading'   = $tbase.Replace('Gate Tracking', 'Something else')
    'no Weight Incoming box'       = $tbase.Replace('Weight Incoming', 'Weight In')
    'Weight Final not a number'    = $tbase.Replace('<h2 ng-click="pageEvent.onClickScheduleList(0,''W'','''','''',0)">3</h2>', '<h2>{{model.WeightFinal}}</h2>')
    'loading cell not a number'    = [regex]::Replace($tbase, '(?s)(class="column1">B</td>.*?style="background-color: #0FB800">\s*)2', '${1}N/A', 1)
    'point row with 4 cells'       = $tbase.Replace('<td align="center" class="column2">5</td>', '<td align="center" class="column2">5</td><td>9</td>')
    'duplicate point'              = $tbase.Replace('class="column1">E<', 'class="column1">B<')
    'no point cards (Angular only)'= $angularOnly
    'point row outside a zone card'= $tbase.Replace('<div class="lastFooter">', '<table><tr><td class="column1">X9</td><td class="column2">1</td><td class="column2">0</td></tr></table><div class="lastFooter">')
    'empty loading cell'           = [regex]::Replace($tbase, '(?s)(class="column1">E</td>.*?style="background-color: #0FB800">)\s*0\s*', '${1}')
    'login page instead'           = '<html><body><form action="/wms/user/login"><input name="txtUserName"><input type="password" name="txtPassword"></form></body></html>'
  }
  $k = 0
  foreach ($name in $tbroken.Keys) {
    $k++
    $h = Join-Path $tmp "tbroken$k.html"; [IO.File]::WriteAllText($h, $tbroken[$name], $utf8)
    $o = Join-Path $tmp "tbroken$k.json"
    $code = Run-Fetch @('-HtmlFile', $h, '-OutFile', $o, '-Page', 'tracking')
    $j = Read-Out $o
    Check ("T2 tracking parse_error: $name  -> " + $j.message) ($code -eq 3 -and $j.status -eq 'parse_error' -and @($j.points).Count -eq 0)
  }

  # real saved Tracking page (local only, never committed): parser result must equal an independent regex count
  $realT = Join-Path $root 'samples\tracking.html'
  if (Test-Path $realT) {
    $o = Join-Path $tmp 'real-tracking.json'
    $code = Run-Fetch @('-HtmlFile', $realT, '-OutFile', $o)
    $j = Read-Out $o
    $flat = ([IO.File]::ReadAllText($realT, $utf8)) -replace '[\r\n]', ' '
    $ms = [regex]::Matches($flat, 'class="column1">([^<]*)</td>\s*<td[^>]*>\s*([^<]*?)\s*</td>\s*<td[^>]*>\s*([^<]*?)\s*</td>')
    $eP = 0; $eL = 0; foreach ($m in $ms) { $eP += [int]$m.Groups[2].Value; $eL += [int]$m.Groups[3].Value }
    $gP = 0; $gL = 0; foreach ($q in $j.points) { $gP += $q.plan; $gL += $q.loading }
    $wm = [regex]::Match($flat, 'Weight Final</span>\s*<h2[^>]*>\s*(\d+)\s*</h2>')
    Check 'T3 real samples\tracking.html: same point count and Plan/loading sums as an independent regex' ($code -eq 0 -and @($j.points).Count -eq $ms.Count -and $gP -eq $eP -and $gL -eq $eL) "parser $(@($j.points).Count)/$gP/$gL vs regex $($ms.Count)/$eP/$eL"
    Check 'T3 real Weight Final equals the <h2> under "Weight Final"' ($wm.Success -and $j.weightIncoming.final -eq [int]$wm.Groups[1].Value)
    $gm = [regex]::Matches($flat, 'class="tbBorder"\s+id="(\d+)">\s*<tr>\s*<td[^>]*class="column1">\s*([^<]*?)\s*</td>')
    $gExp = @{}; foreach ($m in $gm) { $gExp[$m.Groups[2].Value] = [int]$m.Groups[1].Value }
    $gBad = @($j.points | Where-Object { $_.gateId -isnot [int] -or $gExp[$_.name] -ne $_.gateId })
    Check 'T3 real page: every point has gateId = id of its table.tbBorder (independent regex)' ($gm.Count -eq @($j.points).Count -and $gBad.Count -eq 0) "regex $($gm.Count), mismatched $($gBad.Count)"
  } else { Write-Host '  SKIP  T3 (no samples\tracking.html)' }

  $samplesDir = Join-Path $root 'samples'
  $real = @(Get-ChildItem -Path $samplesDir -Filter *.htm* -ErrorAction SilentlyContinue)
  foreach ($f in $real) {
    $o = Join-Path $tmp ('real-' + $f.BaseName + '.json')
    $code = Run-Fetch @('-HtmlFile', $f.FullName, '-OutFile', $o)
    $j = Read-Out $o
    Check ("A4 real saved page samples\" + $f.Name + ' -> ' + $j.status + ' ' + $j.message) ($code -eq 0)
  }
  if ($real.Count -eq 0) { Write-Host '  SKIP  A4 (no HTML saved in samples\ yet)' }

  # ------------------------------------------------------------------ Part B
  Write-Host 'Part B - live flow against mock WMS on localhost' -ForegroundColor Cyan
  $port = Get-Random -Minimum 20000 -Maximum 40000
  $state = Join-Path $tmp 'mock'; New-Item -ItemType Directory -Path $state | Out-Null
  $mock = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
          "`"$(Join-Path $PSScriptRoot 'mock-wms.ps1')`"", '-Port', $port, '-StateDir', "`"$state`"", '-ReportHtml', "`"$fixture`"", '-TrackingHtml', "`"$tfix`"",
          '-ScheduleJson', "`"$(Join-Path $PSScriptRoot 'fixtures\schedule-sample.json')`"")
  for ($i = 0; $i -lt 50 -and -not (Test-Path (Join-Path $state 'ready.txt')); $i++) { Start-Sleep -Milliseconds 200 }
  $mode = Join-Path $state 'mode.txt'; $reqLog = Join-Path $state 'requests.log'
  function Set-Mode([string]$m) { [IO.File]::WriteAllText($mode, $m) ; if (Test-Path $reqLog) { Remove-Item $reqLog } }
  function Count-Req([string]$prefix) { if (Test-Path $reqLog) { @(Get-Content $reqLog | Where-Object { $_ -like "$prefix*" }).Count } else { 0 } }
  $envGood = Join-Path $tmp 'good.env'; $envBad = Join-Path $tmp 'bad.env'; $envDown = Join-Path $tmp 'down.env'
  [IO.File]::WriteAllText($envGood, "WMS_BASE_URL=http://localhost:$port/wms`r`nWMS_USERNAME=testuser`r`nWMS_PASSWORD=test-pass`r`n")
  [IO.File]::WriteAllText($envBad,  "WMS_BASE_URL=http://localhost:$port/wms/`r`nWMS_USERNAME=testuser`r`nWMS_PASSWORD=wrong-pass`r`n")
  [IO.File]::WriteAllText($envDown, "WMS_BASE_URL=http://localhost:1/wms`r`nWMS_USERNAME=testuser`r`nWMS_PASSWORD=test-pass`r`n")
  $live = Join-Path $tmp 'live\latest.json'

  Set-Mode 'normal'
  $code = Run-Fetch @('-Once', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live
  Check 'B1 login + report -> ok, 17 rows, failures 0' ($code -eq 0 -and $j.status -eq 'ok' -and @($j.rows).Count -eq 17 -and $j.consecutiveFailures -eq 0)
  Check 'B1 exactly 1 login POST, 1 report GET' ((Count-Req 'POST /wms/user/login') -eq 1 -and (Count-Req 'GET /wms/Report/ReportShipment') -eq 1)
  Check 'B1 no .tmp left behind' (-not (Test-Path ($live + '.tmp')))
  $histFiles = @(Get-ChildItem (Join-Path $tmp 'logs') -Filter 'history-*.local.jsonl' -ErrorAction SilentlyContinue)
  $histLines = @(); if ($histFiles.Count -eq 1) { $histLines = @(Get-Content $histFiles[0].FullName -Encoding UTF8 | Where-Object { $_ }) }
  $h0 = $null; try { $h0 = $histLines[0] | ConvertFrom-Json } catch { }
  Check 'B1 history: 1 JSONL line with fetchedAt, reportDate, total, 17 rows' ($histLines.Count -eq 1 -and $h0 -and $h0.fetchedAt -eq $j.lastSuccessAt -and $h0.reportDate -eq $j.reportDate -and @($h0.rows).Count -eq 17 -and [decimal]$h0.total.weightKg -eq [decimal]$j.total.weightKg)
  $okAt = $j.lastSuccessAt
  $liveT = Join-Path $tmp 'live\tracking.json'
  $t = Read-Out $liveT
  Check 'P1 page 2: tracking.json written next to latest.json, ok, 28 points, Weight Final 3' ($t.status -eq 'ok' -and @($t.points).Count -eq 28 -and $t.weightIncoming.final -eq 3 -and $t.source -eq 'wms')
  Check 'P1 exactly 1 Tracking GET, with the same session (no extra login)' ((Count-Req 'GET /wms/Report/Tracking') -eq 1 -and (Count-Req 'POST') -eq 1)
  Check 'P1 no tracking .tmp left behind' (-not (Test-Path ($liveT + '.tmp')))
  $tOkAt = $t.lastSuccessAt

  $code = Run-Fetch @('-Once', '-EnvFile', $envDown, '-OutFile', $live, '-TimeoutSec', '5'); $j = Read-Out $live
  Check ('B2 WMS unreachable -> fetch_error, failures 1 -> ' + $j.message) ($code -eq 1 -and $j.status -eq 'fetch_error' -and $j.consecutiveFailures -eq 1)
  Check 'B2 last good rows + lastSuccessAt kept' (@($j.rows).Count -eq 17 -and $j.lastSuccessAt -eq $okAt -and $j.lastAttemptAt)
  Check 'B2 message has no URL/host' ($j.message -notmatch 'localhost|http|:\d{2,5}')
  $code = Run-Fetch @('-Once', '-EnvFile', $envDown, '-OutFile', $live, '-TimeoutSec', '5'); $j = Read-Out $live
  Check 'B2 second failure -> consecutiveFailures 2' ($j.consecutiveFailures -eq 2)
  Check 'B2 failures add no history line' (@(Get-Content $histFiles[0].FullName | Where-Object { $_ }).Count -eq 1)
  $t = Read-Out $liveT
  Check ('P2 WMS unreachable -> tracking fetch_error, failures 2, last good points kept -> ' + $t.message) ($t.status -eq 'fetch_error' -and $t.consecutiveFailures -eq 2 -and @($t.points).Count -eq 28 -and $t.lastSuccessAt -eq $tOkAt)

  Set-Mode 'report500'
  $code = Run-Fetch @('-Once', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live
  Check ('B3 report HTTP 500 -> fetch_error, failures 3 -> ' + $j.message) ($code -eq 1 -and $j.status -eq 'fetch_error' -and $j.consecutiveFailures -eq 3 -and @($j.rows).Count -eq 17)
  Set-Mode 'normal'
  $code = Run-Fetch @('-Once', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live
  Check 'B3 recovery -> ok, failures reset to 0' ($code -eq 0 -and $j.status -eq 'ok' -and $j.consecutiveFailures -eq 0)
  Check 'P3 tracking recovers too -> ok, failures 0' ((Read-Out $liveT).status -eq 'ok' -and (Read-Out $liveT).consecutiveFailures -eq 0)

  # page 2 failures must never touch latest.json (page 1)
  foreach ($tm in @(@('tracking500', 'fetch_error'), @('trackingbroken', 'parse_error'), @('trackinglogin', 'fetch_error'))) {
    Set-Mode $tm[0]
    $code = Run-Fetch @('-Once', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live; $t = Read-Out $liveT
    Check ("P4 $($tm[0]) -> tracking $($tm[1]) (" + $t.message + '), latest.json still ok, exit 0') ($code -eq 0 -and $j.status -eq 'ok' -and @($j.rows).Count -eq 17 -and $t.status -eq $tm[1] -and @($t.points).Count -eq 28)
  }
  Check 'P4 Tracking shows login page -> no extra login for it (only the 1 normal login, 1 Tracking GET)' ((Count-Req 'POST') -eq 1 -and (Count-Req 'GET /wms/Report/Tracking') -eq 1)
  Set-Mode 'normal'
  $code = Run-Fetch @('-Once', '-EnvFile', $envGood, '-OutFile', $live)
  Check 'P4 recovery after Tracking problems -> tracking ok' ((Read-Out $liveT).status -eq 'ok')

  Set-Mode 'reportbroken'
  $code = Run-Fetch @('-Once', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live
  Check ('B4 report page changed -> parse_error -> ' + $j.message) ($code -eq 3 -and $j.status -eq 'parse_error')
  Check 'P5 report parse_error does not block page 2 (tracking still ok)' ((Read-Out $liveT).status -eq 'ok')

  Set-Mode 'loginchanged'
  $code = Run-Fetch @('-Once', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live
  Check ('B5 login form changed -> parse_error, password NOT sent -> ' + $j.message) ($code -eq 3 -and $j.status -eq 'parse_error' -and (Count-Req 'POST') -eq 0)

  Set-Mode 'expire2nd'
  $code = Run-Fetch @('-Cycles', '2', '-IntervalSec', '1', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live
  Check 'B6 session expired -> one re-login -> ok' ($code -eq 0 -and $j.status -eq 'ok' -and (Count-Req 'POST /wms/user/login') -eq 2 -and (Count-Req 'GET /wms/Report/ReportShipment') -eq 3)

  Set-Mode 'expire2nd-reject'
  $code = Run-Fetch @('-Cycles', '5', '-IntervalSec', '1', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live
  Check ('B7 session expired + re-login rejected -> login_failed, stops -> ' + $j.message) ($code -eq 2 -and $j.status -eq 'login_failed' -and (Count-Req 'POST /wms/user/login') -eq 2 -and (Count-Req 'GET /wms/Report/ReportShipment') -eq 2)
  Check 'B7 rows kept for display' (@($j.rows).Count -eq 17)
  $t = Read-Out $liveT
  Check 'P6 login_failed -> tracking login_failed too, points kept' ($t.status -eq 'login_failed' -and @($t.points).Count -eq 28)

  Set-Mode 'normal'
  Start-Sleep -Seconds 1
  (Get-Item $envBad).LastWriteTime = Get-Date      # "owner edits .env" (with a wrong password)
  $code = Run-Fetch @('-Cycles', '3', '-IntervalSec', '1', '-EnvFile', $envBad, '-OutFile', $live); $j = Read-Out $live
  Check ('B8 wrong password -> login_failed, exactly 1 attempt, no retry -> ' + $j.message) ($code -eq 2 -and $j.status -eq 'login_failed' -and (Count-Req 'POST') -eq 1 -and (Count-Req 'GET /wms/Report/ReportShipment') -eq 0)

  Set-Mode 'normal'
  $code = Run-Fetch @('-Cycles', '1', '-EnvFile', $envBad, '-OutFile', $live)
  Check 'B9 restart without editing .env -> blocked, no request at all' ($code -eq 2 -and (Count-Req '') -eq 0 -and (Read-Out $live).status -eq 'login_failed')
  $t = Read-Out $liveT; $t.status = 'ok'; [IO.File]::WriteAllText($liveT, ($t | ConvertTo-Json -Depth 6), $utf8)
  Set-Mode 'normal'
  $code = Run-Fetch @('-Cycles', '1', '-EnvFile', $envBad, '-OutFile', $live)
  $t = Read-Out $liveT
  Check 'P7 blocked at start -> tracking.json also login_failed (page 2 shows the same state), points kept, no request' ($code -eq 2 -and $t.status -eq 'login_failed' -and @($t.points).Count -eq 28 -and (Count-Req '') -eq 0)

  Set-Mode 'normal'
  $code = Run-Fetch @('-Once', '-ResetLogin', '-EnvFile', $envBad, '-OutFile', $live)
  Check 'B10 -ResetLogin allows exactly one new attempt' ($code -eq 2 -and (Count-Req 'POST') -eq 1)

  Set-Mode 'normal'
  Start-Sleep -Seconds 1
  (Get-Item $envGood).LastWriteTime = Get-Date     # owner fixes .env
  $code = Run-Fetch @('-Once', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live
  Check 'B11 after .env is edited -> runs again -> ok' ($code -eq 0 -and $j.status -eq 'ok')

  Set-Mode 'normal'
  $code = Run-Fetch @('-Once', '-EnvFile', (Join-Path $tmp 'missing.env'), '-OutFile', $live); $j = Read-Out $live
  Check ('B12 no .env -> login_failed, no request -> ' + $j.message) ($code -eq 2 -and $j.status -eq 'login_failed' -and (Count-Req '') -eq 0)

  $logText = (Get-ChildItem (Join-Path $tmp 'logs') -Filter *.log | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
  Check 'B13 log never contains password / cookie / host' ($logText -notmatch 'test-pass|wrong-pass|MOCKAUTH|localhost' -and $logText.Length -gt 0)
  $allJson = (Get-ChildItem $tmp -Recurse -Filter *.json | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
  Check 'B13 output JSON never contains password / host' ($allJson -notmatch 'test-pass|wrong-pass|localhost')
  $histText = (Get-ChildItem (Join-Path $tmp 'logs') -Filter *.jsonl | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
  Check 'B13 history never contains password / cookie / host' ($histText.Length -gt 0 -and $histText -notmatch 'test-pass|wrong-pass|MOCKAUTH|localhost|testuser')

  Set-Mode 'normal'
  Start-Sleep -Seconds 1
  (Get-Item $envGood).LastWriteTime = Get-Date     # B12 ended with login_failed; "owner edits .env"
  $blocker =Join-Path $tmp 'not-a-folder.txt'; [IO.File]::WriteAllText($blocker, 'x')     # history folder cannot be created
  $code = Run-Fetch @('-Once', '-EnvFile', $envGood, '-OutFile', $live, '-LogDir', $blocker); $j = Read-Out $live
  Check 'B14 history write fails -> latest.json still written ok' ($code -eq 0 -and $j.status -eq 'ok' -and $j.consecutiveFailures -eq 0)

  Set-Mode 'normal'
  $j.status = 'login_failed'; $j.lastAttemptAt = 'not-a-time'
  [IO.File]::WriteAllText($live, ($j | ConvertTo-Json -Depth 6), $utf8)
  (Get-Item $envGood).LastWriteTime = Get-Date
  $code = Run-Fetch @('-Cycles', '1', '-EnvFile', $envGood, '-OutFile', $live)
  Check 'B15 login_failed with unreadable lastAttemptAt -> blocked (fail closed), no request' ($code -eq 2 -and (Count-Req '') -eq 0)

  # ------------------------------------------------------------------ Part C
  Write-Host 'Part C - page 2 logic (Edge headless) + files that must not reach the repo' -ForegroundColor Cyan
  $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  function Edge-Dump([string]$file) {
    $prof = Join-Path $tmp 'edge-profile'
    $uri = ([Uri](Resolve-Path -LiteralPath $file).ProviderPath).AbsoluteUri
    # msedge.exe is a GUI program: PowerShell only waits for it / captures its output via Start-Process
    $so = Join-Path $tmp ('edge-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    Start-Process -FilePath $edge -ArgumentList @('--headless', '--disable-gpu', '--no-first-run', "--user-data-dir=`"$prof`"", '--dump-dom', $uri) `
      -Wait -NoNewWindow -RedirectStandardOutput $so -RedirectStandardError ($so + '.err')
    return [IO.File]::ReadAllText($so, $utf8)
  }
  if ($edge) {
    $dom = Edge-Dump (Join-Path $PSScriptRoot 'gate-calc-tests.html')
    $m = [regex]::Match($dom, 'GATECALC RESULT pass=(\d+) fail=(\d+)([^<]*)')
    Check ('C1 gate-calc.js tests (aggregate, colours 80/100 boundaries, validation, status): ' + $(if ($m.Success) { $m.Groups[1].Value + ' pass' } else { 'no result' })) ($m.Success -and [int]$m.Groups[2].Value -eq 0 -and [int]$m.Groups[1].Value -gt 30) $(if ($m.Success) { $m.Groups[3].Value } else { '' })

    # per-warehouse totals: GateCalc in the browser vs an independent PowerShell sum
    $calcUri = ([Uri](Join-Path $root 'src\web\js\gate-calc.js')).AbsoluteUri
    function Compare-Agg([string]$label, [string]$trackingJson, [string]$siteJson) {
      $site = $siteJson | ConvertFrom-Json; $tr = $trackingJson | ConvertFrom-Json
      $exp = @{}; $unm = @()
      $ids = @{}; foreach ($b in $site.buildings) { $ids[$b.id] = $true }
      foreach ($p in $tr.points) {
        $bid = $site.pointMap.($p.name)
        if (-not $bid -or -not $ids[$bid]) { $unm += $p.name; continue }
        if (-not $exp[$bid]) { $exp[$bid] = @(0, 0) }
        $exp[$bid] = @(($exp[$bid][0] + $p.plan), ($exp[$bid][1] + $p.loading))
      }
      $expTxt = (($exp.Keys | Sort-Object { $_ } -Culture 'en-US' | ForEach-Object { '{0}={1}+{2}#{3}' -f $_, $exp[$_][0], $exp[$_][1], $exp[$_][1] }) -join ';') + '|' + ($unm -join ',')
      $html = "<html><head><meta charset=`"utf-8`"></head><body><pre id=`"o`">x</pre><script src=`"$calcUri`"></script><script>" +
        "var t=$trackingJson; var s=$siteJson; var a=GateCalc.aggregate(t.points,s);" +
        "var k=Object.keys(a.byBuilding).sort(function(x,y){return x<y?-1:x>y?1:0;});" +
        "document.getElementById('o').textContent='AGG['+k.map(function(i){var b=a.byBuilding[i];return i+'='+b.plan+'+'+b.loading+'#'+b.total;}).join(';')+'|'+a.unmatched.map(function(u){return u.name;}).join(',')+']AGG';</script></body></html>"
      $f = Join-Path $tmp ('agg-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.html'); [IO.File]::WriteAllText($f, $html, $utf8)
      $got = [regex]::Match((Edge-Dump $f), 'AGG\[(.*?)\]AGG').Groups[1].Value
      $sortedGot = (($got.Split('|')[0].Split(';') | Where-Object { $_ } | Sort-Object { $_.Split('=')[0] } -Culture 'en-US') -join ';') + '|' + $got.Split('|')[1]
      Check ("C2 $label : browser totals per warehouse = independent sum (card number # = loading only)") ($got -and $sortedGot -eq $expTxt) "browser [$sortedGot] vs [$expTxt]"
      Remove-Item $f -ErrorAction SilentlyContinue
    }
    $sampleSite = [IO.File]::ReadAllText((Join-Path $root 'src\web\data\site.sample.json'), $utf8)
    Compare-Agg 'sample site + fixture' ([IO.File]::ReadAllText((Join-Path $root 'src\web\data\tracking.sample.json'), $utf8)) $sampleSite
    $localSite = Join-Path $root 'src\web\data\site.local.json'
    if ((Test-Path $localSite) -and (Test-Path (Join-Path $root 'samples\tracking.html'))) {
      Compare-Agg 'REAL site.local.json + samples\tracking.html (local only)' ([IO.File]::ReadAllText((Join-Path $tmp 'real-tracking.json'), $utf8)) ([IO.File]::ReadAllText($localSite, $utf8))
    } else { Write-Host '  SKIP  C2 real (no site.local.json or samples\tracking.html)' }

    # P2-E summary: GateCalc.summary in the browser vs an independent PowerShell sum of every point (unmatched included) + weightIncoming.final
    function Compare-Sum([string]$label, [string]$trackingJson, [string]$siteJson) {
      $site = $siteJson | ConvertFrom-Json; $tr = $trackingJson | ConvertFrom-Json
      $ids = @{}; foreach ($b in $site.buildings) { $ids[$b.id] = $true }
      $ld = 0; $pl = 0; $uc = 0; $ul = 0; $up = 0
      foreach ($p in $tr.points) {
        $ld += $p.loading; $pl += $p.plan
        $bid = $site.pointMap.($p.name)
        if (-not $bid -or -not $ids[$bid]) { $uc++; $ul += $p.loading; $up += $p.plan }
      }
      $w = $(if ($tr.weightIncoming) { [string]$tr.weightIncoming.final } else { 'null' })
      $expTxt = "$ld/$pl/$w/$uc/$ul/$up"
      $html = "<html><head><meta charset=`"utf-8`"></head><body><pre id=`"o`">x</pre><script src=`"$calcUri`"></script><script>" +
        "var t=$trackingJson; var s=$siteJson; var r=GateCalc.summary(t.points,t.weightIncoming,s);" +
        "document.getElementById('o').textContent='SUM['+[r.loading,r.plan,r.weight,r.unmatched.count,r.unmatched.loading,r.unmatched.plan].map(String).join('/')+']SUM';</script></body></html>"
      $f = Join-Path $tmp ('sum-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.html'); [IO.File]::WriteAllText($f, $html, $utf8)
      $got = [regex]::Match((Edge-Dump $f), 'SUM\[(.*?)\]SUM').Groups[1].Value
      Check ("C5 $label : summary loading/plan/W/unmatched = independent sum of all points") ($got -eq $expTxt) "browser [$got] vs [$expTxt]"
      Remove-Item $f -ErrorAction SilentlyContinue
    }
    Compare-Sum 'sample site + fixture' ([IO.File]::ReadAllText((Join-Path $root 'src\web\data\tracking.sample.json'), $utf8)) $sampleSite
    # same fixture with one point renamed so it is unmatched, and weightIncoming = null
    $trU = [IO.File]::ReadAllText((Join-Path $root 'src\web\data\tracking.sample.json'), $utf8) | ConvertFrom-Json
    $trU.points[0].name = 'ZZ-NOT-IN-SITE'; $trU.weightIncoming = $null
    Compare-Sum 'fixture with an unmatched point + weightIncoming null' ($trU | ConvertTo-Json -Depth 6 -Compress) $sampleSite
    if ((Test-Path $localSite) -and (Test-Path (Join-Path $tmp 'real-tracking.json'))) {
      Compare-Sum 'REAL site.local.json + samples\tracking.html (local only)' ([IO.File]::ReadAllText((Join-Path $tmp 'real-tracking.json'), $utf8)) ([IO.File]::ReadAllText($localSite, $utf8))
    } else { Write-Host '  SKIP  C5 real (no site.local.json or samples\tracking.html)' }
  } else { Write-Host '  SKIP  C1/C2/C5 (Microsoft Edge not found)' }

  # files with real company data must be ignored; sample / code files must not be
  Push-Location $root
  try {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
      foreach ($p in 'src/web/data/site.local.json', 'src/web/data/tracking.json', 'src/web/data/tracking-parse-test.local.json', 'src/web/data/latest.json', 'samples/tracking.html', 'design/page2-site.js', 'brief.md') {
        & git check-ignore -q -- $p; Check "C3 ignored by git (never committed): $p" ($LASTEXITCODE -eq 0)
      }
      foreach ($p in 'src/web/data/site.sample.json', 'src/web/data/tracking.sample.json', 'tests/fixtures/tracking-sample.html', 'src/web/page2.html', 'src/web/js/page2.js', 'src/web/js/gate-calc.js', 'src/web/css/page2.css', 'src/wms-common.ps1', 'src/server.ps1', 'tests/fixtures/schedule-sample.json') {
        & git check-ignore -q -- $p; Check "C3 committable (not ignored): $p" ($LASTEXITCODE -ne 0)
      }
      # nothing committable may contain real building names from site.local.json, the company name or an internal IP
      $files = @(& git ls-files) + @(& git ls-files --others --exclude-standard) | Sort-Object -Unique | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) -and $_ -notmatch '\.(png|pdf)$' }
      $words = @()
      if (Test-Path $localSite) {
        $ls = [IO.File]::ReadAllText($localSite, $utf8) | ConvertFrom-Json
        $wmsNames = @($ls.pointMap.PSObject.Properties | ForEach-Object { $_.Name })   # WMS point names (e.g. Scrap) are allowed in the fixture
        foreach ($b in $ls.buildings) { foreach ($w in @($b.label, $b.name, $b.ownerText)) { if ($w -and $w.Length -ge 4 -and $w -notmatch '^W \(Weight\)$' -and $wmsNames -notcontains $w) { $words += $w } } }
        foreach ($a in $ls.areas) { if ($a.label -and $a.label.Length -ge 4 -and $a.label -notmatch '^(ลานจอด|สนาม|บ่อน้ำ|คลอง)$') { $words += $a.label } }
      }
      $words = @($words | Sort-Object -Unique)
      # real coordinates: every (x, y) pair of the local layout (buildings, parts, boundary, label/card/board anchors)
      $pairs = @()
      if (Test-Path $localSite) {
        foreach ($q in $ls.boundary) { $pairs += ,@($q[0], $q[1]) }
        foreach ($b in $ls.buildings) {
          if ($null -ne $b.x) { $pairs += ,@($b.x, $b.y) }
          foreach ($q in @($b.parts)) { if ($q) { $pairs += ,@($q[0], $q[1]) } }
          foreach ($q in @($b.boardAt, $b.labelAt)) { if ($q) { $pairs += ,@($q[0], $q[1]) } }
        }
        foreach ($cp in $ls.cardPlacement.PSObject.Properties) { if ($cp.Value.cardAt) { $pairs += ,@($cp.Value.cardAt[0], $cp.Value.cardAt[1]) } }
      }
      $pairRes = @($pairs | ForEach-Object { '(?<![\d.])' + $_[0] + '\s*,\s*' + $_[1] + '(?![\d.])' } | Sort-Object -Unique)
      $hits = @()
      foreach ($f in $files) {
        $txt = [IO.File]::ReadAllText((Join-Path $root $f), $utf8)
        foreach ($w in $words) { if ($txt.Contains($w)) { $hits += "$f contains '$w'" } }
        foreach ($re in $pairRes) { if ($txt -match $re) { $hits += "$f contains a real coordinate pair ($($Matches[0]))" } }
        if ($f -notmatch 'site\.sample\.json$' -and $txt -match '(boardAt|labelAt|labelOffset|cardAt|cardOffset)("\s*:\s*\[|`\s*\[|`?\s+x\s+)\s*-?\d') { $hits += "$f contains placement numbers ($($Matches[0]))" }        if ($txt -match '192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+') { $hits += "$f contains an IP address" }
        if ($txt -match ('T' + 'MT|ที' + 'เอ็มที')) { $hits += "$f contains the company name" }
      }
      Check ("C4 committable files ($($files.Count)) contain no real building names ($($words.Count) checked), real coordinates ($($pairRes.Count) pairs + placement values), company name or internal IP") ($hits.Count -eq 0) ($hits -join '; ')
    } else { Write-Host '  SKIP  C3/C4 (git not found)' }
  } finally { Pop-Location }

  # ------------------------------------------------------------------ Part D
  Write-Host 'Part D - P2-D truck list (server.ps1 /api/trucks, mock WMS, fictional plates)' -ForegroundColor Cyan
  $server = Join-Path $root 'src\server.ps1'
  $siteS = Join-Path $root 'src\web\data\site.sample.json'
  $trk = Join-Path $tmp 't1.json'                       # parsed fixture: 28 points with gateId
  $gid = @{}; foreach ($q in (Read-Out $trk).points) { $gid[$q.name] = [int]$q.gateId }
  $latestOk = Join-Path $tmp 'd-latest-ok.json'; [IO.File]::WriteAllText($latestOk, '{"schemaVersion":1,"status":"ok"}')
  $latestLf = Join-Path $tmp 'd-latest-lf.json'; [IO.File]::WriteAllText($latestLf, '{"schemaVersion":1,"status":"login_failed"}')
  $dataDir = Join-Path $root 'src\web\data'
  $dataBefore = @{}; foreach ($f in Get-ChildItem $dataDir -File) { $dataBefore[$f.Name] = $f.LastWriteTimeUtc }
  $script:servers = @()
  function Start-Srv([string[]]$extra) {
    $p0 = Get-Random -Minimum 40000 -Maximum 49000
    $out = Join-Path $tmp ('srv-' + $p0 + '.txt')
    $sp = Start-Process powershell -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
          "`"$server`"", '-Port', $p0, '-NoBrowser') + $extra)
    $s = @{ P = $sp; Port = $p0; Out = $out }
    $script:servers += $s
    for ($i = 0; $i -lt 50; $i++) { if ((Http "http://localhost:$p0/config.json").Code -eq 200) { break }; Start-Sleep -Milliseconds 200 }
    return $s
  }
  function Http([string]$url, [string]$method = 'GET', [hashtable]$hdr = @{}) {
    try {
      $rq = [System.Net.HttpWebRequest]::Create($url); $rq.Method = $method; $rq.Proxy = $null; $rq.Timeout = 60000; $rq.ReadWriteTimeout = 60000
      foreach ($k in $hdr.Keys) { $rq.Headers[$k] = $hdr[$k] }
      if ($method -eq 'POST') { $rq.ContentLength = 0 }
      try { $rs = $rq.GetResponse() } catch { if ($_.Exception.InnerException -and $_.Exception.InnerException.Response) { $rs = $_.Exception.InnerException.Response } else { return @{ Code = 0 } } }
      $sr = New-Object IO.StreamReader($rs.GetResponseStream(), $utf8); $txt = $sr.ReadToEnd(); $sr.Close(); $code = [int]$rs.StatusCode
      $acao = [string]$rs.Headers['Access-Control-Allow-Origin'] + [string]$rs.Headers['Access-Control-Allow-Methods'] + [string]$rs.Headers['Access-Control-Allow-Headers']; $rs.Close()
      $jj = $null; try { $jj = $txt | ConvertFrom-Json } catch { }
      return @{ Code = $code; J = $jj; Text = $txt; Cors = $acao }
    } catch { return @{ Code = 0 } }
  }
  $apiHdr = @{ 'X-WMS-Report' = '1' }                  # what page2.js sends
  function WApi($s, [string]$q = 'kind=weight') { Http ("http://localhost:$($s.Port)/api/trucks?" + $q) 'GET' $apiHdr }
  function Api($s, [string]$wh) { Http ("http://localhost:$($s.Port)/api/trucks?wh=" + [Uri]::EscapeDataString($wh)) 'GET' $apiHdr }
  function Sched-Lines { if (Test-Path $reqLog) { @(Get-Content $reqLog | Where-Object { $_ -like 'POST /wms/Report/GetRptTrackingScheduleList*' }) } else { @() } }
  function Expect-Rows([string[]]$gates, [string]$type) {
    $o = @(); foreach ($g in $gates) { $id = $gid[$g]; $n = $(if ($type -eq 'WG') { ($id % 3) + 1 } else { $id % 4 }); for ($i = 0; $i -lt $n; $i++) { $o += 'TST-' + $id + $(if ($type -eq 'WG') { 'P' } else { 'L' }) + $i } }
    return , $o
  }
  function Plates($list) { return , @(@($list) | ForEach-Object { $_.plate }) }
  $n3 = @('D8', 'D9', 'D10', 'D11', 'F4')

  # ---- sample mode: no WMS at all
  Set-Mode 'normal'
  $sS = Start-Srv @('-SiteFile', "`"$siteS`"", '-EnvFile', "`"$envGood`"")
  $r = Api $sS 'N3'
  Check 'D1 sample mode: 200, mode sample, status ok, gates from pointMap (D8, D9, D10, D11, F4)' ($r.Code -eq 200 -and $r.J.mode -eq 'sample' -and $r.J.status -eq 'ok' -and (@($r.J.gates) -join ',') -eq ($n3 -join ','))
  $allCo = (@('N3', 'N1', 'S1', 'S2') | ForEach-Object { $x = Api $sS $_; @($x.J.loading) + @($x.J.plan) } | ForEach-Object { $_.company }) -join ' '
  Check 'D1 sample mode: fictional rows (plate + company only), Thai text arrives as UTF-8' (@($r.J.plan).Count -ge 1 -and $allCo -match '[฀-๿]' -and @(@($r.J.plan)[0].PSObject.Properties).Count -eq 2)
  Check 'D1 sample mode never contacts WMS' ((Count-Req '') -eq 0)
  $r = Api $sS 'NOPE'; Check 'D2 unknown warehouse -> 404 unknown_wh' ($r.Code -eq 404 -and $r.J.status -eq 'unknown_wh')
  $r = Http "http://localhost:$($sS.Port)/api/trucks?wh=..%2Fx" 'GET' $apiHdr; Check 'D2 bad wh (path characters) -> 400' ($r.Code -eq 400)
  $r = Http "http://localhost:$($sS.Port)/api/trucks?wh=N3%0A" 'GET' $apiHdr; Check 'D2 bad wh: valid id + trailing newline -> 400 (\A..\z, not ^..$)' ($r.Code -eq 400)
  $r = Http "http://localhost:$($sS.Port)/api/trucks?wh=N%C3%A93" 'GET' $apiHdr; Check 'D2 bad wh: non-ASCII letter -> 400' ($r.Code -eq 400)
  $r = Http "http://localhost:$($sS.Port)/api/trucks?wh=N3"; Check 'D2 no X-WMS-Report header -> 403' ($r.Code -eq 403)
  $r = Http "http://localhost:$($sS.Port)/api/trucks?wh=N3" 'GET' @{ 'X-WMS-Report' = '0' }; Check 'D2 X-WMS-Report not "1" -> 403' ($r.Code -eq 403)
  $r = Http "http://localhost:$($sS.Port)/api/trucks?wh=N3" 'GET' @{ 'X-WMS-Report' = '1'; 'Sec-Fetch-Site' = 'cross-site' }; Check 'D2 Sec-Fetch-Site cross-site -> 403 even with the header' ($r.Code -eq 403)
  $r = Http "http://localhost:$($sS.Port)/api/trucks?wh=N3" 'GET' @{ 'X-WMS-Report' = '1'; 'Sec-Fetch-Site' = 'same-site' }; Check 'D2 Sec-Fetch-Site same-site (other localhost port) -> 403' ($r.Code -eq 403)
  $r = Http "http://localhost:$($sS.Port)/api/trucks?wh=N3" 'GET' @{ 'X-WMS-Report' = '1'; 'Sec-Fetch-Site' = 'same-origin' }; Check 'D2 Sec-Fetch-Site same-origin + header -> 200' ($r.Code -eq 200 -and $r.J.status -eq 'ok')
  $r = Http "http://localhost:$($sS.Port)/api/trucks?wh=N3" 'OPTIONS' @{ 'Origin' = 'http://evil.example'; 'Access-Control-Request-Method' = 'GET'; 'Access-Control-Request-Headers' = 'x-wms-report' }
  Check 'D2 OPTIONS (CORS preflight) -> not answered with 2xx, no Access-Control-* headers' ($r.Code -ge 400 -and -not $r.Cors)
  $r = Http "http://localhost:$($sS.Port)/api/trucks?wh=N3" 'GET' @{ 'X-WMS-Report' = '1'; 'Origin' = 'http://evil.example' }; Check 'D2 no Access-Control-Allow-Origin on a normal answer either' ($r.Code -eq 200 -and -not $r.Cors)
  $r = Http "http://localhost:$($sS.Port)/api/trucks?wh=N3" 'POST'; Check 'D2 POST /api/trucks -> 405' ($r.Code -eq 405)
  $r = Http "http://localhost:$($sS.Port)/page2.html"; Check 'D2 static files still served (page2.html 200, has the truck panel)' ($r.Code -eq 200 -and $r.Text -match 'id="pop"')
  $r = Http "http://localhost:$($sS.Port)/.env"; Check 'D2 .env still never served' ($r.Code -eq 404)
  $r = WApi $sS
  Check 'W1 W board, sample mode: ?kind=weight -> kind weight, one group "weight" of fictional rows, no WMS request' ($r.Code -eq 200 -and $r.J.mode -eq 'sample' -and $r.J.kind -eq 'weight' -and $r.J.status -eq 'ok' -and @($r.J.weight).Count -ge 1 -and @($r.J.loading).Count -eq 0 -and (Count-Req '') -eq 0)
  $r = WApi $sS 'kind=Weight'; Check 'W1 kind other than "weight" -> 400' ($r.Code -eq 400)
  $r = WApi $sS 'kind=weight&wh=N3'; Check 'W1 kind=weight together with wh -> 400' ($r.Code -eq 400)
  $r = Http "http://localhost:$($sS.Port)/api/trucks?kind=weight"; Check 'W1 kind=weight without X-WMS-Report header -> 403' ($r.Code -eq 403)
  $r = Api $sS 'W'; Check 'W1 a warehouse called "W" stays a warehouse (?wh=W is not the W board; sample site has no points for it -> unknown_wh)' ($r.J.status -eq 'unknown_wh' -and $r.J.kind -ne 'weight')

  # ---- live mode against the mock WMS
  $live1 = @('-Live', '-SiteFile', "`"$siteS`"", '-TrackingFile', "`"$trk`"", '-LatestFile', "`"$latestOk`"", '-WmsTimeoutSec', '3')
  $sL = Start-Srv ($live1 + @('-EnvFile', "`"$envGood`""))
  Set-Mode 'normal'
  $r = Api $sL 'N3'
  Check 'D3 live: status ok, mode live, no failed gates' ($r.J.status -eq 'ok' -and $r.J.mode -eq 'live' -and @($r.J.failedGates).Count -eq 0) $r.Text
  Check 'D3 "กำลังขึ้น" = type '''' rows of all 5 gates, in gate order then WMS order' (((Plates $r.J.loading) -join ',') -eq ((Expect-Rows $n3 '') -join ','))
  Check 'D3 "Plan" = type ''WG'' rows of all 5 gates' (((Plates $r.J.plan) -join ',') -eq ((Expect-Rows $n3 'WG') -join ','))
  $expSeq = @(); foreach ($g in $n3) { $expSeq += "gate=$($gid[$g]) type="; $expSeq += "gate=$($gid[$g]) type=WG" }
  $gotSeq = @(Sched-Lines | ForEach-Object { $_ -replace '^POST /wms/Report/GetRptTrackingScheduleList ', '' })
  Check 'D3 exactly 1 login + 10 schedule POSTs (5 gates x 2 types), one at a time in gate order, body accepted by the mock (JSON like the WMS page)' ((Count-Req 'POST /wms/user/login') -eq 1 -and ($gotSeq -join '|') -eq ($expSeq -join '|')) ($gotSeq -join '|')
  Check 'D3 no other WMS page requested (only login + GetRptTrackingScheduleList)' ((Count-Req '') -eq 12 -and (Count-Req 'GET /wms/user/login') -eq 1)
  $co = @($r.J.loading) + @($r.J.plan) | Where-Object { $_.company -like 'Demo <b>&</b>*' }
  Check 'D3 company text passed through as text (HTML characters not altered by the server; the page escapes them)' (@($co).Count -ge 1)
  $first = $r.J.fetchedAt
  Set-Mode 'normal'
  $r = Api $sL 'N3'
  Check 'D4 same warehouse again within 10 s -> same answer from memory, no WMS request' ($r.J.fetchedAt -eq $first -and (Count-Req '') -eq 0)
  $r = Api $sL 'S1'
  Check 'D5 next warehouse reuses the session (no new login), 10 schedule calls' ($r.J.status -eq 'ok' -and (Count-Req 'POST /wms/user/login') -eq 0 -and @(Sched-Lines).Count -eq 10)
  Set-Mode 'normal'
  $r = WApi $sL
  Check 'W2 live W board: exactly 1 WMS request (gateId 0, type W), rows in WMS order, no tracking gateId needed' ($r.J.kind -eq 'weight' -and $r.J.status -eq 'ok' -and ((Plates $r.J.weight) -join ',') -eq 'TST-0W0,TST-0W1,TST-0W2' -and
    (@(Sched-Lines) -join '|') -eq 'POST /wms/Report/GetRptTrackingScheduleList gate=0 type=W' -and (Count-Req '') -eq 1) $r.Text
  $wAt = $r.J.fetchedAt; Set-Mode 'normal'
  $r = WApi $sL
  Check 'W2 W board again within 10 s -> same answer from memory, no WMS request' ($r.J.fetchedAt -eq $wAt -and (Count-Req '') -eq 0)

  $failGate = Join-Path $state 'failgate.txt'
  [IO.File]::WriteAllText($failGate, [string]$gid['A2']); Set-Mode 'sched500'
  $r = Api $sL 'N2'
  Check 'D6 one gate HTTP 500 -> partial, failedGates [A2], rows of the other gates kept' ($r.J.status -eq 'partial' -and (@($r.J.failedGates) -join ',') -eq 'A2' -and ((Plates $r.J.plan) -join ',') -eq ((Expect-Rows @('A1', 'A6', 'B', 'E') 'WG') -join ','))
  $pAt = $r.J.fetchedAt; Set-Mode 'sched500'
  $r = Api $sL 'N2'
  Check 'D6 a partial answer is reused for 10 s (same answer, no WMS request)' ($r.J.status -eq 'partial' -and $r.J.fetchedAt -eq $pAt -and (Count-Req '') -eq 0)
  [IO.File]::WriteAllText($failGate, [string]$gid['K4']); Set-Mode 'schedbad'
  $r = Api $sL 'S2'
  Check 'D7 one gate answers HTML instead of JSON -> partial, failedGates [K4] (never guessed)' ($r.J.status -eq 'partial' -and (@($r.J.failedGates) -join ',') -eq 'K4')
  [IO.File]::WriteAllText($failGate, [string]$gid['M8']); Set-Mode 'schedslow'
  $t0 = Get-Date
  $r = Api $sL 'S3'
  $secs = ((Get-Date) - $t0).TotalSeconds
  Check ('D8 one gate slower than the timeout -> partial, failedGates [M8], other gates ok (' + [Math]::Round($secs, 1) + ' s)') ($r.J.status -eq 'partial' -and (@($r.J.failedGates) -join ',') -eq 'M8' -and $secs -lt 20) $r.Text
  Remove-Item $failGate
  Set-Mode 'schedexpire'
  $r = Api $sL 'N1'
  Check 'D9 session expired -> exactly one new login -> ok' ($r.J.status -eq 'ok' -and (Count-Req 'POST /wms/user/login') -eq 1 -and @(Sched-Lines).Count -eq 9) $r.Text

  $sW = Start-Srv ($live1 + @('-EnvFile', "`"$envGood`""))
  [IO.File]::WriteAllText((Join-Path $state 'failgate.txt'), '0'); Set-Mode 'sched500'
  $r = WApi $sW
  Check 'W3 W board, WMS answers 500 -> error (1 login, 1 call)' ($r.J.kind -eq 'weight' -and $r.J.status -eq 'error' -and (Count-Req 'POST /wms/user/login') -eq 1 -and @(Sched-Lines).Count -eq 1)
  Set-Mode 'sched500'
  $r = WApi $sW
  Check 'W3 W board failure is not reused: asked again -> WMS called again (session reused, 1 call)' ($r.J.status -eq 'error' -and (Count-Req 'POST /wms/user/login') -eq 0 -and @(Sched-Lines).Count -eq 1)
  Remove-Item (Join-Path $state 'failgate.txt')
  $sL2 = Start-Srv ($live1 + @('-EnvFile', "`"$envGood`""))
  Set-Mode 'schedlogin'
  $r = Api $sL2 'N3'
  Check 'D10 WMS keeps answering the login page -> status session, stops at once (1 login, 1 schedule call)' ($r.J.status -eq 'session' -and (Count-Req 'POST /wms/user/login') -eq 1 -and @(Sched-Lines).Count -eq 1) $r.Text
  Set-Mode 'schedlogin'
  $r = Api $sL2 'N3'
  Check 'D10 a failure is NOT reused: same warehouse again within 10 s -> asks WMS again (1 login, 1 call)' ($r.J.status -eq 'session' -and (Count-Req 'POST /wms/user/login') -eq 1 -and @(Sched-Lines).Count -eq 1)

  $sB = Start-Srv ($live1 + @('-EnvFile', "`"$envBad`""))
  Set-Mode 'normal'
  $r = Api $sB 'N3'
  Check 'D11 wrong password -> login_failed after exactly 1 login attempt, no schedule call' ($r.J.status -eq 'login_failed' -and (Count-Req 'POST /wms/user/login') -eq 1 -and @(Sched-Lines).Count -eq 0)
  Set-Mode 'normal'
  $r = Api $sB 'N1'
  Check 'D11 after login_failed: no more login attempts (no request at all) until the server is restarted' ($r.J.status -eq 'login_failed' -and (Count-Req '') -eq 0)
  $r = WApi $sB
  Check 'W4 W board after login_failed -> login_failed, no request' ($r.J.kind -eq 'weight' -and $r.J.status -eq 'login_failed' -and (Count-Req '') -eq 0)

  $sF = Start-Srv @('-Live', '-SiteFile', "`"$siteS`"", '-TrackingFile', "`"$trk`"", '-LatestFile', "`"$latestLf`"", '-EnvFile', "`"$envGood`"")
  Set-Mode 'normal'
  $r = Api $sF 'N3'
  Check 'D12 fetcher is at login_failed (latest.json) -> login_failed, no request (protects the account)' ($r.J.status -eq 'login_failed' -and (Count-Req '') -eq 0)
  $sG = Start-Srv @('-Live', '-SiteFile', "`"$siteS`"", '-TrackingFile', "`"$(Join-Path $root 'src\web\data\tracking.sample.json')`"", '-LatestFile', "`"$latestOk`"", '-EnvFile', "`"$envGood`"")
  $r = Api $sG 'N3'
  Check 'D13 tracking.json has no gateId yet (old fetcher) -> error no_gate_ids, no request' ($r.J.status -eq 'error' -and $r.J.message -eq 'no_gate_ids' -and (Count-Req '') -eq 0)
  $sE = Start-Srv ($live1 + @('-EnvFile', "`"$(Join-Path $tmp 'missing.env')`""))
  $r = Api $sE 'N3'
  Check 'D14 no .env -> login_failed (env_missing), no request' ($r.J.status -eq 'login_failed' -and $r.J.message -eq 'env_missing' -and (Count-Req '') -eq 0)

  # ---- page: open the panel in Edge headless (sample mode, the site file the page itself uses)
  if ($edge) {
    $siteP = Join-Path $dataDir 'site.local.json'; if (-not (Test-Path $siteP)) { $siteP = $siteS }
    $pm = ([IO.File]::ReadAllText($siteP, $utf8) | ConvertFrom-Json).pointMap
    $trS = Read-Out (Join-Path $dataDir 'tracking.sample.json')
    $sP = Start-Srv @('-EnvFile', "`"$envGood`"")
    # a warehouse whose (fictional) sample rows include the company name with HTML characters <b>&"
    $evil = 'Demo <b>&</b> "Quote" Cargo'
    $whP = $null; $api = $null
    foreach ($q in $trS.points) {
      $v = [string]$pm.($q.name); if (-not $v) { continue }
      $a0 = Api $sP $v
      if ($null -eq $whP) { $whP = $v; $api = $a0 }
      if ((@($a0.J.loading) + @($a0.J.plan) | Where-Object { $_.company -like "$evil*" })) { $whP = $v; $api = $a0; break }
    }
    function Edge-Url([string]$url, [int]$budgetMs) {
      $prof = Join-Path $tmp 'edge-profile-d'
      $so = Join-Path $tmp ('edge-d-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
      Start-Process -FilePath $edge -ArgumentList @('--headless', '--disable-gpu', '--no-first-run', "--user-data-dir=`"$prof`"", '--window-size=1920,1080',
        "--virtual-time-budget=$budgetMs", '--dump-dom', $url) -Wait -NoNewWindow -RedirectStandardOutput $so -RedirectStandardError ($so + '.err')
      return [IO.File]::ReadAllText($so, $utf8)
    }
    $dom = Edge-Url "http://localhost:$($sP.Port)/page2.html#open=$whP" 8000
    $popTag = [regex]::Match($dom, '<aside class="pop"[^>]*>').Value
    $plates = @([regex]::Matches($dom, '<span class="plate">([^<]*)</span>') | ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value) })
    $expP = @(@($api.J.loading) + @($api.J.plan) | ForEach-Object { $_.plate })
    Check 'D15 page: panel opens (not hidden), sample bar shown, plates = API answer in the same order' ($popTag -and $popTag -notmatch '\bhidden\b' -and $dom -match 'ข้อมูลตัวอย่าง — ทะเบียน' -and ($plates -join ',') -eq ($expP -join ',') -and $plates.Count -ge 1) "plates $($plates -join ',') vs $($expP -join ',')"
    Check 'D15 page: groups "กำลังขึ้น" then "Plan", columns External ID + Company Name only' ($dom -match '(?s)class="sec-h">.*?กำลังขึ้น.*class="sec-h">.*?Plan' -and $dom -match 'External ID \(ทะเบียน\)</span><span>Company Name</span></div>' -and $dom -notmatch 'ShipmentCode|Forwarding')
    $evilFull = @(@($api.J.loading) + @($api.J.plan) | Where-Object { $_.company -like "$evil*" } | ForEach-Object { $_.company })[0]
    $tm = [regex]::Match($dom, '<span class="co" title="(Demo [^"]*)">([^<]*)</span>')
    Check 'D15 page: company name with <b>&" is shown as text (escaped), not as HTML' ($evilFull -and $tm.Success -and
      [System.Net.WebUtility]::HtmlDecode($tm.Groups[2].Value) -eq $evilFull -and [System.Net.WebUtility]::HtmlDecode($tm.Groups[1].Value) -eq $evilFull -and
      $tm.Groups[2].Value -like 'Demo &lt;b&gt;&amp;&lt;/b&gt;*' -and $dom -notmatch '>Demo <b>') "found: $($tm.Value)"
    $dom2 = Edge-Url "http://localhost:$($sP.Port)/page2.html#open=$whP" 75000
    $popTag2 = [regex]::Match($dom2, '<aside class="pop"[^>]*>').Value
    Check 'D16 page: nobody touches the screen for 60 s -> panel closes and its list is cleared' ($popTag2 -match '\bhidden\b' -and $dom2 -notmatch '<span class="plate">')
    $wapi = WApi $sP
    $dom3 = Edge-Url "http://localhost:$($sP.Port)/page2.html#open=weight" 8000
    $pop3 = [regex]::Match($dom3, '<aside class="pop"[^>]*>').Value
    $plates3 = @([regex]::Matches($dom3, '<span class="plate">([^<]*)</span>') | ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value) })
    $secs3 = @([regex]::Matches($dom3, 'class="sec-h">'))
    Check 'W5 page: W board panel opens ("W · Weight", one group "Weight Final", no gate line), plates = API answer' ($pop3 -and $pop3 -notmatch '\bhidden\b' -and
      $dom3 -match 'id="popTitle"[^>]*>W · Weight<' -and $secs3.Count -eq 1 -and $dom3 -match 'class="sec-h">.*?Weight Final' -and $dom3 -match 'id="popSub"[^>]*hidden' -and
      ($plates3 -join ',') -eq ((@($wapi.J.weight) | ForEach-Object { $_.plate }) -join ',') -and $plates3.Count -ge 1) "plates $($plates3 -join ',')"

    # P2-E summary card on the real page (sample mode, 1920x1080)
    $sumLd = 0; $sumPl = 0; foreach ($q in $trS.points) { $sumLd += $q.loading; $sumPl += $q.plan }
    $sumW = $trS.weightIncoming.final
    function Sum-Num([string]$d, [string]$id) { $m = [regex]::Match($d, 'id="' + $id + '"[^>]*><b>(\d+)</b><span class="u">'); if ($m.Success) { [int]$m.Groups[1].Value } else { $null } }
    $dS = Edge-Url "http://localhost:$($sP.Port)/page2.html" 8000
    Check "S1 page summary (sample): กำลังขึ้น = sum of all loading ($sumLd), Plan = sum of all plan ($sumPl), W = weightIncoming.final ($sumW)" ((Sum-Num $dS 'sumLd') -eq $sumLd -and (Sum-Num $dS 'sumPl') -eq $sumPl -and (Sum-Num $dS 'sumW') -eq $sumW -and
      $dS -match 'class="panel sum"' -and $dS -match 'id="sumStale"[^>]*hidden' -and $dS -match 'id="sumNa"[^>]*hidden') ("got " + (Sum-Num $dS 'sumLd') + '/' + (Sum-Num $dS 'sumPl') + '/' + (Sum-Num $dS 'sumW'))
    Check 'S2 summary sits above the side cards, truck panel is inside .rbody (cannot cover the summary)' ($dS -match '(?s)<div class="rcol">\s*<!--[^>]*-->\s*<section class="panel sum".*?<div class="rbody">\s*<aside class="side">.*?<aside class="pop"')
    $dSt = Edge-Url "http://localhost:$($sP.Port)/page2.html#preview=stale" 8000
    $hm = ([DateTimeOffset]::Parse($trS.lastSuccessAt)).ToLocalTime().ToString('HH:mm')
    Check "S3 stale: numbers kept but dimmed + 'ข้อมูลเก่า ณ $hm น.'" ($dSt -match 'class="panel sum dim"' -and $dSt -match ('id="sumStale"[^>]*>ข้อมูลเก่า ณ ' + $hm + ' น\.<') -and (Sum-Num $dSt 'sumLd') -eq $sumLd)
    $dPa = Edge-Url "http://localhost:$($sP.Port)/page2.html#preview=parse" 8000
    $dash = @([regex]::Matches($dPa, '<b class="na" aria-label="ไม่มีข้อมูล">–</b>')).Count
    Check 'S4 no usable data (parse): "–" for all 3 numbers (never 0), note "ยังไม่มีข้อมูลที่ใช้ได้" shown' ($dash -eq 3 -and $dPa -notmatch 'id="sumNa"[^>]*hidden' -and $null -eq (Sum-Num $dPa 'sumLd') -and $dPa -match 'id="sumUnm"[^>]*hidden') "dashes $dash"
  } else { Write-Host '  SKIP  D15/D16 (Microsoft Edge not found)' }

  foreach ($s in $script:servers) { try { Stop-Process -Id $s.P.Id -Force } catch { } }
  Start-Sleep -Milliseconds 500
  $srvText = ($script:servers | ForEach-Object { if (Test-Path $_.Out) { [IO.File]::ReadAllText($_.Out, $utf8) } }) -join "`n"
  Check 'D17 server console: one line per click like "trucks wh=N3 gates=5 ok n=..."' ($srvText -match 'trucks wh=N3 gates=5 ok n=\d+' -and $srvText -match 'trucks wh=N2 gates=5 partial n=\d+ failed=1' -and $srvText -match 'trucks kind=weight ok n=3')
  Check 'D17 server console never shows plates, company names, password or the WMS address' ($srvText -notmatch 'TST-|Freight|Haulage|ตัวอย่างขนส่ง|test-pass|wrong-pass|testuser|/wms')
  $leak = @(Get-ChildItem $tmp -Recurse -File | Where-Object { $_.FullName -notlike "$state*" -and $_.Name -notlike 'edge-*' -and $_.FullName -notlike '*edge-profile*' } |
    Where-Object { ([IO.File]::ReadAllText($_.FullName, $utf8)) -match 'TST-\d' })
  Check 'D18 server writes no plate to any file (only the mock request log / the page dump of this test have them)' ($leak.Count -eq 0) (($leak | ForEach-Object { $_.Name }) -join ', ')
  $changed = @(Get-ChildItem $dataDir -File | Where-Object { $_.Name -notin @('latest.json', 'tracking.json') -and $_.Name -notlike '*.tmp' -and
    (-not $dataBefore.ContainsKey($_.Name) -or $dataBefore[$_.Name] -ne $_.LastWriteTimeUtc) })
  Check 'D18 nothing new or changed in src\web\data (truck lists are never cached on disk)' ($changed.Count -eq 0) (($changed | ForEach-Object { $_.Name }) -join ', ')
}
finally {
  foreach ($s in @($script:servers)) { try { Stop-Process -Id $s.P.Id -Force -ErrorAction SilentlyContinue } catch { } }
  if ($mock) { try { Stop-Process -Id $mock.Id -Force } catch { } }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host ("Result: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $script:fail
