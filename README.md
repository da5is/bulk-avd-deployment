# Bulk AVD Deployment

Azure Developer CLI (azd) template that deploys a monitored Azure Virtual Desktop
environment across two resource groups.

**New here? Start with [QUICKSTART.md](QUICKSTART.md)** — deploy to a connected
user in six steps.

## What gets deployed

1. **`rg-<env>-monitoring`** — Log Analytics workspace + Data Collection Rule.
   Subscription Activity Log is streamed here, plus resource logs from every
   resource below. Also deploys an **AVD Insights workbook** (`Microsoft.Insights/workbooks`,
   `AVD Insights - <env>`) sourced from the same workspace, with sections for
   connections, errors/checkpoints, agent health, management activities, and
   session host CPU/memory/input-delay/event log data.
2. **`rg-<env>-avd`**
   - VNet `172.16.0.0/16` (RFC1918-compliant private space)
     - `snet-avd` (`172.16.0.0/23`, 507 usable IPs — sized for 500 AVD hosts) with a
       NAT Gateway attached for outbound internet access
     - `AzureBastionSubnet` (`172.16.2.0/26`)
   - Standard Azure Bastion host for remote administration (no public RDP/SSH)
   - AVD Host Pool (**Personal**, Direct assignment — dedicated, persistent
     desktops), Desktop Application Group, and Workspace
   - 10 session host VMs:
     - `Standard_B2s` (B-series, 2 vCPU / 4 GB RAM)
     - 128 GB **Standard_LRS** OS disk
     - Microsoft Entra ID joined only (no on-prem AD / domain controller — "cloud only")
     - Registered into the host pool automatically via the AVD DSC extension
     - Azure Monitor Agent + DCR association, sending Windows Event Logs and
       performance counters to the same Log Analytics workspace

All resource groups are tagged `azd-env-name` so `azd down` can find and remove
everything.

## Prerequisites

- [Azure Developer CLI](https://aka.ms/azd) installed
- [Azure CLI](https://aka.ms/azure-cli) and [PowerShell 7](https://aka.ms/powershell) (`pwsh`) — used by the `azd` hooks in `azure.yaml`
- An Azure subscription with quota for 10x `Standard_B2s` VMs and AVD
- An Entra role that can delete device objects (**Cloud Device Administrator**,
  Intune Administrator, Windows 365 Administrator or Global Administrator) so the
  hooks can clean up session host registrations — see [Notes](#notes)
- An Entra role that can manage groups (**Groups Administrator**) so the hooks can
  create and delete the `sg-avd-<env>` access group

## Deploy

```pwsh
azd auth login
azd init                      # if not already initialized in this folder
azd env set AVD_ADMIN_PASSWORD '<a-strong-password>'
azd up
```

`AVD_ADMIN_PASSWORD` is required (min 12 chars) and is used as the local
administrator password on each session host VM.

**Number of session hosts (1–500):** since this parameter has no default,
`azd up` will automatically prompt you for it (validated against the 1-500
range declared in `main.bicep`). To skip the prompt, set it ahead of time:

```pwsh
azd env set AVD_SESSION_HOST_COUNT 25
```

## After deploying

`azd up` provisions the infrastructure but nobody can use a desktop until you
grant access and assign a session host.

**➡️ [QUICKSTART.md](QUICKSTART.md)** — the six-step happy path.
**➡️ [docs/post-deployment.md](docs/post-deployment.md)** — full reference,
including the Azure portal equivalents and a troubleshooting table.

The short version:

```pwsh
# 1. Add the user to the access group the deployment manages
az ad group member add --group "sg-avd-$(azd env get-value AZURE_ENV_NAME)" `
    --member-id (az ad user show --id user@contoso.com --query id -o tsv)

# 2. Grant them the AVD roles (also makes them selectable in the portal's Assign picker)
azd hooks run postprovision

# 3. Pin them to a session host, in the portal or via ARM - see the guide
```

## Tear down

```pwsh
azd down --purge
```

The `predown` hook removes the session hosts' Microsoft Entra ID device objects
first, and the `postdown` hook deletes the `sg-avd-<env>` access group. Skipping
them (for example by tearing down the resource groups by hand) leaves stale
device objects behind that will break the Entra join on the next `azd up` — see
[Notes](#notes).

## Notes

- Session host registration token expires 4 hours after deployment starts;
  re-run `azd up` (or a targeted `az deployment` update) if hosts need to
  re-register after that window.
- **Granting desktop access — add the user to `sg-avd-<env>`.** The deployment
  creates and manages a security group for you, so membership is the only thing
  you normally touch. Full walkthrough in
  [docs/post-deployment.md](docs/post-deployment.md).

  ```pwsh
  az ad group member add --group sg-avd-<env> --member-id (az ad user show --id user@contoso.com --query id -o tsv)
  azd hooks run postprovision          # grant the new member the AVD roles
  ```

  Access requires **two** roles; publishing the desktop alone is not enough:
  - **Desktop Virtualization User** on the Desktop Application Group — lets the
    user see and launch the desktop in the AVD client.
  - **Virtual Machine User Login** on `rg-<env>-avd` — lets the user actually
    sign in to the Microsoft Entra ID-joined session hosts.

  `scripts/avd-access-group.ps1` manages this and runs from three hooks:

  | Hook | Action | Purpose |
  | --- | --- | --- |
  | `preprovision` | `-Action Ensure` | Creates `sg-avd-<env>` if missing and publishes its object ID as `AVD_USER_GROUP_IDS`, which the deployment then grants both roles. |
  | `postprovision` | `-Action Sync` | Gives each group member a **direct** assignment of both roles. |
  | `postdown` | `-Action Remove` | Deletes the group, since it belongs to this environment. |

  > ⚠️ **Why members also need direct assignments.** For a personal host pool
  > the portal's session host **"Assign" picker only enumerates users holding a
  > direct Desktop Virtualization User assignment** on the application group —
  > it does **not** expand security groups. Without the `Sync` step, group
  > members get working access but never appear as assignable candidates, and
  > the Assign dialog looks empty. This is why adding someone to the group must
  > be followed by `azd hooks run postprovision`.

  Add `-Prune` to also revoke users who have been removed from the group,
  making the group the sole source of truth:

  ```pwsh
  ./scripts/avd-access-group.ps1 -Action Sync -Prune
  ```

  > **`azd down` deletes the group**, so its membership does not survive a
  > teardown. Use `AVD_ACCESS_GROUP_NAME` to point at a differently-named group.

  To use your own pre-existing principals instead, set either of these before
  provisioning (both accept comma-separated lists, and both roles are created
  for every principal listed):

  ```pwsh
  azd env set AVD_USER_GROUP_IDS '<group-object-id>[,<group-object-id>...]'
  azd env set AVD_USER_IDS       '<user-object-id>[,<user-object-id>...]'
  ```

  `AVD_USER_GROUP_IDS` is overwritten by the `preprovision` hook. Groups must be
  security-enabled, and users listed in `AVD_USER_IDS` are the ones that appear
  in the Assign picker. (`AVD_USER_PRINCIPAL_ID` / `AVD_USER_PRINCIPAL_TYPE`
  still work as a single-principal shorthand.)

  > **These settings live in `.azure/<env>/.env`, which is per-environment.**
  > Creating a *new* azd environment starts from an empty `.env`, so any
  > principals you set by hand must be set again for that environment.

  > **Subscription Owner / Global Administrator does _not_ grant desktop
  > access.** Owner's `*` permission covers `actions` only, while both roles
  > above are `dataActions` — which `*` never matches. An Owner who hasn't been
  > granted these roles gets an empty feed in the AVD client and cannot sign in
  > to a session host.

  > **The principal must be a security group.** Microsoft 365 groups
  > (`securityEnabled: false`, i.e. mail-enabled collaboration groups such as a
  > default "All Company") are rejected by Azure with
  > `GroupTypeNotSupported: Only security-enabled groups can be used in role
  > assignments`. Create a security group instead:
  >
  > ```pwsh
  > az ad group create --display-name sg-avd-users --mail-nickname sg-avd-users
  > ```
- Session hosts are Microsoft Entra ID joined only — there is no on-premises AD
  or domain controller. **Entra ID device objects are directory objects, not
  ARM resources, so `azd down` does not delete them.** Session host names are
  deterministic (`avd<uniqueString(subscriptionId, envName)><index>`), so a
  later `azd up` recreates VMs with identical computer names and the leftover
  device objects still own those hostnames. The join is then rejected with:

  ```text
  0x801c0083 / error_hostname_duplicate
  "Another object with the same value for property hostnames already exists."
  ```

  This failure is silent from ARM's point of view: the `AADLoginForWindows`
  extension still reports *"Provisioning succeeded"* (it only reports handler
  installation, not the join result), but `dsregcmd /status` shows
  `AzureAdJoined : NO`, the AVD agent's `DomainJoinedCheck` and
  `DomainTrustCheck` fail, and **every session host reports `Unavailable`**.

  `scripts/cleanup-entra-devices.ps1` prevents this and is wired into
  `azure.yaml` as two hooks:

  | Hook | Invocation | Purpose |
  | --- | --- | --- |
  | `predown` | `-All` | Deletes the device objects while the VMs still exist, so nothing is orphaned by the teardown. |
  | `preprovision` | *(default)* | Safety net. Deletes only devices that are provably stale — no matching VM, or a device created *before* the VM that currently holds the name. Devices belonging to healthy current VMs are left alone, so it is safe on a re-provision. |

  Deleting device objects requires an Entra role such as **Cloud Device
  Administrator** or **Global Administrator**. Both hooks use
  `continueOnError: true`, so insufficient permissions will not block `azd`.

  To repair hosts that are already stuck in this state, delete the stale
  devices and force a re-join on each VM:

  ```pwsh
  ./scripts/cleanup-entra-devices.ps1
  az vm run-command invoke -g rg-<env>-avd -n <vm> --command-id RunPowerShellScript `
    --scripts "dsregcmd /leave" "Start-ScheduledTask -TaskPath '\Microsoft\Windows\Workplace Join\' -TaskName 'Automatic-Device-Join'"
  az vm restart -g rg-<env>-avd -n <vm>
  ```
- Because the session hosts are Entra ID joined, the host pool sets the
  `targetisaadjoined:i:1` custom RDP property. This is **required** for clients
  that are not Entra joined to the same tenant — including the **web client**
  and macOS/iOS/Android — otherwise connections fail with *"the credentials did
  not work"*. Override the full string with the `customRdpProperty` parameter.
- The host pool uses **Direct** personal desktop assignment so an admin can pin
  a specific user to a specific session host. Azure disables the portal's
  "Assign" button when a personal host pool uses `Automatic`, which instead
  claims the first free host on initial sign-in. Because `Direct` does **not**
  auto-claim, every user must be explicitly assigned to a session host before
  they can connect:

  ```pwsh
  az rest --method patch `
    --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/rg-<env>-avd/providers/Microsoft.DesktopVirtualization/hostPools/hp-<env>/sessionHosts/<vm>?api-version=2024-04-03" `
    --headers "Content-Type=application/json" `
    --body '{\"properties\":{\"assignedUser\":\"user@contoso.com\"}}'
  ```

  Override with:

  ```pwsh
  azd env set AVD_ASSIGNMENT_TYPE Automatic
  ```
- Session host image is `MicrosoftWindowsDesktop:windows-11:win11-23h2-avd:latest`.
- The AVD Insights workbook deployed here is a custom, functionally-equivalent
  workbook built from the documented AVD Log Analytics tables (`WVDConnections`,
  `WVDErrors`, `WVDCheckpoints`, `WVDAgentHealthStatus`, `WVDManagementActivities`,
  `WVDFeeds`, `Perf`, `Event`) — Microsoft's official gallery "AVD Insights"
  workbook content is proprietary and isn't published as reusable JSON, so it
  can't be embedded verbatim in IaC. Anyone viewing it needs **Desktop
  Virtualization Reader** (on the AVD resource group) and **Log Analytics
  Reader** (on the workspace) RBAC roles, per the
  [AVD Insights prerequisites](https://learn.microsoft.com/azure/virtual-desktop/insights).
