<#
  fetch-wms.ps1 - Phase 2 fetcher for wms-realtime-report (Windows PowerShell 5.1, nothing to install)

  What it does (read-only):
    1. reads WMS_BASE_URL / WMS_USERNAME / WMS_PASSWORD from ..\.env (never logged, never written anywhere)
    2. logs in to WMS (form POST <base>/user/login), keeps the session cookie in memory only
    3. GETs <base>/Report/ReportShipmentSumByProduct and parses the table
       "Outbound the amount of work each day" (17 hourly rows + Total)
    4. writes web\data\latest.json (README section 3) via latest.json.tmp + rename
    5. repeats every config.json refreshMinutes (min 1)

  Safety rules:
    - login rejected            -> status login_failed, STOP (no retry; protects the account from lock-out)
    - session expired           -> log in again ONCE; still rejected -> login_failed, STOP
    - table missing / changed   -> status parse_error (numbers are never guessed)
    - network / timeout / 5xx   -> status fetch_error, consecutiveFailures + 1, keep last good rows
    - only two URLs are ever requested: the login page and the report page. Redirects are never followed.
    - the log (..\logs\) never contains the password, cookies, the WMS address or page HTML

  Usage:
    powershell -ExecutionPolicy Bypass -File fetch-wms.ps1                 # loop (normally via start-live.cmd)
    powershell -ExecutionPolicy Bypass -File fetch-wms.ps1 -Once           # one cycle, exit code = status
    powershell -ExecutionPolicy Bypass -File fetch-wms.ps1 -HtmlFile x.html [-OutFile y.json]
                                                                           # parser test only: no network, no .env
    -ResetLogin : allow a new login attempt after login_failed even if .env was not edited
    Exit codes (-Once / -HtmlFile): 0 ok, 1 fetch_error, 2 login_failed (or blocked), 3 parse_error, 4 bad arguments
#>
param(
  [switch]$Once,
  [string]$HtmlFile,
  [string]$OutFile,
  [string]$EnvFile,
  [switch]$ResetLogin,
  [int]$TimeoutSec = 30,
  [string]$LogDir,          # default ..\logs
  [int]$Cycles = 0,         # tests only: stop after N cycles (0 = run until closed)
  [int]$IntervalSec = 0     # tests only: seconds between cycles instead of config refreshMinutes
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }   # Thai messages in the window

$ProjectRoot = Split-Path $PSScriptRoot -Parent
$WebRoot     = Join-Path $PSScriptRoot 'web'
$ConfigPath  = Join-Path $WebRoot 'config.json'
if (-not $LogDir) { $LogDir = Join-Path $ProjectRoot 'logs' }
if (-not $EnvFile) { $EnvFile = Join-Path $ProjectRoot '.env' }
if (-not $OutFile) {
  if ($HtmlFile) { $OutFile = Join-Path $WebRoot 'data\parse-test.local.json' }   # never overwrite live data in test mode
  else           { $OutFile = Join-Path $WebRoot 'data\latest.json' }
}
$Inv  = [System.Globalization.CultureInfo]::InvariantCulture
$Utf8 = New-Object System.Text.UTF8Encoding($false)
# PS 5.1 quirk: arrays can serialize as {"value":[..],"Count":n}; remove the extra type data
Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue

$PERIODS = @(7..23 | ForEach-Object { '{0:00}:01-{1:00}:00' -f $_, ($_ + 1) })
$TITLE_RE = 'Outbound\s+the\s+amount\s+of\s+work\s+each\s+day'
# header words in table order (Period | Workload % | Outbound: Weight, Complete, Remaining, Complete % | Truck: Check in, Outbound, Complete, Remaining, Complete %)
$HEADER_RE = '(?s)Period.*Workload.*Outbound.*Truck.*Weight.*Complete.*Remaining.*Complete.*Check\s*in.*Outbound.*Complete.*Remaining.*Complete'
$FIELDS = 'workloadPct','weightKg','completeKg','remainingKg','completePct','truckCheckIn','truckOutbound','truckComplete','truckRemaining','truckCompletePct'
$INT_FIELDS = 'truckCheckIn','truckOutbound','truckComplete','truckRemaining'
$KG_TOLERANCE = [decimal]0.01

# ---------------------------------------------------------------- helpers
function Get-NowIso { [DateTimeOffset]::Now.ToString("yyyy-MM-dd'T'HH:mm:sszzz", $Inv) }

function Write-Log([string]$msg) {
  $line = '{0}  {1}' -f [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss', $Inv), $msg
  Write-Host $line
  try {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $f = Join-Path $LogDir ('fetch-{0}.log' -f [DateTime]::Now.ToString('yyyy-MM-dd', $Inv))
    [System.IO.File]::AppendAllText($f, $line + "`r`n", $Utf8)
  } catch { }
}

function Read-EnvFile([string]$path) {
  $vals = @{}
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  foreach ($raw in [System.IO.File]::ReadAllLines($path, $Utf8)) {
    $line = $raw.TrimStart()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    $eq = $line.IndexOf('=')
    if ($eq -lt 1) { continue }
    $key = $line.Substring(0, $eq).Trim()
    $val = $line.Substring($eq + 1)
    if ($key -ne 'WMS_PASSWORD') { $val = $val.Trim() }
    if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'")))) {
      $val = $val.Substring(1, $val.Length - 2)
    }
    $vals[$key] = $val
  }
  return $vals
}

function Get-RefreshMinutes {
  try {
    $cfg = [System.IO.File]::ReadAllText($ConfigPath, $Utf8) | ConvertFrom-Json
    $m = [double]$cfg.refreshMinutes
    if ($m -ge 1) { return $m }
    if ($m -gt 0) { return 1 }        # brief 9.5: never more often than every 1 minute
  } catch { }
  return 5
}

function Read-Previous([string]$path) {
  try {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $p = [System.IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json
    if ($p.schemaVersion -eq 1) { return $p }
  } catch { }
  return $null
}

# History for later analysis (which forecast is more accurate): one JSON line per successful fetch
#   <LogDir>\history-YYYY-MM-DD.local.jsonl  (real company data -> gitignored)
#   {"fetchedAt": ISO time, "reportDate": "YYYY-MM-DD", "total": {...}, "rows": [17 hourly rows]}
#   no host, cookie, user or password. A failure here never affects latest.json.
function Add-History($result) {
  try {
    $line = [pscustomobject][ordered]@{
      fetchedAt = $result.lastSuccessAt; reportDate = $result.reportDate
      total = $result.total; rows = $result.rows
    } | ConvertTo-Json -Depth 6 -Compress
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $f = Join-Path $LogDir ('history-{0}.local.jsonl' -f [DateTime]::Now.ToString('yyyy-MM-dd', $Inv))
    [System.IO.File]::AppendAllText($f, $line + "`n", $Utf8)
  } catch {
    Write-Log ('history: could not append (' + $_.Exception.GetType().Name + ') - latest.json is fine')
  }
}

function Save-Json($obj, [string]$path) {
  $json = ConvertTo-Json -InputObject $obj -Depth 6
  $dir = Split-Path $path -Parent
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $tmp = $path + '.tmp'
  [System.IO.File]::WriteAllText($tmp, $json, $Utf8)
  for ($i = 1; $i -le 5; $i++) {
    try {
      if (Test-Path -LiteralPath $path) { [System.IO.File]::Replace($tmp, $path, [NullString]::Value) }
      else { [System.IO.File]::Move($tmp, $path) }
      return
    } catch {
      if ($i -eq 5) { throw }
      Start-Sleep -Milliseconds 300          # the web server may be reading the file right now
    }
  }
}

# Build the latest.json object. On failure keep rows / total / lastSuccessAt from the previous good file.
function New-Result([string]$status, [string]$message, $prev, $rows, $total, [string]$note = '') {
  $now = Get-NowIso
  if ($status -eq 'ok') {
    return [pscustomobject][ordered]@{
      schemaVersion = 1; source = 'wms'; note = $note
      reportDate = [DateTime]::Now.ToString('yyyy-MM-dd', $Inv)
      status = 'ok'; message = ''
      lastAttemptAt = $now; lastSuccessAt = $now; consecutiveFailures = 0
      rows = @($rows); total = $total
    }
  }
  $hasPrev = $null -ne $prev -and $prev.source -eq 'wms' -and $null -ne $prev.rows
  $fails = 1
  if ($hasPrev -and $null -ne $prev.consecutiveFailures) { $fails = [int]$prev.consecutiveFailures + 1 }
  $keepRows = New-Object System.Collections.ArrayList          # stays a JSON array even when empty
  if ($hasPrev) { foreach ($r in $prev.rows) { [void]$keepRows.Add($r) } }
  return [pscustomobject][ordered]@{
    schemaVersion = 1; source = 'wms'; note = $note
    reportDate = $(if ($hasPrev -and $prev.reportDate) { [string]$prev.reportDate } else { [DateTime]::Now.ToString('yyyy-MM-dd', $Inv) })
    status = $status; message = $message
    lastAttemptAt = $now
    lastSuccessAt = $(if ($hasPrev) { $prev.lastSuccessAt } else { $null })
    consecutiveFailures = $fails
    rows = $keepRows
    total = $(if ($hasPrev) { $prev.total } else { $null })
  }
}

# ---------------------------------------------------------------- parser
function Get-CellText([string]$h) {
  $t = $h -replace '(?s)<!--.*?-->', ' ' -replace '<[^>]*>', ' '
  $t = [System.Net.WebUtility]::HtmlDecode($t)
  return ($t -replace '[\s\u00A0\u200B]+', ' ').Trim()
}

function Split-Rows([string]$tableHtml) {
  # tolerant of missing </tr> / </td>
  $rows = @()
  $chunks = [regex]::Split($tableHtml, '(?i)<tr\b')
  for ($i = 1; $i -lt $chunks.Count; $i++) {
    $c = $chunks[$i]
    $end = $c.IndexOf('</tr', [System.StringComparison]::OrdinalIgnoreCase)
    if ($end -ge 0) { $c = $c.Substring(0, $end) }
    $gt = $c.IndexOf('>'); if ($gt -lt 0) { continue }
    $c = $c.Substring($gt + 1)
    $cells = @()
    $parts = [regex]::Split($c, '(?i)<t[dh]\b')
    for ($j = 1; $j -lt $parts.Count; $j++) {
      $p = $parts[$j]; $g = $p.IndexOf('>'); if ($g -lt 0) { continue }
      $cells += , (Get-CellText $p.Substring($g + 1))
    }
    $rows += , @($cells)
  }
  return , $rows
}

function ConvertTo-Num([string]$text, [bool]$integer) {
  $t = $text -replace ',', ''
  if ($integer) { if ($t -notmatch '^\d+$') { return $null } }
  elseif ($t -notmatch '^-?\d+(\.\d+)?$') { return $null }
  return [decimal]::Parse($t, $Inv)
}

# Returns @{ ok = $true; rows; total } or @{ ok = $false; error = '...' }
function ConvertFrom-ReportHtml([string]$html) {
  $fail = { param($m) return @{ ok = $false; error = $m } }
  if (-not $html) { return & $fail 'หน้ารายงานว่างเปล่า' }
  $titles = [regex]::Matches($html, $TITLE_RE, 'IgnoreCase')
  if ($titles.Count -eq 0) { return & $fail 'ไม่พบหัวข้อ "Outbound the amount of work each day"' }

  $tableHtml = $null; $lastErr = 'ไม่พบตารางใต้หัวข้อ "Outbound the amount of work each day"'
  foreach ($m in $titles) {
    $pos = $m.Index
    # first table after the title (real WMS: title <h4> sits inside a layout table, data table follows it);
    # else the table that contains the title
    $starts = @()
    $after = $html.IndexOf('<table', $pos, [System.StringComparison]::OrdinalIgnoreCase)
    if ($after -ge 0) { $starts += $after }
    $open = $html.LastIndexOf('<table', $pos, [System.StringComparison]::OrdinalIgnoreCase)
    if ($open -ge 0) {
      $close = $html.IndexOf('</table', $open, [System.StringComparison]::OrdinalIgnoreCase)
      if ($close -gt $pos) { $starts += $open }
    }
    foreach ($start in $starts) {
      $stop = $html.IndexOf('</table', $start, [System.StringComparison]::OrdinalIgnoreCase)
      if ($stop -lt 0) { $lastErr = 'ตารางไม่มีแท็กปิด'; continue }
      $candidate = $html.Substring($start, $stop - $start)
      if ($candidate.IndexOf('<table', 6, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $lastErr = 'พบตารางซ้อนในตาราง (โครงหน้าเปลี่ยน)'; continue }
      $tableHtml = $candidate; break
    }
    if ($tableHtml) { break }
  }
  if (-not $tableHtml) { return & $fail $lastErr }

  $allRows = Split-Rows $tableHtml
  $periodRe = '^(\d{2}):(\d{2})\s*-\s*(\d{2}):(\d{2})(\s*[^\d\s]{0,6})?$'
  $headerText = ''; $data = @(); $totalCells = $null; $seenData = $false
  foreach ($cells in $allRows) {
    if ($cells.Count -eq 0) { continue }
    $first = $cells[0]
    if ($first -match $periodRe) {
      if ($null -ne $totalCells) { return & $fail 'พบแถวช่วงเวลาอยู่หลังแถว Total' }
      $seenData = $true
      $data += , @{ period = ('{0}:{1}-{2}:{3}' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4]); cells = $cells }
    } elseif ($first -match '^(Total|รวม)$') {
      if ($null -ne $totalCells) { return & $fail 'พบแถว Total มากกว่า 1 แถว' }
      $totalCells = $cells
    } elseif (-not $seenData) {
      $headerText += ' ' + ($cells -join ' ')
    } elseif ($first -match '^\d') {
      return & $fail ('พบแถวที่ไม่รู้จัก: "' + $first + '"')
    }
  }
  if ($headerText -notmatch $HEADER_RE) { return & $fail 'หัวคอลัมน์ไม่ตรงกับที่รู้จัก (Period / Workload / Outbound ... / Truck ...)' }
  if ($data.Count -ne 17) { return & $fail ('จำนวนแถวรายชั่วโมงเป็น ' + $data.Count + ' ต้องเป็น 17') }
  if ($null -eq $totalCells) { return & $fail 'ไม่พบแถว Total' }

  $toObj = {
    param($cells, $label)
    if ($cells.Count -ne 11) { return 'แถว ' + $label + ' มี ' + $cells.Count + ' คอลัมน์ ต้องเป็น 11' }
    $o = [ordered]@{}
    for ($k = 0; $k -lt 10; $k++) {
      $f = $FIELDS[$k]
      $isInt = $INT_FIELDS -contains $f
      $n = ConvertTo-Num $cells[$k + 1] $isInt
      if ($null -eq $n) { return 'แถว ' + $label + ' ช่อง ' + $f + ' ไม่ใช่ตัวเลข: "' + $cells[$k + 1] + '"' }
      if ($isInt) { $o[$f] = [int]$n } else { $o[$f] = $n }
    }
    return $o
  }

  $rows = @()
  for ($i = 0; $i -lt 17; $i++) {
    if ($data[$i].period -ne $PERIODS[$i]) { return & $fail ('แถวที่ ' + ($i + 1) + ' เป็น ' + $data[$i].period + ' ต้องเป็น ' + $PERIODS[$i]) }
    $o = & $toObj $data[$i].cells $PERIODS[$i]
    if ($o -is [string]) { return & $fail $o }
    $row = [ordered]@{ period = $PERIODS[$i] }
    foreach ($f in $FIELDS) { $row[$f] = $o[$f] }
    $rows += [pscustomobject]$row
  }
  $t = & $toObj $totalCells 'Total'
  if ($t -is [string]) { return & $fail $t }
  $total = [pscustomobject]$t

  # ---- cross-checks: never publish numbers we are not sure about
  $sum = @{}; foreach ($f in 'weightKg','completeKg','truckCheckIn','truckOutbound','truckComplete') { $sum[$f] = [decimal]0 }
  foreach ($r in $rows) { foreach ($f in @($sum.Keys)) { $sum[$f] += [decimal]$r.$f } }
  foreach ($f in 'weightKg','completeKg') {
    if ([Math]::Abs($sum[$f] - [decimal]$total.$f) -gt $KG_TOLERANCE) { return & $fail ('ผลรวม ' + $f + ' ไม่ตรงกับแถว Total') }
  }
  foreach ($f in 'truckCheckIn','truckOutbound','truckComplete') {
    if ($sum[$f] -ne [decimal]$total.$f) { return & $fail ('ผลรวม ' + $f + ' ไม่ตรงกับแถว Total') }
  }
  # remaining is cumulative: remaining = previous remaining + in - done.
  # Rows with no flow and remaining 0 (hours not reached yet) are skipped (WMS does not carry the backlog into them).
  $remKg = [decimal]$rows[0].remainingKg; $remTr = [decimal]$rows[0].truckRemaining
  for ($i = 1; $i -lt 17; $i++) {
    $r = $rows[$i]
    if (-not ($r.weightKg -eq 0 -and $r.completeKg -eq 0 -and $r.remainingKg -eq 0)) {
      $exp = $remKg + [decimal]$r.weightKg - [decimal]$r.completeKg
      if ([Math]::Abs([decimal]$r.remainingKg - $exp) -gt $KG_TOLERANCE) { return & $fail ('ยอดค้างสะสม (น้ำหนัก) แถว ' + $r.period + ' ไม่ต่อเนื่อง') }
      $remKg = [decimal]$r.remainingKg
    }
    if (-not ($r.truckOutbound -eq 0 -and $r.truckComplete -eq 0 -and $r.truckRemaining -eq 0)) {
      if ($r.truckRemaining -ne ($remTr + $r.truckOutbound - $r.truckComplete)) { return & $fail ('รถค้างสะสม แถว ' + $r.period + ' ไม่ต่อเนื่อง') }
      $remTr = [decimal]$r.truckRemaining
    }
  }
  if ([Math]::Abs([decimal]$total.remainingKg - $remKg) -gt $KG_TOLERANCE) { return & $fail 'ยอดค้าง (น้ำหนัก) ในแถว Total ไม่ตรงกับแถวล่าสุด' }
  if ([decimal]$total.truckRemaining -ne $remTr) { return & $fail 'รถค้างในแถว Total ไม่ตรงกับแถวล่าสุด' }

  return @{ ok = $true; rows = $rows; total = $total }
}

# ---------------------------------------------------------------- HTTP (no redirects are followed)
$script:Cookies = New-Object System.Net.CookieContainer
[System.Net.ServicePointManager]::Expect100Continue = $false

# PowerShell wraps .NET exceptions (MethodInvocationException); find the WebException inside, if any
function Get-WebException($ex) {
  while ($null -ne $ex) {
    if ($ex -is [System.Net.WebException]) { return $ex }
    $ex = $ex.InnerException
  }
  return $null
}

function Invoke-Wms([string]$method, [string]$url, [string]$formBody) {
  $req = [System.Net.HttpWebRequest]::Create($url)
  $req.Method = $method
  $req.AllowAutoRedirect = $false
  $req.Proxy = $null                  # connect directly to the internal WMS; never send the password via a system proxy
  $req.CookieContainer = $script:Cookies
  $req.Timeout = $TimeoutSec * 1000
  $req.ReadWriteTimeout = $TimeoutSec * 1000
  $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) wms-realtime-report/2 (read-only)'
  $req.Accept = 'text/html,application/xhtml+xml'
  if ($method -eq 'POST') {
    $bytes = $Utf8.GetBytes($formBody)
    $req.ContentType = 'application/x-www-form-urlencoded'
    $req.ContentLength = $bytes.Length
    $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
    $bytes = $null
  }
  $res = $null
  try { $res = $req.GetResponse() }
  catch {
    $we = Get-WebException $_.Exception
    if ($null -eq $we -or $null -eq $we.Response) { throw }   # network / timeout -> caller maps to fetch_error
    $res = $we.Response                                        # HTTP 3xx/4xx/5xx still has a response
  }
  try {
    $enc = $Utf8
    try { if ($res.ContentType -match '(?i)charset\s*=\s*"?([\w\-]+)') { $enc = [System.Text.Encoding]::GetEncoding($Matches[1]) } } catch { }
    $sr = New-Object System.IO.StreamReader($res.GetResponseStream(), $enc)
    $body = $sr.ReadToEnd(); $sr.Close()
    return @{ Status = [int]$res.StatusCode; Location = [string]$res.Headers['Location']; Body = $body }
  } finally { $res.Close() }
}

function Test-IsLoginPage($r) {
  if ($r.Status -ge 300 -and $r.Status -lt 400) { return ($r.Location -match '(?i)/user/login') }
  if ($r.Status -eq 401) { return $true }
  return ($r.Status -eq 200 -and $r.Body -match '(?i)name\s*=\s*["'']?txtPassword')
}

class FetchError : System.Exception { FetchError([string]$m) : base($m) { } }
class LoginFailed : System.Exception { LoginFailed([string]$m) : base($m) { } }
class ParseFailed : System.Exception { ParseFailed([string]$m) : base($m) { } }

# Login: GET the login page (check the form is what we expect), then POST user/password once.
function Connect-Wms($cfg) {
  $script:Cookies = New-Object System.Net.CookieContainer
  $page = Invoke-Wms 'GET' $cfg.LoginUrl $null
  Write-Log ("login page: HTTP {0}" -f $page.Status)
  if ($page.Status -ge 500) { throw [FetchError]::new("WMS ตอบกลับผิดพลาดที่หน้าล็อกอิน (HTTP $($page.Status))") }
  if ($page.Status -ne 200 -or $page.Body -notmatch '(?i)name\s*=\s*["'']?txtUserName' -or $page.Body -notmatch '(?i)name\s*=\s*["'']?txtPassword') {
    # do not send the password to a page we do not recognise
    throw [ParseFailed]::new("หน้าล็อกอิน WMS เปลี่ยนรูปแบบ (HTTP $($page.Status)) จึงยังไม่ส่งรหัสผ่าน")
  }
  $body = 'txtUserName=' + [Uri]::EscapeDataString($cfg.User) + '&txtPassword=' + [Uri]::EscapeDataString($cfg.Pass)
  $r = Invoke-Wms 'POST' $cfg.LoginUrl $body
  $body = $null
  Write-Log ("login post: HTTP {0}" -f $r.Status)
  if ($r.Status -ge 500) { throw [FetchError]::new("WMS ตอบกลับผิดพลาดตอนล็อกอิน (HTTP $($r.Status))") }
  if ((Test-IsLoginPage $r) -or $r.Status -ge 400) {
    throw [LoginFailed]::new('WMS ไม่รับชื่อผู้ใช้/รหัสผ่าน')
  }
  # success is confirmed by the report request that follows
}

function Get-ReportOnce($cfg) {
  $r = Invoke-Wms 'GET' $cfg.ReportUrl $null
  Write-Log ("report: HTTP {0}, {1} chars" -f $r.Status, $r.Body.Length)
  return $r
}

# One cycle. Returns the status string written to latest.json.
function Invoke-Cycle($cfg) {
  $prev = Read-Previous $OutFile
  $status = 'ok'; $msg = ''; $parsed = $null
  try {
    $freshLogin = $false
    if (-not $script:LoggedIn) { Connect-Wms $cfg; $script:LoggedIn = $true; $freshLogin = $true }
    $r = Get-ReportOnce $cfg
    if (Test-IsLoginPage $r) {
      if ($freshLogin) { $script:LoggedIn = $false; throw [LoginFailed]::new('ล็อกอินแล้วแต่ WMS ยังส่งกลับหน้าล็อกอิน') }
      Write-Log 'session expired -> one new login'
      $script:LoggedIn = $false
      try { Connect-Wms $cfg } catch [LoginFailed] { throw [LoginFailed]::new('session หมดอายุ และล็อกอินใหม่ไม่ผ่าน') }
      $script:LoggedIn = $true
      $r = Get-ReportOnce $cfg
      if (Test-IsLoginPage $r) { $script:LoggedIn = $false; throw [LoginFailed]::new('session หมดอายุ และล็อกอินใหม่แล้ว WMS ยังส่งกลับหน้าล็อกอิน') }
    }
    if ($r.Status -ge 500) { throw [FetchError]::new("WMS ตอบกลับผิดพลาด (HTTP $($r.Status))") }
    if ($r.Status -ne 200) { throw [ParseFailed]::new("หน้ารายงานตอบกลับ HTTP $($r.Status) (อาจถูกย้ายหรือเปลี่ยน)") }
    $parsed = ConvertFrom-ReportHtml $r.Body
    if (-not $parsed.ok) { throw [ParseFailed]::new($parsed.error) }
  }
  catch [LoginFailed] { $status = 'login_failed'; $msg = $_.Exception.Message + ' — หยุดดึงข้อมูลแล้ว แก้ .env แล้วเปิดตัวดึงใหม่' }
  catch [ParseFailed] { $status = 'parse_error'; $msg = 'อ่านตาราง WMS ไม่ได้: ' + $_.Exception.Message }
  catch [FetchError]  { $status = 'fetch_error'; $msg = $_.Exception.Message }
  catch {
    # network error, timeout, anything unexpected -> temporary failure, try again next cycle
    $status = 'fetch_error'
    $we = Get-WebException $_.Exception
    if ($we) { $msg = 'เชื่อมต่อ WMS ไม่ได้ (' + $we.Status + ')' }                      # no URL in the message
    else { $msg = 'ดึงข้อมูลไม่สำเร็จ (' + $_.Exception.GetType().Name + ')' }
    $script:LoggedIn = $false
  }

  if ($status -eq 'ok') { $out = New-Result 'ok' '' $prev $parsed.rows $parsed.total }
  else { $out = New-Result $status $msg $prev $null $null }
  Save-Json $out $OutFile
  if ($status -eq 'ok') { Add-History $out }      # after latest.json is safely written; never throws
  if ($status -eq 'ok') { Write-Log ('ok: 17 rows, total weight {0} kg, trucks out {1}' -f $parsed.total.weightKg, $parsed.total.truckOutbound) }
  else { Write-Log ("{0}: {1} (consecutiveFailures {2})" -f $status, $msg, $out.consecutiveFailures) }
  return $status
}

function Get-ExitCode([string]$status) {
  switch ($status) { 'ok' { 0 } 'fetch_error' { 1 } 'login_failed' { 2 } 'parse_error' { 3 } default { 1 } }
}

# ---------------------------------------------------------------- mode 1: parser test with a saved HTML file
if ($HtmlFile) {
  if (-not (Test-Path -LiteralPath $HtmlFile -PathType Leaf)) { Write-Host "HTML file not found: $HtmlFile" -ForegroundColor Red; exit 4 }
  $html = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $HtmlFile).ProviderPath)    # UTF-8 / BOM auto-detect
  $p = ConvertFrom-ReportHtml $html
  $note = 'parsed from a local HTML file (parser test, not live)'
  if ($p.ok) { $out = New-Result 'ok' '' $null $p.rows $p.total $note; $st = 'ok' }
  else { $out = New-Result 'parse_error' ('อ่านตาราง WMS ไม่ได้: ' + $p.error) $null $null $null $note; $st = 'parse_error' }
  Save-Json $out $OutFile
  if ($p.ok) {
    Write-Host ('PARSE OK  rows=17  total weightKg={0} completeKg={1} remainingKg={2} | trucks checkIn={3} out={4} done={5} remaining={6}' -f `
      $p.total.weightKg, $p.total.completeKg, $p.total.remainingKg, $p.total.truckCheckIn, $p.total.truckOutbound, $p.total.truckComplete, $p.total.truckRemaining) -ForegroundColor Green
  } else { Write-Host ('PARSE ERROR: ' + $p.error) -ForegroundColor Red }
  Write-Host "Written: $OutFile"
  exit (Get-ExitCode $st)
}

# ---------------------------------------------------------------- mode 2: live
Write-Host 'WMS fetcher - Phase 2 (live data). Keep this window open. Ctrl+C to stop.' -ForegroundColor Cyan

# after login_failed: do not try again until the owner edits .env (or passes -ResetLogin)
$prevAtStart = Read-Previous $OutFile
if (-not $ResetLogin -and $null -ne $prevAtStart -and $prevAtStart.status -eq 'login_failed') {
  # fail closed: if the time of the failure cannot be read, treat it as "now" (only -ResetLogin gets past)
  $failedAt = [DateTimeOffset]::MaxValue
  try { $failedAt = [DateTimeOffset]::Parse([string]$prevAtStart.lastAttemptAt, $Inv) } catch { }
  $envTime = [DateTimeOffset]::MinValue
  if (Test-Path -LiteralPath $EnvFile) { $envTime = [DateTimeOffset](Get-Item -LiteralPath $EnvFile).LastWriteTime }
  if ($envTime -le $failedAt) {
    Write-Log 'blocked: last run ended with login_failed and .env has not been edited since. Not logging in.'
    Write-Host 'Fix WMS_USERNAME / WMS_PASSWORD in .env and save it, then start again.' -ForegroundColor Yellow
    Write-Host 'If the password is already correct (e.g. IT unlocked the account), run: fetch-wms.ps1 -ResetLogin' -ForegroundColor Yellow
    exit 2
  }
}

$envVals = Read-EnvFile $EnvFile
$missing = @()
foreach ($k in 'WMS_BASE_URL','WMS_USERNAME','WMS_PASSWORD') { if ($null -eq $envVals -or -not $envVals[$k]) { $missing += $k } }
$base = $null
if ($missing.Count -eq 0) {
  $base = $envVals['WMS_BASE_URL'].TrimEnd('/')
  $u = $null
  if (-not [Uri]::TryCreate($base, [UriKind]::Absolute, [ref]$u) -or ($u.Scheme -ne 'http' -and $u.Scheme -ne 'https')) { $missing += 'WMS_BASE_URL (must start with http:// or https://)' }
}
if ($missing.Count -gt 0) {
  $why = $(if ($null -eq $envVals) { 'ไม่พบไฟล์ .env' } else { 'ค่าใน .env ไม่ครบ/ไม่ถูกต้อง: ' + ($missing -join ', ') })
  Save-Json (New-Result 'login_failed' ($why + ' — ยังไม่ได้ล็อกอิน ตั้งค่า .env แล้วเปิดตัวดึงใหม่') $prevAtStart $null $null) $OutFile
  Write-Log ('config error: ' + $(if ($null -eq $envVals) { '.env not found' } else { 'missing/invalid: ' + ($missing -join ', ') }))
  exit 2
}
$cfg = @{
  LoginUrl  = $base + '/user/login'
  ReportUrl = $base + '/Report/ReportShipmentSumByProduct'
  User      = $envVals['WMS_USERNAME']
  Pass      = $envVals['WMS_PASSWORD']
}
$envVals = $null
$script:LoggedIn = $false

if ($Once) { $Cycles = 1 }
$n = 0
while ($true) {
  $started = [DateTime]::Now
  $st = Invoke-Cycle $cfg
  $n++
  if ($st -eq 'login_failed') {
    Write-Host 'Login failed - stopped (no retry, to avoid locking the account). Fix .env, then start again.' -ForegroundColor Red
    exit 2
  }
  if ($Cycles -gt 0 -and $n -ge $Cycles) { exit (Get-ExitCode $st) }
  if ($IntervalSec -gt 0) { $wait = $IntervalSec }      # tests only
  else {
    $wait = (Get-RefreshMinutes) * 60 - ([DateTime]::Now - $started).TotalSeconds
    if ($wait -lt 5) { $wait = 5 }
  }
  Start-Sleep -Seconds ([int][Math]::Ceiling($wait))
}
