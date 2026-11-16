# Security decisions

What each hardening step does, why it is there, and what it does **not** protect against.

## Access

| Choice | Why |
|---|---|
| SSH keys only, passwords off | Password guessing is what automated attackers try all day. Keys can't be guessed. |
| `AllowUsers <admin>`, no root login | One account to defend, and it must be named. The same key cannot log in as root (CI checks this). |
| `MaxAuthTries 3`, `LoginGraceTime 30` | Less time and fewer guesses per connection. |
| Forwarding off (X11, agent, TCP) | A stolen session can't be used as a stepping stone. Set `ssh_allow_tcp_forwarding: true` if you use tunnels. |
| Drop-in file named `10-hardening.conf` | OpenSSH uses the *first* value it reads. Ubuntu's cloud images ship `50-cloud-init.conf` with `PasswordAuthentication yes`; ours is read first and wins. |
| Config checked with `sshd -t` before it is installed | A typo can't take SSH down. |
| The playbook and `bootstrap.sh` refuse to run without a key | Turning passwords off without a key locks you out. |
| `admin_sudo_nopasswd: true` | The account has no password, so sudo can't ask for one. The key is the credential. Set `false` and give the account a password if you prefer. |
| Key encryption/algorithms left at OpenSSH defaults | OpenSSH 8.9/9.6 already prefer modern ones and drop weak ones; pinning a list ages badly. |

**Not covered:** a stolen private key. Protect it with a passphrase (`ssh-keygen -t ed25519`) and use an agent. Using a **non-standard SSH port** (`ssh_port`) only reduces log noise; it is not security.

## Network

- `ufw` denies incoming by default; SSH is `limit`ed (6 connections in 30 s from one address are refused).
- **Docker and ufw:** Docker writes its own firewall rules and *bypasses ufw* for published ports. So the rule here is: only Caddy publishes ports (80/443). Everything else joins the `web` network and is reached through Caddy. `scripts/verify.sh` fails if any other container listens on all interfaces; for a service that must be reachable only locally, publish it as `127.0.0.1:PORT:PORT`.
- `fail2ban` bans an address for an hour after 5 failed logins in 10 minutes. Put your own address in `fail2ban_ignore_ips`.
- `sysctl` hardening (`/etc/sysctl.d/90-hardening.conf`): reverse-path filtering (anti-spoofing), no ICMP redirects or source routing, SYN cookies, logging of impossible addresses, kernel pointers and `dmesg` hidden from users. IP forwarding is left alone because Docker needs it.

## Containers

- Caddy runs with a read-only filesystem, no capabilities except binding low ports, and `no-new-privileges`. The demo service has no capabilities at all.
- The Docker daemon sets `no-new-privileges` for every container by default, size-limited logs, and `live-restore` (containers keep running while Docker is restarted for an update).
- **Adding your user to the `docker` group is the same as giving it root** (it can mount the whole disk). That is why `admin_extra_groups` is empty by default; use `sudo docker ...`.
- Image tags are pinned (`caddy:2.8-alpine`, `traefik/whoami:v1.10.2`) so a re-run can't silently change what is running.

## Updates

Security updates install by themselves (`unattended-upgrades`, security pocket only). Some need a reboot (the health check warns "reboot needed"); set `auto_reboot: true` and `auto_reboot_time` if you would rather it do that at 04:00.

## Backups and secrets

- Backups are encrypted by restic. The key is `/etc/restic/password` (mode 600, generated once, never replaced by re-running). **Copy it to a password manager**; without it the backups are unreadable.
- `/etc/restic/env` holds repository credentials, mode 600. Nothing secret is in this Git repository; `local.yml` is git-ignored.
- Anyone who can read the live server can read what is in `/etc`, `/srv` and `/home`: encryption protects the *copies*.

## What this is not

A baseline, not a certification. It does not include intrusion detection (auditd/AIDE), disk encryption (decide at install time), mandatory access control profiles beyond Ubuntu's defaults, or protection for applications you deploy: their own updates and configuration are on you.
