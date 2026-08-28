# Run the wasm.directory component registry on AKS over automatic HTTPS

This lab deploys [wasm.directory](https://github.com/yoshuawuyts/wasm.directory), a package manager and meta-registry for WebAssembly Components, onto an Azure Kubernetes Service (AKS) cluster, and serves it over a publicly trusted HTTPS endpoint with no domain, DNS records, or credentials to configure.

The registry's own frontend is a **WebAssembly Component compiled to `wasm32-wasip2` and served by `wasmtime serve`**. Putting that workload behind a Kubernetes Gateway is the part of this lab worth reading: the web server is a Wasm component, and nothing about the Gateway, the Service, or the probes has to know that.

The traffic layer is the same one as [aks-https-gateway](../aks-https-gateway/): [Envoy Gateway](https://gateway.envoyproxy.io/) 1.9.0 as the Gateway API implementation, cert-manager with Let's Encrypt, TLS fixed at 1.3 by an Envoy `ClientTrafficPolicy`, and HTTP permanently redirected to HTTPS. Azure publishes a stable, deployment-specific `cloudapp.azure.com` hostname for the Gateway public IP, so the certificate is obtained over HTTP-01 without a domain of your own.

The lab finishes by pointing the project's **stock, unmodified `component` CLI** at the deployment with a single environment variable, and syncing the package index through it. That is the proof that this is a working registry and not just a set of containers that started.

## Requirements

- An **Azure Subscription** (e.g. [Free](https://aka.ms/azure-free-account) or [Student](https://aka.ms/azure-students))
- The [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.86.0 or later
- A Bash shell (macOS, Linux, [Windows Subsystem for Linux (WSL)](https://learn.microsoft.com/windows/wsl/about), [Azure Cloud Shell](https://learn.microsoft.com/azure/cloud-shell/get-started), or [GitHub Codespaces](https://github.com/features/codespaces))
- [Just](https://just.systems/) (`brew install just`, or see the [install guide](https://just.systems/man/en/packages.html))
- The `diff` utility
- An existing resource group
- A domain is optional. The default path uses an Azure-provided hostname.

The default `standard` size does not require local `kubectl`, Helm, cluster credentials, or network access to the Kubernetes API. [`az aks command invoke`](https://learn.microsoft.com/cli/azure/aks/command#az-aks-command-invoke) supplies `kubectl` and Helm inside the cluster.

The smaller `dev` size requires [kubectl](https://kubernetes.io/docs/tasks/tools/), [Helm](https://helm.sh/docs/intro/install/), curl, jq, and OpenSSL on the client, plus network access to the Kubernetes API. The in-cluster command pod reserves 400m CPU and 1000Mi memory, which does not fit while the workload is scheduling on the 4 GiB development node.

## Instructions

Login to Azure and change to this directory.

```bash
az login
cd cloud-native/aks-wasm-directory
```

Set the only required variable. The resource group must already exist.

```bash
export RESOURCE_GROUP='my-existing-resource-group'
```

Running `just` lists the available recipes.

```console
$ just
Available recipes:
    default
    deploy      # Deploy AKS, then install the selected wasm.directory size and HTTPS.
    group-empty # Empty the resource group while preserving the group and its scoped access.
    validate    # Check generated ARM and preview the deployment without changing resources.
    verify      # Prove the deployment end to end: a stock component CLI driving it over HTTPS.
    wait-http01 # Wait for HTTP-01 certificate issuance after creating the printed public DNS record.
```

### Deploy

```bash
just validate
just deploy
just verify
```

`validate` builds fresh ARM JSON from [main.bicep](./main.bicep), requires an empty diff against the committed [main.json](./main.json), syntax-checks both shell scripts, and requests a resource-group-scoped what-if preview.

`deploy` runs one ARM deployment to create the cluster, then installs Envoy Gateway, cert-manager, the database, the meta-registry backend, the Wasm frontend, the Gateway, and the routes. The standard size uses `az aks command invoke`; the dev size obtains a temporary client kubeconfig and runs Helm and the installer locally. It waits for the certificate and prints the endpoint. Expect roughly 15 minutes end to end, most of it cluster creation and the Let's Encrypt HTTP-01 round trip.

`verify` is the part to read the output of. It runs [verify.sh](./verify.sh) against the public endpoint, inside the cluster for `standard` and from the client for `dev`. It checks the certificate is publicly trusted and issued by Let's Encrypt, that TLS 1.3 is accepted and TLS 1.2 rejected, that HTTP redirects, that `/` serves the Wasm frontend and `/v1` the registry API, that the indexer has actually indexed packages, and finally that a stock `component` CLI can sync through the deployment.

### Size profiles

`SIZE=standard|dev` selects the complete cluster and workload profile. It defaults to `standard`.

| Setting | `standard` | `dev` |
| --- | --- | --- |
| Nodes | 2 x `Standard_D2s_v5` | 1 x `Standard_B2s` |
| OS disk | AKS default managed disk | 30 GiB ephemeral disk |
| Database | PostgreSQL 17, 8Gi PVC | SQLite on the backend's 4Gi PVC |
| Backend | 1 replica, 16Gi PVC | 1 replica, 4Gi PVC |
| Frontend | 2 replicas | 1 replica |
| Installer | In-cluster command pod | Local Helm and kubectl |

The standard profile preserves the original lab behavior. The dev default is the configuration proven end to end on a 4 GiB burstable node, with no billed OS disk. It has no node redundancy, no rolling-update overlap for the frontend, does not rehearse PostgreSQL, and leaves little scheduling headroom.

Choose the profile when creating a cluster. Agent-pool VM and OS disk properties are immutable, and the backend StatefulSet changes its database and PVC template between profiles. To switch an existing deployment, use a different `AKS_NAME`, or empty a dedicated lab resource group before redeploying.

Deploy the development profile with:

```bash
SIZE=dev just validate
SIZE=dev just deploy
SIZE=dev just verify
```

`VM_SIZE`, `NODE_COUNT`, `OS_DISK_SIZE`, and `OS_DISK_TYPE` remain independently configurable. The dev defaults select the tested `Standard_B2s` with a free ephemeral OS disk:

```bash
SIZE=dev \
VM_SIZE=Standard_B2s \
OS_DISK_TYPE=Ephemeral \
OS_DISK_SIZE=30 \
just deploy
```

An ephemeral OS disk is recreated when AKS replaces or deallocates the node. The backend data remains on its separate managed-disk PVC. To use the previously proven managed-disk shape instead, set `VM_SIZE=Standard_B2ls_v2 OS_DISK_TYPE=Managed OS_DISK_SIZE=32`; at the measured retail rates it costs $61.02/month instead of $56.22/month.

### Certificate paths

With no certificate variables set, the lab uses its zero-configuration path: Bicep derives `wasm-directory-<uniqueString>` from the resource-group ID, cluster name, and region, and Azure publishes `<label>.<region>.cloudapp.azure.com` for the Gateway public IP.

| Path | Configuration | Result |
| --- | --- | --- |
| Let's Encrypt with an Azure-provided name (default) | Set no certificate variables. Optionally set `DNS_LABEL`. | Azure assigns `<label>.<region>.cloudapp.azure.com`. cert-manager completes HTTP-01 with no domain, no manual record, and no DNS credentials. |
| Let's Encrypt with your own hostname | Set `DOMAIN` and a unique `DNS_LABEL`. | The lab prints a stable Azure alias target. Create one public CNAME, then run `just wait-http01`. |
| Explicit self-signed fallback | Set `SELF_SIGNED=true`. | HTTPS at `wasm-directory.local` with a certificate that is **not** publicly trusted. Use the printed `curl --insecure --resolve ...` command. |

`DNS_LABEL` must contain 1-63 lowercase letters, digits, or hyphens and must start and end with a letter or digit, and must be unique within the region. Envoy Gateway creates the Gateway's `LoadBalancer` Service, so the lab references a namespaced `EnvoyProxy` from the `GatewayClass` and uses `spec.provider.kubernetes.envoyService.annotations` to put `service.beta.kubernetes.io/azure-dns-label-name` on that generated Service.

The Azure DNS DNS-01 path with ExternalDNS is deliberately not reproduced here; [aks-https-gateway](../aks-https-gateway/) covers it, and the subject of this lab is the registry rather than the certificate.

## What gets deployed

- AKS with Azure Linux 3 using the selected size profile
- Envoy Gateway 1.9.0, cert-manager 1.21.1, and Gateway API resources
- PostgreSQL 17 with an 8Gi PVC for `standard`, or SQLite on the backend PVC for `dev`
- `component-meta-registry` as a single-replica `StatefulSet` with a profile-sized PVC
- `component-frontend`, two replicas for `standard` or one for `dev`, serving a `wasm32-wasip2` component under `wasmtime serve`
- One `Gateway` with an HTTP listener that redirects, and an HTTPS listener whose certificate Secret cert-manager generates and renews
- Two `HTTPRoute`s on the HTTPS listener: `/v1` to the registry API, `/` to the frontend

The frontend pods keep a read-only root filesystem and a non-root user, with one concession: an `emptyDir` mounted at `/home/nonroot` with `HOME` pointed at it. `wasmtime serve` compiles the component on startup and writes the result to a cache under `$HOME`, and overriding `runAsUser` leaves the container without a passwd entry, so `HOME` resolves to `/`. Without the volume the pod exits immediately with `failed to create cache directory: /.cache/wasmtime`. Giving it a writable directory keeps the read-only root rather than trading it away.

Both application images are the project's **own release artifacts**, `ghcr.io/yoshuawuyts/wasm.directory/{backend,frontend}` at v0.15.0, pinned by digest. Nothing is rebuilt. They are published `linux/amd64` only, so this lab's node pool must be x86-64; unlike `aks-https-gateway` there is no ARM64 variant to fall back to.

## Five things the source decides for you

Most of the design of this lab is not a matter of taste. Five properties of the upstream code determine it, and getting any of them wrong produces a deployment that starts cleanly and is then subtly wrong.

### 1. The backend Service must be named `backend` and listen on port 80

The frontend resolves its API base URL with `option_env!("API_BASE_URL")` ([`crates/wasm-meta-registry-client/src/client.rs`](https://github.com/yoshuawuyts/wasm.directory/blob/main/crates/wasm-meta-registry-client/src/client.rs)). That is a **compile-time** value baked into the WebAssembly binary, not an environment variable read at runtime, so it cannot be overridden by a Deployment. The published image is built with `API_BASE_URL=http://backend`, the form Azure Container Apps needs, where an app is reached by name on its ingress port 80.

Kubernetes makes that same string work unchanged: a Service named `backend` on port 80, forwarding to the container's 8081. This is why the lab consumes the published image rather than rebuilding it, and it is also the single most likely way a variant of this deployment breaks. `http://backend:8081` does not route in Container Apps and makes the frontend panic on every backend-backed request; here the failure would be the mirror image, a Service on the wrong port with an image you cannot reconfigure.

### 2. One hostname is enough, because every API route is under `/v1`

All twelve meta-registry routes live under `/v1` ([`crates/component-meta-registry/src/server.rs`](https://github.com/yoshuawuyts/wasm.directory/blob/main/crates/component-meta-registry/src/server.rs)), and the client builds its URLs as `<COMPONENT_REGISTRY_URL>/v1/...`. So a `/v1` `PathPrefix` route to the backend is all the CLI needs, and the registry does not require a second `api.` hostname the way the Container Apps deployment gives it.

That matters more than it sounds: it is what lets the zero-configuration certificate path carry the whole lab. With only one Azure-provided hostname available, a design that needed two hostnames would have forced every reader to bring a domain.

Gateway API gives the longer `/v1` prefix precedence over the frontend's `/`, and gives cert-manager's generated `Exact` match on `/.well-known/acme-challenge/` precedence over both, so issuance and renewal are not caught by the HTTP-to-HTTPS redirect.

There is one cost to sharing a hostname, and it is worth stating rather than discovering. The frontend routes `/{namespace}` to a namespace page, so a registry namespace named `v1` would be shadowed by the API route and unreachable through the browser. No such namespace exists in `registry/`, and the Container Apps deployment avoids the question by giving the backend its own `api.` hostname. If you need that separation, set `DOMAIN` to a hostname you control and add a second listener rather than splitting on path.

### 3. The backend runs one replica, and that is a correctness requirement

The backend process is an API server **and** a background OCI indexer. With `COMPONENT_DATABASE_URL` pointing at PostgreSQL, the indexer's work queue is a shared `fetch_queue` table, and the claim on it is not atomic. `Store::dequeue_next` runs a plain non-locking `SELECT` for a pending row and then an `UPDATE` keyed only on the row id, in a `READ COMMITTED` transaction with no `status = 'pending'` guard. Two replicas both see the row as pending, both update it by id, and both proceed. The comment in the source says as much:

> SQLite serializes writes anyway; on Postgres this would benefit from `FOR UPDATE SKIP LOCKED`, which we can add later if multi-worker contention becomes an issue.

The consequences are not merely duplicated work. `fail_task` resets a row to `pending` with no status guard, so one replica failing a task that another already completed resurrects it, and three cycles later marks it `failed`, which is then what `GET /v1/queue` reports. Worse, `reindex_tag` deletes WIT rows and commits before re-extracting, while `try_extract_wit_package` swallows its errors into a warning, so two replicas racing the same reindex can leave a package with no WIT worlds at all and both report success. That is silently incomplete `/v1/search/by-import` and `/v1/search/by-export` results, permanently.

The obvious escape, scaling the API freely and running one indexer, is **not expressible today**: the indexer thread is spawned unconditionally, and there is no `--api-only` or `--no-indexer` flag or environment variable. A single replica is the only correct configuration until the queue claim is made atomic upstream.

Reads are safe, for the record: no HTTP handler touches the on-disk blob cache, so serving is pure-database and a replica would answer correctly. It is the shared queue that breaks.

### 4. The blob cache needs a volume even at one replica

`--data-dir` looks like a cache you can throw away. It is not, quite. With PostgreSQL configured, `data-dir/db` goes unused, but `data-dir/store` remains a [cacache](https://github.com/zkat/cacache-rs) content-addressed store of pulled OCI layers, and the indexer **cannot rebuild it**: `Store::insert` only writes layer blobs when the manifest row is newly inserted or has no layers yet, and `Store::is_tag_fresh` decides freshness from PostgreSQL rows alone without consulting the cache. So once the shared database knows a manifest, a pod that starts with an empty cache stays empty for it forever, and later reindex tasks fail reading a blob that is not there.

An `emptyDir` would therefore poison the indexer on the first pod restart, with no error at deploy time. The `PersistentVolumeClaim` is what prevents that, which is why the backend is a `StatefulSet` rather than a `Deployment`.

This one is worth carrying upstream. The shipped Container Apps deployment mounts no volume at all and allows `maxReplicas: 3`, so it has both problems: cold caches on every revision, and indexer races whenever traffic scales it out. Because it scales on HTTP concurrency it will usually sit at one replica, so the damage would appear only under a traffic spike, and it persists in PostgreSQL after scale-in rather than clearing.

### 5. The end-to-end proof is `registry sync`, not `registry search`

The closing check runs the project's own `component` CLI, configured with nothing but `COMPONENT_REGISTRY_URL`, and asserts on this line:

```
Synced 82 packages from https://<host>
```

It deliberately does **not** assert that the search immediately afterwards returns results, because with a stock CLI it cannot, against this deployment or any other. `Store::add_known_package_with_params` throws away the tag it is handed, with the comment *"the legacy implementation deliberately did NOT write a tag here, tag to digest mappings are only authoritative after a real pull"*. A synced package therefore has no `oci_tag` rows, and both `search_known_packages` and `list_known_packages` drop every package whose tag list is empty. The visible result is that `component registry search trakt` prints `No packages found matching 'trakt'` and `component registry known` prints `No known packages`, immediately after a sync that reported 82 packages, while the server answers `/v1/search?q=trakt` with that package straight away.

`verify.sh` checks the server-side search separately for exactly this reason, so the lab still proves that search works without asserting client behaviour the CLI does not currently have. If you are evaluating the registry and it looks empty from the CLI, this is why, and it is not something the deployment did.

## Why the standard size runs PostgreSQL in the cluster

The upstream repository already ships [`infra/modules/postgresql.bicep`](https://github.com/yoshuawuyts/wasm.directory/blob/main/infra) for Azure Database for PostgreSQL Flexible Server, and for anything real that is the better answer: backups, patching, and failover stop being your problem.

The standard profile runs PostgreSQL in-cluster anyway, so that the whole registry is Kubernetes objects a reader can inspect, change, and delete in one place, with no second provisioning path and no private networking to arrange. It is explicitly not a production database: one replica, no backups, and a `PersistentVolumeClaim` that outlives the pod but not `just group-empty`. The dev profile instead uses SQLite on the backend's managed-disk PVC so the complete stack fits on one 4 GiB node. To use a managed PostgreSQL server, point `COMPONENT_DATABASE_URL` at it and remove the in-cluster PostgreSQL objects from [install.sh](./install.sh).

The password is generated inside the cluster on first install and stored only in a Secret. Re-running the installer deliberately reuses the existing Secret rather than rotating it, because the `PersistentVolumeClaim` still holds a database initialised with the old value.

## Empty the resource group

Never delete a resource group when your Azure access is assigned at resource-group scope. Empty it instead so the group and its role assignments remain.

```bash
just group-empty
```
