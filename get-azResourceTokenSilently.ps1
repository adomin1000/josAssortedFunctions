function get-azTokenSilently{
    Param(
        $refreshTokenCachePath=(Join-Path $env:APPDATA -ChildPath "azRfTknCache.cf"),
        $refreshToken,
        $tenantId,
        [Parameter(Mandatory=$true)]$userUPN,
        $resource="https://graph.microsoft.com"
    )

    $strCurrentTimeZone = (Get-WmiObject win32_timezone).StandardName
    $TZ = [System.TimeZoneInfo]::FindSystemTimeZoneById($strCurrentTimeZone)
    [datetime]$origin = '1970-01-01 00:00:00'

    if($refreshToken){
        try{
            $response = (Invoke-RestMethod "https://login.windows.net/$tenantId/oauth2/token" -Method POST -Body "grant_type=refresh_token&refresh_token=$refreshToken" -ErrorAction Stop)
            $refreshToken = $response.refresh_token
            $AccessToken = $response.access_token
        }catch{
            Write-Output "Failed to use cached refresh token, need interactive login or token from cache"   
            $refreshToken = $False 
        }
    }

    if([System.IO.File]::Exists($refreshTokenCachePath) -and !$refreshToken){
        try{
            $refreshToken = Get-Content $refreshTokenCachePath -ErrorAction Stop | ConvertTo-SecureString -ErrorAction Stop
            $refreshToken = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($refreshToken)
            $refreshToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($refreshToken)
            $response = (Invoke-RestMethod "https://login.windows.net/$tenantId/oauth2/token" -Method POST -Body "grant_type=refresh_token&refresh_token=$refreshToken" -ErrorAction Stop)
            $refreshToken = $response.refresh_token
            $AccessToken = $response.access_token
        }catch{
            Write-Output "Failed to use cached refresh token, need interactive login"
            $refreshToken = $False
        }
    }

    #full login required
    if(!$refreshToken){
        Write-Verbose "No cache file exists and no refresh token supplied, perform interactive logon"
        if ([Environment]::UserInteractive) {
            foreach ($arg in [Environment]::GetCommandLineArgs()) {
                # Test each Arg for match of abbreviated '-NonInteractive' command.
                if ($arg -like '-NonI*') {
                    Throw "Interactive login required, but script is not running interactively. Run once interactively or supply a refresh token with -refreshToken"
                }
            }
        }
        if(!(Get-Module -Name "Az.Accounts")){
            Throw "Az.Accounts module not installed!"
        }
        Write-Verbose "Calling Login-AzAccount"
        if($tenantId){
            $Null = Login-AzAccount -Tenant $tenantId -ErrorAction Stop
        }else{
            $Null = Login-AzAccount -ErrorAction Stop
        }

        #if login worked, we should have a Context
        $context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
        if($context){
            $string = [System.Text.Encoding]::Default.GetString($context.TokenCache.CacheData)
            $marker = 0
            $tokens = @()
            while($true){
                $marker = $string.IndexOf("https://",$marker)
                if($marker -eq -1){break}
                $uri = $string.SubString($marker,$string.IndexOf("RefreshToken",$marker)-4-$marker)
                $marker = $string.IndexOf("RefreshToken",$marker)+15
                if($string.Substring($marker+2,4) -ne "null"){
                    $refreshtoken = $string.SubString($marker,$string.IndexOf("ResourceInResponse",$marker)-3-$marker)
                    $marker = $string.IndexOf("ExpiresOn",$marker)+31
                    $expirydate = $string.SubString($marker,$string.IndexOf("OffsetMinutes",$marker)-6-$marker)
                    $tokens += [PSCustomObject]@{"expiresOn"=[System.TimeZoneInfo]::ConvertTimeFromUtc($origin.AddMilliseconds($expirydate), $TZ);"refreshToken"=$refreshToken;"target"=$uri}
                }
            }       
            $refreshToken = @($tokens | Where-Object {$_.expiresOn -gt (get-Date)} | Sort-Object -Descending -Property expiresOn | select refreshToken)[0].refreshToken
            $response = (Invoke-RestMethod "https://login.windows.net/$tenantId/oauth2/token" -Method POST -Body "grant_type=refresh_token&refresh_token=$refreshToken" -ErrorAction Stop)
            $refreshToken = $response.refresh_token
            $AccessToken = $response.access_token
        }else{
            Throw "Login-AzAccount failed, cannot continue"
        }
    }

    if($refreshToken){
        #update cache file
        Set-Content -Path $refreshTokenCachePath -Value ($refreshToken | ConvertTo-SecureString -AsPlainText -Force -ErrorAction Stop | ConvertFrom-SecureString -ErrorAction Stop) -Force -ErrorAction Continue | Out-Null
    }else{
        Throw "No refresh token found in cache and no valid refresh token passed or received after login, cannot continue"
    }

    if($AccessToken){
        $null = Login-AzAccount -AccountId $userUPN -AccessToken $AccessToken
        $context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
        $resourceToken = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id.ToString(), $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, "https://graph.microsoft.com").AccessToken
    }else{
        Throw "Failed to get fresh access token with refresh token, cannot continue"
    }

    if($resourceToken){
        return $resourceToken
    }else{
        Throw "Failed to translate to correct resource token, cannot continue"
    }
}