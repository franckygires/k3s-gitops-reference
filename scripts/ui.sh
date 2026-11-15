#!/usr/bin/env bash
# Open the Argo CD UI on http://localhost:8081 (Ctrl+C to stop).
. "$(dirname "$0")/lib.sh"

password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
log "Argo CD: http://localhost:8081   user: admin   password: ${password}"
kubectl -n argocd port-forward svc/argocd-server 8081:80
