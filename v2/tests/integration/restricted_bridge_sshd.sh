#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo 'skip - Linux only'; exit 0; }
for c in ssh ssh-keygen sshd python3; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done
tmp=$(mktemp -d); pid=''; cleanup(){ [[ -z "$pid" ]] || sudo kill "$pid" >/dev/null 2>&1 || true; rm -rf "$tmp"; }; trap cleanup EXIT
chmod 755 "$tmp"
port=$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)
ssh-keygen -q -t ed25519 -N '' -f "$tmp/host"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/controller"
cp internal/bridge/bridge.sh "$tmp/bridge.sh"; chmod 755 "$tmp/bridge.sh"
printf 'old-key\n' > "$tmp/authorized_keys.target"; chmod 600 "$tmp/authorized_keys.target"
key=$(cat "$tmp/controller.pub")
printf 'restrict,command="env SKM2_AUTHORIZED_KEYS=%s %s" %s\n' "$tmp/authorized_keys.target" "$tmp/bridge.sh" "$key" > "$tmp/authorized_keys.login"
chmod 600 "$tmp/authorized_keys.login"
cat > "$tmp/sshd_config" <<CFG
Port $port
ListenAddress 127.0.0.1
HostKey $tmp/host
PidFile $tmp/sshd.pid
AuthorizedKeysFile $tmp/authorized_keys.login
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
UsePAM no
StrictModes no
LogLevel ERROR
AllowUsers root
CFG
sudo mkdir -p /run/sshd
sudo "$(command -v sshd)" -D -e -f "$tmp/sshd_config" >"$tmp/sshd.log" 2>&1 & pid=$!
for _ in {1..30}; do
  if ssh -i "$tmp/controller" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=1 -p "$port" root@127.0.0.1 version 2>/dev/null | grep -q '^SKM2-BRIDGE|1$'; then break; fi
  sleep .2
done
out=$(ssh -i "$tmp/controller" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$port" root@127.0.0.1 inspect)
grep -q '^SKM2-STATE|1$' <<<"$out"
if ssh -i "$tmp/controller" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$port" root@127.0.0.1 'uname -a' >/dev/null 2>&1; then
  echo 'FAIL: enrolled management key obtained arbitrary shell command execution' >&2; exit 1
fi
echo 'restricted bridge sshd integration passed'
