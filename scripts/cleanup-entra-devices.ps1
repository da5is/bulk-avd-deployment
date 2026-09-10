<#
.SYNOPSIS
    Removes stale Microsoft Entra ID device objects left behind by deleted AVD session hosts.

.DESCRIPTION
    Entra ID device objects are directory objects, not Azure (ARM) resources, so `azd down`
    deletes the session host VMs but leaves their device registrations behind.

    infra/main.bicep derives session host names deterministically
    (avd<uniqueString(subscriptionId, environmentName)><index>), so the next `azd up`
    recreates VMs with identical computer names. Entra ID then rejects the join with:

        0x801c0083 / error_hostname_duplicate
        "Another object with the same value for property hostnames already exists."

    The VM still boots and the AADLoginForWindows extension still reports "Provisioning
    succeeded" (it only reports handler installation), but the machine is never joined.
    The AVD agent's DomainJoinedCheck and DomainTrustCheck then fail and every session host
    reports Unavailable, so no one can connect.

    This script deletes the orphaned device objects so the join can succeed.

.PARAMETER ResourceGroupName
    Resource group holding the session host VMs. Defaults to rg-<AZURE_ENV_NAME>-avd.

.PARAMETER VmNamePrefix
    Session host name prefix (e.g. 'avdcsrt'). Defaults to $env:AVD_VM_NAME_PREFIX, and
    falls back to inferring the prefix from the VMs found in ResourceGroupName.

.PARAMETER All
    Delete every Entra device matching the prefix, even if a healthy VM with that name still
    exists. Used by the `predown` hook, where the VMs are about to be destroyed.

    Without this switch a device is only deleted when it is provably stale, i.e. either:
      * no Azure VM with that name exists any more (orphan), or
      * a VM with that name exists but the device object was created BEFORE that VM was
        created, so the registration belongs to an earlier generation of the VM.
    A healthy device is always registered after its VM is created, so this ordering test
    makes the script safe to run against an already-deployed, working environment.

.NOTES
    Requires an Entra role that can delete device objects: Cloud Device Administrator,
    Intune Administrator, Windows 365 Administrator, or Global Administrator.
    Never fails the calling azd hook - cleanup is best effort.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ResourceGroupName = $(if ($env:AVD_RESOURCE_GROUP) { $env:AVD_RESOURCE_GROUP } elseif ($env:AZURE_ENV_NAME) { "rg-$($env:AZURE_ENV_NAME)-avd" } else { '' }),
    [string]$VmNamePrefix = $env:AVD_VM_NAME_PREFIX,
    [switch]$All
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "[cleanup-entra-devices] $Message" }

try {
    if (-not $ResourceGroupName) {
        Write-Step 'No resource group could be determined (set AZURE_ENV_NAME or pass -ResourceGroupName). Skipping.'
        return
    }

    # --- Discover the session host VMs that currently exist in Azure -------------------
    $liveVmNames = @()
    $vmCreatedUtc = @{}
    $rgExists = (az group exists --name $ResourceGroupName --output tsv 2>$null)
    if ($rgExists -eq 'true') {
        $vmJson = az vm list --resource-group $ResourceGroupName --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $vmJson) {
            foreach ($vm in ($vmJson | ConvertFrom-Json)) {
                $liveVmNames += $vm.name
                if ($vm.timeCreated) { $vmCreatedUtc[$vm.name] = ([datetime]$vm.timeCreated).ToUniversalTime() }
            }
        }
    }
    Write-Step "Resource group '$ResourceGroupName' has $($liveVmNames.Count) VM(s)."

    # --- Resolve the name prefix ------------------------------------------------------
    if (-not $VmNamePrefix -and $liveVmNames.Count -gt 0) {
        # Session hosts are '<prefix><index>'; strip the trailing index to recover the prefix.
        $VmNamePrefix = @($liveVmNames | ForEach-Object { $_ -replace '\d+$', '' } | Sort-Object -Unique)[0]
    }
    if (-not $VmNamePrefix) {
        Write-Step 'No VM name prefix available (no VMs found and AVD_VM_NAME_PREFIX unset). Nothing to clean up.'
        return
    }
    Write-Step "Using session host name prefix '$VmNamePrefix'."

    # --- Find matching Entra ID device objects ----------------------------------------
    $token = az account get-access-token --resource 'https://graph.microsoft.com' --query accessToken --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        Write-Warning "[cleanup-entra-devices] Could not acquire a Microsoft Graph token. Skipping cleanup."
        return
    }
    $headers = @{ Authorization = "Bearer $token" }

    $filter = [uri]::EscapeDataString("startswith(displayName,'$VmNamePrefix')")
    $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=$filter&`$select=id,displayName,createdDateTime&`$top=999"

    $devices = @()
    while ($uri) {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        $devices += $response.value
        $uri = $response.'@odata.nextLink'
    }
    Write-Step "Found $($devices.Count) Entra device object(s) matching '$VmNamePrefix*'."

    # --- Decide what to delete --------------------------------------------------------
    $stale = @($devices | Where-Object {
        $device = $_
        if ($All) { return $true }

        # Orphan: the VM this device was registered for no longer exists.
        if ($liveVmNames -notcontains $device.displayName) { return $true }

        # Superseded: the device registration predates the VM that currently holds the name,
        # so it belongs to an earlier VM and will block that VM's Entra join.
        $vmCreated = $vmCreatedUtc[$device.displayName]
        if ($vmCreated -and $device.createdDateTime) {
            return (([datetime]$device.createdDateTime).ToUniversalTime() -lt $vmCreated)
        }
        return $false
    })

    if ($stale.Count -eq 0) {
        Write-Step 'No stale device objects to remove.'
        return
    }

    foreach ($device in $stale) {
        if ($PSCmdlet.ShouldProcess($device.displayName, 'Delete Entra ID device object')) {
            try {
                Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/devices/$($device.id)" -Headers $headers -Method Delete | Out-Null
                Write-Step "Deleted stale device '$($device.displayName)' ($($device.id))."
            } catch {
                Write-Warning "[cleanup-entra-devices] Failed to delete device '$($device.displayName)': $($_.Exception.Message)"
            }
        }
    }
} catch {
    # Cleanup must never block `azd up` / `azd down`.
    Write-Warning "[cleanup-entra-devices] Skipped due to an unexpected error: $($_.Exception.Message)"
}
