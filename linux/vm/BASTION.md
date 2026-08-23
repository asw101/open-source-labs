# BASTION

Install the extension

```bash
az extension add --name ssh
```

Connect via Azure Bastion

This lab's template reserves the `AzureBastionSubnet`, but it does not deploy a Bastion host. You create the host by following Microsoft's [Create an Azure Bastion host using the Azure portal tutorial](https://learn.microsoft.com/azure/bastion/tutorial-create-host-portal#createhost), so `BASTION_NAME` must be the name you chose.

Set `RESOURCE_GROUP` to the lab's resource group before running this snippet. `VM_NAME` defaults to `vm1`; if you passed a custom `vmName` when deploying the template, use that name instead.

```bash
: "${RESOURCE_GROUP:?Set RESOURCE_GROUP to the resource group for this lab}"
VM_NAME='vm1'
# Illustrative example only. Replace this with the name you chose for your Bastion host.
BASTION_NAME="${RESOURCE_GROUP}-vnet-bastion"
RESOURCE_ID=$(az vm show -g $RESOURCE_GROUP -n $VM_NAME --out tsv --query 'id')
az network bastion ssh \
    --name $BASTION_NAME \
    --resource-group $RESOURCE_GROUP \
    --target-resource-id $RESOURCE_ID \
    --auth-type 'ssh-key' \
    --username 'azureuser' \
    --ssh-key ~/.ssh/id_rsa
```
