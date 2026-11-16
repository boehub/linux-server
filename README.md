# linux-server

A repeatable, tested setup for a self-hosted **Ubuntu Server** (22.04 or 24.04 LTS): one command turns a fresh install into a hardened machine that runs Docker containers behind automatic HTTPS, backs itself up, and tells you when something is wrong.

```
git clone https://github.com/boehub/linux-server && cd linux-server
sudo ./bootstrap.sh --admin-user alex --ssh-key-file ~/alex.pub --domain home.example.com
```

It is an [Ansible](https://docs.ansible.com/) playbook (so running it twice is safe and a second run changes nothing) with a bootstrap script in front, so the machine only needs Ubuntu and internet access to start from.

## What you get

| Area | What it does |
|---|---|
| **Access** | A named admin user with your SSH key and sudo. SSH allows that user only, keys only: no root login, no passwords, 3 tries, 30 s to log in. The playbook refuses to run without a key, so it cannot lock you out. |
| **Firewall** | `ufw`: deny everything incoming except SSH (rate limited) and, with the web stack, ports 80 and 443. |
| **Intrusion protection** | `fail2ban` bans addresses that keep failing SSH logins. Kernel settings (`sysctl`) against spoofing, redirects and information leaks. |
| **Updates** | Security updates install automatically; reboots stay manual unless you turn on `auto_reboot`. |
| **Docker** | Engine and Compose from Docker's own repository; container logs are size-limited so they cannot fill the disk. |
| **Web stack** | [Caddy](https://caddyserver.com/) in a container: real HTTPS certificates that renew themselves, HTTP-to-HTTPS redirect, security headers, and a demo service. Add your own sites with one line each. |
| **Backups** | `restic`: encrypted, deduplicated, daily, with retention (7 daily / 4 weekly / 6 monthly), a weekly integrity check, and a command that restores the latest backup and compares it with the live files. |
| **Health check** | Every 5 minutes: disk, memory, failed services, pending reboot, unhealthy containers, backup age, clock sync. Problems go to the system log and optionally to your phone (ntfy or any webhook). |
| **Verification** | `scripts/verify.sh` checks the *running* system against all of the above and prints PASS/FAIL. |

## Use it

**On the server itself** (fresh Ubuntu Server install, logged in at the console or over SSH):

```
sudo ./bootstrap.sh --admin-user alex --ssh-key-file ~/alex.pub \
     --hostname homeserver --timezone America/New_York \
     --domain home.example.com --email alex@example.com
```

Then, **before closing that session**, open a second terminal and log in as the new user. `./bootstrap.sh --help` lists everything; `--check` shows what would change without changing it; every setting is in [`group_vars/all.yml`](group_vars/all.yml).

**From your own computer** (managing a remote server): copy `inventory/hosts.example.yml` to `inventory/hosts.yml`, copy `local.yml.example` to `local.yml`, then `ansible-playbook site.yml -e @local.yml`. Run one part with a tag: `--tags ssh`, `--tags backups`, ...

Day-to-day tasks (add a site, restore a file, rotate a key, update) are in [docs/runbook.md](docs/runbook.md).

## How it is organized

```
bootstrap.sh          install Ansible, write local.yml, run the playbook, verify
site.yml              the playbook: checks, then the roles in order
group_vars/all.yml    every setting, with comments
roles/
  base/               packages, time zone, journal, automatic updates
  users/              admin user, keys, sudo
  ssh/                hardened sshd settings (checked with sshd -t before use)
  firewall/           ufw
  fail2ban/           ssh jail
  sysctl/             kernel/network hardening
  docker/             Docker Engine + Compose, daemon settings
  stack/              Caddy + demo app (Compose project in /srv/stack)
  backups/            restic, timer, restore test
  healthcheck/        checks, timer, status.json
scripts/verify.sh     audit of the live system
tests/                unit tests + template rendering
docs/                 security decisions, backups, runbook
```

## How it is tested

Everything runs in GitHub Actions on every push ([`ci.yml`](.github/workflows/ci.yml)):

1. **Lint**: `yamllint`, `ansible-lint`, `shellcheck`.
2. **Unit tests** (`tests/run.sh`, 47 checks): `bootstrap.sh` rejects bad input (no key, root as admin, a private key pasted by mistake, a hostile key comment); every template renders and is checked (sshd settings with `sshd -t`, Caddy and Compose files with the real Caddy and Docker); the health check reports a full disk, low memory and stale backups correctly; the backup scripts create, back up, trim and restore with real `restic`, notice a changed or missing file, and **refuse to start a second repository when the password is wrong** (a bug these tests caught).
3. **End to end**, on a clean Ubuntu 22.04 and 24.04 machine each: run `bootstrap.sh`; run the playbook again and require **zero changes**; run `verify.sh`; then really **SSH in** as the admin (works), as root with the same key (refused), and with a password (refused); fetch the demo page over HTTPS through Caddy; restore a backup and compare it.

Locally: `tests/run.sh` (no root needed, changes nothing).

## Limits, stated plainly

- Single server, no clustering or high availability. It is a home or small-project server, not a data centre.
- The default backup repository is on the same disk: it protects against mistakes, not against losing the disk. Point `backup_repo` at another machine or object storage ([docs/backups.md](docs/backups.md)); the health check will tell you if backups stop.
- Only Ubuntu 22.04/24.04 LTS, on amd64 or arm64 (a Raspberry Pi 4/5 with 64-bit Ubuntu Server works).
- Hardening is a sensible baseline, not a compliance certification. [docs/security.md](docs/security.md) explains each choice and what it does not cover.

## License

MIT
