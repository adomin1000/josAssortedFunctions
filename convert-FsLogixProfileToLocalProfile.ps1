﻿#Module name:       convert-FsLogixProfileToLocalProfile.ps1
#Author:            Jos Lieben
#Author Blog:       https://www.lieben.nu
#Created:           30-11-2021
#Updated:           see Git
#Copyright/License: https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)
#Purpose:           Convert a user profile on a given FSLogix share to a local profile on the device and prevent FSLogix from using the remote profile on that device going forward
#Requirements:      Run on user's AVD. User should NOT be logged in anywhere (or profile won't be mountable). AVD should be domain joined
#How to use:        Run as admin on the user's VM, or run using Run Command (make sure the user's computer account has sufficient permissions on the share in this case)

$user = "samaccountname of user" #e.g. jflieben
$FlipFlopProfileDirectoryName = $True #set to $True if the share has SAMACCOUNT_SID format, otherwise set to $False. See https://docs.microsoft.com/en-us/fslogix/profile-container-configuration-reference#flipflopprofiledirectoryname
$filesharePath = "\\accountname.file.core.windows.net\user-profiles"
$userName = "AZURE\accountname" #use AZURE\StorageAccountName when mapping an Azure File Share. Use UPN for other share types
$password = "StorageAccountKey" #https://docs.microsoft.com/en-us/azure/storage/common/storage-account-keys-manage?tabs=azure-portal#view-account-access-keys
$domainNetbiosName = "EMEA"

try{
    Write-Output "Mounting profile share"
    $LASTEXITCODE = 0 
    $out = NET USE $filesharePath /USER:$($userName) $($password) /PERSISTENT:YES 2>&1
    if($LASTEXITCODE -ne 0){
        Throw "Failed to mount share because of $out"
    }
    Write-Output "Mounted $filesharePath succesfully"
}catch{
    Write-Output $_
    Exit 1
}    

try{
    Write-Output "Detecting profile path for $user"
    if($FlipFlopProfileDirectoryName){
        $profileRemotePath = (Get-ChildItem $filesharePath | where{$_.Name.StartsWith($user)}).FullName
    }else{
        $profileRemotePath = (Get-ChildItem $filesharePath | where{$_.Name.EndsWith($user)}).FullName
    }
    $profileRemotePath = (Get-ChildItem $profileRemotePath | where{$_.Name.StartsWith("Profile")}).FullName
    if(!(Test-Path $profileRemotePath)){
        Throw "Failed to find a profile directory for $user in $filesharePath"
    }
    Write-Output "profile path $profileRemotePath detected"
}catch{
    Write-Output $_
    Exit 1
}

if($profileRemotePath.Count -gt 1){
    Write-Output "Multiple profile containers found for $user, please remove old ones first"
    Exit 1
}

try{
    Write-Output "Mounting profile disk of $user"
    $profileMountResult = Mount-DiskImage -ImagePath $profileRemotePath -StorageType VHD -Access ReadWrite
    $vol = Get-CimInstance -ClassName Win32_Volume | Where{$_.Label -and $_.Label.StartsWith("Profile")}
    if(!$vol.DriveLetter -eq "G:"){
        $vol | Set-CimInstance -Property @{DriveLetter = "G:"}
    }
    $profileSourcePath = Join-Path "G:" -ChildPath "Profile"
    if(!(Test-Path $profileSourcePath)){
        Throw "Could not access $profileSourcePath after mounting the profile disk"
    }
}catch{
    Write-Output $_
    Exit 1
}

try{
    Write-Output "Setting ACL's on profile before copying content..."
    takeown /f $profileSourcePath | Out-Null
    icacls $profileSourcePath /grant SYSTEM:`(OI`)`(CI`)F /c /q | Out-Null
}catch{
    Write-Output $_
    Exit 1
}

try{
    Write-Output "ACL's configured. Checking for FSLogix regfile to import"
    $profileRegDataFilePath = (Join-Path $profileSourcePath -ChildPath "AppData\Local\FSLogix\ProfileData.reg")
    $profileRegData = Get-Content -Path $profileRegDataFilePath
    $profileTargetPath = $profileRegData | % {if($_.StartsWith("`"ProfileImagePath")){$_.SubString(19).Replace('"','').Replace('\\','\')}}
    if(!(Test-Path $profileTargetPath)){
        Throw "Could not parse target path from regfile, or regfile does not exist!"
    }
    Write-Output "Determined profile target path: $profileTargetPath"
}catch{
    $profileTargetPath = Join-Path "c:\users\" -ChildPath $user
    if($FlipFlopProfileDirectoryName){
        $SID = $profileRemotePath.Split('\')[-2].Split("_")[1]
    }else{
        $SID = $profileRemotePath.Split('\')[-2].Split("_")[0]
    }
    ([string]$SID).ToCharArray() | % { $sidToHex += ("{0:x} " -f [int]$_) } 
	
"Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$SID]
`"ProfileImagePath`"=`"$($profileTargetPath.Replace('\','\\'))`"
`"Guid`"=`"{$([guid]::New(([adsisearcher]"SamAccountName=$user").FindOne().Properties.objectguid[0]).Guid)}`"
`"Flags`"=dword:00000000
`"FullProfile`"=dword:00000001
`"Sid`"=hex:$($sidToHex.replace(" ",",").TrimEnd(','))
`"State`"=dword:00000000
`"LocalProfileLoadTimeLow`"=dword:409f513d
`"LocalProfileLoadTimeHigh`"=dword:01d7e5b8
`"ProfileAttemptedProfileDownloadTimeLow`"=dword:00000000
`"ProfileAttemptedProfileDownloadTimeHigh`"=dword:00000000
`"ProfileLoadTimeLow`"=dword:00000000
`"ProfileLoadTimeHigh`"=dword:00000000
`"RunLogonScriptSync`"=dword:00000000
`"LocalProfileUnloadTimeLow`"=dword:2c3ee568
`"LocalProfileUnloadTimeHigh`"=dword:01d7e5c2" | Out-File $profileRegDataFilePath
    Write-Output "Using automatic fallback profile target path: $profileTargetPath"
}

try{
    Write-Output "Copying profile from $profileSourcePath to $profileTargetPath"
    robocopy $profileSourcePath $profileTargetPath /MIR /XJ *>&1 | Out-Null
    Write-Output "Copied profile from $profileSourcePath to $profileTargetPath"
}catch{
    Write-Output $_
}

try{
    if($profileRegDataFilePath -and (Test-Path $profileRegDataFilePath)){
        Write-Output "Writing registry data"
        Invoke-Command {reg import $profileRegDataFilePath *>&1 | Out-Null}
    }else{
        Write-Output "Skipping regfile import due to earlier issues parsing the user's regfile"
    }
}catch{
    Write-Output $_
}

try{
    Write-Output "Dismounting remote profile disk"
    Dismount-DiskImage -ImagePath $profileRemotePath -StorageType VHD -Confirm:$False
    Write-Output "Dismounted $profileRemotePath"
}catch{
    Write-Output $_
}

try{
    Write-Output "Disabling FSLogix on $($env:COMPUTERNAME)"
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey("LocalMachine",[Microsoft.Win32.RegistryView]::Registry64)
    $key = $baseKey.OpenSubKey('SOFTWARE\FSlogix\Profiles\', $true)
    $key.SetValue('Enabled', 0, 'DWORD')
    $fslogixgroups = Get-LocalGroup | where {$_.Name -like "*Exclude List*"}
    $fslogixgroups | % {
        Add-LocalGroupMember -Group $_ -Member $user -ErrorAction SilentlyContinue
    }
    Write-Output "Disabled FSLogix on $($env:COMPUTERNAME)"
}catch{
    Write-Output $_
    Exit 1
}

Write-Output "Setting permissions on $profileTargetPath folder"
icacls $profileTargetPath /inheritance:r | Out-Null
icacls $profileTargetPath /grant $domainNetbiosName\$($user):`(OI`)`(CI`)F /t /c /q | Out-Null
icacls $profileTargetPath /grant SYSTEM:`(OI`)`(CI`)FF /t /c /q | Out-Null
icacls $profileTargetPath /grant Administrators:`(OI`)`(CI`)FF /t /c /q | Out-Null

Write-Output "Cleaning up"
Remove-Item -Path (Join-Path $profileTargetPath -ChildPath "AppData\Local\FSLogix") -Force -Confirm:$False -ErrorAction SilentlyContinue -Recurse
get-childitem -path "c:\users" | %{
    if($_.Name -like "local*"){
        Remove-Item -Path $_.FullName -Force -Recurse -Confirm:$false -ErrorAction SilentlyContinue
        Write-Output "Removed $($_.FullName)"
    }
}

Write-Output "Script completed, VM is rebooting and will be ready for logon soon"
Restart-Computer -Force -Confirm:$False