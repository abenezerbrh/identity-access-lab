<#
.SYNOPSIS
  Builds the lab.local OU structure, RBAC groups, Finance share, and helpdesk delegation.
.NOTES
  Run on DC01 as a domain admin. Safe to re-run: anything that already exists is skipped.
#>
Import-Module ActiveDirectory
$base = "DC=lab,DC=local"

function New-OUIfMissing([string]$Name, [string]$Path) {
    $dn = "OU=$Name,$Path"
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'") { Write-Host "Exists:  $dn" }
    else { New-ADOrganizationalUnit -Name $Name -Path $Path; Write-Host "Created: $dn" }
}

function New-GroupIfMissing([string]$Name, [string]$Scope, [string]$Path) {
    if (Get-ADGroup -Filter "Name -eq '$Name'") { Write-Host "Exists:  $Name" }
    else { New-ADGroup -Name $Name -GroupScope $Scope -GroupCategory Security -Path $Path; Write-Host "Created: $Name" }
}

# --- 1. OU structure ---
New-OUIfMissing "Staff" $base
"Finance","Engineering","Audit" | ForEach-Object { New-OUIfMissing $_ "OU=Staff,$base" }
"Disabled Users","Admin Accounts","Workstations","Groups" | ForEach-Object { New-OUIfMissing $_ $base }
"Roles","Resources" | ForEach-Object { New-OUIfMissing $_ "OU=Groups,$base" }

# --- 2. Role groups (who people are) and resource groups (what they can access) ---
$roles = "OU=Roles,OU=Groups,$base"
$res   = "OU=Resources,OU=Groups,$base"
"GG_Finance","GG_Engineering","GG_Audit","GG_HelpDesk" | ForEach-Object { New-GroupIfMissing $_ Global $roles }
New-GroupIfMissing "DL_FinanceShare_Modify" DomainLocal $res
New-GroupIfMissing "DL_FinanceShare_Read"   DomainLocal $res

# AGDLP nesting: Finance can edit, Audit can read, Engineering gets nothing
Add-ADGroupMember -Identity DL_FinanceShare_Modify -Members GG_Finance
Add-ADGroupMember -Identity DL_FinanceShare_Read   -Members GG_Audit

# --- 3. Finance share: broad share permissions, strict NTFS permissions ---
New-Item -Path C:\Shares\Finance -ItemType Directory -Force | Out-Null
if (-not (Get-SmbShare -Name Finance -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name Finance -Path C:\Shares\Finance `
        -FullAccess "LAB\Domain Admins" -ChangeAccess "NT AUTHORITY\Authenticated Users" | Out-Null
    Write-Host "Created: Finance share"
} else { Write-Host "Exists:  Finance share" }

icacls C:\Shares\Finance /inheritance:r | Out-Null
icacls C:\Shares\Finance /grant:r "LAB\Domain Admins:(OI)(CI)F" "SYSTEM:(OI)(CI)F" `
    "LAB\DL_FinanceShare_Modify:(OI)(CI)M" "LAB\DL_FinanceShare_Read:(OI)(CI)RX" | Out-Null

# --- 4. Helpdesk test account ---
if (-not (Get-ADUser -Filter "SamAccountName -eq 'hd.test'")) {
    New-ADUser -Name "Help Desk Test" -SamAccountName hd.test -UserPrincipalName "hd.test@lab.local" `
        -Path "OU=Admin Accounts,$base" -Enabled $true `
        -AccountPassword (Read-Host -AsSecureString "Password for hd.test")
    Write-Host "Created: hd.test"
} else { Write-Host "Exists:  hd.test" }
Add-ADGroupMember -Identity GG_HelpDesk -Members hd.test

# --- 5. Delegate password resets and unlocks on Staff to the helpdesk ---
# Same result as the Delegate Control wizard, plus the unlock right
$staff = "OU=Staff,$base"
dsacls $staff /I:S /G "LAB\GG_HelpDesk:CA;Reset Password;user" | Out-Null
dsacls $staff /I:S /G "LAB\GG_HelpDesk:RPWP;pwdLastSet;user"    | Out-Null
dsacls $staff /I:S /G "LAB\GG_HelpDesk:RPWP;lockoutTime;user"   | Out-Null

# --- Summary ---
Write-Host "`nFinance share permissions:"
icacls C:\Shares\Finance
Write-Host "Group nesting:"
Get-ADGroupMember DL_FinanceShare_Modify | ForEach-Object { "  DL_FinanceShare_Modify <- $($_.Name)" }
Get-ADGroupMember DL_FinanceShare_Read   | ForEach-Object { "  DL_FinanceShare_Read   <- $($_.Name)" }