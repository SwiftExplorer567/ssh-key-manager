#!/bin/sh
set -eu
VERSION="2.0.0-beta.1"
REPO="SwiftExplorer567/ssh-key-manager"
os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m)
case "$arch" in x86_64|amd64) arch=amd64;; arm64|aarch64) arch=arm64;; *) echo "unsupported architecture: $arch" >&2; exit 1;; esac
case "$os" in darwin|linux) ;; *) echo "unsupported OS: $os" >&2; exit 1;; esac
asset="skm2-${os}-${arch}"
dir="${HOME}/.local/bin"; mkdir -p "$dir"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT HUP INT TERM
base="https://github.com/$REPO/releases/download/v$VERSION"
curl -fL --proto '=https' --tlsv1.2 "$base/$asset" -o "$tmp/skm2"
curl -fL --proto '=https' --tlsv1.2 "$base/$asset.sha256" -o "$tmp/skm2.sha256"
expected=$(awk '{print $1}' "$tmp/skm2.sha256")
if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$tmp/skm2"|awk '{print $1}'); else actual=$(shasum -a 256 "$tmp/skm2"|awk '{print $1}'); fi
[ "$expected" = "$actual" ] || { echo checksum mismatch >&2; exit 1; }
chmod 755 "$tmp/skm2"; mv "$tmp/skm2" "$dir/skm2"; ln -sf "$dir/skm2" "$dir/skm-v2-beta"
echo "Installed SKM V2 beta $VERSION to $dir/skm2"
