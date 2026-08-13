#!/usr/bin/env bash
# SSH Key Manager v1 installer

set -o errexit
set -o nounset
set -o pipefail
umask 077

VERSION="1.1.0"
REPOSITORY="SwiftExplorer567/ssh-key-manager"
SYSTEM_INSTALL=0
PREFIX=""

usage() {
    cat <<'EOF'
Usage: install.sh [--system] [--prefix DIR]

Without options, installs to /usr/local/bin when writable, otherwise ~/.local/bin.
--system may request sudo for /usr/local/bin. --prefix never uses sudo.
EOF
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

verify_checksum_file() {
    local file="$1" checksum_file="$2" expected actual
    expected=$(awk 'NR == 1 {print $1}' "$checksum_file")
    expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
    [[ ${#expected} -eq 64 && "$expected" != *[!0-9a-f]* ]] || return 1
    actual=$(sha256_file "$file") || return 1
    [[ "$actual" == "$expected" ]]
}

while (( $# > 0 )); do
    case "$1" in
        --system) SYSTEM_INSTALL=1 ;;
        --prefix)
            shift
            [[ $# -gt 0 && -n "$1" && "$1" != "/" ]] || {
                echo "--prefix needs a safe directory" >&2
                exit 2
            }
            PREFIX="$1"
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

command -v bash >/dev/null 2>&1 || { echo "bash is required" >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "OpenSSH client is required" >&2; exit 1; }
command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen is required" >&2; exit 1; }

if (( BASH_VERSINFO[0] < 3 )); then
    echo "Bash 3.2 or newer is required" >&2
    exit 1
fi

if [[ -z "$PREFIX" ]]; then
    if [[ -w /usr/local/bin ]]; then PREFIX="/usr/local/bin"; else PREFIX="$HOME/.local/bin"; fi
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/skm-install.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
source_ref="${BASH_SOURCE[0]-}"
source_dir=""
if [[ -n "$source_ref" && -f "$source_ref" ]]; then
    if source_dir=$(cd "$(dirname "$source_ref")" 2>/dev/null && pwd); then :; else source_dir=""; fi
fi
source_file="${source_dir:+$source_dir/ssh-key-manager}"

if [[ -f "$source_file" ]]; then
    cp "$source_file" "$tmp_dir/ssh-key-manager"
    if [[ -f "$source_file.sha256" ]]; then
        verify_checksum_file "$tmp_dir/ssh-key-manager" "$source_file.sha256" || {
            echo "Local release checksum verification failed" >&2
            exit 1
        }
    fi
else
    command -v curl >/dev/null 2>&1 || { echo "curl is required for remote installation" >&2; exit 1; }
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || {
        echo "sha256sum or shasum is required for remote installation" >&2
        exit 1
    }
    echo "Downloading SSH Key Manager v$VERSION..."
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "https://github.com/$REPOSITORY/releases/download/v$VERSION/ssh-key-manager" \
        --output "$tmp_dir/ssh-key-manager" ||
       ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "https://github.com/$REPOSITORY/releases/download/v$VERSION/ssh-key-manager.sha256" \
        --output "$tmp_dir/ssh-key-manager.sha256"; then
        echo "Versioned assets are unavailable; using the checksummed main artifact."
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            "https://raw.githubusercontent.com/$REPOSITORY/main/ssh-key-manager" \
            --output "$tmp_dir/ssh-key-manager"
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            "https://raw.githubusercontent.com/$REPOSITORY/main/ssh-key-manager.sha256" \
            --output "$tmp_dir/ssh-key-manager.sha256"
    fi
    verify_checksum_file "$tmp_dir/ssh-key-manager" "$tmp_dir/ssh-key-manager.sha256" || {
        echo "Downloaded release checksum verification failed" >&2
        exit 1
    }
fi

grep -q '^#!/usr/bin/env bash$' "$tmp_dir/ssh-key-manager" || { echo "Downloaded file is not SSH Key Manager" >&2; exit 1; }
bash -n "$tmp_dir/ssh-key-manager" || { echo "Downloaded script failed syntax validation" >&2; exit 1; }
chmod 755 "$tmp_dir/ssh-key-manager"

install_files() {
    local destination="$1"
    mkdir -p "$destination"
    cp "$tmp_dir/ssh-key-manager" "$destination/ssh-key-manager"
    chmod 755 "$destination/ssh-key-manager"
    ln -sf "$destination/ssh-key-manager" "$destination/skm"
    ln -sf "$destination/ssh-key-manager" "$destination/keymanager"
}

if [[ "$PREFIX" == "/usr/local/bin" && ! -w "$PREFIX" ]]; then
    if (( SYSTEM_INSTALL == 1 )) && command -v sudo >/dev/null 2>&1; then
        sudo mkdir -p "$PREFIX"
        sudo cp "$tmp_dir/ssh-key-manager" "$PREFIX/ssh-key-manager"
        sudo chmod 755 "$PREFIX/ssh-key-manager"
        sudo ln -sf "$PREFIX/ssh-key-manager" "$PREFIX/skm"
        sudo ln -sf "$PREFIX/ssh-key-manager" "$PREFIX/keymanager"
    else
        echo "Cannot write to $PREFIX. Use --system or --prefix \"$HOME/.local/bin\"." >&2
        exit 1
    fi
else
    install_files "$PREFIX"
fi

mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/ssh-key-manager" "$HOME/.ssh"
chmod 700 "${XDG_CONFIG_HOME:-$HOME/.config}/ssh-key-manager" "$HOME/.ssh" 2>/dev/null || true

echo "Installed SSH Key Manager v$VERSION to $PREFIX/ssh-key-manager"
case ":$PATH:" in
    *":$PREFIX:"*) ;;
    *) echo "Add $PREFIX to PATH, then run: skm" ;;
esac
echo "Next: run skm, then choose Machines > Add a machine."
