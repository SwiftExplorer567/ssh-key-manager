#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo 'skip - Linux only'; exit 0; }
for c in ssh ssh-keygen sshd python3 go; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done

tmp=$(mktemp -d); chmod 755 "$tmp"
target_user="skm2rt$RANDOM"; jump_user="skm2jp$RANDOM"; pid=''
ssh_config="$HOME/.ssh/config"; ssh_config_backup="$tmp/ssh_config.backup"; had_config=0
cleanup(){
  [[ -z "$pid" ]] || sudo kill "$pid" >/dev/null 2>&1 || true
  id "$target_user" >/dev/null 2>&1 && sudo userdel "$target_user" >/dev/null 2>&1 || true
  id "$jump_user" >/dev/null 2>&1 && sudo userdel "$jump_user" >/dev/null 2>&1 || true
  if (( had_config )); then cp "$ssh_config_backup" "$ssh_config"; else rm -f "$ssh_config"; fi
  sudo rm -rf "$tmp"
}
trap cleanup EXIT

target_home="$tmp/target-home"; jump_home="$tmp/jump-home"
for spec in "$target_user:$target_home" "$jump_user:$jump_home"; do
  u=${spec%%:*}; h=${spec#*:}
  sudo useradd -d "$h" -M -s /bin/bash "$u"
  sudo passwd -d "$u" >/dev/null
  sudo mkdir -p "$h/.ssh"; sudo chown -R "$u:$u" "$h"; sudo chmod 700 "$h" "$h/.ssh"
done
read -r target_port jump_port < <(python3 - <<'PY'
import socket
s1=socket.socket(); s1.bind(('127.0.0.1',0))
s2=socket.socket(); s2.bind(('127.0.0.1',0))
print(s1.getsockname()[1],s2.getsockname()[1]); s1.close(); s2.close()
PY
)
ssh-keygen -q -t ed25519 -N '' -f "$tmp/host"
ssh-keygen -q -t ed25519 -N '' -C bootstrap -f "$tmp/bootstrap"
for spec in "$target_user:$target_home" "$jump_user:$jump_home"; do
  u=${spec%%:*}; h=${spec#*:}
  sudo cp "$tmp/bootstrap.pub" "$h/.ssh/authorized_keys"
  sudo chown "$u:$u" "$h/.ssh/authorized_keys"; sudo chmod 600 "$h/.ssh/authorized_keys"
done
cat > "$tmp/sshd_config" <<CFG
Port $target_port
Port $jump_port
ListenAddress 127.0.0.1
HostKey $tmp/host
PidFile $tmp/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AllowTcpForwarding yes
UsePAM no
StrictModes no
LogLevel ERROR
AllowUsers $target_user $jump_user
CFG
sudo mkdir -p /run/sshd
sudo "$(command -v sshd)" -D -e -f "$tmp/sshd_config" >"$tmp/sshd.log" 2>&1 & pid=$!
for _ in {1..40}; do
  if ssh -i "$tmp/bootstrap" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=1 -p "$target_port" "$target_user"@127.0.0.1 true >/dev/null 2>&1; then break; fi
  sleep .2
done

v1="$tmp/v1"; mkdir -p "$v1"
printf 'target|%s|127.0.0.1|%s\n' "$target_user" "$target_port" > "$v1/servers.conf"
: > "$v1/identities.conf"; : > "$v1/policy.conf"
read -r host_type host_blob _ < "$tmp/host.pub"
printf '[127.0.0.1]:%s %s %s\n' "$target_port" "$host_type" "$host_blob" > "$v1/known_hosts"
chmod 600 "$v1"/*
mkdir -p "$tmp/controller"; chmod 700 "$tmp/controller"
export SKM2_CONFIG_DIR="$tmp/config"
export SKM2_BOOTSTRAP_KEY="$tmp/bootstrap"
export SKM2_MANAGED_KEY="$tmp/controller/id_ed25519_skm2"
go build -o "$tmp/skm2" ./cmd/skm2
"$tmp/skm2" migrate v1 "$v1" --save >/dev/null
"$tmp/skm2" node enroll target --yes >/dev/null

# 1) Ordinary OpenSSH over a Tailscale-address route uses the same pinned target
# trust model. 127.0.0.1 stands in for a reachable Tailscale IP in isolated CI.
"$tmp/skm2" route add target tailscale 127.0.0.1 --port "$target_port" --priority 5 > "$tmp/tailscale-route.json"
"$tmp/skm2" route list target > "$tmp/routes.json"
direct_id=$(python3 - "$tmp/routes.json" <<'PY'
import json,sys
for r in json.load(open(sys.argv[1])):
  if r['type']=='direct': print(r['id']); break
PY
)
"$tmp/skm2" route remove target "$direct_id" >/dev/null
[[ "$("$tmp/skm2" node bridge-version target)" == 'SKM2-BRIDGE|2' ]]

# Prepare a separately trusted jump host. Jump-host trust intentionally belongs
# to the system OpenSSH config; SKM still pins the final target host key.
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
if [[ -f "$ssh_config" ]]; then cp "$ssh_config" "$ssh_config_backup"; had_config=1; fi
printf '[127.0.0.1]:%s %s %s\n' "$jump_port" "$host_type" "$host_blob" > "$tmp/jump_known_hosts"
chmod 600 "$tmp/jump_known_hosts"
jump_alias="skm2-ci-jump-$RANDOM"; target_alias="skm2-ci-target-$RANDOM"
cat >> "$ssh_config" <<CFG
Host $jump_alias
  HostName 127.0.0.1
  Port $jump_port
  User $jump_user
  IdentityFile $tmp/bootstrap
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $tmp/jump_known_hosts
Host $target_alias
  HostName 127.0.0.1
  Port $target_port
  ProxyJump $jump_alias
CFG
chmod 600 "$ssh_config"

# 2) Explicit ProxyJump route. Remove Tailscale afterwards so success cannot be
# explained by silently falling back to the previous route.
"$tmp/skm2" route add target direct 127.0.0.1 --port "$target_port" --priority 1 --proxy-jump "$jump_alias" > "$tmp/jump-route.json"
"$tmp/skm2" route list target > "$tmp/routes.json"
tailscale_id=$(python3 - "$tmp/routes.json" <<'PY'
import json,sys
for r in json.load(open(sys.argv[1])):
  if r['type']=='tailscale': print(r['id']); break
PY
)
"$tmp/skm2" route remove target "$tailscale_id" >/dev/null
[[ "$("$tmp/skm2" node bridge-version target)" == 'SKM2-BRIDGE|2' ]]

# 3) SSH-config route resolves HostName/Port/ProxyJump with `ssh -G`, then uses
# the alias for the actual OpenSSH connection while SKM verifies the target's
# effective HostName/Port against its pinned host key.
"$tmp/skm2" route add target ssh-config "$target_alias" --priority 1 > "$tmp/config-route.json"
"$tmp/skm2" route list target > "$tmp/routes.json"
proxied_direct_id=$(python3 - "$tmp/routes.json" <<'PY'
import json,sys
for r in json.load(open(sys.argv[1])):
  if r['type']=='direct': print(r['id']); break
PY
)
"$tmp/skm2" route remove target "$proxied_direct_id" >/dev/null
"$tmp/skm2" node inspect target > "$tmp/inspect.json"
grep -q '"node_name": "target"' "$tmp/inspect.json"
"$tmp/skm2" route list target > "$tmp/routes-final.json"
python3 - "$tmp/routes-final.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert len(r)==1 and r[0]['type']=='ssh-config', r
PY

echo 'route execution sshd integration passed'
