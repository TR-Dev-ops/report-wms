<#
  run-tests.ps1 - offline tests for src\fetch-wms.ps1 (never contacts the real WMS, never reads the real .env)
    Part A: parser  - tests\fixtures\report-sample.html (+ broken variants) via -HtmlFile
            (+ src\web\data\screenshot.local.json and any samples\*.html if present on this computer)
    Part B: live flow against tests\mock-wms.ps1 on localhost (fake user testuser / test-pass)
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
$script:pass = 0; $script:fail = 0

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
          "`"$(Join-Path $PSScriptRoot 'mock-wms.ps1')`"", '-Port', $port, '-StateDir', "`"$state`"", '-ReportHtml', "`"$fixture`"")
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
  Check 'B1 exactly 1 login POST, 1 report GET' ((Count-Req 'POST /wms/user/login') -eq 1 -and (Count-Req 'GET /wms/Report') -eq 1)
  Check 'B1 no .tmp left behind' (-not (Test-Path ($live + '.tmp')))
  $histFiles = @(Get-ChildItem (Join-Path $tmp 'logs') -Filter 'history-*.local.jsonl' -ErrorAction SilentlyContinue)
  $histLines = @(); if ($histFiles.Count -eq 1) { $histLines = @(Get-Content $histFiles[0].FullName -Encoding UTF8 | Where-Object { $_ }) }
  $h0 = $null; try { $h0 = $histLines[0] | ConvertFrom-Json } catch { }
  Check 'B1 history: 1 JSONL line with fetchedAt, reportDate, total, 17 rows' ($histLines.Count -eq 1 -and $h0 -and $h0.fetchedAt -eq $j.lastSuccessAt -and $h0.reportDate -eq $j.reportDate -and @($h0.rows).Count -eq 17 -and [decimal]$h0.total.weightKg -eq [decimal]$j.total.weightKg)
  $okAt = $j.lastSuccessAt

  $code = Run-Fetch @('-Once', '-EnvFile', $envDown, '-OutFile', $live, '-TimeoutSec', '5'); $j = Read-Out $live
  Check ('B2 WMS unreachable -> fetch_error, failures 1 -> ' + $j.message) ($code -eq 1 -and $j.status -eq 'fetch_error' -and $j.consecutiveFailures -eq 1)
  Check 'B2 last good rows + lastSuccessAt kept' (@($j.rows).Count -eq 17 -and $j.lastSuccessAt -eq $okAt -and $j.lastAttemptAt)
  Check 'B2 message has no URL/host' ($j.message -notmatch 'localhost|http|:\d{2,5}')
  $code = Run-Fetch @('-Once', '-EnvFile', $envDown, '-OutFile', $live, '-TimeoutSec', '5'); $j = Read-Out $live
  Check 'B2 second failure -> consecutiveFailures 2' ($j.consecutiveFailures -eq 2)
  Check 'B2 failures add no history line' (@(Get-Content $histFiles[0].FullName | Where-Object { $_ }).Count -eq 1)

  Set-Mode 'report500'
  $code = Run-Fetch @('-Once', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live
  Check ('B3 report HTTP 500 -> fetch_error, failures 3 -> ' + $j.message) ($code -eq 1 -and $j.status -eq 'fetch_error' -and $j.consecutiveFailures -eq 3 -and @($j.rows).Count -eq 17)
  Set-Mode 'normal'
  $code = Run-Fetch @('-Once', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live
  Check 'B3 recovery -> ok, failures reset to 0' ($code -eq 0 -and $j.status -eq 'ok' -and $j.consecutiveFailures -eq 0)

  Set-Mode 'reportbroken'
  $code = Run-Fetch @('-Once', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live
  Check ('B4 report page changed -> parse_error -> ' + $j.message) ($code -eq 3 -and $j.status -eq 'parse_error')

  Set-Mode 'loginchanged'
  $code = Run-Fetch @('-Once', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live
  Check ('B5 login form changed -> parse_error, password NOT sent -> ' + $j.message) ($code -eq 3 -and $j.status -eq 'parse_error' -and (Count-Req 'POST') -eq 0)

  Set-Mode 'expire2nd'
  $code = Run-Fetch @('-Cycles', '2', '-IntervalSec', '1', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live
  Check 'B6 session expired -> one re-login -> ok' ($code -eq 0 -and $j.status -eq 'ok' -and (Count-Req 'POST /wms/user/login') -eq 2 -and (Count-Req 'GET /wms/Report') -eq 3)

  Set-Mode 'expire2nd-reject'
  $code = Run-Fetch @('-Cycles', '5', '-IntervalSec', '1', '-EnvFile', $envGood, '-OutFile', $live); $j = Read-Out $live
  Check ('B7 session expired + re-login rejected -> login_failed, stops -> ' + $j.message) ($code -eq 2 -and $j.status -eq 'login_failed' -and (Count-Req 'POST /wms/user/login') -eq 2 -and (Count-Req 'GET /wms/Report') -eq 2)
  Check 'B7 rows kept for display' (@($j.rows).Count -eq 17)

  Set-Mode 'normal'
  Start-Sleep -Seconds 1
  (Get-Item $envBad).LastWriteTime = Get-Date      # "owner edits .env" (with a wrong password)
  $code = Run-Fetch @('-Cycles', '3', '-IntervalSec', '1', '-EnvFile', $envBad, '-OutFile', $live); $j = Read-Out $live
  Check ('B8 wrong password -> login_failed, exactly 1 attempt, no retry -> ' + $j.message) ($code -eq 2 -and $j.status -eq 'login_failed' -and (Count-Req 'POST') -eq 1 -and (Count-Req 'GET /wms/Report') -eq 0)

  Set-Mode 'normal'
  $code = Run-Fetch @('-Cycles', '1', '-EnvFile', $envBad, '-OutFile', $live)
  Check 'B9 restart without editing .env -> blocked, no request at all' ($code -eq 2 -and (Count-Req '') -eq 0 -and (Read-Out $live).status -eq 'login_failed')

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
}
finally {
  if ($mock) { try { Stop-Process -Id $mock.Id -Force } catch { } }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host ("Result: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $script:fail
