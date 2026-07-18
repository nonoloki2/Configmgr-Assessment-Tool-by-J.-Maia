<#
.SYNOPSIS
    Patch Management Modern Workplace Report - gera um relatório executivo em HTML
    (com gráficos) do status de um Deployment de Software Updates (patch mensal) no
    SCCM/MECM, para uma Collection específica. Pode ser usado via janela gráfica
    (Windows Forms) ou via linha de comando (para automação/agendamento).

.DESCRIPTION
    Conecta diretamente no banco SQL do site SCCM (somente leitura, views padrão) e monta
    um relatório HTML autocontido (CSS + Chart.js via CDN) com:
      - KPIs (total de máquinas, sucesso, erro, desconhecido, pendente de reboot)
      - Gráfico de pizza (Sucesso / Erro / Unknown)
      - Gráfico de barras (compliance por Site)
      - Banner de SLA (30 dias corridos a partir do início do deployment, por padrão)
      - Resumo executivo em texto (gerado automaticamente)
      - Tabela detalhada por host, com busca, filtros, ordenação e exportação CSV
      - Alternância de idioma PT-BR / EN-US (rótulos da interface)

.PARAMETER DeploymentID
    AssignmentID do deployment de patch no SCCM (ex: "ABC20123").

.PARAMETER CollectionID
    CollectionID alvo do deployment (ex: "ABC00456").

.PARAMETER SqlServer
    Instância SQL do site (ex: "SCCMSQL01\SCCM" ou "SCCMSQL01,1433").

.PARAMETER Database
    Nome do banco do site (ex: "CM_ABC").

.PARAMETER DemoMode
    Gera o relatório com dados fictícios, sem conectar no SQL. Útil para validar o
    design/layout antes de plugar no ambiente real.

.PARAMETER SlaDays
    Prazo de SLA, em dias corridos, contados a partir do início (StartTime) do
    deployment. Usado para o banner de alerta (verde/amarelo/vermelho) no topo do
    relatório. Padrão: 30 dias.

.PARAMETER Gui
    Força a abertura da janela gráfica mesmo que outros parâmetros tenham sido informados.

.EXAMPLE
    .\Generate-SCCMPatchReport.ps1
    (sem nenhum parâmetro -> abre a janela gráfica "Patch Management Modern Workplace Report")

.EXAMPLE
    .\Generate-SCCMPatchReport.ps1 -DemoMode -OutputPath .\Reports

.EXAMPLE
    .\Generate-SCCMPatchReport.ps1 -DeploymentID "ABC20123" -CollectionID "ABC00456" `
        -SqlServer "SCCMSQL01\SCCM" -Database "CM_ABC" -CompanyName "Acme IT Services" `
        -ComplianceTarget 99
#>

[CmdletBinding()]
param(
    [string]$DeploymentID,
    [string]$CollectionID,
    [string]$SqlServer,
    [string]$Database,
    [switch]$DemoMode,
    [switch]$Gui,
    [string]$OutputPath = ".\Reports",
    [string]$CompanyName = "Sua Empresa - Managed Services",
    [string]$LogoUrl = "",
    [double]$ComplianceTarget = 99.0,
    [int]$SlaDays = 30,
    [ValidateSet('pt-BR','en-US')]
    [string]$DefaultLanguage = 'pt-BR'
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# MAPA DE BUILD -> VERSAO AMIGAVEL DO WINDOWS
# Ajuste/inclua novos builds conforme a Microsoft libera novas versoes.
# (best effort - baseado em builds publicos conhecidos ate o momento)
# ============================================================================
$WindowsBuildMap = @{
    '19044' = 'Windows 10 21H2'
    '19045' = 'Windows 10 22H2'
    '22000' = 'Windows 11 21H2'
    '22621' = 'Windows 11 22H2'
    '22631' = 'Windows 11 23H2'
    '26100' = 'Windows 11 24H2'
    '26200' = 'Windows 11 25H2'
}

function Get-FriendlyWindowsVersion {
    param([string]$Caption, [string]$Build)
    if ($Build -and $WindowsBuildMap.ContainsKey($Build)) {
        return $WindowsBuildMap[$Build]
    }
    if ($Caption) { return "$Caption (build $Build)" }
    return "Desconhecido (build $Build)"
}

# ============================================================================
# CONEXAO SQL (System.Data.SqlClient - nao depende do modulo SqlServer)
# O usuario/service account precisa ter permissao de leitura no banco do site
# (grupo "smsschm_users" / role de leitura do SQL Reporting geralmente serve).
# ============================================================================
function Invoke-CmSqlQuery {
    param(
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Params = @{},
        [Parameter(Mandatory)][string]$SqlServer,
        [Parameter(Mandatory)][string]$Database
    )
    $connString = "Server=$SqlServer;Database=$Database;Integrated Security=True;TrustServerCertificate=True;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 120
        foreach ($k in $Params.Keys) { [void]$cmd.Parameters.AddWithValue("@$k", $Params[$k]) }
        $reader = $cmd.ExecuteReader()
        $table = New-Object System.Data.DataTable
        $table.Load($reader)
        return $table
    }
    finally {
        $conn.Close()
    }
}

# ============================================================================
# COLETA DE DADOS - MODO LIVE
# ============================================================================
function Get-LiveReportData {
    param(
        [Parameter(Mandatory)][string]$DeploymentID,
        [Parameter(Mandatory)][string]$CollectionID,
        [Parameter(Mandatory)][string]$SqlServer,
        [Parameter(Mandatory)][string]$Database,
        [scriptblock]$StatusCallback = { param($msg) Write-Host $msg }
    )

    & $StatusCallback "Consultando metadados do deployment $DeploymentID ..."

    # --- Metadados do deployment (assignment) ---------------------------------
    # NOTA: dependendo da versao/build do SCCM, o nome da view pode ser
    # v_CIAssignment ou vSMS_CIAssignment. Rode antes:
    #   SELECT TOP 1 * FROM v_CIAssignment WHERE AssignmentID = 'SEU_ID'
    # para confirmar antes de rodar em producao.
    $deploySql = @"
SELECT TOP 1
    ca.AssignmentID,
    ca.AssignmentName,
    ca.CollectionID,
    ca.EnforcementDeadline,
    ca.StartTime,
    col.Name AS CollectionName
FROM v_CIAssignment ca
INNER JOIN v_Collection col ON col.CollectionID = ca.CollectionID
WHERE ca.AssignmentID = @DeploymentID
"@
    $deployInfo = Invoke-CmSqlQuery -Query $deploySql -Params @{ DeploymentID = $DeploymentID } -SqlServer $SqlServer -Database $Database
    if ($deployInfo.Rows.Count -eq 0) {
        throw "Deployment '$DeploymentID' nao encontrado. Verifique o AssignmentID."
    }
    $deploy = $deployInfo.Rows[0]

    # --- CIs (updates) que fazem parte deste deployment -------------------
    $ciSql = "SELECT CI_ID FROM v_CIAssignmentToCI WHERE AssignmentID = @DeploymentID"
    $ciRows = Invoke-CmSqlQuery -Query $ciSql -Params @{ DeploymentID = $DeploymentID } -SqlServer $SqlServer -Database $Database
    $ciIds = @($ciRows | ForEach-Object { $_.CI_ID })
    if ($ciIds.Count -eq 0) {
        throw "Nenhum update associado a este deployment foi encontrado."
    }
    $ciIdList = ($ciIds -join ',')

    & $StatusCallback "Consultando membros da collection $CollectionID ..."

    # --- Maquinas membros da collection + inventario basico ----------------
    $sysSql = @"
SELECT
    sys.ResourceID,
    sys.Name0                 AS Hostname,
    sys.AD_Site_Name0         AS ADSite,
    sys.Client_Site_Code      AS ClientSite,
    sys.User_Name0            AS LastLogonUser,
    os.Caption0                AS OSCaption,
    os.Version0                 AS OSVersion,
    os.BuildNumber0             AS OSBuild,
    os.LastBootUpTime0          AS LastBoot
FROM v_FullCollectionMembership fcm
INNER JOIN v_R_System sys ON sys.ResourceID = fcm.ResourceID
LEFT JOIN v_GS_OPERATING_SYSTEM os ON os.ResourceID = sys.ResourceID
WHERE fcm.CollectionID = @CollectionID
"@
    $systems = Invoke-CmSqlQuery -Query $sysSql -Params @{ CollectionID = $CollectionID } -SqlServer $SqlServer -Database $Database

    # --- IPs ------------------------------------------------------------------
    $ipSql = @"
SELECT ip.ResourceID, ip.IP_Addresses0
FROM v_RA_System_IPAddresses ip
WHERE ip.ResourceID IN (SELECT ResourceID FROM v_FullCollectionMembership WHERE CollectionID = @CollectionID)
"@
    $ipRows = Invoke-CmSqlQuery -Query $ipSql -Params @{ CollectionID = $CollectionID } -SqlServer $SqlServer -Database $Database
    $ipByResource = @{}
    foreach ($r in $ipRows) {
        $ip = $r.IP_Addresses0
        if ($ip -and $ip -notmatch '^169\.254' -and $ip -notmatch ':') {
            if (-not $ipByResource.ContainsKey($r.ResourceID)) { $ipByResource[$r.ResourceID] = $ip }
        }
    }

    # --- UPN (User Principal Name) via v_R_User --------------------------------
    # Requer AD User Discovery habilitado e coletando o atributo UserPrincipalName.
    $userSql = "SELECT User_Name0, User_Principal_Name0 FROM v_R_User"
    $userRows = Invoke-CmSqlQuery -Query $userSql -SqlServer $SqlServer -Database $Database
    $upnByUser = @{}
    foreach ($u in $userRows) {
        if ($u.User_Name0 -and -not $upnByUser.ContainsKey($u.User_Name0)) {
            $upnByUser[$u.User_Name0] = $u.User_Principal_Name0
        }
    }

    & $StatusCallback "Consultando status de compliance dos updates ..."

    # --- Status de compliance por maquina/update -------------------------------
    # Status: 0=Unknown, 1=NotRequired, 2=NotPresent (nao instalado/erro), 3=Present (instalado)
    # ATENCAO: o TopicType usado no join com v_StateNames para decodificar o
    # "estado de enforcement" (ex.: "Pending Restart") varia por versao do SCCM.
    # Rode antes: SELECT DISTINCT TopicType FROM v_StateNames  e confirme qual
    # TopicType corresponde a "Software Updates Enforcement State" no seu ambiente
    # (normalmente esta na faixa 400-501). Ajuste o valor abaixo se necessario.
    $enforcementTopicType = 402

    $complianceSql = @"
SELECT
    ucs.ResourceID,
    ucs.CI_ID,
    ucs.Status,
    ucs.LastEnforcementMessageID,
    ucs.LastErrorCode,
    sn.StateName AS EnforcementStateName
FROM v_UpdateComplianceStatus ucs
LEFT JOIN v_StateNames sn
    ON sn.TopicType = $enforcementTopicType AND sn.StateID = ucs.LastEnforcementMessageID
WHERE ucs.CI_ID IN ($ciIdList)
  AND ucs.ResourceID IN (SELECT ResourceID FROM v_FullCollectionMembership WHERE CollectionID = @CollectionID)
"@
    $complianceRows = Invoke-CmSqlQuery -Query $complianceSql -Params @{ CollectionID = $CollectionID } -SqlServer $SqlServer -Database $Database

    $complianceByResource = @{}
    foreach ($c in $complianceRows) {
        if (-not $complianceByResource.ContainsKey($c.ResourceID)) { $complianceByResource[$c.ResourceID] = @() }
        $complianceByResource[$c.ResourceID] += $c
    }

    & $StatusCallback "Processando dados por host ..."

    # --- Monta o resultado final por host --------------------------------------
    $GeneratedAt = Get-Date
    $hosts = foreach ($sys in $systems) {
        $rid = $sys.ResourceID
        $rows = $complianceByResource[$rid]

        $status = 'Unknown'
        $errorText = ''
        $pendingReboot = $false

        if ($rows -and $rows.Count -gt 0) {
            $hasError   = $rows | Where-Object { $_.Status -eq 2 }
            $allPresent = ($rows | Where-Object { $_.Status -ne 3 }).Count -eq 0

            if ($hasError) {
                $status = 'Error'
                $errCodes = $hasError | ForEach-Object {
                    if ($_.LastErrorCode -and $_.LastErrorCode -ne 0) {
                        "0x{0:X8}" -f $_.LastErrorCode
                    }
                } | Where-Object { $_ } | Select-Object -Unique
                $errorText = if ($errCodes) { $errCodes -join ', ' } else { 'Falha na instalacao (sem codigo de erro reportado)' }
            }
            elseif ($allPresent) {
                $status = 'Success'
            }

            $pendingReboot = [bool]($rows | Where-Object { $_.EnforcementStateName -match 'Restart|Reboot' })
        }

        $ip = $ipByResource[$rid]
        $upn = if ($sys.LastLogonUser -and $upnByUser.ContainsKey($sys.LastLogonUser)) { $upnByUser[$sys.LastLogonUser] } else { $sys.LastLogonUser }

        $uptimeDays = $null
        if ($sys.LastBoot) {
            $uptimeDays = [math]::Round((New-TimeSpan -Start $sys.LastBoot -End $GeneratedAt).TotalDays, 1)
        }

        [PSCustomObject]@{
            Hostname       = $sys.Hostname
            OSVersion      = Get-FriendlyWindowsVersion -Caption $sys.OSCaption -Build $sys.OSBuild
            UPN            = if ($upn) { $upn } else { 'N/A' }
            IP             = if ($ip) { $ip } else { 'N/A' }
            Site           = if ($sys.ADSite) { $sys.ADSite } else { $sys.ClientSite }
            Status         = $status
            ErrorDetail    = $errorText
            PendingReboot  = $pendingReboot
            UptimeDays     = $uptimeDays
        }
    }

    return [PSCustomObject]@{
        DeploymentName = $deploy.AssignmentName
        CollectionName = $deploy.CollectionName
        Deadline       = $deploy.EnforcementDeadline
        StartTime      = $deploy.StartTime
        Hosts          = $hosts
    }
}

# ============================================================================
# DADOS DE DEMONSTRACAO (para validar o layout sem depender do SQL)
# ============================================================================
function Get-DemoReportData {
    $sites = 'Sao Paulo - HQ', 'Rio de Janeiro', 'Belo Horizonte', 'Remote/VPN', 'Curitiba'
    $osList = 'Windows 11 24H2', 'Windows 11 23H2', 'Windows 10 22H2', 'Windows 11 25H2'
    $rnd = New-Object System.Random(42)
    $hosts = for ($i = 1; $i -le 187; $i++) {
        $roll = $rnd.Next(1, 101)
        if ($roll -le 91) { $status = 'Success' }
        elseif ($roll -le 97) { $status = 'Error' }
        else { $status = 'Unknown' }

        $errText = ''
        if ($status -eq 'Error') {
            $errText = @('0x80070643 - Falha generica de instalacao', '0x80240034 - Download interrompido',
                         '0x8024200D - Falha ao aplicar o pacote', '0x80070005 - Acesso negado') | Get-Random
        }

        [PSCustomObject]@{
            Hostname      = "WKS-{0:D4}" -f $i
            OSVersion     = $osList | Get-Random
            UPN           = "usuario.$i@clienteXcorp.com"
            IP            = "10.$($rnd.Next(1,20)).$($rnd.Next(1,255)).$($rnd.Next(2,254))"
            Site          = $sites | Get-Random
            Status        = $status
            ErrorDetail   = $errText
            PendingReboot = ($status -eq 'Success' -and $rnd.Next(1,100) -le 8)
            UptimeDays    = [math]::Round($rnd.NextDouble() * 25, 1)
        }
    }
    return [PSCustomObject]@{
        DeploymentName = 'Patch Tuesday - Julho 2026 (Cumulative Update)'
        CollectionName = 'ALL - Workstations Producao'
        Deadline       = (Get-Date).AddDays(2)
        StartTime      = (Get-Date).AddDays(-5)
        Hosts          = $hosts
    }
}

# ============================================================================
# GERACAO DO RELATORIO (usada tanto pela GUI quanto pela linha de comando)
# ============================================================================
function New-PatchReport {
    param(
        [string]$DeploymentID,
        [string]$CollectionID,
        [string]$SqlServer,
        [string]$Database,
        [switch]$DemoMode,
        [string]$OutputPath = ".\Reports",
        [string]$CompanyName = "Sua Empresa - Managed Services",
        [string]$LogoUrl = "",
        [double]$ComplianceTarget = 99.0,
        [int]$SlaDays = 30,
        [string]$DefaultLanguage = 'pt-BR',
        [scriptblock]$StatusCallback = { param($msg) Write-Host $msg }
    )

    $GeneratedAt = Get-Date

    if ($DemoMode) {
        & $StatusCallback "Modo DEMO ativo - gerando dados ficticios..."
        $data = Get-DemoReportData
    }
    else {
        if (-not $DeploymentID -or -not $CollectionID -or -not $SqlServer -or -not $Database) {
            throw "DeploymentID, CollectionID, SQL Server e Database sao obrigatorios (ou ative o Modo Demonstracao)."
        }
        $data = Get-LiveReportData -DeploymentID $DeploymentID -CollectionID $CollectionID `
                    -SqlServer $SqlServer -Database $Database -StatusCallback $StatusCallback
    }

    & $StatusCallback "Calculando metricas e agregacoes..."

    $allHosts = $data.Hosts
    $total = $allHosts.Count
    $success = @($allHosts | Where-Object Status -eq 'Success').Count
    $errorCount = @($allHosts | Where-Object Status -eq 'Error').Count
    $unknown = @($allHosts | Where-Object Status -eq 'Unknown').Count
    $pendingReboot = @($allHosts | Where-Object PendingReboot -eq $true).Count
    $compliancePct = if ($total -gt 0) { [math]::Round(($success / $total) * 100, 1) } else { 0 }
    $gapToTarget = [math]::Round($ComplianceTarget - $compliancePct, 1)

    # Agregacoes por Site
    $bySite = $allHosts | Group-Object Site | ForEach-Object {
        $t = $_.Count
        $s = @($_.Group | Where-Object Status -eq 'Success').Count
        [PSCustomObject]@{ Name = $_.Name; Total = $t; Success = $s; Pct = if ($t -gt 0) { [math]::Round(($s/$t)*100,1) } else { 0 } }
    } | Sort-Object Total -Descending

    # Agregacoes por versao do Windows
    $byOS = $allHosts | Group-Object OSVersion | ForEach-Object {
        $t = $_.Count
        $s = @($_.Group | Where-Object Status -eq 'Success').Count
        [PSCustomObject]@{ Name = $_.Name; Total = $t; Success = $s; Pct = if ($t -gt 0) { [math]::Round(($s/$t)*100,1) } else { 0 } }
    } | Sort-Object Total -Descending

    # Top erros
    $topErrors = $allHosts | Where-Object { $_.Status -eq 'Error' -and $_.ErrorDetail } |
        Group-Object ErrorDetail | Sort-Object Count -Descending | Select-Object -First 5 |
        ForEach-Object { [PSCustomObject]@{ Error = $_.Name; Count = $_.Count } }

    # SLA de negocio: N dias corridos a partir do INICIO do deployment (StartTime),
    # independente do "EnforcementDeadline" configurado no SCCM (que pode ser diferente
    # da politica de SLA acordada com o cliente).
    $slaDeadline = if ($data.StartTime) { $data.StartTime.AddDays($SlaDays) } elseif ($data.Deadline) { $data.Deadline } else { $null }
    $daysElapsed = if ($data.StartTime) { [math]::Round((New-TimeSpan -Start $data.StartTime -End $GeneratedAt).TotalDays, 1) } else { $null }
    $daysToDeadline = if ($slaDeadline) { [math]::Round((New-TimeSpan -Start $GeneratedAt -End $slaDeadline).TotalDays, 1) } else { $null }
    $slaState = if ($null -eq $daysToDeadline) { 'none' } elseif ($daysToDeadline -lt 0) { 'overdue' } elseif ($daysToDeadline -le 5) { 'warning' } else { 'ok' }

    & $StatusCallback "Montando o HTML do relatorio..."

    $hostsJson     = $allHosts | ConvertTo-Json -Depth 5 -Compress
    $bySiteJson    = $bySite   | ConvertTo-Json -Depth 5 -Compress
    $byOSJson      = $byOS     | ConvertTo-Json -Depth 5 -Compress
    $topErrorsJson = $topErrors| ConvertTo-Json -Depth 5 -Compress
    if ($errorCount -eq 0) { $topErrorsJson = '[]' }

    # ========================================================================
    # TEMPLATE HTML
    # ========================================================================
$template = @'
<!DOCTYPE html>
<html lang="pt-BR" data-lang="__DEFAULT_LANG__">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Relatório de Patch - __DEPLOYMENT_NAME__</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.4/chart.umd.min.js"></script>
<style>
  :root{
    --navy:#0b1f3a; --navy2:#12294d; --accent:#2f6fed;
    --green:#1fa15c; --green-bg:#e7f7ee;
    --red:#d93025; --red-bg:#fdecea;
    --gray:#6b7280; --gray-bg:#f1f2f4;
    --amber:#e0952c; --amber-bg:#fdf3e2;
    --bg:#f4f6fb; --card:#ffffff; --border:#e6e9f0; --text:#1a2233; --muted:#6b7280;
    --radius:14px; --shadow:0 2px 10px rgba(16,24,55,.06), 0 1px 2px rgba(16,24,55,.04);
  }
  *{box-sizing:border-box;}
  body{margin:0;font-family:'Segoe UI',Inter,system-ui,-apple-system,Arial,sans-serif;background:var(--bg);color:var(--text);}
  .wrap{max-width:1280px;margin:0 auto;padding:28px 24px 60px;}

  header.top{background:linear-gradient(135deg,var(--navy),var(--navy2));color:#fff;border-radius:var(--radius);padding:28px 32px;box-shadow:var(--shadow);display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:16px;}
  header.top .brand{display:flex;align-items:center;gap:14px;}
  header.top .brand img{height:38px;}
  header.top .brand .company{font-size:13px;opacity:.75;letter-spacing:.03em;text-transform:uppercase;}
  header.top h1{margin:2px 0 0;font-size:22px;font-weight:600;}
  header.top .meta{text-align:right;font-size:13px;opacity:.85;line-height:1.6;}
  header.top .lang-toggle{background:rgba(255,255,255,.12);border:1px solid rgba(255,255,255,.25);color:#fff;border-radius:20px;padding:6px 14px;font-size:12px;cursor:pointer;}
  header.top .lang-toggle:hover{background:rgba(255,255,255,.22);}

  .subbar{display:flex;justify-content:space-between;align-items:center;margin-top:14px;padding:14px 20px;background:var(--card);border-radius:var(--radius);box-shadow:var(--shadow);flex-wrap:wrap;gap:10px;}
  .subbar .item{font-size:13px;color:var(--muted);}
  .subbar .item b{color:var(--text);}

  .sla-banner{margin-top:14px;border-radius:var(--radius);padding:14px 20px;font-size:14px;font-weight:500;display:flex;align-items:center;gap:10px;}
  .sla-ok{background:var(--green-bg);color:var(--green);}
  .sla-warning{background:var(--amber-bg);color:var(--amber);}
  .sla-overdue{background:var(--red-bg);color:var(--red);}

  .kpis{display:grid;grid-template-columns:repeat(5,1fr);gap:16px;margin-top:22px;}
  @media(max-width:1000px){.kpis{grid-template-columns:repeat(2,1fr);}}
  .kpi{background:var(--card);border-radius:var(--radius);padding:18px 20px;box-shadow:var(--shadow);border-left:4px solid var(--border);}
  .kpi .label{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em;}
  .kpi .value{font-size:30px;font-weight:700;margin-top:6px;}
  .kpi .sub{font-size:12px;color:var(--muted);margin-top:4px;}
  .kpi.total{border-left-color:var(--accent);}
  .kpi.success{border-left-color:var(--green);}
  .kpi.success .value{color:var(--green);}
  .kpi.error{border-left-color:var(--red);}
  .kpi.error .value{color:var(--red);}
  .kpi.unknown{border-left-color:var(--gray);}
  .kpi.reboot{border-left-color:var(--amber);}
  .kpi.reboot .value{color:var(--amber);}

  .grid2{display:grid;grid-template-columns:1fr 1.4fr;gap:16px;margin-top:16px;}
  @media(max-width:900px){.grid2{grid-template-columns:1fr;}}
  .card{background:var(--card);border-radius:var(--radius);padding:20px;box-shadow:var(--shadow);}
  .card h3{margin:0 0 14px;font-size:14px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);}
  .chart-box{position:relative;height:260px;}

  .exec-summary{margin-top:16px;background:var(--card);border-radius:var(--radius);padding:20px 24px;box-shadow:var(--shadow);border-left:4px solid var(--accent);}
  .exec-summary h3{margin:0 0 8px;font-size:14px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);}
  .exec-summary p{margin:0;line-height:1.65;font-size:14.5px;}

  .table-card{margin-top:16px;background:var(--card);border-radius:var(--radius);padding:20px;box-shadow:var(--shadow);}
  .table-controls{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:14px;align-items:center;}
  .table-controls input, .table-controls select{padding:9px 12px;border:1px solid var(--border);border-radius:8px;font-size:13px;background:#fff;}
  .table-controls input{flex:1;min-width:200px;}
  .btn{padding:9px 16px;border-radius:8px;border:1px solid var(--border);background:#fff;font-size:13px;cursor:pointer;font-weight:500;}
  .btn:hover{background:var(--gray-bg);}
  .btn.primary{background:var(--accent);color:#fff;border-color:var(--accent);}
  .btn.primary:hover{opacity:.9;}

  table{width:100%;border-collapse:collapse;font-size:13px;}
  thead th{position:sticky;top:0;background:#fafbfd;text-align:left;padding:10px 12px;border-bottom:2px solid var(--border);cursor:pointer;user-select:none;color:var(--muted);font-weight:600;white-space:nowrap;}
  thead th:hover{color:var(--text);}
  tbody td{padding:10px 12px;border-bottom:1px solid var(--border);white-space:nowrap;}
  tbody tr:hover{background:#f7f9fc;}
  .table-scroll{max-height:560px;overflow:auto;border:1px solid var(--border);border-radius:10px;}

  .badge{display:inline-flex;align-items:center;gap:5px;padding:3px 10px;border-radius:20px;font-size:12px;font-weight:600;}
  .badge.Success{background:var(--green-bg);color:var(--green);}
  .badge.Error{background:var(--red-bg);color:var(--red);}
  .badge.Unknown{background:var(--gray-bg);color:var(--gray);}
  .badge.dot{width:7px;height:7px;border-radius:50%;background:currentColor;}
  .reboot-yes{color:var(--amber);font-weight:600;}
  .reboot-no{color:var(--muted);}
  .err-detail{color:var(--red);font-size:12px;max-width:260px;overflow:hidden;text-overflow:ellipsis;}

  footer{text-align:center;color:var(--muted);font-size:12px;margin-top:30px;line-height:1.6;}

  @media print{
    body{background:#fff;}
    .table-controls, .lang-toggle, .btn{display:none !important;}
    .table-scroll{max-height:none;overflow:visible;}
  }
</style>
</head>
<body>
<div class="wrap">

  <header class="top">
    <div class="brand">
      __LOGO_IMG__
      <div>
        <div class="company">__COMPANY_NAME__</div>
        <h1 data-i18n="title">Relatório de Compliance de Patch Management</h1>
      </div>
    </div>
    <div style="display:flex;align-items:center;gap:14px;">
      <div class="meta">
        <div><span data-i18n="generated">Gerado em</span>: __GENERATED_AT__</div>
        <div><span data-i18n="confidential">Confidencial - uso interno</span></div>
      </div>
      <button class="lang-toggle" id="langToggle">EN / PT</button>
    </div>
  </header>

  <div class="subbar">
    <div class="item"><span data-i18n="deployment">Deployment</span>: <b>__DEPLOYMENT_NAME__</b></div>
    <div class="item"><span data-i18n="collection">Collection</span>: <b>__COLLECTION_NAME__</b></div>
    <div class="item"><span data-i18n="target">Meta de Compliance</span>: <b>__TARGET_PCT__%</b></div>
    <div class="item"><span data-i18n="sla_label">SLA</span>: <b>__SLA_DAYS__ <span data-i18n="days">dias</span> (__SLA_DEADLINE__)</b></div>
  </div>

  __SLA_BANNER__

  <div class="kpis">
    <div class="kpi total">
      <div class="label" data-i18n="k_total">Total de Dispositivos</div>
      <div class="value">__TOTAL__</div>
      <div class="sub" data-i18n="k_total_sub">na collection alvo</div>
    </div>
    <div class="kpi success">
      <div class="label" data-i18n="k_success">Patch Instalado</div>
      <div class="value">__SUCCESS__</div>
      <div class="sub">__COMPLIANCE_PCT__% <span data-i18n="k_success_sub">de compliance</span></div>
    </div>
    <div class="kpi error">
      <div class="label" data-i18n="k_error">Com Erro</div>
      <div class="value">__ERROR__</div>
      <div class="sub" data-i18n="k_error_sub">requer ação da equipe</div>
    </div>
    <div class="kpi unknown">
      <div class="label" data-i18n="k_unknown">Desconhecido</div>
      <div class="value">__UNKNOWN__</div>
      <div class="sub" data-i18n="k_unknown_sub">sem retorno do cliente</div>
    </div>
    <div class="kpi reboot">
      <div class="label" data-i18n="k_reboot">Pendente de Reboot</div>
      <div class="value">__PENDING_REBOOT__</div>
      <div class="sub" data-i18n="k_reboot_sub">compliance real em risco</div>
    </div>
  </div>

  <div class="grid2">
    <div class="card">
      <h3 data-i18n="chart_status">Status Geral do Patch</h3>
      <div class="chart-box"><canvas id="pieChart"></canvas></div>
    </div>
    <div class="card">
      <h3 data-i18n="chart_site">Compliance por Site</h3>
      <div class="chart-box"><canvas id="siteChart"></canvas></div>
    </div>
  </div>

  <div class="exec-summary">
    <h3 data-i18n="exec_title">Resumo Executivo</h3>
    <p id="execSummaryText"></p>
  </div>

  <div class="table-card">
    <div class="table-controls">
      <input type="text" id="searchInput" data-i18n-placeholder="search" placeholder="Buscar por hostname, usuário, IP...">
      <select id="statusFilter">
        <option value="" data-i18n="filter_all">Todos os status</option>
        <option value="Success" data-i18n="filter_success">Sucesso</option>
        <option value="Error" data-i18n="filter_error">Erro</option>
        <option value="Unknown" data-i18n="filter_unknown">Desconhecido</option>
      </select>
      <select id="rebootFilter">
        <option value="" data-i18n="filter_reboot_all">Reboot: todos</option>
        <option value="yes" data-i18n="filter_reboot_yes">Reboot pendente</option>
        <option value="no" data-i18n="filter_reboot_no">Sem pendência</option>
      </select>
      <button class="btn primary" id="exportCsv" data-i18n="export_csv">Exportar CSV</button>
      <button class="btn" id="printBtn" data-i18n="print">Imprimir / PDF</button>
    </div>
    <div class="table-scroll">
      <table id="hostTable">
        <thead>
          <tr>
            <th data-key="Hostname" data-i18n="col_host">Hostname</th>
            <th data-key="OSVersion" data-i18n="col_os">Versão do Windows</th>
            <th data-key="UPN" data-i18n="col_upn">UPN do Usuário</th>
            <th data-key="IP" data-i18n="col_ip">IP</th>
            <th data-key="Site" data-i18n="col_site">Site</th>
            <th data-key="Status" data-i18n="col_status">Patch Instalado</th>
            <th data-key="ErrorDetail" data-i18n="col_error">Detalhe do Erro</th>
            <th data-key="PendingReboot" data-i18n="col_reboot">Pending Reboot</th>
            <th data-key="UptimeDays" data-i18n="col_uptime">Uptime (dias)</th>
          </tr>
        </thead>
        <tbody id="hostTableBody"></tbody>
      </table>
    </div>
  </div>

  <footer>
    <div data-i18n="footer1">Este relatório foi gerado automaticamente a partir de dados do SCCM/MECM.</div>
    <div data-i18n="footer2">Documento confidencial - distribuição restrita à equipe de gestão do cliente.</div>
  </footer>
</div>

<script>
const HOSTS = __HOSTS_JSON__;
const BY_SITE = __BY_SITE_JSON__;
const BY_OS = __BY_OS_JSON__;
const TOP_ERRORS = __TOP_ERRORS_JSON__;
const TOTAL = __TOTAL__, SUCCESS = __SUCCESS__, ERRORC = __ERROR__, UNKNOWN = __UNKNOWN__, PENDING_REBOOT = __PENDING_REBOOT__;
const COMPLIANCE_PCT = __COMPLIANCE_PCT__, TARGET_PCT = __TARGET_PCT__, GAP = __GAP__;

const COLORS = { green:'#1fa15c', red:'#d93025', gray:'#8b93a3' };

// ---- Pie chart (status) ----
new Chart(document.getElementById('pieChart'), {
  type: 'pie',
  data: {
    labels: ['Sucesso', 'Erro', 'Desconhecido'],
    datasets: [{
      data: [SUCCESS, ERRORC, UNKNOWN],
      backgroundColor: [COLORS.green, COLORS.red, COLORS.gray],
      borderWidth: 2,
      borderColor: '#fff'
    }]
  },
  options: {
    plugins: {
      legend: { position: 'bottom', labels: { usePointStyle: true, padding: 16, font: { size: 12 } } },
      tooltip: {
        callbacks: {
          label: (ctx) => `${ctx.label}: ${ctx.raw} (${(ctx.raw/TOTAL*100).toFixed(1)}%)`
        }
      }
    },
    maintainAspectRatio: false
  }
});

// ---- Bar chart (compliance por site) ----
new Chart(document.getElementById('siteChart'), {
  type: 'bar',
  data: {
    labels: BY_SITE.map(s => s.Name),
    datasets: [{
      label: '% Compliance',
      data: BY_SITE.map(s => s.Pct),
      backgroundColor: BY_SITE.map(s => s.Pct >= TARGET_PCT ? COLORS.green : (s.Pct >= TARGET_PCT - 10 ? '#e0952c' : COLORS.red)),
      borderRadius: 6
    }]
  },
  options: {
    indexAxis: 'y',
    scales: { x: { min: 0, max: 100, ticks: { callback: v => v + '%' } } },
    plugins: { legend: { display: false }, tooltip: { callbacks: { label: (ctx) => `${ctx.raw}% (${BY_SITE[ctx.dataIndex].Success}/${BY_SITE[ctx.dataIndex].Total})` } } },
    maintainAspectRatio: false
  }
});

// ---- Resumo executivo ----
function buildExecSummary(lang) {
  const worstSite = [...BY_SITE].sort((a,b)=>a.Pct-b.Pct)[0];
  const worstOS = [...BY_OS].sort((a,b)=>a.Pct-b.Pct)[0];
  const gapTxt = GAP > 0
    ? (lang === 'pt-BR' ? `${GAP}% abaixo da meta` : `${GAP}% below target`)
    : (lang === 'pt-BR' ? `dentro da meta estabelecida` : `within the established target`);

  if (lang === 'pt-BR') {
    return `Do total de <b>${TOTAL}</b> dispositivos na collection, <b>${SUCCESS}</b> (${COMPLIANCE_PCT}%) `
      + `tiveram o patch instalado com sucesso, ficando <b>${gapTxt}</b> (meta: ${TARGET_PCT}%). `
      + `<b>${ERRORC}</b> dispositivo(s) apresentaram erro na instalação e requerem ação da equipe, `
      + `e <b>${UNKNOWN}</b> ainda não reportaram status. `
      + (PENDING_REBOOT > 0 ? `Além disso, <b>${PENDING_REBOOT}</b> máquina(s) já receberam o patch mas aguardam reinicialização para aplicar a correção por completo. ` : '')
      + (worstSite ? `O site com menor compliance é <b>${worstSite.Name}</b> (${worstSite.Pct}%)` : '')
      + (worstOS ? `, concentrado principalmente em <b>${worstOS.Name}</b> (${worstOS.Pct}% de compliance). ` : '. ')
      + `Recomenda-se priorizar o acompanhamento dos dispositivos com erro e reforçar a comunicação para reinicialização das máquinas pendentes.`;
  }
  return `Out of <b>${TOTAL}</b> devices in the target collection, <b>${SUCCESS}</b> (${COMPLIANCE_PCT}%) `
    + `successfully installed the patch, currently <b>${gapTxt}</b> (target: ${TARGET_PCT}%). `
    + `<b>${ERRORC}</b> device(s) failed installation and require follow-up, `
    + `and <b>${UNKNOWN}</b> have not yet reported status. `
    + (PENDING_REBOOT > 0 ? `Additionally, <b>${PENDING_REBOOT}</b> device(s) have the patch installed but are pending a reboot to fully apply it. ` : '')
    + (worstSite ? `The lowest-compliance site is <b>${worstSite.Name}</b> (${worstSite.Pct}%)` : '')
    + (worstOS ? `, concentrated mostly on <b>${worstOS.Name}</b> (${worstOS.Pct}% compliance). ` : '. ')
    + `We recommend prioritizing follow-up on failed devices and reinforcing communication to reboot pending machines.`;
}

// ---- Tabela ----
const tbody = document.getElementById('hostTableBody');
const statusLabel = { Success: { pt:'Sim', en:'Yes' }, Error: { pt:'Erro', en:'Error' }, Unknown: { pt:'Desconhecido', en:'Unknown' } };

function renderTable(rows) {
  tbody.innerHTML = rows.map(h => `
    <tr>
      <td>${h.Hostname}</td>
      <td>${h.OSVersion}</td>
      <td>${h.UPN}</td>
      <td>${h.IP}</td>
      <td>${h.Site}</td>
      <td><span class="badge ${h.Status}"><span class="badge dot"></span>${statusLabel[h.Status][currentLang==='pt-BR'?'pt':'en']}</span></td>
      <td class="err-detail" title="${h.ErrorDetail||''}">${h.ErrorDetail||'-'}</td>
      <td class="${h.PendingReboot?'reboot-yes':'reboot-no'}">${h.PendingReboot ? (currentLang==='pt-BR'?'Sim':'Yes') : (currentLang==='pt-BR'?'Não':'No')}</td>
      <td>${h.UptimeDays ?? '-'}</td>
    </tr>`).join('');
}

let currentRows = [...HOSTS];
renderTable(currentRows);

function applyFilters() {
  const q = document.getElementById('searchInput').value.toLowerCase();
  const st = document.getElementById('statusFilter').value;
  const rb = document.getElementById('rebootFilter').value;
  currentRows = HOSTS.filter(h => {
    const matchQ = !q || [h.Hostname, h.UPN, h.IP, h.Site].some(v => (v||'').toLowerCase().includes(q));
    const matchSt = !st || h.Status === st;
    const matchRb = !rb || (rb === 'yes' ? h.PendingReboot : !h.PendingReboot);
    return matchQ && matchSt && matchRb;
  });
  renderTable(currentRows);
}
document.getElementById('searchInput').addEventListener('input', applyFilters);
document.getElementById('statusFilter').addEventListener('change', applyFilters);
document.getElementById('rebootFilter').addEventListener('change', applyFilters);

// ---- Ordenacao ----
let sortDir = {};
document.querySelectorAll('#hostTable thead th').forEach(th => {
  th.addEventListener('click', () => {
    const key = th.dataset.key;
    sortDir[key] = !sortDir[key];
    currentRows.sort((a,b) => {
      let va = a[key], vb = b[key];
      if (typeof va === 'string') { va = va.toLowerCase(); vb = (vb||'').toLowerCase(); }
      if (va < vb) return sortDir[key] ? -1 : 1;
      if (va > vb) return sortDir[key] ? 1 : -1;
      return 0;
    });
    renderTable(currentRows);
  });
});

// ---- Export CSV ----
document.getElementById('exportCsv').addEventListener('click', () => {
  const headers = ['Hostname','OSVersion','UPN','IP','Site','Status','ErrorDetail','PendingReboot','UptimeDays'];
  const csv = [headers.join(',')].concat(currentRows.map(h =>
    headers.map(k => `"${String(h[k] ?? '').replace(/"/g,'""')}"`).join(','))).join('\n');
  const blob = new Blob(['\ufeff' + csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = 'patch_report_hosts.csv'; a.click();
  URL.revokeObjectURL(url);
});
document.getElementById('printBtn').addEventListener('click', () => window.print());

// ---- Traducao PT/EN ----
const I18N = {
  'pt-BR': {
    title:'Relatório de Compliance de Patch Management', generated:'Gerado em', confidential:'Confidencial - uso interno',
    deployment:'Deployment', collection:'Collection', target:'Meta de Compliance', sla_label:'SLA', days:'dias',
    k_total:'Total de Dispositivos', k_total_sub:'na collection alvo',
    k_success:'Patch Instalado', k_success_sub:'de compliance',
    k_error:'Com Erro', k_error_sub:'requer ação da equipe',
    k_unknown:'Desconhecido', k_unknown_sub:'sem retorno do cliente',
    k_reboot:'Pendente de Reboot', k_reboot_sub:'compliance real em risco',
    chart_status:'Status Geral do Patch', chart_site:'Compliance por Site',
    exec_title:'Resumo Executivo',
    search:'Buscar por hostname, usuário, IP...',
    filter_all:'Todos os status', filter_success:'Sucesso', filter_error:'Erro', filter_unknown:'Desconhecido',
    filter_reboot_all:'Reboot: todos', filter_reboot_yes:'Reboot pendente', filter_reboot_no:'Sem pendência',
    export_csv:'Exportar CSV', print:'Imprimir / PDF',
    col_host:'Hostname', col_os:'Versão do Windows', col_upn:'UPN do Usuário', col_ip:'IP', col_site:'Site',
    col_status:'Patch Instalado', col_error:'Detalhe do Erro', col_reboot:'Pending Reboot', col_uptime:'Uptime (dias)',
    footer1:'Este relatório foi gerado automaticamente a partir de dados do SCCM/MECM.',
    footer2:'Documento confidencial - distribuição restrita à equipe de gestão do cliente.'
  },
  'en-US': {
    title:'Patch Management Compliance Report', generated:'Generated on', confidential:'Confidential - internal use',
    deployment:'Deployment', collection:'Collection', target:'Compliance Target', sla_label:'SLA', days:'days',
    k_total:'Total Devices', k_total_sub:'in target collection',
    k_success:'Patch Installed', k_success_sub:'compliance',
    k_error:'With Error', k_error_sub:'requires follow-up',
    k_unknown:'Unknown', k_unknown_sub:'no status reported',
    k_reboot:'Pending Reboot', k_reboot_sub:'real compliance at risk',
    chart_status:'Overall Patch Status', chart_site:'Compliance by Site',
    exec_title:'Executive Summary',
    search:'Search by hostname, user, IP...',
    filter_all:'All statuses', filter_success:'Success', filter_error:'Error', filter_unknown:'Unknown',
    filter_reboot_all:'Reboot: all', filter_reboot_yes:'Pending reboot', filter_reboot_no:'No pending reboot',
    export_csv:'Export CSV', print:'Print / PDF',
    col_host:'Hostname', col_os:'Windows Version', col_upn:'User UPN', col_ip:'IP', col_site:'Site',
    col_status:'Patch Installed', col_error:'Error Detail', col_reboot:'Pending Reboot', col_uptime:'Uptime (days)',
    footer1:'This report was automatically generated from SCCM/MECM data.',
    footer2:'Confidential document - restricted distribution to client management team.'
  }
};

let currentLang = document.documentElement.getAttribute('data-lang') || 'pt-BR';

function applyI18n(lang) {
  currentLang = lang;
  document.documentElement.setAttribute('data-lang', lang);
  document.querySelectorAll('[data-i18n]').forEach(el => {
    const k = el.getAttribute('data-i18n');
    if (I18N[lang][k]) el.textContent = I18N[lang][k];
  });
  document.querySelectorAll('[data-i18n-placeholder]').forEach(el => {
    const k = el.getAttribute('data-i18n-placeholder');
    if (I18N[lang][k]) el.placeholder = I18N[lang][k];
  });
  document.getElementById('execSummaryText').innerHTML = buildExecSummary(lang);
  renderTable(currentRows);
}

document.getElementById('langToggle').addEventListener('click', () => {
  applyI18n(currentLang === 'pt-BR' ? 'en-US' : 'pt-BR');
});

applyI18n(currentLang);
</script>
</body>
</html>
'@

    & $StatusCallback "Aplicando regras de SLA e traducoes..."

    # --- SLA banner (SLA = $SlaDays dias corridos a partir do inicio do deployment) ---
    $slaBannerHtml = ''
    $slaDeadlineStr = if ($slaDeadline) { $slaDeadline.ToString('dd/MM/yyyy') } else { 'N/A' }
    if ($slaState -eq 'overdue') {
        $slaBannerHtml = "<div class='sla-banner sla-overdue'>&#9888; SLA de $SlaDays dias estourado ha $([math]::Abs($daysToDeadline)) dia(s) (prazo era $slaDeadlineStr) - acao imediata recomendada para os $errorCount + $unknown dispositivo(s) ainda nao compliant.</div>"
    }
    elseif ($slaState -eq 'warning') {
        $slaBannerHtml = "<div class='sla-banner sla-warning'>&#9203; Faltam $daysToDeadline dia(s) para o fim do SLA de $SlaDays dias (prazo: $slaDeadlineStr) - acompanhar de perto os pendentes.</div>"
    }
    elseif ($slaState -eq 'ok') {
        $slaBannerHtml = "<div class='sla-banner sla-ok'>&#10003; Dentro do SLA de $SlaDays dias - dia $daysElapsed de $SlaDays, prazo final em $slaDeadlineStr.</div>"
    }

    $logoHtml = if ($LogoUrl) { "<img src='$LogoUrl' alt='logo'>" } else { '' }

    # --- Substituicao de tokens ---
    $html = $template
    $html = $html.Replace('__DEFAULT_LANG__', $DefaultLanguage)
    $html = $html.Replace('__DEPLOYMENT_NAME__', [System.Net.WebUtility]::HtmlEncode($data.DeploymentName))
    $html = $html.Replace('__COLLECTION_NAME__', [System.Net.WebUtility]::HtmlEncode($data.CollectionName))
    $html = $html.Replace('__COMPANY_NAME__', [System.Net.WebUtility]::HtmlEncode($CompanyName))
    $html = $html.Replace('__LOGO_IMG__', $logoHtml)
    $html = $html.Replace('__GENERATED_AT__', $GeneratedAt.ToString('dd/MM/yyyy HH:mm'))
    $html = $html.Replace('__SLA_BANNER__', $slaBannerHtml)
    $html = $html.Replace('__TOTAL__', $total)
    $html = $html.Replace('__SUCCESS__', $success)
    $html = $html.Replace('__ERROR__', $errorCount)
    $html = $html.Replace('__UNKNOWN__', $unknown)
    $html = $html.Replace('__PENDING_REBOOT__', $pendingReboot)
    $html = $html.Replace('__COMPLIANCE_PCT__', $compliancePct)
    $html = $html.Replace('__TARGET_PCT__', $ComplianceTarget)
    $html = $html.Replace('__GAP__', $gapToTarget)
    $html = $html.Replace('__SLA_DAYS__', $SlaDays)
    $html = $html.Replace('__SLA_DEADLINE__', $slaDeadlineStr)
    $html = $html.Replace('__HOSTS_JSON__', $hostsJson)
    $html = $html.Replace('__BY_SITE_JSON__', $bySiteJson)
    $html = $html.Replace('__BY_OS_JSON__', $byOSJson)
    $html = $html.Replace('__TOP_ERRORS_JSON__', $topErrorsJson)

    # --- Grava arquivo ---
    & $StatusCallback "Salvando arquivo..."
    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $fileName = "PatchReport_{0}_{1}.html" -f ($data.DeploymentName -replace '[^a-zA-Z0-9]', '_'), $GeneratedAt.ToString('yyyyMMdd_HHmm')
    $fullPath = Join-Path (Resolve-Path $OutputPath).Path $fileName
    $html | Out-File -FilePath $fullPath -Encoding utf8

    & $StatusCallback "Relatorio gerado com sucesso."

    return [PSCustomObject]@{
        FilePath       = $fullPath
        Total          = $total
        Success        = $success
        Error          = $errorCount
        Unknown        = $unknown
        PendingReboot  = $pendingReboot
        CompliancePct  = $compliancePct
    }
}

# ============================================================================
# JANELA GRAFICA (Windows Forms) - "Patch Management Modern Workplace Report"
# ============================================================================
function Show-ReportGui {
    param(
        [string]$InitialDeploymentID,
        [string]$InitialCollectionID,
        [string]$InitialSqlServer,
        [string]$InitialDatabase,
        [string]$InitialOutputPath = ".\Reports",
        [string]$InitialCompanyName = "Sua Empresa - Managed Services",
        [double]$InitialComplianceTarget = 99.0,
        [int]$InitialSlaDays = 30,
        [string]$InitialDefaultLanguage = 'pt-BR'
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [System.Windows.Forms.Application]::EnableVisualStyles()

    # --- Paleta alinhada com o relatorio HTML ---
    $navy      = [System.Drawing.Color]::FromArgb(11, 31, 58)
    $navy2     = [System.Drawing.Color]::FromArgb(18, 41, 77)
    $accent    = [System.Drawing.Color]::FromArgb(47, 111, 237)
    $bgColor   = [System.Drawing.Color]::FromArgb(244, 246, 251)
    $textColor = [System.Drawing.Color]::FromArgb(26, 34, 51)
    $fontRegular = New-Object System.Drawing.Font("Segoe UI", 9)
    $fontBold    = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $fontTitle   = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $fontSubtitle= New-Object System.Drawing.Font("Segoe UI", 8.5)

    # --- Form principal ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Patch Management Modern Workplace Report"
    $form.Size = New-Object System.Drawing.Size(560, 760)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.BackColor = $bgColor
    $form.Font = $fontRegular

    # --- Cabecalho estilizado ---
    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Size = New-Object System.Drawing.Size(560, 78)
    $headerPanel.Location = New-Object System.Drawing.Point(0, 0)
    $headerPanel.BackColor = $navy
    $form.Controls.Add($headerPanel)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Patch Management Modern Workplace Report"
    $titleLabel.ForeColor = [System.Drawing.Color]::White
    $titleLabel.Font = $fontTitle
    $titleLabel.AutoSize = $false
    $titleLabel.Size = New-Object System.Drawing.Size(520, 30)
    $titleLabel.Location = New-Object System.Drawing.Point(20, 16)
    $headerPanel.Controls.Add($titleLabel)

    $subtitleLabel = New-Object System.Windows.Forms.Label
    $subtitleLabel.Text = "Gerador de relatorio de compliance de patch (SCCM / MECM)"
    $subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(200, 210, 230)
    $subtitleLabel.Font = $fontSubtitle
    $subtitleLabel.AutoSize = $false
    $subtitleLabel.Size = New-Object System.Drawing.Size(520, 20)
    $subtitleLabel.Location = New-Object System.Drawing.Point(20, 46)
    $headerPanel.Controls.Add($subtitleLabel)

    # --- Helper para criar GroupBox ---
    function New-Section {
        param([string]$Title, [int]$Y, [int]$Height)
        $gb = New-Object System.Windows.Forms.GroupBox
        $gb.Text = $Title
        $gb.Font = $fontBold
        $gb.ForeColor = $navy
        $gb.Location = New-Object System.Drawing.Point(20, $Y)
        $gb.Size = New-Object System.Drawing.Size(504, $Height)
        $form.Controls.Add($gb)
        return $gb
    }

    function New-FieldLabel {
        param($Parent, [string]$Text, [int]$X, [int]$Y)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $Text
        $lbl.Font = $fontRegular
        $lbl.ForeColor = $textColor
        $lbl.Location = New-Object System.Drawing.Point($X, $Y)
        $lbl.Size = New-Object System.Drawing.Size(150, 20)
        $Parent.Controls.Add($lbl)
        return $lbl
    }

    # ============================ SECAO: DEPLOYMENT ============================
    $gbDeploy = New-Section -Title "Deployment" -Y 92 -Height 90

    New-FieldLabel -Parent $gbDeploy -Text "Deployment ID:" -X 15 -Y 28
    $txtDeploymentId = New-Object System.Windows.Forms.TextBox
    $txtDeploymentId.Location = New-Object System.Drawing.Point(170, 25)
    $txtDeploymentId.Size = New-Object System.Drawing.Size(310, 24)
    $txtDeploymentId.Text = $InitialDeploymentID
    $gbDeploy.Controls.Add($txtDeploymentId)

    New-FieldLabel -Parent $gbDeploy -Text "Collection ID:" -X 15 -Y 58
    $txtCollectionId = New-Object System.Windows.Forms.TextBox
    $txtCollectionId.Location = New-Object System.Drawing.Point(170, 55)
    $txtCollectionId.Size = New-Object System.Drawing.Size(310, 24)
    $txtCollectionId.Text = $InitialCollectionID
    $gbDeploy.Controls.Add($txtCollectionId)

    # ============================ SECAO: CONEXAO SQL ============================
    $gbSql = New-Section -Title "Conexao com o banco do site SCCM" -Y 192 -Height 130

    $chkDemo = New-Object System.Windows.Forms.CheckBox
    $chkDemo.Text = "Modo Demonstracao (gera dados ficticios, sem conectar no SQL)"
    $chkDemo.Font = $fontRegular
    $chkDemo.Location = New-Object System.Drawing.Point(15, 25)
    $chkDemo.Size = New-Object System.Drawing.Size(470, 22)
    $gbSql.Controls.Add($chkDemo)

    New-FieldLabel -Parent $gbSql -Text "SQL Server:" -X 15 -Y 58
    $txtSqlServer = New-Object System.Windows.Forms.TextBox
    $txtSqlServer.Location = New-Object System.Drawing.Point(170, 55)
    $txtSqlServer.Size = New-Object System.Drawing.Size(310, 24)
    $txtSqlServer.Text = $InitialSqlServer
    $gbSql.Controls.Add($txtSqlServer)

    New-FieldLabel -Parent $gbSql -Text "Database:" -X 15 -Y 90
    $txtDatabase = New-Object System.Windows.Forms.TextBox
    $txtDatabase.Location = New-Object System.Drawing.Point(170, 87)
    $txtDatabase.Size = New-Object System.Drawing.Size(310, 24)
    $txtDatabase.Text = $InitialDatabase
    $gbSql.Controls.Add($txtDatabase)

    $chkDemo.Add_CheckedChanged({
        $txtSqlServer.Enabled = -not $chkDemo.Checked
        $txtDatabase.Enabled = -not $chkDemo.Checked
        $txtDeploymentId.Enabled = -not $chkDemo.Checked
        $txtCollectionId.Enabled = -not $chkDemo.Checked
    })

    # ============================ SECAO: CONFIGURACOES ============================
    $gbConfig = New-Section -Title "Configuracoes do Relatorio" -Y 334 -Height 260

    New-FieldLabel -Parent $gbConfig -Text "Nome da Empresa:" -X 15 -Y 28
    $txtCompany = New-Object System.Windows.Forms.TextBox
    $txtCompany.Location = New-Object System.Drawing.Point(170, 25)
    $txtCompany.Size = New-Object System.Drawing.Size(310, 24)
    $txtCompany.Text = $InitialCompanyName
    $gbConfig.Controls.Add($txtCompany)

    New-FieldLabel -Parent $gbConfig -Text "Meta de Compliance (%):" -X 15 -Y 60
    $numTarget = New-Object System.Windows.Forms.NumericUpDown
    $numTarget.Location = New-Object System.Drawing.Point(170, 58)
    $numTarget.Size = New-Object System.Drawing.Size(100, 24)
    $numTarget.DecimalPlaces = 1
    $numTarget.Minimum = 0
    $numTarget.Maximum = 100
    $numTarget.Value = [decimal]$InitialComplianceTarget
    $gbConfig.Controls.Add($numTarget)

    New-FieldLabel -Parent $gbConfig -Text "SLA (dias):" -X 300 -Y 60
    $numSla = New-Object System.Windows.Forms.NumericUpDown
    $numSla.Location = New-Object System.Drawing.Point(380, 58)
    $numSla.Size = New-Object System.Drawing.Size(100, 24)
    $numSla.Minimum = 1
    $numSla.Maximum = 365
    $numSla.Value = $InitialSlaDays
    $gbConfig.Controls.Add($numSla)

    New-FieldLabel -Parent $gbConfig -Text "Idioma padrao:" -X 15 -Y 92
    $cmbLang = New-Object System.Windows.Forms.ComboBox
    $cmbLang.Location = New-Object System.Drawing.Point(170, 89)
    $cmbLang.Size = New-Object System.Drawing.Size(150, 24)
    $cmbLang.DropDownStyle = "DropDownList"
    [void]$cmbLang.Items.Add("pt-BR")
    [void]$cmbLang.Items.Add("en-US")
    $cmbLang.SelectedItem = $InitialDefaultLanguage
    $gbConfig.Controls.Add($cmbLang)

    New-FieldLabel -Parent $gbConfig -Text "Logo (URL, opcional):" -X 15 -Y 124
    $txtLogo = New-Object System.Windows.Forms.TextBox
    $txtLogo.Location = New-Object System.Drawing.Point(170, 121)
    $txtLogo.Size = New-Object System.Drawing.Size(310, 24)
    $gbConfig.Controls.Add($txtLogo)

    New-FieldLabel -Parent $gbConfig -Text "Pasta de saida:" -X 15 -Y 156
    $txtOutput = New-Object System.Windows.Forms.TextBox
    $txtOutput.Location = New-Object System.Drawing.Point(170, 153)
    $txtOutput.Size = New-Object System.Drawing.Size(240, 24)
    $txtOutput.Text = $InitialOutputPath
    $gbConfig.Controls.Add($txtOutput)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = "..."
    $btnBrowse.Location = New-Object System.Drawing.Point(420, 152)
    $btnBrowse.Size = New-Object System.Drawing.Size(60, 26)
    $gbConfig.Controls.Add($btnBrowse)
    $btnBrowse.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($fbd.ShowDialog() -eq 'OK') { $txtOutput.Text = $fbd.SelectedPath }
    })

    # --- Status label (multilinha) ---
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15, 190)
    $lblStatus.Size = New-Object System.Drawing.Size(470, 44)
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
    $lblStatus.Font = $fontSubtitle
    $lblStatus.Text = ""
    $gbConfig.Controls.Add($lblStatus)

    # --- Barra de progresso ---
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(20, 602)
    $progressBar.Size = New-Object System.Drawing.Size(504, 12)
    $progressBar.Style = "Marquee"
    $progressBar.MarqueeAnimationSpeed = 0
    $progressBar.Visible = $false
    $form.Controls.Add($progressBar)

    # --- Botoes ---
    $btnGenerate = New-Object System.Windows.Forms.Button
    $btnGenerate.Text = "Gerar Relatorio"
    $btnGenerate.Location = New-Object System.Drawing.Point(20, 630)
    $btnGenerate.Size = New-Object System.Drawing.Size(240, 40)
    $btnGenerate.BackColor = $accent
    $btnGenerate.ForeColor = [System.Drawing.Color]::White
    $btnGenerate.Font = $fontBold
    $btnGenerate.FlatStyle = "Flat"
    $btnGenerate.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnGenerate)

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = "Abrir Relatorio"
    $btnOpen.Location = New-Object System.Drawing.Point(270, 630)
    $btnOpen.Size = New-Object System.Drawing.Size(125, 40)
    $btnOpen.Enabled = $false
    $form.Controls.Add($btnOpen)

    $btnFolder = New-Object System.Windows.Forms.Button
    $btnFolder.Text = "Abrir Pasta"
    $btnFolder.Location = New-Object System.Drawing.Point(400, 630)
    $btnFolder.Size = New-Object System.Drawing.Size(124, 40)
    $btnFolder.Enabled = $false
    $form.Controls.Add($btnFolder)

    $script:lastReportPath = $null

    $btnGenerate.Add_Click({
        $btnGenerate.Enabled = $false
        $btnOpen.Enabled = $false
        $btnFolder.Enabled = $false
        $progressBar.Visible = $true
        $progressBar.MarqueeAnimationSpeed = 30
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
        $lblStatus.Text = "Iniciando..."
        [System.Windows.Forms.Application]::DoEvents()

        $statusCb = {
            param($msg)
            $lblStatus.Text = $msg
            [System.Windows.Forms.Application]::DoEvents()
        }

        try {
            $result = New-PatchReport `
                -DeploymentID $txtDeploymentId.Text `
                -CollectionID $txtCollectionId.Text `
                -SqlServer $txtSqlServer.Text `
                -Database $txtDatabase.Text `
                -DemoMode:$chkDemo.Checked `
                -OutputPath $txtOutput.Text `
                -CompanyName $txtCompany.Text `
                -LogoUrl $txtLogo.Text `
                -ComplianceTarget ([double]$numTarget.Value) `
                -SlaDays ([int]$numSla.Value) `
                -DefaultLanguage $cmbLang.SelectedItem `
                -StatusCallback $statusCb

            $script:lastReportPath = $result.FilePath
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(31, 161, 92)
            $lblStatus.Text = "Concluido: $($result.Total) dispositivos | $($result.CompliancePct)% compliance | Erros: $($result.Error)"
            $btnOpen.Enabled = $true
            $btnFolder.Enabled = $true
        }
        catch {
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(217, 48, 37)
            $lblStatus.Text = "Erro: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Erro ao gerar relatorio", `
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
        finally {
            $progressBar.MarqueeAnimationSpeed = 0
            $progressBar.Visible = $false
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $btnGenerate.Enabled = $true
        }
    })

    $btnOpen.Add_Click({
        if ($script:lastReportPath -and (Test-Path $script:lastReportPath)) {
            Start-Process $script:lastReportPath
        }
    })

    $btnFolder.Add_Click({
        if ($script:lastReportPath -and (Test-Path $script:lastReportPath)) {
            Start-Process explorer.exe -ArgumentList "/select,`"$script:lastReportPath`""
        }
    })

    [void]$form.ShowDialog()
}

# ============================================================================
# DESPACHO: decide entre GUI e execucao via linha de comando
# ============================================================================
$hasLiveParams = $DeploymentID -and $CollectionID -and $SqlServer -and $Database
$launchGui = $Gui -or (-not $DemoMode -and -not $hasLiveParams)

if ($launchGui) {
    Show-ReportGui -InitialDeploymentID $DeploymentID -InitialCollectionID $CollectionID `
        -InitialSqlServer $SqlServer -InitialDatabase $Database -InitialOutputPath $OutputPath `
        -InitialCompanyName $CompanyName -InitialComplianceTarget $ComplianceTarget `
        -InitialSlaDays $SlaDays -InitialDefaultLanguage $DefaultLanguage
}
else {
    $result = New-PatchReport -DeploymentID $DeploymentID -CollectionID $CollectionID `
        -SqlServer $SqlServer -Database $Database -DemoMode:$DemoMode -OutputPath $OutputPath `
        -CompanyName $CompanyName -LogoUrl $LogoUrl -ComplianceTarget $ComplianceTarget `
        -SlaDays $SlaDays -DefaultLanguage $DefaultLanguage

    Write-Host "`nRelatorio gerado com sucesso: $($result.FilePath)" -ForegroundColor Green
    Write-Host "Total: $($result.Total) | Sucesso: $($result.Success) | Erro: $($result.Error) | Unknown: $($result.Unknown) | Compliance: $($result.CompliancePct)%" -ForegroundColor Green
}
