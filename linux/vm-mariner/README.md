# Linux on Azure with CBL-Mariner Linux 2.0 and Virtual Machines (VM)

NOTE: This lab is for experimentation with the open source [CBL-Mariner](https://github.com/microsoft/CBL-Mariner) project, and **not a currently supported offering** for Virtual Machines on Azure. For the fully-supported Azure Linux offering for AKS, see [Introducing the Azure Linux container host for AKS](https://aka.ms/azure-linux) and [Quickstart: Deploy an Azure Linux Container Host for AKS cluster by using the Azure CLI](https://learn.microsoft.com/azure/azure-linux/quickstart-azure-cli).

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure-Samples%2Fopen-source-labs%2Fmain%2Flinux%2Fvm-mariner%2Fvm.json)

## Requirements

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- Bash
- [Just](https://just.systems/) (`brew install just`, or see the [install guide](https://just.systems/man/en/packages.html))
- [curl](https://curl.se/)

## Commands

```
$ just
Available recipes:
    default
    docker-tailscale # Install Docker and optionally run Tailscale on the VM.
    group-create     # Create the Azure resource group.
    group-delete     # Delete the Azure resource group and everything in it.
    group-empty      # Empty the resource group, leaving the group itself in place.
    managed-identity # Create and assign a managed identity to the VM.
    pg               # Create an Azure Database for PostgreSQL flexible server.
    pg-admin         # Add the managed identity as PostgreSQL server administrator.
    run-script       # Run VM_COMMAND, if set, followed by VM_SCRIPT on the VM.
    ssh              # Print the SSH command for the VM.
    ssh-key          # Create an SSH key resource for Azure VMs.
    subscription     # Switch between the SUB1 and SUB2 Azure subscriptions.
    vm               # Create the Azure VM directly with the Azure CLI.
    vm-bicep         # Deploy vm.bicep at resource group scope.
```

Create the resource group and deploy the Bicep template:

```
just group-create vm-bicep
```

Empty the group while preserving it and its scoped role assignments, or delete
the group and everything in it:

```
just group-empty
just group-delete
```
