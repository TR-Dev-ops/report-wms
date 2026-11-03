<#
  lan-common.ps1 - Phase 3 (LAN view) helpers, dot-sourced by server.ps1 and tests\run-tests.ps1
  Pure functions only: no network calls, no file writes, no console output, no system settings.
  Nothing here (or anywhere in this project) runs netsh, changes the firewall or asks for admin rights.

  - Static file allowlist (used in every mode): only the files the two pages need
  - lan.local.json : which IPv4 ranges may open the pages (CIDR) + click quotas
  - client IP check (loopback / allowed IPv4 / refused), Host header check (DNS rebinding)
  - click quotas: per computer (per IP) and total WMS requests per minute (memory only, 60 s window)
#>

# ---------------------------------------------------------------- static files (all modes)
# Paths relative to src\web, '/' separators. Anything else -> 404 (e.g. data/screenshot.local.json,
# data/parse-test.local.json, data/tracking-parse-test.local.json, *.tmp, data/archive/...).
$script:LanStaticExact = @('config.json', 'favicon.ico', 'data/latest.json', 'data/tracking.json', 'data/site.local.json',
  'data/site.sample.json', 'data/sample.json', 'data/tracking.sample.json')
function Test-StaticAllowed([string]$rel) {
  if ([string]::IsNullOrEmpty($rel)) { return $false }
  foreach ($x in $script:LanStaticExact) { if ($rel -ieq $x) { return $true } }
  if ($rel -imatch '\A[A-Za-z0-9_-]+\.html\z') { return $true }
  if ($rel -imatch '\Acss/[A-Za-z0-9_-]+\.css\z') { return $true }
  if ($rel -imatch '\Ajs/[A-Za-z0-9_-]+\.js\z') { return $true }
  return $false
}

# ---------------------------------------------------------------- CIDR / lan.local.json
function ConvertFrom-IPv4Text([string]$text) {
  $m = [regex]::Match($text, '\A(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\z')
  if (-not $m.Success) { return $null }
  [uint32]$v = 0
  for ($i = 1; $i -le 4; $i++) {
    $o = [int]$m.Groups[$i].Value
    if ($o -gt 255) { return $null }
    $v = [uint32]($v * 256 + $o)
  }
  return $v
}
function ConvertTo-IPv4Text([uint32]$v) {
  return '{0}.{1}.{2}.{3}' -f (($v -shr 24) -band 255), (($v -shr 16) -band 255), (($v -shr 8) -band 255), ($v -band 255)
}
# "a.b.c.d/n" (n = 8..32) or a single "a.b.c.d" (= /32). Throws on anything else.
# Wider than /8 (e.g. 0.0.0.0/0) is refused: the file must never open the server to everyone.
function ConvertTo-LanCidr([string]$text) {
  $t = ([string]$text).Trim()
  $m = [regex]::Match($t, '\A([0-9.]+)(?:/(\d{1,2}))?\z')
  if (-not $m.Success) { throw "not a CIDR like 192.0.2.0/24: '$t'" }
  $ip = ConvertFrom-IPv4Text $m.Groups[1].Value
  if ($null -eq $ip) { throw "not an IPv4 address: '$t'" }
  $bits = $(if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 32 })
  if ($bits -lt 8 -or $bits -gt 32) { throw "prefix must be /8 to /32: '$t'" }
  [uint32]$mask = $(if ($bits -eq 32) { [uint32]::MaxValue } else { [uint32]([uint32]::MaxValue - ([uint32]([math]::Pow(2, 32 - $bits)) - 1)) })
  $net = [uint32]($ip -band $mask)
  return [pscustomobject]@{ Net = $net; Mask = $mask; Text = ((ConvertTo-IPv4Text $net) + '/' + $bits) }
}
# RFC 1918 private ranges (built from numbers so no address literal sits in the source)
function Get-LanDefaultAllow {
  return @((ConvertTo-LanCidr ((@(10, 0, 0, 0) -join '.') + '/8')),
           (ConvertTo-LanCidr ((@(172, 16, 0, 0) -join '.') + '/12')),
           (ConvertTo-LanCidr ((@(192, 168, 0, 0) -join '.') + '/16')))
}
# Returns @{ Allow; Defaulted; PerIpPerMinute; WmsPerMinute }. No file / empty "allow" -> private ranges + Defaulted.
# Broken JSON, wrong types or a bad CIDR -> throws (the server then stops; it never falls back to "open").
function Read-LanConfig([string]$path) {
  $cfg = @{ Allow = @(Get-LanDefaultAllow); Defaulted = $true; PerIpPerMinute = 6; WmsPerMinute = 30 }
  if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $cfg }
  $txt = [System.IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding($false))).TrimStart([char]0xFEFF)
  if ($txt.Trim() -eq '') { throw 'file is empty (delete it, or write {"allow": [...]})' }
  try { $j = ConvertFrom-Json -InputObject $txt } catch { throw 'not valid JSON' }
  if ($null -eq $j -or $j -isnot [System.Management.Automation.PSCustomObject]) { throw 'must be a JSON object like {"allow": ["192.0.2.0/24"]}' }
  $a = $j.PSObject.Properties['allow']
  if ($null -ne $a -and $null -ne $a.Value) {
    $list = $a.Value
    if ($list -is [string] -or -not ($list -is [array])) { throw '"allow" must be a list, e.g. ["192.0.2.0/24"]' }
    $out = @()
    foreach ($x in $list) {
      if ($x -isnot [string]) { throw '"allow" must contain text only, e.g. "192.0.2.0/24"' }
      $out += ConvertTo-LanCidr $x
    }
    if ($out.Count -gt 0) { $cfg.Allow = $out; $cfg.Defaulted = $false }
  }
  foreach ($k in @('perIpPerMinute', 'wmsPerMinute')) {
    $p = $j.PSObject.Properties[$k]
    if ($null -eq $p -or $null -eq $p.Value) { continue }
    if (-not ($p.Value -is [int] -or $p.Value -is [long]) -or $p.Value -lt 1 -or $p.Value -gt 600) { throw """$k"" must be a whole number 1-600" }
    if ($k -eq 'perIpPerMinute') { $cfg.PerIpPerMinute = [int]$p.Value } else { $cfg.WmsPerMinute = [int]$p.Value }
  }
  return $cfg
}

# ---------------------------------------------------------------- client IP
# Only the TCP address counts (X-Forwarded-For and similar headers are never read).
# Returns @{ Allowed; Loopback; Key (rate-limit key); Text (shown on the console) }
function Test-LanClient([System.Net.IPAddress]$ip, $allow) {
  $no = [pscustomobject]@{ Allowed = $false; Loopback = $false; Key = ''; Text = $(if ($null -ne $ip) { $ip.ToString() } else { '?' }) }
  if ($null -eq $ip) { return $no }
  if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
    if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
    elseif ([System.Net.IPAddress]::IsLoopback($ip)) { return [pscustomobject]@{ Allowed = $true; Loopback = $true; Key = 'loopback'; Text = '::1' } }
    else { return $no }                                  # other IPv6: refused
  }
  if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $no }
  $text = $ip.ToString()
  if ([System.Net.IPAddress]::IsLoopback($ip)) { return [pscustomobject]@{ Allowed = $true; Loopback = $true; Key = 'loopback'; Text = $text } }
  $v = ConvertFrom-IPv4Text $text
  if ($null -eq $v) { return $no }
  foreach ($c in @($allow)) {
    if ($null -ne $c -and ([uint32]($v -band $c.Mask)) -eq $c.Net) { return [pscustomobject]@{ Allowed = $true; Loopback = $false; Key = $text; Text = $text } }
  }
  $no.Text = $text
  return $no
}

# ---------------------------------------------------------------- this computer: names + LAN IPv4 (read at start, never stored)
function Get-LanLocalIPv4 {
  $out = @()
  try {
    foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
      if ($n.OperationalStatus -ne 'Up') { continue }
      foreach ($u in $n.GetIPProperties().UnicastAddresses) {
        if ($u.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and -not [System.Net.IPAddress]::IsLoopback($u.Address)) { $out += $u.Address.ToString() }
      }
    }
  } catch { }
  return @($out | Select-Object -Unique)
}
function Get-LanHostNames {
  $names = @('localhost', '127.0.0.1', '[::1]')
  try { $names += [Environment]::MachineName } catch { }
  try { $names += [System.Net.Dns]::GetHostName() } catch { }
  try {
    $g = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    if ($g.HostName) { $names += $g.HostName; if ($g.DomainName) { $names += ($g.HostName + '.' + $g.DomainName) } }
  } catch { }
  $names += Get-LanLocalIPv4
  return @($names | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
}
# Host header must be one of $names followed by :<port> (bare name only when the port is 80). Anything else -> $false.
function Test-LanHost([string]$hostHeader, [string[]]$names, [int]$port) {
  if ([string]::IsNullOrWhiteSpace($hostHeader)) { return $false }
  $h = $hostHeader.Trim().ToLowerInvariant()
  foreach ($n in $names) {
    if ($h -ceq ($n + ':' + $port)) { return $true }
    if ($port -eq 80 -and $h -ceq $n) { return $true }
  }
  return $false
}

# ---------------------------------------------------------------- click quotas (memory only, 60 s window)
function New-LanLimiter([int]$perIp, [int]$wmsPerMin) {
  return @{ PerIp = @{}; Wms = (New-Object System.Collections.Generic.List[DateTime]); PerIpMax = $perIp; WmsMax = $wmsPerMin }
}
function Remove-LanOld($lim, [DateTime]$now) {
  foreach ($k in @($lim.PerIp.Keys)) {
    $l = $lim.PerIp[$k]
    while ($l.Count -gt 0 -and ($now - $l[0]).TotalSeconds -ge 60) { $l.RemoveAt(0) }
    if ($l.Count -eq 0) { $lim.PerIp.Remove($k) }
  }
  while ($lim.Wms.Count -gt 0 -and ($now - $lim.Wms[0]).TotalSeconds -ge 60) { $lim.Wms.RemoveAt(0) }
}
function Get-LanWait([DateTime]$oldest, [DateTime]$now) {
  $s = [int][math]::Ceiling(60 - ($now - $oldest).TotalSeconds)
  if ($s -lt 1) { $s = 1 }; if ($s -gt 60) { $s = 60 }
  return $s
}
# One /api/trucks request from one computer. 0 = allowed (and counted), else seconds to wait (not counted).
function Test-LanPerIp($lim, [string]$key, [DateTime]$now) {
  Remove-LanOld $lim $now
  if (-not $lim.PerIp.ContainsKey($key)) { $lim.PerIp[$key] = New-Object System.Collections.Generic.List[DateTime] }
  $l = $lim.PerIp[$key]
  if ($l.Count -ge $lim.PerIpMax) { return (Get-LanWait $l[0] $now) }
  $l.Add($now)
  return 0
}
# Before a click starts: would $cost more WMS requests stay within the total per minute? 0 = yes, else seconds to wait.
function Test-LanWmsBudget($lim, [int]$cost, [DateTime]$now) {
  Remove-LanOld $lim $now
  if ($lim.Wms.Count + $cost -le $lim.WmsMax) { return 0 }
  if ($cost -gt $lim.WmsMax) { return 60 }
  $need = $lim.Wms.Count + $cost - $lim.WmsMax                          # this many oldest entries must expire first
  return (Get-LanWait $lim.Wms[$need - 1] $now)
}
function Add-LanWmsCall($lim, [DateTime]$now) { $lim.Wms.Add($now) }
