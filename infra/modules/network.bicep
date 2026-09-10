@description('Location for networking resources.')
param location string
param tags object
param vnetName string
param logAnalyticsWorkspaceId string

// RFC1918-compliant private address space (172.16.0.0/12 range -> using a /16 block)
var vnetAddressPrefix = '172.16.0.0/16'
// /23 provides 507 usable addresses - large enough to hold 500 AVD session hosts
var avdSubnetPrefix = '172.16.0.0/23'
// Azure Bastion requires a dedicated subnet named exactly "AzureBastionSubnet", min /26
var bastionSubnetPrefix = '172.16.2.0/26'

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
