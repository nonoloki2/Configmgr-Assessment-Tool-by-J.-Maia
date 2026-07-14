# ============================
# SMBv2: Require digital signing
# ============================
Write-Host "Applying SMBv2 security settings..."
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name RequireSecuritySignature -Value 1
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" -Name RequireSecuritySignature -Value 1

# ============================
# TLS/SSL: Disable TLS 1.0 and 1.1
# ============================
Write-Host "Disabling TLS 1.0 and TLS 1.1..."
$protocols = @("TLS 1.0", "TLS 1.1")
foreach ($protocol in $protocols) {
    $basePath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$protocol"
    
    # Disable for Server
    New-Item -Path "$basePath\Server" -Force | Out-Null
    New-ItemProperty -Path "$basePath\Server" -Name "Enabled" -Value 0 -PropertyType "DWORD" -Force
    New-ItemProperty -Path "$basePath\Server" -Name "DisabledByDefault" -Value 1 -PropertyType "DWORD" -Force

    # Disable for Client
    New-Item -Path "$basePath\Client" -Force | Out-Null
    New-ItemProperty -Path "$basePath\Client" -Name "Enabled" -Value 0 -PropertyType "DWORD" -Force
    New-ItemProperty -Path "$basePath\Client" -Name "DisabledByDefault" -Value 1 -PropertyType "DWORD" -Force
}

# ============================
# TLS/SSL: Enforce strong cryptography
# ============================
Write-Host "Enforcing strong cryptography for .NET Framework..."
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319" -Name "SchUseStrongCrypto" -Value 1 -Type DWord
Set-ItemProperty -Path "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319" -Name "SchUseStrongCrypto" -Value 1 -Type DWord
