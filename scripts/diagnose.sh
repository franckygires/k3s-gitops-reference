#!/usr/bin/env bash
# Print what is needed to understand a failure, most useful first. Never fails itself.
. "$(dirname "$0")/lib.sh"
set +e

section() { printf '\n### %s\n' "$*"; }
k() { kubectl --request-timeout=20s "$@" 2>&1; }

section "Nodes"
k get nodes -o wide

section "Argo CD applications"
k -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,PHASE:.status.operationState.phase,MESSAGE:.status.operationState.message'

section "Application conditions"
k -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .status.conditions[*]}{.type}{"="}{.message}{" | "}{end}{"\n"}{end}'

section "Pods that are not Running or Completed"
k get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide

section "Pods with restarts or not ready"
k get pods -A --no-headers | awk '{split($3,r,"/"); if (r[1]!=r[2] && $4!="Completed" || $5+0>0) print}'

section "Secret store and external secret"
k get clustersecretstore vault -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
k -n demo get externalsecret pg-app -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'

section "PostgreSQL cluster"
k -n demo get cluster pg -o jsonpath='phase={.status.phase} ready={.status.readyInstances}/{.spec.instances} primary={.status.currentPrimary}{"\n"}'

section "Certificate"
k -n demo get certificate api-tls -o jsonpath='{range .status.conditions[*]}{.type}={.status}: {.message}{"\n"}{end}'

section "Warning events (latest 25)"
k get events -A --field-selector=type=Warning --sort-by=.lastTimestamp | tail -25

section "Vault (last 20 lines)"
k -n vault logs vault-0 --tail=20

section "External Secrets (last 15 lines)"
k -n external-secrets logs deploy/external-secrets --tail=15

section "Argo CD application controller (errors, last 15)"
k -n argocd logs argocd-application-controller-0 --tail=400 | grep -iE 'level=(error|fatal)' | tail -15

section "Host"
uptime
free -m | sed -n 2p
docker ps --format '{{.Names}}\t{{.Status}}'
