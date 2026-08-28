#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo 'skip - Linux only'; exit 0; }
for c in ssh ssh-keygen sshd python3 go; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done

tmp=$(mktemp -d)
chmod 755 "$tmp"
user="skm2ci$RANDOM"
pid=''
cleanup() {
  [[ -z "$pid" ]] || sudo kill "$pid" >/dev/null 2>&1 || true
  id "$user" >/dev/null 2>&1 && sudo userdel "$user" >/dev/null 2>&1 || true
  sudo rm -rf "$tmp"
}
on_exit() {
  rc=$?
  trap - EXIT
  if (( rc != 0 )) && [[ -f "$tmp/sshd.log" ]]; then
    echo '=== sshd.log ===' >&2
    sudo cat "$tmp/sshd.log" >&2 || true
  fi
  cleanup
  exit "$rc"
}
trap on_exit EXIT

home="$tmp/home"
sudo useradd -d "$home" -M -s /bin/bash "$user"
# Ubuntu useradd creates a locked password field. Password authentication stays
# disabled in this isolated sshd; deleting the password only makes pubkey login
# eligible for the temporary account.
sudo passwd -d "$user" >/dev/null
sudo mkdir -p "$home/.ssh"
sudo chown -R "$user:$user" "$home"
sudo chmod 700 "$home" "$home/.ssh"

port=$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)
ssh-keygen -q -t ed25519 -N '' -f "$tmp/host"
ssh-keygen -q -t ed25519 -N '' -C 'bootstrap' -f "$tmp/bootstrap"
ssh-keygen -q -t ed25519 -N '' -C 'smoke' -f "$tmp/smoke"
sudo cp "$tmp/bootstrap.pub" "$home/.ssh/authorized_keys"
sudo chown "$user:$user" "$home/.ssh/authorized_keys"
sudo chmod 600 "$home/.ssh/authorized_keys"

cat > "$tmp/sshd_config" <<CFG
Port $port
ListenAddress 127.0.0.1
HostKey $tmp/host
PidFile $tmp/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
LogLevel VERBOSE
AllowUsers $user
CFG

sudo mkdir -p /run/sshd
sudo "$(command -v sshd)" -D -e -f "$tmp/sshd_config" >"$tmp/sshd.log" 2>&1 & pid=$!
for _ in {1..40}; do
  if ssh -i "$tmp/bootstrap" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=1 -p "$port" "$user"@127.0.0.1 true >/dev/null 2>&1; then
    break
  fi
  sleep .2
done
ssh -i "$tmp/bootstrap" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$port" "$user"@127.0.0.1 true

v1="$tmp/v1"
mkdir -p "$v1"
printf 'target|%s|127.0.0.1|%s\n' "$user" "$port" > "$v1/servers.conf"
: > "$v1/identities.conf"
: > "$v1/policy.conf"
read -r host_type host_blob _ < "$tmp/host.pub"
printf '[127.0.0.1]:%s %s %s\n' "$port" "$host_type" "$host_blob" > "$v1/known_hosts"
chmod 600 "$v1"/*

# Keep controller-private material in its own 0700 directory. The controller
# intentionally hardens the managed key's parent directory; it must not be the
# same parent that contains the simulated remote account home.
mkdir -p "$tmp/controller"
chmod 700 "$tmp/controller"
export SKM2_CONFIG_DIR="$tmp/config"
export SKM2_BOOTSTRAP_KEY="$tmp/bootstrap"
export SKM2_MANAGED_KEY="$tmp/controller/id_ed25519_skm2"
go build -o "$tmp/skm2" ./cmd/skm2

"$tmp/skm2" migrate v1 "$v1" --save > "$tmp/migrate.json"
"$tmp/skm2" node enroll target --yes > "$tmp/enroll.json"
grep -q 'SKM2-BRIDGE|2' "$tmp/enroll.json"
[[ "$("$tmp/skm2" node bridge-version target)" == 'SKM2-BRIDGE|2' ]]
"$tmp/skm2" node inspect target > "$tmp/inspect.json"
grep -q '"node_name": "target"' "$tmp/inspect.json"

"$tmp/skm2" subject add smoke service > /dev/null
"$tmp/skm2" credential import smoke "$tmp/smoke.pub" > "$tmp/credential.json"
"$tmp/skm2" policy grant smoke target > /dev/null
"$tmp/skm2" policy mode target authoritative > /dev/null
"$tmp/skm2" plan --node target --out "$tmp/plan.json" > /dev/null
python3 - "$tmp/plan.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert len(p['changes']) == 1, p
assert p['changes'][0]['action'] == 'grant', p
assert p['expected_revisions'], p
PY

"$tmp/skm2" apply "$tmp/plan.json" --yes > "$tmp/apply.json"
newrev=$(python3 - "$tmp/apply.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]))
assert len(v) == 1, v
print(v[0]['new_revision'])
PY
)
[[ -n "$newrev" ]]
read -r _ smoke_blob _ < "$tmp/smoke.pub"
sudo grep -Fq "$smoke_blob" "$home/.ssh/authorized_keys"
smoke_fp=$(ssh-keygen -E sha256 -lf "$tmp/smoke.pub" | awk '{print $2}')
sudo grep -Fxq "$smoke_fp" "$home/.ssh/authorized_keys.skm2.managed"

# A plan snapshot cannot be replayed after its observed remote revision changed.
if "$tmp/skm2" apply "$tmp/plan.json" --yes >"$tmp/stale.out" 2>"$tmp/stale.err"; then
  echo 'FAIL: stale plan unexpectedly applied twice' >&2
  exit 1
fi
grep -q 'remote revision mismatch' "$tmp/stale.err"

# Roll back the grant, then remove the restricted controller key using the
# original bootstrap credential. This leaves the test account with its initial
# authorization state.
"$tmp/skm2" node rollback target --expected "$newrev" --yes > "$tmp/rollback.json"
if sudo grep -Fq "$smoke_blob" "$home/.ssh/authorized_keys"; then
  echo 'FAIL: smoke credential remained after rollback' >&2
  exit 1
fi
sudo test ! -s "$home/.ssh/authorized_keys.skm2.managed"

read -r _ managed_blob _ < "$tmp/controller/id_ed25519_skm2.pub"
read -r _ bootstrap_blob _ < "$tmp/bootstrap.pub"
sudo grep -Fq "$managed_blob" "$home/.ssh/authorized_keys"
"$tmp/skm2" node unenroll target --yes > "$tmp/unenroll.json"
if sudo grep -Fq "$managed_blob" "$home/.ssh/authorized_keys"; then
  echo 'FAIL: restricted management key remained after unenroll' >&2
  exit 1
fi
sudo grep -Fq "$bootstrap_blob" "$home/.ssh/authorized_keys"
if "$tmp/skm2" node bridge-version target >/dev/null 2>&1; then
  echo 'FAIL: bridge remained reachable with removed management key' >&2
  exit 1
fi

echo 'controller lifecycle sshd integration passed'
