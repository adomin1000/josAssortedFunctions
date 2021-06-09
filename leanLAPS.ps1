<#
    .DESCRIPTION
    Local Admin Password Rotation and Account Management
    Set configuration values, and follow rollout instructions at https://www.lieben.nu/liebensraum/?p=3605
  
    .NOTES
    filename:       leanLAPS.ps1
    author:         Jos Lieben (Lieben Consultancy)
    created:        09/06/2021
    last updated:   09/06/2021
    copyright:      2021, Jos Lieben, Lieben Consultancy, not for commercial use without written consent
    inspired by:    Rudy Ooms; https://call4cloud.nl/2021/05/the-laps-reloaded/
#>

####CONFIG
$maxDaysBetweenResets = 7
$minimumPasswordLength = 21
$localAdminName = "LCAdmin"
$removeOtherLocalAdmins = $False
$onlyRunOnWindows10 = $True #buildin protection in case an admin accidentally assigns this script to e.g. a domain controller

function Get-NewPassword($passwordLength){
   -join ('abcdefghkmnrstuvwxyzABCDEFGHKLMNPRSTUVWXYZ23456789!{}@%'.ToCharArray() | Get-Random -Count $passwordLength)
}

Function Write-Log($Message){
    $EventSource=".LiebenConsultancy"
    if ([System.Diagnostics.EventLog]::Exists('Application') -eq $False -or [System.Diagnostics.EventLog]::SourceExists($EventSource) -eq $False){
        New-EventLog -LogName Application -Source $EventSource  | Out-Null
    }
    Write-EventLog -LogName Application -Source $EventSource -EntryType Information -EventId 1985 -Message $Message
}

Write-Log "LeanLAPS starting on $($ENV:COMPUTERNAME) as $($MyInvocation.MyCommand.Name)"

if($onlyRunOnWindows10 -and [Environment]::OSVersion.Version.Major -ne 10){
    Write-Log "Unsupported OS!"
    Write-Error "Unsupported OS!"
    Exit 0
}

$mode = $MyInvocation.MyCommand.Name.Split(".")[0]
$newPwd = $Null

try{
    $localAdmin = Get-LocalUser -name $localAdminName -ErrorAction Stop
}catch{
    if($mode -eq "detect"){
        Write-Log "$localAdminName doesn't exist yet, restarting in remediate mode"
        Exit 1
    }
    Write-Log "$localAdminName doesn't exist yet, creating..."
    $newPwd = Get-NewPassword $minimumPasswordLength
    $localAdmin = New-LocalUser -AccountNeverExpires -Name $localAdminName -Password ($newPwd | ConvertTo-SecureString -AsPlainText -Force)
    Write-Log "$localAdminName created"
}

try{
    $administratorsGroupName = (New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")).Translate([System.Security.Principal.NTAccount]).Value.Split("\")[1]
    $group = gwmi win32_group -filter "Name = `"$($administratorsGroupName)`""
    $administrators = $group.GetRelated('Win32_UserAccount')

    if($administrators.SID -notcontains $($localAdmin.SID.Value)){
        Write-Log "$localAdminName is not a local administrator, adding..."
        Add-LocalGroupMember -Group (Get-LocalGroup -SID S-1-5-32-544) -Member $localAdmin -Confirm:$False -ErrorAction Stop
        Write-Log "Added $localAdminName to the local administrators group"
    }
    #remove other local admins if specified, only executes if adding the new local admin succeeded
    if($removeOtherLocalAdmins){
        foreach($administrator in $administrators){
            if($administrator.SID -ne $localAdmin.SID.Value){
                Write-Log "removeOtherLocalAdmins set to True, removing $($administrator.Name) from Local Administrators"
                Remove-LocalGroupMember -Group (Get-LocalGroup -SID S-1-5-32-544) -Member $administrator -Confirm:$False
                Write-Log "Removed $($administrator.Name) from Local Administrators"
            }
        }
    }
}catch{
    Write-Log "Something went wrong while processing the local administrators group $($_)"
    Write-Error "Something went wrong while processing the local administrators group $($_)"
    Exit 0
}

if($newPwd){ #newly created admin
    Write-Log "Password for $localAdminName set to a new value, see MDE"
    Write-Host "Password set to $newPwd for $localAdminName"
    Exit 0
}

if((New-TimeSpan -Start $localAdmin.PasswordLastSet -End (Get-Date)).TotalDays -gt $maxDaysBetweenResets){
    if($mode -eq "detect"){
        Write-Log "restarting in remediate mode"
        Exit 1
    }
    try{
        Write-Log "Setting password for $localAdminName ..."
        $newPwd = Get-NewPassword $minimumPasswordLength
        $localAdmin | Set-LocalUser -Password $newPwd -Confirm:$False
        Write-Log "Password for $localAdminName set to a new value, see MDE"
        Write-Host "Password set to $newPwd for $localAdminName"
        Exit 0
    }catch{
        Write-Log "Failed to set new password for $localAdminName"
        Write-Error "Failed to set password for $localAdminName because of $($_)"
        Exit 1
    }
}

Write-Log "No remediation needed, LeanLAPS will exit"
Exit 0