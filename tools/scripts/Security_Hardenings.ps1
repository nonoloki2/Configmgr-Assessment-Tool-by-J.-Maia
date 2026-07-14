# Disable TLS 1.0 and TLS 1.1
$protocols = @("TLS 1.0", "TLS 1.1")
foreach ($protocol in $protocols) {
    $basePath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$protocol"
    New-Item -Path "$basePath\Server" -Force | Out-Null
    New-ItemProperty -Path "$basePath\Server" -Name "Enabled" -Value 0 -PropertyType "DWord" -Force | Out-Null
    New-ItemProperty -Path "$basePath\Server" -Name "DisabledByDefault" -Value 1 -PropertyType "DWord" -Force | Out-Null

    New-Item -Path "$basePath\Client" -Force | Out-Null
    New-ItemProperty -Path "$basePath\Client" -Name "Enabled" -Value 0 -PropertyType "DWord" -Force | Out-Null
    New-ItemProperty -Path "$basePath\Client" -Name "DisabledByDefault" -Value 1 -PropertyType "DWord" -Force | Out-Null
}

# Disable SSL 2.0 and SSL 3.0
$sslVersions = @("SSL 2.0", "SSL 3.0")
foreach ($ssl in $sslVersions) {
    $basePath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$ssl"
    New-Item -Path "$basePath\Server" -Force | Out-Null
    New-ItemProperty -Path "$basePath\Server" -Name "Enabled" -Value 0 -PropertyType "DWord" -Force | Out-Null
    New-ItemProperty -Path "$basePath\Server" -Name "DisabledByDefault" -Value 1 -PropertyType "DWord" -Force | Out-Null

    New-Item -Path "$basePath\Client" -Force | Out-Null
    New-ItemProperty -Path "$basePath\Client" -Name "Enabled" -Value 0 -PropertyType "DWord" -Force | Out-Null
    New-ItemProperty -Path "$basePath\Client" -Name "DisabledByDefault" -Value 1 -PropertyType "DWord" -Force | Out-Null
}

# Disable weak cipher suites
$cipherPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Ciphers"
$weakCiphers = @(
    "DES 56/56",
    "NULL",
    "RC2 40/128",
    "RC2 56/128",
    "RC2 128/128",
    "RC4 40/128",
    "RC4 56/128",
    "RC4 64/128",
    "RC4 128/128"
)
foreach ($cipher in $weakCiphers) {
    New-Item -Path "$cipherPath\$cipher" -Force | Out-Null
    New-ItemProperty -Path "$cipherPath\$cipher" -Name "Enabled" -Value 0 -PropertyType "DWord" -Force | Out-Null
}

# Require SMB2 signing to prevent man-in-the-middle attacks
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "RequireSecuritySignature" -Value 1
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" -Name "RequireSecuritySignature" -Value 1

# Completion message
Write-Host "✅ All security hardening settings have been applied. Please restart your system for changes to take full effect." -ForegroundColor Green