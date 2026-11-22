# Railway template checklist: ERPNext v16

Step-by-step for building the template in the Railway dashboard
(**Workspace → Templates → New Template**, or build it in a scratch project and
use **Project Settings → Generate Template**). Service names matter: the
variable references below assume exactly `ERPNext`, `MariaDB` and `Redis`.

Pinned versions (verified 2026-11-21):

| Component | Pin | Where |
|---|---|---|
| ERPNext / Frappe | `frappe/erpnext:v16.60.0@sha256:3847babae025dae001e638b7fc5503c944fd968216b3074e60edfcc240fb2db6` (ERPNext 16.60.0, Frappe 16.60.x) | `Dockerfile` (`ERPNEXT_IMAGE`) |
| MariaDB | `mariadb:11.8.9@sha256:e1d5495f445654134f226f55a41ce0da227116f6f27f283101f405c794d841fc` | `mariadb/Dockerfile` |
| Redis | Railway's Redis database service (optionally set image to `redis:8.6.8`) | Railway dashboard |
| supervisor | 4.3.0 (sha256-pinned wheel) | `Dockerfile` |

> **Published template:** https://railway.com/deploy/erpnext-v16-1 (published 2026-11-22).
>
> **How the published version was built** (Railway's template generator keeps only variables containing `${{...}}`,
> drops plain values and service healthcheck timeouts, and needs a GitHub-app link to generate repo services):
> the template was generated from a project with placeholder images, then each repo service's source was switched
> to this GitHub repo in the template composer. Only secrets and references are template variables; every other
> setting has a default in the image (Dockerfile `ENV` / entrypoint `${VAR:-default}`). Railway injects `PORT=8080`;
> the public domain targets 8080. Healthcheck (900 s) and restart policy come from `railway.json` / `mariadb/railway.json`. Redis is a `redis:8.6.8` image service with a `/data` volume (start command chowns the volume first).
> Verified by deploying the template itself into an empty project with zero inputs.

---

## 0. Before you start

- [ ] Repo pushed to GitHub (public, so template users can deploy it), default branch `main`.
- [ ] Note the commit / tag you are publishing (e.g. tag `v16.60.0-1`). Railway templates deploy
      the branch head, so only merge tested pin bumps to `main`.

## 1. Service `MariaDB`

- [ ] **+ New → GitHub Repo** → this repo. Rename the service to **`MariaDB`**.
- [ ] Settings → **Root Directory**: `/mariadb` (builder: Dockerfile, auto-detected).
- [ ] Settings → **Watch Paths**: `/mariadb/**` (so app-only commits don't rebuild/restart the DB).
- [ ] Right-click → **Attach Volume** → mount path **`/var/lib/mysql`**.
- [ ] Variables:

  | Name | Value |
  |---|---|
  | `MARIADB_ROOT_PASSWORD` | `${{secret(32, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")}}` |

- [ ] Networking: **no** public domain, **no** TCP proxy. Private network only.
- [ ] Healthcheck: none (not an HTTP service).
- [ ] Restart policy: **Always**.
- [ ] (Optional) Resource limit: 1 GB memory. Idle use is ~250–400 MB (`innodb-buffer-pool-size = 256M`).

Why a Dockerfile instead of the plain `mariadb` image: Frappe needs
`utf8mb4` / `utf8mb4_unicode_ci` and `innodb-snapshot-isolation=OFF`; baking
them into `mariadb/frappe.cnf` avoids relying on a custom start command.

## 2. Service `Redis`

- [ ] **+ New → Database → Redis** (Railway's own Redis service). Keep the name **`Redis`**.
- [ ] (Optional, recommended) Settings → Source image: pin a tag, e.g. `redis:8.6.8`
      (frappe_docker uses Redis 8.6). Keep Railway's start command and volume as they are.
- [ ] Networking: **remove the public TCP proxy** if Railway added one. Private only.
- [ ] One Redis instance serves both cache and queue (lean). For heavy use, add a second
      Redis and set `REDIS_CACHE_URL` / `REDIS_QUEUE_URL` separately on ERPNext.

## 3. Service `ERPNext`

- [ ] **+ New → GitHub Repo** → this repo. Rename to **`ERPNext`**.
- [ ] Settings → **Root Directory**: `/` (builder: Dockerfile at repo root).
- [ ] Settings → (optional) **Watch Paths**: `/**` and `!/mariadb/**`.
- [ ] Right-click → **Attach Volume** → mount path **`/home/frappe/frappe-bench/sites`**.
      This one volume holds site config, uploaded files and the local backups.
- [ ] Settings → **Healthcheck Path**: `/api/method/ping`
- [ ] Settings → **Healthcheck Timeout**: `900` seconds (first boot creates the site: 3–10 min).
      Also set as variable below, in case the composer drops the setting.
- [ ] Settings → **Restart Policy**: **Always** (the supervisor watchdog exits the container
      when a process keeps crashing; Railway must restart it).
- [ ] Settings → **Serverless / App Sleeping**: **off** (scheduler and nightly backups must run).
- [ ] Settings → **Public Networking → Generate Domain**, target port **8080**.
- [ ] Do **not** set a custom Start Command and do **not** set `RAILWAY_RUN_UID`
      (the entrypoint starts as root, fixes volume ownership, then drops to `frappe`).
- [ ] (Optional) Resource limit: 2 GB memory. Idle use ~0.7–1.0 GB; first boot peaks higher.
- [ ] Variables:

  | Name | Value | Notes |
  |---|---|---|
  | `PORT` | `8080` | nginx listens here |
  | `SITE_NAME` | `erp.local` | internal name, **never change after first boot**; not the URL |
  | `ADMIN_PASSWORD` | `${{secret(24, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")}}` | Administrator password, used on first boot only |
  | `DB_HOST` | `${{MariaDB.RAILWAY_PRIVATE_DOMAIN}}` | |
  | `DB_PORT` | `3306` | |
  | `DB_ROOT_PASSWORD` | `${{MariaDB.MARIADB_ROOT_PASSWORD}}` | |
  | `REDIS_URL` | `${{Redis.REDIS_URL}}` | cache + queue + socket.io |
  | `FRAPPE_HOST_NAME` | `https://${{RAILWAY_PUBLIC_DOMAIN}}` | links in emails/PDFs; change when adding a custom domain |
  | `GUNICORN_WORKERS` | `1` | ~150–250 MB each |
  | `GUNICORN_THREADS` | `4` | |
  | `BACKUP_ENABLED` | `true` | |
  | `BACKUP_TIME` | `02:00` | UTC |
  | `BACKUP_KEEP` | `3` | local copies on the volume |
  | `BACKUP_WITH_FILES` | `true` | |
  | `BACKUP_S3_REPOSITORY` | *(empty, optional)* | e.g. `s3:https://<acct>.r2.cloudflarestorage.com/<bucket>/erpnext` |
  | `BACKUP_S3_PASSWORD` | `${{secret(32, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")}}` | restic encryption password; users must save a copy |
  | `BACKUP_S3_KEEP` | `14` | |
  | `AWS_ACCESS_KEY_ID` | *(empty, optional)* | bucket key |
  | `AWS_SECRET_ACCESS_KEY` | *(empty, optional)* | bucket secret |
  | `AWS_DEFAULT_REGION` | `auto` | `auto` for R2; real region for AWS |
  | `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` | `900` | first boot |

  In the template composer, give each optional variable a short description and leave
  it **not required**. `ADMIN_PASSWORD` and the `secret()` values should be generated,
  not asked for.

## 4. Template metadata

- [ ] Name: **ERPNext v16 | Open-Source Odoo/SAP Alternative with Backups**
      (another creator already uses "ERPNext 16 | Open-Source ERP with Nightly Backups"; keep ours distinct).
- [ ] Short description: *ERPNext v16 on the official pinned image in one lean container, MariaDB 11.8,
      Redis, auto site setup, nightly backups with optional encrypted S3 copy and a one-command restore.*
- [ ] Category: Other / Business; tags: `erp`, `erpnext`, `frappe`, `accounting`, `inventory`, `odoo-alternative`, `backups`.
- [ ] Icon: generic (no Frappe/ERPNext logo).
- [ ] Overview: paste the top of `README.md` (what it is, cost, backups, "unofficial" note).
- [ ] After each monthly pin bump: append `[Updated <Month YYYY>]` to the description.
- [ ] Template Queue: email notifications **on**.

## 5. Smoke test before publishing

Run `TEST.md` section B in a fresh Railway project, then delete that project.
