<# 
.SYNOPSIS
Força a atualização do membership da collection "Global Server Prod Patching (Saturday)"
no site PR1.
#>

# Caminho do módulo do SCCM
$SCCMModulePath = "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"

Write-Host "Importando módulo do Configuration Manager..." -ForegroundColor Cyan
Import-Module $SCCMModulePath -Force

# Conectar ao site PR1
cd PR1:

# Nome da collection
$CollectionName = "Global Server Prod Patching (Saturday)"

# Forçar update do membership
Write-Host "Forçando atualização do membership da collection: $CollectionName" -ForegroundColor Yellow
Invoke-CMCollectionUpdate -Name $CollectionName

Write-Host "Atualização de membership disparada com sucesso!" -ForegroundColor Green
