<#
    .SYNOPSIS
    report on files that exclude a certain path length in any sharepoint or teams site in Office 365
    .DESCRIPTION
    Certain Office tools cannot access Sharepoint Online files if they exceed a certain path length. This script helps you assess which files are affected so you can remediate proactively.
    The script can scan for all or specific file types. Certain modules are required and auto installed if you have sufficient permissions.

    .EXAMPLE
    .\get-FilesWithLongPathsInOffice365.ps1 -fileExtension ".xlsx" -maxPathLength 225 -tenantName ogd -useMFA
    .PARAMETER fileExtension
    If you supply this parameter, only files matching this extension will be reported, if you leave it empty, all files will be reported that exceed the path length you supply
    Example: .xlsx
    .PARAMETER maxPathLength
    Maximum length of the file path, including https://tenant.sharepoint.com
    Example: 220
    .PARAMETER tenantName
    Name of your Office 365 tenant (https://TENANTA.sharepoint.com) = TENANTA
    Example: tenanta
    .PARAMETER useMFA
    Switch parameter, if the admin account you plan to use is MFA enabled, supply -useMFA to this script
    .PARAMETER exportCSV
    By default, script shows data through Out-GridView, if you supply -exportCSV, a CSV file will be written to your temp folder
    .NOTES
    filename: get-FilesWithLongPathsInOffice365.ps1
    author: Jos Lieben
    blog: www.lieben.nu
    created: 19/10/2018
#>
Param(
    [String]$fileExtension,
    [Int]$maxPathLength=218,
    [Parameter(Mandatory=$true)][String]$tenantName,
    [Switch]$useMFA,
    [Switch]$exportCSV
)function Load-Module{    Param(        $Name    )    Write-Output "Checking for $Name Module"
    $module = Get-Module -Name $Name -ListAvailable
    if ($module -eq $null) {
        write-Output "$Name Powershell module not installed...trying to Install, this will fail in an unelevated session"
        #Check if elevated
        If (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")){   
            $arguments = "& '" + $myinvocation.mycommand.definition + "'"
            Start-Process powershell -Verb runAs -ArgumentList $arguments
            Break
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
        Import-Module $Name -DisableNameChecking -Force -NoClobber        Write-Output "module loaded"    }catch{        Write-Output "failed to load module"    }}Load-Module SharePointPnPPowerShellOnlineLoad-Module SharePointPnPPowerShell2016Load-Module SharePointPnPPowerShell2013if(!$useMFA){    $Credential = Get-Credential}if($useMFA){    Connect-PnPOnline "https://$tenantName-admin.sharepoint.com" -UseWebLogin
}else{
    Connect-PnPOnline "https://$tenantName-admin.sharepoint.com" -Credentials $Credential
}

$reportRows = New-Object System.Collections.ArrayList

$sites = Get-PnPListItem -List DO_NOT_DELETE_SPLIST_TENANTADMIN_AGGREGATED_SITECOLLECTIONS -Fields ID,Title,TemplateTitle,SiteUrl,IsGroupConnected
foreach($site in $sites){
    Write-Output "Processing $($site.FieldValues.Title) with url $($site.FieldValues.SiteUrl)"
    if($useMFA){        Connect-PnPOnline $site.FieldValues.SiteUrl -UseWebLogin
    }else{
        Connect-PnPOnline $site.FieldValues.SiteUrl -Credentials $Credential
    }
    $lists = Get-PnPList -Includes BaseTemplate,EntityTypeName
    $lists | where {$_.BaseType -eq "DocumentLibrary" -and ($_.EntityTypeName -eq "Documents" -or $_.EntityTypeName -eq "Shared_x0020_Documents")} | % {
        Write-Output "Detected document library $($_.Title) with Id $($_.Id) and Url $($_.SiteUrl), processing..."
        $items = Get-PnPListItem -List $_
        foreach($item in $items){
            if($item.FileSystemObjectType -eq "Folder"){
                continue #Mapjes skippen we!
            }
            $baseUrl = ($site.FieldValues.SiteUrl -Split("/sites"))[0]
            $relative = $item.FieldValues.FileRef
            if($fileExtension -and $fileExtension.Length -gt 0 -and !$relative.EndsWith($fileExtension)){
                continue #filter by file extension
            }
            $fullPath = "$($baseUrl)$($relative)"
            if($fullPath.Length -lt $maxPathLength){
                continue #filter by max length
            }
            $ObjectProperties = [Ordered]@{
                "Path Length" = $fullPath.Length
                "Site URL" = $baseUrl
                "File" = $item.FieldValues.FileLeafRef
                "Full Path" = $fullPath
            }
            [void]$reportRows.Add((New-Object -TypeName PSObject -Property $ObjectProperties))
        }
    }
}
if($exportCSV){
    $path = Join-Path $Env:TEMP -ChildPath "filesWithLongPaths.csv"
    $reportRows | export-csv -Path $path -Force -NoClobber -NoTypeInformation -Encoding UTF8
    Write-Output "data exported to $path"
}
$reportRows | Out-GridView


