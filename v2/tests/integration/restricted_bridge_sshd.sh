#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo 'skip - Linux only'; exit 0; }
for c in ssh ssh-keygen sshd python3; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done

tmp=$(mktemp -d); pid=''
cleanup(){ [[ -z "$pid" ]] || sudo kill "$pid" >/dev/null 2>&1 || true; sudo rm -rf "$tmp"; }
trap cleanup EXIT
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
ssh_base=(ssh -i "$tmp/controller" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$port" root@127.0.0.1)

for _ in {1..30}; do
  if "${ssh_base[@]}" version 2>/dev/null | grep -q '^SKM2-BRIDGE|3$'; then break; fi
  sleep .2
done

out=$("${ssh_base[@]}" inspect)
grep -q '^SKM2-STATE|3$' <<<"$out"
rev=$(awk -F= '/^revision=/{print $2; exit}' <<<"$out")
[[ -n "$rev" ]]

# The enrolled management key must never turn into a generic shell key.
if "${ssh_base[@]}" 'uname -a' >/dev/null 2>&1; then
  echo 'FAIL: enrolled management key obtained arbitrary shell command execution' >&2
  exit 1
fi

# A revision-matched apply updates authorized_keys, ownership metadata and a
# mutation receipt. Ownership is protocol state, never inferred from comments.
printf 'new-key\n' | "${ssh_base[@]}" apply "$rev" op_apply 'SHA256:managedtest' > "$tmp/apply.out"
grep -q '^SKM2-APPLIED|3$' "$tmp/apply.out"
grep -q '^operation=op_apply$' "$tmp/apply.out"
newrev=$(awk -F= '/^revision=/{print $2; exit}' "$tmp/apply.out")
[[ -n "$newrev" && "$newrev" != "$rev" ]]
sudo grep -qx 'new-key' "$tmp/authorized_keys.target"
sudo grep -qx 'SHA256:managedtest' "$tmp/authorized_keys.target.skm2.managed"
out=$("${ssh_base[@]}" inspect)
grep -q '^managed=SHA256:managedtest$' <<<"$out"
grep -q '^last_operation=op_apply$' <<<"$out"
grep -q "^last_before=$rev$" <<<"$out"
grep -q "^last_after=$newrev$" <<<"$out"

# Reusing the stale pre-apply revision must fail closed and must not overwrite
# the receipt for the successfully committed operation.
if printf 'attacker-key\n' | "${ssh_base[@]}" apply "$rev" op_stale >"$tmp/stale.out" 2>"$tmp/stale.err"; then
  echo 'FAIL: stale apply unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'revision mismatch' "$tmp/stale.err"
sudo grep -qx 'new-key' "$tmp/authorized_keys.target"
out=$("${ssh_base[@]}" inspect)
grep -q '^last_operation=op_apply$' <<<"$out"

# Rollback is revision guarded, receipt-bearing, and restores both target and
# ownership state.
"${ssh_base[@]}" rollback "$newrev" op_rollback > "$tmp/rollback.out"
grep -q '^SKM2-APPLIED|3$' "$tmp/rollback.out"
grep -q '^operation=op_rollback$' "$tmp/rollback.out"
sudo grep -qx 'old-key' "$tmp/authorized_keys.target"
sudo test ! -s "$tmp/authorized_keys.target.skm2.managed"
out=$("${ssh_base[@]}" inspect)
grep -q '^last_operation=op_rollback$' <<<"$out"

echo 'restricted bridge sshd integration passed'
