targetScope = 'subscription'

param logAnalyticsWorkspaceId string

// Ships subscription-level Activity Log to the central Log Analytics workspace.
resource activityLogDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'activity-log-to-la'
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
