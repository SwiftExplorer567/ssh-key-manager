#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[[ "$(uname -s)" == "Linux" ]] || { printf 'skip - Linux-only OpenSSH integration test\n'; exit 0; }

for cmd in ssh ssh-keygen ssh-agent ssh-add python3; do
    command -v "$cmd" >/dev/null 2>&1 || { printf 'missing required command: %s\n' "$cmd" >&2; exit 1; }
done
SSHD_BIN=$(command -v sshd || true)
[[ -n "$SSHD_BIN" ]] || { printf 'sshd is required for integration test\n' >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/skm-sshd.XXXXXX")
sshd_pid=""
agent_started=0
cleanup() {
    if [[ -n "$sshd_pid" ]]; then sudo kill "$sshd_pid" >/dev/null 2>&1 || true; fi
    if (( agent_started == 1 )); then ssh-agent -k >/dev/null 2>&1 || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
chmod 755 "$tmp"

user=$(id -un)
port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)

ssh-keygen -q -t ed25519 -N '' -f "$tmp/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/managed"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/decoy"
cp "$tmp/decoy.pub" "$tmp/authorized_keys"
chmod 644 "$tmp/authorized_keys"

cat > "$tmp/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $tmp/host_key
PidFile $tmp/sshd.pid
AuthorizedKeysFile $tmp/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
UsePAM no
StrictModes no
LogLevel ERROR
AllowUsers $user
EOF

sudo "$SSHD_BIN" -D -e -f "$tmp/sshd_config" > "$tmp/sshd.log" 2>&1 &
sshd_pid=$!

ready=0
for _ in $(seq 1 30); do
    if ssh -i "$tmp/decoy" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=1 -p "$port" "$user@127.0.0.1" true >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.2
done
if (( ready != 1 )); then
    cat "$tmp/sshd.log" >&2 || true
    printf 'isolated sshd did not become ready\n' >&2
    exit 1
fi

eval "$(ssh-agent -s)" >/dev/null
agent_started=1
ssh-add "$tmp/decoy" >/dev/null

export SKM_TESTING=1
export SKM_CONFIG_DIR="$tmp/skm-config"
export SKM_SSH_DIR="$tmp/skm-ssh"
export SKM_MANAGED_KEY="$tmp/managed"
export SKM_KNOWN_HOSTS_FILE="$tmp/skm-known-hosts"
export SKM_STRICT_HOST_KEY_CHECKING=no
mkdir -p "$SKM_CONFIG_DIR" "$SKM_SSH_DIR"
: > "$SKM_KNOWN_HOSTS_FILE"

# shellcheck source=src/runtime.sh
source "$ROOT/src/runtime.sh"
# shellcheck source=src/hosts.sh
source "$ROOT/src/hosts.sh"
# shellcheck source=src/host_trust.sh
source "$ROOT/src/host_trust.sh"
# shellcheck source=src/ssh_transport.sh
source "$ROOT/src/ssh_transport.sh"

HOST_NAMES=(integration)
HOST_USERS=("$user")
HOST_ADDRS=(127.0.0.1)
HOST_PORTS=("$port")
HOST_STATUSES=(active)

# The agent has a valid decoy key, but SKM must offer only its managed key.
if ssh_run_batch 0 true >/dev/null 2>&1; then
    printf 'FAIL: SKM authenticated with an agent/default identity instead of the managed key\n' >&2
    exit 1
fi
printf 'ok - unmanaged agent identity cannot satisfy SKM transport\n'

cp "$tmp/managed.pub" "$tmp/authorized_keys"
chmod 644 "$tmp/authorized_keys"
if ! ssh_run_batch 0 true >/dev/null 2>&1; then
    cat "$tmp/sshd.log" >&2 || true
    printf 'FAIL: authorized SKM managed key could not authenticate\n' >&2
    exit 1
fi
printf 'ok - managed identity authenticates when explicitly authorized\n'
printf 'OpenSSH integration test passed.\n'
