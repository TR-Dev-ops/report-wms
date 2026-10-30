<#
  make-fixture.ps1 - builds tests\fixtures\report-sample.html from src\web\data\sample.json (FICTIONAL numbers)
  The HTML layout imitates the WMS report page seen in the owner's screenshot (2 header rows, "07:01 - 08:00 น." periods,
  thousands separators, Total row). It is NOT a copy of the real HTML - the parser must still be confirmed with a page
  the owner saves into samples\ (see README).
  -Source <data.json> -Out <file.html> : build from another data file (used by run-tests.ps1)
#>
param([string]$Source, [string]$Out)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$inv = [Globalization.CultureInfo]::InvariantCulture
if (-not $Source) { $Source = Join-Path $root 'src\web\data\sample.json' }
$d = [IO.File]::ReadAllText($Source, [Text.Encoding]::UTF8) | ConvertFrom-Json
function K($v) { ([decimal]$v).ToString('#,##0.000', $inv) }
function P($v) { ([decimal]$v).ToString('0.00', $inv) }
function I($v) { ([int]$v).ToString('0', $inv) }
function Cells($label, $r, $tag) {
  "      <tr>`n        <$tag>$label</$tag>" +
  "<td class=""text-right"">$(P $r.workloadPct)</td><td class=""text-right"">$(K $r.weightKg)</td><td class=""text-right"">$(K $r.completeKg)</td>" +
  "<td class=""text-right"">$(K $r.remainingKg)</td><td class=""text-right"">$(P $r.completePct)</td>" +
  "<td class=""text-right"">$(I $r.truckCheckIn)</td><td class=""text-right"">$(I $r.truckOutbound)</td><td class=""text-right"">$(I $r.truckComplete)</td>" +
  "<td class=""text-right"">$(I $r.truckRemaining)</td><td class=""text-right"">$(P $r.truckCompletePct)</td>`n      </tr>"
}
$rows = foreach ($r in $d.rows) { $lbl = ($r.period -replace '-', ' - ') + ' น.'; Cells $lbl $r 'td' }
$t = $d.total
$total = Cells 'Total' $t 'td'
$total = $total.Replace('<td class="text-right">' + (P $t.workloadPct) + '</td>', '<td class="text-right">100</td>')
$html = @"
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>Report daily real time activity</title>
  <!-- TEST FIXTURE: fictional numbers from sample.json, layout imitates the WMS screenshot -->
</head>
<body>
  <div class="header"><span class="user">Logged in as TEST USER</span> <a href="#">Change Password</a> <a href="#">Logout</a></div>
  <ul class="nav"><li><a href="#">Shipment</a></li><li><a href="#">Report</a></li></ul>
  <div class="page-title"><h3>Report daily real time activity</h3><h3>รายงานแจกแจงปริมาณงานรายชั่วโมง</h3></div>
  <div class="panel">
    <h4><b>Outbound the amount of work each day</b></h4>
    <table class="table table-bordered table-condensed">
      <thead>
      <tr>
        <th rowspan="2">Period</th><th>Workload<br/>over time</th><th colspan="4">Outbound</th><th colspan="5">Truck</th>
      </tr>
      <tr>
        <th>%</th><th>Weight (Kg.)</th><th>Complete</th><th>Remaining</th><th>Complete<br/>%</th>
        <th>Check in</th><th>Outbound</th><th>Complete</th><th>Remaining</th><th>Complete<br/>%</th>
      </tr>
      </thead>
      <tbody>
$($rows -join "`n")
$total
      </tbody>
    </table>
  </div>
</body>
</html>
"@
$out = $(if ($Out) { $Out } else { Join-Path $PSScriptRoot 'fixtures\report-sample.html' })
[IO.File]::WriteAllText($out, $html, (New-Object Text.UTF8Encoding($false)))
"Written: $out"
