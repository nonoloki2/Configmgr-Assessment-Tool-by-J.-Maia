# Importa o módulo do Configuration Manager
Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1"

# Define o site code do SCCM (ex: "ABC")
$SiteCode = "CT1"
Set-Location "$SiteCode`:"

# Caminho da Device Collection
$CollectionName = "name"

# Caminho do arquivo de hosts
$HostsFile = "D:\Scripts\hosts.txt"

# Lê os nomes dos dispositivos
$HostList = Get-Content $HostsFile

# Loop para adicionar cada dispositivo à coleção
foreach ($Host in $HostList) {
    # Verifica se o recurso existe no SCCM
    $Resource = Get-CMDevice -Name $Host

    if ($Resource) {
        # Adiciona à coleção
        Add-CMDeviceCollectionDirectMembershipRule -CollectionName $CollectionName -ResourceID $Resource.ResourceID
        Write-Host "Adicionado: $Host"
    } else {
        Write-Warning "Dispositivo não encontrado no SCCM: $Host"
    }
}