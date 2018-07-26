function get-azureRMADAppPermissionsReport(){
    #Requires -Modules ImportExcel
    <#
      .SYNOPSIS
      Retrieve all permissions an Azure AD application has set
      .DESCRIPTION
      
      .EXAMPLE
      $permissions = get-azureRMADAppPermissionsReport -token (get-azureRMtoken -username jos.lieben@xxx.com -password password01) -reportPath c:\temp\report.xlsx
      .PARAMETER token
      a valid Azure RM token retrieved through my get-azureRMtoken function
      .PARAMETER reportPath
      Full path to desired report file, if unspecified, will write to temp
      .NOTES
      filename: get-azureRMADAppPermissionsReport.ps1
      author: Jos Lieben
      blog: www.lieben.nu
      created: 26/7/2018
    #>
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true)]$token,
        $reportPath=(Join-Path $Env:TEMP -ChildPath "azureRMAppPermissionsReport.xlsx")
    )
    $applications = get-azureRMADAllApplications -token $token
    $userConsent = @()
    $adminConsent = @()
    $userToApp = @{}
    $count = 0
    foreach($application in $applications){
        $permissions = get-azureRMADAppPermissions -token $token -appId $application.objectId
        if($permissions.admin){
            $applications[$count] | Add-Member NoteProperty -Name AdminHasConsented -Value $True
        }else{
            $applications[$count] | Add-Member NoteProperty -Name AdminHasConsented -Value $False
        }
        if($permissions.user){
            $applications[$count] | Add-Member NoteProperty -Name UsersHaveConsented -Value $True
        }else{
            $applications[$count] | Add-Member NoteProperty -Name UsersHaveConsented -Value $False
        }
        $applications[$count] | Add-Member NoteProperty -Name Permissions -Value $permissions
        $count++
    }

    $applications | Select displayName,publisherName,accountEnabled,appRoleAssignmentRequired,isApplicationVisible,AdminHasConsented,UsersHaveConsented,appDisplayName,homePageUrl,ssoConfiguration,appRoles,tags,userAccessUrl | Export-Excel -workSheetName "Applications" -path $reportPath -ClearSheet -TableName "Applications" -AutoSize
    
    foreach($application in ($applications | Where-Object {$_.AdminHasConsented})){
        foreach($permission in $application.permissions.admin){
            $adminConsent += [PSCustomObject]@{
            "appId"=$application.appId
            "appDisplayName"=$application.displayName
            "Resource"=$permission.resourceName
            "Permission"=$permission.permissionId
            "RoleOrScopeClaim"=$permission.roleOrScopeClaim
            "Description"=$permission.permissionDescription}
        }
    }

    $adminConsent | Export-Excel -workSheetName "AdminConsentedRights" -path $reportPath -ClearSheet -TableName "AdminConsentedRights" -AutoSize

    foreach($application in ($applications | Where-Object {$_.UsersHaveConsented})){
        foreach($permission in $application.permissions.user){
            $userConsent += [PSCustomObject]@{
            "appId"=$application.appId
            "appDisplayName"=$application.displayName
            "Resource"=$permission.resourceName
            "Permission"=$permission.permissionId
            "RoleOrScopeClaim"=$permission.roleOrScopeClaim
            "Description"=$permission.permissionDescription}

            foreach($principal in $permission.principalIds){
                if(!$userToApp.$principal){
                    $userToApp.$principal = @()
                }
                $userToApp.$principal += [PSCustomObject]@{
                "appId"=$application.appId
                "appDisplayName"=$application.displayName
                "Resource"=$permission.resourceName
                "Permission"=$permission.permissionId
                "RoleOrScopeClaim"=$permission.roleOrScopeClaim
                "Description"=$permission.permissionDescription}
            }
        }
    }
    
    $userConsent | Export-Excel -workSheetName "UserConsentedRights" -path $reportPath -ClearSheet -TableName "UserConsentedRights" -AutoSize

    $userToAppTranslated = @()
    foreach($user in $userToApp.Keys){
        try{
            $userInfo = get-azureRMADUserInfo -token $token -userGuid $user
        }catch{
            $userInfo = [PSCustomObject]@{
                "UserDisplayName"=$user
                "UserPrincipalName"=$NULL
                "accountEnabled"=$NULL
                "appId"=$NULL
                "appDisplayName"=$NULL
                "Resource"=$NULL
                "Permission"=$NULL
                "RoleOrScopeClaim"=$NULL
                "Description"="FAILED TO RETRIEVE DATA FOR THIS USER GUID: $user"}
        }
        $userToAppTranslated += [PSCustomObject]@{
        "UserDisplayName"=$userInfo.displayName
        "UserPrincipalName"=$userInfo.userPrincipalName
        "accountEnabled"=$userInfo.accountEnabled
        "appId"=$user.appId
        "appDisplayName"=$user.appDisplayName
        "Resource"=$user.Resource
        "Permission"=$user.Permission
        "RoleOrScopeClaim"=$user.RoleOrScopeClaim
        "Description"=$user.Description}
    }
    
    $userToAppTranslated | Export-Excel -workSheetName "UserToAppMapping" -path $reportPath -ClearSheet -TableName "UserToAppMapping" -AutoSize

}