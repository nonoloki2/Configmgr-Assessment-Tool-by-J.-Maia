# Configurações
$SiteServer = "maznasccmp01.na.admworld.com"   # Substitua pelo hostname real do seu servidor de site
$SiteCode = "PR1"
$CollectionName = "SCTASK1902722"
$OutputPath = "C:\SCCM_Status_Export"

# Garante o diretório
if (!(Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath | Out-Null }

# Namespace remoto
$SccmNamespace = "root\SMS\site_$SiteCode"

# Busca via WMI remoto
$ClientSummaries = Get-WmiObject -Namespace $SccmNamespace -Class SMS_ClientSummary -ComputerName $SiteServer

# Agrupa por status
$GroupedStatus = $ClientSummaries | Group-Object -Property ClientCheckDescription

foreach ($Group in $GroupedStatus) {
    $StatusName = $Group.Name -replace '[^a-zA-Z0-9]', '_'
    $FileName = "$($CollectionName)_$StatusName.txt"
    $FullPath = Join-Path $OutputPath $FileName

    $Group.Group | ForEach-Object { $_.Name } | Sort-Object | Out-File -FilePath $FullPath -Encoding UTF8
    Write-Host "Arquivo criado: $FullPath"
}

Write-Host "`nExportação concluída com sucesso!"
