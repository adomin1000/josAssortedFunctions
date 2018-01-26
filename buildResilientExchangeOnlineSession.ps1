function buildResilientExchangeOnlineSession {
    Param(
        [Parameter(Mandatory=$true)]$o365Creds,
        $commandPrefix
    )
    Write-Verbose "Connecting to Exchange Online"
    Set-Variable -Scope Global -Name o365Creds -Value $o365Creds -Force
    $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://outlook.office365.com/powershell-liveid/ -Credential $o365Creds -Authentication Basic -AllowRedirection
    Import-PSSession $Session -AllowClobber -DisableNameChecking
    Write-Verbose "Connected to Exchange Online, exporting module..."
    $temporaryModulePath = (Join-Path $Env:TEMP -ChildPath "temporaryEXOModule")
    $res = Export-PSSession -Session $Session -CommandName * -OutputModule $temporaryModulePath -AllowClobber -Force
    $temporaryModulePath = Join-Path $temporaryModulePath -ChildPath "temporaryEXOModule.psm1"
    Write-Verbose "Rewriting Exchange Online module, please wait a few minutes..."
    [String]$newContent
    $found = $False
    (Get-Content $temporaryModulePath) | % {
        if(!$found -and $_.IndexOf("host.UI.PromptForCredential(") -ge 0){
            $line = "-Credential `$global:o365Creds ``"
            if($line){
                $found = $True
            }
        }
        if($line){
            $newContent += $line
            $line=$Null
        }else{
            $newContent += $_
        }
        $newContent += "`r`n"
    }
    $newContent | Out-File -FilePath $temporaryModulePath -Force -Confirm:$False -ErrorAction Stop
    $Session | Remove-PSSession -Confirm:$False
    Write-Verbose "Module rewritten, re-importing..."
    if($commandPrefix){
        Import-Module -Name $temporaryModulePath -Prefix $commandPrefix -DisableNameChecking -WarningAction SilentlyContinue -Force
        Write-Verbose "Module imported, you may now use all Exchange Online commands using $commandPrefix as prefix"
    }else{
        Import-Module -Name $temporaryModulePath -DisableNameChecking -WarningAction SilentlyContinue -Force
        Write-Verbose "Module imported, you may now use all Exchange Online commands"
    }
    return $temporaryModulePath
}
