#Author:           Jos Lieben (OGD)
#Author Company:   OGD (http://www.ogd.nl)
#Author Blog:      http://www.lieben.nu
#Date:             05-06-2018
#Purpose:          Configurable drivemapping to server shares with automatic querying for credentials

#REQUIRED CONFIGURATION
$driveLetter = "U:" #change to desired driveletter
$path = "\\nlvfs01\dfs-units$\" #change to desired server / share path
$shortCutTitle = "U-Drive" #this will be the name of the shortcut
$autosuggestLogin = $True #automatically prefills the login field of the auth popup with the user's O365 email (azure ad join)
$desiredShortcutLocation = [Environment]::GetFolderPath("Desktop") #you can also use MyDocuments or any other valid input for the GetFolderPath function


###START SCRIPT

$desiredMapScriptFolder = Join-Path $Env:LOCALAPPDATA -ChildPath "Lieben.nu"
$desiredMapScriptPath = Join-Path $desiredMapScriptFolder -ChildPath "SMBdriveMapper.ps1"

if(![System.IO.Directory]::($desiredMapScriptFolder)){
    New-Item -Path $desiredMapScriptFolder -Type Directory -Force
}

$scriptContent = "
Param(
    `$driveLetter,
    `$sourcePath
)
"
if($autosuggestLogin){
    $scriptContent+= "
try{
    `$objUser = New-Object System.Security.Principal.NTAccount(`$Env:USERNAME)
    `$strSID = (`$objUser.Translate([System.Security.Principal.SecurityIdentifier])).Value
    `$basePath = `"HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\`$strSID\IdentityCache\`$strSID`"
    if((test-path `$basePath) -eq `$False){
        `$userId = `$Null
    }
    `$userId = (Get-ItemProperty -Path `$basePath -Name UserName).UserName
}catch{
    `$Null
}
"
}else{
    $scriptContent+= "
`$userId = `$null
    "
}

$scriptContent+= "
`$credentials = Get-Credential -UserName `$userId -Message `"Password required for `$driveLetter`" -ErrorAction Stop
[void] [System.Reflection.Assembly]::LoadWithPartialName(`"System.Drawing`") 
[void] [System.Reflection.Assembly]::LoadWithPartialName(`"System.Windows.Forms`")

if(!`$credentials){
    `$OUTPUT= [System.Windows.Forms.MessageBox]::Show(`"`$driveLetter will not be available, as you did not enter credentials`", `"`$driveLetter error`" , 0) 
    Exit
}

try{`$del = NET USE `$driveLetter /DELETE /Y 2>&1}catch{`$Null}

try{
    `$net = new-object -ComObject WScript.Network
    `$net.MapNetworkDrive(`$driveLetter, `$sourcePath, `$false, `$credentials.UserName, `$credentials.GetNetworkCredential())
}catch{
    `$OUTPUT= [System.Windows.Forms.MessageBox]::Show(`"Connection failed, technical reason: `$(`$Error[0])`", `"`$driveLetter error`" , 0) 
}"

$scriptContent | Out-File $desiredMapScriptPath -Force

$WshShell = New-Object -comObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut((Join-Path $desiredShortcutLocation -ChildPath "$($shortCutTitle).lnk"))
$Shortcut.TargetPath = "powershell.exe"
$Shortcut.WorkingDirectory = "%SystemRoot%\WindowsPowerShell\v1.0\"
$Shortcut.Arguments =  "-WindowStyle Hidden -ExecutionPolicy ByPass -File `"$desiredMapScriptPath`" $driveLetter `"$path`"”
$Shortcut.IconLocation = "explorer.exe ,0"
$shortcut.WindowStyle = 7
$Shortcut.Save()