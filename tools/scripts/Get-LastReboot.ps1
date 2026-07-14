# Caminho do arquivo com a lista de servidores
$hostsFile = "C:\hosts.txt"

# Caminho do arquivo de log de saída
$logFile = "C:\last_reboot.txt"

# Limpa o conteúdo anterior do log
Clear-Content -Path $logFile -ErrorAction SilentlyContinue

# Lê cada servidor da lista
Get-Content $hostsFile | ForEach-Object {
    $server = $_.Trim()
    if ($server) {
        try {
            # Obtém a data do último boot via WMI
            $lastBoot = Get-CimInstance -ComputerName $server -ClassName Win32_OperatingSystem | Select-Object -ExpandProperty LastBootUpTime
            $formattedBoot = ([Management.ManagementDateTimeConverter]::ToDateTime($lastBoot)).ToString("yyyy-MM-dd HH:mm:ss")
            $output = "$server - Último reboot: $formattedBoot"
        } catch {
            $output = "$server - Erro ao conectar ou obter informação: $_"
        }

        # Salva no arquivo de log
        Add-Content -Path $logFile -Value $output
    }
}