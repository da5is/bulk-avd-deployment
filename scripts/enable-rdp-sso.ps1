<#
.SYNOPSIS
    Enables Microsoft Entra ID authentication for RDP so users can sign in to the
    Entra ID-joined session hosts.

.DESCRIPTION
    The host pool asks clients to authenticate with a Microsoft Entra ID token
    (`enablerdsaadauth:i:1`). That token is only issued if the tenant has opted in, by setting
    `isRemoteDesktopProtocolEnabled` on the *Windows Cloud Login* service principal. The flag
    lives on a directory object rather than an ARM resource, so Bicep cannot set it - without
    this script the desktop appears in the client but every connection fails with
    "the credentials did not work".

    The predecessor property, `targetisaadjoined:i:1`, needed no tenant opt-in but forced
    plain username/password authentication, which breaks whenever the account is subject to
    multifactor authentication or a Conditional Access policy. Microsoft has replaced it with
    `enablerdsaadauth`, which this template now uses.

    Also registers the session hosts as trusted devices so users are not asked to confirm
    "Allow this connection?" the first time they reach each host.

.PARAMETER Action
    Enable  Turn on Entra ID authentication for RDP in the tenant and register the session
            hosts as trusted devices. Idempotent, so re-running picks up new hosts.

    Remove  Unregister and delete this environment's trusted device group. The tenant-wide
            authentication flag is deliberately left on, because other host pools in the
            tenant may depend on it.

.NOTES
    Requires permission to update application configuration (e.g. Application Administrator,
    Cloud Application Administrator or Global Administrator) and to manage groups.
    Hooks invoke this with continueOnError, so it never blocks `azd up` / `azd down`.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Enable', 'Remove')]
    [string]$Action = 'Enable',

    [string]$EnvironmentName = $env:AZURE_ENV_NAME,
    [string]$VmNamePrefix = $env:AVD_VM_NAME_PREFIX,
    [string]$DeviceGroupName = $env:AVD_SSO_DEVICE_GROUP_NAME
)

$ErrorActionPreference = 'Stop'

# Windows Cloud Login is the app that issues the RDP access token for Entra ID-joined hosts.
# Microsoft Remote Desktop served the same purpose for clients predating Windows App and is
# still consulted by older client builds, so both are opted in.
$rdpServicePrincipals = @(
    @{ AppId = '270efc09-cd0d-444b-a71f-39af4910ec45'; Name = 'Windows Cloud Login' },
    @{ AppId = 'a4a365df-50f1-4397-bc59-1a1564b8bb9c'; Name = 'Microsoft Remote Desktop' }
)

function Write-Step { param([string]$Message) Write-Host "[enable-rdp-sso] $Message" }

function Get-GraphHeaders {
    $token = az account get-access-token --resource 'https://graph.microsoft.com' --query accessToken --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not acquire a Microsoft Graph access token.' }
    return @{ Authorization = "Bearer $token" }
}

function Get-ServicePrincipalId {
    param([hashtable]$Headers, [string]$AppId)
    $filter = [uri]::EscapeDataString("appId eq '$AppId'")
    $uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$filter&`$select=id"
    return (Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get).value | Select-Object -First 1 -ExpandProperty id -ErrorAction SilentlyContinue
}

function Get-GroupByName {
    param([hashtable]$Headers, [string]$Name)
    $filter = [uri]::EscapeDataString("displayName eq '$Name'")
    $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id,displayName,groupTypes"
    return (Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get).value | Select-Object -First 1
}

try {
    if (-not $EnvironmentName) {
        Write-Step 'AZURE_ENV_NAME is not set. Skipping.'
        return
    }
    if (-not $DeviceGroupName) { $DeviceGroupName = "sg-avd-$EnvironmentName-hosts" }

    $headers = Get-GraphHeaders

    # remoteDesktopSecurityConfiguration is only exposed on the beta endpoint.
    $graphBeta = 'https://graph.microsoft.com/beta/servicePrincipals'

    if ($Action -eq 'Enable') {

        foreach ($sp in $rdpServicePrincipals) {
            $spId = Get-ServicePrincipalId -Headers $headers -AppId $sp.AppId
            if (-not $spId) {
                Write-Step "Service principal '$($sp.Name)' is not provisioned in this tenant. Skipping."
                continue
            }

            $config = Invoke-RestMethod -Uri "$graphBeta/$spId/remoteDesktopSecurityConfiguration" -Headers $headers -Method Get
            if ($config.isRemoteDesktopProtocolEnabled) {
                Write-Step "Entra ID authentication for RDP is already enabled on '$($sp.Name)'."
            } elseif ($PSCmdlet.ShouldProcess($sp.Name, 'Enable Entra ID authentication for RDP')) {
                $body = @{ isRemoteDesktopProtocolEnabled = $true } | ConvertTo-Json
                try {
                    Invoke-RestMethod -Uri "$graphBeta/$spId/remoteDesktopSecurityConfiguration" -Headers $headers -Method Patch -Body $body -ContentType 'application/json' | Out-Null
                    Write-Step "Enabled Entra ID authentication for RDP on '$($sp.Name)'."
                } catch {
                    # Without this flag no RDP token is issued, so the desktop appears in the
                    # client but every connection fails. Shout about it rather than letting
                    # continueOnError bury a warning that only surfaces as a broken deployment.
                    Write-Warning @"
[enable-rdp-sso] COULD NOT ENABLE ENTRA ID AUTHENTICATION FOR RDP on '$($sp.Name)'.
                 $($_.Exception.Message)

                 ACTION REQUIRED - until this is set, users will see the desktop but every
                 connection will fail with "the credentials did not work".

                 This needs an Entra role such as Application Administrator, Cloud Application
                 Administrator or Global Administrator. Ask someone who has one to either
                 re-run this script:

                     ./scripts/enable-rdp-sso.ps1

                 or set it in the portal: Microsoft Entra ID > Devices >
                 Remote connection configuration > $($sp.Name) > enable, then Save.
"@
                }
            }
        }

        if (-not $VmNamePrefix) {
            Write-Step 'AVD_VM_NAME_PREFIX is not set, so the consent prompt cannot be suppressed. Users will be asked to allow the connection once per host.'
            return
        }

        # Trusted device group. A dynamic rule keeps itself current as hosts are added or
        # replaced, but dynamic membership needs Entra ID P1, so fall back to a static group
        # that this script repopulates on every run.
        $spId = Get-ServicePrincipalId -Headers $headers -AppId $rdpServicePrincipals[0].AppId
        if (-not $spId) { return }

        $group = Get-GroupByName -Headers $headers -Name $DeviceGroupName
        if (-not $group -and $PSCmdlet.ShouldProcess($DeviceGroupName, 'Create trusted device group')) {
            $base = @{
                displayName     = $DeviceGroupName
                mailNickname    = $DeviceGroupName
                mailEnabled     = $false
                securityEnabled = $true
                description     = "Session hosts trusted for Azure Virtual Desktop single sign-on in the '$EnvironmentName' environment."
            }
            $dynamic = $base.Clone()
            $dynamic.groupTypes = @('DynamicMembership')
            $dynamic.membershipRule = "(device.displayName -startsWith `"$VmNamePrefix`")"
            $dynamic.membershipRuleProcessingState = 'On'

            try {
                $group = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/groups' -Headers $headers -Method Post -Body ($dynamic | ConvertTo-Json) -ContentType 'application/json'
                Write-Step "Created dynamic device group '$DeviceGroupName' ($($group.id)) matching '$VmNamePrefix*'."
            } catch {
                Write-Step "Dynamic group creation failed (Entra ID P1 is required); falling back to a static group."
                $static = $base.Clone()
                $static.groupTypes = @()
                $group = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/groups' -Headers $headers -Method Post -Body ($static | ConvertTo-Json) -ContentType 'application/json'
                Write-Step "Created static device group '$DeviceGroupName' ($($group.id))."
            }
        }
        if (-not $group) { return }

        if ($group.groupTypes -notcontains 'DynamicMembership') {
            # Static group: reconcile membership against the session host device objects.
            $filter = [uri]::EscapeDataString("startswith(displayName,'$VmNamePrefix')")
            $devices = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=$filter&`$select=id,displayName" -Headers $headers -Method Get).value
            $existing = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members?`$select=id" -Headers $headers -Method Get).value

            foreach ($device in $devices) {
                if ($existing.id -contains $device.id) { continue }
                if (-not $PSCmdlet.ShouldProcess($device.displayName, 'Add session host to trusted device group')) { continue }
                $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($device.id)" } | ConvertTo-Json
                try {
                    Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/`$ref" -Headers $headers -Method Post -Body $body -ContentType 'application/json' | Out-Null
                    Write-Step "Added session host '$($device.displayName)' to '$DeviceGroupName'."
                } catch {
                    Write-Warning "[enable-rdp-sso] Could not add '$($device.displayName)' to '$DeviceGroupName': $($_.Exception.Message)"
                }
            }
        }

        $targets = (Invoke-RestMethod -Uri "$graphBeta/$spId/remoteDesktopSecurityConfiguration/targetDeviceGroups" -Headers $headers -Method Get).value
        if ($targets.id -contains $group.id) {
            Write-Step "'$DeviceGroupName' is already registered as a trusted device group."
        } elseif ($PSCmdlet.ShouldProcess($DeviceGroupName, 'Register as trusted device group')) {
            $body = @{ id = $group.id; displayName = $DeviceGroupName } | ConvertTo-Json
            Invoke-RestMethod -Uri "$graphBeta/$spId/remoteDesktopSecurityConfiguration/targetDeviceGroups" -Headers $headers -Method Post -Body $body -ContentType 'application/json' | Out-Null
            Write-Step "Registered '$DeviceGroupName' as a trusted device group; the connection consent prompt is suppressed."
        }
    }

    if ($Action -eq 'Remove') {
        $group = Get-GroupByName -Headers $headers -Name $DeviceGroupName
        if (-not $group) {
            Write-Step "Device group '$DeviceGroupName' not found. Nothing to remove."
            return
        }

        $spId = Get-ServicePrincipalId -Headers $headers -AppId $rdpServicePrincipals[0].AppId
        if ($spId -and $PSCmdlet.ShouldProcess($DeviceGroupName, 'Unregister trusted device group')) {
            try {
                Invoke-RestMethod -Uri "$graphBeta/$spId/remoteDesktopSecurityConfiguration/targetDeviceGroups/$($group.id)" -Headers $headers -Method Delete | Out-Null
                Write-Step "Unregistered '$DeviceGroupName' from the trusted device groups."
            } catch {
                Write-Step "'$DeviceGroupName' was not registered as a trusted device group."
            }
        }

        if ($PSCmdlet.ShouldProcess($DeviceGroupName, 'Delete trusted device group')) {
            Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)" -Headers $headers -Method Delete | Out-Null
            Write-Step "Deleted device group '$DeviceGroupName' ($($group.id))."
        }
    }
} catch {
    Write-Warning "[enable-rdp-sso] Skipped due to an error: $($_.Exception.Message)"
}
