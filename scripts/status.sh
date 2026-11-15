#!/usr/bin/env bash
# What Argo CD thinks, and what is actually running.
. "$(dirname "$0")/lib.sh"

log "Nodes"
kubectl get nodes -o wide
log "Argo CD applications"
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,SYNC:.status.sync.status,HEALTH:.status.health.status,MESSAGE:.status.conditions[0].message'
log "PostgreSQL"
kubectl -n demo get cluster pg 2>/dev/null || true
kubectl -n demo get pods -o wide 2>/dev/null || true
log "Pods that are not running"
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || true
