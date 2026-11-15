#!/usr/bin/env bash
# Shared settings and helpers. Sourced by every script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
set -a; . "$ROOT/versions.env"; set +a

CACHE="$ROOT/.cache"
mkdir -p "$CACHE"

# The cluster has its own kubeconfig: nothing here reads or writes ~/.kube/config.
export KUBECONFIG="$CACHE/kubeconfig"
export PATH="$ROOT/bin:$PATH"

MIRROR_NAME="${CLUSTER_NAME}-git-mirror"
NETWORK="k3d-${CLUSTER_NAME}"
BASE_URL="https://${DEMO_HOST}:${HTTPS_PORT}"
CA_FILE="$CACHE/local-ca.crt"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed${2:+ ($2)}"; }

now() { date +%s; }
# 135 -> "2m15s"
duration() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

# curl against the demo API through the load balancer, without relying on public DNS,
# and trusting only the cluster's own certificate authority.
api() {
  curl --silent --show-error --max-time "${API_TIMEOUT:-5}" \
    --resolve "${DEMO_HOST}:${HTTPS_PORT}:127.0.0.1" --cacert "$CA_FILE" "$@"
}

# Fetch the CA that cert-manager created, so tests verify the real certificate chain.
fetch_ca() {
  kubectl -n cert-manager get secret local-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CA_FILE"
}

primary_pod()  { kubectl -n demo get cluster pg -o jsonpath='{.status.currentPrimary}'; }
node_of()      { kubectl -n demo get pod "$1" -o jsonpath='{.spec.nodeName}'; }
psql_primary() { kubectl -n demo exec "$(primary_pod)" -c postgres -- psql -U postgres -d app -At -c "$1"; }

# Wait until a command succeeds. usage: wait_for <seconds> <description> <command...>
wait_for() {
  local timeout=$1 what=$2 start; shift 2
  start=$(now)
  until "$@" >/dev/null 2>&1; do
    (( $(now) - start > timeout )) && die "timed out after ${timeout}s waiting for ${what}"
    sleep 3
  done
}
