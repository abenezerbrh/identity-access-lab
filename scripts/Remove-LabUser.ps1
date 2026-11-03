<#
.SYNOPSIS
  Offboards a user: disable, strip groups, record what they had, move to Disabled Users.
.EXAMPLE
  .\Remove-LabUser.ps1 -Username treyes -Ticket LAB-205 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Username,
    [Parameter(Mandatory)][string]$Ticket,
    [string]$LogPath = "C:\Lab\Logs\offboarding.log"
)

Import-Module ActiveDirectory
$disabledOU = "OU=Disabled Users,DC=lab,DC=local"

function Write-Log([string]$Message) {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Ticket, $Message
    Add-Content -Path $LogPath -Value $line -WhatIf:$false
    Write-Host $line
}

New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force -WhatIf:$false | Out-Null

try {
    $user = Get-ADUser -Identity $Username -Properties MemberOf -ErrorAction Stop
}
catch {
    Write-Log "FAILED: user $Username not found"
    exit 1
}

# Record group names first, so the account could be restored if this was a mistake
$groupNames = $user.MemberOf | ForEach-Object { (Get-ADGroup $_).Name }
Write-Log "START $Username. Groups before: $($groupNames -join ', ')"

if ($PSCmdlet.ShouldProcess($Username, "Disable, scramble password, remove groups, move to Disabled Users")) {
    Disable-ADAccount -Identity $user

    $scramble = -join ((33..126) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    Set-ADAccountPassword -Identity $user -Reset -NewPassword (ConvertTo-SecureString $scramble -AsPlainText -Force)

    foreach ($g in $user.MemberOf) {
        Remove-ADGroupMember -Identity $g -Members $user -Confirm:$false
    }

    Set-ADUser -Identity $user -Description ("Disabled {0} | {1} | was in: {2}" -f (Get-Date -Format yyyy-MM-dd), $Ticket, ($groupNames -join ','))

    # Move last, because the account's location (DN) changes when it moves
    Move-ADObject -Identity $user.DistinguishedName -TargetPath $disabledOU

    Write-Log "DONE $Username disabled, $($groupNames.Count) group(s) removed, moved to Disabled Users"
}