﻿<#
    .SYNOPSIS
    Generates a report of all guest users in your tenant, including the last signed in date (if any) based on signInActivity.
    Optionally, it can remove users if they have been inactive for a given threshold number of days.

    If the nonInteractive switch is supplied, the script will leverage Managed Identity (e.g. when running as an Azure Runbook) to log in to the Graph API. 
    In that case, assign User.ReadWrite.All (when using 'removeInactiveGuests'), AuditLog.Read.All and Organization.Read.All permissions to the managed identity by using: https://gitlab.com/Lieben/assortedFunctions/-/blob/master/add-roleToManagedIdentity.ps1

    If you want the script to send mail reports, also assign a value for the From, To addresses and assign the Mail.Send graph permission to the managed identity as per above instructions.

    .NOTES
    filename:   get-AzureAdInactiveGuestUsers.ps1
    author:     Jos Lieben / jos@lieben.nu
    copyright:  Lieben Consultancy, free to (re)use, keep headers intact
    site:       https://www.lieben.nu
    Created:    16/12/2021
    Updated:    See Gitlab
#>
#Requires -Modules @{ ModuleName="Az.Accounts"; ModuleVersion="2.7.0" }, @{ ModuleName="Az.Resources"; ModuleVersion="5.1.0" }

Param(
    [Int]$inactiveThresholdInDays = 90,
    [Switch]$removeInactiveGuests,
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
            
$propertiesSelector = @("UserType","UserPrincipalName","Id","DisplayName","ExternalUserState","ExternalUserStateChangeDateTime","CreatedDateTime","CreationType","AccountEnabled")

if(!$nonInteractive){
    Write-Progress -Activity "Azure AD Guest User Report" -Status "Grabbing all guests in your AD" -Id 1 -PercentComplete 0
}

$guests = @()
$userData = Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/users?`$Filter=UserType eq 'Guest'&`$select=UserType,UserPrincipalName,Id,DisplayName,ExternalUserState,ExternalUserStateChangeDateTime,CreatedDateTime,CreationType,AccountEnabled,signInActivity" -Method GET -Headers @{"Authorization"="Bearer $token"}
$guests += $userData.value
while($userData.'@odata.nextLink'){
    if(!$nonInteractive){
        Write-Progress -Activity "Azure AD Guest User Report" -Status "Grabbing all guests in your AD ($($guests.count))" -Id 1 -PercentComplete 0
    }
    $userData = Invoke-RestMethod -Uri $userData.'@odata.nextLink' -Method GET -Headers @{"Authorization"="Bearer $token"}    
    $guests += $userData.value
}

$reportData = @()
for($i=0; $i -lt $guests.Count; $i++){
    try{$percentComplete = $i/$guests.Count*100}catch{$percentComplete=0}
    if(!$nonInteractive){
        Write-Progress -Activity "Azure AD Guest User Report" -Status "Processing $i/$($guests.Count) $($guests[$i].UserPrincipalName)" -Id 1 -PercentComplete $percentComplete
    }
    $obj = [PSCustomObject]@{}
    foreach($property in $propertiesSelector){
        $obj | Add-Member -MemberType NoteProperty -Name $property -Value $guests[$i].$property
    }

    $lastSignIn = $Null
    if($guests[$i].signInActivity){
        if($guests[$i].signInActivity.lastSignInDateTime -and $guests[$i].signInActivity.lastSignInDateTime -ne "0001-01-01T00:00:00Z"){
            $lastSignIn = [DateTime]$guests[$i].signInActivity.lastSignInDateTime
        }
        if($guests[$i].signInActivity.lastNonInteractiveSignInDateTime -and $guests[$i].signInActivity.lastNonInteractiveSignInDateTime -ne "0001-01-01T00:00:00Z"){
            if(!$lastSignIn -or [Datetime]$guests[$i].signInActivity.lastNonInteractiveSignInDateTime -gt $lastSignIn){
                $lastSignIn = [Datetime]$guests[$i].signInActivity.lastNonInteractiveSignInDateTime
            }
        }
    }

    if($lastSignIn){
        Write-Host "$($guests[$i].UserPrincipalName) detected last signin: $lastSignIn"
        $obj | Add-Member -MemberType NoteProperty -Name "LastSignIn" -Value $lastSignIn.ToString("yyyy-MM-dd hh:mm:ss")
        $obj | Add-Member -MemberType NoteProperty -Name "InactiveDays" -Value ([math]::Round((New-TimeSpan -Start ($lastSignIn) -End (Get-Date)).TotalDays))
    }else{
        Write-Host "$($guests[$i].UserPrincipalName) detected last signin: Never"
        $obj | Add-Member -MemberType NoteProperty -Name "InactiveDays" -Value ([math]::Round((New-TimeSpan -Start ([DateTime]$guests[$i].CreatedDateTime) -End (Get-Date)).TotalDays))
        $obj | Add-Member -MemberType NoteProperty -Name "LastSignIn" -Value "Never"
    }

    $obj | Add-Member -MemberType NoteProperty -Name "AccountAgeInDays" -Value ([math]::Round((New-TimeSpan -Start ([DateTime]$guests[$i].CreatedDateTime) -End (Get-Date)).TotalDays))

    if($removeInactiveGuests){
        $remove = $False
        if($obj.LastSignIn -eq "Never" -and ([DateTime]$guests[$i].CreatedDateTime -lt (Get-Date).AddDays($inactiveThresholdInDays*-1))){
            $remove = $True
            Write-Host "Will delete $($guests[$i].UserPrincipalName) because it was never signed in and was created more than $inactiveThresholdInDays days ago"
        }
        if($obj.LastSignIn -ne "Never" -and $lastSignIn -lt (Get-Date).AddDays($inactiveThresholdInDays*-1)){
            $remove = $True
            Write-Host "Will delete $($guests[$i].UserPrincipalName) because it was last signed in more than $inactiveThresholdInDays days ago"
        }
        if($remove){
            Try{
                Remove-AzADUser -ObjectId $guests[$i].Id -Confirm:$False
                $obj | Add-Member -MemberType NoteProperty -Name "AutoRemoved" -Value "Yes"
                Write-Host "Deleted $($guests[$i].UserPrincipalName)"
            }catch{
                $obj | Add-Member -MemberType NoteProperty -Name "AutoRemoved" -Value "Failed"
                Write-Host "Failed to delete $($guests[$i].UserPrincipalName)"
            }
        }else{
            $obj | Add-Member -MemberType NoteProperty -Name "AutoRemoved" -Value "No"
        }
    }
    $reportData+=$obj
}

$reportData | Export-CSV -Path "guestActivityReport.csv" -Encoding UTF8 -NoTypeInformation

if(!$nonInteractive){
    .\guestActivityReport.csv
}

If($mailFrom -and $mailTo){
    $body = @{
        "message"=@{
            "subject" = "guest activity report"
            "body" = @{
                "contentType" = "HTML"
                "content" = [String]"please find attached an automated guest activity report"
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

    $attachment = Get-Item "guestActivityReport.csv"

    $FileName=(Get-Item -Path $attachment).name
    $base64string = [Convert]::ToBase64String([IO.File]::ReadAllBytes($attachment))
    $body.message.attachments += [PSCustomObject]@{
        "@odata.type" = "#microsoft.graph.fileAttachment"
        "name" = "guestActivityReport.csv"
        "contentType" = "text/plain"
        "contentBytes" = "$base64string"
    }

    Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$mailFrom/sendMail" -Method POST -Headers @{"Authorization"="Bearer $token"} -Body ($body | convertto-json -depth 10) -ContentType "application/json"

}