# ERPNext v16 on Railway (lean, with nightly backups)

> **Unofficial community template.** Not affiliated with or endorsed by Frappe
> Technologies or Railway. It runs the **official `frappe/erpnext` Docker
> image**, unmodified apart from adding a process supervisor.

ERPNext is a free, open-source ERP (accounting, inventory, sales, purchasing,
manufacturing, projects, HR add-ons) and a common alternative to Odoo or
SAP Business One. This template gives you a working ERPNext v16 site on
Railway in about 10 minutes, with backups switched on from day one.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/erpnext-v16-1)

## What you get

```
             HTTPS (Railway edge)
                     │
┌────────────────────▼─────────────────────────────┐   ┌────────────┐
│ ERPNext  (one container, supervisord)            │──▶│  MariaDB   │ volume /var/lib/mysql
│  nginx :$PORT → gunicorn :8000 (127.0.0.1)       │   │  11.8.9    │
│               → socket.io :9000 (127.0.0.1)      │   └────────────┘
│  worker (long,default,short) · scheduler         │   ┌────────────┐
│  nightly backup loop                             │──▶│  Redis     │ cache + queue
│ volume: /home/frappe/frappe-bench/sites          │   └────────────┘
└──────────────────────────────────────────────────┘
```

| Service | Source | Volume | Public |
|---|---|---|---|
| ERPNext | this repo `Dockerfile` (FROM `frappe/erpnext:v16.60.0@sha256:3847…2db6`) | `/home/frappe/frappe-bench/sites` | yes (HTTPS) |
| MariaDB | this repo `mariadb/Dockerfile` (FROM `mariadb:11.8.9@sha256:e1d5…41fc`) | `/var/lib/mysql` | no |
| Redis | Railway Redis | Railway default | no |

**Why one container?** A Railway volume can be attached to only one service,
but Frappe's web server, socket.io server, background worker and scheduler all
need the same `sites/` folder. So they all run in one container under
supervisord, sharing one volume. MariaDB and Redis stay separate services.

Highlights:

- **Pinned versions** (tag + digest). Nothing floats on `:latest`.
- **Automatic first boot:** waits for MariaDB/Redis, writes the Frappe config,
  creates the site with ERPNext installed, random Administrator password.
- **Safe upgrades within v16:** when the pinned image changes, the container
  takes a database backup and runs `bench migrate` before starting.
- **Nightly backups** (database + files) to the volume, last 3 kept, plus an
  optional **encrypted off-site copy** to any S3-compatible bucket
  (Cloudflare R2, Backblaze B2, AWS S3, Railway Buckets) via restic.
- **One-command restore** (`restore.sh`), including the site's encryption key.
- **Lean defaults:** 1 gunicorn worker × 4 threads, 1 combined queue worker,
  one Redis for cache + queue.
- Public sign-up off, MariaDB and Redis private-only.

## Deploy

1. Click **Deploy on Railway**. No input is required; passwords are generated.
2. Wait for the first deploy. **The first boot takes 3–10 minutes** (the site is
   created and ERPNext installed). The healthcheck allows up to 15 minutes.
3. Open the ERPNext service's public domain.
4. Log in as **`Administrator`** with the password in the ERPNext service →
   **Variables → `ADMIN_PASSWORD`**. Complete the setup wizard.
5. Change the Administrator password in ERPNext (the variable is only used on
   the first boot; changing it later does nothing).

### Custom domain

Add the domain in ERPNext service → Settings → Networking, then set
`FRAPPE_HOST_NAME=https://your.domain` so emails and PDFs link to it.
The internal `SITE_NAME` stays as it is: the site answers on every domain.

## Monthly cost (estimate)

Railway bills usage: RAM $10/GB-month, CPU $20/vCPU-month, volumes
$0.15/GB-month, egress $0.05/GB (Railway pricing page, Nov 2026). The Hobby
plan is $5/month and includes $5 of usage.

| Service | Typical RAM | Est. cost/month |
|---|---|---|
| ERPNext (web + worker + scheduler + socket.io + nginx) | 0.7–1.0 GB | $7–12 incl. light CPU |
| MariaDB | 0.25–0.4 GB | $3–5 |
| Redis | 20–60 MB | <$1 |
| Volumes (DB + sites + local backups) | 2–5 GB | <$1 |
| **Total, small team (1–10 users)** | | **≈ $12–20** |
| Busy use (more workers, imports, reports) | 1.5–2.5 GB | $20–35 |

These are estimates, not measurements on your data. Check the Railway
**Usage** page after a few days. To keep the bill down: keep
`GUNICORN_WORKERS=1`, keep one Redis, and set a memory limit per service
(Settings → Resource limits: ~2 GB ERPNext, 1 GB MariaDB). Don't go below
~1.5 GB for ERPNext during the first boot.

## Configuration

All on the ERPNext service unless noted. Defaults are in `.env.example`.

| Variable | Default | Meaning |
|---|---|---|
| `ADMIN_PASSWORD` | generated | Administrator password, **first boot only** |
| `SITE_NAME` | `erp.local` | Internal site name. **Never change it after the first boot** (the container refuses to start if you do). |
| `FRAPPE_HOST_NAME` | `https://$RAILWAY_PUBLIC_DOMAIN` | Base URL for links in emails/PDFs |
| `DB_HOST` / `DB_PORT` / `DB_ROOT_PASSWORD` | MariaDB references | Database connection (root is needed to create/restore the site DB) |
| `REDIS_URL` | `${{Redis.REDIS_URL}}` | Used for cache, queue and socket.io. Override with `REDIS_CACHE_URL` / `REDIS_QUEUE_URL` to split. |
| `GUNICORN_WORKERS` / `GUNICORN_THREADS` | `1` / `4` | Web capacity. Each extra worker ≈ +150–250 MB. |
| `GUNICORN_TIMEOUT` | `120` | Seconds before a slow request is killed |
| `WORKER_QUEUES` | `long,default,short` | Queues served by the single background worker |
| `AUTO_MIGRATE` | `true` | Run backup + `bench migrate` when the image version changes |
| `CLIENT_MAX_BODY_SIZE` | `50m` | Max upload size |
| `BACKUP_*`, `AWS_*` | see below | Backups |

## Backups

### What happens every night

At `BACKUP_TIME` (UTC, default `02:00`) the container runs `bench backup
--with-files --compress` into `sites/.backups/<timestamp>-nightly/` on the
volume:

```
20261121T020000Z-nightly/
  …-database.sql.gz           database
  …-files.tgz                 public files
  …-private-files.tgz         private files
  …-site_config_backup.json   site config incl. encryption_key
```

The newest `BACKUP_KEEP` (default 3) are kept. If free space on the volume
drops below `BACKUP_MIN_FREE_MB` (default 1024), older backups are pruned
first and the backup is skipped if space is still short (it never fills the
volume and takes the site down). Before every migrate and restore, an extra
database-only safety backup is taken (last 2 kept).

**Local backups live on the same volume as the site.** They protect against
mistakes (bad import, deleted records, failed upgrade), not against losing
the volume or the Railway project. For that, turn on the off-site copy.

### Off-site copy to S3 (recommended)

Set on the ERPNext service, then redeploy:

| Variable | Example |
|---|---|
| `BACKUP_S3_REPOSITORY` | `s3:https://<account-id>.r2.cloudflarestorage.com/<bucket>/erpnext` (R2) · `s3:https://s3.us-east-1.amazonaws.com/<bucket>/erpnext` (AWS) · `s3:https://s3.<region>.backblazeb2.com/<bucket>/erpnext` (B2) |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | bucket API key |
| `AWS_DEFAULT_REGION` | `auto` (R2) or the bucket region |
| `BACKUP_S3_PASSWORD` | generated by the template; restic encrypts the backups with it |
| `BACKUP_S3_KEEP` | `14` snapshots |

Each nightly folder is uploaded with [restic](https://restic.net) (already in
the official image): encrypted, deduplicated, old snapshots pruned.

> **Copy `BACKUP_S3_PASSWORD` into your password manager now.** If the Railway
> project is deleted, the bucket is useless without it.

### Manual backup / list

Open a shell in the ERPNext service (`railway ssh`, or the service's shell in
the dashboard):

```bash
backup.sh --now              # full backup now
backup.sh --now --db-only    # database only
backup.sh --list             # local folders (+ S3 snapshots)
```

To download a backup to your computer, use Railway's volume tools, or set up
the S3 copy and download from the bucket (`restic restore`).

Railway's own volume backups (service → Backups) can be enabled in addition;
they snapshot the whole volume.

## Restore

Restoring **replaces the current database** (and files, if the backup has
them). `restore.sh` first takes a safety backup, puts the site in
maintenance mode and stops the worker and scheduler.

```bash
railway ssh                                    # into the ERPNext service
backup.sh --list                               # pick a folder
restore.sh 20261121T020000Z-nightly            # asks you to type the site name
restore.sh s3:latest --yes                     # newest off-site snapshot
restore.sh s3:<snapshot-id> --yes              # a specific snapshot
```

Afterwards, log in with the Administrator password **from the backup**.

### Restoring a backup from another server

Works for any ERPNext **v16** backup (`bench backup --with-files` output,
e.g. from Frappe Cloud or another template):

1. Copy the files into the container, e.g. into `/home/frappe/frappe-bench/sites/.backups/import/`
   (upload to your S3 bucket and `restic`/`curl` them in, or use `railway ssh` with a
   download URL you control).
2. `restore.sh /home/frappe/frappe-bench/sites/.backups/import --yes`
3. If the backup came from an **older v16 patch**, the migrate step brings it up to date.
   A backup from a **newer** version is refused; add `--allow-downgrade` only if you
   know what you are doing.
4. Include the `site_config_backup.json` (or at least its `encryption_key`).
   Without it, saved passwords (email accounts, integrations) cannot be decrypted
   and must be re-entered.

v15 backups: restore them on a v15 install first and upgrade there, or migrate
manually. Cross-major restores are not supported here.

## Upgrades

- **Within v16 (patch/minor):** the template's `Dockerfile` pins an exact
  `frappe/erpnext` tag + digest. When the pin is bumped (monthly, marked
  "[Updated <month>]"), redeploy: the container backs up the database, runs
  `bench migrate`, then starts. To bump yourself, fork the repo and change
  `ERPNEXT_IMAGE` in the `Dockerfile` (tag **and** digest from Docker Hub), or
  set a service variable `ERPNEXT_IMAGE=frappe/erpnext:v16.x.y@sha256:…`
  (Railway passes it as a build argument).
- **Major versions (v16 → v17): not supported.** The container refuses to
  start if the site data is from a different major version than the image.
  Major upgrades need Frappe's documented upgrade path (and often app/custom
  code changes); do them on a copy, from a backup, outside this template.
- **MariaDB:** pinned to 11.8.9 (the version frappe_docker ships for v16).
  Patch bumps (11.8.x) are fine; don't jump to another minor/major.

## Email

Railway blocks outbound SMTP on Free, Trial and Hobby plans (Pro and above
can send). ERPNext sends mail **only via SMTP**, so on those plans outgoing
email (password resets, invoices by email) will not work. Options: upgrade the
workspace to Pro and configure an Email Account (Settings → Email Account)
with any SMTP provider, or run ERPNext without email. Don't rely on email for
password recovery: keep the Administrator password safe.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Deploy fails at "healthcheck" on first boot | Check logs. If the site was still being created, raise `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` and redeploy; an interrupted first boot is retried automatically. |
| `MariaDB rejected the root credentials` | `DB_ROOT_PASSWORD` must equal MariaDB's `MARIADB_ROOT_PASSWORD`. MariaDB keeps the password it was **first** started with; changing the variable later does not change it. |
| `This volume already holds site …` | `SITE_NAME` was changed. Set it back. |
| `Major version upgrades are not supported` | You pointed the image at another major version. Pin back to v16. |
| Realtime (live updates/progress bars) not working | Look for `socket.io` errors in logs; make sure nothing in front of Railway strips WebSocket upgrades. |
| Site slow / out of memory | Raise the memory limit or `GUNICORN_WORKERS`; check heavy reports/imports. |
| Need a bench shell | `railway ssh` then `cd /home/frappe/frappe-bench && su frappe -s /bin/bash` (or run `bench` via `setpriv --reuid=frappe --regid=0 --init-groups bench …`). |

## Limitations

- Only the `frappe` and `erpnext` apps (from the official image). Extra apps
  (HRMS, etc.) need a custom image built with frappe_docker; not covered here.
- Single container: no horizontal scaling of web or workers.
- Major version upgrades are not supported (see above).
- Not tested with Railway replicas; keep replicas at 1 (the volume allows only one anyway).

## Local testing

```bash
cp .env.example .env    # fill in the three passwords
docker compose up --build
# http://localhost:8080  (first boot 3–10 min)
```

`docker-compose.yml` mirrors the Railway services one-to-one.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | `FROM` pinned `frappe/erpnext`, adds supervisord + scripts |
| `entrypoint.sh` | volume ownership, wait for DB/Redis, config, first-boot site, migrate, start supervisord |
| `supervisord.conf` | gunicorn, socket.io, worker, scheduler, nginx, backup loop, watchdog |
| `nginx.conf.template` | adapted from frappe_docker's nginx template |
| `backup.sh` / `restore.sh` | backups and restore |
| `supervisor-watchdog.sh` | exits the container if a process is stuck in FATAL |
| `mariadb/` | MariaDB 11.8 with the settings Frappe needs |
| `docker-compose.yml` | local copy of the Railway setup |
| `railway-template.md` | how the Railway template is configured |
| `TEST.md` | test checklist |

## Credits and license

- [ERPNext](https://github.com/frappe/erpnext) (GPL-3.0) and
  [Frappe Framework](https://github.com/frappe/frappe) (MIT) by Frappe Technologies.
- [frappe_docker](https://github.com/frappe/frappe_docker) (MIT): the official image,
  process layout and nginx template this repo is based on.
- MariaDB (GPL-2.0), Redis, supervisor, restic: see their projects.

The files in this repository are MIT licensed (see `LICENSE`). That license
covers only these files, not ERPNext, Frappe or any other software they run.
