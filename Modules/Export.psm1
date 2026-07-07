Set-StrictMode -Version Latest

function Export-AssessmentCsv {
    param(
        [Parameter(Mandatory)] [object[]]$Results,
        [Parameter(Mandatory)] [string]$OutputFolder,
        [Parameter(Mandatory)] [string]$AssessmentId
    )

    function Ensure-Folder {
        param([Parameter(Mandatory)][string]$Folder)
        if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
            New-Item -ItemType Directory -Path $Folder -Force -ErrorAction Stop | Out-Null
        }
    }

    # Keep the file name intentionally short to avoid Windows MAX_PATH issues in deeply nested GitHub folders.
    $shortId = $AssessmentId.Substring(0,8)
    $fileName = "Discovery_$((Get-Date).ToString('yyyyMMdd_HHmmss'))_$shortId.csv"

    try {
        Ensure-Folder -Folder $OutputFolder
        $path = Join-Path $OutputFolder $fileName
        $Results | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        return $path
    }
    catch {
        # Fallback for long paths, OneDrive/GitHub folders, or restricted project directories.
        $fallbackFolder = Join-Path $env:TEMP 'ConfigMgrAssessmentTool_by_J_Maia\CSV'
        Ensure-Folder -Folder $fallbackFolder
        $fallbackPath = Join-Path $fallbackFolder $fileName
        $Results | Export-Csv -LiteralPath $fallbackPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        return $fallbackPath
    }
}

Export-ModuleMember -Function Export-AssessmentCsv
