<#
  mock-wms.ps1 - TEST ONLY fake WMS on http://localhost:<Port>/wms/ used by run-tests.ps1
  Imitates what was observed on the real WMS without logging in (2026-10-30):
    GET  /wms/user/login        -> login form (txtUserName, txtPassword, no anti-forgery token)
    POST /wms/user/login        -> good user/pass: 302 + cookie ; bad: 200 login form again (ASSUMED behaviour)
    GET  /wms/Report/ReportShipmentSumByProduct -> no session: 302 to /WMS/User/Login ; with session: report HTML
  Test credentials are fake: testuser / test-pass
  Behaviour is switched by <StateDir>\mode.txt :
    normal | report500 | reportbroken | loginchanged | expire2nd | expire2nd-reject
  Every request is appended to <StateDir>\requests.log as "METHOD /path"
#>
param([int]$Port, [string]$StateDir, [string]$ReportHtml)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$loginForm = '<html><head><title>Login</title></head><body><form action="/wms/user/login" method="post">' +
  '<input type="text" id="txtUserName" name="txtUserName"><input type="password" id="txtPassword" name="txtPassword">' +
  '<button class="btn btn-login">LOGIN NOW</button></form></body></html>'
$sessions = @{}
$reportCount = 0
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
  if ($mode -ne $lastMode) { $reportCount = 0; $rejectAll = $false; $lastMode = $mode }
  $path = $req.Url.AbsolutePath
  [IO.File]::AppendAllText((Join-Path $StateDir 'requests.log'), "$($req.HttpMethod) $path`r`n")
  $cookie = $req.Cookies['MOCKAUTH']
  $valid = $null -ne $cookie -and $sessions.ContainsKey($cookie.Value)
  try {
    if ($path -ieq '/wms/user/login' -and $req.HttpMethod -eq 'GET') {
      if ($mode -eq 'loginchanged') { Reply $res 200 '<html><body><form action="/wms/sso" method="post"><input name="otp"></form></body></html>' $null }
      else { Reply $res 200 $loginForm $null }
    }
    elseif ($path -ieq '/wms/user/login' -and $req.HttpMethod -eq 'POST') {
      $sr = New-Object IO.StreamReader($req.InputStream, $utf8); $body = $sr.ReadToEnd(); $sr.Close()
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
    else { Reply $res 404 'not found' $null }
  } catch { try { $res.Abort() } catch { } }
}
