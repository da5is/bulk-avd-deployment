# bulk-avd-deployment

An Azure Developer CLI (`azd`) template: subscription-scoped Bicep that deploys a
monitored Azure Virtual Desktop (personal, Direct-assignment) environment, plus
PowerShell hooks that manage the two directory-object concerns ARM can't (Entra ID
device cleanup and desktop-access group sync). There is no application code — this
is infra + automation only.

## Commands

There is no build/test/lint tooling in this repo (no package.json, no Pester tests).
Validate changes with the actual `azd`/`az` toolchain:

```pwsh
az bicep build --file infra/main.bicep      # compile-check Bicep without deploying
azd provision --preview                     # what-if / validate against a real subscription
azd up                                       # full deploy (requires AVD_ADMIN_PASSWORD, prompts for AVD_SESSION_HOST_COUNT)
azd down --purge                             # full teardown
```

To run a single hook script directly (they're plain PowerShell, safe to invoke ad hoc):

```pwsh
./scripts/cleanup-entra-devices.ps1 -WhatIf          # dry-run, uses -SupportsShouldProcess
./scripts/avd-access-group.ps1 -Action Sync -WhatIf
```

## Architecture

`infra/main.bicep` is subscription-scoped (`targetScope = 'subscription'`) and
orchestrates modules under `infra/modules/` into two resource groups:

- `rg-<env>-monitoring` — Log Analytics workspace (`modules/log-analytics.bicep`),
  a Data Collection Rule (`modules/monitoring-dcr.bicep`), subscription Activity Log
  streaming (`modules/activity-log-diagnostics.bicep`), and a custom AVD Insights
  workbook (`modules/avd-insights-workbook.bicep` + its JSON payload in
  `avd-insights-workbook-content.json` — built from scratch because Microsoft's
  gallery workbook JSON isn't publishable).
- `rg-<env>-avd` — VNet/NAT/Bastion (`modules/network.bicep`, `modules/bastion.bicep`),
  AVD host pool/app group/workspace (`modules/avd.bicep`), and session host VMs
  (`modules/session-hosts.bicep`).

Module outputs chain together explicitly in `main.bicep` (e.g. `logAnalytics.outputs.workspaceId`
feeds the DCR, Bastion, network, and AVD modules; `avd.outputs.registrationToken` feeds
session host provisioning). When adding a module, wire new cross-module data through
explicit `outputs`/`params`, not shared state.

Session host VM names are deterministic:
`avd<uniqueString(subscriptionId, environmentName)><index>` (see `vmNamePrefix` in
`main.bicep`), and this prefix is exported as the `AVD_VM_NAME_PREFIX` azd output
specifically so `scripts/cleanup-entra-devices.ps1` can find matching Entra device
objects even after the resource group has been deleted.

### azd hooks (`azure.yaml`)

Two PowerShell scripts under `scripts/` are wired into four hook points and handle
directory-object concerns that ARM does not manage:

| Hook | Script | Action |
| --- | --- | --- |
| `preprovision` | `cleanup-entra-devices.ps1` | (default) delete only provably-stale device objects |
| `preprovision` | `avd-access-group.ps1` | `-Action Ensure` — create `sg-avd-<env>`, publish `AVD_USER_GROUP_IDS` |
| `postprovision` | `avd-access-group.ps1` | `-Action Sync` — materialize group members as direct role assignments |
| `predown` | `cleanup-entra-devices.ps1` | `-All` — delete every matching device (VMs about to be destroyed) |
| `postdown` | `avd-access-group.ps1` | `-Action Remove` — delete the access group |

All hooks use `continueOnError: true` and each script wraps its body in
`try { } catch { Write-Warning ... }` — cleanup/sync must never block `azd up`/`azd down`.
Both scripts are pwsh-only (cross-platform, no posix/windows split needed) and support
`-WhatIf` via `[CmdletBinding(SupportsShouldProcess)]`.

## Conventions

- **Bicep params are surfaced as azd env vars.** Every user-tunable parameter in
  `main.bicep` documents its `azd env set <VAR> <value>` form directly in the
  `@description`, and `infra/main.parameters.json` maps `${VAR}` placeholders to the
  param. When adding a parameter, follow this pattern (doc string + parameters.json entry).
- **Why-comments over what-comments.** Both scripts and `azure.yaml` favor block
  comments explaining *why* a step exists (e.g. why direct role assignments are needed
  alongside a group, why device objects must predate cleanup) rather than restating
  the code. Preserve this style in new automation.
- **Graph calls use raw REST + `az account get-access-token`**, not `Microsoft.Graph`
  PowerShell modules — keeps the scripts dependency-free beyond `az`/`pwsh`.
- **Role assignment scope discipline:** `avd-access-group.ps1` only ever touches the
  two specific AVD roles (Desktop Virtualization User, Virtual Machine User Login) at
  two exact scopes (app group, AVD resource group), and `-Prune` only removes direct
  `User`-type assignments at those exact scopes — never group or inherited assignments.
- Two-resource-group split (`monitoring` / `avd`) and the `rg-<env>-*`, `sg-avd-<env>`,
  `hp-<env>`, `dag-<env>`, `law-<env>` naming scheme are load-bearing for the hook
  scripts (they reconstruct these names from `AZURE_ENV_NAME` rather than reading
  outputs) — keep new resources consistent with this naming if hooks need to find them.

## Docs

`README.md` is the full reference (architecture, teardown caveats, RBAC gotchas).
`QUICKSTART.md` is the six-step happy path for a first deploy. `docs/post-deployment.md`
covers granting access/troubleshooting after `azd up`. Update these when behavior
they describe changes (e.g. hook order, required roles, naming scheme).
