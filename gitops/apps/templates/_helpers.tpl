{{/* Sync policy shared by every Application: Git is the only way in, drift is reverted. */}}
{{- define "apps.syncPolicy" -}}
automated:
  prune: true
  selfHeal: true
retry:
  limit: 10
  backoff:
    duration: 10s
    factor: 2
    maxDuration: 2m
{{- end -}}
