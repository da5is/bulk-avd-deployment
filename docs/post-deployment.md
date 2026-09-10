# After `azd up`

`azd up` builds the infrastructure, but it does **not** finish the job: nobody can
use a desktop until you grant access and assign a session host. This guide covers
those steps, with the Azure portal equivalent wherever one exists.

Throughout, `<env>` is your azd environment name (`azd env list`). With an
environment called `avdload` the resources are:

| Thing | Name |
| --- | --- |
| Host pool | `hp-avdload` |
| Desktop application group | `dag-avdload` |
| Workspace | `ws-avdload` |
| Resource group | `rg-avdload-avd` |
| Access group | `sg-avd-avdload` |
| Session hosts | `avdrjex0` … `avdrjex4` |

---

## Checklist

1. [Confirm the session hosts are healthy](#1-confirm-the-session-hosts-are-healthy)
2. [Give people access](#2-give-people-access)
3. [Assign each user a session host](#3-assign-each-user-a-session-host)
4. [Connect](#4-connect)

---

## 1. Confirm the session hosts are healthy

Every host must report **Available**. Anything else means the rest of the guide
will not work.

**Portal:** *Azure Virtual Desktop* → **Host pools** → `hp-<env>` → **Session hosts**.
Check the *Status* column.

**CLI:**

```pwsh
$sub = azd env get-value AZURE_SUBSCRIPTION_ID
$env = azd env get-value AZURE_ENV_NAME
$token = az account get-access-token --query accessToken -o tsv
$uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/rg-$env-avd/providers/Microsoft.DesktopVirtualization/hostPools/hp-$env/sessionHosts?api-version=2024-04-03"
(Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $token" }).value |
    ForEach-Object { [pscustomobject]@{ host = ($_.name -split '/')[-1]; status = $_.properties.status } }
```

> **`Unavailable` with `DomainJoinedCheck` failing** means the Entra ID join was
> rejected because a stale device object still owns the hostname. See
> [Troubleshooting](#troubleshooting).

---

## 2. Give people access

Access needs **two** roles, and they live at **two different scopes**:

| Role | Scope | Without it |
| --- | --- | --- |
| **Desktop Virtualization User** | Desktop application group `dag-<env>` | The desktop never appears in the client — the feed is empty. |
| **Virtual Machine User Login** | Resource group `rg-<env>-avd` | The desktop appears but sign-in fails with *"the credentials did not work"*. |

> ⚠️ **Being a Subscription Owner or Global Administrator does not grant either
> of these.** Both roles are `dataActions`, and Owner's `*` only covers `actions`,
> which never matches a `dataAction`. Admins must be granted these roles like
> anyone else.

### The supported way: add the user to `sg-avd-<env>`

The deployment creates and owns a security group for this. Add the user, then run
the sync:

```pwsh
$env = azd env get-value AZURE_ENV_NAME
$userId = az ad user show --id user@contoso.com --query id -o tsv

az ad group member add --group "sg-avd-$env" --member-id $userId
azd hooks run postprovision
```

**Portal alternative for the membership step:** *Microsoft Entra ID* → **Groups**
→ `sg-avd-<env>` → **Members** → **Add members**. You still have to run
`azd hooks run postprovision` afterwards.

> **Why the sync is mandatory.** The group role assignment alone is enough to
> *use* the desktop, but the portal's session host **"Assign" picker only lists
> users that hold a direct Desktop Virtualization User assignment** — it does not
> expand groups. Skip the sync and step 3 will show **no candidate users**. The
> sync gives each group member their own direct assignment, which is what makes
> them selectable.

To also revoke people you have removed from the group, making the group the sole
source of truth:

```pwsh
./scripts/avd-access-group.ps1 -Action Sync -Prune
```

### Doing it entirely in the portal

Possible, but you must remember to do **both** scopes — the AVD blade only covers
the first one:

1. *Azure Virtual Desktop* → **Application groups** → `dag-<env>` →
   **Assignments** → **Add** → pick the user or group.
   *(This grants Desktop Virtualization User.)*
2. *Resource groups* → `rg-<env>-avd` → **Access control (IAM)** →
   **Add role assignment** → **Virtual Machine User Login** → pick the same
   principal.

If you assign an individual **user** here, they will appear in the Assign picker
without running the sync. If you assign a **group**, they will not.

---

## 3. Assign each user a session host

This host pool is **Personal** with **Direct** assignment, so a user must be
pinned to a specific session host before they can connect. Direct assignment does
**not** auto-claim a host.

**Portal:** *Azure Virtual Desktop* → **Host pools** → `hp-<env>` →
**Session hosts** → tick a host → **Assign** → choose the user.

> Seeing **no candidate users**? The picker only lists users with a *direct*
> Desktop Virtualization User assignment. Run `azd hooks run postprovision`
> (see [step 2](#2-give-people-access)) and reload the blade.

**CLI:**

```pwsh
$sub = azd env get-value AZURE_SUBSCRIPTION_ID
$env = azd env get-value AZURE_ENV_NAME
$token = az account get-access-token --query accessToken -o tsv

$uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/rg-$env-avd/providers/Microsoft.DesktopVirtualization/hostPools/hp-$env/sessionHosts/<vm-name>?api-version=2024-04-03"
$body = '{"properties":{"assignedUser":"user@contoso.com"}}'

Invoke-RestMethod -Uri $uri -Method Patch -Body $body `
    -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
```

> Use PowerShell's `Invoke-RestMethod` rather than `az rest` here. On Windows the
> `az.bat` wrapper mangles the JSON body's quotes and fails with
> *"was unexpected at this time"*.

To switch to self-service instead — first sign-in claims any free host, no pinning
and no Assign picker involved — redeploy with automatic assignment:

```pwsh
azd env set AVD_ASSIGNMENT_TYPE Automatic
azd provision
```

Note that `Automatic` greys out the portal's **Assign** button, since the service
owns assignment from then on.

---

## 4. Connect

| Client | Where |
| --- | --- |
| Browser | <https://windows.cloud.microsoft> (formerly `client.wvd.microsoft.com`) |
| Windows | **Windows App**, from the Microsoft Store |
| macOS / iOS / Android | **Windows App**, from the relevant app store |

Sign in as the assigned user and the desktop published by `ws-<env>` appears.

Session hosts have `startVMOnConnect` enabled, so a deallocated VM powers on
automatically — the first connection of the day is slower.

---

## Adding someone later

```pwsh
az ad group member add --group "sg-avd-$(azd env get-value AZURE_ENV_NAME)" `
    --member-id (az ad user show --id newuser@contoso.com --query id -o tsv)
azd hooks run postprovision     # required: makes them selectable in Assign
```

Then pin them to a free session host ([step 3](#3-assign-each-user-a-session-host)).

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Assign picker shows **no candidate users** | Access was granted through a group; the picker does not expand groups. | `azd hooks run postprovision` |
| Client feed is empty / `error-avd-noDevices-tile` | No **Desktop Virtualization User** on the app group, or the sign-in token predates the grant. | Grant the role, then sign out and back in — group membership is a token claim, so an existing session will not pick it up. |
| Desktop appears, but connecting fails with *"the credentials did not work"* | Missing **Virtual Machine User Login** on `rg-<env>-avd`, or the host pool lost `targetisaadjoined:i:1`. | Grant the role; confirm the RDP property with `azd provision`. |
| Session hosts **Unavailable**, `DomainJoinedCheck` / `DomainTrustCheck` failed | Stale Entra device objects still own the hostnames, so the join was rejected with `0x801c0083 / error_hostname_duplicate`. The VM extension still reports success, which masks it. | `./scripts/cleanup-entra-devices.ps1`, then force a re-join and reboot — see the README. |
| Owner / Global Admin still cannot connect | Owner is `actions: ["*"]`, and both AVD roles are `dataActions`, which `*` never matches. | Grant both roles explicitly. |
| `GroupTypeNotSupported` when assigning a role | The target is a Microsoft 365 (mail-enabled) group. | Use a security group; `sg-avd-<env>` already is one. |

Server-side state worth checking, in order: host pool → application group →
workspace are linked and in the same region; the `SessionDesktop` application is
published; hosts are `Available`; and both role assignments exist at their
respective scopes.

---

## Before you tear down

`azd down` runs hooks that delete the Entra ID device objects and the
`sg-avd-<env>` access group. **Group membership does not survive a teardown** —
you will re-add users after the next `azd up`.

Session host pins are also lost, because `assignedUser` is not part of the
template. Redo [step 3](#3-assign-each-user-a-session-host) after redeploying.
