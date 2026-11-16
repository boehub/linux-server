# Backups

Backups use [restic](https://restic.net/): encrypted, deduplicated snapshots. `server-backup` runs daily from a systemd timer (default 03:30, randomly delayed up to 15 minutes), backing up `backup_paths` (default `/etc /srv /home /root`) and then deleting snapshots beyond the retention (7 daily, 4 weekly, 6 monthly). Once a week it also re-reads 5% of the stored data and verifies it.

## Put the backups somewhere else

The default repository (`/var/backups/restic`) is on the same disk as the data. Set `backup_repo` and its credentials in `local.yml`:

```yaml
# another machine over SSH (the server's root user needs a key that logs in there)
backup_repo: "sftp:backup@nas.local:/backups/homeserver"

# Backblaze B2
backup_repo: "b2:my-bucket:homeserver"
backup_env:
  B2_ACCOUNT_ID: "..."
  B2_ACCOUNT_KEY: "..."

# any S3-compatible storage
backup_repo: "s3:s3.amazonaws.com/my-bucket/homeserver"
backup_env:
  AWS_ACCESS_KEY_ID: "..."
  AWS_SECRET_ACCESS_KEY: "..."
```

Then `ansible-playbook site.yml -e @local.yml --tags backups`. The first run creates the repository and makes the first backup straight away, so a wrong password, key or network setting fails now rather than at 03:30.

## Check, restore, repeat

```
sudo systemctl start server-backup       # back up now
sudo server-restore-test                 # restore the newest backup to a temp folder and compare with the live files
sudo server-restore-test /srv/stack      # ... for specific paths
```

To use restic directly with the saved settings:

```
sudo bash -c 'set -a; . /etc/restic/env; restic snapshots'
sudo bash -c 'set -a; . /etc/restic/env; restic restore latest --target /tmp/restore --include /etc/ssh'
```

**A backup you have never restored is a hope, not a backup.** Run `server-restore-test` after changing anything, and once in a while for real: restore a folder somewhere and look at it.

## What is *not* in the backup

Anything outside `backup_paths`, other file systems (`--one-file-system`), and Docker's own volumes under `/var/lib/docker`. Keep your containers' data in `/srv/<app>` (bind mounts) so it is covered, or add the volume path to `backup_paths`. For databases, take a dump into `/srv` first (a cron job or systemd timer) rather than copying files that are changing underneath you.

## The password

`/etc/restic/password` was generated on first run. Save it: `sudo cat /etc/restic/password`. If you lose it, the backups cannot be opened by anyone, including you.
