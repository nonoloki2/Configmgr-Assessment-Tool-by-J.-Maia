<# 
.SYNOPSIS
Instala todas as atualizações do Windows automaticamente.

.DESCRIPTION
Usa o módulo PSWindowsUpdate para buscar e instalar updates do Windows/Microsoft Update.
#>

# Garante que o script está rodando como administrador
If (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Warning "Please run as administrator!"
    Break
}

# Importa o módulo PSWindowsUpdate
Import-Module PSWindowsUpdate -Force

# Busca e instala todas as atualizações disponíveis
Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Verbose
