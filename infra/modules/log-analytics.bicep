@description('Location for the Log Analytics workspace.')
param location string
param tags object
param workspaceName string

resource law 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

output workspaceId string = law.id
output workspaceName string = law.name
output workspaceCustomerId string = law.properties.customerId
