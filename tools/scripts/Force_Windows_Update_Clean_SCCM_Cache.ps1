# Executa em modo silencioso e elevado
$ErrorActionPreference = 'Stop'

# Para o serviço do agente SCCM
Write-Host "Parando serviço CcmExec..."
Stop-Service -Name CcmExec -Force -ErrorAction SilentlyContinue

# Limpa a pasta ccmcache
$ccmCachePath = "$env:SystemRoot\ccmcache"
if (Test-Path $ccmCachePath) {
    Write-Host "Limpando pasta ccmcache em $ccmCachePath..."
    Get-ChildItem -Path $ccmCachePath -Recurse -Force | Remove-Item -Force -Recurse
} else {
    Write-Host "Pasta ccmcache não encontrada em $ccmCachePath"
}

# Reinicia o serviço do agente SCCM
Write-Host "Reiniciando serviço CcmExec..."
Start-Service -Name CcmExec

# Instala o NuGet provider sem confirmação
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser

# Garante que o repositório PSGallery esteja confiável
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

# Instala o módulo PSWindowsUpdate se ainda não estiver instalado
if (-not (Get-InstalledModule -Name PSWindowsUpdate -ErrorAction SilentlyContinue)) {
    Install-Module -Name PSWindowsUpdate -Force -Confirm:$false -Scope CurrentUser -AllowClobber
}

# Executa atualização do Windows sem prompts e sem reiniciar
Import-Module PSWindowsUpdate
Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Verbose