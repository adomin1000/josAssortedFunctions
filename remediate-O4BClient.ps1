#Module name:       remediate-O4bClient.ps1
#Author:            Jos Lieben
#Author Blog:       https://www.lieben.nu
#Created:           29-11-2021
#Updated:           see Git
#Copyright/License: https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)
#Purpose:           Used as MEM Proactive Remediation job to detect O4B issues and correct them
#Requirements:      Windows 10 build 1803, Onedrive preinstalled / configured (see my blog for instructions on fully automating that)

if($Env:USERPROFILE.EndsWith("system32\config\systemprofile")){
    Throw "Running as SYSTEM, this script should run in user context!"
    Exit 1
}

$mode = $MyInvocation.MyCommand.Name.Split(".")[0]
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Web")

try{
    $tenantIdKeyPath = "HKLM:\System\CurrentControlSet\Control\CloudDomainJoin\TenantInfo"
    $tenantId = @(Get-ChildItem -Path $tenantIdKeyPath)[0].Name.Split("\")[-1]
    if(!$tenantId -or $tenantId.Length -lt 10){
        Throw "No valid tenant ID returned from $tenantIdKeyPath"
    }
}catch{
    Write-Host $_
    Exit 1
}

#wait until Onedrive has been configured properly (ie: linked to user's account)
$waited = 0
:accounts while($true){
    try{
        if(Test-Path HKCU:\Software\Microsoft\OneDrive\Accounts){
            #look for a Business key with our configured tenant ID that is properly filled out
            foreach($account in @(Get-ChildItem HKCU:\Software\Microsoft\OneDrive\Accounts)){
                if($account.GetValue("Business") -eq 1 -and $account.GetValue("ConfiguredTenantId") -eq $tenantId){
                    if((Test-Path $account.GetValue("UserFolder"))){
                        $odAccount = $account
                        $companyName = $account.GetValue("DisplayName").Replace("/"," ")
                        $userEmail = $account.GetValue("UserEmail")
                        break accounts
                    }
                }
            }             
        }
    }catch{$Null}
    
    if($waited -gt 600){
        Write-Host "Waited for more than 10 minutes, Onedrive hasn't been linked yet. Tell user to sign in to Onedrive"
        Exit 1
    }
    Start-Sleep -s 10
    $waited += 10
}

function detectOdmLogFile(){
    $odmDiagLogPath = Join-Path $($env:LOCALAPPDATA) "Microsoft\OneDrive\logs\Business1\SyncDiagnostics.log"
    if((Test-Path $odmDiagLogPath)){
        return $odmDiagLogPath
    }else{
        return $False
    }    
}

function detectOdmRunning(){
    try{
        $o4bProcessInfo = @(Get-ProcessWithOwner -ProcessName "onedrive")[0]
        if($o4bProcessInfo.ProcessName){
            return $true
        }else{
            Throw
        }
    }catch{
        return $False
    }    
}

function parseOdmLogFileForStatus(){
    #with thanks to Rudy Ooms for the example! https://call4cloud.nl/2020/09/lost-in-monitoring-onedrive/
    Param(
        [String][Parameter(Mandatory=$true)]$logPath
    )
    
    try{
        $progressState = Get-Content $logPath | Where-Object { $_.Contains("SyncProgressState") } | %{ -split $_ | select -index 1 }    
        switch($progressState){
            0{ return "Healthy"}
            42{ return "Healthy"}
            16777216{ return "Healthy"}
		    65536{ return "Paused"}
		    8194{ return "Disabled"}
		    1854{ return "Unhealthy"}
		    default { return "Unknown: $progressState"}
	    }
    }catch{
        return "Unknown: Could not find sync state in O4B log $_"
    }   
}

function detectIfLogfileStale(){
    Param(
        [String][Parameter(Mandatory=$true)]$logPath
    )

    if (((get-date).AddHours(-24)) -gt ((get-item $logPath).LastWriteTime)) {
        return $True
    } else {
        return $False
    }
}

function Get-ProcessWithOwner { 
    param( 
        [parameter(mandatory=$true,position=0)]$ProcessName 
    ) 
    $ComputerName=$env:COMPUTERNAME 
    $UserName=$env:USERNAME 
    $PSStandardMembers = [System.Management.Automation.PSMemberInfo[]]@($(New-Object System.Management.Automation.PSPropertySet('DefaultDisplayPropertySet',[string[]]$('ProcessName','UserName','Domain','ComputerName','handle')))) 
    try { 
        $Processes = Get-wmiobject -Class Win32_Process -ComputerName $ComputerName -Filter "name LIKE '$ProcessName%'" 
    } catch { 
        return -1 
    } 
    if ($Processes -ne $null) { 
        $OwnedProcesses = @() 
        foreach ($Process in $Processes) { 
            if($Process.GetOwner().User -eq $UserName){ 
                $Process |  
                Add-Member -MemberType NoteProperty -Name 'Domain' -Value $($Process.getowner().domain) 
                $Process | 
                Add-Member -MemberType NoteProperty -Name 'ComputerName' -Value $ComputerName  
                $Process | 
                Add-Member -MemberType NoteProperty -Name 'UserName' -Value $($Process.GetOwner().User)  
                $Process |  
                Add-Member -MemberType MemberSet -Name PSStandardMembers -Value $PSStandardMembers 
                $OwnedProcesses += $Process 
            } 
        } 
        return $OwnedProcesses 
    } else { 
        return 0 
    } 
}

function startO4B(){
    if((Test-Path (Join-Path $env:LOCALAPPDATA -ChildPath "\Microsoft\OneDrive\OneDrive.exe"))){
        $exePath = (Join-Path $env:LOCALAPPDATA -ChildPath "\Microsoft\OneDrive\OneDrive.exe")
    }else{
        $exePath = "C:\Program Files\Microsoft OneDrive\OneDrive.exe"
    }

    #onedrive needs to run in unelevated context, so de-elevate if necessary
    If (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")){  
        $createTask = "schtasks /Create /SC ONCE /TN remediateO4BClient /IT /RL LIMITED /F /TR `"$exePath`" /ST 23:59"    
        $res = Invoke-Expression $createTask | Out-Null
        $res = Invoke-Expression "schtasks /Run /TN remediateO4BClient /I" | Out-Null
        Start-Sleep -s 2
        $res = Invoke-Expression "schtasks /delete /TN remediateO4BClient /F" | Out-Null
    }else{
        Start-Process $exePath
    }
}

function restartO4B(){
    $processes = Get-ProcessWithOwner -ProcessName "onedrive"
    $processes | % {
        if($_.handle){
            Stop-Process -Id $processes.handle -Force -Confirm:$False
        }
    }
    Start-Sleep -Seconds 3
    startO4B
    Start-Sleep -Seconds 10
}

#code that runs when MEM runs this script in Detection Mode
if($mode -eq "detect"){
    #give everything a chance to start up
    Start-Sleep -s 300

    #no logfile while in detection mode, we'll have to remediate
    if($False -eq (detectOdmLogFile)){
        Write-Host "No Onedrive logfile present"
        Exit 1
    }

    #onedrive not running, we'll have to remediate
    if($False -eq (detectOdmRunning)){
        Write-Host "Onedrive not running"
        Exit 1
    }

    #logfile is old, we'll have to remediate
    if((detectIfLogfileStale -logPath (detectOdmLogFile))){
        Write-Host "Onedrive logfile is old and not updating"
        Exit 1
    }

    #check onedrive state and decide if we need to remediate
    $onedriveStatus = (parseOdmLogFileForStatus -logPath (detectOdmLogFile))

    if($onedriveStatus -eq "Unhealthy" -or $onedriveStatus.StartsWith("Unknown:")){
        Write-Host "Onedrive not in a healthy state: $onedriveStatus"
        Exit 1
    }else{
        Write-Host "Onedrive state: $onedriveStatus"
        Exit 0
    }
}

#code that runs when MEM runs this script in Remediation Mode
if($mode -ne "detect"){

    if($False -ne (detectOdmLogFile)){
        if((detectIfLogfileStale -logPath (detectOdmLogFile))){
            #remove stale logfile so it can be refreshed
            Remove-Item -Path (detectOdmLogFile) -Force -Confirm:$False
        }
    }

    if($False -eq (detectOdmRunning)){
        #ODM is not running, start it and check again
        startO4B
        Start-Sleep -s 300
        if($False -eq (detectOdmRunning)){
            Write-Host "Could not start Onedrive client! No onedrive.exe process discovered"
            Exit 1
        }
    }

    #no logfile while in remediation mode, we'll have to wait a few minutes
    if($False -eq (detectOdmLogFile)){
        Start-Sleep -s 300
    }

    #if still no logfile, we'll have to restart the Onedrive client
    if($False -eq (detectOdmLogFile)){
        restartO4B
        Start-Sleep -s 300
        if($False -eq (detectOdmLogFile)){
            Write-Host "No logfile after restarting Onedrive, something may be wrong with the Onedrive client that cannot be auto-remediated"
            Exit 1
        }
    }

    #logfile status should be good now, if not, cannot do much more
    $onedriveStatus = (parseOdmLogFileForStatus -logPath (detectOdmLogFile))
    if(($onedriveStatus -eq "Unhealthy" -or $onedriveStatus.StartsWith("Unknown:"))){
        Write-Host "After restarting Onedrive, still not in a healthy state: $onedriveStatus"
        Exit 1
    }else{
        Write-Host "Onedrive state: $onedriveStatus"
        Exit 0
    }
}
