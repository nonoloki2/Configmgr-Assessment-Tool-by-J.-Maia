function Initialize-CATLogger {
    [CmdletBinding()]
    param([object]$Session)
    $datePath = Join-Path $Session.AppRoot (Join-Path 'Output\Logs' (Get-Date -Format 'yyyy\MM\dd'))
    if (-not (Test-Path -LiteralPath $datePath)) { New-Item -ItemType Directory -Path $datePath -Force | Out-Null }
    $file = Join-Path $datePath ('CAT_{0}_{1}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $Session.AssessmentID.Substring(0,8))
    try {
        New-Item -ItemType File -Path $file -Force | Out-Null
        $Session.LogFile = $file
    } catch {
        $fallback = Join-Path $env:TEMP ('CAT_{0}_{1}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $Session.AssessmentID.Substring(0,8))
        New-Item -ItemType File -Path $fallback -Force | Out-Null
        $Session.LogFile = $fallback
    }
}

function Write-CATLog {
    [CmdletBinding()]
    param([object]$Session,[string]$Level='INFO',[string]$Message,[string]$Category='General',[string]$Target='')
    $line = '{0} [{1}] [{2}] {3} {4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Category, $(if($Target){"[$Target]"}else{''}), $Message
    if ($Session.LogFile) { Add-Content -LiteralPath $Session.LogFile -Value $line -Encoding UTF8 }
    return $line
}
Export-ModuleMember -Function *
