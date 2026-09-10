@description('Location for session host VMs.')
param location string
param tags object
param subnetId string
param adminUsername string

@secure()
param adminPassword string

param hostPoolName string

@secure()
param hostPoolRegistrationToken string

param sessionHostCount int
param vmNamePrefix string
param dataCollectionRuleId string

// B-series, 4GB RAM (2 vCPU) - matches "B-Series with 4GB of memory" requirement
var vmSize = 'Standard_B2s'

resource nics 'Microsoft.Network/networkInterfaces@2023-05-01' = [for i in range(0, sessionHostCount): {
  name: '${vmNamePrefix}${i}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}]

resource vms 'Microsoft.Compute/virtualMachines@2023-03-01' = [for i in range(0, sessionHostCount): {
  name: take('${vmNamePrefix}${i}', 15)
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: take('${vmNamePrefix}${i}', 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'windows-11'
        sku: 'win11-23h2-avd'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        // 128GB standard managed disk, dedicated persistent OS disk per user
        diskSizeGB: 128
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nics[i].id
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
  }
}]

// Entra ID (Azure AD) join - no on-prem AD/domain controller required ("cloud only")
resource aadJoinExtension 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = [for i in range(0, sessionHostCount): {
  parent: vms[i]
  name: 'AADLoginForWindows'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.2'
    autoUpgradeMinorVersion: true
  }
}]

// Registers the VM as an AVD session host in the personal host pool
resource avdAgentExtension 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = [for i in range(0, sessionHostCount): {
  parent: vms[i]
  name: 'AVD-DSC'
  location: location
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.73'
    autoUpgradeMinorVersion: true
    settings: {
      modulesUrl: 'https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_09-08-2022.zip'
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        hostPoolName: hostPoolName
        aadJoin: true
      }
    }
    protectedSettings: {
      properties: {
        registrationInfoToken: hostPoolRegistrationToken
      }
    }
  }
  dependsOn: [
    aadJoinExtension[i]
  ]
}]

// Azure Monitor Agent - ships Windows Event Logs and perf counters to the central Log Analytics workspace
resource amaExtension 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = [for i in range(0, sessionHostCount): {
  parent: vms[i]
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.20'
    autoUpgradeMinorVersion: true
  }
  dependsOn: [
    avdAgentExtension[i]
  ]
}]

resource dcrAssociations 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = [for i in range(0, sessionHostCount): {
  name: '${vmNamePrefix}${i}-dcra'
  scope: vms[i]
  properties: {
    dataCollectionRuleId: dataCollectionRuleId
  }
  dependsOn: [
    amaExtension[i]
  ]
}]

output vmNames array = [for i in range(0, sessionHostCount): take('${vmNamePrefix}${i}', 15)]
