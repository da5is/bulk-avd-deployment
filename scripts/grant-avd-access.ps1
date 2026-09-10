<#
.SYNOPSIS
    Grants a user AVD desktop access by adding them to the environment's access group.

.DESCRIPTION
    Convenience wrapper around the manual "add a user, then sync" workflow: adds the given
    user to the sg-avd-<env> Entra ID security group, then runs the postprovision hook
    (avd-access-group.ps1 -Action Sync) so the new member is immediately materialized as a
    direct role assignment and shows up in the portal's session host "Assign" picker.

.PARAMETER UserPrincipalName
    UPN (or object ID) of the user to grant access to. Prompted for if not supplied.

.PARAMETER EnvironmentName
    azd environment name. Defaults to the current azd environment (`azd env get-value
    AZURE_ENV_NAME`).

.EXAMPLE
    ./scripts/grant-avd-access.ps1 -UserPrincipalName user@contoso.com

.EXAMPLE
    ./scripts/grant-avd-access.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$UserPrincipalName,
    [string]$EnvironmentName
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "[grant-avd-access] $Message" }

try {
    if (-not $EnvironmentName) {
        $EnvironmentName = azd env get-value AZURE_ENV_NAME 2>$null
    }
    if (-not $EnvironmentName) {
        throw 'Could not determine the azd environment name. Pass -EnvironmentName or run `azd env select` first.'
    }

    if (-not $UserPrincipalName) {
        $UserPrincipalName = Read-Host 'User principal name (e.g. user@contoso.com) to grant AVD access to'
    }
    if (-not $UserPrincipalName) {
        throw 'A user principal name is required.'
    }

    $groupName = "sg-avd-$EnvironmentName"

    Write-Step "Looking up user '$UserPrincipalName'..."
    $userId = az ad user show --id $UserPrincipalName --query id --output tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $userId) {
        throw "Could not find user '$UserPrincipalName': $userId"
    }

    if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Add to group '$groupName'")) {
        Write-Step "Adding '$UserPrincipalName' to group '$groupName'..."
        $result = az ad group member add --group $groupName --member-id $userId 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not add '$UserPrincipalName' to '$groupName': $result"
        }
        Write-Step "Added '$UserPrincipalName' to '$groupName'."
    }

    if ($PSCmdlet.ShouldProcess($EnvironmentName, 'Run postprovision hook (sync role assignments)')) {
        Write-Step 'Running postprovision hook to sync role assignments...'
        azd hooks run postprovision
    }

    Write-Step 'Done.'
} catch {
    Write-Warning "[grant-avd-access] $($_.Exception.Message)"
    exit 1
}
