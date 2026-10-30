<#
  server.ps1 - tiny static web server for wms-realtime-report (Phase 1)
  - Serves the files in .\web on http://localhost:<Port>/ (this computer only)
  - Read-only: answers GET/HEAD for files inside .\web, nothing else
  - Uses only what ships with Windows (PowerShell 5.1 + .NET HttpListener). No install needed.
  - Stop: close this window or press Ctrl+C
#>
param(
  [int]$Port = 8787,
  [switch]$NoBrowser
)
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'web'))
$prefix = "http://localhost:$Port/"

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
  Read-Host 'Press Enter to close'
  exit 1
}

Write-Host "WMS realtime report - Phase 1 (sample data)" -ForegroundColor Cyan
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
$utf8 = New-Object System.Text.UTF8Encoding($false)

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
      if ($req.HttpMethod -eq 'HEAD') { $bytes = [byte[]]@() }
      Send $res 200 $bytes $type
    } catch {
      try { Send $res 500 $utf8.GetBytes('Server error') 'text/plain; charset=utf-8' } catch { }
    }
  }
} finally {
  $listener.Stop(); $listener.Close()
}
