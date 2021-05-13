<#
    .SYNOPSIS
    Sets custom lock screen based on file in an Azure Storage Blob container
    See blob template to automatically configure a blob container: https://gitlab.com/Lieben/assortedFunctions/-/blob/master/ARM%20templates/blob%20storage%20with%20container%20for%20Teams%20Backgrounds%20and%20public%20access.json
    Also works with Windows 10 Pro / non-enterprise versions

    .NOTES
    filename: set-windows10LockScreen.ps1
    author: Jos Lieben
    blog: www.lieben.nu
    created: 13/05/2021
#>

Start-Transcript -Path (Join-Path -Path $Env:TEMP -ChildPath "set-windows10LockScreen.log")

$changedDate = "2021-05-13"

$lockscreenFileURL = "https://tasdsadgsadsad.blob.core.windows.net/teamsbackgrounds/figure-a.jpg" #this is the name of your storage account in Azure 
$tempFile = (Join-Path $Env:TEMP -ChildPath "img100.jpg")

try{
    Write-Output "downloading lock screen file from $lockscreenFileURL"
    Invoke-WebRequest -Uri $lockscreenFileURL -UseBasicParsing -Method GET -OutFile $tempFile
    Write-Output "file downloaded to $tempFile"
}catch{
    Write-Output "Failed to download file, aborting"
    Write-Error $_ -ErrorAction SilentlyContinue
    Exit
}

#remove buffered lockscreen images
Write-Output "Deleting image buffers"
get-childitem "$($env:ProgramData)\Microsoft\Windows\SystemData" -Recurse | % {
    if($_.Name.StartsWith("LockScreen")){
        Remove-Item -Path $_.FullName -Force -Confirm:$False -Recurse
    }
}

Start-Process -filePath "$($env:systemRoot)\system32\takeown.exe" -ArgumentList "/F `"$($env:systemRoot)\Web\Screen`" /R /A /D Y" -NoNewWindow -Wait
Start-Process -filePath "$($env:systemRoot)\system32\icacls.exe" -ArgumentList "`"$($env:systemRoot)\Web\Screen`" /grant Administrators:(OI)(CI)F /T" -NoNewWindow -Wait
Start-Process -filePath "$($env:systemRoot)\system32\icacls.exe" -ArgumentList "`"$($env:systemRoot)\Web\Screen`" /grant Everyone:(OI)(CI)R /T" -NoNewWindow -Wait
Start-Process -filePath "$($env:systemRoot)\system32\icacls.exe" -ArgumentList "`"$($env:systemRoot)\Web\Screen`" /reset /T" -NoNewWindow -Wait

Write-Output "Removing current images"
#remove current lockscreen images
get-childitem "$($env:systemRoot)\Web\Screen" | % {
    Remove-Item -Path $_.FullName -Force -Confirm:$False -Recurse
}

#store new lockscreen image
Write-Output "Moving $tempFile to destination folder"
Move-Item -Path $tempFile -Destination "$($env:systemRoot)\Web\Screen\img100.jpg" -Force -Confirm:$False

#Restrict user ability to change lock screen image
Write-Output "restricting user from modifying the lock screen image"
New-Item -Path "HKLM:\Software\Policies\Microsoft\Windows" -Name "Personalization" -Force -ErrorAction SilentlyContinue | Out-Null 
Set-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Windows\Personalization" -Name 'NoChangingLockScreen' -Value 1 -Type 'Dword' -Force 

Write-Output "Script complete"
Stop-Transcript