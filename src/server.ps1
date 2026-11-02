<#
  server.ps1 - tiny web server for wms-realtime-report
  - Serves the files in .\web on http://localhost:<Port>/ (this computer only)
  - Answers GET/HEAD for files inside .\web, plus one API (below). Nothing else.
  - Uses only what ships with Windows (PowerShell 5.1 + .NET HttpListener). No install needed.
  - -Live : Phase 2. Serves config.json with "dataFile": "data/latest.json" and "sampleClock": ""
            (page 2 then reads data/tracking.json; an optional "trackingFile" key is rewritten too)
            (the file on disk is NOT changed, so start.cmd keeps showing sample data)
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
  [int]$TrucksBudgetSec = 20  # no new WMS request after this many seconds of one click
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

$types = @{
  '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
  '.js' = 'application/javascript; charset=utf-8'; '.json' = 'application/json; charset=utf-8'
  '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try { $listener.Start() } catch {
  Write-Host "Cannot start web server on port $Port. Another program may be using it." -ForegroundColor Red
  Write-Host "Try: powershell -ExecutionPolicy Bypass -File server.ps1 -Port 8788"
  Write-Host $_.Exception.Message
  if (-not $NoBrowser) { Read-Host 'Press Enter to close' }
  exit 1
}

if ($Live) { Write-Host "WMS realtime report - LIVE data (data/latest.json written by fetch-wms.ps1)" -ForegroundColor Cyan }
else { Write-Host "WMS realtime report - data file from config.json (default: sample data)" -ForegroundColor Cyan }
Write-Host "Open: $prefix"
Write-Host "Serving: $root"
Write-Host "Keep this window open. Close it (or Ctrl+C) to stop."
if (-not $NoBrowser) { Start-Process $prefix }

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

function New-TruckAnswer([string]$mode, [string]$wh, [string]$status, [string]$message, $gates, $failed, $loading, $plan) {
  $a = New-Object System.Collections.ArrayList; foreach ($x in @($gates)) { if ($null -ne $x) { [void]$a.Add($x) } }
  $f = New-Object System.Collections.ArrayList; foreach ($x in @($failed)) { if ($null -ne $x) { [void]$f.Add($x) } }
  $l = New-Object System.Collections.ArrayList; foreach ($x in @($loading)) { if ($null -ne $x) { [void]$l.Add($x) } }
  $p = New-Object System.Collections.ArrayList; foreach ($x in @($plan)) { if ($null -ne $x) { [void]$p.Add($x) } }
  return [pscustomobject][ordered]@{
    schemaVersion = 1; mode = $mode; wh = $wh; status = $status; message = $message
    gates = $a; failedGates = $f; loading = $l; plan = $p
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
  $ld = & $make ($seed % 3) $seed
  $pl = & $make (($seed % 5) + 2) ($seed + 101)
  return New-TruckAnswer 'sample' $wh 'ok' '' $gates @() $ld $pl
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
    $page = Invoke-Wms 'GET' $cfg.LoginUrl $null
    if ($page.Status -ne 200 -or $page.Body -notmatch '(?i)name\s*=\s*["'']?txtUserName' -or $page.Body -notmatch '(?i)name\s*=\s*["'']?txtPassword') {
      Write-Line "trucks: WMS login page not recognised (HTTP $($page.Status)) - password not sent"
      return 'error'
    }
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
function Invoke-ScheduleCall($cfg, [int]$gateId, [string]$type) {
  if (-not $script:Wms.LoggedIn) {
    if ($script:Wms.Logins -ge 1) { return @{ kind = 'session' } }       # at most one login per click
    $c = Connect-WmsServer $cfg
    if ($c -ne 'ok') { return @{ kind = $c } }
  }
  # same JSON as the WMS page (TrackingService.js): date = JSON of new Date() (UTC ISO), the rest as in the ng-click
  $date = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", $Inv)
  $json = '{"date":"' + $date + '","gateId":' + $gateId + ',"type":"' + $type + '","workType":"","workStyle":"","wheelType":0}'
  $call = { Invoke-Wms 'POST' $cfg.ScheduleUrl $json 'application/json;charset=utf-8' 'application/json, text/plain, */*' }
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

function Handle-Trucks($req, $res) {
  $wh = [string]$req.QueryString['wh']
  if ($wh -cnotmatch '\A[A-Za-z0-9_-]{1,32}\z') {          # \z: no trailing newline (unlike $)
    Send $res 400 $utf8.GetBytes('{"schemaVersion":1,"status":"bad_request"}') 'application/json; charset=utf-8'; return
  }
  $now = [DateTime]::Now
  foreach ($k in @($script:Reuse.Keys)) { if (($now - $script:Reuse[$k].At).TotalSeconds -ge $REUSE_SEC) { $script:Reuse.Remove($k) } }
  if ($Live -and $script:Reuse.ContainsKey($wh)) {
    Write-Line "trucks wh=$wh same answer as $([int]($now - $script:Reuse[$wh].At).TotalSeconds) s ago (no WMS call)"
    Send $res 200 $script:Reuse[$wh].Bytes 'application/json; charset=utf-8'; return
  }
  $gates = Get-WarehouseGates $wh
  if ($gates.Count -eq 0) {
    $a = New-TruckAnswer $(if ($Live) { 'live' } else { 'sample' }) $wh 'unknown_wh' '' @() @() @() @()
    Send $res 404 $utf8.GetBytes((ConvertTo-Json -InputObject $a -Depth 4 -Compress)) 'application/json; charset=utf-8'; return
  }
  if ($Live) { $a = Get-LiveTrucks $wh $gates } else { $a = Get-SampleTrucks $wh $gates }
  $bytes = $utf8.GetBytes((ConvertTo-Json -InputObject $a -Depth 4 -Compress))
  $n = @($a.loading).Count + @($a.plan).Count
  $extra = $(if (@($a.failedGates).Count) { " failed=$(@($a.failedGates).Count)" } else { '' }) + $(if ($a.message) { " ($($a.message))" } else { '' })
  Write-Line ("trucks wh={0} gates={1} {2} n={3}{4}{5}" -f $wh, $gates.Count, $a.status, $n, $extra, $(if ($Live) { '' } else { ' [sample]' }))
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
      # Phase 1 = this computer only. http.sys accepts connections on all interfaces,
      # so refuse every request that does not come from a loopback address.
      $remote = $req.RemoteEndPoint
      if (-not $req.IsLocal -or $null -eq $remote -or -not [System.Net.IPAddress]::IsLoopback($remote.Address)) {
        Send $res 403 $utf8.GetBytes('Forbidden: this computer only') 'text/plain; charset=utf-8'; continue
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
        Handle-Trucks $req $res; continue
      }
      if ($req.HttpMethod -ne 'GET' -and $req.HttpMethod -ne 'HEAD') {
        Send $res 405 $utf8.GetBytes('Method not allowed') 'text/plain; charset=utf-8'; continue
      }
      $rel = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath).TrimStart('/')
      if ($rel -eq '') { $rel = 'index.html' }
      $full = [System.IO.Path]::GetFullPath((Join-Path $root $rel))
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
