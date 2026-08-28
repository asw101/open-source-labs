#!/usr/bin/env bash
set -euo pipefail

cluster_name="${1:?cluster name is required}"
domain="${2:?application domain is required}"
acme_email="${3-}"
certificate_mode="${4:?certificate mode is required}"
dns_label="${5-}"
azure_region="${6-}"
action="${7-install}"
size="${8-standard}"

namespace='wasm-directory'

# Both images are the project's own release artifacts, pinned by digest at
# v0.15.0. They are published linux/amd64 only, so this lab's node pool must be
# x86-64; there is no ARM64 variant to fall back to.
backend_image='ghcr.io/yoshuawuyts/wasm.directory/backend@sha256:d63df8ed6d268a736e5849e42b31d4401f880fb9f67b2ad3dda5da2805b3219e'
frontend_image='ghcr.io/yoshuawuyts/wasm.directory/frontend@sha256:88085affd229702d859c6c544db2214a69fca204bde3b86e5d2f0b9619b90e59'
postgres_image='postgres:17-alpine@sha256:18cfe3ef5e6815560c98237d6216d1e5119702fb0f3894c8785dd58b8bbe5d73'

case "$action" in
    install|wait) ;;
    *)
        printf 'Unknown action: %s\n' "$action" >&2
        exit 1
        ;;
esac

case "$size" in
    standard)
        backend_storage='16Gi'
        frontend_replicas='2'
        frontend_strategy=''
        ;;
    dev)
        backend_storage='4Gi'
        frontend_replicas='1'
        frontend_strategy=$'  strategy:\n    type: Recreate'
        ;;
    *)
        printf 'Unknown size: %s. Use standard or dev.\n' "$size" >&2
        exit 1
        ;;
esac

azure_alias_target=""
if [[ -n "$dns_label" ]]; then
    [[ "$dns_label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#dns_label} -le 63 ]] || {
        printf 'Invalid DNS_LABEL: %s. Use 1-63 lowercase letters, digits, or hyphens, starting and ending with a letter or digit.\n' "$dns_label" >&2
        exit 1
    }
    [[ "$azure_region" =~ ^[a-z0-9]+$ ]] || {
        printf 'Invalid Azure region for the public DNS hostname: %s\n' "$azure_region" >&2
        exit 1
    }
    azure_alias_target="$dns_label.$azure_region.cloudapp.azure.com"
fi

case "$certificate_mode" in
    letsencrypt-http01)
        [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ ]] || {
            printf 'Invalid DOMAIN: %s\n' "$domain" >&2
            exit 1
        }
        ;;
    letsencrypt-azure-http01)
        [[ "$domain" == "$azure_alias_target" ]] || {
            printf 'The derived hostname does not match DNS_LABEL and the AKS region: %s\n' "$domain" >&2
            exit 1
        }
        ;;
    selfsigned)
        [[ "$domain" == "wasm-directory.local" ]] || {
            printf 'Unexpected fallback domain: %s\n' "$domain" >&2
            exit 1
        }
        ;;
    *)
        printf 'Unknown certificate mode: %s\n' "$certificate_mode" >&2
        exit 1
        ;;
esac

email_pattern='^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
if [[ -n "$acme_email" && ! "$acme_email" =~ $email_pattern ]]; then
    printf 'Invalid ACME_EMAIL: %s\n' "$acme_email" >&2
    exit 1
fi

wait_for_gateway_address() {
    local address=""
    local elapsed=0

    printf 'Waiting up to 10 minutes for the Gateway public address...\n' >&2
    while (( elapsed < 600 )); do
        address="$(kubectl get gateway wasm-directory \
            --namespace "$namespace" \
            --output=jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
        if [[ -n "$address" ]]; then
            printf '%s\n' "$address"
            return 0
        fi
        sleep 10
        ((elapsed += 10))
        if (( elapsed % 60 == 0 )); then
            printf 'Still waiting for the Gateway public address (%d minutes elapsed).\n' "$((elapsed / 60))" >&2
        fi
    done

    if [[ "$certificate_mode" == "letsencrypt-azure-http01" ]]; then
        printf 'The Gateway did not receive a public address within 10 minutes. Confirm that DNS_LABEL %s is unique in %s and that the generated Envoy Gateway Service has the Azure DNS-label annotation.\n' "$dns_label" "$azure_region" >&2
    else
        printf 'The Gateway did not receive a public address within 10 minutes. Run this command again after checking the Envoy Gateway service.\n' >&2
    fi
    return 1
}

wait_for_http01_certificate() {
    local gateway_address="$1"

    printf '\nWaiting up to 15 minutes for cert-manager to issue the HTTP-01 certificate.\n'
    if [[ "$certificate_mode" == "letsencrypt-azure-http01" ]]; then
        printf 'Azure is publishing %s for the Gateway public IP %s; no DNS record needs to be created manually.\n' "$domain" "$gateway_address"
    elif [[ -n "$azure_alias_target" ]]; then
        printf 'It is retrying while public DNS propagates. Required record: %s CNAME %s\n' "$domain" "$azure_alias_target"
    else
        printf 'It is retrying while public DNS propagates. Required record: %s A %s\n' "$domain" "$gateway_address"
    fi
    if ! kubectl wait --for=condition=Ready certificate/wasm-directory-tls \
        --namespace "$namespace" \
        --timeout=15m; then
        printf '\nThe certificate did not become ready within 15 minutes.\n' >&2
        if [[ "$certificate_mode" == "letsencrypt-azure-http01" ]]; then
            printf 'Confirm that the Envoy Gateway Service has DNS label %s, that the label is unique in %s, that %s resolves publicly to %s, and that HTTP port 80 reaches the Gateway.\n' "$dns_label" "$azure_region" "$domain" "$gateway_address" >&2
        elif [[ -n "$azure_alias_target" ]]; then
            printf 'Confirm that %s is an unproxied CNAME to %s, that it resolves publicly to %s, and that HTTP port 80 reaches the Gateway, then run just wait-http01 again.\n' "$domain" "$azure_alias_target" "$gateway_address" >&2
        else
            printf 'Confirm that %s resolves publicly to %s on an unproxied A record and that HTTP port 80 is not redirected before it reaches the Gateway, then run just wait-http01 again.\n' "$domain" "$gateway_address" >&2
        fi
        return 1
    fi
}

# Print the closing summary, including the end-to-end proof that the stock
# `component` CLI can drive this deployment.
print_ready() {
    local gateway_address="$1"

    printf '\nwasm.directory is ready.\n'
    if [[ "$certificate_mode" == "selfsigned" ]]; then
        printf 'Self-signed endpoint IP: %s\n' "$gateway_address"
        printf 'Frontend:  curl --resolve %s:443:%s --insecure https://%s/\n' "$domain" "$gateway_address" "$domain"
        printf 'Registry:  curl --resolve %s:443:%s --insecure https://%s/v1/health\n' "$domain" "$gateway_address" "$domain"
        return 0
    fi

    printf 'Trusted endpoint: https://%s\n' "$domain"
    if [[ "$certificate_mode" == "letsencrypt-azure-http01" ]]; then
        printf 'Azure is publishing the Gateway public IP at %s.\n' "$domain"
    elif [[ -n "$azure_alias_target" ]]; then
        printf 'CNAME record: %s CNAME %s\n' "$domain" "$azure_alias_target"
    fi
    printf '\nFrontend:      https://%s/\n' "$domain"
    printf 'Registry API:  https://%s/v1/health\n' "$domain"
    printf 'Indexer queue: https://%s/v1/queue\n' "$domain"
    printf '\nPoint a stock component CLI at this deployment:\n'
    printf '  export COMPONENT_REGISTRY_URL=https://%s\n' "$domain"
    printf '  component registry search http\n'
    printf '\nTLS 1.2 rejection test: openssl s_client -connect %s:443 -servername %s -tls1_2\n' "$gateway_address" "$domain"
}

if [[ "$action" == "wait" ]]; then
    [[ "$certificate_mode" == "letsencrypt-http01" ]] || {
        printf 'The wait action is only valid for the HTTP-01 certificate path.\n' >&2
        exit 1
    }
    gateway_address="$(wait_for_gateway_address)"
    wait_for_http01_certificate "$gateway_address"
    kubectl wait --for=condition=Programmed gateway/wasm-directory --namespace "$namespace" --timeout=10m
    print_ready "$gateway_address"
    exit 0
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

helm upgrade --install envoy-gateway \
    oci://docker.io/envoyproxy/gateway-helm \
    --version v1.9.0 \
    --namespace envoy-gateway-system \
    --create-namespace \
    --wait \
    --timeout 10m

cat > "$work_dir/cert-manager-values.yaml" <<'EOF'
crds:
  enabled: true
config:
  gatewayAPI:
    enabled: true
EOF

helm upgrade --install cert-manager \
    oci://quay.io/jetstack/charts/cert-manager \
    --version v1.21.1 \
    --namespace cert-manager \
    --create-namespace \
    --values "$work_dir/cert-manager-values.yaml" \
    --wait \
    --timeout 10m

kubectl create namespace "$namespace" --dry-run=client --output=yaml | kubectl apply -f -

if [[ "$size" == "standard" ]]; then
    # The PostgreSQL password is generated in-cluster on first install and
    # never leaves it. Re-running the installer must not rotate it: the
    # existing PersistentVolumeClaim still holds a database initialised with
    # the old value, and a rotated Secret would leave the backend unable to
    # authenticate.
    if kubectl get secret wasm-directory-postgres --namespace "$namespace" >/dev/null 2>&1; then
        printf 'Reusing the existing PostgreSQL password Secret.\n'
    else
        printf 'Generating a PostgreSQL password.\n'
        kubectl create secret generic wasm-directory-postgres \
            --namespace "$namespace" \
            --from-literal=POSTGRES_USER=registry \
            --from-literal=POSTGRES_DB=registry \
            --from-literal=POSTGRES_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | cut -c1-32)"
    fi
fi

if [[ "$certificate_mode" == "selfsigned" ]]; then
    cat > "$work_dir/issuer.yaml" <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
EOF
    issuer_name='selfsigned'
else
    {
        cat <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
EOF
        if [[ -n "$acme_email" ]]; then
            printf '    email: %s\n' "$acme_email"
        fi
        cat <<EOF
    privateKeySecretRef:
      name: letsencrypt-account
    server: https://acme-v02.api.letsencrypt.org/directory
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - group: gateway.networking.k8s.io
                kind: Gateway
                name: wasm-directory
                namespace: $namespace
                sectionName: http
EOF
    } > "$work_dir/issuer.yaml"
    issuer_name='letsencrypt'
fi

kubectl apply -f "$work_dir/issuer.yaml"
kubectl wait --for=condition=Ready "clusterissuer/$issuer_name" --timeout=5m

if [[ -n "$dns_label" ]]; then
    cat > "$work_dir/application.yaml" <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: azure-dns-label
  namespace: $namespace
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        annotations:
          service.beta.kubernetes.io/azure-dns-label-name: "$dns_label"
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: azure-dns-label
    namespace: $namespace
EOF
else
    # GatewayClass is cluster-scoped, and this name is shared with the sibling
    # aks-https-gateway lab. Each lab creates its own cluster, so they never
    # meet; running both on one cluster would need one of them renamed.
    cat > "$work_dir/application.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF
fi

if [[ "$size" == "standard" ]]; then
    # PostgreSQL. A single-replica StatefulSet with one PersistentVolumeClaim
    # keeps the standard lab self-contained. It is deliberately not a
    # production database.
    #
    # PGDATA is a subdirectory of the mount because the Azure disk is formatted
    # ext4 and its lost+found directory makes initdb refuse a mount-point
    # PGDATA.
    cat >> "$work_dir/application.yaml" <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: $namespace
spec:
  clusterIP: None
  selector:
    app: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: $namespace
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        fsGroup: 70
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: postgres
          image: $postgres_image
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          envFrom:
            - secretRef:
                name: wasm-directory-postgres
          ports:
            - name: postgres
              containerPort: 5432
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\""]
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 6
          livenessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\""]
            initialDelaySeconds: 30
            periodSeconds: 15
            timeoutSeconds: 3
            failureThreshold: 3
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 8Gi
EOF
fi

# The backend is a single-replica StatefulSet with its own PersistentVolumeClaim.
# Both halves of that sentence are deliberate; the README explains the evidence.
#
# One replica, because the process is an Axum API server *and* a background OCI
# indexer, and the indexer's fetch queue is a shared PostgreSQL table whose
# claim is not atomic: Store::dequeue_next does a plain SELECT followed by an
# UPDATE keyed only on the row id, inside a READ COMMITTED transaction, so two
# replicas claim the same row. The in-source comment says as much. There is
# also no flag that runs the API without the indexer, so the alternative of a
# freely scaling API plus one indexer is not expressible without a code change.
#
# A PersistentVolumeClaim rather than an emptyDir, because --data-dir/store is
# a cacache blob cache that the indexer cannot rebuild. Store::insert only
# writes layer blobs when the manifest row is new or has no layers, so once
# PostgreSQL knows a manifest, a pod that starts with an empty cache stays
# empty for it forever, and later reindex tasks fail reading a blob that is not
# there. The volume is what keeps a restart from silently poisoning the
# indexer.
cat >> "$work_dir/application.yaml" <<EOF
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: backend
  namespace: $namespace
spec:
  serviceName: backend
  replicas: 1
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: backend
          image: $backend_image
          # Order matters: Kubernetes expands \$(VAR) only from entries that
          # appear earlier in this list, so the three secret references have to
          # precede the URL that interpolates them. Listing the URL first
          # leaves the literal string \$(POSTGRES_USER) in the connection URL,
          # which fails as an unparseable host rather than as a bad password.
          env:
            # Manager::open_at calls Config::load, which fails outright with
            # "Could not determine config directory" when neither
            # XDG_CONFIG_HOME nor HOME is set. Overriding runAsUser leaves the
            # container with no passwd entry, so HOME is not reliably set for
            # us. Pointing it at the volume makes the lookup miss and fall back
            # to defaults instead of aborting startup.
            - name: HOME
              value: /data
EOF

if [[ "$size" == "standard" ]]; then
    cat >> "$work_dir/application.yaml" <<EOF
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: wasm-directory-postgres
                  key: POSTGRES_USER
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: wasm-directory-postgres
                  key: POSTGRES_PASSWORD
            - name: POSTGRES_DB
              valueFrom:
                secretKeyRef:
                  name: wasm-directory-postgres
                  key: POSTGRES_DB
            - name: COMPONENT_DATABASE_URL
              value: postgres://\$(POSTGRES_USER):\$(POSTGRES_PASSWORD)@postgres:5432/\$(POSTGRES_DB)
EOF
else
    cat >> "$work_dir/application.yaml" <<'EOF'
            - name: COMPONENT_DATABASE_URL
              value: sqlite:///data/registry.db?mode=rwc
EOF
fi

cat >> "$work_dir/application.yaml" <<EOF
          ports:
            - name: http
              containerPort: 8081
          startupProbe:
            httpGet:
              path: /v1/health
              port: http
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 60
          readinessProbe:
            httpGet:
              path: /v1/health
              port: http
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: data
              mountPath: /data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: $backend_storage
EOF

# The backend Service is named "backend" and listens on port 80 because the
# published frontend image has API_BASE_URL=http://backend compiled into the
# WebAssembly component. That value is baked in by option_env! at build time,
# not read at runtime, so it cannot be overridden with an environment variable.
# Naming the Service anything else, or exposing it on 8081, makes the frontend
# panic on every backend-backed request. Kubernetes DNS makes the Azure
# Container Apps form work here unchanged.
cat >> "$work_dir/application.yaml" <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: $namespace
spec:
  selector:
    app: backend
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: $namespace
spec:
  replicas: $frontend_replicas
$frontend_strategy
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: frontend
          image: $frontend_image
          # wasmtime compiles the component on startup and caches the result
          # under \$HOME/.cache/wasmtime. Overriding runAsUser leaves the
          # container with no passwd entry, so HOME resolves to /, and with
          # readOnlyRootFilesystem the process exits immediately with
          # "failed to create cache directory: /.cache/wasmtime". Giving it a
          # writable emptyDir keeps the read-only root filesystem instead of
          # trading it away, and the cache is per-pod and disposable anyway.
          env:
            - name: HOME
              value: /home/nonroot
          ports:
            - name: http
              containerPort: 8080
          startupProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            readOnlyRootFilesystem: true
          volumeMounts:
            - name: wasmtime-cache
              mountPath: /home/nonroot
      volumes:
        - name: wasmtime-cache
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: $namespace
spec:
  selector:
    app: frontend
  ports:
    - name: http
      port: 80
      targetPort: http
EOF

# One hostname serves both halves. Every meta-registry endpoint lives under
# /v1, and the CLI builds its URLs as <COMPONENT_REGISTRY_URL>/v1/..., so a
# /v1 PathPrefix route to the backend is all the CLI needs. Gateway API gives
# the longer prefix precedence over the frontend's /, and gives cert-manager's
# generated Exact match on /.well-known/acme-challenge/ precedence over both.
cat >> "$work_dir/application.yaml" <<EOF
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: wasm-directory
  namespace: $namespace
  annotations:
    cert-manager.io/cluster-issuer: $issuer_name
    cert-manager.io/private-key-algorithm: ECDSA
    cert-manager.io/private-key-rotation-policy: Always
    cert-manager.io/private-key-size: "256"
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: http
      hostname: "$domain"
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
    - name: https
      hostname: "$domain"
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - group: ""
            kind: Secret
            name: wasm-directory-tls
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: tls-13
  namespace: $namespace
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: wasm-directory
  tls:
    minVersion: "1.3"
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: redirect-http
  namespace: $namespace
spec:
  parentRefs:
    - name: wasm-directory
      sectionName: http
  hostnames:
    - "$domain"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: registry-api
  namespace: $namespace
spec:
  parentRefs:
    - name: wasm-directory
      sectionName: https
  hostnames:
    - "$domain"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1
      backendRefs:
        - name: backend
          port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: frontend
  namespace: $namespace
spec:
  parentRefs:
    - name: wasm-directory
      sectionName: https
  hostnames:
    - "$domain"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend
          port: 80
EOF

kubectl apply -f "$work_dir/application.yaml"

if [[ "$size" == "standard" ]]; then
    kubectl rollout status statefulset/postgres --namespace "$namespace" --timeout=10m
fi
kubectl rollout status statefulset/backend --namespace "$namespace" --timeout=10m
kubectl rollout status deployment/frontend --namespace "$namespace" --timeout=10m

if [[ "$certificate_mode" == "letsencrypt-http01" ]]; then
    gateway_address="$(wait_for_gateway_address)"
    printf '\n============================================================\n'
    printf 'HTTP-01 DNS ACTION REQUIRED\n'
    printf 'Create this public DNS record now:\n\n'
    if [[ -n "$azure_alias_target" ]]; then
        printf '  %s CNAME %s\n\n' "$domain" "$azure_alias_target"
        printf 'Azure keeps %s pointed at the Gateway public IP %s.\n\n' "$azure_alias_target" "$gateway_address"
    else
        printf '  %s A %s\n\n' "$domain" "$gateway_address"
    fi
    printf 'The record must send port 80 directly to this Gateway. After it resolves publicly, run:\n\n'
    printf '  just wait-http01\n'
    printf '============================================================\n'
    printf 'cert-manager is already retrying the HTTP-01 challenge; no DNS provider credentials were configured.\n'
    exit 0
fi

if [[ "$certificate_mode" == "letsencrypt-azure-http01" ]]; then
    gateway_address="$(wait_for_gateway_address)"
    wait_for_http01_certificate "$gateway_address"
else
    kubectl wait --for=condition=Ready certificate/wasm-directory-tls --namespace "$namespace" --timeout=15m
fi
kubectl wait --for=condition=Programmed gateway/wasm-directory --namespace "$namespace" --timeout=10m

gateway_address="$(kubectl get gateway wasm-directory --namespace "$namespace" --output=jsonpath='{.status.addresses[0].value}')"
print_ready "$gateway_address"
