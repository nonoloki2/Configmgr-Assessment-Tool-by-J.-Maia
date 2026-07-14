<#
.SYNOPSIS
Reseta componentes do Windows Update (Windows 10/11/Server), limpa SoftwareDistribution/Catroot2,
reseta BITS/WinHTTP, re-registra DLLs comuns e reinicia serviços.

.PARAMETER RunHealthRepair
Executa DISM /RestoreHealth e SFC /Scannow no final (pode demorar).

.PARAMETER KeepLogs
Não limpa a pasta de logs do WindowsUpdate (opcional).

.PARAMETER DontRemoveWSPolicies
Não remove políticas de Windows Update/WSUS em HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate

.EXAMPLE
.\Reset-WindowsUpdate.ps1
.\Reset-WindowsUpdate.ps1 -RunHealthRepair
.\Reset-WindowsUpdate.ps1 -DontRemoveWSPolicies
#>

[CmdletBinding()]
param(
    [switch]$RunHealthRepair,
    [switch]$KeepLogs,
    [switch]$DontRemoveWSPolicies
)

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "Execute este script em um PowerShell 'Run as Administrator'." }
}

function Stop-ServicesSafe {
    param([string[]]$Names)

    foreach ($n in $Names) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($null -ne $svc -and $svc.Status -ne 'Stopped') {
            Write-Host "Parando serviço: $n"
            Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
            try { $svc.WaitForStatus('Stopped','00:00:30') | Out-Null } catch {}
        }
    }
}

function Start-ServicesSafe {
    param([string[]]$Names)

    foreach ($n in $Names) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($null -ne $svc -and $svc.Status -ne 'Running') {
            Write-Host "Iniciando serviço: $n"
            Start-Service -Name $n -ErrorAction SilentlyContinue
            try { $svc.WaitForStatus('Running','00:00:30') | Out-Null } catch {}
        }
    }
}

function Rename-Or-DeleteFolder {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Rename
    )

    if (Test-Path $Path) {
        try {
            if ($Rename) {
                $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
                $newPath = "${Path}.bak_$stamp"
                Write-Host "Renomeando: $Path -> $newPath"
                Rename-Item -Path $Path -NewName (Split-Path -Leaf $newPath) -Force
            } else {
                Write-Host "Limpando pasta: $Path"
                Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            }
        } catch {
            Write-Warning "Falha ao manipular ${Path}. Tentando fallback por sub-itens..."
            try {
                Get-ChildItem -Path $Path -Force -ErrorAction Stop |
                    Remove-Item -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Warning "Não foi possível limpar ${Path}: $($_.Exception.Message)"
            }
        }
    }
}

function Reset-WinHTTPProxy {
    Write-Host "Reset WinHTTP proxy..."
    & netsh winhttp reset proxy | Out-Null
}

function Reset-BITSJobs {
    Write-Host "Resetando jobs do BITS..."
    & bitsadmin /reset /allusers 2>$null | Out-Null
}

function ReRegister-WUDlls {
    Write-Host "Re-registrando DLLs comuns do Windows Update..."
    $dlls = @(
        "atl.dll","urlmon.dll","mshtml.dll","shdocvw.dll","browseui.dll","jscript.dll","vbscript.dll",
        "scrrun.dll","msxml.dll","msxml3.dll","msxml6.dll","actxprxy.dll","softpub.dll","wintrust.dll",
        "dssenh.dll","rsaenh.dll","gpkcsp.dll","sccbase.dll","slbcsp.dll","cryptdlg.dll",
        "oleaut32.dll","ole32.dll","shell32.dll","initpki.dll","wuapi.dll","wuaueng.dll","wuaueng1.dll",
        "wucltui.dll","wups.dll","wups2.dll","wuweb.dll","qmgr.dll","qmgrprxy.dll","wucltux.dll","muweb.dll","wuwebv.dll"
    )

    foreach ($d in $dlls) {
        $p = Join-Path $env:windir "System32\$d"
        if (Test-Path $p) {
            & regsvr32.exe /s $p
        }
    }
}

function Reset-WURegistryKeys {
    # Remove políticas WSUS (apenas se existirem).
    # Use -DontRemoveWSPolicies para não mexer nisso.
    if (-not $DontRemoveWSPolicies) {
        Write-Host "Limpando políticas WSUS/WindowsUpdate (se existirem)..."
        $wuPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
        if (Test-Path $wuPolicyPath) {
            try {
                Remove-Item -Path $wuPolicyPath -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Warning "Não consegui remover ${wuPolicyPath}: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Host "Mantendo políticas WSUS/WindowsUpdate (parametro -DontRemoveWSPolicies)."
    }

    # Reset de estados do Windows Update (chaves comuns)
    $auPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update"
    if (Test-Path $auPath) {
        try {
            Remove-ItemProperty -Path $auPath -Name "AUState" -ErrorAction SilentlyContinue
        } catch {}
    }
}

function Reset-NetworkStackOptional {
    # Útil quando erro está ligado a rede/stack (opcional). Pode exigir reboot.
    Write-Host "Resetando Winsock (pode exigir reboot)..."
    & netsh winsock reset | Out-Null
}

function Trigger-WUDetection {
    Write-Host "Disparando detecção do Windows Update..."
    # Windows 10/11/Server recentes:
    & UsoClient StartScan 2>$null | Out-Null

    # Fallback antigo:
    & wuauclt /detectnow /reportnow 2>$null | Out-Null
}

# ---------------- MAIN ----------------
Assert-Admin

$services = @("wuauserv","bits","cryptsvc","msiserver","trustedinstaller")
Write-Host "== Reset Windows Update Components =="

# 1) Parar serviços
Stop-ServicesSafe -Names $services

# 2) Limpar cache e stores (melhor renomear em vez de deletar total)
$sd = Join-Path $env:windir "SoftwareDistribution"
$cr = Join-Path $env:windir "System32\catroot2"

Rename-Or-DeleteFolder -Path $sd -Rename
Rename-Or-DeleteFolder -Path $cr -Rename

if (-not $KeepLogs) {
    $wuLog = Join-Path $env:windir "Logs\WindowsUpdate"
    # Nem sempre existe em todos OS
    if (Test-Path $wuLog) {
        Write-Host "Limpando logs WindowsUpdate..."
        try {
            Get-ChildItem $wuLog -Force -ErrorAction SilentlyContinue |
                Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        } catch {}
    }
}

# 3) Reset de BITS, WinHTTP, reg DLLs e chaves
Reset-BITSJobs
Reset-WinHTTPProxy
ReRegister-WUDlls
Reset-WURegistryKeys

# (Opcional) Se você quiser habilitar winsock reset, descomente:
# Reset-NetworkStackOptional

# 4) Iniciar serviços
Start-ServicesSafe -Names $services

# 5) (Opcional) reparar imagem e arquivos
if ($RunHealthRepair) {
    Write-Host "Executando DISM RestoreHealth..."
    & DISM.exe /Online /Cleanup-Image /RestoreHealth

    Write-Host "Executando SFC Scannow..."
    & sfc.exe /scannow
}

# 6) Disparar scan
Trigger-WUDetection

Write-Host "Concluído. Se você fez winsock reset ou o problema persistir, recomendo REINICIAR a máquina."
