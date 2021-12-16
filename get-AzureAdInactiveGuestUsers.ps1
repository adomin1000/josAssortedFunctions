<#
    .SYNOPSIS
    Generates a report of all guest users in your tenant, including the last signed in date (if any) based on SignIn logs in Azure Log Analytics.
    Optionally, it can remove users if they have been inactive for a given threshold number of days.

    .NOTES
    filename:   get-AzureAdInactiveGuestUsers.ps1
    author:     Jos Lieben / jos@lieben.nu
    copyright:  Lieben Consultancy, free to (re)use, keep headers intact
    site:       https://www.lieben.nu
    Created:    16/12/2021
    Updated:    See Gitlab
#>
#Requires -Modules @{ ModuleName="Az.Accounts "; ModuleVersion="2.7.0" }, @{ ModuleName="Az.Resources"; ModuleVersion="5.1.0" }

Param(
    [Parameter(Mandatory=$true)][String]$workspaceName,
    [Parameter(Mandatory=$true)][String]$subscriptionName,
    [Int]$inactiveThresholdInDays = 90,
    [Switch]$removeInactiveGuests
)

Login-AzAccount -Subscription $subscriptionName
$workspace = Get-AzOperationalInsightsWorkspace | Where{$_.Name -eq $workspaceName}

$propertiesSelector = @("UserType","UserPrincipalName","Id","DisplayName","ExternalUserState","ExternalUserStateChangeDateTime","CreatedDateTime","CreationType","AccountEnabled")


Write-Progress -Activity "Azure AD Guest User Report" -Status "Grabbing all guests in your AD" -Id 1 -PercentComplete 0

$guests = Get-AzADUser -Filter "UserType eq 'Guest'" -Select $propertiesSelector
$reportData = @()
for($i=0; $i -lt $guests.Count; $i++){
    try{$percentComplete = $i/$guests.Count*100}catch{$percentComplete=0}
    Write-Progress -Activity "Azure AD Guest User Report" -Status "Processing $i/$($guests.Count) $($guests[$i].UserPrincipalName)" -Id 1 -PercentComplete $percentComplete
    $obj = [PSCustomObject]@{}
    foreach($property in $propertiesSelector){
        $obj | Add-Member -MemberType NoteProperty -Name $property -Value $guests[$i].$property
    }

    #return last logon from LA workspace
    $query = "SigninLogs | where TimeGenerated < ago(1s) and TimeGenerated > ago(1825d) | where UserId  == `"$($guests[$i].Id)`" | summarize arg_max(TimeGenerated, *) by Identity"
    $attempts = 0
    while($true){
        try{
            $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $query -ErrorAction Stop
            break
        }catch{
            Start-Sleep -s 1
            $attempts++
        }
        if($attempts -gt 10){
            Write-Host "Error querying workspace for $($guests[$i].Id) because of $($_)"
            break
        }
    }

    if($result.Results.TimeGenerated){
        Write-Host "$($guests[$i].UserPrincipalName) detected last signin: $($result.Results.TimeGenerated)"
        $obj | Add-Member -MemberType NoteProperty -Name "LastSignIn" -Value ([DateTime]$result.Results.TimeGenerated).ToString("yyyy-MM-dd hh:mm:ss")
        $obj | Add-Member -MemberType NoteProperty -Name "InactiveDays" -Value ([math]::Round((New-TimeSpan -Start ([DateTime]$result.Results.TimeGenerated) -End (Get-Date)).TotalDays))
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
        if($obj.LastSignIn -ne "Never" -and [DateTime]$result.Results.TimeGenerated -lt (Get-Date).AddDays($inactiveThresholdInDays*-1)){
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