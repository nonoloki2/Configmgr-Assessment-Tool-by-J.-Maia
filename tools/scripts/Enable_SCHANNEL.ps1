# Caminho base
$basePath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols"

# Protocolos inseguros - desabilitar
$protocolsToDisable = @("SSL 3.0", "TLS 1.0", "TLS 1.1")
foreach ($protocol in $protocolsToDisable) {
    foreach ($role in @("Client", "Server")) {
        $path = "$basePath\$protocol\$role"
        New-Item -Path $path -Force | Out-Null
        New-ItemProperty -Path $path -Name "Enabled" -Value 0 -PropertyType DWord -Force | Out-Null
    }
}

# TLS 1.2 - habilitar
foreach ($role in @("Client", "Server")) {
    $path = "$basePath\TLS 1.2\$role"
    New-Item -Path $path -Force | Out-Null
    New-ItemProperty -Path $path -Name "Enabled" -Value 1 -PropertyType DWord -Force | Out-Null
}