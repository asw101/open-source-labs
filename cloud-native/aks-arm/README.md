# Deploy Azure Kubernetes Service (AKS) with Bicep on Azure Cobalt Arm-based VMs

Deploys [Azure Kubernetes Service (AKS)](https://learn.microsoft.com/azure/aks/what-is-aks) as a raw Bicep resource running [Azure Linux](https://learn.microsoft.com/azure/aks/use-azure-linux) on [Azure Cobalt 100 Arm-based VMs](https://learn.microsoft.com/azure/virtual-machines/sizes/cobalt-overview).

## Deploy via Azure Portal

[Deploy to Azure](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure-Samples%2Fazure-opensource-labs%2Fmain%2Fcloud-native%2Faks-arm%2Faks.json)

## Prerequisites

- Azure Subscription
- Azure CLI
- Bicep

## Deploy via Azure CLI

Azure Linux 3 no longer needs a preview feature registration. It is a first
class `osSKU` value on the stable `2026-05-01` API version this template uses,
and the template defaults to it. Verified on 2026-08-11: with
`AzureLinuxV3Preview` reporting `NotRegistered`, a deployment of this template
still came up on Azure Linux V3 node images.

Create resource group:

```bash
az group create \
    --name 250100-aks \
    --location eastus
```

Deploy Azure Kubernetes Service (AKS) cluster:

```bash
az deployment group create \
    --resource-group 250100-aks \
    --template-file cloud-native/aks-arm/aks.bicep
```

## Cleanup

Deploy the empty Bicep template:

```bash
az deployment group create \
    --resource-group 250100-aks \
    --mode Complete \
    --template-file cloud-native/aks-arm/empty.bicep
```
