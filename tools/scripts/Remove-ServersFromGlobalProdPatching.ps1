<# 
.SYNOPSIS
Remove servidores da collection "Global Server Prod Patching (Saturday)" no SCCM (site PR1).

.DESCRIPTION
Esse script importa o módulo do Configuration Manager, conecta ao site PR1,
carrega a lista de servidores a partir de um arquivo TXT em D:\Temp\servers.txt
e remove os objetos da collection especificada.
#>

# Caminho do módulo do SCCM
$SCCMModulePath = "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"

Write-Host "Importando módulo do Configuration Manager..." -ForegroundColor Cyan
Import-Module $SCCMModulePath -Force

# Conectar ao site PR1
cd PR1:

# Nome da collection conforme indicado
$CollectionName = "Global Server Prod Patching (Saturday)"

# Caminho fixo para a lista de servidores
$ServerListPath = "D:\Temp\servers.txt"

# Carregar lista de servidores do TXT
if (-Not (Test-Path $ServerListPath)) {
    Write-Error "Arquivo de servidores não encontrado: $ServerListPath"
    exit
}

$Servers = Get-Content $ServerListPath | Where-Object {$_ -and $_.Trim() -ne ""}

Write-Host "Encontrados $($Servers.Count) servidores no arquivo." -ForegroundColor Yellow

foreach ($Server in $Servers) {
    $CleanName = $Server.Trim()
    $Device = Get-CMDevice -Name $CleanName -ErrorAction SilentlyContinue

    if ($Device) {
        Write-Host "Removendo $CleanName da collection $CollectionName..." -ForegroundColor Green
        Remove-CMDeviceCollectionDirectMembershipRule -CollectionName $CollectionName -ResourceID $Device.ResourceID -Force
    } else {
        Write-Warning "Dispositivo $CleanName não encontrado no SCCM."
    }
}

Write-Host "Processo concluído!" -ForegroundColor Cyan
