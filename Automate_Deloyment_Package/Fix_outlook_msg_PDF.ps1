<#
.SYNOPSIS
    Corrige a associação de arquivos .msg para abrir com o Outlook em vez do Adobe Reader,
    no contexto de um usuário específico, remotamente.
.PARAMETER TargetUser
    Nome de usuário (SAM, ex: "gabriela.renton") do perfil afetado.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$TargetUser
)

$logPath = "C:\Temp\FixMsgAssoc_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$toolDir = "C:\Temp\SetUserFTA"
New-Item -ItemType Directory -Path $toolDir -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    Write-Host $line
    Add-Content -Path $logPath -Value $line
}

# --- 1. Confirma que o usuário está com sessão ativa (necessário para o trigger Interactive) ---
$session = query user 2>$null | Where-Object { $_ -match [regex]::Escape($TargetUser) }
if (-not $session) {
    Write-Log "ERRO: usuário '$TargetUser' não encontrado com sessão ativa nesta máquina. Peça para ele logar e rode novamente."
    return
}
Write-Log "Sessão ativa encontrada para $TargetUser."

# --- 2. Baixa o SetUserFTA.exe (se ainda não estiver presente) ---
$exePath = Join-Path $toolDir "SetUserFTA.exe"
if (-not (Test-Path $exePath)) {
    try {
        Invoke-WebRequest -Uri "https://kolbi.cz/SetUserFTA.exe" -OutFile $exePath -UseBasicParsing
        Write-Log "SetUserFTA.exe baixado com sucesso."
    } catch {
        Write-Log "ERRO ao baixar SetUserFTA.exe: $_. Copie manualmente para $toolDir e rode de novo."
        return
    }
} else {
    Write-Log "SetUserFTA.exe já presente em $toolDir."
}

# --- 3. Descobre o ProgID que o Outlook usa para .msg neste sistema ---
$progId = (Get-ItemProperty "HKLM:\SOFTWARE\Classes\.msg" -Name "(default)" -ErrorAction SilentlyContinue).'(default)'
if (-not $progId) { $progId = "Outlook.File.msg" }  # fallback padrão
Write-Log "ProgID identificado para .msg: $progId"

# --- 4. Cria tarefa agendada temporária que roda no contexto do usuário logado ---
$taskName = "TEMP_FixMsgFTA_$TargetUser"
$action  = New-ScheduledTaskAction -Execute $exePath -Argument ".msg $progId" -WorkingDirectory $toolDir
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
$principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Limited

try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-Log "Tarefa '$taskName' registrada. Executando..."
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 5

    $result = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
    Write-Log "Resultado da execução (0 = sucesso): $result"
} catch {
    Write-Log "ERRO ao registrar/executar a tarefa: $_"
} finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Tarefa temporária removida."
}

Write-Log "=== Concluído. Log salvo em $logPath ==="