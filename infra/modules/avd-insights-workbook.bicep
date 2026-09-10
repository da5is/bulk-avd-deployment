@description('Location for the workbook resource.')
param location string
param tags object
param environmentName string
param logAnalyticsWorkspaceId string

// A stable GUID for the workbook resource name so redeploys update in place instead of duplicating.
var workbookName = guid('avd-insights-workbook', environmentName)

resource avdInsightsWorkbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookName
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'AVD Insights - ${environmentName}'
    category: 'workbook'
    sourceId: logAnalyticsWorkspaceId
    serializedData: loadTextContent('avd-insights-workbook-content.json')
  }
}

output workbookId string = avdInsightsWorkbook.id
