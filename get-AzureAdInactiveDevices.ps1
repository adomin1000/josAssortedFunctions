<#
    .SYNOPSIS
    Generates a report of all devices in your tenant, including the last signed in date (if any) based on the last activity.
    Optionally, it can remove devices if they have been inactive for a given threshold number of days by supplying the removeInactiveDevices switch

    If the nonInteractive switch is supplied, the script will leverage Managed Identity (e.g. when running as an Azure Runbook) to log in to the Graph API. 
    Assign the Device.Read.All permissions to the managed identity by using: https://gitlab.com/Lieben/assortedFunctions/-/blob/master/add-roleToManagedIdentity.ps1
    In addition assign the cloud device administrator (Azure AD) role to the Managed Identity.

    If you want the script to send mail reports, also assign a value for the From, To addresses and assign the Mail.Send graph permission to the managed identity as per above instructions.

    If the firstDisableDevices switch is also supplied, devices will not be deleted when the inactiveThresholdInDays is met, but disabled instead. Then after the 
    disableDurationInDays threshold, they will be deleted.

    .NOTES
    filename:   get-AzureAdInactiveDevices.ps1
    author:     Jos Lieben / jos@lieben.nu
    copyright:  Lieben Consultancy, free to (re)use, keep headers intact
    disclaimer: https://www.lieben.nu/liebensraum/contact/#disclaimer-and-copyright
    site:       https://www.lieben.nu
    Created:    16/12/2021
    Updated:    See Gitlab
#>
#Requires -Modules @{ ModuleName="Az.Accounts"; ModuleVersion="2.7.0" }, @{ ModuleName="Az.Resources"; ModuleVersion="5.1.0" }

Param(
    [Int]$inactiveThresholdInDays = 90,
    [Switch]$removeInactiveDevices,
    [Switch]$firstDisableDevices,
    [Int]$disableDurationInDays = 30,
    [Switch]$nonInteractive,
    [String]$mailFrom, #this should not be a shared mailbox
    [String[]]$mailTo
)

[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
$res = [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12
try{
    if($nonInteractive){
        Write-Output "Logging in with MI"
        $Null = Connect-AzAccount -Identity -ErrorAction Stop
        Write-Output "Logged in as MI"
    }else{
        Login-AzAccount -ErrorAction Stop
    }
}catch{
    Throw $_
}

$context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
$token = ([Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id.ToString(), $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, "https://graph.microsoft.com")).AccessToken
            
$propertiesSelector = @("extensionAttributes","id","accountEnabled","createdDateTime","approximateLastSignInDateTime","deviceId","displayName","onPremisesSyncEnabled","operatingSystem","profileType","trustType","sourceType")

if(!$nonInteractive){
    Write-Progress -Activity "Azure AD Device Report" -Status "Grabbing all devices in your AD" -Id 1 -PercentComplete 0
}

$devices = @()
$deviceData = Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/devices?`$select=*" -Method GET -Headers @{"Authorization"="Bearer $token"}
$devices += $deviceData.value
while($deviceData.'@odata.nextLink'){
    if(!$nonInteractive){
        Write-Progress -Activity "Azure AD Device Report" -Status "Grabbing all devices in your AD ($($devices.count))" -Id 1 -PercentComplete 0
    }
    $deviceData = Invoke-RestMethod -Uri $deviceData.'@odata.nextLink' -Method GET -Headers @{"Authorization"="Bearer $token"}    
    $devices += $deviceData.value
}

$reportData = @()
for($i=0; $i -lt $devices.Count; $i++){
    try{$percentComplete = $i/$devices.Count*100}catch{$percentComplete=0}
    if(!$nonInteractive){
        Write-Progress -Activity "Azure AD Device Report" -Status "Processing $i/$($devices.Count) $($devices[$i].displayName)" -Id 1 -PercentComplete $percentComplete
    }
    $obj = [PSCustomObject]@{}
    foreach($property in $propertiesSelector){
        $obj | Add-Member -MemberType NoteProperty -Name $property -Value $devices[$i].$property
    }

    $lastSignIn = $Null
    if($devices[$i].approximateLastSignInDateTime){
        if($devices[$i].signInActivity.lastSignInDateTime -ne "0001-01-01T00:00:00Z"){
            $lastSignIn = [DateTime]$devices[$i].approximateLastSignInDateTime
        }
    }

    $created = $Null
    if($devices[$i].createdDateTime){
        $created = $devices[$i].createdDateTime
    }elseif($devices[$i].registrationDateTime){
        $created = $devices[$i].registrationDateTime
    }else{
        $created = $devices[$i].approximateLastSignInDateTime
    }

    if($lastSignIn){
        Write-Host "$($devices[$i].displayName) detected last signin: $lastSignIn"
        $obj | Add-Member -MemberType NoteProperty -Name "LastSignIn" -Value $lastSignIn.ToString("yyyy-MM-dd hh:mm:ss")
        $obj | Add-Member -MemberType NoteProperty -Name "InactiveDays" -Value ([math]::Round((New-TimeSpan -Start ($lastSignIn) -End (Get-Date)).TotalDays))
    }else{
        Write-Host "$($devices[$i].displayName) detected last signin: Never"
        $obj | Add-Member -MemberType NoteProperty -Name "InactiveDays" -Value ([math]::Round((New-TimeSpan -Start ([DateTime]$created) -End (Get-Date)).TotalDays))
        $obj | Add-Member -MemberType NoteProperty -Name "LastSignIn" -Value "Never"
    }

    $obj | Add-Member -MemberType NoteProperty -Name "DeviceAgeInDays" -Value ([math]::Round((New-TimeSpan -Start ([DateTime]$created) -End (Get-Date)).TotalDays))

    if($removeInactiveDevices){
        $remove = $False
        if($obj.LastSignIn -eq "Never" -and ([DateTime]$created -lt (Get-Date).AddDays($inactiveThresholdInDays*-1))){
            $remove = $True
            Write-Host "Will delete or disable $($devices[$i].displayName) because it was never signed in and was created more than $inactiveThresholdInDays days ago"
        }
        if($obj.LastSignIn -ne "Never" -and $lastSignIn -lt (Get-Date).AddDays($inactiveThresholdInDays*-1)){
            $remove = $True
            Write-Host "Will delete or disable $($devices[$i].displayName) because it was last signed in more than $inactiveThresholdInDays days ago"
        }

        if($remove){
            Try{
                if($obj.operatingSystem -eq "Unknown"){
                    Throw "it is an autopilot object and has to be deleted or deactivated in AutoPilot"
                }
                if($obj.onPremisesSyncEnabled){
                    Throw "it is synced from an on premises AD, please delete or deactivate it there"
                }
                if($firstDisableDevices){
                    $remove = $False
                    if($obj.accountEnabled -eq $True){
                        #device is active, we need to disable it as inactivity threshold is met
                        $body = @{
                            "extensionAttributes"= @{
                                "extensionAttribute6"= "$((Get-Date).ToFileTimeUtc())"
                            }
                            "accountEnabled"= $false
                        }
                        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/devices/$($devices[$i].id)" -Body ($body | convertto-json -Depth 5) -Method PATCH -Headers @{"Authorization"="Bearer $token"} -ContentType "application/json"
                        $obj | Add-Member -MemberType NoteProperty -Name "Result" -Value "Disabled"
                        Write-Host "Disabled $($devices[$i].displayName)"
                    }else{
                        if($obj.extensionAttributes.extensionAttribute6){
                            if([DateTime]::FromFileTime($obj.extensionAttributes.extensionAttribute6) -le (Get-Date).AddDays($disableDurationInDays*-1)){
                                $remove = $True
                            }else{
                                $obj | Add-Member -MemberType NoteProperty -Name "Result" -Value "Disabled"
                            }
                        }else{
                            $remove = $True
                        }
                    }
                }
                if($remove){
                    Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/devices/$($devices[$i].id)" -Method DELETE -Headers @{"Authorization"="Bearer $token"}
                    $obj | Add-Member -MemberType NoteProperty -Name "Result" -Value "Removed"
                    Write-Host "Deleted $($devices[$i].displayName)"
                }
            }catch{
                $obj | Add-Member -MemberType NoteProperty -Name "Result" -Value "Failed"
                Write-Host "Failed to delete or disable $($devices[$i].displayName) because $_"
            }
        }else{
            $obj | Add-Member -MemberType NoteProperty -Name "Result" -Value "N/A"
        }
    }
    $reportData+=$obj
}

$reportData | Export-CSV -Path "deviceActivityReport.csv" -Encoding UTF8 -NoTypeInformation

if(!$nonInteractive){
    .\deviceActivityReport.csv
}

If($mailFrom -and $mailTo){
    $body = @{
        "message"=@{
            "subject" = "device activity report"
            "body" = @{
                "contentType" = "HTML"
                "content" = [String]"please find attached an automated device activity report"
            }
            "toRecipients" = @()
            "from" = [PSCustomObject]@{
                "emailAddress"= [PSCustomObject]@{
                    "address"= $mailFrom
                }
            }
            "attachments" = @()
        };
        "saveToSentItems"=$False
    }

    foreach($recipient in $mailTo){
        $body.message.toRecipients += [PSCustomObject]@{"emailAddress" = [PSCustomObject]@{"address"=$recipient}} 
    }

    $attachment = Get-Item "deviceActivityReport.csv"

    $FileName=(Get-Item -Path $attachment).name
    $base64string = [Convert]::ToBase64String([IO.File]::ReadAllBytes($attachment))
    $body.message.attachments += [PSCustomObject]@{
        "@odata.type" = "#microsoft.graph.fileAttachment"
        "name" = "deviceActivityReport.csv"
        "contentType" = "text/plain"
        "contentBytes" = "$base64string"
    }

    Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$mailFrom/sendMail" -Method POST -Headers @{"Authorization"="Bearer $token"} -Body ($body | convertto-json -depth 10) -ContentType "application/json"

}