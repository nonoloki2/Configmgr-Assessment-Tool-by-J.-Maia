$marker = Join-Path $env:ProgramData 'SAP\SAPGUI80-Migration\Installed.tag'

if (Test-Path -LiteralPath $marker -PathType Leaf) {
    Write-Output 'SAP GUI 8.00 migration detected'
    exit 0
}

exit 1
