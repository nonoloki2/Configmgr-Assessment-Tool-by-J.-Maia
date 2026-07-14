<# 
.SYNOPSIS
Remove a list of computers from an Active Directory group.

.DESCRIPTION
This script reads a list of computer accounts from a TXT file (one per line)
and removes them from the specified Active Directory group.
It requires the RSAT Active Directory module and appropriate permissions.

.PARAMETER GroupName
The name of the Active Directory group.

.PARAMETER ComputerListPath
The path to the TXT file containing the list of computer names.
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$GroupName,

    [Parameter(Mandatory=$true)]
    [string]$ComputerListPath
)

# Import the Active Directory module
Import-Module ActiveDirectory

# Validate if the TXT file exists
if (-Not (Test-Path $ComputerListPath)) {
    Write-Error "File not found: $ComputerListPath"
    exit
}

# Read the list of computers from the file, ignoring empty lines
$Computers = Get-Content $ComputerListPath | Where-Object {$_ -and $_.Trim() -ne ""}

Write-Host "Preparing to remove $($Computers.Count) computer(s) from group $GroupName..." -ForegroundColor Cyan

foreach ($Comp in $Computers) {
    $CompName = $Comp.Trim()

    try {
        # Attempt to remove the computer from the group
        Write-Host "Removing $CompName from group $GroupName..." -ForegroundColor Yellow
        Remove-ADGroupMember -Identity $GroupName -Members $CompName -Confirm:$false -ErrorAction Stop
        Write-Host "SUCCESS: $CompName removed from $GroupName." -ForegroundColor Green
    }
    catch {
        # If something fails, display the error message
        Write-Warning "FAILED: Could not remove $CompName. Reason: $($_.Exception.Message)"
    }
}

Write-Host "Process finished." -ForegroundColor Cyan
