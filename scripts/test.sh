#!/usr/bin/env bash
# Checks that the running cluster matches what the README claims. Exit code 1 if any check fails.
. "$(dirname "$0")/lib.sh"

failures=0
check() { # usage: check "<description>" <command...>
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$what"; else fail "$what"; failures=$((failures + 1)); fi
}

fetch_ca

log "Cluster"
check "3 nodes are Ready" bash -c '[ "$(kubectl get nodes --no-headers | grep -cw Ready)" -eq 3 ]'
check "all 3 nodes run the control plane and etcd" bash -c \
  '[ "$(kubectl get nodes -l node-role.kubernetes.io/etcd=true --no-headers | wc -l)" -eq 3 ]'

log "GitOps"
for app in root cert-manager cloudnative-pg external-secrets vault platform postgres demo; do
  check "application '$app' is Synced and Healthy" bash -c \
    "[ \"\$(kubectl -n argocd get application $app -o jsonpath='{.status.sync.status}/{.status.health.status}')\" = Synced/Healthy ]"
done

log "PostgreSQL"
check "3 instances are ready" bash -c \
  '[ "$(kubectl -n demo get cluster pg -o jsonpath="{.status.readyInstances}")" -eq 3 ]'
check "each instance runs on a different node" bash -c \
  '[ "$(kubectl -n demo get pods -l cnpg.io/cluster=pg -o jsonpath="{range .items[*]}{.spec.nodeName}{\"\n\"}{end}" | sort -u | wc -l)" -eq 3 ]'
check "synchronous replication is configured" bash -c \
  '[ -n "$(kubectl -n demo exec "$(kubectl -n demo get cluster pg -o jsonpath="{.status.currentPrimary}")" -c postgres -- psql -U postgres -At -c "show synchronous_standby_names")" ]'
check "at least one standby is synchronous right now" bash -c \
  '[ "$(kubectl -n demo exec "$(kubectl -n demo get cluster pg -o jsonpath="{.status.currentPrimary}")" -c postgres -- psql -U postgres -At -c "select count(*) from pg_stat_replication where sync_state in ('"'"'sync'"'"','"'"'quorum'"'"')")" -ge 1 ]'

log "TLS and application"
check "the API answers over HTTPS with a certificate signed by the cluster CA" \
  api --fail -o /dev/null "$BASE_URL/events"
check "HTTPS is refused without that CA (the certificate is not publicly trusted)" bash -c \
  "! curl -s --max-time 5 --resolve ${DEMO_HOST}:${HTTPS_PORT}:127.0.0.1 -o /dev/null ${BASE_URL}/events"
note="smoke-$(date +%s)"
check "a write goes through the API and is read back" bash -c "
  . '$ROOT/scripts/lib.sh'
  api --fail -o /dev/null -X POST -H 'content-type: application/json' -d '{\"note\":\"$note\"}' '$BASE_URL/events' &&
  api --fail '$BASE_URL/events?note=eq.$note' | grep -q '$note'"

log "Secrets"
check "the database secret is produced by External Secrets from Vault" bash -c \
  '[ "$(kubectl -n demo get externalsecret pg-app -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}")" = True ]'
check "the password does not appear anywhere in the repository" bash -c "
  pw=\$(kubectl -n demo get secret pg-app -o jsonpath='{.data.password}' | base64 -d)
  [ -n \"\$pw\" ] && ! grep -rqF --exclude-dir=.cache --exclude-dir=.git --exclude-dir=bin -- \"\$pw\" '$ROOT'"

log "Network policies"
probe() { # usage: probe <host> <port>  -> succeeds if a pod outside the namespace can connect
  kubectl -n default run "probe-$RANDOM" --rm -i --restart=Never --quiet --image=busybox:1.36 \
    --timeout=60s -- nc -w 3 -z "$1" "$2"
}
check "a pod from another namespace cannot reach PostgreSQL" bash -c "$(declare -f probe); ! probe pg-rw.demo.svc 5432"
check "a pod from another namespace cannot bypass the ingress to reach the API" bash -c "$(declare -f probe); ! probe api.demo.svc 80"

echo
if [ "$failures" -eq 0 ]; then
  log "All checks passed"
else
  die "$failures check(s) failed"
fi
