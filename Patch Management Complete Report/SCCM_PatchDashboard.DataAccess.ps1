function ConvertTo-NormalizedDeploymentStatus {
    <#
        Mapeia o Status_State (texto vindo de v_StateNames) para os 4
        buckets que o dashboard já usa hoje: Success / InProgress / Error / Unknown.
        Qualquer valor não mapeado cai em Unknown (e é logado), nunca quebra o dashboard.
    #>
    param([string]$StatusState, [string]$LogPath)

    if ([string]::IsNullOrWhiteSpace($StatusState)) { return 'Unknown' }

    switch -Regex ($StatusState.Trim()) {
        '^(Success|Compliant|Succeeded|Installed)$'            { return 'Success' }
        '^(In Progress|InProgress|Downloading|Installing|Waiting.*)$' { return 'InProgress' }
        '^(Error|Failed|Non-?Compliant.*Error)$'                { return 'Error' }
        '^(Unknown|Requirements Not Met|Not Applicable|Non-?Compliant)$' { return 'Unknown' }
        default {
            if ($LogPath) { Write-Log $LogPath "Status_State '$StatusState' sem mapeamento conhecido; tratado como Unknown." 'WARN' }
            return 'Unknown'
        }
    }
}

# ================================================================
# CAMADA SQL - ADO.NET puro (System.Data.SqlClient), sem depender
# de nenhum modulo externo (nada a instalar no servidor).
# ================================================================

Add-Type -AssemblyName System.Data -ErrorAction SilentlyContinue

function New-SqlConnectionString {
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Database
    )
    # Autenticacao Windows Integrada (conta de servico da automacao).
    # Se o ambiente exigir login SQL, troque a linha abaixo por:
    #   "Server=$Server;Database=$Database;User ID=SEU_USER;Password=SUA_SENHA;TrustServerCertificate=True;Connection Timeout=30;"
    return "Server=$Server;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=30;"
}

function ConvertFrom-DataTable {
    <#
        Converte um System.Data.DataTable em uma lista de PSCustomObject,
        preservando [DBNull]::Value como esta (codigo existente ja checa isso).
    #>
    param([Parameter(Mandatory)][System.Data.DataTable]$Table)

    $colNames = @($Table.Columns | ForEach-Object { $_.ColumnName })
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($row in $Table.Rows) {
        $props = [ordered]@{}
        foreach ($c in $colNames) { $props[$c] = $row[$c] }
        $result.Add([pscustomobject]$props)
    }
    return $result.ToArray()
}

function Get-SqlDataSet {
    <#
        Executa uma query (texto ou arquivo .sql) e devolve um DataSet.
        Suporta multiplos result sets (o SqlDataAdapter preenche
        $ds.Tables[0], [1], [2]... na ordem em que a query os retorna).
    #>
    param(
        [Parameter(Mandatory)][string]$ConnectionString,
        [string]$Query,
        [string]$InputFile,
        [int]$TimeoutSeconds = 300
    )

    if ($InputFile) { $Query = Get-Content -LiteralPath $InputFile -Raw -Encoding UTF8 }
    if ([string]::IsNullOrWhiteSpace($Query)) { throw "Get-SqlDataSet: nenhuma query informada (Query ou InputFile)." }

    $conn = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    $cmd  = New-Object System.Data.SqlClient.SqlCommand $Query, $conn
    $cmd.CommandTimeout = $TimeoutSeconds
    $ds = New-Object System.Data.DataSet
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    try {
        $da.Fill($ds) | Out-Null
    }
    finally {
        $conn.Close()
        $conn.Dispose()
    }
    return $ds
}

function Invoke-SqlNonQuery {
    <# Executa comandos sem retorno de linhas (INSERT/UPDATE/MERGE). #>
    param(
        [Parameter(Mandatory)][string]$ConnectionString,
        [Parameter(Mandatory)][string]$Query,
        [int]$TimeoutSeconds = 60
    )
    $conn = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    $cmd  = New-Object System.Data.SqlClient.SqlCommand $Query, $conn
    $cmd.CommandTimeout = $TimeoutSeconds
    try {
        $conn.Open()
        $cmd.ExecuteNonQuery() | Out-Null
    }
    finally {
        $conn.Close()
        $conn.Dispose()
    }
}

# ================================================================
# ETAPA 1 - extracao via SQL (substitui Get-SmsProviderData / WMI)
# ================================================================

function Get-SqlComplianceRows {
    <#
        Executa a query da ETAPA 1 (01_Compliance_Query_AutoResolve.sql) via
        ADO.NET e devolve os dispositivos ja no MESMO formato de objeto que
        Convert-AssetsToRows produz hoje, para o dashboard nao precisar mudar.
        Colunas que so existiam via WMI (ClientType, Preferred DP, Pending
        Reboot, scans, etc.) ficam em branco nesta etapa, por decisao combinada.
    #>
    param(
        [Parameter(Mandatory)][string]$SqlServer,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$CollectionID,
        [Parameter(Mandatory)][string]$DeploymentNamePattern,
        [Parameter(Mandatory)][string]$QueryFilePath,
        [Parameter(Mandatory)][string]$LogPath
    )

    $connStr = New-SqlConnectionString -Server $SqlServer -Database $Database

    $sqlText = Get-Content -LiteralPath $QueryFilePath -Raw -Encoding UTF8
    $sqlText = $sqlText.Replace(
        "DECLARE @CollectionID NVARCHAR(8) = 'A0300E28';",
        "DECLARE @CollectionID NVARCHAR(8) = '$CollectionID';"
    )
    $sqlText = $sqlText -replace `
        "DECLARE @DeploymentNamePattern NVARCHAR\(200\) =\s*\r?\n\s*'.*?';", `
        "DECLARE @DeploymentNamePattern NVARCHAR(200) = '$DeploymentNamePattern';"

    Write-Log $LogPath "Executando query de compliance via ADO.NET (AssignmentID/KBs/ciclo resolvidos dinamicamente pelo proprio T-SQL)."

    $ds = Get-SqlDataSet -ConnectionString $connStr -Query $sqlText -TimeoutSeconds 300

    if ($ds.Tables.Count -lt 3) {
        throw "A query nao devolveu os 3 result sets esperados (diagnostico, compliant, non-compliant). Verifique se ela rodou ate o fim sem erro no SQL Server."
    }

    $diagRows = ConvertFrom-DataTable -Table $ds.Tables[0]
    $diag = $diagRows | Select-Object -First 1

    Write-Log $LogPath ("Resolvido -> AssignmentID={0} | Deployment='{1}' | Cycle_Start={2} | Cycle_Day={3} | KBs={4}" -f `
        $diag.Resolved_AssignmentID, $diag.Resolved_DeploymentName, $diag.Cycle_Start_Date, $diag.Cycle_Day_Number, $diag.Resolved_KBs)

    $compliantRows    = ConvertFrom-DataTable -Table $ds.Tables[1]
    $nonCompliantRows = ConvertFrom-DataTable -Table $ds.Tables[2]

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($r in @($compliantRows) + @($nonCompliantRows)) {
        $statusState = [string]$r.Status_State
        $deploymentStatus = ConvertTo-NormalizedDeploymentStatus -StatusState $statusState -LogPath $LogPath

        $errorCodeValue = [UInt64]0
        if ($r.Error_Code_ExitCode -ne [DBNull]::Value -and $r.Error_Code_ExitCode) {
            try { $errorCodeValue = [UInt64][int64]$r.Error_Code_ExitCode } catch { $errorCodeValue = 0 }
        }
        $errorDetail = if ($errorCodeValue -ne 0) {
            Get-ErrorDetail -Code $errorCodeValue -LastEnforcementMessage '' -StatusDescription ''
        } else { '' }
        $recommendedActions = if ($errorCodeValue -ne 0) { Get-ErrorRecommendations -Code $errorCodeValue } else { '' }

        $hasOSDomain = $r.PSObject.Properties.Name -contains 'OSDomain'

        $rows.Add([pscustomobject]@{
            Device                      = [string]$r.ComputerName
            ClientType                  = ''
            Client                      = ''
            CurrentLoggedOnUser         = [string]$r.UserId
            UserUPN                     = [string]$r.User_Email
            SiteCode                    = ''
            ClientStatus                = 'Unknown'
            ClientCheckResult           = 'Unknown'
            PolicyRequest               = ''
            HeartbeatDDR                = ''
            HardwareScan                = ''
            SoftwareScan                = ''
            ManagementPoint             = ''
            StatusMessage                = ''
            PreferredDistributionPoints = ''
            ADSite                      = ''
            Domain                      = if ($hasOSDomain) { [string]$r.OSDomain } else { '' }
            Uptime                      = ''
            OperatingSystem             = ''
            OSVersion                   = ''
            OSBuildNumber               = [string]$r.FullOSBuild
            PendingRestart              = ''
            RebootReason                = ''
            RebootClientState           = ''
            DeploymentStatus            = $deploymentStatus
            ErrorCode                   = if ($r.Hex_Error_Code -ne [DBNull]::Value) { [string]$r.Hex_Error_Code } else { '' }
            ErrorDetail                 = $errorDetail
            RecommendedActions          = $recommendedActions
            LastStatusTime              = if ($r.Last_Modification -ne [DBNull]::Value) { [string]$r.Last_Modification } else { '' }
            ResourceID                  = 0
            ComplianceBucket            = [string]$r.Compliance_Bucket
            CycleStartDate              = [string]$diag.Cycle_Start_Date
            CycleDayNumber              = [int]$diag.Cycle_Day_Number
        })
    }

    [pscustomobject]@{
        Rows           = $rows.ToArray()
        AssignmentID   = [string]$diag.Resolved_AssignmentID
        DeploymentName = [string]$diag.Resolved_DeploymentName
        CollectionID   = $CollectionID
        CycleStartDate = [datetime]$diag.Cycle_Start_Date
        CycleDayNumber = [int]$diag.Cycle_Day_Number
        ResolvedKBs    = [string]$diag.Resolved_KBs
    }
}

# ================================================================
# ETAPA 2 - historico diario em ARQUIVO JSON LOCAL (nao no SQL de
# producao). O script so faz SELECT no banco do SCCM; nenhuma
# escrita, nenhum CREATE/INSERT/MERGE la. Todo estado de histórico
# fica isolado num arquivo ao lado do script, na maquina de automacao.
# ================================================================

function Import-CycleHistory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw | ConvertFrom-Json)
}

function Export-CycleHistory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Records
    )
    $sorted = $Records | Sort-Object CycleLabel, DayNumber
    $sorted | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Save-CycleSnapshot {
    <#
        Grava (ou atualiza) a linha do dia corrente no arquivo JSON de
        historico (ETAPA 2). Nao toca em nada no SQL Server.
    #>
    param(
        [Parameter(Mandatory)][string]$HistoryPath,
        [Parameter(Mandatory)][string]$CycleLabel,
        [Parameter(Mandatory)][int]$DayNumber,
        [Parameter(Mandatory)][datetime]$CalendarDate,
        [Parameter(Mandatory)][int]$PopulationTotal,
        [Parameter(Mandatory)][int]$CorrectedCount,
        [Parameter(Mandatory)][string]$LogPath
    )

    $percent = if ($PopulationTotal -gt 0) { [math]::Round(($CorrectedCount / $PopulationTotal) * 100, 2) } else { 0 }

    $history = [System.Collections.Generic.List[object]](Import-CycleHistory -Path $HistoryPath)
    $existing = $history | Where-Object { $_.CycleLabel -eq $CycleLabel -and $_.DayNumber -eq $DayNumber } | Select-Object -First 1

    $record = [pscustomobject]@{
        CycleLabel       = $CycleLabel
        DayNumber        = $DayNumber
        CalendarDate     = $CalendarDate.ToString('yyyy-MM-dd')
        PopulationTotal  = $PopulationTotal
        CorrectedCount   = $CorrectedCount
        PercentCompliant = $percent
        IsSeedData       = $false
    }

    if ($existing) {
        $idx = 0
        for ($i = 0; $i -lt $history.Count; $i++) {
            if ($history[$i].CycleLabel -eq $CycleLabel -and $history[$i].DayNumber -eq $DayNumber) { $idx = $i; break }
        }
        $history[$idx] = $record
    } else {
        $history.Add($record)
    }

    Export-CycleHistory -Path $HistoryPath -Records $history.ToArray()
    Write-Log $LogPath "Snapshot gravado no JSON: ciclo $CycleLabel, dia $DayNumber ($($CalendarDate.ToString('yyyy-MM-dd'))), $CorrectedCount/$PopulationTotal ($percent%)."
    return $percent
}

function Get-PreviousCycleLabel {
    param([string]$CycleLabel)  # 'YYYY-MM'
    $dt = [datetime]::ParseExact($CycleLabel + '-01', 'yyyy-MM-dd', $null)
    $prev = $dt.AddMonths(-1)
    return $prev.ToString('yyyy-MM')
}

function ConvertTo-ScalarDouble {
    <# Protege contra valores vindos do JSON como array/duplicados em vez de numero unico. #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [array]) {
        if ($Value.Count -eq 0) { return $null }
        $Value = $Value[0]
    }
    try { return [double]$Value } catch { return $null }
}

function Get-CycleFooterHtml {
    <#
        Monta o HTML do rodape (tabela dia-a-dia, resumo semanal,
        fechamento do ciclo) lendo o histórico direto do JSON local -
        nenhuma consulta ao SQL Server aqui.
    #>
    param(
        [Parameter(Mandatory)][string]$HistoryPath,
        [Parameter(Mandatory)][string]$CycleLabel,
        [Parameter(Mandatory)][string]$LogPath
    )

    $prevLabel = Get-PreviousCycleLabel -CycleLabel $CycleLabel
    $history = Import-CycleHistory -Path $HistoryPath

    $curRows  = @($history | Where-Object CycleLabel -eq $CycleLabel)
    $prevRows = @($history | Where-Object CycleLabel -eq $prevLabel)

    if ($curRows.Count -eq 0) {
        Write-Log $LogPath "Sem linhas de historico (JSON) para o ciclo $CycleLabel; rodape comparativo nao sera exibido hoje." 'WARN'
        return ''
    }

    $prevByDay = @{}
    foreach ($p in $prevRows) { $prevByDay[[int]$p.DayNumber] = $p }

    # Se houver linhas duplicadas para o mesmo DayNumber (ex.: JSON antigo com
    # lixo de execucao anterior), fica so com a ULTIMA por dia.
    $curByDay = [ordered]@{}
    foreach ($c in $curRows) { $curByDay[[int]$c.DayNumber] = $c }

    $days = $curByDay.Keys | Sort-Object { [int]$_ } | ForEach-Object {
        $cur = $curByDay[$_]
        $prev = $prevByDay[[int]$cur.DayNumber]
        $curPercentD  = ConvertTo-ScalarDouble $cur.PercentCompliant
        $prevPercentD = if ($prev) { ConvertTo-ScalarDouble $prev.PercentCompliant } else { $null }
        $delta = if ($null -ne $curPercentD -and $null -ne $prevPercentD) {
            [math]::Round($curPercentD - $prevPercentD, 2)
        } else { $null }

        [pscustomobject]@{
            DayNumber       = [int]$cur.DayNumber
            CalendarDate    = $cur.CalendarDate
            CurrentPercent  = $curPercentD
            PreviousPercent = $prevPercentD
            DeltaPercent    = $delta
        }
    }

    $rowsHtml = ($days | ForEach-Object {
        $curPct  = if ($null -ne $_.CurrentPercent)  { '{0:N2}%' -f [double]$_.CurrentPercent }  else { '-' }
        $prevPct = if ($null -ne $_.PreviousPercent) { '{0:N2}%' -f [double]$_.PreviousPercent } else { '-' }
        $delta   = if ($null -ne $_.DeltaPercent) {
            $d = [double]$_.DeltaPercent
            $cls = if ($d -gt 0) { 'deltaPos' } elseif ($d -lt 0) { 'deltaNeg' } else { 'deltaFlat' }
            "<span class='$cls'>$('{0:+0.00;-0.00;0.00}' -f $d)%</span>"
        } else { '-' }
        $curDate = if ($_.CalendarDate) { ([datetime]$_.CalendarDate).ToString('dd/MM') } else { '' }
        "<tr><td>Dia $($_.DayNumber)</td><td>$curDate</td><td>$curPct</td><td>$prevPct</td><td>$delta</td></tr>"
    }) -join "`n"

    $lastWithData = $days | Where-Object { $null -ne $_.CurrentPercent } | Select-Object -Last 1
    $firstOfWeek  = $days | Where-Object { $null -ne $_.CurrentPercent } | Select-Object -Last 7 -First 1
    $weeklyGain = if ($lastWithData -and $firstOfWeek -and $lastWithData.DayNumber -ne $firstOfWeek.DayNumber) {
        '{0:N2}%' -f ([double]$lastWithData.CurrentPercent - [double]$firstOfWeek.CurrentPercent)
    } else { 'N/A' }

    $day31 = $days | Where-Object { $_.DayNumber -eq 31 } | Select-Object -First 1
    $cycleEndSummary = if ($day31 -and $null -ne $day31.CurrentPercent) {
        "Fechamento do ciclo (dia 31): <strong>{0:N2}%</strong>" -f [double]$day31.CurrentPercent
    } else {
        "Ciclo em andamento - ultimo dia com dado: <strong>{0:N2}%</strong> (Dia $($lastWithData.DayNumber))" -f [double]$lastWithData.CurrentPercent
    }

    $overallDelta = if ($day31 -and $null -ne $day31.DeltaPercent) {
        "Ganho/perda total no fechamento vs ciclo anterior: <strong>{0:+0.00;-0.00;0.00}%</strong>" -f [double]$day31.DeltaPercent
    } elseif ($lastWithData -and $null -ne $lastWithData.DeltaPercent) {
        "Ganho/perda ate agora vs mesmo dia do ciclo anterior: <strong>{0:+0.00;-0.00;0.00}%</strong>" -f [double]$lastWithData.DeltaPercent
    } else { '' }

    return @"
<section class="panel cycle-footer">
  <h2 style="margin-top:0">Comparativo do ciclo - $CycleLabel vs $prevLabel</h2>
  <div class="note">Ganho da semana (ultimos 7 dias com dado): <strong>$weeklyGain</strong> &nbsp;|&nbsp; $cycleEndSummary &nbsp;|&nbsp; $overallDelta</div>
  <table class="cycle-footer-table" style="width:100%;border-collapse:collapse;margin-top:10px;font-size:13px;">
    <thead>
      <tr style="text-align:left;border-bottom:2px solid #d8e1eb;">
        <th style="padding:6px">Dia do ciclo</th><th style="padding:6px">Data</th>
        <th style="padding:6px">% $CycleLabel</th><th style="padding:6px">% $prevLabel</th><th style="padding:6px">Delta</th>
      </tr>
    </thead>
    <tbody>
$rowsHtml
    </tbody>
  </table>
</section>
<style>
.deltaPos{color:#1f9d55;font-weight:600}
.deltaNeg{color:#d64545;font-weight:600}
.deltaFlat{color:#7b8794;font-weight:600}
.cycle-footer-table tbody tr:nth-child(even){background:#f7fafc}
</style>
"@
}
