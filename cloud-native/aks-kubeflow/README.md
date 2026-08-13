# Kubeflow on Azure Kubernetes Service (AKS)

[Walkthrough (vimeo.com)](https://vimeo.com/asw101/aks-kubeflow)

This lab is the Advanced scenario for deployment of Kubeflow using [just](https://just.systems/) and the included [Justfile](Justfile) for automation of deployment steps. See [BASIC-CLI.md](BASIC-CLI.md) for the Basic scenario, which provides manual steps without any further automation, configuration of ingress, TLS, and a stronger default password.

## Requirements

- [just](https://just.systems/man/en/packages.html)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [curl](https://curl.se/)
- [OpenSSL](https://www.openssl.org/)
- [Python 3](https://www.python.org/) with [bcrypt](https://pypi.org/project/bcrypt/) (`python3 -m pip install bcrypt`)

## Commands

```console
$ just --list
Available recipes:
    aks              # Create the Azure Kubernetes Service cluster.
    aks-credentials  # Get credentials for the AKS cluster.
    aks-kubectl      # Install kubectl through the Azure CLI.
    checkout         # Discard changes in the cloned manifests repository.
    clean            # Remove the cloned manifests repository.
    clone            # Clone the configured Kubeflow manifests release.
    configure-dex    # Configure Dex with a generated password and record it in auth.md.
    configure-tls    # Configure TLS for the ingress gateway's public IP address.
    default
    ensure-kustomize # Install kustomize 3.2.0 in /usr/local/bin.
    group-create     # Create the Azure resource group.
    group-delete     # Delete the Azure resource group and everything in it.
    group-empty      # Empty the resource group, leaving the group itself in place.
    kubectl-ready    # Wait for every Kubeflow pod to become ready.
    kubeflow         # Install Kubeflow from the cloned manifests, retrying transient apply failures.
    kubeflow-all     # Run the complete Kubeflow deployment and configuration sequence.
    kubeflow-delete  # Delete Kubeflow resources defined by the cloned manifests.
    kubeflow-pods    # List pods in each Kubeflow namespace.
    kubeflow-port    # Forward local port 8080 to the Kubeflow ingress gateway.
    password         # Generate a 32-character password and its cost-12 bcrypt hash.
    patch            # Copy the AKS-specific manifest overlays into the cloned manifests.
    restart-dex      # Restart the Dex deployment.
    wait seconds     # Wait for the specified number of seconds.
```

## Deployment

```bash
# confirm tools
sudo just ensure-kustomize
just aks-kubectl

# kubernetes
just group-create
just aks
just aks-credentials

# kubeflow
just kubeflow-all
# or
just clean
just clone
just configure-dex
just patch
just kubeflow
just kubectl-ready
just restart-dex
just configure-tls
```
