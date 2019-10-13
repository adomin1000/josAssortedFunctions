<#
    .SYNOPSIS
    report on and fix files and folders that are above a certain path length in any sharepoint, onedrive for business or teams site in Office 365
    .DESCRIPTION
    Certain Office tools (the older the worse) cannot access Office 365 files if they exceed a certain path length. This script helps you assess which files are affected so you can remediate proactively.
    The script can scan for all or specific file types. Certain modules are required and auto installed if you have sufficient permissions.

    .EXAMPLE
    .\fix-FilesWithLongPathsInOffice365.ps1 -specialFileExtensions ".xlsx,.xls" -maxPathLengthSpecialFiles 218 -maxPathLengthNormalFiles 256 -tenantName lieben -csvPath "c:\temp\result.csv"

    .PARAMETER csvPath
    Required full path to where you want the script to write a CSV file to. Also used to read data from if it already exists

    .PARAMETER specialFileExtensions
    Specify a comma seperated list of file extensions for with to apply the maxPathLengthSpecialFiles parameter
    Example: .xlsx,.xls

    .PARAMETER maxPathLengthSpecialFiles
    Minimum length of the file path to include it in the report, including https://tenant.sharepoint.com
    Example: 218

    .PARAMETER maxPathLengthNormalFiles
    Minimum length of the folder or file path to include it in the report, including https://tenant.sharepoint.com
    Example: 256

    .PARAMETER tenantName
    Name of your Office 365 tenant (https://TENANTA.sharepoint.com) = TENANTA
    Example: tenanta

    .PARAMETER useMFA
    Switch parameter, if the admin account you plan to use is MFA enabled, supply -useMFA to this script

    .PARAMETER specificSiteUrls
    Comma seperated list of sites to process. If not specified ALL sites are processed (including Onedrive for Business and Microsoft Teams)

    .PARAMETER specificDocumentLibraryUrls 
    Comma seperated list of document libraries to process.
    Not used if specificSiteUrls is supplied
    Supply only the SITE url with the document library, no additional URL components should be present.
    GOOD example: https://onedrivemapper.sharepoint.com/sites/SITE/Shared%20Documents
    WRONG example: https://onedrivemapper.sharepoint.com/sites/SITE/Shared%20Documents/Forms/AllItems.aspx

    .NOTES
    filename: fix-FilesWithLongPathsInOffice365.ps1
    author: Jos Lieben
    blog: www.lieben.nu
    created: 13/10/2019

    Example script to parse a CSV file for character types (to find ODD characters that may not be correctable by script):
    $csv = import-csv "C:\temp\SharedDocuments.csv" -Encoding UTF8
    $uniqueChars = @{}
    foreach($item in $csv){
        for($i=7;$i -lt $item."Item full URL".Length;$i++){
            if(!$uniqueChars.$($item."Item full URL"[$i])){
                $uniqueChars.$($item."Item full URL"[$i]) = 1
            }else{
                $uniqueChars.$($item."Item full URL"[$i]) += 1
            }
        }
    }

    $uniqueChars.GetEnumerator() |
        Select-Object -Property Key,Value |
            Export-Csv -NoTypeInformation -Path c:\temp\test.csv -Encoding UTF8
#>
Param(
    [String]$specialFileExtensions=".xlsx,.xls",
    [Int]$maxPathLengthSpecialFiles=218,
    [Int]$maxPathLengthNormalFiles=256,
    [Int]$EditorWidth=1200,
    [Int]$EditorHeight=800,
    [Parameter(Mandatory=$true)][String]$tenantName,
    [Parameter(Mandatory=$true)]$csvPath,
    [String]$specificSiteUrls=$Null,
    [String]$specificDocumentLibraryUrls=$Null,
    [Switch]$useMFA,
    [Switch]$WhatIf
)

if($EditorWidth -le 900){
    $EditorWidth = 900
}

if($EditorHeight -le 500){
    $EditorHeight = 500
}

$adminUrl = "https://$tenantName-admin.sharepoint.com"
$baseUrl = "https://$tenantName.sharepoint.com"

if($specialFileExtensions.Length -gt 0){
    [Array]$specialFileExtensions = $specialFileExtensions.Split(",",[System.StringSplitOptions]::RemoveEmptyEntries)
}else{
    $specialFileExtensions = $Null
}

if($specificSiteUrls.Length -gt 0){
    [Array]$specificSiteUrls = $specificSiteUrls.Split(",",[System.StringSplitOptions]::RemoveEmptyEntries)
}else{
    [Array]$specificSiteUrls = @()
}

if($specificDocumentLibraryUrls.Length -gt 0){
    [Array]$specificDocumentLibraryUrls = $specificDocumentLibraryUrls.Split(",",[System.StringSplitOptions]::RemoveEmptyEntries)
}else{
    [Array]$specificDocumentLibraryUrls = @()
}

function Load-Module{
    Param(
        $Name
    )
    Write-Output "Checking for $Name Module"
    $module = Get-Module -Name $Name -ListAvailable
    if ($null -eq $module) {
        write-Output "$Name Powershell module not installed...trying to Install, this will fail in an unelevated session"
        #Check if elevated
        If (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")){   
            Write-Output "Please restart this script in elevated mode!"
            Read-Host "Press any key to continue"
            Exit
        }
        try{
            Install-Module $Name -SkipPublisherCheck -Force -Confirm:$False
            Write-Output "$Name module installed!"
        }catch{
            write-Error "Install by running 'Install-Module $Name' from an elevated PowerShell prompt"
            Throw
        }
    }else{
        write-output "Module already installed"
    }
    try{
        Write-Output "loading module"
        Import-Module $Name -DisableNameChecking -Force -NoClobber
        Write-Output "module loaded"
    }catch{
        Write-Output "failed to load module"
    }
}

function EditCSV { 
    $x = 100
    $y = 100
    $Width = $EditorWidth
    $Height= $EditorHeight
    #Windows Assemblies
    [reflection.assembly]::loadwithpartialname("System.Windows.Forms") | Out-Null 
    [reflection.assembly]::loadwithpartialname("System.Drawing") | Out-Null 
    [reflection.assembly]::loadwithpartialname("System.Data") | Out-Null 
    try{$owner = New-Object Win32Window -ArgumentList ([System.Diagnostics.Process]::GetCurrentProcess().MainWindowHandle)}catch{$Null}
    #LoadCSV
    #Variables MUST have script scope to allow form to see them
    $script:CsvData = import-csv $csvPath -Encoding UTF8 -Delimiter "," | Sort-Object -Descending -Property {[int]$_."Deepest Child Path Depth"}
    $script:dt = new-object System.Data.DataTable
    $columns = $CsvData[0].psobject.Properties | Select-Object name -ExpandProperty name
    $columns | ForEach-Object {
        if(@("Deepest Child Path Depth","Delta","Path Leaf Length","Path Parent Length","Path Total Length") -contains $_){
            [void]$script:dt.columns.add($_,"int")
        }else{
            [void]$script:dt.columns.add($_,"string")
        }
    }
    $CsvData | ForEach-Object {
         $currentRow = $_
 
         $dr = $script:dt.NewRow()
         $columns | ForEach-Object {
            $dr.$_ = $currentRow.$_ 
         }
         $script:dt.Rows.Add($dr)
    }

    #Helper Functions
    function paint($form, $ctrl, $TablIndex, $name, $Text, $x, $y, $Width, $Height){
        try{$form.Controls.Add($ctrl)                             }catch{}
        try{$ctrl.TabIndex = $TablIndex                           }catch{}
        try{$ctrl.Text     = $Text                                }catch{}
        try{$ctrl.name     = $name                                }catch{}
        try{$ctrl.Location = System_Drawing_Point $x     $y       }catch{}
        try{$ctrl.size     = System_Drawing_Size  $Width $Height  }catch{}
        try{$ctrl.DataBindings.DefaultDataSourceUpdateMode = 0    }catch{}
        $ctrl
    }
    function System_Drawing_Point($x,     $Y)     {$_ = New-Object System.Drawing.Point; $_.x     = $X;     $_.Y      = $Y;      $_}
    function System_Drawing_Size( $Width, $Height){$_ = New-Object System.Drawing.Size;  $_.Width = $Width; $_.Height = $Height; $_}

    #Paint Form
    $form1      = paint $null (New-Object System.Windows.Forms.Form) $null 'form1' "Lieben Consultancy" $x $y $Width $Height
                $form1.add_Load({
                    $dataGrid1.DataSource = $script:dt; 
                    $dataGrid1.AllowSorting = $True 
                    $dataGrid1.AutoSize = $True
                    $form1.refresh() 
                }) 
    $label1     = paint $form1 (New-Object System.Windows.Forms.Label) $null "label1" "Click Recalculate to recalculate all path lengths, use the other buttons to choose to make changes to your tenant" 12 13 ($width-100) 23
                $label1.Font = New-Object System.Drawing.Font("Microsoft Sans Serif",9.75,2,3,0) 
                $label1.ForeColor = [System.Drawing.Color]::FromArgb(255,0,102,204) 
    $buttonSave = paint $form1 (New-Object System.Windows.Forms.Button) 1 "button1" "Recalculate path lengths" ($width-700) ($Height-75) 200 23 
                $buttonSave.UseVisualStyleBackColor = $True 
                $buttonSave.add_Click({ 
                    $script:EditorResult = 1
                    $Form1.Close()
                }) 
    $buttonCommit = paint $form1 (New-Object System.Windows.Forms.Button) 2 'button2' 'Commit changes to Tenant' ($width-480) ($Height-75) 250 23 
                $buttonCommit.UseVisualStyleBackColor = $True 
                $buttonCommit.add_Click({ 
                    $script:EditorResult = 2
                    $Form1.Close()
                }) 
    $buttonClose = paint $form1 (New-Object System.Windows.Forms.Button) 2 'button3' 'Save without committing' ($width-220) ($Height-75) 170 23 
                $buttonClose.UseVisualStyleBackColor = $True 
                $buttonClose.add_Click({ 
                    $script:EditorResult = 3
                    $Form1.Close()
                }) 
    $dataGrid1 = paint $form1 (New-Object System.Windows.Forms.DataGrid) 0 "dataGrid0" $Null 12 40 ($width-40) ($Height-125) 
                $dataGrid1.HeaderForeColor = [System.Drawing.Color]::FromArgb(255,0,0,0) 
                
                $dataGrid1.AutoSize=$True
                $dataGrid1.AllowSorting=$True
    
    #Show and Wait till complete
    $form1.ShowDialog($owner)| Out-Null 

    #Save CSV
    $script:dt | export-csv -NoTypeInformation -path $csvPath -Force -Encoding UTF8 -Delimiter ","
} 

function doTheSharepointStuff{
    Param(
        $mode=0   
    )
    try{
        Load-Module SharePointPnPPowerShellOnline
        if(!$useMFA -and !$script:Credential){
            $script:Credential = Get-Credential
        }
        if($useMFA){
            Connect-PnPOnline $adminUrl -UseWebLogin
        }else{
            Connect-PnPOnline $adminUrl -Credentials $Credential
        }
    }catch{
        Throw "Could not connect to SpO online, check your credentials"
    }

    #Load CSV data if mode 1 is specified into a highly efficient hashtable for ultra-fast lookups
    if($mode -eq 1){
        try{
            $Script:modifiedReportRows = @{}
            $Script:modifiedReportRows.Raw = @(import-csv -Path $csvPath -Delimiter "," -Encoding UTF8 | Where-Object {$_."Item ID".Length -gt 0})
            [System.Collections.Generic.List[psobject]]$Script:modifiedReportRows.Results = @()
            [System.Collections.Generic.Dictionary[guid,int]]$Script:modifiedReportRows.FastSearch = @{}
            $counter = 0
            $Script:modifiedReportRows.Raw | ForEach-Object {
                if($_){
                    $Script:modifiedReportRows.Results.Add($_)  
                    $Script:modifiedReportRows.FastSearch.Add($_."Item ID",$counter)
                    $counter++
                }
            }
       
            if($Script:modifiedReportRows.Results.Count -lt 1){
                Throw "there is no data in the CSV file"
            }
            Write-Output "$($Script:modifiedReportRows.Results.Count) rows imported from $($csvPath)"
        }catch{
            Throw "CSV file will not be used to correct data in SpO"
            $mode = 0
        }
    }

    $targets = @()

    if($specificSiteUrls.Count -gt 0){
        Write-Output "Running for specific Sharepoint, Onedrive or Team sites: "
        Write-Output $specificSiteUrls
        foreach($site in $specificSiteUrls){
            $targets += [PSCustomObject]@{"TargetUrl"=$site;"Type"="site";}  
        }
    }elseif($specificDocumentLibraryUrls.Count -gt 0){
        Write-Output "Running for specific document libraries: "
        Write-Output $specificDocumentLibraryUrls  
        foreach($library in $specificDocumentLibraryUrls){
            $targets += [PSCustomObject]@{"TargetUrl"=$library;"Type"="library";}  
        }   
    }else{
        Write-Output "Running for all Sharepoint, Onedrive and Team sites"
        #intial discovery phase
        Get-PnPListItem -List DO_NOT_DELETE_SPLIST_TENANTADMIN_AGGREGATED_SITECOLLECTIONS -Fields ID,Title,TemplateTitle,SiteUrl,IsGroupConnected | ForEach-Object {
            if($_.FieldValues.SiteUrl.StartsWith("https")){
                $targets+=[PSCustomObject]@{"TargetUrl"=$_.FieldValues.SiteUrl;"Type"="site";}    
            }
        }
        
        #secondary discovery phase
        foreach($extraSite in (Get-PnPTenantSite -IncludeOneDriveSites | Select-Object Title,Url)){
            if($extraSite.Url.StartsWith("https") -and $targets.TargetUrl -notcontains $extraSite.Url){
                $targets+=[PSCustomObject]@{"TargetUrl"=$extraSite.Url;"Type"="site";} 
            }
        }
        
        #add subsites of any of the discovered sites
        for($targetCount = 0;$targetCount -lt $targets.Count;$targetCount++){
            write-output "Discovering subsites of: $($targets[$targetCount].TargetUrl)"
            try{
                if($useMFA){
                    Connect-PnPOnline $targets[$targetCount].TargetUrl -UseWebLogin
                }else{
                    Connect-PnPOnline $targets[$targetCount].TargetUrl -Credentials $script:Credential
                }
                Get-PnPSubWebs -Recurse | ForEach-Object {
                    if($targets.TargetUrl -notcontains $_.Url){
                        $targets+=[PSCustomObject]@{"TargetUrl"=$_.Url;"Type"="site";} 
                    }        
                }
            }catch{$Null}
        }
        
        $targets = @($targets | Where-Object {-not $_.TargetUrl.EndsWith("/")})
        
        if($targets.Count -le 0){
            Throw "No sites found in your environment!"
        }
    }

    $reportRows = New-Object System.Collections.ArrayList
    for($targetCount = 0;$targetCount -lt $targets.Count;$targetCount++){
        if($targets[$targetCount].type -eq "site"){
            $siteUrl = $targets[$targetCount].TargetUrl
        }else{
            $siteUrl = $targets[$targetCount].TargetUrl.SubString(0,$targets[$targetCount].TargetUrl.LastIndexOf("/"))
            $docLibName = $targets[$targetCount].TargetUrl.SubString($targets[$targetCount].TargetUrl.LastIndexOf("/")+1)
        }
        Write-Progress -Activity "$($targetCount+1)/$($targets.Count) $($targets[$targetCount].TargetUrl)" -Status "Retrieving lists in site..." -PercentComplete 0
        Write-Output "Processing $($targets[$targetCount].TargetUrl)"
        if($useMFA){
            Connect-PnPOnline $siteUrl -UseWebLogin
        }else{
            Connect-PnPOnline $siteUrl -Credentials $script:Credential
        }
        $lists = @(Get-PnPList -Includes BaseType,BaseTemplate,ItemCount | Where-Object {($_.BaseTemplate -eq 101 -or $_.BaseTemplate -eq 700) -and $_.ItemCount -gt 0})
        for($listCount = 0;$listCount -lt $lists.Count;$listCount++) {
            if($targets[$targetCount].type -eq "library"){
                if($lists[$listCount].RootFolder.ServerRelativeUrl.EndsWith($([System.Web.HttpUtility]::UrlDecode($docLibName)))){
                    #correct list selected, proceed
                }else{
                    continue
                }
            }
            Write-Output "Detected document library $($lists[$listCount].Title) with Id $($lists[$listCount].Id.Guid) and Url $baseUrl$($lists[$listCount].RootFolder.ServerRelativeUrl), processing $($lists[$listCount].ItemCount) items..."
            Write-Progress -Activity "$($targetCount+1)/$($targets.Count) site $($targets[$targetCount].TargetUrl)" -Status "Retrieving items for list $($lists[$listCount].Title)" -PercentComplete 0
            $items = $Null
            $items = Get-PnPListItem -List $lists[$listCount] -PageSize 2000
            $itemCount = 0
            foreach($item in $items){
                $itemCount++
                try{$percentage = ($itemCount/$($lists[$listCount].ItemCount)*100)}catch{$percentage=1}
                Write-Progress -Activity "$($targetCount+1)/$($targets.Count) site $($targets[$targetCount].TargetUrl)" -Status "Processing list $($lists[$listCount].Title) item $itemCount of $($lists[$listCount].ItemCount)" -PercentComplete $percentage
                $importCSVInfo = "N/A"
                $processRename = $False

                $localMaxPathLength = $maxPathLengthNormalFiles

                #Determine the file type and skip if a file type filter is used and it matches
                if($item.FileSystemObjectType -ne "Folder"){
                    try{
                        $fileType = $Null
                        $fileType = $item.FieldValues.FileRef.Substring($item.FieldValues.FileRef.LastIndexOf("."))
                        if($fileType -and $specialFileExtensions -contains $fileType){
                            $localMaxPathLength = $maxPathLengthSpecialFiles    
                        }
                    }catch{
                        $fileType = "Unknown"
                    }
                }else{
                    $fileType = "N/A"
                }

                #skip any files that are below the max path length. Do include folders, as they may need to be renamed through the CSV
                if("$baseUrl$($item.FieldValues.FileRef)".Length -lt $localMaxPathLength){
                    if($item.FileSystemObjectType -ne "Folder"){
                        continue
                    }
                }

                #Determine if a rename is required for a file/folder
                if($mode -eq 1){
                    $guid = $item.FieldValues.GUID.Guid
                    try{
                        [Array]$modifiedReportRow = @()
                        [Array]$modifiedReportRow = @($Script:modifiedReportRows.Results[$Script:modifiedReportRows.FastSearch[$guid]])
                    }catch{
                        [Array]$modifiedReportRow = @()
                    }
                    if($modifiedReportRow.Count -gt 1){
                        Write-Error "Error: more than 1 item with the same GUID found in the CSV file with modifications for $($item.FieldValues.FileRef) with GUID $($item.FieldValues.GUID.Guid)" -ErrorAction Continue
                        $importCSVInfo = "Error: more than 1 item with the same GUID found in the CSV file with modifications for $($item.FieldValues.FileRef) with GUID $($item.FieldValues.GUID.Guid)"
                        continue
                    }elseif($modifiedReportRow.Count -eq 0){
                        write-output "found zero hits in the CSV for $($item.FieldValues.FileRef) with GUID $($item.FieldValues.GUID.Guid)"
                        continue
                    }else{
                        if((Split-Path $item.FieldValues.FileRef -Leaf) -ne $modifiedReportRow."Item Name"){
                            try{
                                $item = Get-PnPListItem -List $lists[$listCount] -Id $item.FieldValues.ID
                                $processRename = $True
                            }catch{
                                write-output "Error: item was found in CSV, but could not retrieve the item in Sharepoint Online"
                                $importCSVInfo = "Error: item was found in CSV, but could not retrieve the item in Sharepoint Online"
                                continue
                            }
                        }
                    }
                }

                $itemName = Split-Path $item.FieldValues.FileRef -Leaf
                $itemFullUrl = "$baseUrl$($item.FieldValues.FileRef)"

                #Process rename if applicable
                if($mode -eq 1 -and $processRename){
                    try{
                        if($item.FileSystemObjectType -ne "Folder"){
                            if(!$WhatIf){
                                Rename-PnPFile -ServerRelativeUrl $item.FieldValues.FileRef -TargetFileName $modifiedReportRow."Item Name" -Force -Confirm:$False -ErrorAction Stop
                            }
                        }else{
                            $folderName = $item.FieldValues.FileRef.SubString($lists[$listCount].ParentWebUrl.Length+1)
                            if(!$WhatIf){
                                Rename-PnPFolder -Folder $folderName -TargetFolderName $modifiedReportRow."Item Name" -ErrorAction Stop
                            }
                        }
                        Write-Output "Renamed $($item.FileSystemObjectType) $itemName to $($modifiedReportRow."Item Name")"
                        $importCSVInfo = "Renamed $($item.FileSystemObjectType) $itemName to $($modifiedReportRow."Item Name")"
                        $itemName = $modifiedReportRow."Item Name"
                    }catch{
                        Write-Error "Failed to rename $itemName to $($modifiedReportRow."Item Name")" -ErrorAction Continue
                        $importCSVInfo = "Failed to rename file/folder because of $($_.Exception)"        
                    }
                }
                       

                $ObjectProperties = [Ordered]@{
                    "Delta" = $localMaxPathLength-$itemFullUrl.Length
                    "Deepest Child Path Depth" = $itemFullUrl.Length
                    "Path Total Length" = $itemFullUrl.Length
                    "Path Parent Length" = $itemFullUrl.Length-$item.FieldValues.FileLeafRef.Length
                    "Path Leaf Length" = $item.FieldValues.FileLeafRef.Length
                    "Site URL" = $targets[$targetCount].TargetUrl
                    "Item full URL" = $itemFullUrl
                    "Item ID" = $item.FieldValues.GUID.Guid
                    "Item Name" = $item.FieldValues.FileLeafRef
                    "Item extension" = $fileType
                    "Item Type" = $item.FileSystemObjectType
                    "ResultOfChange" = $importCSVInfo
                }
                [void]$reportRows.Add((New-Object -TypeName PSObject -Property $ObjectProperties))
            }
        }
    }

    for($i = 0;$i -lt $reportRows.Count;$i++){
        try{$percentComplete = ($i/$reportRows.Count)*100}catch{$percentComplete=1}
        Write-Progress -Activity "Removing folders from dataset that have no child objects exceeding the maximum path length" -Status "Checking row $i of $($reportRows.Count)" -PercentComplete $percentComplete 
        #enrich the report with additional data and filter out unneccesary data
        if($reportRows[$i]."Item Type" -eq "Folder"){
            $script:removeFolder = $True
            $reportRows | & {
                process{
                    #only process child rows
                    if($_."Item full URL".StartsWith($reportRows[$i]."Item full URL")){
                        if($reportRows[$i]."Deepest Child Path Depth" -lt $_."Item full URL".Length){
                            $reportRows[$i]."Deepest Child Path Depth" = $_."Item full URL".Length
                        }
                        if($_."Item full URL" -ge $maxPathLengthNormalFiles){
                            $script:removeFolder = $False
                        }
                    }
                }
            }
            if($script:removeFolder -and $mode -eq 0){
                $reportRows[$i]."Path Total Length" = $Null
            }
        }    
    }

    if($mode -eq 0){
        $reportRows = $reportRows | Where-Object {$_."Path Total Length"}
    }

    Write-Progress -Activity "$($targetCount+1)/$($targets.Count)" -Status "Exporting to CSV" -PercentComplete 99
    $reportRows | export-csv -Path $csvPath -Force -NoTypeInformation -Encoding UTF8 -Delimiter ","
    Write-Progress -Activity "$($targetCount+1)/$($targets.Count)" -Status "Script complete" -PercentComplete 100 -Completed
    Write-Output "data retrieved and exported to $($csvPath)"
}

#retrieve data from SpO first IF the supplied CSV file does not yet exist
if([System.IO.File]::Exists($csvPath)){
    Write-Output "Found a CSV file in specified path of $($csvPath), assuming you want to edit it"    
}else{
    doTheSharepointStuff -mode 0
}

#do an edit loop and optionally commit changes depending on user input
while($True){
    #start editor first
    EditCSV

    #reprocess the CSV
    Write-Progress -Activity "UseEditor" -Status "Loading CSV file..." -PercentComplete 0
    try{
        $reportRows = @(import-csv -Path $csvPath -Delimiter "," -Encoding UTF8 | Where-Object {$_."Item ID".Length -gt 0})
    }catch{
        Start-Sleep -s 1
        continue
    }
    #loop over any changed rows and rewrite their URL's in the CSV only
    $changedRows = $False
    for($i = 0;$i -lt $reportRows.Count;$i++){
        Write-Progress -Activity "UseEditor" -Status "Checking row $i" -PercentComplete 0
        if($reportRows[$i]."Item full URL".EndsWith($reportRows[$i]."Item Name")){
            continue
        }else{
            $changedRows = $True
            #now change the original URL
            $oldUrlToReplace = $reportRows[$i]."Item full URL"                
            $reportRows[$i]."Item full URL" = "$($reportRows[$i]."Item full URL".SubString(0,$reportRows[$i]."Item full URL".LastIndexOf("/")+1))$($reportRows[$i]."Item Name")" 
                
            #if this is just a file, no need to loop over the whole CSV, only the file had to be renamed
            if($reportRows[$i]."Item Type" -ne "Folder"){
                Write-Output "Replaced $($reportRows[$i]."Item Name") in $oldUrlToReplace in CSV file"
                Continue
            }   
                                
            #row has a change in it, we should process renames in the entire CSV
            Write-Progress -Activity "UseEditor" -Status "Fixing row $i" -PercentComplete 0
            $j=0
            $reportRows | & {
                process{
                    if($_."Item full URL".StartsWith($oldUrlToReplace) -and $_."Item full URL" -ne $reportRows[$i]."Item full URL"){
                        Write-Output "Replaced $($reportRows[$i]."Item full URL") in $($reportRows[$j]."Item full URL") in CSV file"
                        $reportRows[$j]."Item full URL" = $reportRows[$j]."Item full URL".Replace($oldUrlToReplace,$reportRows[$i]."Item full URL")
                    }
                    $j++
                }
            }
        }
    }
        
    if($changedRows){
        #recalculate the path length columns
        for($i = 0;$i -lt $reportRows.Count;$i++){
            $reportRows[$i]."Delta" = $maxPathLengthNormalFiles-$reportRows[$i]."Item full URL".Length
            #for folders, loop over all child items to update the deepest child path depth as well
            if($reportRows[$i]."Item Type" -eq "Folder"){
                Write-Progress -Activity "UseEditor" -Status "Updating child paths for row $i" -PercentComplete 0
                [Int]$reportRows[$i]."Deepest Child Path Depth" = $reportRows[$i]."Item full URL".Length
                $reportRows | & {
                    process{
                        if($_."Item full URL".StartsWith($reportRows[$i]."Item full URL")){
                            if($reportRows[$i]."Deepest Child Path Depth" -lt $_."Item full URL".Length){
                                $reportRows[$i]."Deepest Child Path Depth" = $_."Item full URL".Length
                            }
                        }
                    }
                }
            }else{
                $reportRows[$i]."Deepest Child Path Depth" = $reportRows[$i]."Item full URL".Length
                $fileType = $Null
                $fileType = $reportRows[$i]."Item full URL".Substring($reportRows[$i]."Item full URL".LastIndexOf("."))
                if($fileType -and $specialFileExtensions -contains $fileType){
                    $reportRows[$i]."Delta" = $maxPathLengthSpecialFiles-$reportRows[$i]."Item full URL".Length
                }
            }  
            $reportRows[$i]."Path Total Length" = $reportRows[$i]."Item full URL".Length
            $reportRows[$i]."Path Parent Length" = $reportRows[$i]."Item full URL".Length - $reportRows[$i]."Item Name".Length                         
            $reportRows[$i]."Path Leaf Length" = $reportRows[$i]."Item Name".Length                  
        }
        Write-Progress -Activity "UseEditor" -Status "Exporting to CSV" -PercentComplete 0

        try{
            $reportRows | export-csv -Path $csvPath -Force -NoTypeInformation -Encoding UTF8 -Delimiter ","
        }catch{
            Start-Sleep -s 1
            continue
        }
    }

    if($script:EditorResult -eq 2){
        Write-Output "Committing changes to Sharepoint, Onedrive and/or Teams now..."
        doTheSharepointStuff -mode 1
        Exit
    }

    if($script:EditorResult -eq 3){
        Write-Output "CSV with (potential) changes written to $($csvPath)"
        Exit
    }
}

