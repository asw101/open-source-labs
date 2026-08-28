#!/usr/bin/env bash
# Prove the deployment end to end from a client with cluster credentials.
#
# Every check here goes over the public HTTPS endpoint, not through a Service
# or a port-forward, so it exercises the same path a reader's browser and CLI
# would. The closing check runs the project's own unmodified `component` CLI,
# which ships in the backend image, against COMPONENT_REGISTRY_URL.
set -uo pipefail

domain="${1:?application domain is required}"
namespace='wasm-directory'
base="https://$domain"
failures=0
frontend_html="$(mktemp)"
trap 'rm -f "$frontend_html"' EXIT

backend_image="$(kubectl get statefulset backend --namespace "$namespace" \
    --output=jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
if [[ -z "$backend_image" ]]; then
    printf 'Could not read the backend image from statefulset/backend in namespace %s.\n' "$namespace" >&2
    printf 'The deployment is not installed, or is installed elsewhere. Run just deploy first.\n' >&2
    exit 1
fi

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

printf '\n== Public HTTPS endpoint: %s\n' "$base"

# 1. Publicly trusted certificate. No --insecure, and ssl_verify_result must be
#    0, which is the part that would still pass with a self-signed certificate
#    if --insecure were used by mistake.
verify_result="$(curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}' "$base/v1/health" 2>&1)"
if [[ "$verify_result" == "200 0" ]]; then
    pass "GET /v1/health returned 200 with a publicly trusted certificate"
else
    fail "GET /v1/health returned '$verify_result', expected '200 0'"
fi

health_body="$(curl -sS "$base/v1/health" 2>&1)"
if [[ "$health_body" == *'"status":"ok"'* ]]; then
    pass "/v1/health body is $health_body"
else
    fail "/v1/health body was '$health_body'"
fi

# 2. The certificate is from Let's Encrypt and names this host.
cert_text="$(printf '' | openssl s_client -connect "$domain:443" -servername "$domain" 2>/dev/null \
    | openssl x509 -noout -issuer -subject -dates 2>/dev/null)"
if [[ -n "$cert_text" ]]; then
    printf '%s\n' "$cert_text" | awk '{print "        " $0}'
    if [[ "$cert_text" == *"Let's Encrypt"* ]]; then
        pass "certificate was issued by Let's Encrypt"
    else
        fail "certificate issuer is not Let's Encrypt"
    fi
else
    fail "could not read the served certificate"
fi

# 3. TLS 1.3 only, per the Envoy ClientTrafficPolicy.
if printf '' | openssl s_client -connect "$domain:443" -servername "$domain" -tls1_3 >/dev/null 2>&1; then
    pass "TLS 1.3 is accepted"
else
    fail "TLS 1.3 was rejected"
fi
if tls12_output="$(printf '' | openssl s_client -connect "$domain:443" -servername "$domain" -tls1_2 2>&1)"; then
    fail "TLS 1.2 was accepted; the ClientTrafficPolicy minimum is not in force"
elif printf '%s' "$tls12_output" | grep -qiE 'alert protocol version|no protocols available|wrong version number|unsupported protocol'; then
    pass "TLS 1.2 is rejected by the Gateway"
else
    fail "the TLS 1.2 probe failed without a protocol rejection, so nothing was proven: $(printf '%s' "$tls12_output" | tr '\n' ' ' | cut -c1-160)"
fi

# 4. HTTP is redirected to HTTPS.
redirect="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "http://$domain/" 2>&1)"
if [[ "$redirect" == "301 https://$domain/"* ]]; then
    pass "HTTP / redirects 301 to $base/"
else
    fail "HTTP / returned '$redirect'"
fi

# 5. Routing: / reaches the Wasm frontend, /v1 reaches the meta-registry. The
#    frontend is a WebAssembly component served by `wasmtime serve`, so this
#    also confirms that workload is reachable through the Gateway.
front_code="$(curl -sS -o "$frontend_html" -w '%{http_code}' "$base/" 2>&1)"
if [[ "$front_code" == "200" ]] && grep -qi '<html' "$frontend_html"; then
    pass "GET / returned 200 HTML from the Wasm frontend ($(wc -c < "$frontend_html") bytes)"
else
    fail "GET / returned '$front_code' and did not look like HTML"
fi

# 6. The indexer has actually indexed something. Counting packages in the API
#    is the check that matters; the queue endpoint is printed for context but
#    an empty queue on its own would also be true of a registry that has never
#    run.
queue="$(curl -sS "$base/v1/queue" 2>&1)"
printf '        queue: %s\n' "${queue:0:400}"

# The queue counters are the only true totals this API exposes, so the
# indexer's progress is asserted from them. /v1/packages is paginated: it
# returns 20 by default and the server clamps limit to 100, so a length taken
# from it is a page size. Reporting that as a package total would understate a
# healthy registry by an order of magnitude, which is how this check first read.
completed="$(printf '%s' "$queue" | jq -r '.completed // 0' 2>/dev/null || echo 0)"
failed="$(printf '%s' "$queue" | jq -r '.failed // 0' 2>/dev/null || echo 0)"
if [[ "${completed:-0}" -gt 0 ]]; then
    pass "the indexer has completed $completed tasks"
else
    fail "the indexer has completed no tasks; it has not finished a cycle"
fi
if [[ "${failed:-0}" -eq 0 ]]; then
    pass "the indexer reports no failed tasks"
else
    fail "the indexer reports $failed failed task(s)"
fi

page_count="$(curl -sS "$base/v1/packages" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
if [[ "${page_count:-0}" -gt 0 ]]; then
    pass "/v1/packages served a first page of $page_count packages"
else
    fail "/v1/packages returned an empty first page"
fi

recent="$(curl -sS "$base/v1/packages/recent?limit=5" 2>&1)"
printf '        recent: %s\n' "${recent:0:400}"

# 7. Search by exported interface, the capability that makes this a
#    meta-registry rather than a list of names. The query parameter is
#    `interface`; passing `q` returns "missing field `interface`" with a 4xx,
#    which is a routing-looks-fine, answer-is-wrong failure mode.
#
#    This asserts only that the endpoint is routed and answers a JSON array. A
#    populated result additionally requires WIT to have been extracted from
#    pulled layers, which trails the package index, so a fresh deployment can
#    legitimately answer []. Do not read this as proof that WIT indexing works.
by_export="$(curl -sS "$base/v1/search/by-export?interface=wasi" 2>&1)"
if [[ "$by_export" == "["* ]]; then
    by_export_count="$(printf '%s' "$by_export" | jq 'length' 2>/dev/null || echo 0)"
    pass "/v1/search/by-export is routed and answered a JSON array ($by_export_count matches)"
else
    fail "/v1/search/by-export returned '${by_export:0:200}'"
fi

# 8. The end-to-end proof. A stock, unmodified `component` CLI, pointed at this
#    deployment with nothing but COMPONENT_REGISTRY_URL, syncs and searches
#    through it. The CLI binary is the one built into the project's own backend
#    image, so nothing about it is lab-specific.
printf '\n== Stock component CLI against COMPONENT_REGISTRY_URL=%s\n' "$base"

# Pick a package the registry has actually indexed, so the search below is run
# against a name that genuinely exists rather than a hardcoded guess.
search_term="$(curl -sS "$base/v1/packages/recent?limit=1" 2>/dev/null \
    | jq -r '.[0].repository // empty' 2>/dev/null | awk -F/ '{print $NF}')"
[[ -n "$search_term" ]] || search_term='wasi'

kubectl delete pod component-cli --namespace "$namespace" --ignore-not-found --wait=true >/dev/null 2>&1
cli_output="$(kubectl run component-cli \
    --namespace "$namespace" \
    --image="$backend_image" \
    --restart=Never \
    --attach \
    --rm \
    --quiet \
    --env=HOME=/tmp \
    --env="COMPONENT_REGISTRY_URL=$base" \
    --command -- sh -c "component registry sync && component registry search $search_term" 2>&1)"
printf '%s\n' "$cli_output" | awk '{print "        " $0}'

# This is the end-to-end proof: a stock CLI, configured with nothing but
# COMPONENT_REGISTRY_URL, fetched this deployment's package index over the
# public HTTPS endpoint and stored it. The count must be non-zero, because
# "Synced 0 packages" would also be printed by a CLI that reached an empty or
# wrong host.
if printf '%s' "$cli_output" | grep -qE "Synced [1-9][0-9]* packages from $base"; then
    pass "component registry sync pulled the index from $base"
else
    fail "component registry sync did not report a non-empty sync from $base"
fi

# Deliberately NOT asserted: that the following search returns results.
#
# `component registry search` reads the local store, and sync cannot populate
# it usefully. Store::add_known_package_with_params discards the tag it is
# given ("the legacy implementation deliberately did NOT write a tag here"), so
# a synced package has no oci_tag rows, and both search_known_packages and
# list_known_packages drop every package whose tag list is empty. A stock CLI
# therefore reports "No packages found" for a package the server returns
# happily from /v1/search, and `component registry known` prints "No known
# packages" straight after a successful sync.
#
# That is upstream behaviour against any meta-registry, not a property of this
# deployment, so failing the lab on it would be wrong. The search result is
# printed above for information, and the server-side equivalent is checked
# independently below.
if printf '%s' "$cli_output" | grep -q "No packages found matching"; then
    printf '  NOTE  client-side search found nothing; see the comment in verify.sh and the README\n'
fi

server_hits="$(curl -sS "$base/v1/search?q=$search_term" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
if [[ "${server_hits:-0}" -gt 0 ]]; then
    pass "server-side /v1/search?q=$search_term returned $server_hits result(s)"
else
    fail "server-side /v1/search?q=$search_term returned nothing for an indexed package"
fi

printf '\n'
if (( failures == 0 )); then
    printf 'All checks passed.\n'
    exit 0
fi
printf '%d check(s) failed.\n' "$failures"
exit 1
