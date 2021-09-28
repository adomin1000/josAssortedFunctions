<#
    .DESCRIPTION
    Local Admin Password Rotation and Account Management
    Set configuration values, and follow rollout instructions at https://www.lieben.nu/liebensraum/?p=3605

    Not testing in hybrid scenario's. Should work, but may conflict with e.g. specific password policies.
  
    .NOTES
    filename:       leanLAPS.ps1
    author:         Jos Lieben (Lieben Consultancy)
    created:        09/06/2021
    last updated:   23/09/2021
    Copyright:      https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author)
    inspired by:    Rudy Ooms; https://call4cloud.nl/2021/05/the-laps-reloaded/
#>

####CONFIG
$minimumPasswordLength = 21
$localAdminName = "LCAdmin"
$removeOtherLocalAdmins = $False #if set to True, will remove ALL other local admins, including those set through AzureAD device settings
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
    Exit 0
}else{
    #check if marker file present, which means we're in the 2nd detection run where nothing should happen except posting the new password to Intune
    if($markerFileExists){
        $pwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR((Get-Content $markerFile | ConvertTo-SecureString)))
        Remove-Item -Path $markerFile -Force -Confirm:$False
        Write-Host "LeanLAPS current password: $pwd for $($localAdminName), last changed on $(Get-Date)"
        #ensure the password is removed from Intune log files and registry (which are written after a delay):
        $triggers = @((New-ScheduledTaskTrigger -At (get-date).AddMinutes(5) -Once),(New-ScheduledTaskTrigger -At (get-date).AddMinutes(10) -Once),(New-ScheduledTaskTrigger -At (get-date).AddMinutes(30) -Once))
        $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ex bypass -EncodedCommand RgB1AG4AYwB0AGkAbwBuACAAVwByAGkAdABlAC0AQwB1AHMAdABvAG0ARQB2AGUAbgB0AEwAbwBnACgAJABNAGUAcwBzAGEAZwBlACkAewAKACAAIAAgACAAJABFAHYAZQBuAHQAUwBvAHUAcgBjAGUAPQAiAC4ATABpAGUAYgBlAG4AQwBvAG4AcwB1AGwAdABhAG4AYwB5ACIACgAgACAAIAAgAGkAZgAgACgAWwBTAHkAcwB0AGUAbQAuAEQAaQBhAGcAbgBvAHMAdABpAGMAcwAuAEUAdgBlAG4AdABMAG8AZwBdADoAOgBFAHgAaQBzAHQAcwAoACcAQQBwAHAAbABpAGMAYQB0AGkAbwBuACcAKQAgAC0AZQBxACAAJABGAGEAbABzAGUAIAAtAG8AcgAgAFsAUwB5AHMAdABlAG0ALgBEAGkAYQBnAG4AbwBzAHQAaQBjAHMALgBFAHYAZQBuAHQATABvAGcAXQA6ADoAUwBvAHUAcgBjAGUARQB4AGkAcwB0AHMAKAAkAEUAdgBlAG4AdABTAG8AdQByAGMAZQApACAALQBlAHEAIAAkAEYAYQBsAHMAZQApAHsACgAgACAAIAAgACAAIAAgACAAJAByAGUAcwAgAD0AIABOAGUAdwAtAEUAdgBlAG4AdABMAG8AZwAgAC0ATABvAGcATgBhAG0AZQAgAEEAcABwAGwAaQBjAGEAdABpAG8AbgAgAC0AUwBvAHUAcgBjAGUAIAAkAEUAdgBlAG4AdABTAG8AdQByAGMAZQAgACAAfAAgAE8AdQB0AC0ATgB1AGwAbAAKACAAIAAgACAAfQAKACAAIAAgACAAJAByAGUAcwAgAD0AIABXAHIAaQB0AGUALQBFAHYAZQBuAHQATABvAGcAIAAtAEwAbwBnAE4AYQBtAGUAIABBAHAAcABsAGkAYwBhAHQAaQBvAG4AIAAtAFMAbwB1AHIAYwBlACAAJABFAHYAZQBuAHQAUwBvAHUAcgBjAGUAIAAtAEUAbgB0AHIAeQBUAHkAcABlACAASQBuAGYAbwByAG0AYQB0AGkAbwBuACAALQBFAHYAZQBuAHQASQBkACAAMQA5ADgANQAgAC0ATQBlAHMAcwBhAGcAZQAgACQATQBlAHMAcwBhAGcAZQAKAH0ACgAKACMAdwBpAHAAZQAgAHAAYQBzAHMAdwBvAHIAZAAgAGYAcgBvAG0AIABsAG8AZwBmAGkAbABlAHMACgB0AHIAeQB7AAoAIAAgACAAIAAkAGkAbgB0AHUAbgBlAEwAbwBnADEAIAA9ACAASgBvAGkAbgAtAFAAYQB0AGgAIAAkAEUAbgB2ADoAUAByAG8AZwByAGEAbQBEAGEAdABhACAALQBjAGgAaQBsAGQAcABhAHQAaAAgACIATQBpAGMAcgBvAHMAbwBmAHQAXABJAG4AdAB1AG4AZQBNAGEAbgBhAGcAZQBtAGUAbgB0AEUAeAB0AGUAbgBzAGkAbwBuAFwATABvAGcAcwBcAEEAZwBlAG4AdABFAHgAZQBjAHUAdABvAHIALgBsAG8AZwAiAAoAIAAgACAAIAAkAGkAbgB0AHUAbgBlAEwAbwBnADIAIAA9ACAASgBvAGkAbgAtAFAAYQB0AGgAIAAkAEUAbgB2ADoAUAByAG8AZwByAGEAbQBEAGEAdABhACAALQBjAGgAaQBsAGQAcABhAHQAaAAgACIATQBpAGMAcgBvAHMAbwBmAHQAXABJAG4AdAB1AG4AZQBNAGEAbgBhAGcAZQBtAGUAbgB0AEUAeAB0AGUAbgBzAGkAbwBuAFwATABvAGcAcwBcAEkAbgB0AHUAbgBlAE0AYQBuAGEAZwBlAG0AZQBuAHQARQB4AHQAZQBuAHMAaQBvAG4ALgBsAG8AZwAiAAoAIAAgACAAIABTAGUAdAAtAEMAbwBuAHQAZQBuAHQAIAAtAEYAbwByAGMAZQAgAC0AQwBvAG4AZgBpAHIAbQA6ACQARgBhAGwAcwBlACAALQBQAGEAdABoACAAJABpAG4AdAB1AG4AZQBMAG8AZwAxACAALQBWAGEAbAB1AGUAIAAoAEcAZQB0AC0AQwBvAG4AdABlAG4AdAAgAC0AUABhAHQAaAAgACQAaQBuAHQAdQBuAGUATABvAGcAMQAgAHwAIABTAGUAbABlAGMAdAAtAFMAdAByAGkAbgBnACAALQBQAGEAdAB0AGUAcgBuACAAIgBQAGEAcwBzAHcAbwByAGQAIgAgAC0ATgBvAHQATQBhAHQAYwBoACkACgAgACAAIAAgAFMAZQB0AC0AQwBvAG4AdABlAG4AdAAgAC0ARgBvAHIAYwBlACAALQBDAG8AbgBmAGkAcgBtADoAJABGAGEAbABzAGUAIAAtAFAAYQB0AGgAIAAkAGkAbgB0AHUAbgBlAEwAbwBnADIAIAAtAFYAYQBsAHUAZQAgACgARwBlAHQALQBDAG8AbgB0AGUAbgB0ACAALQBQAGEAdABoACAAJABpAG4AdAB1AG4AZQBMAG8AZwAyACAAfAAgAFMAZQBsAGUAYwB0AC0AUwB0AHIAaQBuAGcAIAAtAFAAYQB0AHQAZQByAG4AIAAiAFAAYQBzAHMAdwBvAHIAZAAiACAALQBOAG8AdABNAGEAdABjAGgAKQAKAH0AYwBhAHQAYwBoAHsAJABOAHUAbABsAH0ACgAKACMAbwBuAGwAeQAgAHcAaQBwAGUAIAByAGUAZwBpAHMAdAByAHkAIABkAGEAdABhACAAYQBmAHQAZQByACAAZABhAHQAYQAgAGgAYQBzACAAYgBlAGUAbgAgAHMAZQBuAHQAIAB0AG8AIABNAHMAZgB0AAoAaQBmACgAKABHAGUAdAAtAEMAbwBuAHQAZQBuAHQAIAAtAFAAYQB0AGgAIAAkAGkAbgB0AHUAbgBlAEwAbwBnADIAIAB8ACAAUwBlAGwAZQBjAHQALQBTAHQAcgBpAG4AZwAgAC0AUABhAHQAdABlAHIAbgAgACIAUABvAGwAaQBjAHkAIAByAGUAcwB1AGwAdABzACAAYQByAGUAIABzAHUAYwBjAGUAcwBzAGYAdQBsAGwAeQAgAHMAZQBuAHQALgAiACkAKQB7AAoAIAAgACAAIABXAHIAaQB0AGUALQBDAHUAcwB0AG8AbQBFAHYAZQBuAHQATABvAGcAIAAiAEkAbgB0AHUAbgBlACAAbABvAGcAZgBpAGwAZQAgAGkAbgBkAGkAYwBhAHQAZQBzACAAcwBjAHIAaQBwAHQAIAByAGUAcwB1AGwAdABzACAAaABhAHYAZQAgAGIAZQBlAG4AIAByAGUAcABvAHIAdABlAGQAIAB0AG8AIABNAGkAYwByAG8AcwBvAGYAdAAiAAoAIAAgACAAIABTAGUAdAAtAEMAbwBuAHQAZQBuAHQAIAAtAEYAbwByAGMAZQAgAC0AQwBvAG4AZgBpAHIAbQA6ACQARgBhAGwAcwBlACAALQBQAGEAdABoACAAJABpAG4AdAB1AG4AZQBMAG8AZwAyACAALQBWAGEAbAB1AGUAIAAoAEcAZQB0AC0AQwBvAG4AdABlAG4AdAAgAC0AUABhAHQAaAAgACQAaQBuAHQAdQBuAGUATABvAGcAMgAgAHwAIABTAGUAbABlAGMAdAAtAFMAdAByAGkAbgBnACAALQBQAGEAdAB0AGUAcgBuACAAIgBQAG8AbABpAGMAeQAgAHIAZQBzAHUAbAB0AHMAIABhAHIAZQAgAHMAdQBjAGMAZQBzAHMAZgB1AGwAbAB5ACAAcwBlAG4AdAAuACIAIAAtAE4AbwB0AE0AYQB0AGMAaAApAAoAIAAgACAAIABTAHQAYQByAHQALQBTAGwAZQBlAHAAIAAtAHMAIAA5ADAACgAgACAAIAAgAHQAcgB5AHsACgAgACAAIAAgACAAIAAgACAAZgBvAHIAZQBhAGMAaAAoACQAVABlAG4AYQBuAHQAIABpAG4AIAAoAEcAZQB0AC0AQwBoAGkAbABkAEkAdABlAG0AIAAiAEgASwBMAE0AOgBcAFMAbwBmAHQAdwBhAHIAZQBcAE0AaQBjAHIAbwBzAG8AZgB0AFwASQBuAHQAdQBuAGUATQBhAG4AYQBnAGUAbQBlAG4AdABFAHgAdABlAG4AcwBpAG8AbgBcAFMAaQBkAGUAQwBhAHIAUABvAGwAaQBjAGkAZQBzAFwAUwBjAHIAaQBwAHQAcwBcAFIAZQBwAG8AcgB0AHMAIgApACkAewAKACAAIAAgACAAIAAgACAAIAAgACAAIAAgAGYAbwByAGUAYQBjAGgAKAAkAHMAYwByAGkAcAB0ACAAaQBuACAAKABHAGUAdAAtAEMAaABpAGwAZABJAHQAZQBtACAAJABUAGUAbgBhAG4AdAAuAFAAUwBQAGEAdABoACkAKQB7AAoAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAkAGoAcwBvAG4AIAA9ACAAKAAoAEcAZQB0AC0ASQB0AGUAbQBQAHIAbwBwAGUAcgB0AHkAIAAtAFAAYQB0AGgAIAAoAEoAbwBpAG4ALQBQAGEAdABoACAAJABzAGMAcgBpAHAAdAAuAFAAUwBQAGEAdABoACAALQBDAGgAaQBsAGQAUABhAHQAaAAgACIAUgBlAHMAdQBsAHQAIgApACAALQBOAGEAbQBlACAAIgBSAGUAcwB1AGwAdAAiACkALgBSAGUAcwB1AGwAdAAgAHwAIABjAG8AbgB2AGUAcgB0AGYAcgBvAG0ALQBqAHMAbwBuACkACgAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAGkAZgAoACQAagBzAG8AbgAuAFAAbwBzAHQAUgBlAG0AZQBkAGkAYQB0AGkAbwBuAEQAZQB0AGUAYwB0AFMAYwByAGkAcAB0AE8AdQB0AHAAdQB0AC4AUwB0AGEAcgB0AHMAVwBpAHQAaAAoACIATABlAGEAbgBMAEEAUABTACIAKQApAHsACgAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAJABqAHMAbwBuAC4AUABvAHMAdABSAGUAbQBlAGQAaQBhAHQAaQBvAG4ARABlAHQAZQBjAHQAUwBjAHIAaQBwAHQATwB1AHQAcAB1AHQAIAA9ACAAIgBSAEUARABBAEMAVABFAEQAIgAKACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIABTAGUAdAAtAEkAdABlAG0AUAByAG8AcABlAHIAdAB5ACAALQBQAGEAdABoACAAKABKAG8AaQBuAC0AUABhAHQAaAAgACQAcwBjAHIAaQBwAHQALgBQAFMAUABhAHQAaAAgAC0AQwBoAGkAbABkAFAAYQB0AGgAIAAiAFIAZQBzAHUAbAB0ACIAKQAgAC0ATgBhAG0AZQAgACIAUgBlAHMAdQBsAHQAIgAgAC0AVgBhAGwAdQBlACAAKAAkAGoAcwBvAG4AIAB8ACAAQwBvAG4AdgBlAHIAdABUAG8ALQBKAHMAbwBuACAALQBEAGUAcAB0AGgAIAAxADAAIAAtAEMAbwBtAHAAcgBlAHMAcwApACAALQBGAG8AcgBjAGUAIAAtAEMAbwBuAGYAaQByAG0AOgAkAEYAYQBsAHMAZQAKACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIABXAHIAaQB0AGUALQBDAHUAcwB0AG8AbQBFAHYAZQBuAHQATABvAGcAIAAiAHIAZQBkAGEAYwB0AGUAZAAgAGEAbABsACAAbABvAGMAYQBsACAAZABhAHQAYQAiAAoAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAB9AAoAIAAgACAAIAAgACAAIAAgACAAIAAgACAAfQAKACAAIAAgACAAIAAgACAAIAB9AAoAIAAgACAAIAB9AGMAYQB0AGMAaAB7ACQATgB1AGwAbAB9AAoAfQA=" #base64 UTF16-LE encoded command https://www.base64encode.org/
        $Null = Register-ScheduledTask -TaskName "leanLAPS_WL" -Trigger $triggers -User "SYSTEM" -Action $Action -Force
        Exit 0
    }
}

try{
    $localAdmin = $Null
    $localAdmin = Get-LocalUser -name $localAdminName -ErrorAction Stop
    if(!$localAdmin){Throw}
}catch{
    Write-CustomEventLog "$localAdminName doesn't exist yet, creating..."
    try{
        $newPwd = Get-NewPassword $minimumPasswordLength
        $pwdSet = $True
        $localAdmin = New-LocalUser -PasswordNeverExpires -AccountNeverExpires -Name $localAdminName -Password ($newPwd | ConvertTo-SecureString -AsPlainText -Force)
        Write-CustomEventLog "$localAdminName created"
    }catch{
        Write-CustomEventLog "Something went wrong while provisioning $localAdminName $($_)"
        Write-Host "Something went wrong while provisioning $localAdminName $($_)"
        Exit 0
    }
}

try{
    $administratorsGroupName = (New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")).Translate([System.Security.Principal.NTAccount]).Value.Split("\")[1]
    Write-CustomEventLog "local administrators group is called $administratorsGroupName"
    $group = [ADSI]::new("WinNT://$($env:COMPUTERNAME)/$($administratorsGroupName),Group")
    $administrators = $group.Invoke('Members') | % {([ADSI]$_).Path.Split("/")[-1]}

    Write-CustomEventLog "There are $($administrators.count) readable accounts in $administratorsGroupName"

    if(!$administrators -or $administrators -notcontains $localAdminName){
        Write-CustomEventLog "$localAdminName is not a local administrator, adding..."
        $res = Add-LocalGroupMember -Group $administratorsGroupName -Member $localAdminName -Confirm:$False -ErrorAction Stop
        Write-CustomEventLog "Added $localAdminName to the local administrators group"
    }
    #remove other local admins if specified, only executes if adding the new local admin succeeded
    if($removeOtherLocalAdmins){
        foreach($administrator in $administrators){
            if($administrator -ne $localAdminName){
                Write-CustomEventLog "removeOtherLocalAdmins set to True, removing $($administrator) from Local Administrators"
                $res = Remove-LocalGroupMember -Group $administratorsGroupName -Member $administrator -Confirm:$False
                Write-CustomEventLog "Removed $administrator from Local Administrators"
            }
        }
    }else{
        Write-CustomEventLog "removeOtherLocalAdmins set to False, not removing any administrator permissions"
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
        $res = $localAdmin | Set-LocalUser -Password ($newPwd | ConvertTo-SecureString -AsPlainText -Force) -Confirm:$False -AccountNeverExpires -PasswordNeverExpires $True -UserMayChangePassword $True
        Write-CustomEventLog "Password for $localAdminName set to a new value, see MDE"
    }catch{
        Write-CustomEventLog "Failed to set new password for $localAdminName"
        Write-Host "Failed to set password for $localAdminName because of $($_)"
        Exit 0
    }
}

Write-Host "LeanLAPS ran successfully for $($localAdminName)"
$res = Set-Content -Path $markerFile -Value (ConvertFrom-SecureString (ConvertTo-SecureString $newPwd -asplaintext -force)) -Force -Confirm:$False
Exit 1