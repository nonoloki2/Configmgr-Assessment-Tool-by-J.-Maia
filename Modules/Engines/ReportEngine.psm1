function ConvertTo-CATHtmlEncoded {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-CATStatusRank {
    param([string]$Status)
    switch ($Status) {
        'Critical' { return 5 }
        'Warning' { return 4 }
        'UnableToCheck' { return 3 }
        'Healthy' { return 2 }
        'Info' { return 1 }
        'NotApplicable' { return 0 }
        default { return 0 }
    }
}

function Get-CATWorstStatus {
    param([object[]]$Items)
    $worst = 'Info'; $rank = -1
    foreach($i in @($Items)){
        $r = Get-CATStatusRank -Status $i.Status
        if($r -gt $rank){ $rank = $r; $worst = $i.Status }
    }
    return $worst
}

function Get-CATStatusDot {
    param([string]$Status)
    switch ($Status) {
        'Healthy' { return '<span class="dot healthy"></span>' }
        'Warning' { return '<span class="dot warning"></span>' }
        'Critical' { return '<span class="dot critical"></span>' }
        'UnableToCheck' { return '<span class="dot unable"></span>' }
        'NotApplicable' { return '<span class="dot na"></span>' }
        default { return '<span class="dot info"></span>' }
    }
}

function New-CATReportTable {
    param([object[]]$Rows,[string[]]$Columns)
    if(-not $Rows -or @($Rows).Count -eq 0){ return '<div class="empty">No data collected for this section.</div>' }
    $thead = '<tr>' + (($Columns | ForEach-Object { '<th>' + (ConvertTo-CATHtmlEncoded $_) + '</th>' }) -join '') + '</tr>'
    $bodyRows = foreach($row in $Rows){
        $cells = foreach($col in $Columns){
            $v = $row.$col
            if($col -eq 'Status') { '<td class="statuscell">' + (Get-CATStatusDot $v) + '<span>' + (ConvertTo-CATHtmlEncoded $v) + '</span></td>' }
            else { '<td>' + (ConvertTo-CATHtmlEncoded $v) + '</td>' }
        }
        '<tr>' + ($cells -join '') + '</tr>'
    }
    return '<table class="cat-table"><thead>' + $thead + '</thead><tbody>' + ($bodyRows -join "`n") + '</tbody></table>'
}

function Convert-CATResultToRows {
    param([object[]]$Results)
    foreach($r in @($Results)){
        [pscustomobject]@{
            Check = $r.Check
            Status = $r.Status
            Value = $r.Value
            Finding = $r.Finding
            Recommendation = $r.Recommendation
            Evidence = $r.Evidence
        }
    }
}

function Export-CATHtmlReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session)

    $reportRoot = Join-Path $Session.AppRoot 'Output\Reports'
    if(-not (Test-Path -LiteralPath $reportRoot)){ New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $shortId = $Session.AssessmentID.Substring(0,8)
    $path = Join-Path $reportRoot ("CAT_Report_{0}_{1}.html" -f $stamp,$shortId)
    $all = @($Session.Results)
    $core = @($all | Where-Object { $_.Module -eq 'CoreHealth' -and $_.Target })
    $servers = @($Session.Inventory.Servers | Sort-Object -Unique)
    if(-not $servers -or $servers.Count -eq 0){ $servers = @($core | Select-Object -ExpandProperty Target -Unique | Sort-Object) }

    $countHealthy = @($all | Where-Object Status -eq 'Healthy').Count
    $countWarning = @($all | Where-Object Status -eq 'Warning').Count
    $countCritical = @($all | Where-Object Status -eq 'Critical').Count
    $countUnable = @($all | Where-Object Status -eq 'UnableToCheck').Count
    $siteCode = if($Session.Inventory.Site -and $Session.Inventory.Site.SiteCode){$Session.Inventory.Site.SiteCode}else{'Unknown'}
    $roleCount = @($Session.Inventory.Roles).Count
    $serverCount = @($servers).Count

    $cards = New-Object System.Collections.Generic.List[string]
    foreach($server in $servers){
        $srvResults = @($core | Where-Object Target -eq $server)
        $roles = @($Session.Inventory.Roles | Where-Object ServerName -eq $server | Select-Object -ExpandProperty RoleName -Unique)
        $status = Get-CATWorstStatus -Items $srvResults
        $statusClass = switch($status){ 'Critical'{'critical'} 'Warning'{'warning'} 'UnableToCheck'{'unable'} 'Healthy'{'healthy'} default{'info'} }
        $roleBadges = if($roles){ ($roles | ForEach-Object { '<span class="badge">' + (ConvertTo-CATHtmlEncoded $_) + '</span>' }) -join ' ' } else { '<span class="badge muted">No role data</span>' }
        $osRows = Convert-CATResultToRows @($srvResults | Where-Object Category -eq 'Operating System')
        $patchRows = Convert-CATResultToRows @($srvResults | Where-Object Category -eq 'Patch Evidence')
        $connectRows = Convert-CATResultToRows @($srvResults | Where-Object Category -eq 'Connectivity')
        $storageRows = Convert-CATResultToRows @($srvResults | Where-Object Category -eq 'Storage')
        $memoryRows = Convert-CATResultToRows @($srvResults | Where-Object Category -eq 'Memory')
        $cpuRows = Convert-CATResultToRows @($srvResults | Where-Object Category -eq 'CPU')
        $serviceRows = Convert-CATResultToRows @($srvResults | Where-Object Category -eq 'Services')
        $storageCards = foreach($d in @($srvResults | Where-Object Category -eq 'Storage')){
            $pct = 0; $free = '' ; $total = ''
            if($d.Value -match 'Free=([^;]+); FreePct=([0-9\.]+)%'){ $free = $Matches[1]; $pct=[double]$Matches[2] }
            if($d.Value -match 'Total=([^;]+);'){ $total = $Matches[1] }
            $barStatus = switch($d.Status){ 'Critical'{'critical'} 'Warning'{'warning'} 'Healthy'{'healthy'} default{'info'} }
            $widthPct = ([math]::Min(100,[math]::Max(0,$pct))).ToString('0.##',[Globalization.CultureInfo]::InvariantCulture)
            '<div class="disk-card"><div class="disk-head"><strong>' + (ConvertTo-CATHtmlEncoded $d.Check) + '</strong><span>' + (Get-CATStatusDot $d.Status) + (ConvertTo-CATHtmlEncoded $d.Status) + '</span></div><div class="bar"><span class="' + $barStatus + '" style="width:' + $widthPct + '%"></span></div><div class="disk-meta">Free: ' + (ConvertTo-CATHtmlEncoded $free) + ' (' + (ConvertTo-CATHtmlEncoded $pct) + '%) / Total: ' + (ConvertTo-CATHtmlEncoded $total) + '</div></div>'
        }
        if(-not $storageCards){ $storageCards = @('<div class="empty">No disk data collected.</div>') }
        $serverAnchor = ($server -replace '[^A-Za-z0-9_-]','_')
        $card = @"
<section class="server-card $statusClass" data-server="$(ConvertTo-CATHtmlEncoded $server)" data-status="$status" data-roles="$(ConvertTo-CATHtmlEncoded ($roles -join ' '))" id="$serverAnchor">
  <button class="server-header" onclick="toggleCard(this)">
    <span class="server-title">🖥️ $(ConvertTo-CATHtmlEncoded $server)</span>
    <span class="server-status">$(Get-CATStatusDot $status) $(ConvertTo-CATHtmlEncoded $status)</span>
  </button>
  <div class="server-body">
    <div class="roles">$roleBadges</div>
    <div class="tabs-mini">
      <button onclick="showTab(this,'overview')" class="active">Overview</button>
      <button onclick="showTab(this,'os')">Operating System</button>
      <button onclick="showTab(this,'storage')">Storage</button>
      <button onclick="showTab(this,'services')">Services</button>
    </div>
    <div class="tab-panel overview active">
      <div class="mini-grid">
        <div><h4>Connectivity</h4>$(New-CATReportTable -Rows $connectRows -Columns @('Check','Status','Value','Finding'))</div>
        <div><h4>Memory</h4>$(New-CATReportTable -Rows $memoryRows -Columns @('Check','Status','Value','Finding'))</div>
        <div><h4>CPU</h4>$(New-CATReportTable -Rows $cpuRows -Columns @('Check','Status','Value','Finding'))</div>
      </div>
    </div>
    <div class="tab-panel os">
      <h4>Operating System</h4>
      $(New-CATReportTable -Rows $osRows -Columns @('Check','Status','Value','Finding','Evidence'))
      <h4>Patch Evidence</h4>
      $(New-CATReportTable -Rows $patchRows -Columns @('Check','Status','Value','Finding','Evidence'))
    </div>
    <div class="tab-panel storage">
      <h4>Storage Cards</h4>
      <div class="disk-grid">$($storageCards -join "`n")</div>
      <h4>Storage Details</h4>
      $(New-CATReportTable -Rows $storageRows -Columns @('Check','Status','Value','Finding','Recommendation'))
    </div>
    <div class="tab-panel services">
      <h4>Services</h4>
      $(New-CATReportTable -Rows $serviceRows -Columns @('Check','Status','Value','Finding'))
    </div>
  </div>
</section>
"@
        $cards.Add($card) | Out-Null
    }

    $css = @'
:root{--bg:#f5f7fb;--card:#fff;--text:#1d1d1f;--muted:#606975;--line:#dde3ea;--green:#25a55b;--yellow:#d99a16;--red:#d63b3b;--blue:#2f6fed;--gray:#7b8794}*{box-sizing:border-box}body{margin:0;font-family:Segoe UI,Arial,sans-serif;background:var(--bg);color:var(--text)}header{position:sticky;top:0;z-index:2;background:#fff;border-bottom:1px solid var(--line);padding:18px 26px;box-shadow:0 2px 10px rgba(0,0,0,.04)}h1{margin:0;font-size:26px}.subtitle{color:var(--muted);margin-top:6px}.layout{display:grid;grid-template-columns:280px 1fr;gap:18px;padding:18px}.side{position:sticky;top:104px;align-self:start}.panel{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:14px;box-shadow:0 1px 5px rgba(0,0,0,.04)}.metric{display:flex;justify-content:space-between;margin:8px 0}.metric strong{font-size:18px}.filters input,.filters select{width:100%;margin:6px 0 10px 0;padding:9px;border:1px solid var(--line);border-radius:8px}.server-card{background:var(--card);border:1px solid var(--line);border-radius:14px;margin-bottom:14px;overflow:hidden;box-shadow:0 1px 6px rgba(0,0,0,.04)}.server-card.critical{border-left:6px solid var(--red)}.server-card.warning{border-left:6px solid var(--yellow)}.server-card.healthy{border-left:6px solid var(--green)}.server-card.unable{border-left:6px solid var(--gray)}.server-header{width:100%;background:#fff;border:0;border-bottom:1px solid var(--line);padding:16px 18px;display:flex;justify-content:space-between;align-items:center;font-size:18px;cursor:pointer;text-align:left}.server-title{font-weight:700}.server-body{padding:16px 18px}.roles{margin-bottom:12px}.badge{display:inline-block;background:#eef4ff;color:#1d4f91;border:1px solid #c9ddff;border-radius:999px;padding:4px 9px;margin:2px;font-size:12px;font-weight:600}.badge.muted{background:#f0f0f0;color:#666;border-color:#ddd}.dot{display:inline-block;width:12px;height:12px;border-radius:50%;margin-right:8px;vertical-align:middle}.dot.healthy{background:var(--green)}.dot.warning{background:var(--yellow)}.dot.critical{background:var(--red)}.dot.unable{background:var(--gray)}.dot.info{background:var(--blue)}.dot.na{background:#c9ced6}.summary-row{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}.summary-card{background:#fff;border:1px solid var(--line);border-radius:12px;padding:14px}.summary-card span{color:var(--muted)}.summary-card strong{display:block;font-size:24px;margin-top:4px}.tabs-mini{display:flex;gap:8px;margin-bottom:14px;flex-wrap:wrap}.tabs-mini button{border:1px solid var(--line);background:#f7f9fc;border-radius:999px;padding:7px 12px;cursor:pointer}.tabs-mini button.active{background:#1f6feb;color:#fff;border-color:#1f6feb}.tab-panel{display:none}.tab-panel.active{display:block}.mini-grid{display:grid;grid-template-columns:1fr;gap:14px}.cat-table{width:100%;border-collapse:collapse;background:#fff;border:1px solid var(--line);border-radius:8px;overflow:hidden}.cat-table th{background:#f2f5f9;text-align:left;padding:9px;border-bottom:1px solid var(--line);font-size:12px;color:#46515e}.cat-table td{padding:9px;border-bottom:1px solid #eef1f5;vertical-align:top;font-size:13px}.statuscell{white-space:nowrap}.disk-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:12px}.disk-card{border:1px solid var(--line);border-radius:12px;padding:12px;background:#fbfcfe}.disk-head{display:flex;justify-content:space-between;margin-bottom:10px}.bar{height:12px;background:#e9edf3;border-radius:999px;overflow:hidden}.bar span{display:block;height:100%;border-radius:999px}.bar span.healthy{background:var(--green)}.bar span.warning{background:var(--yellow)}.bar span.critical{background:var(--red)}.bar span.info{background:var(--blue)}.disk-meta{color:var(--muted);font-size:12px;margin-top:8px}.empty{color:var(--muted);font-style:italic;padding:10px}.hidden{display:none!important}.toc{max-height:360px;overflow:auto}.toc a{display:block;color:#1f6feb;text-decoration:none;margin:6px 0;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}@media(max-width:950px){.layout{grid-template-columns:1fr}.side{position:static}.summary-row{grid-template-columns:repeat(2,1fr)}}
'@
    $toc = ($servers | ForEach-Object { $anchor = ($_ -replace '[^A-Za-z0-9_-]','_'); '<a href="#' + $anchor + '">' + (ConvertTo-CATHtmlEncoded $_) + '</a>' }) -join "`n"
    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>ConfigMgr Assessment Report - $(ConvertTo-CATHtmlEncoded $siteCode)</title>
<style>$css</style>
</head>
<body>
<header>
  <h1>ConfigMgr Assessment Tool by J. Maia</h1>
  <div class="subtitle">Version 1.4.0-alpha | Build 0011 | Assessment ID: $(ConvertTo-CATHtmlEncoded $Session.AssessmentID) | Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
</header>
<div class="layout">
  <aside class="side">
    <div class="panel filters">
      <h3>Filters</h3>
      <input id="searchBox" placeholder="Search server..." oninput="applyFilters()" />
      <select id="statusFilter" onchange="applyFilters()">
        <option value="all">All statuses</option>
        <option value="Critical">Critical</option>
        <option value="Warning">Warning</option>
        <option value="Healthy">Healthy</option>
        <option value="UnableToCheck">UnableToCheck</option>
      </select>
      <input id="roleFilter" placeholder="Filter by role badge..." oninput="applyFilters()" />
    </div>
    <div class="panel">
      <h3>Environment</h3>
      <div class="metric"><span>Site</span><strong>$(ConvertTo-CATHtmlEncoded $siteCode)</strong></div>
      <div class="metric"><span>Servers</span><strong>$serverCount</strong></div>
      <div class="metric"><span>Role instances</span><strong>$roleCount</strong></div>
    </div>
    <div class="panel toc"><h3>Servers</h3>$toc</div>
  </aside>
  <main>
    <div class="summary-row">
      <div class="summary-card"><span>Healthy</span><strong>$countHealthy</strong></div>
      <div class="summary-card"><span>Warning</span><strong>$countWarning</strong></div>
      <div class="summary-card"><span>Critical</span><strong>$countCritical</strong></div>
      <div class="summary-card"><span>Unable to check</span><strong>$countUnable</strong></div>
    </div>
    <div style="height:14px"></div>
    $($cards -join "`n")
  </main>
</div>
<script>
function toggleCard(btn){ var body = btn.parentElement.querySelector('.server-body'); body.classList.toggle('hidden'); }
function showTab(btn, cls){ var card = btn.closest('.server-body'); card.querySelectorAll('.tabs-mini button').forEach(function(b){b.classList.remove('active')}); btn.classList.add('active'); card.querySelectorAll('.tab-panel').forEach(function(p){p.classList.remove('active')}); card.querySelector('.tab-panel.'+cls).classList.add('active'); }
function applyFilters(){ var q=(document.getElementById('searchBox').value||'').toLowerCase(); var st=document.getElementById('statusFilter').value; var role=(document.getElementById('roleFilter').value||'').toLowerCase(); document.querySelectorAll('.server-card').forEach(function(c){ var match=true; if(q && c.dataset.server.toLowerCase().indexOf(q)<0) match=false; if(st!='all' && c.dataset.status!=st) match=false; if(role && c.dataset.roles.toLowerCase().indexOf(role)<0) match=false; c.classList.toggle('hidden', !match); }); }
</script>
</body>
</html>
"@
    $html | Set-Content -LiteralPath $path -Encoding UTF8
    $Session | Add-Member -NotePropertyName LastHtmlPath -NotePropertyValue $path -Force
    return $path
}

Export-ModuleMember -Function *
