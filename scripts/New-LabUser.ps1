<#
.SYNOPSIS
  Onboards new hires from a CSV into lab.local.
.EXAMPLE
  .\New-LabUser.ps1 -CsvPath C:\Lab\newhires.csv -Ticket LAB-101 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [Parameter(Mandatory)][string]$Ticket,
    [string]$LogPath = "C:\Lab\Logs\onboarding.log"
)

Import-Module ActiveDirectory
$base       = "DC=lab,DC=local"
$validDepts = "Finance","Engineering","Audit"

function Write-Log([string]$Message) {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Ticket, $Message
    Add-Content -Path $LogPath -Value $line -WhatIf:$false
    Write-Host $line
}

function New-TempPassword {
    # One of each character type guarantees the domain complexity rule is met
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; $lower = 'abcdefghijkmnpqrstuvwxyz'
    $digit = '23456789'; $symbol = '!@#$%*'
    $all = $upper + $lower + $digit + $symbol
    $chars = @(
        $upper[(Get-Random -Maximum $upper.Length)]
        $lower[(Get-Random -Maximum $lower.Length)]
        $digit[(Get-Random -Maximum $digit.Length)]
        $symbol[(Get-Random -Maximum $symbol.Length)]
    ) + (1..10 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] })
    -join ($chars | Sort-Object { Get-Random })
}

New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force -WhatIf:$false | Out-Null

foreach ($h in Import-Csv $CsvPath) {
    $fullName = "$($h.FirstName) $($h.LastName)"

    if ($h.Department -notin $validDepts) {
        Write-Log "SKIPPED ${fullName}: unknown department '$($h.Department)'"
        continue
    }

    # Don't create a second account for someone who already has one
    $existing = Get-ADUser -Filter "GivenName -eq '$($h.FirstName)' -and Surname -eq '$($h.LastName)'" -Properties Department |
                Where-Object Department -eq $h.Department
    if ($existing) {
        Write-Log "SKIPPED ${fullName}: already exists as $($existing.SamAccountName)"
        continue
    }

    # Username = first initial + last name, with a number if it's taken
    $baseSam = (($h.FirstName.Substring(0,1) + $h.LastName).ToLower()) -replace '[^a-z0-9]', ''
    $sam = $baseSam; $n = 1
    while (Get-ADUser -Filter "SamAccountName -eq '$sam'") { $n++; $sam = "$baseSam$n" }

    $ou    = "OU=$($h.Department),OU=Staff,$base"
    $group = "GG_$($h.Department)"
    $temp  = New-TempPassword

    if ($PSCmdlet.ShouldProcess($sam, "Create in $ou and add to $group")) {
        try {
            New-ADUser -Name $fullName -GivenName $h.FirstName -Surname $h.LastName `
                -SamAccountName $sam -UserPrincipalName "$sam@lab.local" `
                -Title $h.Title -Department $h.Department -Path $ou `
                -AccountPassword (ConvertTo-SecureString $temp -AsPlainText -Force) `
                -ChangePasswordAtLogon $true -Enabled $true `
                -Description "Onboarded $(Get-Date -Format yyyy-MM-dd) | $Ticket" -ErrorAction Stop
            Add-ADGroupMember -Identity $group -Members $sam -ErrorAction Stop
            Write-Log "CREATED $sam in $ou, added to $group"
            Write-Host "  Temp password for ${sam}: $temp" -ForegroundColor Yellow
        }
        catch {
            Write-Log "FAILED ${sam}: $($_.Exception.Message)"
        }
    }
}