#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$HostsFile,
    [string]$PsExecPath,
    [string]$OutputFolder,
    [int]$DaysBack = 7,
    [int]$ConnectionTimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'

function Get-ScriptFolder {
    if ($PSCommandPath) { return (Split-Path -Parent $PSCommandPath) }
    if ($MyInvocation.MyCommand.Path) { return (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    return (Get-Location).Path
}

function Write-EmptyCsv {
    param([string]$Path, [string[]]$Columns)

    $header = ($Columns | ForEach-Object { '"' + ($_ -replace '"','""') + '"' }) -join ';'
    [System.IO.File]::WriteAllText(
        $Path,
        $header + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($true))
    )
}

$ScriptFolder = Get-ScriptFolder

if ([string]::IsNullOrWhiteSpace($HostsFile)) {
    $HostsFile = Join-Path $ScriptFolder 'hosts.txt'
}

if ([string]::IsNullOrWhiteSpace($OutputFolder)) {
    $OutputFolder = Join-Path $ScriptFolder 'FREB_Reports'
}

if ([string]::IsNullOrWhiteSpace($PsExecPath)) {
    $candidates = @(
        (Join-Path $ScriptFolder 'PsExec64.exe'),
        (Join-Path $ScriptFolder 'PsExec.exe'),
        'C:\Sysinternals\PsExec64.exe',
        'C:\Sysinternals\PsExec.exe'
    )

    $PsExecPath = $candidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}

$RemoteCollector = Join-Path $ScriptFolder 'RemoteCollector.ps1'

Clear-Host
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' IIS FREB Error Collector - PsExec' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "Pasta do script : $ScriptFolder"
Write-Host "Arquivo hosts   : $HostsFile"
Write-Host "RemoteCollector : $RemoteCollector"
Write-Host "PsExec           : $PsExecPath"
Write-Host "Pasta de saída  : $OutputFolder"
Write-Host "Últimos dias    : $DaysBack"
Write-Host ''

if (-not (Test-Path -LiteralPath $HostsFile -PathType Leaf)) {
    throw "Arquivo hosts.txt não encontrado: $HostsFile"
}

if (-not (Test-Path -LiteralPath $RemoteCollector -PathType Leaf)) {
    throw "RemoteCollector.ps1 não encontrado: $RemoteCollector"
}

if ([string]::IsNullOrWhiteSpace($PsExecPath) -or -not (Test-Path -LiteralPath $PsExecPath -PathType Leaf)) {
    throw "PsExec.exe ou PsExec64.exe não encontrado. Coloque-o em $ScriptFolder ou informe -PsExecPath."
}

if (-not (Test-Path -LiteralPath $OutputFolder -PathType Container)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

$Hosts = @(
    Get-Content -LiteralPath $HostsFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') } |
        Sort-Object -Unique
)

if ($Hosts.Count -eq 0) {
    throw "Nenhum servidor válido encontrado em $HostsFile"
}

$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$CsvPath = Join-Path $OutputFolder "FREB_Errors_$Timestamp.csv"
$StatusCsvPath = Join-Path $OutputFolder "FREB_ScanStatus_$Timestamp.csv"

$Results = New-Object System.Collections.Generic.List[object]
$StatusResults = New-Object System.Collections.Generic.List[object]

foreach ($ComputerName in $Hosts) {
    Write-Host "[$ComputerName] Executando coleta via PsExec..." -ForegroundColor Yellow

    $remoteArgs = @(
        "\\$ComputerName"
        '-accepteula'
        '-nobanner'
        '-n'
        "$ConnectionTimeoutSeconds"
        '-s'
        'powershell.exe'
        '-NoLogo'
        '-NoProfile'
        '-NonInteractive'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $RemoteCollector
        '-DaysBack'
        "$DaysBack"
    )

    $output = @()
    $exitCode = -1

    try {
        $output = @(& $PsExecPath @remoteArgs 2>&1)
        $exitCode = $LASTEXITCODE
    }
    catch {
        $output = @($_.Exception.Message)
    }

    $summary = $null
    $hostFound = 0

    foreach ($line in $output) {
        $text = [string]$line

        if ($text.StartsWith('FREB_RESULT|')) {
            $json = $text.Substring(12)
            try {
                $obj = $json | ConvertFrom-Json

                $Results.Add([PSCustomObject]@{
                    Hostname       = $ComputerName
                    AppPool        = $obj.AppPool
                    Erro           = $obj.Erro
                    PackageID      = $obj.PackageID
                    ArquivoComErro = $obj.ArquivoComErro
                    URL            = $obj.URL
                    FailureReason  = $obj.FailureReason
                    StatusCode     = $obj.StatusCode
                    SubStatusCode  = $obj.SubStatusCode
                    TriggerStatus  = $obj.TriggerStatus
                    SiteIIS        = $obj.SiteIIS
                    DataLog        = $obj.DataLog
                    TempoMS        = $obj.TempoMS
                    ActivityID     = $obj.ActivityID
                    ArquivoXML     = $obj.ArquivoXML
                })

                $hostFound++
                Write-Host ("[{0}] Erro {1} | Pool: {2} | Pacote: {3} | Arquivo: {4}" -f `
                    $ComputerName, $obj.Erro, $obj.AppPool, $obj.PackageID, $obj.ArquivoComErro) -ForegroundColor Red
            }
            catch {
                Write-Warning "[$ComputerName] Falha ao interpretar resultado JSON: $($_.Exception.Message)"
            }
        }
        elseif ($text.StartsWith('FREB_SUMMARY|')) {
            $json = $text.Substring(13)
            try { $summary = $json | ConvertFrom-Json } catch {}
        }
    }

    if ($summary) {
        $StatusResults.Add([PSCustomObject]@{
            Hostname        = $ComputerName
            Status          = $summary.Status
            XmlFilesRead    = $summary.XmlFilesRead
            ErrorsFound     = $summary.ErrorsFound
            InvalidXmlCount = $summary.InvalidXmlCount
            PsExecExitCode  = $exitCode
            Details         = $summary.Details
            FrebPath        = $summary.FrebPath
        })

        $color = if ($summary.Status -eq 'Success') { 'Green' } else { 'Red' }
        Write-Host ("[{0}] {1} | XMLs: {2} | Erros: {3}" -f `
            $ComputerName, $summary.Status, $summary.XmlFilesRead, $summary.ErrorsFound) -ForegroundColor $color
    }
    else {
        $details = (($output | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Last 10) -join ' | ')
        if (-not $details) { $details = 'PsExec não retornou saída útil.' }

        $StatusResults.Add([PSCustomObject]@{
            Hostname        = $ComputerName
            Status          = 'PsExecFailed'
            XmlFilesRead    = 0
            ErrorsFound     = $hostFound
            InvalidXmlCount = 0
            PsExecExitCode  = $exitCode
            Details         = $details
            FrebPath        = 'C:\inetpub\logs\FailedReqLogFiles'
        })

        Write-Host "[$ComputerName] Falha via PsExec. ExitCode: $exitCode" -ForegroundColor Red
        Write-Host $details -ForegroundColor DarkRed
    }

    Write-Host ''
}

$columns = @(
    'Hostname','AppPool','Erro','PackageID','ArquivoComErro','URL','FailureReason',
    'StatusCode','SubStatusCode','TriggerStatus','SiteIIS','DataLog','TempoMS',
    'ActivityID','ArquivoXML'
)

if ($Results.Count -gt 0) {
    $Results |
        Select-Object $columns |
        Sort-Object Hostname, DataLog, Erro, PackageID, ArquivoComErro |
        Export-Csv -LiteralPath $CsvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8
}
else {
    Write-EmptyCsv -Path $CsvPath -Columns $columns
}

$StatusResults |
    Sort-Object Hostname |
    Export-Csv -LiteralPath $StatusCsvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' Processo concluído' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "Ocorrências       : $($Results.Count)"
Write-Host "Relatório de erros: $CsvPath"
Write-Host "Status dos hosts  : $StatusCsvPath"
