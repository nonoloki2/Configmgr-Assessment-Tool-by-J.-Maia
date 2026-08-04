<#
.SYNOPSIS
    Limpa a OutlookSecureTempFolder de todos os perfis de usuário na máquina.
.DESCRIPTION
    Fecha o processo do Outlook em execução, percorre todos os perfis em
    C:\Users, localiza o caminho da OutlookSecureTempFolder no registro de
    cada usuário (carregando a hive NTUSER.DAT quando o perfil não está
    logado) e limpa o conteúdo da pasta.
    Requer execução como Administrador.
#>

#Requires -RunAsAdministrator

$logPath = "C:\Temp\OutlookTempCleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
New-Item -ItemType Directory -Path "C:\Temp" -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    Write-Host $line
    Add-Content -Path $logPath -Value $line
}

Write-Log "=== Iniciando limpeza da OutlookSecureTempFolder em todos os perfis ==="

# --- Fecha o Outlook (se estiver rodando) para evitar arquivos travados ---
$outlookProcs = Get-Process -Name "OUTLOOK" -ErrorAction SilentlyContinue
if ($outlookProcs) {
    Write-Log "Outlook em execução detectado (PID(s): $($outlookProcs.Id -join ', ')). Encerrando..."
    $outlookProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    # Confirma que realmente fechou
    $stillRunning = Get-Process -Name "OUTLOOK" -ErrorAction SilentlyContinue
    if ($stillRunning) {
        Write-Log "AVISO: Outlook ainda em execução após tentativa de encerramento (PID(s): $($stillRunning.Id -join ', '))."
    } else {
        Write-Log "Outlook encerrado com sucesso."
    }
} else {
    Write-Log "Outlook não estava em execução."
}

# Pega todos os perfis de usuário reais (ignora contas de serviço padrão)
$profileList = Get-ChildItem "C:\Users" -Directory | Where-Object {
    $_.Name -notin @('Public', 'Default', 'Default User', 'All Users')
}

foreach ($profile in $profileList) {
    $userName   = $profile.Name
    $ntuserPath = Join-Path $profile.FullName "NTUSER.DAT"

    if (-not (Test-Path $ntuserPath)) {
        Write-Log "[$userName] NTUSER.DAT não encontrado, pulando."
        continue
    }

    $sid = $null
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($userName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        Write-Log "[$userName] Não foi possível resolver SID, pulando."
        continue
    }

    $hiveLoaded    = Test-Path "Registry::HKEY_USERS\$sid"
    $tempHiveName  = "TempHive_$userName"
    $hiveMountedByScript = $false

    if (-not $hiveLoaded) {
        $result = reg load "HKU\$tempHiveName" "$ntuserPath" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "[$userName] Falha ao carregar hive (pode estar em uso/logado). Detalhe: $result"
            continue
        }
        $hiveMountedByScript = $true
        $regRoot = "Registry::HKEY_USERS\$tempHiveName"
    } else {
        $regRoot = "Registry::HKEY_USERS\$sid"
    }

    $officeVersions = @('16.0','15.0','14.0')
    $tempFolderFound = $false

    foreach ($ver in $officeVersions) {
        $regKeyPath = "$regRoot\Software\Microsoft\Office\$ver\Outlook\Security"
        if (Test-Path $regKeyPath) {
            $secureTempFolder = (Get-ItemProperty -Path $regKeyPath -Name "OutlookSecureTempFolder" -ErrorAction SilentlyContinue).OutlookSecureTempFolder
            if ($secureTempFolder) {
                $tempFolderFound = $true
                $resolvedPath = $secureTempFolder -replace '%USERPROFILE%', $profile.FullName
                $resolvedPath = [Environment]::ExpandEnvironmentVariables($resolvedPath)

                if (Test-Path $resolvedPath) {
                    try {
                        $files = Get-ChildItem -Path $resolvedPath -Force -ErrorAction SilentlyContinue
                        $count = ($files | Measure-Object).Count
                        $files | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
                        Write-Log "[$userName] Office $ver - Limpou $count itens em: $resolvedPath"
                    } catch {
                        Write-Log "[$userName] Office $ver - Erro ao limpar $resolvedPath : $_"
                    }
                } else {
                    Write-Log "[$userName] Office $ver - Caminho não existe no disco: $resolvedPath"
                }
            }
        }
    }

    if (-not $tempFolderFound) {
        Write-Log "[$userName] Nenhuma chave OutlookSecureTempFolder encontrada (Outlook pode não estar instalado/configurado)."
    }

    if ($hiveMountedByScript) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 500
        $unloadResult = reg unload "HKU\$tempHiveName" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "[$userName] AVISO: falha ao descarregar hive temporária: $unloadResult"
        }
    }
}

Write-Log "=== Limpeza concluída. Log salvo em $logPath ==="