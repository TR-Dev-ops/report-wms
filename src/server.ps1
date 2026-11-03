<#
  server.ps1 - tiny web server for wms-realtime-report
  - Serves the files in .\web on http://localhost:<Port>/ (this computer only)
  - Answers GET/HEAD for files inside .\web, plus one API (below). Nothing else.
  - Uses only what ships with Windows (PowerShell 5.1 + .NET HttpListener). No install needed.
  - -Live : Phase 2. Serves config.json with "dataFile": "data/latest.json" and "sampleClock": ""
            (page 2 then reads data/tracking.json; an optional "trackingFile" key is rewritten too)
            (the file on disk is NOT changed, so start.cmd keeps showing sample data)
  - GET /api/trucks?kind=weight        (page 2: owner clicked the W board) -> "weight" = Weight Final trucks,
      1 WMS request: GetRptTrackingScheduleList gateId 0, type 'W' (same rules as below)
  - GET /api/trucks?wh=<building id>   (page 2, P2-D: owner clicked a warehouse card)
      truck list of that warehouse: "loading" (type '') and "plan" (type 'WG'), External ID (Plate) + Company Name only
      * sample mode (no -Live): fictional plates/companies made up here, WMS is never contacted
      * -Live: POST <WMS>/Report/GetRptTrackingScheduleList (the only WMS endpoint used here, read-only),
        one gate at a time (never in parallel), gates = site pointMap points of that warehouse,
        gateId from data/tracking.json (written by fetch-wms.ps1). Only when someone clicks / presses refresh -
        never on a timer, never ahead of time. Same warehouse asked again within 10 s -> the same answer
        from memory (no second WMS call).
      * login: reads ..\.env itself (same rules as fetch-wms.ps1), session cookie in memory only.
        Login page in the answer -> one new login; still refused -> "session". Login rejected -> "login_failed"
        and no more login attempts until this window is restarted. latest.json says login_failed -> no attempt.
      * plates / company names are real data: kept in memory only, never written to any file or the console.
        The console shows only e.g. "trucks wh=D gates=4 ok n=12".
  - Static files: only the files the two pages need (Test-StaticAllowed in lan-common.ps1), in every mode.
      Anything else in .\web (data/screenshot.local.json, *.parse-test.local.json, *.tmp, archive ...) -> 404.
      Exception for this computer only (loopback) in sample mode: the dataFile / trackingFile named in config.json.
  - -Lan : Phase 3 (LAN view, start-live-lan.cmd). Listens on http://+:<Port>/ (needs the URL registration of
      README 8.9 step 1, done by the owner / IT - this script never runs netsh, never touches the firewall and never
      asks for admin rights; without it the script stops with a message). Then, for every request:
        client IP = loopback or an IPv4 inside lan.local.json "allow" (no file: RFC 1918 ranges + warning) else 403,
        Host header = localhost / this computer's name / LAN IPv4 + :<Port> else 403,
        /api/trucks: max perIpPerMinute per computer (default 6) and wmsPerMinute WMS requests in total (default 30,
        login GET/POST included; a click that alone needs more than wmsPerMinute -> status "quota_too_small")
        else 429 {"status":"rate_limited","retryAfterSec":n} without contacting WMS (answers from the 10 s memory count per computer, not in the total).
      Visitor IPs are shown on this console only (new viewer / trucks ... from <IP> / refused ...), never in a file.
      Without -Lan everything works as before (localhost only, no quotas).
  - Stop: close this window or press Ctrl+C
#>
param(
  [int]$Port = 8787,
  [switch]$NoBrowser,
  [switch]$Live,
  [string]$EnvFile,           # default ..\.env                      (truck list, -Live only)
  [string]$TrackingFile,      # default web\data\tracking.json        (gateId of every point)
  [string]$LatestFile,        # default web\data\latest.json          (login_failed guard)
  [string]$SiteFile,          # default web\data\site.local.json, else web\data\site.sample.json
  [int]$WmsTimeoutSec = 10,   # per WMS request
  [int]$TrucksBudgetSec = 20, # no new WMS request after this many seconds of one click
  [switch]$Lan,               # Phase 3: let allowed computers on the LAN open the pages (start-live-lan.cmd)
  [string]$LanConfig,         # default lan.local.json next to this script
  [switch]$LanTestLocalBind   # tests only: all -Lan checks on, but listen on http://localhost:<Port>/ (no URL registration)
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'web'))
$configPath = Join-Path $root 'config.json'
$prefix = "http://localhost:$Port/"
$ProjectRoot = Split-Path $PSScriptRoot -Parent
if (-not $EnvFile) { $EnvFile = Join-Path $ProjectRoot '.env' }
if (-not $TrackingFile) { $TrackingFile = Join-Path $root 'data\tracking.json' }
if (-not $LatestFile) { $LatestFile = Join-Path $root 'data\latest.json' }
$Inv = [System.Globalization.CultureInfo]::InvariantCulture
$utf8 = New-Object System.Text.UTF8Encoding($false)      # also $Utf8 for wms-common.ps1 (names are case-insensitive)
$TimeoutSec = $WmsTimeoutSec                              # used by Invoke-Wms
$script:Cookies = New-Object System.Net.CookieContainer
[System.Net.ServicePointManager]::Expect100Continue = $false
Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue   # PS 5.1: arrays must serialize as JSON arrays
. (Join-Path $PSScriptRoot 'wms-common.ps1')
. (Join-Path $PSScriptRoot 'lan-common.ps1')
if ($LanTestLocalBind) { $Lan = [switch]$true }
$script:LanCfg = $null; $script:LanNames = @(); $script:Limiter = $null
if ($Lan) {
  if (-not $LanConfig) { $LanConfig = Join-Path $PSScriptRoot 'lan.local.json' }
  try { $script:LanCfg = Read-LanConfig $LanConfig } catch {
    Write-Host "LAN mode NOT started: lan.local.json is broken - $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Fix or delete src\lan.local.json (see README 8.9 and lan.example.json). The server does not open itself wider instead.'
    if (-not $NoBrowser) { Read-Host 'Press Enter to close' }
    exit 2
  }
  $script:LanNames = Get-LanHostNames
  $script:Limiter = New-LanLimiter $script:LanCfg.PerIpPerMinute $script:LanCfg.WmsPerMinute
  if (-not $LanTestLocalBind) { $prefix = "http://+:$Port/" }
}

$types = @{
  '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
  '.js' = 'application/javascript; charset=utf-8'; '.json' = 'application/json; charset=utf-8'
  '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try { $listener.Start() } catch {
  $he = $_.Exception; while ($null -ne $he -and $he -isnot [System.Net.HttpListenerException]) { $he = $he.InnerException }
  if ($Lan -and -not $LanTestLocalBind -and $null -ne $he -and $he.ErrorCode -eq 5) {
    # Access denied = the URL http://+:<Port>/ is not registered for this account. Never fixed from here (no netsh,
    # no admin prompt) and never silently switched back to localhost: the owner / IT does README 8.9 step 1.
    Write-Host "LAN mode NOT started: Windows has not allowed this account to listen on http://+:$Port/ (Access denied)." -ForegroundColor Red
    Write-Host 'Do README section 8.9 step 1 first (Run as administrator, done by the owner or IT - this program never does it):'
    Write-Host "  netsh http add urlacl url=http://+:$Port/ user=<DOMAIN>\<user>   (the account that opens this program: $env:USERDOMAIN\$env:USERNAME)"
    Write-Host 'Until then use start-live.cmd (this computer only). Close the "WMS fetcher" window too if it was opened.'
    if (-not $NoBrowser) { Read-Host 'Press Enter to close' }
    exit 1
  }
  Write-Host "Cannot start web server on port $Port. Another program may be using it." -ForegroundColor Red
  Write-Host "Try: powershell -ExecutionPolicy Bypass -File server.ps1 -Port 8788"
  Write-Host $_.Exception.Message
  if (-not $NoBrowser) { Read-Host 'Press Enter to close' }
  exit 1
}

if ($Live) { Write-Host "WMS realtime report - LIVE data (data/latest.json written by fetch-wms.ps1)" -ForegroundColor Cyan }
else { Write-Host "WMS realtime report - data file from config.json (default: sample data)" -ForegroundColor Cyan }
Write-Host "Open: http://localhost:$Port/"
Write-Host "Serving: $root"
Write-Host "Keep this window open. Close it (or Ctrl+C) to stop."
$localUrl = "http://localhost:$Port/"
if ($Lan) {
  # shown on this console only, never written to a file
  Write-Host ''
  Write-Host 'LAN MODE ON: คอมในวงแลนที่อนุญาตเปิดดูได้' -ForegroundColor Black -BackgroundColor Yellow
  Write-Host ("  Team computers open:  http://{0}:{1}/" -f [Environment]::MachineName, $Port) -ForegroundColor Yellow
  foreach ($a in (Get-LanLocalIPv4)) { Write-Host ("                   or:  http://{0}:{1}/   (IP may change - prefer the computer name)" -f $a, $Port) -ForegroundColor Yellow }
  Write-Host ('  Allowed ranges: ' + (($script:LanCfg.Allow | ForEach-Object { $_.Text }) -join ', ') + ' (+ this computer)')
  if ($script:LanCfg.Defaulted) {
    Write-Host '  WARNING ยังไม่ได้จำกัดวงแลน: แนะนำให้ถาม IT ว่าวงของคอมทีมคือวงไหน (then put it in src\lan.local.json, README 8.9)' -ForegroundColor Red
  }
  Write-Host ('  Truck list quota: {0} clicks/min per computer, {1} WMS requests/min in total' -f $script:LanCfg.PerIpPerMinute, $script:LanCfg.WmsPerMinute)
  Write-Host '  Stop LAN mode: close this window and use start-live.cmd again.'
  Write-Host ''
}
if (-not $NoBrowser) { Start-Process $localUrl }

function Send([System.Net.HttpListenerResponse]$res, [int]$code, [byte[]]$body, [string]$type) {
  $res.StatusCode = $code
  $res.ContentType = $type
  $res.Headers['Cache-Control'] = 'no-store'
  $res.Headers['X-Content-Type-Options'] = 'nosniff'
  $res.ContentLength64 = $body.Length
  if ($body.Length -gt 0) { $res.OutputStream.Write($body, 0, $body.Length) }
  $res.OutputStream.Close()
}
function Write-Line([string]$msg) { Write-Host ('{0}  {1}' -f [DateTime]::Now.ToString('HH:mm:ss', $Inv), $msg) }   # console only, never a file

# ======================================================================= Phase 3 (LAN) console lines - memory + console only
$script:Viewers = @{}          # IP -> last seen (new viewer line + count of the last 10 min)
$script:ViewerReportAt = [DateTime]::Now
$script:Refused = @{}          # "what|ip" -> @{ At = last printed; More = lines held back since }
function Write-Refused([string]$what, [string]$ip) {
  $now = [DateTime]::Now; $k = $what + '|' + $ip
  if ($script:Refused.Count -gt 500) { foreach ($x in @($script:Refused.Keys)) { if (($now - $script:Refused[$x].At).TotalMinutes -ge 10) { $script:Refused.Remove($x) } } }
  if ($script:Refused.Count -gt 1000) { $script:Refused.Clear() }          # hard cap: memory never grows without limit
  $e = $script:Refused[$k]
  if ($null -ne $e -and ($now - $e.At).TotalSeconds -lt 60) { $e.More++; return }   # same refusal again within 60 s: count, do not flood the screen
  $more = $(if ($null -ne $e -and $e.More -gt 0) { " (+$($e.More) more in the last minute)" } else { '' })
  $script:Refused[$k] = @{ At = $now; More = 0 }
  Write-Line "refused $what from $ip$more"
}
function Get-ViewerCount([DateTime]$now) { return @($script:Viewers.Values | Where-Object { ($now - $_).TotalMinutes -lt 10 }).Count }
function Note-Viewer($client) {
  $now = [DateTime]::Now
  if (-not $client.Loopback) {
    if (-not $script:Viewers.ContainsKey($client.Text)) {
      $script:Viewers[$client.Text] = $now
      Write-Line ("new viewer {0}  (computers in the last 10 min: {1})" -f $client.Text, (Get-ViewerCount $now))
    } else { $script:Viewers[$client.Text] = $now }
  }
  if (($now - $script:ViewerReportAt).TotalMinutes -ge 10) {
    $script:ViewerReportAt = $now
    foreach ($x in @($script:Viewers.Keys)) { if (($now - $script:Viewers[$x]).TotalMinutes -ge 10) { $script:Viewers.Remove($x) } }   # memory: keep the last 10 min only
    $n = Get-ViewerCount $now
    if ($n -gt 0) { Write-Line "computers in the last 10 min: $n" }
  }
}
# a click that alone needs more WMS requests than wmsPerMinute can never fit: say so (waiting would not help)
function Send-QuotaTooSmall($res, [string]$what, [int]$cost, $client) {
  Write-Line "trucks $what needs up to $cost WMS requests, more than wmsPerMinute=$($script:Limiter.WmsMax) - raise it in lan.local.json$(' from ' + $client.Text)"
  Send $res 200 $utf8.GetBytes('{"schemaVersion":1,"status":"quota_too_small","needed":' + $cost + ',"wmsPerMinute":' + $script:Limiter.WmsMax + '}') 'application/json; charset=utf-8'
}
function Send-RateLimited($res, [int]$wait, $client, [string]$why) {
  Write-Refused "429 $why" $client.Text
  $res.Headers['Retry-After'] = [string]$wait
  Send $res 429 $utf8.GetBytes('{"schemaVersion":1,"status":"rate_limited","retryAfterSec":' + $wait + '}') 'application/json; charset=utf-8'
}
# this computer only, sample mode: the data / tracking file named in config.json (README 7: compare with screenshot.local.json)
function Test-ConfigDataFile([string]$full) {
  try { $c = Read-JsonFile $configPath } catch { return $false }
  if ($null -eq $c) { return $false }
  $dataDir = [System.IO.Path]::GetFullPath((Join-Path $root 'data')) + [System.IO.Path]::DirectorySeparatorChar
  foreach ($k in @('dataFile', 'trackingFile')) {
    $v = $c.PSObject.Properties[$k]
    if ($null -eq $v -or $v.Value -isnot [string] -or $v.Value -eq '') { continue }
    try { $f = [System.IO.Path]::GetFullPath((Join-Path $root $v.Value)) } catch { continue }
    if ($f -ieq $full -and $f.StartsWith($dataDir, [System.StringComparison]::OrdinalIgnoreCase) -and $f.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

# ======================================================================= P2-D truck list
$script:Wms = @{ LoggedIn = $false; Blocked = $false; Cfg = $null; Logins = 0 }
$script:Reuse = @{}          # wh -> @{ At = DateTime; Bytes = byte[] }  (memory only, dropped after 10 s)
$REUSE_SEC = 10

function Read-JsonFile([string]$path) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  return ([System.IO.File]::ReadAllText($path, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json)
}

# gate (point) names of one warehouse, in pointMap order
function Get-WarehouseGates([string]$wh) {
  $path = $SiteFile
  if (-not $path) {
    $path = Join-Path $root 'data\site.local.json'
    if (-not (Test-Path -LiteralPath $path)) { $path = Join-Path $root 'data\site.sample.json' }
  }
  $site = Read-JsonFile $path
  $names = New-Object System.Collections.ArrayList
  if ($null -ne $site -and $null -ne $site.pointMap) {
    foreach ($p in $site.pointMap.PSObject.Properties) { if ([string]$p.Value -ceq $wh) { [void]$names.Add([string]$p.Name) } }
  }
  return , $names
}

function New-TruckAnswer([string]$mode, [string]$wh, [string]$status, [string]$message, $gates, $failed, $loading, $plan, [string]$kind = 'warehouse', $weight = @()) {
  $a = New-Object System.Collections.ArrayList; foreach ($x in @($gates)) { if ($null -ne $x) { [void]$a.Add($x) } }
  $f = New-Object System.Collections.ArrayList; foreach ($x in @($failed)) { if ($null -ne $x) { [void]$f.Add($x) } }
  $l = New-Object System.Collections.ArrayList; foreach ($x in @($loading)) { if ($null -ne $x) { [void]$l.Add($x) } }
  $p = New-Object System.Collections.ArrayList; foreach ($x in @($plan)) { if ($null -ne $x) { [void]$p.Add($x) } }
  $w = New-Object System.Collections.ArrayList; foreach ($x in @($weight)) { if ($null -ne $x) { [void]$w.Add($x) } }
  return [pscustomobject][ordered]@{
    schemaVersion = 1; mode = $mode; kind = $kind; wh = $wh; status = $status; message = $message
    gates = $a; failedGates = $f; loading = $l; plan = $p; weight = $w
    fetchedAt = [DateTimeOffset]::Now.ToString("yyyy-MM-dd'T'HH:mm:sszzz", $Inv)
  }
}

# sample mode: fictional plates and companies (made up here, not taken from WMS)
function Get-SampleTrucks([string]$wh, $gates) {
  $pre = @('70', '71', '72', 'ทด', 'สม', 'ตย')
  $cos = @('บริษัท ตัวอย่างขนส่ง จำกัด', 'หจก. สมมติทรานสปอร์ต', 'บริษัท ทดสอบโลจิสติกส์ จำกัด', 'บริษัท เดโม่คาร์โก้ จำกัด',
    'Sample Freight Co., Ltd.', 'บริษัท ตัวอย่างขนส่งสินค้าระหว่างประเทศและบริการคลังสินค้าครบวงจร จำกัด (ชื่อยาวสมมติ)',
    'หจก. รถบรรทุกจำลอง', 'Demo Haulage Co., Ltd.', 'Demo <b>&</b> "Quote" Cargo (ชื่อสมมติ ทดสอบอักขระพิเศษ)')
  $seed = 0; foreach ($ch in $wh.ToCharArray()) { $seed += [int]$ch }
  $make = {
    param([int]$n, [int]$s)
    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $n; $i++) {
      $k = ($s * 31 + $i * 17) % 997
      $p = $pre[$k % $pre.Count]; $num = 1000 + ($k * 7919) % 9000
      $plate = $(if ($p -match '^\d') { $p + '-' + $num } else { $p + ' ' + $num })
      [void]$out.Add([pscustomobject][ordered]@{ plate = $plate; company = $cos[($k + $i) % $cos.Count] })
    }
    return , $out
  }
  if ($wh -eq '') {                                   # Weight Final (kind=weight): one group
    $wr = & $make 4 777
    return New-TruckAnswer 'sample' '' 'ok' '' @() @() @() @() 'weight' $wr
  }
  $ld = & $make ($seed % 3) $seed
  $pl = & $make (($seed % 5) + 2) ($seed + 101)
  return New-TruckAnswer 'sample' $wh 'ok' '' $gates @() $ld $pl
}

# P2-D W board: trucks of "Weight Final" = the same endpoint with gateId 0, type 'W' (ng-click on the Weight Final
# number in the WMS Gate Tracking page). 1 request per click. No gateId needed from tracking.json.
function Get-LiveWeight {
  $script:Wms.Logins = 0
  $latestFailed = $false
  try { $lt = Read-JsonFile $LatestFile; $latestFailed = $null -ne $lt -and $lt.status -eq 'login_failed' } catch { }
  if ($script:Wms.Blocked -or $latestFailed) { return New-TruckAnswer 'live' '' 'login_failed' 'login_blocked' @() @() @() @() 'weight' }
  $cfg = Get-WmsCfg
  if ($null -eq $cfg) { return New-TruckAnswer 'live' '' 'login_failed' 'env_missing' @() @() @() @() 'weight' }
  $r = Invoke-ScheduleCall $cfg 0 'W'
  switch ($r.kind) {
    'ok' { return New-TruckAnswer 'live' '' 'ok' '' @() @() @() @() 'weight' $r.rows }
    'fail' { return New-TruckAnswer 'live' '' 'error' '' @() @() @() @() 'weight' }
    default { return New-TruckAnswer 'live' '' $r.kind '' @() @() @() @() 'weight' }
  }
}

function Get-WmsCfg {
  if ($null -ne $script:Wms.Cfg) { return $script:Wms.Cfg }
  $e = Read-EnvFile $EnvFile
  if ($null -eq $e) { return $null }
  $base = [string]$e['WMS_BASE_URL']; $base = $base.TrimEnd('/')
  $u = $null
  if (-not $e['WMS_USERNAME'] -or -not $e['WMS_PASSWORD'] -or -not [Uri]::TryCreate($base, [UriKind]::Absolute, [ref]$u) -or ($u.Scheme -ne 'http' -and $u.Scheme -ne 'https')) { return $null }
  $script:Wms.Cfg = @{ LoginUrl = $base + '/user/login'; ScheduleUrl = $base + '/Report/GetRptTrackingScheduleList'
                       User = $e['WMS_USERNAME']; Pass = $e['WMS_PASSWORD'] }
  $e = $null
  return $script:Wms.Cfg
}

# 'ok' | 'login_failed' (refused: blocks further logins) | 'error' (network / 5xx / unknown login form: password not sent)
function Connect-WmsServer($cfg) {
  $script:Cookies = New-Object System.Net.CookieContainer
  $script:Wms.LoggedIn = $false
  $script:Wms.Logins++
  try {
    if ($null -ne $script:Limiter) { Add-LanWmsCall $script:Limiter ([DateTime]::Now) }   # LAN total quota counts login requests too
    $page = Invoke-Wms 'GET' $cfg.LoginUrl $null
    if ($page.Status -ne 200 -or $page.Body -notmatch '(?i)name\s*=\s*["'']?txtUserName' -or $page.Body -notmatch '(?i)name\s*=\s*["'']?txtPassword') {
      Write-Line "trucks: WMS login page not recognised (HTTP $($page.Status)) - password not sent"
      return 'error'
    }
    if ($null -ne $script:Limiter) { Add-LanWmsCall $script:Limiter ([DateTime]::Now) }
    $r = Invoke-Wms 'POST' $cfg.LoginUrl ('txtUserName=' + [Uri]::EscapeDataString($cfg.User) + '&txtPassword=' + [Uri]::EscapeDataString($cfg.Pass))
  } catch {
    Write-Line ('trucks: cannot reach WMS for login (' + $_.Exception.GetType().Name + ')')
    return 'error'
  }
  if ($r.Status -ge 500) { Write-Line "trucks: WMS login error HTTP $($r.Status)"; return 'error' }
  if ((Test-IsLoginPage $r) -or $r.Status -ge 400) {
    $script:Wms.Blocked = $true
    Write-Line 'trucks: WMS refused the user/password - no more login attempts until this window is restarted'
    return 'login_failed'
  }
  $script:Wms.LoggedIn = $true
  Write-Line 'trucks: logged in to WMS'
  return 'ok'
}

# one gate + one type. Returns @{ kind = 'ok' | 'fail' | 'session' | 'login_failed' | 'error'; rows }
function Invoke-ScheduleCall($cfg, [int]$gateId, [string]$type) {   # type: '' | 'WG' | 'W' (gateId 0)
  if (-not $script:Wms.LoggedIn) {
    if ($script:Wms.Logins -ge 1) { return @{ kind = 'session' } }       # at most one login per click
    $c = Connect-WmsServer $cfg
    if ($c -ne 'ok') { return @{ kind = $c } }
  }
  # same JSON as the WMS page (TrackingService.js): date = JSON of new Date() (UTC ISO), the rest as in the ng-click
  $date = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", $Inv)
  $json = '{"date":"' + $date + '","gateId":' + $gateId + ',"type":"' + $type + '","workType":"","workStyle":"","wheelType":0}'
  $call = { if ($null -ne $script:Limiter) { Add-LanWmsCall $script:Limiter ([DateTime]::Now) }
            Invoke-Wms 'POST' $cfg.ScheduleUrl $json 'application/json;charset=utf-8' 'application/json, text/plain, */*' }
  try { $r = & $call } catch { return @{ kind = 'fail' } }
  if (Test-IsLoginPage $r) {
    $script:Wms.LoggedIn = $false
    if ($script:Wms.Logins -ge 1) { return @{ kind = 'session' } }
    $c = Connect-WmsServer $cfg                                            # session expired -> one new login
    if ($c -ne 'ok') { return @{ kind = $c } }
    try { $r = & $call } catch { return @{ kind = 'fail' } }
    if (Test-IsLoginPage $r) { $script:Wms.LoggedIn = $false; return @{ kind = 'session' } }
  }
  if ($r.Status -ne 200 -or -not $r.Body.TrimStart().StartsWith('[')) { return @{ kind = 'fail' } }
  try { $arr = ConvertFrom-Json -InputObject $r.Body } catch { return @{ kind = 'fail' } }
  if ($null -eq $arr) { $arr = @() }
  if (-not ($arr -is [array])) { return @{ kind = 'fail' } }
  $rows = New-Object System.Collections.ArrayList
  foreach ($o in $arr) {
    if ($null -eq $o -or $null -eq $o.PSObject.Properties['Plate']) { return @{ kind = 'fail' } }   # format changed: never guess
    $co = $o.PSObject.Properties['CompanyName']
    [void]$rows.Add([pscustomobject][ordered]@{
      plate = $(if ($null -ne $o.Plate) { ([string]$o.Plate).Trim() } else { '' })
      company = $(if ($null -ne $co -and $null -ne $co.Value) { ([string]$co.Value).Trim() } else { '' }) })
  }
  return @{ kind = 'ok'; rows = $rows }
}

function Get-LiveTrucks([string]$wh, $gates) {
  $script:Wms.Logins = 0
  $ids = @{}
  try {
    $t = Read-JsonFile $TrackingFile
    if ($null -ne $t) { foreach ($p in @($t.points)) { if ($null -ne $p -and $p.gateId -is [int] -and $p.gateId -gt 0) { $ids[[string]$p.name] = [int]$p.gateId } } }
  } catch { }
  $failed = New-Object System.Collections.ArrayList
  $work = @()
  foreach ($g in $gates) { if ($ids.ContainsKey($g)) { $work += $g } else { [void]$failed.Add($g) } }
  if ($work.Count -eq 0) { return New-TruckAnswer 'live' $wh 'error' 'no_gate_ids' $gates $gates @() @() }

  $latestFailed = $false
  try { $lt = Read-JsonFile $LatestFile; $latestFailed = $null -ne $lt -and $lt.status -eq 'login_failed' } catch { }
  if ($script:Wms.Blocked -or $latestFailed) { return New-TruckAnswer 'live' $wh 'login_failed' 'login_blocked' $gates @() @() @() }
  $cfg = Get-WmsCfg
  if ($null -eq $cfg) { return New-TruckAnswer 'live' $wh 'login_failed' 'env_missing' $gates @() @() @() }

  $loading = New-Object System.Collections.ArrayList; $plan = New-Object System.Collections.ArrayList
  $okGates = 0; $started = [DateTime]::Now
  foreach ($g in $work) {
    $gateOk = $true
    foreach ($type in @('', 'WG')) {                                         # '' = กำลังขึ้น, 'WG' = Plan
      if (([DateTime]::Now - $started).TotalSeconds -ge $TrucksBudgetSec) { $gateOk = $false; break }
      $r = Invoke-ScheduleCall $cfg $ids[$g] $type
      switch ($r.kind) {
        'ok' { if ($type -eq '') { foreach ($x in $r.rows) { [void]$loading.Add($x) } } else { foreach ($x in $r.rows) { [void]$plan.Add($x) } } }
        'fail' { $gateOk = $false }
        default { return New-TruckAnswer 'live' $wh $r.kind '' $gates @() @() @() }   # session / login_failed / error: stop now
      }
      if (-not $gateOk) { break }
    }
    if ($gateOk) { $okGates++ } else { [void]$failed.Add($g) }
  }
  $st = $(if ($failed.Count -eq 0) { 'ok' } elseif ($okGates -gt 0) { 'partial' } else { 'error' })
  return New-TruckAnswer 'live' $wh $st '' $gates $failed $loading $plan
}

function Handle-Trucks($req, $res, $client) {
  $wh = [string]$req.QueryString['wh']
  $kind = $req.QueryString['kind']
  $now = [DateTime]::Now
  foreach ($k in @($script:Reuse.Keys)) { if (($now - $script:Reuse[$k].At).TotalSeconds -ge $REUSE_SEC) { $script:Reuse.Remove($k) } }
  $from = ''
  if ($Lan) {
    # per computer: every /api/trucks request counts (warehouses + W, answers from memory too)
    $from = ' from ' + $client.Text
    $wait = Test-LanPerIp $script:Limiter $client.Key $now
    if ($wait -gt 0) { Send-RateLimited $res $wait $client 'clicks'; return }
  }
  if ($null -ne $kind) {
    # ?kind=weight (W board). A separate parameter, so it never clashes with a warehouse id (a building may be called "W").
    if ($kind -cne 'weight' -or $null -ne $req.QueryString['wh']) {
      Send $res 400 $utf8.GetBytes('{"schemaVersion":1,"status":"bad_request"}') 'application/json; charset=utf-8'; return
    }
    $key = '?weight'                                       # reuse key: cannot be a warehouse id (those are [A-Za-z0-9_-])
    if ($Live -and $script:Reuse.ContainsKey($key)) {
      Write-Line "trucks kind=weight same answer as $([int]($now - $script:Reuse[$key].At).TotalSeconds) s ago (no WMS call)$from"
      Send $res 200 $script:Reuse[$key].Bytes 'application/json; charset=utf-8'; return
    }
    if ($Live -and $Lan) {                                 # total WMS quota, checked before: 1 request + 2 kept for a possible login
      if (3 -gt $script:Limiter.WmsMax) { Send-QuotaTooSmall $res 'kind=weight' 3 $client; return }
      $wait = Test-LanWmsBudget $script:Limiter 3 $now
      if ($wait -gt 0) { Send-RateLimited $res $wait $client 'wms-quota'; return }
    }
    if ($Live) { $a = Get-LiveWeight } else { $a = Get-SampleTrucks '' @() }
    $bytes = $utf8.GetBytes((ConvertTo-Json -InputObject $a -Depth 4 -Compress))
    Write-Line ("trucks kind=weight {0} n={1}{2}{3}{4}" -f $a.status, @($a.weight).Count, $(if ($a.message) { " ($($a.message))" } else { '' }), $(if ($Live) { '' } else { ' [sample]' }), $from)
    if ($Live -and $a.status -eq 'ok') { $script:Reuse[$key] = @{ At = [DateTime]::Now; Bytes = $bytes } }
    Send $res 200 $bytes 'application/json; charset=utf-8'
    return
  }
  if ($wh -cnotmatch '\A[A-Za-z0-9_-]{1,32}\z') {          # \z: no trailing newline (unlike $)
    Send $res 400 $utf8.GetBytes('{"schemaVersion":1,"status":"bad_request"}') 'application/json; charset=utf-8'; return
  }
  if ($Live -and $script:Reuse.ContainsKey($wh)) {
    Write-Line "trucks wh=$wh same answer as $([int]($now - $script:Reuse[$wh].At).TotalSeconds) s ago (no WMS call)$from"
    Send $res 200 $script:Reuse[$wh].Bytes 'application/json; charset=utf-8'; return
  }
  $gates = Get-WarehouseGates $wh
  if ($gates.Count -eq 0) {
    $a = New-TruckAnswer $(if ($Live) { 'live' } else { 'sample' }) $wh 'unknown_wh' '' @() @() @() @()
    Send $res 404 $utf8.GetBytes((ConvertTo-Json -InputObject $a -Depth 4 -Compress)) 'application/json; charset=utf-8'; return
  }
  if ($Live -and $Lan) {
    # total WMS quota, checked before the first request: up to 2 requests per gate ('' + 'WG') + 2 kept for a
    # possible login (GET + POST; at most one login per click). Never stops half way.
    $cost = 2 * $gates.Count + 2
    if ($cost -gt $script:Limiter.WmsMax) { Send-QuotaTooSmall $res "wh=$wh" $cost $client; return }
    $wait = Test-LanWmsBudget $script:Limiter $cost $now
    if ($wait -gt 0) { Send-RateLimited $res $wait $client 'wms-quota'; return }
  }
  if ($Live) { $a = Get-LiveTrucks $wh $gates } else { $a = Get-SampleTrucks $wh $gates }
  $bytes = $utf8.GetBytes((ConvertTo-Json -InputObject $a -Depth 4 -Compress))
  $n = @($a.loading).Count + @($a.plan).Count
  $extra = $(if (@($a.failedGates).Count) { " failed=$(@($a.failedGates).Count)" } else { '' }) + $(if ($a.message) { " ($($a.message))" } else { '' })
  Write-Line ("trucks wh={0} gates={1} {2} n={3}{4}{5}{6}" -f $wh, $gates.Count, $a.status, $n, $extra, $(if ($Live) { '' } else { ' [sample]' }), $from)
  # only good answers are reused for 10 s; a failure (error / session / login) is never repeated from memory
  if ($Live -and ($a.status -eq 'ok' -or $a.status -eq 'partial')) { $script:Reuse[$wh] = @{ At = [DateTime]::Now; Bytes = $bytes } }
  Send $res 200 $bytes 'application/json; charset=utf-8'
  $a = $null
}

# ======================================================================= main loop
try {
  while ($listener.IsListening) {
    $async = $listener.BeginGetContext($null, $null)
    while (-not $async.AsyncWaitHandle.WaitOne(500)) { }   # lets Ctrl+C work
    $ctx = $listener.EndGetContext($async)
    $req = $ctx.Request; $res = $ctx.Response
    try {
      $remote = $req.RemoteEndPoint
      if ($Lan) {
        # Phase 3: allowed LAN computers + this computer; the TCP address only (no X-Forwarded-For), then the Host header
        $client = Test-LanClient $(if ($null -ne $remote) { $remote.Address } else { $null }) $script:LanCfg.Allow
        if (-not $client.Allowed) {
          Write-Refused '403 ip' $client.Text
          Send $res 403 $utf8.GetBytes('Forbidden: this computer is not in the allowed LAN range') 'text/plain; charset=utf-8'; continue
        }
        if (-not (Test-LanHost $req.Headers['Host'] $script:LanNames $Port)) {
          Write-Refused '403 host' $client.Text
          Send $res 403 $utf8.GetBytes('Forbidden: unknown host name') 'text/plain; charset=utf-8'; continue
        }
        Note-Viewer $client
      } else {
        # Phase 1 = this computer only. http.sys accepts connections on all interfaces,
        # so refuse every request that does not come from a loopback address.
        if (-not $req.IsLocal -or $null -eq $remote -or -not [System.Net.IPAddress]::IsLoopback($remote.Address)) {
          Send $res 403 $utf8.GetBytes('Forbidden: this computer only') 'text/plain; charset=utf-8'; continue
        }
        $client = [pscustomobject]@{ Allowed = $true; Loopback = $true; Key = 'loopback'; Text = $remote.Address.ToString() }
      }
      if ($req.Url.AbsolutePath -ceq '/api/trucks') {
        # GET only (no OPTIONS / CORS headers at all). Only our own page: it sends X-WMS-Report: 1, which a
        # plain cross-site link/form/img cannot send without a CORS preflight (never answered). Browsers also
        # send Sec-Fetch-Site: anything other than same-origin / none = another site -> refused.
        if ($req.HttpMethod -ne 'GET') { Send $res 405 $utf8.GetBytes('Method not allowed') 'text/plain; charset=utf-8'; continue }
        $sfs = $req.Headers['Sec-Fetch-Site']
        if ($req.Headers['X-WMS-Report'] -cne '1' -or ($null -ne $sfs -and $sfs -ne 'same-origin' -and $sfs -ne 'none')) {
          Send $res 403 $utf8.GetBytes('Forbidden') 'text/plain; charset=utf-8'; continue
        }
        Handle-Trucks $req $res $client; continue
      }
      if ($req.HttpMethod -ne 'GET' -and $req.HttpMethod -ne 'HEAD') {
        Send $res 405 $utf8.GetBytes('Method not allowed') 'text/plain; charset=utf-8'; continue
      }
      $rel = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath).TrimStart('/')
      if ($rel -eq '') { $rel = 'index.html' }
      $full = $null
      if ($rel.IndexOf(':') -lt 0) { try { $full = [System.IO.Path]::GetFullPath((Join-Path $root $rel)) } catch { $full = $null } }
      if ($null -eq $full) { Send $res 404 $utf8.GetBytes('Not found') 'text/plain; charset=utf-8'; continue }   # ':' (drive, ::$DATA) or invalid path
      # only files inside .\web ; never serve hidden files or folders (any path part starting with a dot, e.g. .env, .git)
      $hidden = $false
      if ($full.Length -gt $root.Length) {
        foreach ($part in $full.Substring($root.Length).Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
          if ($part.StartsWith('.')) { $hidden = $true }
        }
      }
      if (-not $full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
          $hidden -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Send $res 404 $utf8.GetBytes('Not found') 'text/plain; charset=utf-8'; continue
      }
      # allowlist (every mode): only the files the pages need; the path checked is the one actually read
      $relFull = $full.Substring($root.Length + 1).Replace([System.IO.Path]::DirectorySeparatorChar, '/')
      if (-not (Test-StaticAllowed $relFull) -and -not ($client.Loopback -and -not $Live -and (Test-ConfigDataFile $full))) {
        Send $res 404 $utf8.GetBytes('Not found') 'text/plain; charset=utf-8'; continue
      }
      $ext = [System.IO.Path]::GetExtension($full).ToLower()
      $type = $types[$ext]; if (-not $type) { $type = 'application/octet-stream' }
      $bytes = [System.IO.File]::ReadAllBytes($full)
      if ($Live -and $full -ieq $configPath) {
        # live mode: point the page at the fetcher output and use the real clock (config.json on disk unchanged)
        $txt = $utf8.GetString($bytes).TrimStart([char]0xFEFF)
        $txt = [regex]::Replace($txt, '"dataFile"\s*:\s*(null|"[^"]*")', '"dataFile": "data/latest.json"')
        $txt = [regex]::Replace($txt, '"trackingFile"\s*:\s*(null|"[^"]*")', '"trackingFile": "data/tracking.json"')   # page 2 (optional key)
        $txt = [regex]::Replace($txt, '"sampleClock"\s*:\s*(null|"[^"]*")', '"sampleClock": ""')
        $bytes = $utf8.GetBytes($txt)
      }
      if ($req.HttpMethod -eq 'HEAD') { $bytes = [byte[]]@() }
      Send $res 200 $bytes $type
    } catch {
      try { Send $res 500 $utf8.GetBytes('Server error') 'text/plain; charset=utf-8' } catch { }
    }
  }
} finally {
  $listener.Stop(); $listener.Close()
}
