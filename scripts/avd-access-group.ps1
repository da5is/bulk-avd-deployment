<#
.SYNOPSIS
    Manages the Microsoft Entra ID security group used to grant AVD desktop access.

.DESCRIPTION
    Provides the group-based access workflow for this template: add a user to one group and
    they can both see the desktop and be assigned to a session host in the Azure portal.

    A group role assignment alone is NOT enough for the portal. For a personal host pool the
    portal's session host "Assign" picker only enumerates users that hold a *direct*
    Desktop Virtualization User role assignment on the application group - it does not expand
    security groups. Group members would have working access but would never appear as
    assignable candidates.

    This script closes that gap by materialising the group's members as direct role
    assignments, so the group stays the single place you manage membership.

.PARAMETER Action
    Ensure  Create the security group if it does not exist and publish its object ID to the
            azd environment as AVD_USER_GROUP_IDS, so the Bicep deployment grants it both
            AVD roles. Run before provisioning.

    Sync    Read the group's members and give each user a direct assignment of both AVD roles,
            which is what makes them appear in the portal's "Assign" picker. Run after
            provisioning, and again whenever you add someone to the group.

    Remove  Delete the security group. Run after teardown.

.PARAMETER Prune
    With -Action Sync, also remove direct *user* role assignments for users who are no longer
    members of the group, making the group the sole source of truth. Only touches the two AVD
    roles at the two scopes this template manages, and never touches group or service
    principal assignments.

.NOTES
    Requires permission to manage groups (e.g. Groups Administrator) and to create role
    assignments (e.g. User Access Administrator or Owner) on the AVD resource group.
    Hooks invoke this with continueOnError, so it never blocks `azd up` / `azd down`.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Ensure', 'Sync', 'Remove')]
    [string]$Action = 'Ensure',

    [string]$EnvironmentName = $env:AZURE_ENV_NAME,
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$GroupName = $env:AVD_ACCESS_GROUP_NAME,
    [string]$ResourceGroupName = $env:AVD_RESOURCE_GROUP,
    [switch]$Prune
)

$ErrorActionPreference = 'Stop'

# Both roles are required: the first publishes the desktop, the second permits interactive
# sign-in to the Entra ID-joined session hosts.
$desktopVirtualizationUserRoleId = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'
$virtualMachineUserLoginRoleId = 'fb879df8-f326-4884-b1cf-06f3ad86be52'

function Write-Step { param([string]$Message) Write-Host "[avd-access-group] $Message" }

function Get-GraphHeaders {
    $token = az account get-access-token --resource 'https://graph.microsoft.com' --query accessToken --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not acquire a Microsoft Graph access token.' }
    return @{ Authorization = "Bearer $token" }
}

function Get-AccessGroup {
    param([hashtable]$Headers, [string]$Name)
    $filter = [uri]::EscapeDataString("displayName eq '$Name'")
    $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id,displayName"
    return (Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get).value | Select-Object -First 1
}

try {
    if (-not $EnvironmentName) {
        Write-Step 'AZURE_ENV_NAME is not set. Skipping.'
        return
    }
    if (-not $GroupName) { $GroupName = "sg-avd-$EnvironmentName" }
    if (-not $ResourceGroupName) { $ResourceGroupName = "rg-$EnvironmentName-avd" }
    if (-not $SubscriptionId) {
        $SubscriptionId = az account show --query id --output tsv 2>$null
    }

    $headers = Get-GraphHeaders
    $group = Get-AccessGroup -Headers $headers -Name $GroupName

    switch ($Action) {

        'Ensure' {
            if ($group) {
                Write-Step "Group '$GroupName' already exists ($($group.id))."
            } elseif ($PSCmdlet.ShouldProcess($GroupName, 'Create Entra ID security group')) {
                # mailEnabled:false + securityEnabled:true is required - Azure refuses to place
                # role assignments on Microsoft 365 (mail-enabled) groups.
                $body = @{
                    displayName     = $GroupName
                    mailNickname    = $GroupName
                    mailEnabled     = $false
                    securityEnabled = $true
                    description     = "Grants Azure Virtual Desktop access for the '$EnvironmentName' environment."
                } | ConvertTo-Json

                $group = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/groups' -Headers $headers -Method Post -Body $body -ContentType 'application/json'
                Write-Step "Created security group '$GroupName' ($($group.id))."
            }

            if ($group) {
                # Publish the ID so main.parameters.json resolves ${AVD_USER_GROUP_IDS} and the
                # deployment grants this group both AVD roles.
                azd env set AVD_USER_GROUP_IDS $group.id -e $EnvironmentName | Out-Null
                azd env set AVD_ACCESS_GROUP_NAME $GroupName -e $EnvironmentName | Out-Null
                Write-Step "Published AVD_USER_GROUP_IDS=$($group.id) to azd environment '$EnvironmentName'."
            }
        }

        'Sync' {
            if (-not $group) {
                Write-Step "Group '$GroupName' not found. Nothing to sync."
                return
            }

            $appGroupScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/applicationGroups/dag-$EnvironmentName"
            $rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"

            # Transitive members so nested groups are honoured; only users can be pinned to a
            # session host, so ignore any other principal type.
            $uri = "https://graph.microsoft.com/v1.0/groups/$($group.id)/transitiveMembers/microsoft.graph.user?`$select=id,userPrincipalName"
            $members = @()
            while ($uri) {
                $page = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
                $members += $page.value
                $uri = $page.'@odata.nextLink'
            }
            Write-Step "Group '$GroupName' has $($members.Count) user member(s)."

            foreach ($member in $members) {
                foreach ($assignment in @(
                        @{ Role = $desktopVirtualizationUserRoleId; Scope = $appGroupScope; Label = 'Desktop Virtualization User' },
                        @{ Role = $virtualMachineUserLoginRoleId; Scope = $rgScope; Label = 'Virtual Machine User Login' }
                    )) {

                    if (-not $PSCmdlet.ShouldProcess("$($member.userPrincipalName) -> $($assignment.Label)", 'Create role assignment')) { continue }

                    $result = az role assignment create `
                        --assignee-object-id $member.id `
                        --assignee-principal-type User `
                        --role $assignment.Role `
                        --scope $assignment.Scope `
                        --query id --output tsv 2>&1

                    if ($LASTEXITCODE -eq 0) {
                        # az role assignment create is idempotent: an existing assignment is
                        # returned rather than duplicated, so this covers both cases.
                        Write-Step "Ensured '$($assignment.Label)' for $($member.userPrincipalName)."
                    } elseif ("$result" -match 'RoleAssignmentExists|already exists') {
                        Write-Step "Already granted '$($assignment.Label)' to $($member.userPrincipalName)."
                    } else {
                        Write-Warning "[avd-access-group] Could not grant '$($assignment.Label)' to $($member.userPrincipalName): $result"
                    }
                }
            }

            if ($Prune) {
                $memberIds = @($members | ForEach-Object { $_.id })
                foreach ($target in @(
                        @{ Role = $desktopVirtualizationUserRoleId; Scope = $appGroupScope; Label = 'Desktop Virtualization User' },
                        @{ Role = $virtualMachineUserLoginRoleId; Scope = $rgScope; Label = 'Virtual Machine User Login' }
                    )) {

                    $existing = az role assignment list --scope $target.Scope --role $target.Role --output json 2>$null | ConvertFrom-Json
                    foreach ($assignment in $existing) {
                        # Only prune direct user grants at this exact scope; leave the group's own
                        # assignment and anything inherited from a parent scope alone.
                        if ($assignment.principalType -ne 'User') { continue }
                        if ($assignment.scope -ne $target.Scope) { continue }
                        if ($memberIds -contains $assignment.principalId) { continue }

                        if ($PSCmdlet.ShouldProcess("$($assignment.principalName) -> $($target.Label)", 'Remove role assignment')) {
                            az role assignment delete --ids $assignment.id --output none 2>$null
                            Write-Step "Pruned '$($target.Label)' from $($assignment.principalName) (no longer a group member)."
                        }
                    }
                }
            }
        }

        'Remove' {
            if (-not $group) {
                Write-Step "Group '$GroupName' not found. Nothing to delete."
                return
            }
            if ($PSCmdlet.ShouldProcess($GroupName, 'Delete Entra ID security group')) {
                Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)" -Headers $headers -Method Delete | Out-Null
                Write-Step "Deleted security group '$GroupName' ($($group.id))."
            }
        }
    }
} catch {
    Write-Warning "[avd-access-group] Skipped due to an error: $($_.Exception.Message)"
}
