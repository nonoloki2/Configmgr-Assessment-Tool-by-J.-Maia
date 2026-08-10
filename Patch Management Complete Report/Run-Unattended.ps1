<#
================================================================================
 SCCM Monthly Patch Dashboard - ETAPA 3
 Execução 100% desatendida (sem WPF). Disparado pela ferramenta de automação
 todo dia às 17h. Gera o mesmo Dashboard.html de sempre, agora alimentado
 pelas queries SQL (Etapa 1), grava o snapshot do dia (Etapa 2) e injeta o
 rodapé comparativo de ciclo direto no HTML.
================================================================================
#>

param()

# ================================================================
# CONFIGURAÇÃO FIXA — preencher UMA vez. A automação não passa
# nenhum parâmetro na hora de agendar; roda sem argumentos.
# ================================================================

$SqlServer   = ''                     # <-- ÚNICO valor que falta preencher (nome/instância do SQL Server do site A03)
$Database    = 'CMA03'

# Coleção alvo (as mesmas 3 opções que já vinham nas queries originais — deixe só uma ativa)
#$CollectionID = 'A03002CF'           # All MDTs and Workstations
#$CollectionID = 'A0300E27'           # All Enterprise MDTs and Workstation
$CollectionID = 'A0300E28'            # All NBU Workstations

$DeploymentNamePattern = 'Desktop Deployment - Enterprise Production - Windows - {YYYY} - {MM}'

# Pastas relativas ao próprio script — nada disso precisa ser passado por fora
$QueryFilePath = Join-Path $PSScriptRoot '01_Compliance_Query_AutoResolve.sql'
$OutputFolder  = Join-Path $PSScriptRoot 'Reports'
$LogFolder     = Join-Path $OutputFolder 'Logs'

if ([string]::IsNullOrWhiteSpace($SqlServer)) {
    throw "Preencha a variável `$SqlServer no início deste script antes de agendar a automação."
}

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SCCM_PatchDashboard.Core.ps1')
. (Join-Path $PSScriptRoot 'SCCM_PatchDashboard.DataAccess.ps1')

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logPath = Join-Path $LogFolder "Run_$stamp.log"
Set-Content -LiteralPath $logPath -Value '' -Encoding UTF8

try {
    Write-Log $logPath "===== Execução iniciada (headless) ====="

    # 1) Extrai dados via SQL (AssignmentID, KBs e ciclo resolvidos dinamicamente pela própria query)
    $data = Get-SqlComplianceRows -SqlServer $SqlServer -Database $Database `
        -CollectionID $CollectionID -DeploymentNamePattern $DeploymentNamePattern `
        -QueryFilePath $QueryFilePath -LogPath $logPath

    if ($data.Rows.Count -eq 0) {
        throw "Nenhum dispositivo retornado para a coleção $CollectionID / AssignmentID $($data.AssignmentID)."
    }

    $cycleLabel = $data.CycleStartDate.ToString('yyyy-MM')
    $today = Get-Date

    # 2) Grava o snapshot do dia no histórico (Etapa 2)
    $population = $data.Rows.Count
    $corrected  = @($data.Rows | Where-Object ComplianceBucket -eq 'Compliant').Count

    Save-CycleSnapshot -SqlServer $SqlServer -Database $Database -CollectionID $CollectionID `
        -CycleLabel $cycleLabel -DayNumber $data.CycleDayNumber -CalendarDate $today `
        -PopulationTotal $population -CorrectedCount $corrected -LogPath $logPath | Out-Null

    # 3) Monta o HTML do rodapé comparativo (ciclo atual x ciclo anterior)
    $footerHtml = Get-CycleFooterHtml -SqlServer $SqlServer -Database $Database `
        -CycleLabel $cycleLabel -LogPath $logPath

    # 4) Gera o dashboard (mesmas funções/HTML de sempre + rodapé novo)
    $result = Export-ReportPackage `
        -Rows $data.Rows `
        -DeploymentName $data.DeploymentName `
        -CollectionName $data.DeploymentName `
        -CollectionID $data.CollectionID `
        -AssignmentID $data.AssignmentID `
        -DeploymentID ([string]$data.AssignmentID) `
        -BaseOutputFolder $OutputFolder `
        -LogPath $logPath `
        -CheckApiBase '' `
        -CheckToken '' `
        -CycleFooterHtml $footerHtml

    Write-Log $logPath "Dashboard gerado com sucesso: $($result.DashboardPath)"
    Write-Log $logPath "===== Execução concluída OK ====="
    exit 0
}
catch {
    $msg = "ERRO: $($_.Exception.Message) | Linha: $($_.InvocationInfo.ScriptLineNumber) | $($_.InvocationInfo.PositionMessage)"
    if (Test-Path -LiteralPath $logPath) { Write-Log $logPath $msg 'ERROR' }
    Write-Error $msg
    exit 1
}
