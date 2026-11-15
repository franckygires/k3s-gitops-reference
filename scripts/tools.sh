#!/usr/bin/env bash
# Install the pinned k3d release into ./bin, after checking its published checksum.
# docker, kubectl and helm are expected to be installed already.
. "$(dirname "$0")/lib.sh"

need docker "https://docs.docker.com/engine/install/"
need kubectl "https://kubernetes.io/docs/tasks/tools/"
need helm "https://helm.sh/docs/intro/install/"
need curl

if [ -x "$ROOT/bin/k3d" ] && "$ROOT/bin/k3d" version | grep -q "${K3D_VERSION}"; then
  log "k3d ${K3D_VERSION} already installed in ./bin"
  exit 0
fi

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
asset="k3d-${os}-${arch}"
base="https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}"

log "Downloading k3d ${K3D_VERSION} (${asset})"
mkdir -p "$ROOT/bin"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$asset" "$base/$asset"
curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt"

expected=$(awk -v a="$asset" '$2 ~ a"$" {print $1; exit}' "$tmp/checksums.txt")
actual=$(sha256sum "$tmp/$asset" | cut -d' ' -f1)
[ -n "$expected" ] || die "no checksum published for $asset"
[ "$expected" = "$actual" ] || die "checksum mismatch for $asset (expected $expected, got $actual)"

install -m 0755 "$tmp/$asset" "$ROOT/bin/k3d"
log "Installed $("$ROOT/bin/k3d" version | head -1) (checksum verified)"
