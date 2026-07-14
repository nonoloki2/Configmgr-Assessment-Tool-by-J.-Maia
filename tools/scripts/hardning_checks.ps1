# Function to check registry value and return status
function Check-RegistrySetting {
    param (
        [string]$Path,
        [string]$Name,
        [int]$ExpectedValue
    )
    if (Test-Path $Path) {
        $actual = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($actual -eq $ExpectedValue) {
            Write-Host "✔ [$Name] at [$Path] is correctly set to $ExpectedValue" -ForegroundColor Green
        } else {
            Write-Host "⚠ [$Name] at [$Path] is set to $actual (expected $ExpectedValue)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "❌ Registry path not found: $Path" -ForegroundColor Red
    }
}

# TLS 1.1 disabled
Check-RegistrySetting -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Server" -Name "Enabled" -ExpectedValue 0
Check-RegistrySetting -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Client" -Name "Enabled" -ExpectedValue 0

# 3DES disabled
Check-RegistrySetting -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Ciphers\Triple DES 168" -Name "Enabled" -ExpectedValue 0

# DES disabled
Check-RegistrySetting -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Ciphers\DES 56/56" -Name "Enabled" -ExpectedValue 0

# MD5 hash disabled
Check-RegistrySetting -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Hash\MD5" -Name "Enabled" -ExpectedValue 0

# SMBv2 signing enforced
Check-RegistrySetting -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" -Name "RequireSecuritySignature" -ExpectedValue 1
Check-RegistrySetting -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "RequireSecuritySignature" -ExpectedValue 1