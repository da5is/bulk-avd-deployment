targetScope = 'subscription'

@minLength(1)
@maxLength(20)
@description('Name of the azd environment. Used as a naming prefix/suffix for all resources.')
param environmentName string

@minLength(1)
@description('Azure region for VM, networking, and monitoring resources.')
param location string

@allowed([
  'centralindia'
  'uksouth'
  'ukwest'
  'eastasia'
  'southeastasia'
  'japaneast'
  'japanwest'
  'australiaeast'
  'canadaeast'
  'canadacentral'
  'northeurope'
  'westeurope'
  'koreacentral'
  'southafricanorth'
  'eastus'
  'westus'
  'westus2'
  'westus3'
  'northcentralus'
  'southcentralus'
  'westcentralus'
  'centralus'
  'eastus2'
])
@description('Azure region for the AVD control plane (host pool, application group, workspace). Must be one of the regions where Microsoft.DesktopVirtualization/hostpools is available; may differ from "location".')
param hostPoolLocation string = location

@description('Local administrator username for AVD session host VMs.')
param adminUsername string = 'avdadmin'

@secure()
@minLength(12)
@description('Local administrator password for AVD session host VMs. Set via: azd env set AVD_ADMIN_PASSWORD <value>')
param adminPassword string

@minValue(1)
@maxValue(500)
@description('Number of AVD session host VMs to deploy (1-500).')
param sessionHostCount int

// Param names are prefixed with "vnet" so azd's alphabetical prompt ordering (it sorts
// Bicep parameter names before prompting for missing values) asks for the VNet address
// space before the subnets that must fall within it.
@description('VNet address space in CIDR notation, e.g. 172.16.0.0/16 (RFC1918-compliant). Set via: azd env set AVD_VNET_ADDRESS_PREFIX <cidr>')
param vnetAddressPrefix string

@description('snet-avd subnet CIDR, must fall within vnetAddressPrefix and be large enough for sessionHostCount (e.g. 172.16.0.0/23 for up to 500 hosts). Set via: azd env set AVD_SESSION_HOST_SUBNET_PREFIX <cidr>')
param vnetAvdSubnetPrefix string

@description('AzureBastionSubnet CIDR (min /26), must fall within vnetAddressPrefix, e.g. 172.16.2.0/26. Set via: azd env set AVD_BASTION_SUBNET_PREFIX <cidr>')
param vnetBastionSubnetPrefix string

@description('Time (UTC) the host pool registration token is generated. Do not set manually.')
param tokenTimestamp string = utcNow('u')

@allowed([
  'Direct'
  'Automatic'
])
@description('Personal desktop assignment type. "Direct" allows assigning a specific user to a specific session host; "Automatic" disables manual assignment. Set via: azd env set AVD_ASSIGNMENT_TYPE <value>')
param personalDesktopAssignmentType string = 'Direct'

@description('Object ID of the Entra ID user or group granted desktop access and session host sign-in. Set via: azd env set AVD_USER_PRINCIPAL_ID <objectId>')
param avdUserPrincipalId string = ''

@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
@description('Principal type of avdUserPrincipalId. Set via: azd env set AVD_USER_PRINCIPAL_TYPE <User|Group>')
param avdUserPrincipalType string = 'Group'

@description('Comma-separated Entra ID *group* object IDs granted desktop access. Groups must be security-enabled. Set via: azd env set AVD_USER_GROUP_IDS <id1,id2>')
param avdUserGroupIds string = ''

@description('Comma-separated Entra ID *user* object IDs granted desktop access. Required for a user to appear in the portal\'s session host "Assign" picker. Set via: azd env set AVD_USER_IDS <id1,id2>')
param avdUserIds string = ''

var tags = {
  'azd-env-name': environmentName
}

var monitoringRgName = 'rg-${environmentName}-monitoring'
var avdRgName = 'rg-${environmentName}-avd'
var workspaceName = 'law-${environmentName}'
var vnetName = 'vnet-${environmentName}'
var bastionName = 'bas-${environmentName}'
var uniqueSuffix = take(uniqueString(subscription().subscriptionId, environmentName), 4)
var vmNamePrefix = 'avd${uniqueSuffix}'

// -----------------------------------------------------------------------------
// Resource Groups
// -----------------------------------------------------------------------------
resource rgMonitoring 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: monitoringRgName
  location: location
  tags: tags
}

resource rgAvd 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: avdRgName
  location: location
  tags: tags
}

// -----------------------------------------------------------------------------
// Central Log Analytics workspace + Data Collection Rule (monitoring RG)
// -----------------------------------------------------------------------------
module logAnalytics 'modules/log-analytics.bicep' = {
  name: 'log-analytics'
  scope: rgMonitoring
  params: {
    location: location
    tags: tags
    workspaceName: workspaceName
  }
}

module dcr 'modules/monitoring-dcr.bicep' = {
  name: 'monitoring-dcr'
  scope: rgMonitoring
  params: {
    location: location
    tags: tags
    dcrName: 'dcr-${environmentName}'
    workspaceId: logAnalytics.outputs.workspaceId
  }
}

// AVD Insights workbook (multi-tab: connections, errors, checkpoints, agent health,
// management activities, session host performance/events) sourced from the same LA workspace.
module avdInsightsWorkbook 'modules/avd-insights-workbook.bicep' = {
  name: 'avd-insights-workbook'
  scope: rgMonitoring
  params: {
    location: location
    tags: tags
    environmentName: environmentName
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
  }
}

// Subscription Activity Log -> Log Analytics
module activityLog 'modules/activity-log-diagnostics.bicep' = {
  name: 'activity-log-diagnostics'
  params: {
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
  }
}

// -----------------------------------------------------------------------------
// Networking (AVD RG): VNet, NAT Gateway, Bastion subnet
// -----------------------------------------------------------------------------
module network 'modules/network.bicep' = {
  name: 'network'
  scope: rgAvd
  params: {
    location: location
    tags: tags
    vnetName: vnetName
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    vnetAddressPrefix: vnetAddressPrefix
    avdSubnetPrefix: vnetAvdSubnetPrefix
    bastionSubnetPrefix: vnetBastionSubnetPrefix
  }
}

module bastion 'modules/bastion.bicep' = {
  name: 'bastion'
  scope: rgAvd
  params: {
    location: location
    tags: tags
    bastionName: bastionName
    bastionSubnetId: network.outputs.bastionSubnetId
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
  }
}

// -----------------------------------------------------------------------------
// AVD control plane (host pool, application group, workspace)
// -----------------------------------------------------------------------------
module avd 'modules/avd.bicep' = {
  name: 'avd'
  scope: rgAvd
  params: {
    location: hostPoolLocation
    tags: tags
    environmentName: environmentName
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    tokenTimestamp: tokenTimestamp
    personalDesktopAssignmentType: personalDesktopAssignmentType
    avdUserPrincipalId: avdUserPrincipalId
    avdUserPrincipalType: avdUserPrincipalType
    avdUserGroupIds: avdUserGroupIds
    avdUserIds: avdUserIds
  }
}

// -----------------------------------------------------------------------------
// AVD session hosts (personal, dedicated, persistent, B-series, 128GB standard disk)
// -----------------------------------------------------------------------------
module sessionHosts 'modules/session-hosts.bicep' = {
  name: 'session-hosts'
  scope: rgAvd
  params: {
    location: location
    tags: tags
    subnetId: network.outputs.avdSubnetId
    adminUsername: adminUsername
    adminPassword: adminPassword
    hostPoolName: avd.outputs.hostPoolName
    hostPoolRegistrationToken: avd.outputs.registrationToken
    sessionHostCount: sessionHostCount
    vmNamePrefix: vmNamePrefix
    dataCollectionRuleId: dcr.outputs.dcrId
  }
}

output MONITORING_RESOURCE_GROUP string = rgMonitoring.name
output AVD_RESOURCE_GROUP string = rgAvd.name
output LOG_ANALYTICS_WORKSPACE_NAME string = workspaceName
output AVD_HOST_POOL_NAME string = avd.outputs.hostPoolName
output AVD_WORKSPACE_NAME string = avd.outputs.workspaceName
output AVD_INSIGHTS_WORKBOOK_ID string = avdInsightsWorkbook.outputs.workbookId
// Consumed by scripts/cleanup-entra-devices.ps1 so the azd hooks can find the session host
// device objects in Entra ID even after the resource group has been torn down.
output AVD_VM_NAME_PREFIX string = vmNamePrefix
