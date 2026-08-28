#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo 'skip - Linux only'; exit 0; }
for c in ssh ssh-keygen sshd python3 go; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done

tmp=$(mktemp -d); chmod 755 "$tmp"
user="skm2rot$RANDOM"; pid=''
cleanup(){ [[ -z "$pid" ]] || sudo kill "$pid" >/dev/null 2>&1 || true; id "$user" >/dev/null 2>&1 && sudo userdel "$user" >/dev/null 2>&1 || true; sudo rm -rf "$tmp"; }
trap cleanup EXIT
home="$tmp/home"
sudo useradd -d "$home" -M -s /bin/bash "$user"
sudo passwd -d "$user" >/dev/null
sudo mkdir -p "$home/.ssh"; sudo chown -R "$user:$user" "$home"; sudo chmod 700 "$home" "$home/.ssh"
port=$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)
ssh-keygen -q -t ed25519 -N '' -f "$tmp/host"
ssh-keygen -q -t ed25519 -N '' -C bootstrap -f "$tmp/bootstrap"
ssh-keygen -q -t ed25519 -N '' -C old-credential -f "$tmp/old"
ssh-keygen -q -t ed25519 -N '' -C new-credential -f "$tmp/new"
sudo cp "$tmp/bootstrap.pub" "$home/.ssh/authorized_keys"; sudo chown "$user:$user" "$home/.ssh/authorized_keys"; sudo chmod 600 "$home/.ssh/authorized_keys"
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
LogLevel ERROR
AllowUsers $user
CFG
sudo mkdir -p /run/sshd
sudo "$(command -v sshd)" -D -e -f "$tmp/sshd_config" >"$tmp/sshd.log" 2>&1 & pid=$!
ssh_cmd(){ ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$port" "$@" "$user"@127.0.0.1 true; }
for _ in {1..40}; do ssh_cmd -i "$tmp/bootstrap" >/dev/null 2>&1 && break; sleep .2; done
ssh_cmd -i "$tmp/bootstrap"

v1="$tmp/v1"; mkdir -p "$v1"
printf 'target|%s|127.0.0.1|%s\n' "$user" "$port" > "$v1/servers.conf"
: > "$v1/identities.conf"; : > "$v1/policy.conf"
read -r host_type host_blob _ < "$tmp/host.pub"
printf '[127.0.0.1]:%s %s %s\n' "$port" "$host_type" "$host_blob" > "$v1/known_hosts"
chmod 600 "$v1"/*
mkdir -p "$tmp/controller"; chmod 700 "$tmp/controller"
export SKM2_CONFIG_DIR="$tmp/config"
export SKM2_BOOTSTRAP_KEY="$tmp/bootstrap"
export SKM2_MANAGED_KEY="$tmp/controller/id_ed25519_skm2"
go build -o "$tmp/skm2" ./cmd/skm2
"$tmp/skm2" migrate v1 "$v1" --save >/dev/null
"$tmp/skm2" node enroll target --yes >/dev/null
"$tmp/skm2" subject add device device >/dev/null
"$tmp/skm2" credential import device "$tmp/old.pub" > "$tmp/old.json"
old_id=$(python3 - "$tmp/old.json" <<'PY'
import json,sys; print(json.load(open(sys.argv[1]))['id'])
PY
)
"$tmp/skm2" policy grant device target >/dev/null
"$tmp/skm2" policy mode target authoritative >/dev/null
"$tmp/skm2" plan --node target --out "$tmp/plan-old.json" >/dev/null
"$tmp/skm2" apply "$tmp/plan-old.json" --yes >/dev/null
ssh_cmd -i "$tmp/old"

"$tmp/skm2" credential rotate device "$tmp/new.pub" > "$tmp/rotate.json"
python3 - "$tmp/rotate.json" "$old_id" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['new_credential']['status']=='active', r
assert any(c['id']==sys.argv[2] and c['status']=='retiring' for c in r['retiring']), r
PY
"$tmp/skm2" plan --node target --out "$tmp/plan-overlap.json" >/dev/null
python3 - "$tmp/plan-overlap.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert len(p['changes'])==1 and p['changes'][0]['action']=='grant', p
PY
"$tmp/skm2" apply "$tmp/plan-overlap.json" --yes >/dev/null
# During overlap both credentials authenticate.
ssh_cmd -i "$tmp/old"
ssh_cmd -i "$tmp/new"

"$tmp/skm2" credential retire device "$old_id" >/dev/null
"$tmp/skm2" plan --node target --out "$tmp/plan-retire.json" >/dev/null
python3 - "$tmp/plan-retire.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert len(p['changes'])==1 and p['changes'][0]['action']=='revoke', p
PY
"$tmp/skm2" apply "$tmp/plan-retire.json" --yes >/dev/null
if ssh_cmd -i "$tmp/old" >/dev/null 2>&1; then
  echo 'FAIL: retired credential still authenticated' >&2
  exit 1
fi
ssh_cmd -i "$tmp/new"
new_fp=$(ssh-keygen -E sha256 -lf "$tmp/new.pub" | awk '{print $2}')
old_fp=$(ssh-keygen -E sha256 -lf "$tmp/old.pub" | awk '{print $2}')
sudo grep -Fxq "$new_fp" "$home/.ssh/authorized_keys.skm2.managed"
if sudo grep -Fxq "$old_fp" "$home/.ssh/authorized_keys.skm2.managed"; then
  echo 'FAIL: retired credential remained managed' >&2
  exit 1
fi

echo 'credential rotation sshd integration passed'
