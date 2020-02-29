#Requires -PSEdition Core
#Requires -Module AWSPowerShell.NetCore

<#
.SYNOPSIS
This is a simple utility script that allows you to retrieve credentials for AWS accounts that are secured using AWS SSO.  Access tokens are cached locally to prevent the need to be pushed to a web browser each time you invoke the script (this is similar behaviour to aws cli v2).
.DESCRIPTION
This is a simple utility script that allows you to retrieve credentials for AWS accounts that are secured using AWS SSO.  Access tokens are cached locally to prevent the need to be pushed to a web browser each time you invoke the script (this is similar behaviour to aws cli v2).

Main usability enhancement compared to aws cli 2 is the abillity to specify the -AllRoleCredentials switch and retrieve all credentials for all accounts that you have access to.  You will be prompted to select a role where you have access to multiple roles for an account, alternatively you can specify a role by using the -RoleName parameter.
.EXAMPLE
    Get-AWSSSORoleCredential -StartUrl "https://mycompany.awsapps.com/start"
.EXAMPLE
    Get-AWSSSORoleCredential -StartUrl "https://mycompany.awsapps.com/start" -AllAccountRoles
.EXAMPLE
    $RoleCredentials = Get-AWSSSORoleCredential -StartUrl "https://mycompany.awsapps.com/start"
    Get-S3Bucket -AccessKey $RoleCredentials.AccessKey -SecretKey $RoleCredentials.SecretKey -SessionToken $RoleCredentials.SessionToken
.EXAMPLE
    $AllRoleCredentials = Get-AWSSSORoleCredential -StartUrl "https://mycompany.awsapps.com/start" -AllAccountRoles
    $AllRoleCredentials | Foreach-Object { Get-S3Bucket -AccessKey $_.AccessKey -SecretKey $_.SecretKey -SessionToken $_.SessionToken }
.INPUTS
    StartUrl (Mandatory)
.OUTPUTS
    AccountId, RoleName, AccessKey, Expiration, SecretKey, SessionToken
.NOTES
    General notes
.COMPONENT
    The component this cmdlet belongs to
.ROLE
    The role this cmdlet belongs to
.FUNCTIONALITY
    The functionality that best describes this cmdlet
#>

function Get-AWSSSORoleCredential {
    param(
        [Parameter(Mandatory=$true)][string]$StartUrl,
        [string]$AccountId,
        [string]$RoleName,
        [switch]$AllAccountRoles,
        [switch]$RefreshAccessToken,
        [string]$Region,
        [switch]$PassThru,
        [string]$ClientName = "default",
        [ValidateSet('public')][string]$ClientType = "public",
        [int]$TimeoutInSeconds = 120,
        [string]$Path = (Join-Path $Home ".awsssohelper")
    )

    try {
        Get-DefaultAWSRegion
    }
    catch {
        Import-Module AWSPowerShell.NetCore
    }

    if ($Region) {
        Set-DefaultAWSRegion $Region
    }
    elseif (($null -eq (Get-DefaultAWSRegion).Region)) {
        throw "No default AWS region configured, specify '-Region <region>' parameter or configure defaults using 'Set-DefaultAWSRegion'."
    }
    else {
        $Region = (Get-DefaultAWSRegion).Region
    }

    $CachePath = Join-Path $Path $ClientName

    if (!(Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory | Out-Null
    }

    if (Test-Path $CachePath) {
        $AccessToken = Get-Content $CachePath -ErrorAction SilentlyContinue | ConvertFrom-Json
        try {
            Get-SSOAccountList -AccessToken $AccessToken.AccessToken  -Credential ([Amazon.Runtime.AnonymousAWSCredentials]::new()) | Out-Null
        }
        catch {
            Write-Host "Cached access token is no longer valid, will need to obtain via SSO."
            $RefreshAccessToken = $true
        }
    }

    if (!$AccessToken) {
        $RefreshAccessToken = $true
    }
    elseif ((New-TimeSpan $AccessToken.LoggedAt (Get-Date)).TotalMinutes -gt $AccessToken.ExpiresIn) {
        $RefreshAccessToken = $true
    }

    if ($RefreshAccessToken) {

        $Client = Register-SSOOIDCClient -ClientName $ClientName -ClientType $ClientType -Credential ([Amazon.Runtime.AnonymousAWSCredentials]::new())
        $DeviceAuth = Start-SSOOIDCDeviceAuthorization -ClientId $Client.ClientId -ClientSecret $Client.ClientSecret -StartUrl $StartUrl -Credential ([Amazon.Runtime.AnonymousAWSCredentials]::new())

        try {
            $Process = Start-Process $DeviceAuth.VerificationUriComplete -PassThru
        }
        catch {
            continue
        }

        if (!$Process.Id) {
            Write-Host "`r`nVisit the following URL to authorise this session:`r`n"
            Write-Host -ForegroundColor White "$($DeviceAuth.VerificationUriComplete)`r`n"
        }
        
        Clear-Variable AccessToken -ErrorAction SilentlyContinue
        Write-Host "Waiting for SSO login via browser..."
        $SSOStart = Get-Date
        
        while (!$AccessToken -and ((New-TimeSpan $SSOStart (Get-Date)).TotalSeconds -lt $TimeoutInSeconds)) {
            try {
                $AccessToken = New-SSOOIDCToken -ClientId $Client.ClientId -ClientSecret $Client.ClientSecret -Code $DeviceAuth.Code -DeviceCode $DeviceAuth.DeviceCode -GrantType "urn:ietf:params:oauth:grant-type:device_code" -Credential ([Amazon.Runtime.AnonymousAWSCredentials]::new())
            }
            catch {
                Write-Host $_.Exception.GetType().FullName, $_.Exception.Message
                Start-Sleep -Seconds 5
            }
        }
        if (!$AccessToken) {
            throw 'No access token obtained, exiting.'
        }
        
        $AccessToken | ConvertTo-Json | Set-Content $CachePath

    }

    if (!$AccountId) {
        try {
            $AWSAccounts = Get-SSOAccountList -AccessToken $AccessToken.AccessToken  -Credential ([Amazon.Runtime.AnonymousAWSCredentials]::new())
        }
        catch {
            throw "Error obtaining account list, access token is invalid.  Try running the command again with '-RefreshAccessToken' parameter."
        }
        if (!$AllAccountRoles) {
            $AccountId = ($AWSAccounts | Sort-Object AccountName | Out-GridView -PassThru -Title "Select AWS Account" | Select-Object -First 1).AccountId
        }
        else {
            $AccountId = $AWSAccounts | Select-Object -ExpandProperty AccountId
        }
    }

    GetAccountRoleCredential -AccountId $AccountId -AccessToken $AccessToken.AccessToken -RoleName $RoleName -AllAccountRoles:$AllAccountRoles

}

function GetAccountRoleCredential {
    param(
        [string[]]$AccountId,
        [string]$AccessToken,
        [string]$RoleName,
        [string]$Region,
        [switch]$AllAccountRoles
    )

    $Credentials = @()

    foreach ($Id in ($AccountId -split ' ')) {
        if (!$RoleName) {
            $SSORoles = Get-SSOAccountRoleList -AccessToken $AccessToken -AccountId $Id -Credential ([Amazon.Runtime.AnonymousAWSCredentials]::new())
            if ($SSORoles.Count -eq 1) {
                $RoleName = ($SSORoles | Select-Object -First 1).RoleName
            }
            else {
                $RoleName = ($SSORoles | Out-GridView -PassThru -Title "Select AWS SSO Role" | Select-Object -First 1).RoleName
            }
        }
    
        $SSORoleCredential = Get-SSORoleCredential -AccessToken $AccessToken -AccountId $Id -RoleName $RoleName -Credential ([Amazon.Runtime.AnonymousAWSCredentials]::new())
    
        $Credentials += [pscustomobject][ordered]@{
            AccountId = $Id;
            RoleName = $RoleName;
            AccessKey = $SSORoleCredential.AccessKeyId;
            Expiration = $SSORoleCredential.Expiration;
            SecretKey = $SSORoleCredential.SecretAccessKey;
            SessionToken = $SSORoleCredential.SessionToken
        }
    
    }

    if ($PassThru) {
        return $Credentials | Select-Object AccessKey,SecretKey,SessionToken
    }

    return $Credentials
}

Export-ModuleMember -Function 'Get-AWSSSORoleCredential'