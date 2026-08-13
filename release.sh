#!/usr/bin/env bash
# Prepare a verified release commit and annotated tag. Pushing is explicit.

set -o errexit
set -o nounset
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"

new_version="${1:-}"
[[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Usage: ./release.sh X.Y.Z" >&2
    exit 2
}

[[ -z "$(git status --short)" ]] || { echo "Working tree must be clean." >&2; exit 1; }
[[ "$(git branch --show-current)" == "main" ]] || { echo "Release from main." >&2; exit 1; }

current=$(sed -n 's/^VERSION="\([0-9.]*\)"/\1/p' src/runtime.sh | head -1)
[[ -n "$current" ]] || { echo "Cannot read current version." >&2; exit 1; }
git rev-parse "v$new_version" >/dev/null 2>&1 && { echo "Tag v$new_version already exists." >&2; exit 1; }

backup_dir=$(mktemp -d "${TMPDIR:-/tmp}/skm-release.XXXXXX")
cp src/runtime.sh install.sh ssh-key-manager ssh-key-manager.sha256 "$backup_dir/"
rollback_release() {
    local status="${1:-1}"
    trap - ERR HUP INT TERM
    git restore --staged -- src/runtime.sh install.sh ssh-key-manager ssh-key-manager.sha256 >/dev/null 2>&1 || true
    cp "$backup_dir/runtime.sh" src/runtime.sh
    cp "$backup_dir/install.sh" install.sh
    cp "$backup_dir/ssh-key-manager" ssh-key-manager
    cp "$backup_dir/ssh-key-manager.sha256" ssh-key-manager.sha256
    rm -rf "$backup_dir"
    echo "Release failed; version files were restored." >&2
    exit "$status"
}
trap 'rollback_release $?' ERR
trap 'rollback_release 129' HUP
trap 'rollback_release 130' INT
trap 'rollback_release 143' TERM

if [[ "$new_version" != "$current" ]]; then
    perl -pi -e "s/^VERSION=\"\Q$current\E\"/VERSION=\"$new_version\"/" src/runtime.sh install.sh
else
    echo "Source is already v$current; validating and tagging the current release."
fi
make build
make test
make lint
make check-generated

git add src/runtime.sh ssh-key-manager ssh-key-manager.sha256 install.sh
if ! git diff --cached --quiet; then
    git commit -m "chore(release): v$new_version"
fi
git tag -a "v$new_version" -m "SSH Key Manager v$new_version"
trap - ERR HUP INT TERM
rm -rf "$backup_dir"

echo "Created release commit and tag v$new_version."
echo "Review, then publish explicitly:"
echo "  git push origin main v$new_version"
