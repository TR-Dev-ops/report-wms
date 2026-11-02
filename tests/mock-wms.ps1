<#
  mock-wms.ps1 - TEST ONLY fake WMS on http://localhost:<Port>/wms/ used by run-tests.ps1
  Imitates what was observed on the real WMS without logging in (2026-10-30):
    GET  /wms/user/login        -> login form (txtUserName, txtPassword, no anti-forgery token)
    POST /wms/user/login        -> good user/pass: 302 + cookie ; bad: 200 login form again (ASSUMED behaviour)
    GET  /wms/Report/ReportShipmentSumByProduct -> no session: 302 to /WMS/User/Login ; with session: report HTML
  Test credentials are fake: testuser / test-pass
  Behaviour is switched by <StateDir>\mode.txt :
    normal | report500 | reportbroken | loginchanged | expire2nd | expire2nd-reject
    | tracking500 | trackingbroken | trackinglogin   (page 2: only the Tracking page misbehaves)
    GET  /wms/Report/Tracking -> no session: 302 to /WMS/User/Login ; with session: -TrackingHtml
    POST /wms/Report/GetRptTrackingScheduleList (P2-D truck list, JSON body like the WMS Angular page sends)
         -> no session: 302 ; bad body: 400 ; else JSON array built from -ScheduleJson (fictional rows):
            gateId g, type ''  -> (g % 4) rows, Plate "TST-<g>L<i>" ; type 'WG' -> (g % 3) + 1 rows, Plate "TST-<g>P<i>"
         modes: schedlogin (always 302) | schedexpire (1st call of the mode: session dropped + 302)
                sched500 / schedslow / schedbad : only the gate in <StateDir>\failgate.txt answers 500 / sleeps 4 s / HTML
  Every request is appended to <StateDir>\requests.log as "METHOD /path" (schedule calls: "... gate=<g> type=<t>")
#>
param([int]$Port, [string]$StateDir, [string]$ReportHtml, [string]$TrackingHtml, [string]$ScheduleJson)
Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$loginForm = '<html><head><title>Login</title></head><body><form action="/wms/user/login" method="post">' +
  '<input type="text" id="txtUserName" name="txtUserName"><input type="password" id="txtPassword" name="txtPassword">' +
  '<button class="btn btn-login">LOGIN NOW</button></form></body></html>'
$sessions = @{}
$reportCount = 0
$schedCount = 0
$rejectAll = $false
$lastMode = ''
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
[IO.File]::WriteAllText((Join-Path $StateDir 'ready.txt'), 'ready')

function Reply($res, [int]$code, [string]$body, [string]$location) {
  $res.StatusCode = $code
  if ($location) { $res.RedirectLocation = $location }
  $res.ContentType = 'text/html; charset=utf-8'
  $b = $utf8.GetBytes($body)
  $res.ContentLength64 = $b.Length
  $res.OutputStream.Write($b, 0, $b.Length)
  $res.OutputStream.Close()
}

while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  $req = $ctx.Request; $res = $ctx.Response
  $mode = 'normal'
  $mf = Join-Path $StateDir 'mode.txt'
  if (Test-Path $mf) { $mode = ([IO.File]::ReadAllText($mf)).Trim() }
  if ($mode -ne $lastMode) { $reportCount = 0; $schedCount = 0; $rejectAll = $false; $lastMode = $mode }
  $path = $req.Url.AbsolutePath
  $reqBody = ''
  if ($req.HttpMethod -eq 'POST') { $sr0 = New-Object IO.StreamReader($req.InputStream, $utf8); $reqBody = $sr0.ReadToEnd(); $sr0.Close() }
  $extra = ''
  $sj = $null
  if ($path -ieq '/wms/Report/GetRptTrackingScheduleList') {
    try { $sj = ConvertFrom-Json -InputObject $reqBody } catch { }
    if ($sj) { $extra = " gate=$($sj.gateId) type=$($sj.type)" }
  }
  [IO.File]::AppendAllText((Join-Path $StateDir 'requests.log'), "$($req.HttpMethod) $path$extra`r`n")
  $cookie = $req.Cookies['MOCKAUTH']
  $valid = $null -ne $cookie -and $sessions.ContainsKey($cookie.Value)
  try {
    if ($path -ieq '/wms/user/login' -and $req.HttpMethod -eq 'GET') {
      if ($mode -eq 'loginchanged') { Reply $res 200 '<html><body><form action="/wms/sso" method="post"><input name="otp"></form></body></html>' $null }
      else { Reply $res 200 $loginForm $null }
    }
    elseif ($path -ieq '/wms/user/login' -and $req.HttpMethod -eq 'POST') {
      $body = $reqBody
      $f = @{}; foreach ($kv in $body.Split('&')) { $p = $kv.Split('=', 2); if ($p.Count -eq 2) { $f[[Uri]::UnescapeDataString($p[0])] = [Uri]::UnescapeDataString($p[1]) } }
      if (-not $rejectAll -and $f['txtUserName'] -eq 'testuser' -and $f['txtPassword'] -eq 'test-pass') {
        $id = [guid]::NewGuid().ToString('N'); $sessions[$id] = $true
        $res.Headers.Add('Set-Cookie', "MOCKAUTH=$id; path=/; HttpOnly")
        Reply $res 302 'moved' '/wms/'
      } else { Reply $res 200 $loginForm $null }
    }
    elseif ($path -ieq '/wms/Report/ReportShipmentSumByProduct' -and $req.HttpMethod -eq 'GET') {
      if (-not $valid) { $res.Headers.Add('Set-Cookie', 'ASP.NET_SessionId=x; path=/'); Reply $res 302 'moved' '/WMS/User/Login' }
      else {
        $reportCount++
        if (($mode -eq 'expire2nd' -or $mode -eq 'expire2nd-reject') -and $reportCount -eq 2) {
          $sessions.Clear()
          if ($mode -eq 'expire2nd-reject') { $rejectAll = $true }
          Reply $res 302 'moved' '/WMS/User/Login'
        }
        elseif ($mode -eq 'report500') { Reply $res 500 'Server Error' $null }
        elseif ($mode -eq 'reportbroken') { Reply $res 200 '<html><body><h3>Report daily real time activity</h3><p>maintenance</p></body></html>' $null }
        else { Reply $res 200 ([IO.File]::ReadAllText($ReportHtml, $utf8)) $null }
      }
    }
    elseif ($path -ieq '/wms/Report/Tracking' -and $req.HttpMethod -eq 'GET') {
      if (-not $valid -or $mode -eq 'trackinglogin') { Reply $res 302 'moved' '/WMS/User/Login' }
      elseif ($mode -eq 'tracking500') { Reply $res 500 'Server Error' $null }
      elseif ($mode -eq 'trackingbroken') { Reply $res 200 '<html><body><h2>Gate Tracking</h2><p>maintenance</p></body></html>' $null }
      else { Reply $res 200 ([IO.File]::ReadAllText($TrackingHtml, $utf8)) $null }
    }
    elseif ($path -ieq '/wms/Report/GetRptTrackingScheduleList' -and $req.HttpMethod -eq 'POST') {
      $schedCount++
      $fg = ''; $ff = Join-Path $StateDir 'failgate.txt'; if (Test-Path $ff) { $fg = ([IO.File]::ReadAllText($ff)).Trim() }
      $okBody = $null -ne $sj -and [string]$req.ContentType -match '^application/json' -and
        [string]$sj.date -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$' -and $sj.gateId -is [int] -and
        ($sj.type -ceq '' -or $sj.type -ceq 'WG') -and $sj.workType -ceq '' -and $sj.workStyle -ceq '' -and $sj.wheelType -is [int] -and $sj.wheelType -eq 0 -and
        @($sj.PSObject.Properties).Count -eq 6
      if (-not $valid -or $mode -eq 'schedlogin') { Reply $res 302 'moved' '/WMS/User/Login' }
      elseif ($mode -eq 'schedexpire' -and $schedCount -eq 1) { $sessions.Clear(); Reply $res 302 'moved' '/WMS/User/Login' }
      elseif (-not $okBody) { Reply $res 400 'bad request' $null }
      elseif ($mode -eq 'sched500' -and [string]$sj.gateId -eq $fg) { Reply $res 500 'Server Error' $null }
      elseif ($mode -eq 'schedbad' -and [string]$sj.gateId -eq $fg) { Reply $res 200 '<html><body>maintenance</body></html>' $null }
      else {
        if ($mode -eq 'schedslow' -and [string]$sj.gateId -eq $fg) { Start-Sleep -Seconds 4 }
        $src = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($ScheduleJson, $utf8))   # Object[] (no @(): it would wrap the array)
        $g = [int]$sj.gateId
        $n = $(if ($sj.type -ceq 'WG') { ($g % 3) + 1 } else { $g % 4 })
        $rows = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $n; $i++) {
          $o = $src[($g + $i) % $src.Count] | ConvertTo-Json -Depth 3 | ConvertFrom-Json
          $o.Plate = 'TST-' + $g + $(if ($sj.type -ceq 'WG') { 'P' } else { 'L' }) + $i
          [void]$rows.Add($o)
        }
        $res.StatusCode = 200; $res.ContentType = 'application/json; charset=utf-8'
        $b = $utf8.GetBytes((ConvertTo-Json -InputObject $rows -Depth 3 -Compress))
        $res.ContentLength64 = $b.Length; $res.OutputStream.Write($b, 0, $b.Length); $res.OutputStream.Close()
      }
    }
    else { Reply $res 404 'not found' $null }
  } catch { try { $res.Abort() } catch { } }
}
