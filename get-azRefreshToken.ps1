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

    #check if cache file exists, otherwise assume full login required
    if(![System.IO.File]::Exists($refreshTokenCachePath) -and !$refreshToken){
        Write-Verbose "No cache file exists and no refresh token supplied, perform interactive logon"
        if(!(Get-Module -Name "Az.Accounts")){
            Throw "Az.Accounts module not installed!"
        }
        Write-Verbose "Calling Login-AzAccount"
        if($tenantId){
            $Null = Login-AzAccount -AccountId $userUPN -Tenant $tenantId -ErrorAction Stop
        }else{
            $Null = Login-AzAccount -AccountId $userUPN -ErrorAction Stop
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
        }else{
            Throw "Login-AzAccount failed, cannot continue"
        }
    }

    if($refreshToken){
        #update cache file
        Set-Content -Path $refreshTokenCachePath -Value ($refreshToken | ConvertTo-SecureString -AsPlainText -Force -ErrorAction Stop | ConvertFrom-SecureString -ErrorAction Stop) -Force -ErrorAction Continue | Out-Null
    }elseif([System.IO.File]::Exists($refreshTokenCachePath)){
        $refreshToken = Get-Content $refreshTokenCachePath -ErrorAction Stop | ConvertTo-SecureString -ErrorAction Stop
        $refreshToken = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($refreshToken)
        $refreshToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($refreshToken)
    }else{
        Throw "No refresh token found in cache and no valid refresh token passed or received after login, cannot continue"
    }

    #get new access token
    $AccessToken = (Invoke-RestMethod "https://login.windows.net/$tenantId/oauth2/token" -Method POST -Body "grant_type=refresh_token&refresh_token=$refreshToken" -ErrorAction Stop).access_token

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
    


            $stringForFile = $string | ConvertTo-SecureString -AsPlainText -Force -ErrorAction Stop | ConvertFrom-SecureString -ErrorAction Stop
        
                $string = Get-Content $filePath -ErrorAction Stop | ConvertTo-SecureString -ErrorAction Stop
        $string = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($string)
        $string = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($string)
        if($string.Length -lt 3){throw "no valid string returned from cache"}
}

Login-AzAccount -Tenant ab773612-c917-4af5-8b81-4a5222340706

$context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
$graphToken = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id.ToString(), $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, $resource).AccessToken

$strCurrentTimeZone = (Get-WmiObject win32_timezone).StandardName
$TZ = [System.TimeZoneInfo]::FindSystemTimeZoneById($strCurrentTimeZone)
[datetime]$origin = '1970-01-01 00:00:00'
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

$token = @($tokens | Where-Object {$_.expiresOn -gt (get-Date)} | Sort-Object -Descending -Property expiresOn | select refreshToken)[0].refreshToken

if($token){
    Write-Host "Stole refresh token from cache!" -ForegroundColor Green
}

$url = "https://login.windows.net/ab773612-c917-4af5-8b81-4a5222340706/oauth2/token"
$body = "grant_type=refresh_token&refresh_token=$token"
$response = Invoke-RestMethod $url -Method POST -Body $body
$AccessToken = $response.access_token

if($AccessToken){
    Write-Host "Got fresh access token using Refresh token" -ForegroundColor Green
}

$null = Login-AzAccount -AccountId "jos@lieben.nu" -AccessToken $AccessToken
$context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
$graphToken = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id.ToString(), $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, "https://graph.microsoft.com").AccessToken

if($graphToken){
    Write-Host "Got graph token!" -ForegroundColor Green
}

<#
$body1 = $body + "&resource=https%3A%2F%2Fvault.azure.net"
$response = Invoke-RestMethod $url -Method POST -Body $body1
$body2 = $body + "&resource=https%3A%2F%2Fgraph.windows.net"
$GraphAccessToken = $response.access_token#>

$tokenPayload = $token.Replace('-', '+').Replace('_', '/')
$tokenPayload.PadRight($tokenPayload.Length % 4,"=")
[System.Text.Encoding]::ASCII.GetString([System.Convert]::FromBase64String($tokenPayload)) | ConvertFrom-Json