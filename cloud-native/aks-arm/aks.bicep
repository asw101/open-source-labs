@description('The name of the Managed Cluster resource.')
param clusterName string = 'aks-arm'

@description('The location of the Managed Cluster resource.')
param location string = resourceGroup().location

@description('Optional DNS prefix to use with hosted Kubernetes API server FQDN.')
param dnsPrefix string

@description('Disk size (in GB) to provision for each of the agent pool nodes. Specifying 0 applies the default disk size for the VM size.')
@minValue(0)
@maxValue(1023)
param osDiskSizeGB int = 0

@description('The number of nodes in each agent pool.')
@minValue(1)
@maxValue(50)
param agentCount int = 1

@description('The size of the Azure Cobalt 100 Arm-based virtual machines.')
param agentVMSize string = 'Standard_D2pds_v6'

@description('User name for the Linux virtual machines.')
param linuxAdminUsername string

@description('SSH RSA public key used to access the Linux virtual machines.')
param sshRSAPublicKey string

resource aks 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    agentPoolProfiles: [
      {
        count: agentCount
        mode: 'System'
        name: 'system1'
        osDiskSizeGB: osDiskSizeGB
        osSKU: 'AzureLinux'
        osType: 'Linux'
        vmSize: agentVMSize
      }
      {
        count: agentCount
        mode: 'User'
        name: 'user1'
        osDiskSizeGB: osDiskSizeGB
        osSKU: 'AzureLinux'
        osType: 'Linux'
        vmSize: agentVMSize
      }
    ]
    linuxProfile: {
      adminUsername: linuxAdminUsername
      ssh: {
        publicKeys: [
          {
            keyData: sshRSAPublicKey
          }
        ]
      }
    }
  }
}

output controlPlaneFQDN string = aks.properties.fqdn
