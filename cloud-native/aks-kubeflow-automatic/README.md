# Kubeflow on AKS Automatic: a reproduction

This lab does not produce a working Kubeflow deployment. It exists to reproduce,
in a small number of commands, the fact that the Kubeflow community distribution
cannot be installed on an [AKS Automatic](https://learn.microsoft.com/azure/aks/intro-aks-automatic)
cluster, and to print exactly which cluster policies reject it. The sibling
[`aks-kubeflow`](../aks-kubeflow/) lab is the same installation on a regular
cluster, where it succeeds.

The intended audience is the AKS product team. Everything below was observed on a
real Automatic cluster, not inferred from documentation.

## What happens

`main.bicep` creates a single AKS Automatic cluster. `just apply-kubeflow` then
renders the pinned Kubeflow release with the same overlay the sibling lab uses and
applies it once. The apply fails, and `just report` summarises the rejections.

Two independent mechanisms reject the workload. Both are enabled by Automatic and
are absent from a regular cluster.

### Azure Policy, enforced through Gatekeeper

| Constraint | What Kubeflow does |
| --- | --- |
| `k8sazurev1uniqueserviceselector` | Ships Services whose selectors and ports overlap: `cluster-local-gateway` in `istio-system`, and `kserve-controller-manager-metrics-service` in `kubeflow`. |
| `k8sazurev2containernolatestimage` | Ships container `perf-data-init` with the `:latest` tag. |

### AKS managed ValidatingAdmissionPolicies

| Policy | Rejected resources |
| --- | --- |
| `aks-managed-protect-system-namespaces` | `configmap/istio-cni-config`, `daemonset/istio-cni-node`, `rolebinding/cert-manager:leaderelection`, `rolebinding/cert-manager-cainjector:leaderelection` |
| `aks-managed-critical-addons-only` | `daemonset/istio-cni-node` |

The second group is the more fundamental of the two. Kubeflow installs Istio's CNI
components and cert-manager's leader-election RoleBindings into `kube-system`, and
Automatic exists partly to prevent workloads from writing there. A Kubeflow install
that avoided `kube-system` entirely would still have to satisfy the Azure Policy
constraints above.

An earlier run also spent 50 minutes retrying these rejections before giving up.
They are permanent, so this lab applies once and reports, rather than retrying.

## Observed result

On a `Standard` tier Automatic cluster in `canadacentral` on Kubernetes 1.35.6,
one apply produced 33 Gatekeeper denials and 110 `Forbidden` responses. The cluster
itself deployed cleanly, and `kubectl get nodes` worked through the role assignment
this template creates, so the failure is admission control rejecting Kubeflow
rather than anything wrong with the cluster.

## Versions

| Component | Version |
| --- | --- |
| AKS Kubernetes | `1.36` requested; Automatic may resolve a different patch |
| Kubeflow community distribution | `26.03.1` |
| cert-manager (bundled) | `1.20.2` |
| Istio (bundled) | `1.30.1` |
| Bicep CLI | `0.46.1` |
| Kustomize | `v5.8.1` |

## Prerequisites

- An Azure subscription, an existing resource group in an
  [Automatic-supported region](https://learn.microsoft.com/azure/aks/automatic/quick-automatic-managed-network#limitations),
  and an authenticated [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).
- Bash, [just](https://just.systems/), `curl`, `tar`, `sha256sum`, `kubectl`,
  [Kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/) `v5.8.1`,
  and `kubelogin`.
- `User Access Administrator` or `Owner` on the resource group, because the
  template creates a role assignment.

`RESOURCE_GROUP` is required. `AKS_NAME` defaults to `aks-kubeflow-automatic`.
Set `SIGNEDINUSER` to the object ID that should receive
`Azure Kubernetes Service RBAC Cluster Admin` on the cluster, and
`SIGNEDINUSER_TYPE` to `ServicePrincipal` when running as one. Automatic disables
local accounts, so without that role assignment `kubectl` is denied.

## Recipes

```console
Available recipes:
    apply-kubeflow # Attempt the Kubeflow install once and record every rejection. Expected to fail.
    clean-cache    # Remove the downloaded and extracted Kubeflow release.
    credentials    # Get credentials for the cluster. Automatic disables local accounts.
    default
    deploy-aks     # Deploy the AKS Automatic cluster at resource-group scope.
    fetch-kubeflow # Download, verify, and prepare the pinned Kubeflow release.
    group-empty    # Empty the resource group while preserving it and its scoped access.
    report         # Summarise which cluster policies rejected Kubeflow.
    validate       # Compare generated ARM with its Bicep source and preview the deployment.
```

## Reproduce

```bash
export RESOURCE_GROUP='<existing-resource-group>'
export SIGNEDINUSER="$(az ad signed-in-user show --query id --out tsv)"
just validate
just deploy-aks
just credentials
just apply-kubeflow
just report
just group-empty
```

`validate` changes nothing: it compares the committed ARM with a fresh build of
`main.bicep` and runs a resource-group what-if.

If `just apply-kubeflow` ever succeeds, the incompatibility has been fixed and this
lab's premise no longer holds. It says so rather than failing quietly.

## Cleanup

`just group-empty` removes the cluster with a Complete-mode empty deployment while
preserving the resource group and any role assignments scoped to it. Never delete
the resource group.
