Set-StrictMode -Version Latest

function Export-AssessmentCsv {
    param(
        [Parameter(Mandatory)] [object[]]$Results,
        [Parameter(Mandatory)] [string]$OutputFolder,
        [Parameter(Mandatory)] [string]$AssessmentId
    )

    if (-not (Test-Path $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }

    $fileName = "ConfigMgr_Assessment_Discovery_$((Get-Date).ToString('yyyyMMdd_HHmmss'))_$AssessmentId.csv"
    $path = Join-Path $OutputFolder $fileName
    $Results | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
    return $path
}

Export-ModuleMember -Function Export-AssessmentCsv
