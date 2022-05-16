<#
    .SYNOPSIS
    Automatically right sizes a given VM

    .NOTES
    filename: AADRS.psm1
    author: Jos Lieben / jos@lieben.nu
    copyright: https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)
    site: https://www.lieben.nu/liebensraum/2022/05/automatic-modular-rightsizing-of-azure-vms-with-special-focus-on-azure-virtual-desktop/
    Created: 16/05/2022
#>

function set-vmToSize{
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory)][Object]$vm,
        [Parameter(Mandatory)][String]$newSize,
        [Switch]$Force,
        [Switch]$Boot,
        [Switch]$WhatIf
    )

    if($vm.HardwareProfile.VmSize -ne $newSize){
        if($vm.PowerState -eq "VM running"){
            if($Force){
                Write-Verbose "Stopping $($vm.Name) as it is running and -Force was specified"
                if(!$WhatIf){
                    Stop-AzVM -Name $($vm.Name) -Confirm:$False -Force
                }
                Write-Verbose "Stopped $($vm.Name)"
            }else{
                Throw "$($vm.Name) still running, cannot resize a running VM. Use -Force if you wish to shut down $($vm.Name) automatically"
            }
        }else{
            Write-Verbose "$($vm.Name) is already stopped or deallocated"
        }
        $vm.HardwareProfile.VmSize = $newSize
        Write-Verbose "Sending resize command"
        if(!$WhatIf){
            $retVal = ($vm | Update-AzVM).StatusCode
        }else{
            $retVal = "OK"
        }
        Write-Verbose "VM Resized"
        if($Boot){
            Write-Verbose "Starting $($vm.Name) as -Boot was specified"
            if(!$WhatIf){
                Start-AzVM -Name $($vm.Name) -Confirm:$False -NoWait
            }
        }
        return $retVal
    }else{
        Throw "VM already at specified size"
    }
}


function get-azureVMPricesAndPerformance{
    [cmdletbinding()]
    Param(
        [String][Parameter(Mandatory)]$region
    )
    $vmPrices = @()
    $vmPricingData = Invoke-RestMethod -Uri "https://prices.azure.com/api/retail/prices?meterRegion=primary&api-version=2021-10-01-preview&currencyCode='USD'&`$filter=serviceName eq 'Virtual Machines' and priceType eq 'Consumption' and armRegionName eq '$region'" -Usebasicparsing -Method GET -ContentType "application/json"
    $vmPrices += $vmPricingData.Items
    while($vmPricingData.NextPageLink){
        $vmPricingData = Invoke-RestMethod -Uri $vmPricingData.NextPageLink -Usebasicparsing -Method GET -ContentType "application/json"
        $vmPrices += $vmPricingData.Items
    }

    Write-Verbose "$($vmPrices.Count) prices retrieved, retrieving performance scores..."

    $vmScoreRawData = (Invoke-RestMethod -Uri "https://raw.githubusercontent.com/MicrosoftDocs/azure-docs/main/articles/virtual-machines/linux/compute-benchmark-scores.md" -Method GET -UseBasicParsing) -split "`n"
    $vmScoreData = @()
    $inTable = $False
    for($l=0;$l -lt $vmScoreRawData.Count; $l++){
        if($vmScoreRawData[$l].StartsWith("| VM Size |")){
            #skip a line
            $l++
            $inTable = $True
            continue
        }
        if($inTable){
            if(!$vmScoreRawData[$l].StartsWith("| ")){
                $inTable = $False
                continue
            }
            $lineData = $vmScoreRawData[$l].Split("|")
            $vmScoreData += [PSCustomObject]@{
                "type" = $lineData[1].Trim()
                "perf" = $lineData[6].Trim()
            }
        }
    }

    Write-Verbose "$($vmScoreData.Count) performance rows retrieved, merging data..."

    $global:azureVMPrices = @()
    $vmPrices = $vmPrices | where{-Not($_.skuName.EndsWith("Spot")) -and -Not($_.skuName.EndsWith("Low Priority"))}
    foreach($sku in ($vmPrices.armSkuName | Select-Object -Unique)){
        $vmPricing = $vmPrices | where{$_.armSkuName -eq $sku}
        $obj = [PSCustomObject]@{
            "Name" = $sku
            "numberOfCores" = $($global:azureAvailableVMSizes | where{$_.Name -eq $sku}).NumberOfCores
            "memoryInMB" = $($global:azureAvailableVMSizes | where{$_.Name -eq $sku}).MemoryInMB
            "linuxPrice" = $($vmPricing | where{!$_.productName.EndsWith("Windows")}).retailPrice
            "windowsPrice" = $($vmPricing | where{$_.productName.EndsWith("Windows")}).retailPrice
            "perf" = $($vmScoreData | where{$_.type -eq $sku} | Sort-Object -Property perf | Select-Object -Last 1).perf
        }
        $global:azureVMPrices+= $obj
    }
}

function get-vmRightSize{
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory)][String]$targetVMName,
        [Parameter(Mandatory)][Guid]$workspaceId, #workspace GUID where perf data is stored (use Get-AzOperationalInsightsWorkspace to find this)
        $domain, #if your machines are domain joined, enter the domain name here
        [Int]$maintenanceWindowStartHour, #start hour of maintenancewindow in military time UTC (0-23)
        [Int]$maintenanceWindowLengthInHours, #length of maintenance window in hours (round up if needed)
        [ValidateSet(0,1,2,3,4,5,6)][Int]$maintenanceWindowDay, #day on which the maintenance window starts (UTC) where 0 = Sunday and 6 = Saturday
        [String]$region = "westeurope", #you can find yours using Get-AzLocation | select Location
        [Int]$measurePeriodHours = 152 #lookback period for a VM's performance while it was online, this is used to calculate the optimum. It is not recommended to size multiple times in this period!
    )
    
    #####CONFIGURATION##########################
    $vCPUTrigger = 0.75 #if a CPU is over 75% + the differerence percent on average, a vCPU should be added. If under 75% - the difference percent, the optimum amount should be calculated
    $memoryTrigger = 0.75 #if this percentage of memory + the difference percent is in use on average, more should be added. If under this percentage - the difference percent, memory should be recalculated
    $rightSizingMinimumDifferencePercent = 0.10 #minimum difference/buffer of 10% to avoid VM's getting resized back and forth every time you call this function
    $minMemoryGB = 4 #will never assign less than this (even if you've whitelisted VM's with more)
    $maxMemoryGB = 32 #will never assign more than this (even if you've whitelisted VM's with more)
    $minvCPUs = 2 #min 2 required for network acceleration!
    $maxvCPUs = 12 #in no case will this function assign a vmtype with more vCPU's than this
    #the following is a 'whitelist' of VM types to prevent the function from selecting undesired VM types
    #this function will select the optimum VM that meets CPU/MEM requirements based first on cost, then performance, then version (if known)
    $allowedVMTypes = @("Standard_D2ds_v4","Standard_D4ds_v4","Standard_D8ds_v4","Standard_D2ds_v5","Standard_D4ds_v5","Standard_D8ds_v5","Standard_E2ds_v4","Standard_E4ds_v4","Standard_E8ds_v4","Standard_E2ds_v5","Standard_E4ds_v5","Standard_E8ds_v5")
    #####END OF OPTIONAL CONFIGURATION#########
  
    $cul = $vCPUTrigger + $rightSizingMinimumDifferencePercent
    $cll = $vCPUTrigger - $rightSizingMinimumDifferencePercent
    $mul = $memoryTrigger + $rightSizingMinimumDifferencePercent
    $mll = $memoryTrigger - $rightSizingMinimumDifferencePercent

    #determine Azure Monitor query parameters in case a maintenance window was specified
    if($domain){
        $domain = ".$($domain)"
    }
    if($maintenanceWindowStartHour -and $maintenanceWindowDay -and $maintenanceWindowLengthInHours){
        $start = ([datetime]"2022-02-01T$($maintenanceWindowStartHour):00:00")
        $end = $start.AddHours($maintenanceWindowLengthInHours)
        if($start.Day -eq $end.Day){
            $queryAddition = " and ((dayofweek(TimeGenerated) == $($maintenanceWindowDay)d and (hourofday(TimeGenerated) < $maintenanceWindowStartHour or hourofday(TimeGenerated) > $($end.Hour))) or dayofweek(TimeGenerated) != $($maintenanceWindowDay)d)"
        }else{
            $queryAddition = " and ((dayofweek(TimeGenerated) == $($maintenanceWindowDay)d and (hourofday(TimeGenerated) < $maintenanceWindowStartHour)) or dayofweek(TimeGenerated) != $($maintenanceWindowDay)d) and ((dayofweek(TimeGenerated) == $($maintenanceWindowDay+1)d and (hourofday(TimeGenerated) > $($end.Hour))) or dayofweek(TimeGenerated) != $($maintenanceWindowDay+1)d)"
        }       
        Write-Verbose "$targetVMName grabbing data to calculate optimal size excluding maintenance window on day $maintenanceWindowDay at $maintenanceWindowStartHour for $maintenanceWindowLengthInHours hours"
    }else{
        $queryAddition = $Null
        Write-Verbose "$targetVMName grabbing data to calculate optimal size"
    }

    #use a global var to cache data between subsequent calls to list all available Azure VM sizes in the region
    if(!$global:azureAvailableVMSizes){
        try{
            $global:azureAvailableVMSizes = Get-AzVMSize -Location $region
        }catch{
            Throw "$targetVMName failed to retrieve available Azure VM sizes in your region because of $_"
        }
    }
    #use a global var to cache data between subsequent calls to list cost and performance data in the selected region
    if(!$global:azureVMPrices){
        try{
            Write-Verbose "Caching azure vm performance and pricing data"
            get-azureVMPricesAndPerformance -region $region
        }catch{
            Throw "$targetVMName failed to get pricing and performance data for Azure VM sizes because of $_"
        }
    }

    #enrich all whitelisted VM's with pricing data and remove any that are not availabe in the selected region
    $selectedVMTypes = @()
    foreach($allowedVMType in $allowedVMTypes){
        if($azureAvailableVMSizes.Name -contains $allowedVMType){
            $vmPricingInfo = $Null
            $vmPricingInfo = $azureVMPrices | where{$_.Name -eq $allowedVMType}
            if($vmPricingInfo){
                $selectedVMTypes += [PSCustomObject]@{
                    "Name" = $allowedVMType
                    "NumberOfCores" = $vmPricingInfo.numberOfCores
                    "MemoryInMB" = $vmPricingInfo.memoryInMB
                    "linuxPrice" = $vmPricingInfo.linuxPrice
                    "windowsPrice" = $vmPricingInfo.windowsPrice #https://docs.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices
                    "perf" = $vmPricingInfo.perf #https://docs.microsoft.com/en-us/azure/virtual-machines/linux/compute-benchmark-scores#about-coremark
                }
            }
        }
    }

    #sort the VM types we may use based on their price first, then performance rating
    $selectedVMTypes = $selectedVMTypes | Sort-Object @{e={$_.windowsPrice};a=1},@{e={$_.perf}; a=0},@{e={$_.Name.Split("_")[-1]}; a=0}

    #get meta data of targeted VM
    try{
        $targetVM = Get-AzVM -Name $targetVMName
        $targetVMPricing = $Null
        $targetVMPricing = $azureVMPrices.listVmInformations | where{$_.name -eq $targetVM.HardwareProfile.VmSize}

        $targetVMCurrentHardware = $azureAvailableVMSizes | where{$_.Name -eq $targetVM.HardwareProfile.VmSize}
        if(!$targetVMCurrentHardware){
            Throw "Current VM type $($targetVM.HardwareProfile.VmSize) could not be found in Azure's Available VM list, please resize manually to a currently supported size before using this function"
        }
        Write-Verbose "$targetVMName currently runs on $($targetVMCurrentHardware.NumberOfCores) vCPU's and $($targetVMCurrentHardware.MemoryInMB)MB memory ($($targetVM.HardwareProfile.VmSize))"
    }catch{
        Throw "$targetVMName failed to get VM metadata from Azure because of $_"
    }

    #check for the LCRightSizeConfig tag
    if($targetVM.Tags["LCRightSizeConfig"]){
        Write-Verbose "$targetVMName has right sizing tag with value $($targetVM.Tags["LCRightSizeConfig"])"
        if($targetVM.Tags["LCRightSizeConfig"] -eq "disabled"){
            Throw "$targetVMName right sizing disabled through Azure Tag"
        }else{
            return $targetVM.Tags["LCRightSizeConfig"]
        }
    }

    #get memory performance of targeted VM in configured period
    try{
        $query = "Perf | where TimeGenerated between (ago($($measurePeriodHours)h) .. ago(0h)) and CounterName == 'Available Mbytes' and Computer == '$($targetVMName)$($domain)'$queryAddition | project TimeGenerated, CounterValue | order by CounterValue"
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $query -ErrorAction Stop
        $resultsArray = [System.Linq.Enumerable]::ToArray($result.Results)
        Write-Verbose "$targetVMName retrieved $($resultsArray.Count) memory datapoints from Azure Monitor"
        #we need to ensure enough datapoints exist
        if($resultsArray.Count -le $measurePeriodHours*4){
            Throw "too few MEM perf data points to reliably calculate optimal VM size"
        }
        $memoryStats = get-vmCounterStats -Data $resultsArray.CounterValue
        #memory is expressed in Free MB's, recalculate to used % so we can apply similar logic as with CPU's
        $memUsedPct = (($targetVMCurrentHardware.MemoryInMB-$memoryStats.Percentile5)/$targetVMCurrentHardware.MemoryInMB)
        if($memUsedPct -gt 100 -or $memUsedPct -lt 0 -or $memoryStats.Maximum -gt $targetVMCurrentHardware.MemoryInMB){
            Throw "Unexpected (negative or too large) memory perf value detected, VM was probably already resized less than $measurePeriodHours hours ago"
        }
    }catch{
        Throw "$targetVMName failed to get memory performance data from Azure Monitor because $_"
    }

    Write-Verbose "$targetVMName has $($targetVMCurrentHardware.MemoryInMB)MB and in the top 5% of the time it averages at $($targetVMCurrentHardware.MemoryInMB - $memoryStats.Percentile5)MB ($([Math]::Round($memUsedPct*100,2))%) used"

    #get cpu performance of targeted VM in configured period
    try{
        $query = "Perf | where TimeGenerated between (ago($($measurePeriodHours)h) .. ago(0h)) and CounterName == '% Processor Time' and Computer == '$($targetVMName)$($domain)'$queryAddition | project TimeGenerated, CounterValue | order by CounterValue"
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $query -ErrorAction Stop
        $resultsArray = [System.Linq.Enumerable]::ToArray($result.Results)
        Write-Verbose "$targetVMName retrieved $($resultsArray.Count) cpu datapoints from Azure Monitor"
        #we need to ensure enough datapoints exist
        if($resultsArray.Count -le $measurePeriodHours*4){
            Throw "too few CPU perf data points to reliably calculate optimal VM size"
        }
        $cpuStats = get-vmCounterStats -Data $resultsArray.CounterValue
        $cpuUsedPct = $cpuStats.Percentile95/100
        if($cpuUsedPct -lt 0){
            Throw "Negative value detected, VM was probably already resized less than $measurePeriodHours hours ago"
        }
    }catch{
        Throw "$targetVMName failed to get CPU performnace data from Azure Monitor because $_"
    }

    Write-Verbose "$targetVMName has $($targetVMCurrentHardware.NumberOfCores) cpu cores and in the top 5% of the time it averages at $([Math]::Round($cpuStats.Percentile95,2))% max of the cores"

    $targetMinimumCPUCount=$targetVMCurrentHardware.NumberOfCores
    $targetMinimumMemoryInMB=$targetVMCurrentHardware.MemoryInMB

    #determine if CPU needs to be increased
    if($cpuUsedPct -gt $cul){
        $targetMinimumCPUCount = [Math]::Min($maxvCPUs,[Math]::Max($minvCPUs,[Math]::Ceiling($targetVMCurrentHardware.NumberOfCores*($cpuUsedPct/$cll))))
    }

    #determine if CPU needs to be decreased
    if($cpuUsedPct -lt $cll){
        $targetMinimumCPUCount = [Math]::Max($minvCPUs,[Math]::Min($maxvCPUs,[Math]::Ceiling($targetVMCurrentHardware.NumberOfCores*($cpuUsedPct/$cul))))
    }

    #determine if Memory needs to be increased
    if($memUsedPct -gt $mul){
        $targetMinimumMemoryInMB = [Math]::Min($maxMemoryGB*1024,[Math]::Max($minMemoryGB*1024,[Math]::Ceiling($targetVMCurrentHardware.MemoryInMB*($memUsedPct/$mll))))
    }

    #determine if memory needs to be decreased
    if($memUsedPct -lt $mll){
        $targetMinimumMemoryInMB = [Math]::Max($minMemoryGB*1024,[Math]::Min($maxMemoryGB*1024,[Math]::Ceiling($targetVMCurrentHardware.MemoryInMB*($memUsedPct/$mul))))
    }
    
    Write-Verbose "$targetVMName should have at least $targetMinimumCPUCount vCPU's and $targetMinimumMemoryInMB MB memory"

    $desiredVMType = $Null
    for($i=0;$i -lt $selectedVMTypes.Count;$i++){
        if($selectedVMTypes[$i].NumberOfCores -ge $targetMinimumCPUCount -and $selectedVMTypes[$i].NumberOfCores -le $maxvCPUs -and $selectedVMTypes[$i].MemoryInMB -le $maxMemoryGB*1024 -and $selectedVMTypes[$i].MemoryInMB -ge $targetMinimumMemoryInMB){
            $desiredVMType = $selectedVMTypes[$i]
            break
        }
    }

    if($targetVMPricing -and $desiredVMType){
        $costFactor = ($targetVMPricing.windowsPrice-$desiredVMType.windowsPrice)/$targetVMPricing.windowsPrice
    }

    if($desiredVMType){
        if($desiredVMType.Name -eq $targetVM.HardwareProfile.VmSize){
            Write-Verbose "$targetVMName is already sized correctly at $($targetVM.HardwareProfile.VmSize)"
            return $targetVM.HardwareProfile.VmSize
        }else{
            if($costFactor){
                if($costFactor -gt 0){
                    Write-Verbose "$targetVMName financial impact: $([Math]::Round($costFactor*100,2))% cost reduction"
                }else{
                    Write-Verbose "$targetVMName financial impact: $([Math]::Round($costFactor*100*-1,2))% cost increase"
                }
            }
            Write-Verbose "$targetVMName should be resized from $($targetVM.HardwareProfile.VmSize) to $($desiredVMType.Name)"
            Write-Verbose "$targetVMName $($desiredVMType.Name) has $($desiredVMType.NumberOfCores) vCPU's and $($desiredVMType.MemoryInMB)MB Memory"
            return $desiredVMType.Name
        }
    }
}


function get-vmCounterStats{
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory)]$Data
    )
    $Data = [System.Collections.ArrayList][Double[]]$resultsArray.CounterValue | Sort-Object
    $Stats = $Data | Microsoft.PowerShell.Utility\Measure-Object -Minimum -Maximum -Sum -Average
    if ($Data.Count % 2 -eq 0) {
        $MedianIndex = ($Data.Count / 2) - 1
        $LowerMedian = $Data[$MedianIndex]
        $UpperMedian = $Data[$MedianIndex - 1]
        $Median = ($LowerMedian + $UpperMedian) / 2
    } else {
        $MedianIndex = [math]::Ceiling(($Data.Count - 1) / 2)
        $Median = $Data[$MedianIndex]
    }
    Add-Member -InputObject $Stats -MemberType NoteProperty -Name 'Median' -Value $Median
       
    $Variance = 0
    foreach ($_ in $Data) {
        $Variance += [math]::Pow($_ - $Stats.Average, 2) / $Stats.Count
    }
    $Variance /= $Stats.Count
    Add-Member -InputObject $Stats -MemberType NoteProperty -Name 'Variance' -Value $Variance

    $StandardDeviation = [math]::Sqrt($Stats.Variance)
    Add-Member -InputObject $Stats -MemberType NoteProperty -Name 'StandardDeviation' -Value $StandardDeviation
      
    $Percentile1Index = [math]::Ceiling(1 / 100 * $Data.Count)
    $Percentile5Index = [math]::Ceiling(5 / 100 * $Data.Count)
    $Percentile10Index = [math]::Ceiling(10 / 100 * $Data.Count)
    $Percentile25Index = [math]::Ceiling(25 / 100 * $Data.Count)
    $Percentile75Index = [math]::Ceiling(75 / 100 * $Data.Count)
    $Percentile90Index = [math]::Ceiling(90 / 100 * $Data.Count)
    $Percentile95Index = [math]::Ceiling(95 / 100 * $Data.Count)
    $Percentile99Index = [math]::Ceiling(99 / 100 * $Data.Count)
    Add-Member -InputObject $Stats -MemberType NoteProperty -Name 'Percentile1' -Value $Data[$Percentile1Index]
    Add-Member -InputObject $Stats -MemberType NoteProperty -Name 'Percentile5' -Value $Data[$Percentile5Index]
    Add-Member -InputObject $Stats -MemberType NoteProperty -Name 'Percentile10' -Value $Data[$Percentile10Index]
    Add-Member -InputObject $Stats -MemberType NoteProperty -Name 'Percentile25' -Value $Data[$Percentile25Index]
    Add-Member -InputObject $Stats -MemberType NoteProperty -Name 'Percentile75' -Value $Data[$Percentile75Index]
    Add-Member -InputObject $Stats -MemberType NoteProperty -Name 'Percentile90' -Value $Data[$Percentile90Index]
    Add-Member -InputObject $Stats -MemberType NoteProperty -Name 'Percentile95' -Value $Data[$Percentile95Index]
    Add-Member -InputObject $Stats -MemberType NoteProperty -Name 'Percentile99' -Value $Data[$Percentile99Index]

    Return $Stats
}

function set-vmRightSize{
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory)][String]$targetVMName,
        [Parameter(Mandatory)][Guid]$workspaceId, #workspace GUID where perf data is stored (use Get-AzOperationalInsightsWorkspace to find this)
        $domain, #if your machines are domain joined, enter the domain name here
        [Int]$maintenanceWindowStartHour, #start hour of maintenancewindow in military time UTC (0-23)
        [Int]$maintenanceWindowLengthInHours, #length of maintenance window in hours (round up if needed)
        [ValidateSet(0,1,2,3,4,5,6)][Int]$maintenanceWindowDay, #day on which the maintenance window starts (UTC) where 0 = Sunday and 6 = Saturday
        [String]$region = "westeurope", #you can find yours using Get-AzLocation | select Location
        [Int]$measurePeriodHours = 152, #lookback period for a VM's performance while it was online, this is used to calculate the optimum. It is not recommended to size multiple times in this period!
        [Switch]$Force, #shuts a VM down to resize it if it detects the VM is still running when you run this command
        [Switch]$Boot, #after resizing, by default a VM stays offline. Use -Boot to automatically start if after resizing
        [Switch]$WhatIf #best used together with -Verbose. Causes the script not to modify anything, just to log what it would do
    )
    try{
        Write-Verbose "$targetVMName getting metadata"
        $vm = Get-AzVM -Name $targetVMName -Status
        Write-Verbose "$targetVMName calculating optimal size"
        $optimalSize = get-vmRightSize -targetVMName $targetVMName -workspaceId $workspaceId -maintenanceWindowStartHour $maintenanceWindowStartHour -maintenanceWindowLengthInHours $maintenanceWindowLengthInHours -maintenanceWindowDay $maintenanceWindowDay -region $region -measurePeriodHours $measurePeriodHours
        if($optimalSize -eq $vm.HardwareProfile.VmSize){
            Write-Verbose "$targetVMName already at optimal size"
            return $False
        }else{
            Write-Verbose "$targetVMName resizing from $($vm.HardwareProfile.VmSize) to $optimalSize ..."
            set-vmToSize -vm $vm -newSize $optimalSize -Force:$Force.IsPresent -Boot:$Boot.IsPresent -WhatIf:$WhatIf.IsPresent
        }
    }catch{
        Write-Error $_
        return $False
    }
}