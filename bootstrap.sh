#!/usr/bin/env bash
# Set up THIS Ubuntu server: install Ansible, then apply the playbook to the machine itself.
#
#   sudo ./bootstrap.sh --admin-user alex --ssh-key-file ~/alex.pub
#   sudo ./bootstrap.sh --admin-user alex --ssh-key "ssh-ed25519 AAAA... alex@laptop" \
#        --domain home.example.com --email alex@example.com
#
# It turns SSH password logins off, so a key is required: without one you would lock yourself
# out. Run it from the console or an SSH session you keep open, and test a second login before
# closing the first.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VENV=${SERVER_SETUP_VENV:-/opt/server-setup-venv}
LOCAL=${SERVER_SETUP_LOCAL:-$HERE/local.yml}   # where the settings file is written

usage() {
    cat <<'USAGE'
Usage: sudo ./bootstrap.sh --admin-user NAME (--ssh-key KEY | --ssh-key-file FILE) [options]

Required
  --admin-user NAME      the login you will use from now on (created if missing)
  --ssh-key KEY          a public key allowed to log in (repeatable)
  --ssh-key-file FILE    a file of public keys, one per line (repeatable)

Options
  --hostname NAME        set the hostname
  --timezone ZONE        e.g. America/New_York (default UTC)
  --domain NAME          the domain Caddy serves and gets a certificate for (default localhost)
  --email ADDRESS        contact address for Let's Encrypt
  --no-docker            skip Docker and the web stack
  --no-stack             install Docker but not the Caddy stack
  --no-backups           skip the backup timer
  --extra-vars FILE      also load settings from this YAML file (repeatable)
  --check                dry run: show what would change (best effort; later steps may need earlier ones)
  --print-config         write local.yml and show it, but do not run anything
  -h, --help             this text

More settings: edit local.yml (see local.yml.example and group_vars/all.yml).
USAGE
}

die() { echo "bootstrap: $*" >&2; exit 1; }

# A public key line: a known type, base64 data, an optional comment. Never a private key.
valid_key() {
    [[ $1 != *"PRIVATE KEY"* ]] || return 1
    [[ $1 =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/]+=*(\ .*)?$ ]]
}

admin_user='' hostname='' timezone='' domain='' email=''
keys=()
no_docker=0 no_stack=0 no_backups=0 check=0 print_only=0
extra=()

while [ $# -gt 0 ]; do
    case $1 in
        --admin-user) admin_user=${2-}; shift 2 || die "--admin-user needs a value" ;;
        --ssh-key) [ -n "${2-}" ] || die "--ssh-key needs a value"; keys+=("$2"); shift 2 ;;
        --ssh-key-file)
            [ -r "${2-}" ] || die "cannot read key file '${2-}'"
            while IFS= read -r line || [ -n "$line" ]; do
                [ -z "${line//[[:space:]]/}" ] && continue
                [[ $line == \#* ]] && continue
                keys+=("$line")
            done < "$2"
            shift 2 ;;
        --hostname) hostname=${2-}; shift 2 || die "--hostname needs a value" ;;
        --timezone) timezone=${2-}; shift 2 || die "--timezone needs a value" ;;
        --domain) domain=${2-}; shift 2 || die "--domain needs a value" ;;
        --email) email=${2-}; shift 2 || die "--email needs a value" ;;
        --no-docker) no_docker=1; shift ;;
        --no-stack) no_stack=1; shift ;;
        --no-backups) no_backups=1; shift ;;
        --extra-vars)
            [ -r "${2-}" ] || die "cannot read extra-vars file '${2-}'"
            extra+=("$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"); shift 2 ;;
        --check) check=1; shift ;;
        --print-config) print_only=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

[ -n "$admin_user" ] || { usage >&2; die "--admin-user is required"; }
[[ $admin_user =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "'$admin_user' is not a valid Linux user name (lower-case letters, digits, - and _)"
[ "$admin_user" != root ] || die "choose a normal user name, not root (root logins are turned off)"
[ "${#keys[@]}" -gt 0 ] || { usage >&2; die "at least one SSH public key is required (otherwise you would be locked out)"; }
for k in "${keys[@]}"; do
    valid_key "$k" || die "this does not look like an SSH public key (is it the .pub file?): ${k:0:40}..."
done
[ -z "$domain" ] || [[ $domain =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "'$domain' is not a valid domain name"
[ -z "$timezone" ] || [[ $timezone =~ ^[A-Za-z0-9_+/-]+$ ]] || die "'$timezone' is not a valid time zone"

# ---- write local.yml (JSON is valid YAML, and python quotes everything safely) ----------
python3 - "$LOCAL" "$admin_user" "$hostname" "$timezone" "$domain" "$email" \
    "$no_docker" "$no_stack" "$no_backups" "${keys[@]}" <<'PY'
import json, sys
path, user, host, tz, domain, email, nodocker, nostack, nobackup, *keys = sys.argv[1:]
cfg = {"admin_user": user, "admin_ssh_keys": keys}
if host: cfg["server_hostname"] = host
if tz: cfg["server_timezone"] = tz
if domain: cfg["stack_domain"] = domain
if email: cfg["stack_acme_email"] = email
if nodocker == "1": cfg["enable_docker"] = False
if nostack == "1": cfg["enable_stack"] = False
if nobackup == "1": cfg["enable_backups"] = False
with open(path, "w") as f:
    f.write("---\n# Written by bootstrap.sh (git-ignored). Edit freely; re-run bootstrap.sh or ansible-playbook.\n")
    f.write(json.dumps(cfg, indent=2) + "\n")
PY
echo "wrote $LOCAL"
if [ "$print_only" = 1 ]; then
    cat "$LOCAL"
    exit 0
fi

[ "$(id -u)" = 0 ] || die "run this with sudo"
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = ubuntu ] || die "this is for Ubuntu Server (found ${PRETTY_NAME:-unknown})"
case ${VERSION_ID:-} in 22.04|24.04) ;; *) die "Ubuntu 22.04 or 24.04 LTS is required (found ${VERSION_ID:-unknown})" ;; esac

# ---- Ansible in its own virtualenv (the same recent version on 22.04 and 24.04) ---------
if [ ! -x "$VENV/bin/ansible-playbook" ]; then
    echo "installing Ansible into $VENV"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq python3-venv python3-pip git ca-certificates >/dev/null
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip
    "$VENV/bin/pip" install --quiet 'ansible-core>=2.16'
fi
export PATH="$VENV/bin:$PATH"
ansible-galaxy collection install -r "$HERE/requirements.yml" >/dev/null

cd "$HERE"
args=(site.yml -e "@$LOCAL")
for f in "${extra[@]}"; do args+=(-e "@$f"); done
[ "$check" = 1 ] && args+=(--check --diff)
ansible-playbook "${args[@]}"

[ "$check" = 1 ] && { echo; echo "Dry run finished: nothing was changed."; exit 0; }

echo
"$HERE/scripts/verify.sh" || echo "(some checks failed: see above)"
cat <<DONE

Done. Before you close this session:
  1. Open a SECOND terminal and log in:   ssh $admin_user@<this server's address>
  2. Save the backup password somewhere safe:   sudo cat /etc/restic/password
     (without it the backups cannot be read)
  3. Read docs/runbook.md for day-to-day tasks.
DONE
