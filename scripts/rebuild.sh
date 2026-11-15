#!/usr/bin/env bash
# Destroy everything, rebuild it from Git, verify it, and report how long that took.
. "$(dirname "$0")/lib.sh"

start=$(now)
"$ROOT/scripts/destroy.sh"
"$ROOT/scripts/up.sh"
"$ROOT/scripts/test.sh"
total=$(( $(now) - start ))

echo "$total" > "$CACHE/last-rebuild-seconds"
log "Destroyed, rebuilt from Git and verified in $(duration "$total")"
