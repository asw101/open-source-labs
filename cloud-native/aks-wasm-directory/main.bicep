@description('Azure region for the AKS cluster.')
param location string = resourceGroup().location

@description('Name of the AKS cluster.')
param clusterName string = 'aks-wasm-directory'

@description('VM size for the learning cluster nodes.')
param vmSize string = 'Standard_D2s_v5'

@description('Node count. Two nodes give the registry, PostgreSQL, Envoy Gateway, and cert-manager room to schedule.')
@minValue(1)
@maxValue(5)
param nodeCount int = 2

@description('OS disk size in GiB for the system pool. 0 lets AKS pick its default.')
@minValue(0)
@maxValue(1024)
param osDiskSizeGB int = 0

@description('OS disk type for the system pool. Ephemeral requires a compatible VM size and disk size.')
@allowed([
  'Managed'
  'Ephemeral'
])
param osDiskType string = 'Managed'

@description('Public application hostname. Leave empty to use an Azure-provided DNS label.')
param domainName string = ''

@description('Optional Azure-managed public IP DNS label. With no domainName, leave empty to derive a stable unique label.')
param dnsLabel string = ''

@description('Use a self-signed certificate instead of the default Azure DNS-label and Let\'s Encrypt path. An explicit dnsLabel may still annotate the public IP.')
param selfSigned bool = false

@description('Optional email address for the Let\'s Encrypt ACME account.')
param acmeEmail string = ''

var useSelfSigned = domainName == '' && selfSigned
var useAzureProvidedHostname = domainName == '' && !useSelfSigned
var useDnsLabel = dnsLabel != '' || useAzureProvidedHostname
var suffix = substring(uniqueString(resourceGroup().id), 0, 6)
var generatedDnsLabel = 'wasm-directory-${uniqueString(resourceGroup().id, clusterName, toLower(location))}'
var effectiveDnsLabel = dnsLabel != '' ? dnsLabel : generatedDnsLabel

resource cluster 'Microsoft.ContainerService/managedClusters@2026-01-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  properties: {
    dnsPrefix: '${clusterName}-${suffix}'
    enableRBAC: true
    agentPoolProfiles: [
      union(
        {
          name: 'systempool'
          count: nodeCount
          vmSize: vmSize
          mode: 'System'
          osType: 'Linux'
          osSKU: 'AzureLinux3'
          osDiskType: osDiskType
        },
        osDiskSizeGB == 0 ? {} : { osDiskSizeGB: osDiskSizeGB }
      )
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkPolicy: 'azure'
      loadBalancerSku: 'standard'
    }
  }
}

output clusterName string = cluster.name
output domainName string = domainName != ''
  ? domainName
  : (useAzureProvidedHostname ? '${effectiveDnsLabel}.${toLower(location)}.cloudapp.azure.com' : 'wasm-directory.local')
output dnsLabel string = useDnsLabel ? effectiveDnsLabel : ''
output clusterLocation string = toLower(location)
output acmeEmail string = acmeEmail
output certificateMode string = useAzureProvidedHostname
  ? 'letsencrypt-azure-http01'
  : (useSelfSigned ? 'selfsigned' : 'letsencrypt-http01')
