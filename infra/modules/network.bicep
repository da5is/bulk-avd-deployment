@description('Location for networking resources.')
param location string
param tags object
param vnetName string
param logAnalyticsWorkspaceId string

@description('VNet address space in CIDR notation (e.g. 172.16.0.0/16). Set via: azd env set AVD_VNET_ADDRESS_PREFIX <cidr>')
param vnetAddressPrefix string

@description('snet-avd subnet CIDR, must fall within vnetAddressPrefix and be large enough for the session host count. Set via: azd env set AVD_SESSION_HOST_SUBNET_PREFIX <cidr>')
param avdSubnetPrefix string

@description('AzureBastionSubnet CIDR (min /26), must fall within vnetAddressPrefix. Set via: azd env set AVD_BASTION_SUBNET_PREFIX <cidr>')
param bastionSubnetPrefix string

resource natPip 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: '${vnetName}-natgw-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2023-05-01' = {
  name: '${vnetName}-natgw'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: natPip.id
      }
    ]
    idleTimeoutInMinutes: 10
  }
}

resource avdNsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: '${vnetName}-avd-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-avd'
        properties: {
          addressPrefix: avdSubnetPrefix
          natGateway: {
            id: natGateway.id
          }
          networkSecurityGroup: {
            id: avdNsg.id
          }
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
    ]
  }
}

resource vnetDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-la'
  scope: vnet
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output vnetId string = vnet.id
output avdSubnetId string = vnet.properties.subnets[0].id
output bastionSubnetId string = vnet.properties.subnets[1].id
