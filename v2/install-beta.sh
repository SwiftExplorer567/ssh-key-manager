#!/bin/sh
set -eu

VERSION="2.0.0-beta.1"
REPO="SwiftExplorer567/ssh-key-manager"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)

case "$arch" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac

case "$os" in
  darwin|linux) ;;
  *) echo "unsupported OS: $os" >&2; exit 1 ;;
esac

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

asset="skm2-${os}-${arch}"
dir="${HOME}/.local/bin"
mkdir -p "$dir"
chmod 700 "$dir" 2>/dev/null || true

tmp=$(mktemp -d)
stage="$dir/.skm2.install.$$"
trap 'rm -rf "$tmp"; rm -f "$stage"' EXIT HUP INT TERM

base="https://github.com/$REPO/releases/download/v$VERSION"

curl -fL --proto '=https' --tlsv1.2 \
  "$base/$asset" -o "$tmp/skm2"
curl -fL --proto '=https' --tlsv1.2 \
  "$base/$asset.sha256" -o "$tmp/skm2.sha256"

expected=$(awk 'NR==1 {print $1}' "$tmp/skm2.sha256")
case "$expected" in
  [0-9a-fA-F][0-9a-fA-F]*) ;;
  *) echo "invalid checksum file" >&2; exit 1 ;;
esac

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/skm2" | awk '{print $1}')
else
  command -v shasum >/dev/null 2>&1 || { echo "sha256sum or shasum is required" >&2; exit 1; }
  actual=$(shasum -a 256 "$tmp/skm2" | awk '{print $1}')
fi

[ "$expected" = "$actual" ] || { echo "checksum mismatch" >&2; exit 1; }

chmod 755 "$tmp/skm2"
actual_version=$("$tmp/skm2" version 2>/dev/null || true)
[ "$actual_version" = "$VERSION" ] || {
  echo "binary version mismatch: expected $VERSION, got ${actual_version:-unknown}" >&2
  exit 1
}

cp "$tmp/skm2" "$stage"
chmod 755 "$stage"

if [ -f "$dir/skm2" ] && [ ! -L "$dir/skm2" ]; then
  cp -p "$dir/skm2" "$dir/skm2.previous"
fi

mv -f "$stage" "$dir/skm2"
ln -sfn "$dir/skm2" "$dir/skm-v2-beta"
trap - EXIT HUP INT TERM
rm -rf "$tmp"

echo "Installed SKM V2 beta $VERSION to $dir/skm2"
