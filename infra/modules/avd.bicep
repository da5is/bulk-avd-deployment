@description('Location for AVD control plane resources (host pool, application group, workspace). May differ from the session host VM region.')
param location string
param tags object
param environmentName string
param logAnalyticsWorkspaceId string
param tokenTimestamp string

@allowed([
  'Direct'
  'Automatic'
])
@description('Personal desktop assignment type. "Direct" lets an admin assign a specific user to a specific session host. "Automatic" assigns the first available session host on initial sign-in and disables manual assignment.')
param personalDesktopAssignmentType string = 'Direct'

@description('Object ID of the Entra ID user or group granted access to the desktop. Leave empty to skip creating role assignments. Prefer avdUserGroupIds / avdUserIds; this is kept for backwards compatibility.')
param avdUserPrincipalId string = ''

@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
@description('Principal type of avdUserPrincipalId.')
param avdUserPrincipalType string = 'Group'

@description('Comma-separated Entra ID *group* object IDs granted desktop access. Groups must be security-enabled; Microsoft 365 groups are rejected by Azure.')
param avdUserGroupIds string = ''

// The Azure portal's "Assign" picker for personal desktops only enumerates users holding a
// *direct* Desktop Virtualization User assignment on the application group - it does not expand
// groups. Users granted access solely through a group therefore never appear as candidates,
// so list them here as well to make them assignable in the portal.
@description('Comma-separated Entra ID *user* object IDs granted desktop access. Required for a user to appear in the portal\'s session host "Assign" picker.')
param avdUserIds string = ''

// enablerdsaadauth:i:1 makes clients authenticate to the Entra ID-joined session hosts with a
// Microsoft Entra ID token, which is what lets the web client and other devices that are not
// joined to this tenant sign in. It also gives single sign-on and, unlike its predecessor,
// works with multifactor authentication and Conditional Access.
//
// It replaces targetisaadjoined:i:1, which is mutually exclusive with it and must not be set
// alongside it. That property restricted sign-in to a username and password prompt, so any
// account subject to MFA or Conditional Access failed with "the credentials did not work".
//
// The token is only issued once the tenant opts in by setting isRemoteDesktopProtocolEnabled on
// the Windows Cloud Login service principal, which is a directory object ARM cannot reach - see
// scripts/enable-rdp-sso.ps1, wired into the postprovision hook.
@description('Custom RDP properties applied to the host pool.')
param customRdpProperty string = 'enablerdsaadauth:i:1;drivestoredirect:s:;usbdevicestoredirect:s:;redirectclipboard:i:0;redirectprinters:i:0;audiomode:i:0;videoplaybackmode:i:1;devicestoredirect:s:*;redirectcomports:i:1;redirectsmartcards:i:1;enablecredsspsupport:i:1;redirectwebauthn:i:1;use multimon:i:1;'

var desktopVirtualizationUserRoleId = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'
var virtualMachineUserLoginRoleId = 'fb879df8-f326-4884-b1cf-06f3ad86be52'

// Build a single {id, type} list from the legacy single-principal parameter and the two lists.
// union() drops entries that are duplicated verbatim; do not list the same object ID under two
// different principal types, as the resulting role assignment names would collide.
var legacyPrincipals = empty(avdUserPrincipalId) ? [] : [{ id: trim(avdUserPrincipalId), type: avdUserPrincipalType }]
var groupPrincipals = empty(trim(avdUserGroupIds)) ? [] : map(split(avdUserGroupIds, ','), id => { id: trim(id), type: 'Group' })
var userPrincipals = empty(trim(avdUserIds)) ? [] : map(split(avdUserIds, ','), id => { id: trim(id), type: 'User' })
var avdPrincipals = union(legacyPrincipals, groupPrincipals, userPrincipals)

// Host pool registration token, valid for a limited window used only during initial session host registration.
param tokenExpirationTime string = dateTimeAdd(tokenTimestamp, 'PT4H')

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2022-09-09' = {
  name: 'hp-${environmentName}'
  location: location
  tags: tags
  properties: {
    hostPoolType: 'Personal'
    personalDesktopAssignmentType: personalDesktopAssignmentType
    customRdpProperty: customRdpProperty
    loadBalancerType: 'Persistent'
    preferredAppGroupType: 'Desktop'
    startVMOnConnect: true
    registrationInfo: {
      expirationTime: tokenExpirationTime
      registrationTokenOperation: 'Update'
    }
  }
}

resource desktopAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2022-09-09' = {
  name: 'dag-${environmentName}'
  location: location
  tags: tags
  properties: {
    hostPoolArmPath: hostPool.id
    applicationGroupType: 'Desktop'
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2022-09-09' = {
  name: 'ws-${environmentName}'
  location: location
  tags: tags
  properties: {
    applicationGroupReferences: [
      desktopAppGroup.id
    ]
  }
}

resource hostPoolDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-la'
  scope: hostPool
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource workspaceDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-la'
  scope: workspace
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

// Lets the principal see and launch the published desktop in the AVD client.
// A user needs this assigned *directly* (not via a group) to show up in the portal's
// session host "Assign" picker for a personal host pool.
resource desktopUserRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for p in avdPrincipals: {
  name: guid(desktopAppGroup.id, p.id, desktopVirtualizationUserRoleId)
  scope: desktopAppGroup
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', desktopVirtualizationUserRoleId)
    principalId: p.id
    principalType: p.type
  }
}]

// Required to sign in to Entra ID-joined session hosts; publishing the desktop alone is not enough.
resource vmUserLoginRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for p in avdPrincipals: {
  name: guid(resourceGroup().id, p.id, virtualMachineUserLoginRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', virtualMachineUserLoginRoleId)
    principalId: p.id
    principalType: p.type
  }
}]

output hostPoolName string = hostPool.name
@secure()
output registrationToken string = hostPool.properties.registrationInfo.token
output workspaceName string = workspace.name
