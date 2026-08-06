<#
.SYNOPSIS
    Localiza e desinstala TODAS as versoes de um software instalado,
    varrendo o Registro do Windows (64 e 32 bits) e as pastas
    Program Files / Program Files (x86).

.DESCRIPTION
    - Procura em:
        HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall
        HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall
        HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall
    - Filtra pelo nome (parcial, sem diferenciar maiusculas/minusculas).
    - Usa QuietUninstallString quando existe; senao monta um comando
      silencioso (msiexec /x {GUID} /quiet /norestart para MSI,
      ou tenta acrescentar /quiet, /S, /silent para instaladores EXE).
    - Tambem varre C:\Program Files e C:\Program Files (x86) procurando
      pastas com nome compativel e um uninstall.exe / unins000.exe dentro,
      como fallback para o que nao aparece no registro.
    - Modo -WhatIf simula sem executar nada. Sem -Force, pede confirmacao
      antes de cada desinstalacao.

.PARAMETER SoftwareName
    Parte do nome do software a procurar. Ex: "Protection Suite", "protection".

.PARAMETER Force
    Executa a desinstalacao sem pedir confirmacao item a item.

.PARAMETER WhatIf
    Apenas mostra o que seria feito, sem executar nada (simulacao).

.PARAMETER LogPath
    Caminho do arquivo de log. Padrao: %TEMP%\Uninstall-SoftwareByName.log

.EXAMPLE
    .\Uninstall-SoftwareByName.ps1 -SoftwareName "Protection Suite"

.EXAMPLE
    .\Uninstall-SoftwareByName.ps1 -SoftwareName "Protection Suite" -Force

.EXAMPLE
    .\Uninstall-SoftwareByName.ps1 -SoftwareName "Protection Suite" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$SoftwareName,

    [switch]$Force,

    [string]$LogPath = (Join-Path $env:TEMP "Uninstall-SoftwareByName.log")
)

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

function Test-IsAdmin {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pri = New-Object Security.Principal.WindowsPrincipal($id)
    return $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Warning "Este script deve ser executado como Administrador para enxergar e remover todos os programas (inclusive de outros usuarios)."
    Write-Warning "Reabra o PowerShell como Administrador e execute novamente."
    exit 1
}

# Com -Force, tambem suprime a confirmacao automatica do PowerShell
# (a que vem do ConfirmImpact = 'High' no CmdletBinding), alem da nossa
# confirmacao manual mais abaixo.
if ($Force) {
    $ConfirmPreference = 'None'
}

Write-Log "=== Iniciando varredura por '$SoftwareName' ==="

# ---------------------------------------------------------------------------
# 1) Varredura no Registro
# ---------------------------------------------------------------------------

$uninstallRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)

$found = New-Object System.Collections.Generic.List[Object]

foreach ($root in $uninstallRoots) {
    if (-not (Test-Path $root)) { continue }

    Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty -Path $_.PsPath -ErrorAction SilentlyContinue
        if ($null -eq $props.DisplayName) { return }

        if ($props.DisplayName -like "*$SoftwareName*") {
            $found.Add([PSCustomObject]@{
                Source              = "Registro"
                DisplayName         = $props.DisplayName
                DisplayVersion      = $props.DisplayVersion
                Publisher           = $props.Publisher
                UninstallString     = $props.UninstallString
                QuietUninstallString= $props.QuietUninstallString
                InstallLocation     = $props.InstallLocation
                RegistryKey         = $_.PsPath
            })
        }
    }
}

Write-Log "Encontrados $($found.Count) item(ns) no Registro."

# ---------------------------------------------------------------------------
# 2) Varredura em Program Files / Program Files (x86)
#    (fallback para instalacoes que nao registraram entrada de Uninstall)
# ---------------------------------------------------------------------------

$programDirs = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
$folderMatches = New-Object System.Collections.Generic.List[Object]

foreach ($base in $programDirs) {
    Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$SoftwareName*" } |
        ForEach-Object {
            $dir = $_.FullName
            $uninstaller = Get-ChildItem -Path $dir -Recurse -Depth 2 -ErrorAction SilentlyContinue -Include "uninstall*.exe","unins000.exe" |
                Select-Object -First 1

            $folderMatches.Add([PSCustomObject]@{
                Source          = "Pasta"
                FolderPath      = $dir
                UninstallerPath = if ($uninstaller) { $uninstaller.FullName } else { $null }
                # ja coberto pelo registro?
                AlreadyInRegistry = [bool]($found | Where-Object { $_.InstallLocation -and $_.InstallLocation.TrimEnd('\') -eq $dir.TrimEnd('\') })
            })
        }
}

Write-Log "Encontradas $($folderMatches.Count) pasta(s) compativel(is) em Program Files / Program Files (x86)."

if ($found.Count -eq 0 -and $folderMatches.Count -eq 0) {
    Write-Log "Nenhum software correspondente a '$SoftwareName' foi encontrado." "WARN"
    exit 0
}

# ---------------------------------------------------------------------------
# 3) Exibir resumo antes de agir
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "==================== RESUMO ====================" -ForegroundColor Cyan
if ($found.Count -gt 0) {
    $found | ForEach-Object {
        Write-Host ""
        Write-Host "[Registro] $($_.DisplayName) - versao $($_.DisplayVersion)" -ForegroundColor Yellow
        Write-Host "  Fabricante : $($_.Publisher)"
        Write-Host "  Uninstall  : $($_.UninstallString)"
        if ($_.QuietUninstallString) {
            Write-Host "  QuietUninst: $($_.QuietUninstallString)"
        }
    }
}
if ($folderMatches.Count -gt 0) {
    $folderMatches | ForEach-Object {
        Write-Host ""
        Write-Host "[Pasta] $($_.FolderPath)" -ForegroundColor Yellow
        if ($_.UninstallerPath) {
            Write-Host "  Uninstaller encontrado: $($_.UninstallerPath)"
        } else {
            Write-Host "  Nenhum uninstaller.exe conhecido encontrado nesta pasta (remocao manual pode ser necessaria)."
        }
        if ($_.AlreadyInRegistry) {
            Write-Host "  (Ja coberto por uma entrada do Registro acima)"
        }
    }
}
Write-Host "=================================================="
Write-Host ""

# ---------------------------------------------------------------------------
# 4) Funcao para montar/rodar o comando de desinstalacao silenciosa
# ---------------------------------------------------------------------------

function Invoke-SilentUninstall {
    param(
        [string]$DisplayName,
        [string]$UninstallString,
        [string]$QuietUninstallString
    )

    $cmd = $null

    if ($QuietUninstallString) {
        $cmd = $QuietUninstallString
    }
    elseif ($UninstallString -match 'msiexec') {
        # Extrai o GUID / codigo do produto MSI e monta comando silencioso padrao
        if ($UninstallString -match '(\{[0-9A-Fa-f\-]{36}\})') {
            $productCode = $Matches[1]
            $cmd = "msiexec.exe /x $productCode /quiet /norestart"
        } else {
            $cmd = ($UninstallString -replace '/I', '/X') + " /quiet /norestart"
        }
    }
    elseif ($UninstallString) {
        # Instalador generico (EXE). Tenta acrescentar flags silenciosas comuns
        # sem duplicar se ja existirem.
        $cmd = $UninstallString
        if ($cmd -notmatch '(?i)/quiet|/silent|/S\b|/verysilent') {
            $cmd = "$cmd /quiet"
        }
    }

    if (-not $cmd) {
        Write-Log "Nao foi possivel montar comando de desinstalacao para '$DisplayName'." "ERROR"
        return $false
    }

    Write-Log "Comando: $cmd"

    if (-not $PSCmdlet.ShouldProcess($DisplayName, "Desinstalar")) {
        return $false
    }

    if (-not $Force) {
        $answer = Read-Host "Confirmar desinstalacao de '$DisplayName'? (S/N)"
        if ($answer -notin @("S", "s", "Y", "y")) {
            Write-Log "Pulado por escolha do usuario: $DisplayName"
            return $false
        }
    }

    try {
        # Separa executavel dos argumentos respeitando aspas
        if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') {
            $exe  = $Matches[1]
            $args = $Matches[2]
        } else {
            $parts = $cmd -split '\s+', 2
            $exe   = $parts[0]
            $args  = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        }

        $proc = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru -ErrorAction Stop
        Write-Log "'$DisplayName' finalizado com codigo de saida $($proc.ExitCode)."
        return $true
    }
    catch {
        Write-Log "Falha ao desinstalar '$DisplayName': $_" "ERROR"
        return $false
    }
}

# ---------------------------------------------------------------------------
# 5) Executa desinstalacoes encontradas no Registro
# ---------------------------------------------------------------------------

foreach ($item in $found) {
    Invoke-SilentUninstall -DisplayName $item.DisplayName `
                            -UninstallString $item.UninstallString `
                            -QuietUninstallString $item.QuietUninstallString | Out-Null
}

# ---------------------------------------------------------------------------
# 6) Executa uninstallers encontrados apenas por pasta (nao no registro)
# ---------------------------------------------------------------------------

foreach ($item in ($folderMatches | Where-Object { -not $_.AlreadyInRegistry -and $_.UninstallerPath })) {
    Invoke-SilentUninstall -DisplayName $item.FolderPath `
                            -UninstallString "`"$($item.UninstallerPath)`" /S" `
                            -QuietUninstallString $null | Out-Null
}

Write-Log "=== Varredura/desinstalacao concluida. Log completo em: $LogPath ==="
