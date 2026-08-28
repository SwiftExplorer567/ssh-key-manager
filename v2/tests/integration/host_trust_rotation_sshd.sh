#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo 'skip - Linux only'; exit 0; }
for c in ssh ssh-keygen ssh-keyscan sshd python3 go; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done

tmp=$(mktemp -d); chmod 755 "$tmp"
user="skm2ht$RANDOM"; pid=''
cleanup(){ [[ -z "$pid" ]] || sudo kill "$pid" >/dev/null 2>&1 || true; id "$user" >/dev/null 2>&1 && sudo userdel "$user" >/dev/null 2>&1 || true; sudo rm -rf "$tmp"; }
trap cleanup EXIT
home="$tmp/home"
sudo useradd -d "$home" -M -s /bin/bash "$user"; sudo passwd -d "$user" >/dev/null
sudo mkdir -p "$home/.ssh"; sudo chown -R "$user:$user" "$home"; sudo chmod 700 "$home" "$home/.ssh"
port=$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)
ssh-keygen -q -t ed25519 -N '' -C old-host -f "$tmp/oldhost"
ssh-keygen -q -t ed25519 -N '' -C new-host -f "$tmp/newhost"
ssh-keygen -q -t ed25519 -N '' -C wrong-host -f "$tmp/wronghost"
ssh-keygen -q -t ed25519 -N '' -C bootstrap -f "$tmp/bootstrap"
cp "$tmp/oldhost" "$tmp/host"
cp "$tmp/oldhost.pub" "$tmp/host.pub"
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
start_sshd(){
  sudo "$(command -v sshd)" -D -e -f "$tmp/sshd_config" >"$tmp/sshd.log" 2>&1 & pid=$!
  for _ in {1..40}; do
    ssh -i "$tmp/bootstrap" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=1 -p "$port" "$user"@127.0.0.1 true >/dev/null 2>&1 && return 0
    sleep .2
  done
  return 1
}
stop_sshd(){ sudo kill "$pid" >/dev/null 2>&1 || true; wait "$pid" 2>/dev/null || true; pid=''; }
sudo mkdir -p /run/sshd
start_sshd

v1="$tmp/v1"; mkdir -p "$v1"
printf 'target|%s|127.0.0.1|%s\n' "$user" "$port" > "$v1/servers.conf"
: > "$v1/identities.conf"; : > "$v1/policy.conf"
read -r old_type old_blob _ < "$tmp/oldhost.pub"
printf '[127.0.0.1]:%s %s %s\n' "$port" "$old_type" "$old_blob" > "$v1/known_hosts"
chmod 600 "$v1"/*
mkdir -p "$tmp/controller"; chmod 700 "$tmp/controller"
export SKM2_CONFIG_DIR="$tmp/config"
export SKM2_BOOTSTRAP_KEY="$tmp/bootstrap"
export SKM2_MANAGED_KEY="$tmp/controller/id_ed25519_skm2"
go build -o "$tmp/skm2" ./cmd/skm2
"$tmp/skm2" migrate v1 "$v1" --save >/dev/null
old_fp=$(ssh-keygen -E sha256 -lf "$tmp/oldhost.pub" | awk '{print $2}')
new_fp=$(ssh-keygen -E sha256 -lf "$tmp/newhost.pub" | awk '{print $2}')
"$tmp/skm2" host verify target > "$tmp/verify-old.json"
grep -q '"ok": true' "$tmp/verify-old.json"
"$tmp/skm2" host scan target > "$tmp/scan-old.json"
grep -Fq "$old_fp" "$tmp/scan-old.json"

# Real server identity changes underneath the stable node/route.
stop_sshd
cp "$tmp/newhost" "$tmp/host"; cp "$tmp/newhost.pub" "$tmp/host.pub"
start_sshd
if "$tmp/skm2" host verify target >"$tmp/verify-stale.out" 2>"$tmp/verify-stale.err"; then
  echo 'FAIL: stale host pin verified after server identity changed' >&2
  exit 1
fi
grep -q '"ok": false' "$tmp/verify-stale.out"

# A user-supplied key that is not currently presented must never be trusted.
if "$tmp/skm2" host rotate target --expected-old "$old_fp" --key "$tmp/wronghost.pub" --yes >"$tmp/wrong.out" 2>"$tmp/wrong.err"; then
  echo 'FAIL: unpresented host key candidate was trusted' >&2
  exit 1
fi
grep -q 'is not currently presented' "$tmp/wrong.err"

# Rotation requires both the expected old pin and a candidate proven to be
# currently presented by the endpoint.
"$tmp/skm2" host rotate target --expected-old "$old_fp" --key "$tmp/newhost.pub" --yes > "$tmp/rotate.json"
grep -Fq "$new_fp" "$tmp/rotate.json"
"$tmp/skm2" host verify target > "$tmp/verify-new.json"
grep -q '"ok": true' "$tmp/verify-new.json"
grep -Fq "$new_fp" "$tmp/verify-new.json"

# Pinned OpenSSH control-plane access must work again under the rotated trust.
"$tmp/skm2" node enroll target --yes > /dev/null
[[ "$("$tmp/skm2" node bridge-version target)" == 'SKM2-BRIDGE|2' ]]

echo 'host trust rotation sshd integration passed'
