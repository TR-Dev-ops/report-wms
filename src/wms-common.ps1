<#
  wms-common.ps1 - helpers shared by fetch-wms.ps1 and server.ps1 (dot-sourced: . "$PSScriptRoot\wms-common.ps1")
  The caller must define in its script scope:
    $Utf8        UTF8Encoding without BOM
    $TimeoutSec  per-request timeout in seconds
    $script:Cookies  a System.Net.CookieContainer (the WMS session cookie, memory only)
  Nothing here writes to disk or prints anything.
#>

# Reads WMS_BASE_URL / WMS_USERNAME / WMS_PASSWORD (and any KEY=value line) from a .env file. Returns $null if missing.
# The values are never printed or logged by the callers.
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

# PowerShell wraps .NET exceptions (MethodInvocationException); find the WebException inside, if any
function Get-WebException($ex) {
  while ($null -ne $ex) {
    if ($ex -is [System.Net.WebException]) { return $ex }
    $ex = $ex.InnerException
  }
  return $null
}

# One HTTP request. Redirects are never followed, no system proxy, cookie container = $script:Cookies.
# Returns @{ Status; Location; Body; ContentType }. Network errors / timeouts throw (caller maps them).
function Invoke-Wms([string]$method, [string]$url, [string]$body,
                    [string]$contentType = 'application/x-www-form-urlencoded', [string]$accept = 'text/html,application/xhtml+xml') {
  $req = [System.Net.HttpWebRequest]::Create($url)
  $req.Method = $method
  $req.AllowAutoRedirect = $false
  $req.Proxy = $null                  # connect directly to the internal WMS; never send the password via a system proxy
  $req.CookieContainer = $script:Cookies
  $req.Timeout = $TimeoutSec * 1000
  $req.ReadWriteTimeout = $TimeoutSec * 1000
  $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) wms-realtime-report/2 (read-only)'
  $req.Accept = $accept
  if ($method -eq 'POST') {
    $bytes = $Utf8.GetBytes([string]$body)
    $req.ContentType = $contentType
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
    $text = $sr.ReadToEnd(); $sr.Close()
    return @{ Status = [int]$res.StatusCode; Location = [string]$res.Headers['Location']; Body = $text; ContentType = [string]$res.ContentType }
  } finally { $res.Close() }
}

# WMS answered with (or redirected to) the login page = no valid session
function Test-IsLoginPage($r) {
  if ($r.Status -ge 300 -and $r.Status -lt 400) { return ($r.Location -match '(?i)/user/login') }
  if ($r.Status -eq 401) { return $true }
  return ($r.Status -eq 200 -and $r.Body -match '(?i)name\s*=\s*["'']?txtPassword')
}
