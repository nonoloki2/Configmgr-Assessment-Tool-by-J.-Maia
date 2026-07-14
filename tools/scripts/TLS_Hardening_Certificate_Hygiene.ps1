# Run as Administrator

Write-Host "🔐 Applying TLS/SSL hardening settings..." -ForegroundColor Cyan

# Disable SSLv2, SSLv3, TLS 1.0, TLS 1.1
$protocols = @("SSL 2.0", "SSL 3.0", "TLS 1.0", "TLS 1.1")
foreach ($protocol in $protocols) {
    foreach ($role in @("Client", "Server")) {
        $path = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$protocol\$role"
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -Path $path -Name "Enabled" -Value 0 -PropertyType "DWORD" -Force | Out-Null
        New-ItemProperty -Path $path -Name "DisabledByDefault" -Value 1 -PropertyType "DWORD" -Force | Out-Null
    }
}

# Enable TLS 1.2
foreach ($role in @("Client", "Server")) {
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\$role"
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -Path $path -Name "Enabled" -Value 1 -PropertyType "DWORD" -Force | Out-Null
    New-ItemProperty -Path $path -Name "DisabledByDefault" -Value 0 -PropertyType "DWORD" -Force | Out-Null
}

# Disable weak cipher suites
$cipherPaths = @(
    "RC4 128/128", "RC4 64/128", "RC4 56/128", "RC4 40/128",
    "DES 56/56", "Triple DES 168", "Triple DES 112",
    "MD5", "SHA", "SHA1", "NULL", "EXPORT"
)
foreach ($cipher in $cipherPaths) {
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Ciphers\$cipher"
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -Path $path -Name "Enabled" -Value 0 -PropertyType "DWORD" -Force | Out-Null
}

# Disable static key exchange algorithms
$keyExchanges = @("DH", "PKCS", "RSA", "DSS", "PSK")
foreach ($alg in $keyExchanges) {
    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\KeyExchangeAlgorithms\$alg"
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -Path $path -Name "Enabled" -Value 0 -PropertyType "DWORD" -Force | Out-Null
}

Write-Host "✅ TLS/SSL configuration hardened successfully." -ForegroundColor Green
Write-Host "📌 Restart the server to apply all changes." -ForegroundColor Yellow