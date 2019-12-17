﻿<#
    .DESCRIPTION
    Cleans up any duplicate devices in Azure AD that have the same hardware ID, by only leaving the most recently active one enabled

    .NOTES
    author: Jos Lieben
    blog: www.lieben.nu
    created: 17/12/2019
#>


#get all enabled AzureAD devices
$devices = Get-MsolDevice -All | Where{$_.Enabled}
$hwIds = @{}
$duplicates=@{}

#create hashtable with all devices that have a Hardware ID
foreach($device in $devices){
    $physId = $Null
    foreach($deviceId in $device.DevicePhysicalIds){
        if($deviceId.StartsWith("[HWID]")){
            $physId = $deviceId.Split(":")[-1]
        }
    }
    if($physId){
        if(!$hwIds.$physId){
            $hwIds.$physId = @{}
            $hwIds.$physId.Devices = @()
            $hwIds.$physId.DeviceCount = 0
        }
        $hwIds.$physId.DeviceCount++
        $hwIds.$physId.Devices += $device
    }
}

#select HW ID's that have multiple device entries
$hwIds.Keys | % {
    if($hwIds.$_.DeviceCount -gt 1){
        $duplicates.$_ = $hwIds.$_.Devices
    }
}

#loop over the duplicate HW Id's
$cleanedUp = 0
$totalDevices = 0
foreach($key in $duplicates.Keys){
    $mostRecent = (Get-Date).AddYears(-100)
    foreach($device in $duplicates.$key){
        $totalDevices++
        #detect which device is the most recently active device
        if([DateTime]$device.ApproximateLastLogonTimestamp -gt $mostRecent){
            $mostRecent = [DateTime]$device.ApproximateLastLogonTimestamp
        }
    }

    foreach($device in $duplicates.$key){
        if([DateTime]$device.ApproximateLastLogonTimestamp -lt $mostRecent){
            try{
                Disable-MsolDevice -DeviceId $device.DeviceId -Force -Confirm:$False -ErrorAction Stop
                Write-Output "Disabled Stale device $($device.DisplayName) with last active date: $($device.ApproximateLastLogonTimestamp)"
                $cleanedUp++
            }catch{
                Write-Output "Failed to disable Stale device $($device.DisplayName) with last active date: $($device.ApproximateLastLogonTimestamp)"
                Write-Output $_.Exception
            }
            
        }
    }
}

Write-Output "Total unique hardware ID's with >1 device registration: $($duplicates.Keys.Count)"

Write-Output "Total devices registered to these $($duplicates.Keys.Count) hardware ID's: $totalDevices" 

Write-Output "Devices cleaned up: $cleanedUp"

<# fun snippet to get distribution:
$distribution = @{}
foreach($key in $duplicates.Keys){
    if($distribution.$($duplicates.$key.Count)){
        [Int]$distribution.$($duplicates.$key.Count)++ | out-null
    }else{
        [Int]$distribution.$($duplicates.$key.Count) = 1
    }
}
Write-Output $distribution
#>