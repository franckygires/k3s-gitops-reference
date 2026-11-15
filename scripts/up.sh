#!/usr/bin/env bash
# Create the cluster and hand it to Argo CD. Safe to run again: every step is idempotent.
#
#   SOURCE=local  (default) Argo CD reads a mirror of this checkout.
#   SOURCE=github           Argo CD reads the public repository, at REVISION (branch, tag or commit).
. "$(dirname "$0")/lib.sh"

SOURCE="${SOURCE:-local}"
REVISION="${REVISION:-main}"
GITHUB_URL="${GITHUB_URL:-https://github.com/franckygires/k3s-gitops-reference}"
started=$(now)

need docker; need kubectl; need helm
need k3d "run: make tools"

# --- 1. Cluster: three K3s servers, each with the control plane and an etcd member ------------
# Servers are started one at a time, and each must settle before the next one joins. Starting all
# three at once saturates a small machine: etcd slows down, nodes lose their leases and restart,
# and the restarts keep the machine saturated.
server_args=()
while IFS= read -r line; do
  case "$line" in ''|'#'*) ;; *) server_args+=("$line") ;; esac
done < "$ROOT/bootstrap/k3s-server-args"

refresh_kubeconfig() { k3d kubeconfig get "$CLUSTER_NAME" > "$KUBECONFIG"; chmod 600 "$KUBECONFIG"; }

settle() { # usage: settle <number of nodes expected>
  wait_for 600 "$1 node(s) to be Ready" bash -c \
    "[ \"\$(kubectl get nodes --no-headers 2>/dev/null | grep -cw Ready)\" -eq $1 ]"
  wait_for 600 "$1 etcd member(s)" bash -c \
    "[ \"\$(kubectl get nodes -l node-role.kubernetes.io/etcd=true --no-headers 2>/dev/null | wc -l)\" -eq $1 ]"
  wait_for 600 "CoreDNS" kubectl -n kube-system rollout status deploy/coredns --timeout=5s
  wait_for 600 "Traefik" kubectl -n kube-system rollout status deploy/traefik --timeout=5s
}

if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
  log "Cluster '${CLUSTER_NAME}' already exists"
  k3d cluster start "$CLUSTER_NAME" >/dev/null
  refresh_kubeconfig
else
  log "Creating the cluster with its first server"
  create_args=()
  for a in "${server_args[@]}"; do create_args+=(--k3s-arg "${a}@server:*"); done
  # --cluster-init makes the first server start an etcd cluster that others can join.
  # The k3d load balancer stands in for the external load balancer of a real deployment.
  k3d cluster create "$CLUSTER_NAME" --servers 1 --agents 0 \
    --k3s-arg "--cluster-init@server:0" "${create_args[@]}" \
    --port "${HTTPS_PORT}:443@loadbalancer" --port "${HTTP_PORT}:80@loadbalancer" \
    --kubeconfig-update-default=false --kubeconfig-switch-context=false \
    --wait --timeout 600s > "$CACHE/create.log" 2>&1 || { cat "$CACHE/create.log"; die "cluster creation failed"; }
  refresh_kubeconfig
  settle 1
fi

servers=$(kubectl get nodes --no-headers | wc -l)
while [ "$servers" -lt 3 ]; do
  log "Adding server $((servers + 1)) of 3"
  name="${CLUSTER_NAME}-server-${servers}"
  join_args=()
  for a in "${server_args[@]}"; do join_args+=(--k3s-arg "$a"); done
  # etcd admits one new member at a time: a server that tries to join while the previous one is
  # still being promoted is refused. Rather than guess how long promotion takes, retry.
  attempt=1
  until k3d node create "$name" --cluster "$CLUSTER_NAME" --role server \
    "${join_args[@]}" --wait --timeout 300s > "$CACHE/join.log" 2>&1; do
    [ "$attempt" -ge 5 ] && { cat "$CACHE/join.log"; die "server $((servers + 1)) could not join after 5 attempts"; }
    echo "    join refused (attempt ${attempt}/5), retrying in 20 s: $(grep -iE 'level=(fatal|error)|ERRO|FATA' "$CACHE/join.log" | tail -1 | cut -c1-200)"
    k3d node delete "k3d-${name}-0" >/dev/null 2>&1 || true
    kubectl delete node "k3d-${name}-0" --ignore-not-found >/dev/null 2>&1 || true
    attempt=$((attempt + 1))
    sleep 20
  done
  servers=$((servers + 1))
  settle "$servers"
done

# --- 2. Make the built-in ingress and DNS survive the loss of a node -------------------------
log "Spreading Traefik and CoreDNS across the three nodes"
kubectl apply -f "$ROOT/bootstrap/traefik-ha.yaml" >/dev/null
kubectl -n kube-system scale deploy coredns --replicas=3 >/dev/null
kubectl -n kube-system rollout status deploy/coredns --timeout=10m >/dev/null
wait_for 600 "3 Traefik replicas" bash -c \
  '[ "$(kubectl -n kube-system get deploy traefik -o jsonpath="{.status.readyReplicas}")" = "3" ]'

# --- 3. The one secret an operator provides by hand ------------------------------------------
# Generated here, stored only in the cluster, loaded into Vault when Vault starts. Never in Git.
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl -n vault get secret vault-seed >/dev/null 2>&1; then
  log "Generating the database password (kept out of Git)"
  kubectl -n vault create secret generic vault-seed \
    --from-literal=pg-password="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)" >/dev/null
fi

# --- 4. Argo CD ------------------------------------------------------------------------------
log "Installing Argo CD (chart ${ARGOCD_CHART_VERSION})"
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --values "$ROOT/bootstrap/argocd-values.yaml" --wait --timeout 10m >/dev/null

# --- 5. Point Argo CD at Git and let it build everything else --------------------------------
if [ "$SOURCE" = "github" ]; then
  repo_url="$GITHUB_URL"
  log "Argo CD will read ${repo_url} at ${REVISION}"
else
  repo_url=$("$ROOT/scripts/mirror.sh")
  REVISION=main
  log "Argo CD will read the local mirror of this checkout (${repo_url})"
fi

kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${repo_url}
    targetRevision: ${REVISION}
    path: gitops/apps
    helm:
      parameters:
        - name: repoURL
          value: ${repo_url}
        - name: revision
          value: ${REVISION}
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
YAML

# --- 6. Wait for Git to become reality -------------------------------------------------------
log "Waiting for Argo CD to deploy the platform (operators, secrets, database, application)"
expected="cert-manager cloudnative-pg external-secrets vault platform postgres demo root"
deadline=$(( $(now) + 1200 ))
last=""
while :; do
  ready=0; summary=""
  for app in $expected; do
    state=$(kubectl -n argocd get application "$app" \
      -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo "-/-")
    [ "$state" = "Synced/Healthy" ] && ready=$((ready + 1))
    summary="$summary $app=$state"
  done
  if [ "$summary" != "$last" ]; then
    printf '    %s/8 ready |%s\n' "$ready" "$summary"
    last="$summary"
  fi
  [ "$ready" -eq 8 ] && break
  (( $(now) > deadline )) && die "the platform did not converge in 20 minutes; run: make status"
  sleep 5
done

wait_for 300 "the ingress certificate" kubectl -n demo wait --for=condition=Ready certificate/api-tls --timeout=5s
fetch_ca
wait_for 180 "the API to answer over HTTPS" api --fail -o /dev/null "$BASE_URL/events"

elapsed=$(( $(now) - started ))
echo "$elapsed" > "$CACHE/last-up-seconds"
log "Ready in $(duration "$elapsed")"
cat <<MSG

  API        ${BASE_URL}/events   (certificate signed by the cluster's own CA: ${CA_FILE})
  Try it     curl --cacert ${CA_FILE} ${BASE_URL}/events
  Argo CD    make ui
  Checks     make test
  Failure    make drill
MSG
