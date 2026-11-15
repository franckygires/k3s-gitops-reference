#!/usr/bin/env bash
# Publish the working tree to a small Git server that the cluster can reach.
#
# Argo CD only ever reads Git. In local mode that Git is a mirror of this checkout, so what runs
# in the cluster is exactly what is on disk, including uncommitted work, without pushing anywhere.
# Prints the repository URL as seen from inside the cluster.
. "$(dirname "$0")/lib.sh"

snapshot="$CACHE/snapshot"
bare="$CACHE/mirror/repo.git"
mkdir -p "$snapshot" "$CACHE/mirror"

git_s() { git -C "$snapshot" -c user.name=mirror -c user.email=mirror@localhost "$@"; }

[ -d "$snapshot/.git" ] || git_s init -q -b main

# Replace the snapshot's content with the working tree, keeping its history.
find "$snapshot" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
tar -C "$ROOT" --exclude=./.git --exclude=./.cache --exclude=./bin -cf - . | tar -C "$snapshot" -xf -
git_s add -A
if ! git_s diff --cached --quiet || ! git_s rev-parse -q --verify HEAD >/dev/null; then
  git_s commit -q --allow-empty -m "snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

[ -d "$bare" ] || git init -q --bare -b main "$bare"
git_s push -q --force "$bare" main
# Static ("dumb") HTTP needs this index refreshed after every push.
git -C "$bare" update-server-info

if ! docker ps --format '{{.Names}}' | grep -qx "$MIRROR_NAME"; then
  docker rm -f "$MIRROR_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$MIRROR_NAME" --network "$NETWORK" --restart unless-stopped \
    -v "$CACHE/mirror:/usr/share/nginx/html:ro" nginx:alpine >/dev/null
fi

ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NETWORK\").IPAddress}}" "$MIRROR_NAME")
[ -n "$ip" ] || die "could not find the Git mirror's address on network $NETWORK"
echo "http://${ip}/repo.git"
