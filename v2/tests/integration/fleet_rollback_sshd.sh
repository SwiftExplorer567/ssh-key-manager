#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo 'skip - Linux only'; exit 0; }
for c in ssh ssh-keygen sshd python3 go; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done

tmp=$(mktemp -d)
chmod 755 "$tmp"
user1="skm2f1$RANDOM"
user2="skm2f2$RANDOM"
pid=''
cleanup() {
  [[ -z "$pid" ]] || sudo kill "$pid" >/dev/null 2>&1 || true
  id "$user1" >/dev/null 2>&1 && sudo userdel "$user1" >/dev/null 2>&1 || true
  id "$user2" >/dev/null 2>&1 && sudo userdel "$user2" >/dev/null 2>&1 || true
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

home1="$tmp/home1"
home2="$tmp/home2"
for spec in "$user1:$home1" "$user2:$home2"; do
  u=${spec%%:*}; h=${spec#*:}
  sudo useradd -d "$h" -M -s /bin/bash "$u"
  sudo passwd -d "$u" >/dev/null
  sudo mkdir -p "$h/.ssh"
  sudo chown -R "$u:$u" "$h"
  sudo chmod 700 "$h" "$h/.ssh"
done

read -r port1 port2 < <(python3 - <<'PY'
import socket
s1=socket.socket(); s1.bind(('127.0.0.1',0))
s2=socket.socket(); s2.bind(('127.0.0.1',0))
print(s1.getsockname()[1], s2.getsockname()[1])
s1.close(); s2.close()
PY
)

ssh-keygen -q -t ed25519 -N '' -f "$tmp/host"
ssh-keygen -q -t ed25519 -N '' -C bootstrap -f "$tmp/bootstrap"
ssh-keygen -q -t ed25519 -N '' -C fleet-smoke -f "$tmp/smoke"
for spec in "$user1:$home1" "$user2:$home2"; do
  u=${spec%%:*}; h=${spec#*:}
  sudo cp "$tmp/bootstrap.pub" "$h/.ssh/authorized_keys"
  sudo chown "$u:$u" "$h/.ssh/authorized_keys"
  sudo chmod 600 "$h/.ssh/authorized_keys"
done

cat > "$tmp/sshd_config" <<CFG
Port $port1
Port $port2
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
AllowUsers $user1 $user2
CFG

sudo mkdir -p /run/sshd
sudo "$(command -v sshd)" -D -e -f "$tmp/sshd_config" >"$tmp/sshd.log" 2>&1 & pid=$!
ssh_bootstrap() {
  local user=$1 port=$2; shift 2
  ssh -i "$tmp/bootstrap" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 -p "$port" "$user"@127.0.0.1 "$@"
}
for _ in {1..40}; do
  if ssh_bootstrap "$user1" "$port1" true >/dev/null 2>&1 && ssh_bootstrap "$user2" "$port2" true >/dev/null 2>&1; then
    break
  fi
  sleep .2
done
ssh_bootstrap "$user1" "$port1" true
ssh_bootstrap "$user2" "$port2" true

v1="$tmp/v1"
mkdir -p "$v1"
printf 'target1|%s|127.0.0.1|%s\n' "$user1" "$port1" > "$v1/servers.conf"
printf 'target2|%s|127.0.0.1|%s\n' "$user2" "$port2" >> "$v1/servers.conf"
: > "$v1/identities.conf"
: > "$v1/policy.conf"
read -r host_type host_blob _ < "$tmp/host.pub"
printf '[127.0.0.1]:%s %s %s\n' "$port1" "$host_type" "$host_blob" > "$v1/known_hosts"
printf '[127.0.0.1]:%s %s %s\n' "$port2" "$host_type" "$host_blob" >> "$v1/known_hosts"
chmod 600 "$v1"/*

mkdir -p "$tmp/controller"
chmod 700 "$tmp/controller"
export SKM2_CONFIG_DIR="$tmp/config"
export SKM2_BOOTSTRAP_KEY="$tmp/bootstrap"
export SKM2_MANAGED_KEY="$tmp/controller/id_ed25519_skm2"
go build -o "$tmp/skm2" ./cmd/skm2

"$tmp/skm2" migrate v1 "$v1" --save > /dev/null
"$tmp/skm2" node enroll target1 --yes > /dev/null
"$tmp/skm2" node enroll target2 --yes > /dev/null
"$tmp/skm2" subject add fleet-smoke service > /dev/null
"$tmp/skm2" credential import fleet-smoke "$tmp/smoke.pub" > /dev/null
"$tmp/skm2" policy grant fleet-smoke target1 > /dev/null
"$tmp/skm2" policy grant fleet-smoke target2 > /dev/null

"$tmp/skm2" node inspect target1 > "$tmp/i1.json"
"$tmp/skm2" node inspect target2 > "$tmp/i2.json"
python3 - "$tmp/i1.json" "$tmp/i2.json" "$tmp/observed.json" <<'PY'
import json,sys
obs=[json.load(open(sys.argv[1]))['observed'], json.load(open(sys.argv[2]))['observed']]
json.dump(obs, open(sys.argv[3],'w'))
PY
"$tmp/skm2" plan --observed "$tmp/observed.json" --out "$tmp/plan.json" > /dev/null
python3 - "$tmp/plan.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert len(p['changes']) == 2, p
assert all(c['action']=='grant' for c in p['changes']), p
assert len(p['expected_revisions']) == 2, p
PY

# ApplyPlanSafe sorts principals by stable ID. Sabotage only the second principal
# so the first target is definitely mutated before the deliberate second-target
# failure. The wrapper still delegates capabilities/inspect to the real bridge,
# therefore full-fleet preflight succeeds before mutation starts.
"$tmp/skm2" node list > "$tmp/nodes.json"
read -r fail_node fail_user fail_port < <(python3 - "$tmp/nodes.json" <<'PY'
import json,sys
pairs=[]
for n in json.load(open(sys.argv[1])):
  for p in n['principals']:
    r=sorted(p['routes'], key=lambda x:(x.get('priority',0),x['id']))[0]
    pairs.append((p['id'],n['name'],p['username'],r.get('port',22)))
pairs.sort()
_,node,user,port=pairs[-1]
print(node,user,port)
PY
)

ssh_bootstrap "$fail_user" "$fail_port" sh -s <<'REMOTE'
set -eu
bridge="$HOME/.local/libexec/skm2/bridge"
cp "$bridge" "$bridge.real"
cat > "$bridge" <<'WRAPPER'
#!/bin/sh
case "${SSH_ORIGINAL_COMMAND:-${1:-}}" in
  apply\ *) echo 'deliberate fleet integration apply failure' >&2; exit 97 ;;
  *) exec "$HOME/.local/libexec/skm2/bridge.real" "$@" ;;
esac
WRAPPER
chmod 700 "$bridge"
REMOTE

if "$tmp/skm2" apply "$tmp/plan.json" --yes >"$tmp/apply.out" 2>"$tmp/apply.err"; then
  echo 'FAIL: fleet apply unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'automatic rollback completed for 1 previously applied target' "$tmp/apply.err"
if grep -q 'AUTOMATIC ROLLBACK INCOMPLETE' "$tmp/apply.err"; then
  echo 'FAIL: rollback was reported incomplete' >&2
  cat "$tmp/apply.err" >&2
  exit 1
fi

read -r _ smoke_blob _ < "$tmp/smoke.pub"
for h in "$home1" "$home2"; do
  if sudo grep -Fq "$smoke_blob" "$h/.ssh/authorized_keys"; then
    echo "FAIL: fleet-smoke credential remained in $h" >&2
    exit 1
  fi
  sudo test ! -s "$h/.ssh/authorized_keys.skm2.managed"
done

# The first target has an auto-rollback receipt/history entry. The second target
# never committed the sabotaged apply and therefore must remain at its preflight
# revision without being guessed/rolled back.
grep -q '"operation":"auto-rollback"' "$tmp/config/history.jsonl"

echo 'fleet rollback sshd integration passed'
