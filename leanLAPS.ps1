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
$minimumPasswordLength = 21
$localAdminName = "LCAdmin"
$removeOtherLocalAdmins = $False
$onlyRunOnWindows10 = $True #buildin protection in case an admin accidentally assigns this script to e.g. a domain controller
$markerFile = Join-Path $Env:TEMP -ChildPath "leanLAPS.marker"
$markerFileExists = (Test-Path $markerFile)

function Get-NewPassword($passwordLength){
   -join ('abcdefghkmnrstuvwxyzABCDEFGHKLMNPRSTUVWXYZ23456789'.ToCharArray() | Get-Random -Count $passwordLength)
}

Function Write-CustomEventLog($Message){
    $EventSource=".LiebenConsultancy"
    if ([System.Diagnostics.EventLog]::Exists('Application') -eq $False -or [System.Diagnostics.EventLog]::SourceExists($EventSource) -eq $False){
        $res = New-EventLog -LogName Application -Source $EventSource  | Out-Null
    }
    $res = Write-EventLog -LogName Application -Source $EventSource -EntryType Information -EventId 1985 -Message $Message
}

Write-CustomEventLog "LeanLAPS starting on $($ENV:COMPUTERNAME) as $($MyInvocation.MyCommand.Name)"

if($onlyRunOnWindows10 -and [Environment]::OSVersion.Version.Major -ne 10){
    Write-CustomEventLog "Unsupported OS!"
    Write-Error "Unsupported OS!"
    Exit 0
}

$mode = $MyInvocation.MyCommand.Name.Split(".")[0]
$pwdSet = $false

#when in remediation mode, always exit successfully as we remediated during the detection phase
if($mode -ne "detect"){
    #$intuneLog1 = Join-Path $Env:ProgramData -childpath "Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log"
    #$intuneLog2 = Join-Path $Env:ProgramData -childpath "Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
    Exit 0
}else{
    #check if marker file present, which means we're in the 2nd detection run where nothing should happen
    if($markerFileExists){
        Remove-Item -Path $markerFile -Force -Confirm:$False
        Write-Host "Status: Actual"
        Exit 0
    }
}

try{
    $localAdmin = Get-LocalUser -name $localAdminName -ErrorAction Stop
}catch{
    Write-CustomEventLog "$localAdminName doesn't exist yet, creating..."
    $newPwd = Get-NewPassword $minimumPasswordLength
    $pwdSet = $True
    $localAdmin = New-LocalUser -PasswordNeverExpires -AccountNeverExpires $True -Name $localAdminName -Password ($newPwd | ConvertTo-SecureString -AsPlainText -Force)
    Write-CustomEventLog "$localAdminName created"
}

try{
    $administratorsGroupName = (New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")).Translate([System.Security.Principal.NTAccount]).Value.Split("\")[1]
    $group = gwmi win32_group -filter "Name = `"$($administratorsGroupName)`""
    $administrators = $group.GetRelated('Win32_UserAccount')

    if($administrators.SID -notcontains $($localAdmin.SID.Value)){
        Write-CustomEventLog "$localAdminName is not a local administrator, adding..."
        $res = Add-LocalGroupMember -Group (Get-LocalGroup -SID S-1-5-32-544) -Member $localAdmin -Confirm:$False -ErrorAction Stop
        Write-CustomEventLog "Added $localAdminName to the local administrators group"
    }
    #remove other local admins if specified, only executes if adding the new local admin succeeded
    if($removeOtherLocalAdmins){
        foreach($administrator in $administrators){
            if($administrator.SID -ne $localAdmin.SID.Value){
                Write-CustomEventLog "removeOtherLocalAdmins set to True, removing $($administrator.Name) from Local Administrators"
                $res = Remove-LocalGroupMember -Group (Get-LocalGroup -SID S-1-5-32-544) -Member $administrator -Confirm:$False
                Write-CustomEventLog "Removed $($administrator.Name) from Local Administrators"
            }
        }
    }
}catch{
    Write-CustomEventLog "Something went wrong while processing the local administrators group $($_)"
    Write-Host "Something went wrong while processing the local administrators group $($_)"
    Exit 0
}

if(!$pwdSet){
    try{
        Write-CustomEventLog "Setting password for $localAdminName ..."
        $newPwd = Get-NewPassword $minimumPasswordLength
        $pwdSet = $True
        $res = $localAdmin | Set-LocalUser -Password ($newPwd | ConvertTo-SecureString -AsPlainText -Force) -Confirm:$False
        Write-CustomEventLog "Password for $localAdminName set to a new value, see MDE"
    }catch{
        Write-CustomEventLog "Failed to set new password for $localAdminName"
        Write-Host "Failed to set password for $localAdminName because of $($_)"
        Exit 0
    }
}

Write-Host "LeanLAPS set password to $newPwd for $($localAdminName)"
Set-Content -Path $markerFile -Value 1 -Force -Confirm:$False
Exit 1