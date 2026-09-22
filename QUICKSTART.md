# Quickstart

From nothing to a user sitting on a desktop. For the full reference — portal-only
paths, troubleshooting, teardown behaviour — see
[docs/post-deployment.md](docs/post-deployment.md).

**Prerequisites:** [Azure Developer CLI](https://aka.ms/azd), [Azure CLI](https://aka.ms/azure-cli),
[PowerShell 7](https://aka.ms/powershell) (`pwsh`), and an account that can create role
assignments, groups, and delete device objects in Microsoft Entra ID.

---

## 1. Set the required inputs

```pwsh
azd auth login
azd env new <env-name>                      # or: azd env select <existing>

azd env set AVD_ADMIN_PASSWORD '<12+ chars>'
azd env set AVD_SESSION_HOST_COUNT 5        # 1-500; you are prompted if unset
azd env set AVD_VNET_ADDRESS_PREFIX 172.16.0.0/16          # you are prompted if unset
azd env set AVD_SESSION_HOST_SUBNET_PREFIX 172.16.0.0/23   # you are prompted if unset
azd env set AVD_BASTION_SUBNET_PREFIX 172.16.2.0/26        # you are prompted if unset
```

`AVD_ADMIN_PASSWORD` becomes the local administrator password on every session
host. These settings are stored per environment in `.azure/<env>/.env`.

---

## 2. Deploy

```pwsh
azd up
```

Everything in this step is automatic:

| Phase | What happens |
| --- | --- |
| `preprovision` | Deletes stale Entra ID device objects, so the session hosts' Entra join is not rejected as a duplicate hostname. |
| `preprovision` | Creates the `sg-avd-<env>` security group and publishes its object ID as `AVD_USER_GROUP_IDS`. |
| Bicep | Resource groups, virtual network, Log Analytics, host pool, application group, workspace, session host VMs (Entra join → AVD agent → monitoring agent), and **grants the group both AVD roles**. |
| `postprovision` | Syncs group members into direct role assignments. A no-op on the first run, because the group is still empty. |
| `postprovision` | Opts the tenant in to Microsoft Entra ID authentication for RDP, without which every connection fails with *"the credentials did not work"*. |

---

## 3. Check the session hosts are healthy

**Portal:** *Azure Virtual Desktop* → **Host pools** → `hp-<env>` → **Session hosts**.

**CLI:**

```pwsh
$sub = azd env get-value AZURE_SUBSCRIPTION_ID
$e = azd env get-value AZURE_ENV_NAME
$token = az account get-access-token --query accessToken -o tsv
$uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/rg-$e-avd/providers/Microsoft.DesktopVirtualization/hostPools/hp-$e/sessionHosts?api-version=2024-04-03"

(Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $token" }).value |
    ForEach-Object { [pscustomobject]@{ host = ($_.name -split '/')[-1]; status = $_.properties.status } }
```

Every host must report **Available**.

> **Stop here if any host is `Unavailable` with `DomainJoinedCheck` failing.** The
> Entra join was rejected because a stale device object still owns the hostname.
> Run `./scripts/cleanup-entra-devices.ps1`, then force a re-join and reboot — see
> [docs/post-deployment.md](docs/post-deployment.md#troubleshooting).

---

## 4. Add a user

**This is the manual part.** `azd up` deliberately grants nobody access.

```pwsh
$e = azd env get-value AZURE_ENV_NAME

az ad group member add --group "sg-avd-$e" `
    --member-id (az ad user show --id user@contoso.com --query id -o tsv)

azd hooks run postprovision
```

*Portal alternative for the first command:* *Microsoft Entra ID* → **Groups** →
`sg-avd-<env>` → **Members** → **Add members**.

> ⚠️ **`azd hooks run postprovision` is not optional.** It grants each group
> member the two required roles *directly*. Without it the user gets no access,
> and even once the group itself is granted, they will not appear in the Assign
> picker in step 5 — the portal does not expand groups there.

Access needs two roles, at two different scopes, and the sync handles both:

| Role | Scope | Without it |
| --- | --- | --- |
| Desktop Virtualization User | `dag-<env>` | Empty feed — the desktop never appears. |
| Virtual Machine User Login | `rg-<env>-avd` | Desktop appears, but sign-in fails with *"the credentials did not work"*. |

> Being a Subscription Owner or Global Administrator grants **neither** of these.
> Both are `dataActions`, which Owner's `*` never matches.

---

## 5. Pin the user to a session host

The host pool is **Personal** with **Direct** assignment, so it does not
auto-claim a host. Every user needs one.

**Portal:** *Azure Virtual Desktop* → **Host pools** → `hp-<env>` →
**Session hosts** → tick a free host → **Assign** → choose the user.

**CLI:**

```pwsh
$sub = azd env get-value AZURE_SUBSCRIPTION_ID
$e = azd env get-value AZURE_ENV_NAME
$token = az account get-access-token --query accessToken -o tsv

$uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/rg-$e-avd/providers/Microsoft.DesktopVirtualization/hostPools/hp-$e/sessionHosts/<vm-name>?api-version=2024-04-03"

Invoke-RestMethod -Uri $uri -Method Patch `
    -Body '{"properties":{"assignedUser":"user@contoso.com"}}' `
    -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
```

> No candidate users in the picker? You skipped `azd hooks run postprovision`.
>
> Use `Invoke-RestMethod`, not `az rest` — on Windows the `az.bat` wrapper mangles
> the JSON body and fails with *"was unexpected at this time"*.

---

## 6. Connect

Sign in as the assigned user at **<https://windows.cloud.microsoft>**, or use the
**Windows App** on Windows, macOS, iOS or Android.

Session hosts have `startVMOnConnect` enabled, so a deallocated VM powers on by
itself — expect the first connection to be slow.

---

## Adding more people

Repeat [step 4](#4-add-a-user) and [step 5](#5-pin-the-user-to-a-session-host)
for each person. Everything else is already in place.

---

## Tearing down

```pwsh
azd down --purge
```

Hooks delete the session hosts' Entra ID device objects and the `sg-avd-<env>`
group. Consequently **group membership and session host assignments do not
survive a teardown** — after the next `azd up`, redo steps 4 and 5.
