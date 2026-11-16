# Runbook

Everyday tasks. `local.yml` holds your settings; after changing it re-run `sudo ./bootstrap.sh <same flags>` (on the server) or `ansible-playbook site.yml -e @local.yml` (from your computer). Re-running is safe.

## Is it healthy?

```
sudo scripts/verify.sh                   # checks the live system against the setup
sudo server-healthcheck                  # disk, memory, services, reboot needed, containers, backup age, clock
jq . /var/lib/server-health/status.json  # the last scheduled check
journalctl -t server-healthcheck -n 20   # problems it logged
systemctl list-timers 'server-*'         # when the next backup and check run
```

## Get phone alerts

Pick an [ntfy.sh](https://ntfy.sh) topic name that is hard to guess and set `healthcheck_notify_url: "https://ntfy.sh/your-secret-topic"`. Any URL that accepts a POST body works. Install the ntfy app and subscribe to the topic. Test it by setting `healthcheck_disk_max_percent: 1` for a moment.

## Add a website or app

1. Point a DNS record for `app.example.com` at the server and make sure ports 80 and 443 reach it (router forwarding at home).
2. Run the app as a container on the `web` network, **without publishing a port**. For example in `/srv/app/compose.yml`:
   ```yaml
   services:
     app:
       image: ghcr.io/example/app:1.2.3
       restart: unless-stopped
       networks: [web]
       volumes: ["./data:/data"]       # under /srv, so it is backed up
   networks:
     web:
       external: true
   ```
   then `cd /srv/app && sudo docker compose up -d`.
3. Add it to `local.yml` and re-run the playbook:
   ```yaml
   stack_sites:
     - {host: app.example.com, upstream: "app:8080"}
   ```
   Caddy gets the certificate by itself (set `stack_acme_email` so you are contacted before one expires).

## Change who can log in

Edit `admin_ssh_keys` in `local.yml` and re-run. With `admin_keys_exclusive: true` (the default) keys not in the list are removed, which is how you revoke one. **Test the new login in a second terminal before closing the first.**

## Updates

Security updates are automatic. For everything else: `sudo apt update && sudo apt upgrade`, then reboot if `/var/run/reboot-required` exists. Container images are pinned: change the tag in `roles/stack/templates/compose.yml.j2` (or in your own compose file), re-run, and `docker compose up -d` applies it.

## Something went wrong

| Symptom | Look at |
|---|---|
| Locked out of SSH | Use the console (monitor/keyboard, or your host's web console). `sudo journalctl -u ssh -n 50`; fix `admin_ssh_keys`; re-run. |
| Banned by fail2ban | `sudo fail2ban-client set sshd unbanip <your address>`; add it to `fail2ban_ignore_ips`. |
| Site shows a certificate error | `sudo docker compose -f /srv/stack/compose.yml logs caddy`. Usual causes: DNS not pointing here yet, port 80/443 not reachable. With the default `stack_domain: localhost` the certificate is a local test one by design. |
| Backups failing | `journalctl -u server-backup -n 50`. Run `sudo systemctl start server-backup` and watch. The health check reports "last success Nh ago". |
| Disk full | `sudo ncdu /` ; `sudo docker system df` ; `sudo docker image prune -a` removes unused images. |
| A change broke SSH config | Not possible through this playbook (`sshd -t` runs first); if edited by hand, `sudo sshd -t` shows the error. |

## Rebuild from scratch

1. Install Ubuntu Server on the new machine and run `bootstrap.sh` with the same `local.yml`.
2. Put the old `/etc/restic/password` back **before** the first backup, i.e. before running bootstrap, or copy it afterwards and `rm -rf` the freshly created empty repository: `sudo install -m600 saved-password /etc/restic/password`.
3. `sudo bash -c 'set -a; . /etc/restic/env; restic restore latest --target /'` restores `/srv` and friends; then `sudo docker compose -f /srv/stack/compose.yml up -d`.
