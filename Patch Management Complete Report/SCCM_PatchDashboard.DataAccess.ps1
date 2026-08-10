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
# ETAPA 2 - grava/le o historico diario
# ================================================================

function Save-CycleSnapshot {
    <#
        Grava (ou atualiza) a linha do dia corrente na tabela de historico
        criada na ETAPA 2 (dbo.PatchCycle_DailyHistory).
    #>
    param(
        [Parameter(Mandatory)][string]$SqlServer,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$CollectionID,
        [Parameter(Mandatory)][string]$CycleLabel,
        [Parameter(Mandatory)][int]$DayNumber,
        [Parameter(Mandatory)][datetime]$CalendarDate,
        [Parameter(Mandatory)][int]$PopulationTotal,
        [Parameter(Mandatory)][int]$CorrectedCount,
        [Parameter(Mandatory)][string]$LogPath
    )

    $connStr = New-SqlConnectionString -Server $SqlServer -Database $Database
    $percent = if ($PopulationTotal -gt 0) { [math]::Round(($CorrectedCount / $PopulationTotal) * 100, 2) } else { 0 }

    $mergeSql = @"
MERGE dbo.PatchCycle_DailyHistory AS target
USING (SELECT
            '$CycleLabel'                          AS CycleLabel,
            $DayNumber                              AS DayNumber,
            CONVERT(date, '$($CalendarDate.ToString('yyyy-MM-dd'))') AS CalendarDate,
            '$CollectionID'                         AS CollectionID,
            $PopulationTotal                        AS PopulationTotal,
            $CorrectedCount                         AS CorrectedCount,
            $percent                                AS PercentCompliant
      ) AS src
ON  target.CycleLabel = src.CycleLabel
AND target.DayNumber  = src.DayNumber
WHEN MATCHED THEN
    UPDATE SET
        PopulationTotal    = src.PopulationTotal,
        CorrectedCount     = src.CorrectedCount,
        PercentCompliant   = src.PercentCompliant,
        CollectionID       = src.CollectionID,
        SnapshotCapturedAt = SYSDATETIME(),
        IsSeedData         = 0
WHEN NOT MATCHED THEN
    INSERT (CycleLabel, DayNumber, CalendarDate, CollectionID, PopulationTotal, CorrectedCount, PercentCompliant, IsSeedData)
    VALUES (src.CycleLabel, src.DayNumber, src.CalendarDate, src.CollectionID, src.PopulationTotal, src.CorrectedCount, src.PercentCompliant, 0);
"@

    Invoke-SqlNonQuery -ConnectionString $connStr -Query $mergeSql -TimeoutSeconds 60
    Write-Log $LogPath "Snapshot gravado: ciclo $CycleLabel, dia $DayNumber ($($CalendarDate.ToString('yyyy-MM-dd'))), $CorrectedCount/$PopulationTotal ($percent%)."
    return $percent
}

function Get-PreviousCycleLabel {
    param([string]$CycleLabel)  # 'YYYY-MM'
    $dt = [datetime]::ParseExact($CycleLabel + '-01', 'yyyy-MM-dd', $null)
    $prev = $dt.AddMonths(-1)
    return $prev.ToString('yyyy-MM')
}

function Get-CycleFooterHtml {
    <#
        Monta o HTML do rodape: tabela dia-a-dia (ciclo atual x ciclo anterior,
        pelo mesmo Day Number), resumo semanal e performance do ciclo (dia 31/fim).
    #>
    param(
        [Parameter(Mandatory)][string]$SqlServer,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$CycleLabel,
        [Parameter(Mandatory)][string]$LogPath
    )

    $connStr = New-SqlConnectionString -Server $SqlServer -Database $Database
    $prevLabel = Get-PreviousCycleLabel -CycleLabel $CycleLabel

    $sql = @"
SELECT
    cur.DayNumber,
    cur.CalendarDate                                   AS Current_Date,
    cur.PercentCompliant                               AS Current_Percent,
    prev.CalendarDate                                  AS Previous_Date,
    prev.PercentCompliant                              AS Previous_Percent,
    CASE WHEN cur.PercentCompliant IS NULL OR prev.PercentCompliant IS NULL THEN NULL
         ELSE ROUND(cur.PercentCompliant - prev.PercentCompliant, 2) END AS Delta_Percent
FROM dbo.PatchCycle_DailyHistory cur
LEFT JOIN dbo.PatchCycle_DailyHistory prev
    ON prev.CycleLabel = '$prevLabel' AND prev.DayNumber = cur.DayNumber
WHERE cur.CycleLabel = '$CycleLabel'
ORDER BY cur.DayNumber;
"@

    $ds = Get-SqlDataSet -ConnectionString $connStr -Query $sql -TimeoutSeconds 60
    $days = @(ConvertFrom-DataTable -Table $ds.Tables[0])

    if ($days.Count -eq 0) {
        Write-Log $LogPath "Sem linhas de historico para o ciclo $CycleLabel; rodape comparativo nao sera exibido hoje." 'WARN'
        return ''
    }

    $rowsHtml = ($days | ForEach-Object {
        $curPct  = if ($_.Current_Percent  -ne [DBNull]::Value) { '{0:N2}%' -f [double]$_.Current_Percent }  else { '-' }
        $prevPct = if ($_.Previous_Percent -ne [DBNull]::Value) { '{0:N2}%' -f [double]$_.Previous_Percent } else { '-' }
        $delta   = if ($_.Delta_Percent    -ne [DBNull]::Value) {
            $d = [double]$_.Delta_Percent
            $cls = if ($d -gt 0) { 'deltaPos' } elseif ($d -lt 0) { 'deltaNeg' } else { 'deltaFlat' }
            "<span class='$cls'>$('{0:+0.00;-0.00;0.00}' -f $d)%</span>"
        } else { '-' }
        $curDate = if ($_.Current_Date -ne [DBNull]::Value) { ([datetime]$_.Current_Date).ToString('dd/MM') } else { '' }
        "<tr><td>Dia $($_.DayNumber)</td><td>$curDate</td><td>$curPct</td><td>$prevPct</td><td>$delta</td></tr>"
    }) -join "`n"

    $lastWithData = $days | Where-Object { $_.Current_Percent -ne [DBNull]::Value } | Select-Object -Last 1
    $firstOfWeek  = $days | Where-Object { $_.Current_Percent -ne [DBNull]::Value } | Select-Object -Last 7 -First 1
    $weeklyGain = if ($lastWithData -and $firstOfWeek -and $lastWithData.DayNumber -ne $firstOfWeek.DayNumber) {
        '{0:N2}%' -f ([double]$lastWithData.Current_Percent - [double]$firstOfWeek.Current_Percent)
    } else { 'N/A' }

    $day31 = $days | Where-Object { $_.DayNumber -eq 31 } | Select-Object -First 1
    $cycleEndSummary = if ($day31 -and $day31.Current_Percent -ne [DBNull]::Value) {
        "Fechamento do ciclo (dia 31): <strong>{0:N2}%</strong>" -f [double]$day31.Current_Percent
    } else {
        "Ciclo em andamento - ultimo dia com dado: <strong>{0:N2}%</strong> (Dia $($lastWithData.DayNumber))" -f [double]$lastWithData.Current_Percent
    }

    $overallDelta = if ($day31 -and $day31.Delta_Percent -ne [DBNull]::Value) {
        "Ganho/perda total no fechamento vs ciclo anterior: <strong>{0:+0.00;-0.00;0.00}%</strong>" -f [double]$day31.Delta_Percent
    } elseif ($lastWithData -and $lastWithData.Delta_Percent -ne [DBNull]::Value) {
        "Ganho/perda ate agora vs mesmo dia do ciclo anterior: <strong>{0:+0.00;-0.00;0.00}%</strong>" -f [double]$lastWithData.Delta_Percent
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
