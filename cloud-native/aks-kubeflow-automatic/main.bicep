@description('Name of the AKS cluster.')
param clusterName string = 'aks-kubeflow-automatic'

@description('Azure region for the cluster. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Object ID granted Azure Kubernetes Service RBAC Cluster Admin on the cluster. Required for Automatic, which uses Microsoft Entra ID authentication. Leave empty to skip the role assignment.')
param signedinuser string = ''

@description('Principal type of signedinuser.')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param signedinuserType string = 'User'

@description('Kubernetes version. Leave empty to take the AKS default for the region.')
param kubernetesVersion string = ''

var versionProperties = empty(kubernetesVersion)
  ? {}
  : {
      kubernetesVersion: kubernetesVersion
    }

resource cluster 'Microsoft.ContainerService/managedClusters@2026-05-01' = {
  name: clusterName
  location: location
  sku: {
    name: 'Automatic'
    tier: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: versionProperties
}

// az aks create grants the caller this role automatically; a template deployment
// does not, so kubectl would be denied without it.
var aksRbacClusterAdminRoleId = 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b'

resource clusterAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(signedinuser)) {
  name: guid(cluster.id, signedinuser, aksRbacClusterAdminRoleId)
  scope: cluster
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aksRbacClusterAdminRoleId)
    principalId: signedinuser
    principalType: signedinuserType
  }
}

// The overlay annotates the Istio ingress Service with this label, so it must
// be deterministic and known before Kubeflow is installed.
var dnsLabel = 'kubeflow-${uniqueString(resourceGroup().id, clusterName, toLower(location))}'

output aksClusterName string = cluster.name
output kubernetesVersion string = cluster.properties.kubernetesVersion
output location string = cluster.location
output dnsLabel string = dnsLabel
output kubeflowHostname string = '${dnsLabel}.${toLower(location)}.cloudapp.azure.com'
