$script:LogFilePath = $null

function Initialize-CATLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][string]$AssessmentId
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:LogFilePath = Join-Path $LogDirectory "ConfigMgrAssessment_${stamp}_${AssessmentId}.log"
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Log started. AssessmentId=$AssessmentId" | Out-File -FilePath $script:LogFilePath -Encoding UTF8
    return $script:LogFilePath
}

function Write-CATLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )

    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    if ($script:LogFilePath) {
        $line | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    }
    return $line
}

function Get-CATLogPath {
    return $script:LogFilePath
}

Export-ModuleMember -Function Initialize-CATLog, Write-CATLog, Get-CATLogPath
