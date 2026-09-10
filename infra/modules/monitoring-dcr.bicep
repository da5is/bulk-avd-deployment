@description('Location for the Data Collection Rule.')
param location string
param tags object
param dcrName string
param workspaceId string

// Collects Windows event logs and key performance counters from AVD session hosts
// and ships them to the central Log Analytics workspace via Azure Monitor Agent.
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: dcrName
  location: location
  tags: tags
  properties: {
    dataSources: {
      windowsEventLogs: [
        {
          name: 'eventLogsDataSource'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: [
            'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
            'System!*[System[(Level=1 or Level=2 or Level=3)]]'
            'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational!*'
          ]
        }
      ]
      performanceCounters: [
        {
          name: 'perfCounterDataSource'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\Processor(_Total)\\% Processor Time'
            '\\Memory\\Available MBytes'
            '\\LogicalDisk(_Total)\\% Free Space'
            '\\User Input Delay per Session(*)\\Max Input Delay'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: workspaceId
          name: 'laDestination'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Event'
        ]
        destinations: [
          'laDestination'
        ]
      }
      {
        streams: [
          'Microsoft-Perf'
        ]
        destinations: [
          'laDestination'
        ]
      }
    ]
  }
}

output dcrId string = dcr.id
