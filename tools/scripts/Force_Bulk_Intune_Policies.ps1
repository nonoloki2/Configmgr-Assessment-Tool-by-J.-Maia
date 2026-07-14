# Lista de computadores (pode ser substituída por importação de CSV ou consulta AD)
$computadores = @("PC01", "PC02", "PC03")  # Substitua pelos nomes reais

# Comando remoto para forçar avaliação de compliance
$scriptRemoto = {
    Write-Host "Sincronizando políticas do Intune em $env:COMPUTERNAME..."

    $agentPath = "C:\Program Files (x86)\Microsoft Intune Management Extension\Microsoft.Management.Services.IntuneWindowsAgent.exe"
    if (Test-Path $agentPath) {
        Start-Process -FilePath $agentPath -ArgumentList "intunemanagementextension://synccompliance" -Wait
        Write-Host "Compliance reavaliado em $env:COMPUTERNAME."
    } else {
        Write-Host "Intune Agent não encontrado em $env:COMPUTERNAME."
    }

    # Força sincronização geral com Intune
    try {
        Start-ScheduledTask -TaskName "PushLaunch"
        Write-Host "Tarefa PushLaunch executada."
    } catch {
        Write-Host "Tarefa PushLaunch não encontrada ou falhou."
    }
}

# Executa remotamente em cada computador
foreach ($pc in $computadores) {
    Write-Host "`n--- Executando em $pc ---"
    Invoke-Command -ComputerName $pc -ScriptBlock $scriptRemoto -ErrorAction SilentlyContinue
}