function Export-CATCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$AssessmentId,
        [string]$SiteCode = 'UNKNOWN'
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $file = Join-Path $OutputDirectory "ConfigMgr_Assessment_${SiteCode}_${stamp}_${AssessmentId}.csv"
    $Results | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
    return $file
}

Export-ModuleMember -Function Export-CATCsv
