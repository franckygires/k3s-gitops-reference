#!/usr/bin/env bash
# Failure drill: stop the node that hosts the PostgreSQL primary while a client keeps writing,
# then prove that no acknowledged write was lost and measure how long writes were unavailable.
#
# A write counts as acknowledged only when the API answered 201 with the new row's id.
. "$(dirname "$0")/lib.sh"

WRITE_SECONDS="${WRITE_SECONDS:-60}"   # how long the client keeps writing after the node is stopped
run="drill-$(date +%s)"
work="$CACHE/$run"; mkdir -p "$work"
report="$CACHE/drill-report.md"

fetch_ca
[ "$(kubectl -n demo get cluster pg -o jsonpath='{.status.readyInstances}')" = "3" ] ||
  die "the cluster is not fully healthy; run 'make test' first"

old_primary=$(primary_pod)
node=$(node_of "$old_primary")
log "Primary is ${old_primary} on node ${node}"

# --- The client: one write every 200 ms, recording the outcome of each ------------------------
writer() {
  while [ ! -e "$work/stop" ]; do
    t=$(date +%s.%N)
    body=$(API_TIMEOUT=2 api -X POST -H 'content-type: application/json' -H 'Prefer: return=representation' \
      -w '\n%{http_code}' -d "{\"note\":\"$run\"}" "$BASE_URL/events" 2>/dev/null || true)
    if [ "$(printf '%s' "$body" | tail -n1)" = "201" ]; then
      id=$(printf '%s' "$body" | head -n1 | sed -E 's/.*"id":([0-9]+).*/\1/')
      echo "$t ok $id" >> "$work/log"
    else
      echo "$t fail" >> "$work/log"
    fi
    sleep 0.2
  done
}
writer &
writer_pid=$!
trap 'touch "$work/stop"; wait "$writer_pid" 2>/dev/null || true' EXIT

log "Client is writing; letting it run for 10 s"
sleep 10

log "Stopping node ${node} (docker stop)"
stopped_at=$(date +%s.%N)
docker stop "$node" >/dev/null

log "Client keeps writing for ${WRITE_SECONDS} s"
sleep "$WRITE_SECONDS"
touch "$work/stop"; wait "$writer_pid" 2>/dev/null || true
trap - EXIT

new_primary=$(primary_pod)
log "Primary is now ${new_primary} on node $(node_of "$new_primary")"

# --- The verdict -----------------------------------------------------------------------------
acked=$(awk '$2=="ok"{print $3}' "$work/log" | sort -n)
acked_count=$(printf '%s\n' "$acked" | grep -c . || true)
failed_count=$(grep -c ' fail$' "$work/log" || true)
in_db=$(psql_primary "select id from events where note = '$run' order by id")
lost=$(comm -23 <(printf '%s\n' "$acked" | sort) <(printf '%s\n' "$in_db" | sort) | grep -c . || true)

# Unavailability: the longest gap between two successful writes. A few writes can still succeed
# just after the node is stopped, before the failure is detected, so the gap is measured where it
# actually happens rather than around the moment of the stop.
outage=$(awk '
  $2=="ok" { if (prev && $1 - prev > gap) gap = $1 - prev; prev = $1 }
  END { if (prev) printf "%.1f", gap; else print "n/a" }' "$work/log")

log "Restarting node ${node} and waiting for the cluster to heal"
heal_start=$(now)
docker start "$node" >/dev/null
wait_for 600 "3 PostgreSQL instances" bash -c \
  '[ "$(kubectl -n demo get cluster pg -o jsonpath="{.status.readyInstances}")" = "3" ]'
heal=$(( $(now) - heal_start ))

{
  echo "# Failure drill: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Stopped node \`${node}\`, which hosted the PostgreSQL primary \`${old_primary}\`, while a client wrote every 200 ms."
  echo
  echo "| Measure | Result |"
  echo "|---|---|"
  echo "| Writes acknowledged to the client | ${acked_count} |"
  echo "| Acknowledged writes missing from the database | **${lost}** |"
  echo "| Requests that failed during the failover | ${failed_count} |"
  echo "| Longest time without a successful write | ${outage} s |"
  echo "| New primary | \`${new_primary}\` |"
  echo "| Time for the stopped node to rejoin and PostgreSQL to return to 3 instances | $(duration "$heal") |"
} > "$report"

echo; cat "$report"; echo
[ "$acked_count" -gt 0 ] || die "the client never managed to write: the drill proves nothing"
[ "$lost" -eq 0 ] || die "${lost} acknowledged write(s) were lost"
[ "$new_primary" != "$old_primary" ] || die "the primary did not move: the failover did not happen"
log "No acknowledged write was lost (report: ${report#"$ROOT"/})"
