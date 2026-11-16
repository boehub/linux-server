#!/usr/bin/env bash
# Tests that need no root and change nothing on the machine:
#   bootstrap.sh argument checks, the rendered templates, the health check, the backup scripts.
# The full end-to-end test (apply the playbook for real) runs in CI; see .github/workflows/ci.yml.
#   tests/run.sh            (REQUIRE_TOOLS=1 makes a missing tool an error instead of a skip)
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0 failn=0 skipn=0

ok()   { pass=$((pass + 1)); }
bad()  { failn=$((failn + 1)); printf 'FAIL  %s\n' "$1"; [ -z "${2-}" ] || printf '      %s\n' "$2"; }
skip() { skipn=$((skipn + 1)); printf 'skip  %s\n' "$1"; }
need() {  # need TOOL: true when present; otherwise skip (or fail when REQUIRE_TOOLS is set)
    command -v "$1" >/dev/null 2>&1 && return 0
    [ -z "${REQUIRE_TOOLS-}" ] || bad "tool '$1' is required but missing"
    return 1
}
expect_ok() {    # expect_ok "name" cmd...
    local name=$1; shift; local out
    if out=$("$@" 2>&1); then ok; else bad "$name" "$(head -c 300 <<<"$out")"; fi
}
expect_fail() {  # expect_fail "name" "text the error must contain" cmd...
    local name=$1 text=$2; shift 2; local out
    if out=$("$@" 2>&1); then bad "$name" "expected a failure but it succeeded"
    elif grep -qF -- "$text" <<<"$out"; then ok
    else bad "$name" "error did not mention '$text': $(head -c 300 <<<"$out")"; fi
}
contains() {     # contains "name" file text
    if grep -qF -- "$3" "$2"; then ok; else bad "$1" "'$3' not found in $2"; fi
}

KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbcdefghijklmnopqrstuvwxyz0123456789ABCDEF ops@test"
BOOT="$ROOT/bootstrap.sh"
export SERVER_SETUP_LOCAL="$WORK/local.yml"

# ---- bootstrap.sh: refuses unsafe or wrong input ------------------------------------------
echo "== bootstrap.sh"
expect_fail "needs an admin user"        "--admin-user is required"  "$BOOT" --print-config
expect_fail "needs a key (lock-out guard)" "SSH public key is required" "$BOOT" --admin-user ops --print-config
expect_fail "rejects root as the admin"  "not root"                  "$BOOT" --admin-user root --ssh-key "$KEY" --print-config
expect_fail "rejects a bad user name"    "valid Linux user name"     "$BOOT" --admin-user 'Bad Name' --ssh-key "$KEY" --print-config
expect_fail "rejects a private key"      "does not look like"        "$BOOT" --admin-user ops --ssh-key "-----BEGIN OPENSSH PRIVATE KEY-----" --print-config
expect_fail "rejects text that is not a key" "does not look like"    "$BOOT" --admin-user ops --ssh-key "hello world" --print-config
expect_fail "rejects a bad domain"       "valid domain"              "$BOOT" --admin-user ops --ssh-key "$KEY" --domain 'a b;c' --print-config
expect_fail "rejects an unknown option"  "unknown option"            "$BOOT" --nope
expect_fail "missing key file"           "cannot read key file"      "$BOOT" --admin-user ops --ssh-key-file "$WORK/none" --print-config
expect_ok   "help works"                 "$BOOT" --help

printf '# my keys\n\n%s\n%s\n' "$KEY" "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7 second@test" > "$WORK/keys.pub"
expect_ok "writes a settings file" "$BOOT" --admin-user ops --ssh-key-file "$WORK/keys.pub" --hostname box --timezone America/New_York \
    --domain home.example.com --email me@example.com --no-backups --print-config
if need python3; then
    if python3 - "$WORK/local.yml" <<'PY'
import json, sys
text = open(sys.argv[1]).read().split("---\n", 1)[1]
cfg = json.loads("\n".join(l for l in text.splitlines() if not l.startswith("#")))
assert cfg["admin_user"] == "ops" and len(cfg["admin_ssh_keys"]) == 2, cfg
assert cfg["server_hostname"] == "box" and cfg["server_timezone"] == "America/New_York"
assert cfg["stack_domain"] == "home.example.com" and cfg["stack_acme_email"] == "me@example.com"
assert cfg["enable_backups"] is False and "enable_docker" not in cfg
PY
    then ok; else bad "settings file has the right contents"; fi
fi
# a hostile value must not turn into anything but data
expect_ok "quotes odd comments safely" "$BOOT" --admin-user ops --ssh-key 'ssh-ed25519 AAAAC3NzaC1lZDI1 a"b$(touch /tmp/pwned);c' --print-config
[ ! -e /tmp/pwned ] && ok || bad "key comment was executed as a command"

# ---- templates --------------------------------------------------------------------------
echo "== templates"
if need ansible-playbook; then
    R=/tmp/linux-server-render
    rm -rf "$R"
    if (cd "$ROOT" && ansible-playbook tests/render.yml -e @group_vars/all.yml -e admin_user=ops \
        -e '{"admin_ssh_keys":["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIATEST ops@test"],"stack_sites":[{"host":"app.example.com","upstream":"app:8080"}],"stack_acme_email":"ops@example.com","backup_env":{"SECRET":"a b$c"}}' >"$WORK/render.log" 2>&1); then
        ok
        contains "sshd: root login off"        "$R/ssh/10-hardening.conf" "PermitRootLogin no"
        contains "sshd: passwords off"         "$R/ssh/10-hardening.conf" "PasswordAuthentication no"
        contains "sshd: only the admin"        "$R/ssh/10-hardening.conf" "AllowUsers ops"
        contains "fail2ban: watches sshd"      "$R/fail2ban/jail-local.conf" "[sshd]"
        contains "caddy: serves the demo"      "$R/stack/Caddyfile" "reverse_proxy whoami:80"
        contains "caddy: extra site"           "$R/stack/Caddyfile" "reverse_proxy app:8080"
        contains "caddy: contact address"      "$R/stack/Caddyfile" "email ops@example.com"
        contains "compose: web network"        "$R/stack/compose.yml" "name: web"
        contains "sysctl: syn cookies"         "$R/sysctl/90-hardening.conf" "net.ipv4.tcp_syncookies = 1"
        contains "backup env: value is quoted" "$R/backups/env" "SECRET='a b\$c'"
        if need jq; then expect_ok "daemon.json is valid JSON" jq -e '."log-opts"."max-size"' "$R/docker/daemon.json"; fi
        # the settings must be readable by a shell exactly the way the scripts read them
        expect_ok "backup env sources cleanly" bash -c "set -a; . '$R/backups/env'; [ \"\$SECRET\" = 'a b\$c' ]"
        expect_ok "verify env sources cleanly" bash -c ". '$R/base/server-setup.env'; [ \"\$ADMIN_USER\" = ops ]"
        if command -v sshd >/dev/null 2>&1; then
            expect_ok "sshd accepts the settings" /usr/sbin/sshd -t -f "$R/ssh/10-hardening.conf"
        else need sshd || skip "sshd not installed: skipping sshd -t"; fi
    else
        bad "templates render" "$(tail -5 "$WORK/render.log")"
    fi
else skip "ansible not installed: skipping template tests"; fi

# ---- health check -------------------------------------------------------------------------
echo "== health check"
HC="$ROOT/roles/healthcheck/files/server-healthcheck"
if need jq; then
    export HC_CONF="$WORK/hc.env" HC_STATUS_FILE="$WORK/health/status.json" HC_BACKUP_STATE="$WORK/last-success" HC_DISK_PATHS="/"
    printf 'DISK_MAX_PERCENT=100\nMEM_MIN_PERCENT=0\nCHECK_BACKUPS=0\nCHECK_DOCKER=0\n' > "$HC_CONF"
    out=$("$HC" 2>&1); rc=$?
    if [ $rc -eq 0 ] || grep -q "PROBLEM: \(systemd units\|clock\|reboot\)" <<<"$out"; then ok; else bad "healthy settings give no disk/memory problems" "$out"; fi
    expect_ok "writes valid JSON" jq -e '.checks | length > 0' "$HC_STATUS_FILE"

    printf 'DISK_MAX_PERCENT=0\nMEM_MIN_PERCENT=0\nCHECK_BACKUPS=0\nCHECK_DOCKER=0\n' > "$HC_CONF"
    out=$("$HC" 2>&1); rc=$?
    [ $rc -eq 1 ] && ok || bad "a full disk is a failure (exit 1)" "rc=$rc"
    grep -q "PROBLEM: disk /" <<<"$out" && ok || bad "names the full disk" "$out"
    [ "$(jq -r .ok "$HC_STATUS_FILE")" = false ] && ok || bad "JSON says ok=false"

    printf 'DISK_MAX_PERCENT=100\nMEM_MIN_PERCENT=101\nCHECK_BACKUPS=0\nCHECK_DOCKER=0\n' > "$HC_CONF"
    out=$("$HC" 2>&1); grep -q "PROBLEM: memory" <<<"$out" && ok || bad "low memory is reported" "$out"

    printf 'DISK_MAX_PERCENT=100\nMEM_MIN_PERCENT=0\nCHECK_BACKUPS=1\nCHECK_DOCKER=0\nBACKUP_MAX_AGE_HOURS=36\n' > "$HC_CONF"
    out=$("$HC" 2>&1); grep -q "PROBLEM: backup: no successful backup" <<<"$out" && ok || bad "missing backup is reported" "$out"
    date +%s > "$HC_BACKUP_STATE"
    out=$("$HC" 2>&1); grep -q "PROBLEM: backup" <<<"$out" && bad "fresh backup is fine" "$out" || ok
    echo $(( $(date +%s) - 3 * 86400 )) > "$HC_BACKUP_STATE"
    out=$("$HC" 2>&1); grep -q "PROBLEM: backup: last success 72h ago" <<<"$out" && ok || bad "old backup is reported" "$out"
    unset HC_CONF HC_STATUS_FILE HC_BACKUP_STATE HC_DISK_PATHS
else skip "jq not installed: skipping health check tests"; fi

# ---- backups ------------------------------------------------------------------------------
echo "== backups"
if need restic && need jq; then
    B="$WORK/b"; mkdir -p "$B/data/sub" "$B/state"
    echo "hello" > "$B/data/a.txt"; echo "world" > "$B/data/sub/b.txt"; mkdir -p "$B/data/skip"; echo x > "$B/data/skip/junk.cache"
    head -c 24 /dev/urandom | base64 > "$B/pw"
    cat > "$B/env" <<ENV
RESTIC_REPOSITORY=$B/repo
RESTIC_PASSWORD_FILE=$B/pw
BACKUP_PATHS="$B/data /does/not/exist"
KEEP_DAILY=2
KEEP_WEEKLY=1
KEEP_MONTHLY=1
CHECK_SUBSET=100%
ENV
    echo "$B/data/skip" > "$B/excludes"
    export SERVER_BACKUP_ENV="$B/env" SERVER_BACKUP_STATE="$B/state" SERVER_BACKUP_EXCLUDES="$B/excludes"
    BK="$ROOT/roles/backups/files/server-backup"; RT="$ROOT/roles/backups/files/server-restore-test"

    expect_ok "first backup creates the repository and succeeds" "$BK"
    [ -s "$B/state/last-success" ] && ok || bad "records the time of the last success"
    n=$(restic -r "$B/repo" -p "$B/pw" snapshots --json | jq length)
    [ "$n" = 1 ] && ok || bad "one snapshot after one backup" "got $n"
    restic -r "$B/repo" -p "$B/pw" ls latest 2>/dev/null | grep -q "junk.cache" && bad "excluded files are left out" || ok
    expect_ok "second backup (existing repository) succeeds" "$BK"
    expect_ok "restore test passes when nothing changed" "$RT" "$B/data/a.txt" "$B/data/sub"
    echo "changed" >> "$B/data/a.txt"
    expect_fail "restore test notices a changed file" "DIFFERS" "$RT" "$B/data/a.txt"
    expect_fail "restore test notices a file that was never backed up" "MISSING" "$RT" "$B/data/never-backed-up"

    # a wrong password must stop the run, and must not create a second repository
    head -c 24 /dev/urandom | base64 > "$B/pw.wrong"
    sed "s|RESTIC_PASSWORD_FILE=.*|RESTIC_PASSWORD_FILE=$B/pw.wrong|" "$B/env" > "$B/env.wrong"
    expect_fail "wrong password is an error, not a new repository" "wrong password" env SERVER_BACKUP_ENV="$B/env.wrong" "$BK"

    # no backup paths at all
    sed "s|^BACKUP_PATHS=.*|BACKUP_PATHS=\"/does/not/exist\"|" "$B/env" > "$B/env.none"
    expect_fail "no existing paths is an error" "none of the backup paths exist" env SERVER_BACKUP_ENV="$B/env.none" "$BK"
    unset SERVER_BACKUP_ENV SERVER_BACKUP_STATE SERVER_BACKUP_EXCLUDES
else skip "restic/jq not installed: skipping backup tests"; fi

echo
printf '%d passed, %d failed, %d skipped\n' "$pass" "$failn" "$skipn"
[ "$failn" -eq 0 ]
