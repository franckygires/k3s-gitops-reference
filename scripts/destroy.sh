#!/usr/bin/env bash
# Remove the cluster and the local Git mirror. Nothing outside this repository is touched.
. "$(dirname "$0")/lib.sh"

need k3d "run: make tools"
log "Deleting cluster '${CLUSTER_NAME}' and the Git mirror"
docker rm -f "$MIRROR_NAME" >/dev/null 2>&1 || true
k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true
rm -rf "$CACHE/kubeconfig" "$CACHE/mirror" "$CACHE/snapshot" "$CACHE/local-ca.crt"
