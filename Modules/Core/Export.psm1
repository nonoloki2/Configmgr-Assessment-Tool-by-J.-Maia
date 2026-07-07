function Export-CATCsv {
    [CmdletBinding()]
    param([object]$Session)
    $csvDir = Join-Path $Session.AppRoot 'Output\CSV'
    if (-not (Test-Path -LiteralPath $csvDir)) { New-Item -ItemType Directory -Path $csvDir -Force | Out-Null }
    $fileName = 'CAT_{0}_{1}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $Session.AssessmentID.Substring(0,8)
    $path = Join-Path $csvDir $fileName
    try {
        $Session.Results | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
        $Session.LastCsvPath = $path
        return $path
    } catch {
        $fallback = Join-Path $env:TEMP $fileName
        $Session.Results | Export-Csv -LiteralPath $fallback -NoTypeInformation -Encoding UTF8
        $Session.LastCsvPath = $fallback
        return $fallback
    }
}
Export-ModuleMember -Function *
