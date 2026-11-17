#!/usr/bin/env bash
# Check that the server really is the way it was set up to be, by looking at the live system
# (not at the Ansible files). Prints PASS/FAIL per check; exits 1 if any failed.
#   sudo scripts/verify.sh
set -uo pipefail

ENV_FILE=${SERVER_SETUP_ENV:-/etc/server-setup.env}
[ -r "$ENV_FILE" ] || { echo "verify: $ENV_FILE not found: has the playbook been run?" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "verify: run with sudo (it reads firewall and SSH settings)" >&2; exit 2; }
# shellcheck disable=SC1090
. "$ENV_FILE"

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
check() {  # check "description" command...
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# ---- SSH ------------------------------------------------------------------------------
sshd_t=$(sshd -T 2>/dev/null)
# shellcheck disable=SC2317,SC2329  # called through check() as "$@"
sshd_has() { grep -qix "$1" <<<"$sshd_t"; }
check "SSH: root login is off"             sshd_has "permitrootlogin no"
check "SSH: password logins are off"       sshd_has "passwordauthentication no"
check "SSH: keyboard-interactive is off"   sshd_has "kbdinteractiveauthentication no"
check "SSH: only $ADMIN_USER may log in"   sshd_has "allowusers $ADMIN_USER"
check "SSH: listening on port $SSH_PORT"   bash -c "ss -ltn | grep -q ':$SSH_PORT '"
check "SSH: $ADMIN_USER has a key in authorized_keys" \
    bash -c "grep -qE '^(ssh-|ecdsa-|sk-)' \"\$(getent passwd $ADMIN_USER | cut -d: -f6)/.ssh/authorized_keys\""
check "sudo file for $ADMIN_USER is valid" visudo -cf /etc/sudoers.d/90-admin

# ---- firewall, fail2ban, kernel -------------------------------------------------------
ufw_v=$(ufw status verbose 2>/dev/null)
check "firewall: ufw is active"            grep -q "^Status: active" <<<"$ufw_v"
check "firewall: incoming is denied by default" grep -q "deny (incoming)" <<<"$ufw_v"
check "firewall: SSH port $SSH_PORT is allowed" grep -qE "^$SSH_PORT/tcp +(LIMIT|ALLOW)" <<<"$ufw_v"
check "fail2ban: running"                  systemctl is-active --quiet fail2ban
check "fail2ban: sshd jail is on"          fail2ban-client status sshd
# shellcheck disable=SC2317,SC2329
sysctl_is() { [ "$(sysctl -n "$1" 2>/dev/null)" = "$2" ]; }
check "kernel: reverse-path filtering on"  sysctl_is net.ipv4.conf.all.rp_filter 1
check "kernel: SYN cookies on"             sysctl_is net.ipv4.tcp_syncookies 1
check "kernel: ICMP redirects ignored"     sysctl_is net.ipv4.conf.all.accept_redirects 0
check "kernel: kernel pointers hidden"     sysctl_is kernel.kptr_restrict 2

# ---- updates --------------------------------------------------------------------------
if [ "${AUTO_UPDATES:-0}" = 1 ]; then
    check "updates: automatic security updates on" \
        bash -c "apt-config dump | grep -q 'APT::Periodic::Unattended-Upgrade \"1\"'"
fi

# ---- Docker and the web stack -----------------------------------------------------------
if [ "${ENABLE_DOCKER:-0}" = 1 ]; then
    check "docker: running"                systemctl is-active --quiet docker
    check "docker: logs are size-limited"  bash -c "jq -e '.\"log-opts\".\"max-size\"' /etc/docker/daemon.json"
    # Docker publishes ports straight past ufw, so only 80/443 (Caddy) may be open to everyone.
    exposed=$(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | awk -F'|' '
        { n = split($2, p, ", ")
          for (i = 1; i <= n; i++)
            if (match(p[i], /^(0\.0\.0\.0|\[::\]):[0-9]+/)) {
              port = p[i]; sub(/^(0\.0\.0\.0|\[::\]):/, "", port); sub(/->.*/, "", port)
              if (port != "80" && port != "443") print $1 ":" port
            } }')
    if [ -z "$exposed" ]; then pass "docker: no container exposes a port to the world except 80/443"
    else fail "docker: containers publishing ports on all interfaces: $(echo "$exposed" | paste -sd' ' -)"; fi
fi
if [ "${ENABLE_STACK:-0}" = 1 ]; then
    check "stack: Caddy container is running" \
        bash -c "docker compose -f '$STACK_DIR/compose.yml' ps --status running --services | grep -qx caddy"
    if [ "${STACK_DEMO:-0}" = 1 ]; then
        check "stack: https://$STACK_DOMAIN answers 200 through Caddy" \
            bash -c "curl -ksS --max-time 20 --retry 5 --retry-delay 2 --retry-connrefused -o /dev/null -w '%{http_code}' \
                --resolve '$STACK_DOMAIN:443:127.0.0.1' 'https://$STACK_DOMAIN/' | grep -qx 200"
        check "stack: plain HTTP redirects to HTTPS" \
            bash -c "curl -sS --max-time 20 -o /dev/null -w '%{http_code}' --resolve '$STACK_DOMAIN:80:127.0.0.1' 'http://$STACK_DOMAIN/' | grep -qE '^30[1-8]$'"
    fi
fi

# ---- backups and health check -----------------------------------------------------------
if [ "${ENABLE_BACKUPS:-0}" = 1 ]; then
    check "backups: timer is scheduled"    systemctl is-enabled --quiet server-backup.timer
    check "backups: password file is private (mode 600)" bash -c "[ \"\$(stat -c %a /etc/restic/password)\" = 600 ]"
    if [ -r /var/lib/server-backup/last-success ]; then
        check "backups: a backup succeeded in the last 36 hours" \
            bash -c "[ \$(( \$(date +%s) - \$(cat /var/lib/server-backup/last-success) )) -lt 129600 ]"
    else
        fail "backups: no successful backup yet (run: sudo systemctl start server-backup)"
    fi
fi
if [ "${ENABLE_HEALTHCHECK:-0}" = 1 ]; then
    check "health check: timer is scheduled" systemctl is-enabled --quiet server-healthcheck.timer
fi

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; exit 0; fi
echo "$fails check(s) failed"; exit 1
