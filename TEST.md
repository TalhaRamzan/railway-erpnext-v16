# TEST.md: ERPNext v16 template

Three levels: **A** static checks (no Docker needed, done), **B** local
`docker compose` run, **C** real Railway deploy. Run B and C before every
publish and every pin bump. Keep C short (a few hours) and delete the test
project afterwards.

## A. Static checks (done on 2026-11-21, no Docker available)

| Check | Result |
|---|---|
| `bash -n` on `entrypoint.sh`, `backup.sh`, `restore.sh`, `supervisor-watchdog.sh` | pass |
| `shellcheck -x -s bash` (v0.11.0 via shellcheck-py) on all 4 scripts | pass, 0 findings |
| `docker-compose.yml` parses as YAML (PyYAML) | pass |
| `supervisord.conf` loads with supervisor 4.3.0's own parser (`ServerOptions.realize`), all `%(ENV_*)s` expand | pass |
| `nginx.conf.template` rendered with the same variable list as the entrypoint; nothing left unsubstituted, nginx `$vars` intact; parsed with `crossplane` 0.5.8 (directive/context check) | pass (real `nginx -t` runs at container start) |
| Entrypoint helpers unit-tested (Redis URL → host:port incl. password with `@`/`:`, major-version parse) | pass (bash 3.2 on macOS; functions using bash 4+ syntax like `${x,,}`/`mapfile` only run in the container's bash 5.2) |
| `frappe/erpnext:v16.60.0` index digest `sha256:3847bab…2db6` exists (Docker Hub registry API, amd64 + arm64) | pass |
| `mariadb:11.8.9` digest `sha256:e1d5495…41fc`, `redis:8.6.8-alpine` digest `sha256:91c71f9…1137`, `frappe/erpnext:v16.55.0` (for the migrate test) all resolve on registry-1.docker.io | pass |
| Base image config: user `frappe`, entrypoint `/usr/local/bin/entrypoint.sh`, history contains restic, chromium, wkhtmltopdf | pass |
| Process commands match frappe_docker `compose.yaml` / `pwd.yml` / `resources/core/start.sh` (gunicorn args, `bench worker --queue`, `bench schedule`, `node apps/frappe/socketio.js`) | pass |
| Config keys match the upstream `configurator` (`db_host`, `db_port`, `redis_cache`, `redis_queue`, `redis_socketio`, `socketio_port`, `chromium_path`) | pass |
| MariaDB flags match `overrides/compose.mariadb.yaml` (utf8mb4, unicode_ci, skip handshake, snapshot isolation OFF) | pass |
| `bench new-site / backup / restore / migrate` options exist in frappe `version-16` `commands/site.py` | pass |
| supervisor 4.3.0 wheel sha256 matches PyPI | pass |

## B. Local run (`docker compose`)

```bash
cp .env.example .env   # fill DB_ROOT_PASSWORD, REDIS_PASSWORD, ADMIN_PASSWORD
docker compose up --build
```

- [ ] Image builds (supervisor installs; the binary check in the Dockerfile passes).
- [ ] Logs show: MariaDB up → Redis up → "Creating site" → "Site created" → "Setup complete" → supervisord starts 6 programs + watchdog.
- [ ] First boot time: ______ min (expect 3–10).
- [ ] `curl -fsS localhost:8080/api/method/ping` → `{"message":"pong"}`.
- [ ] Open http://localhost:8080, log in as `Administrator` / `ADMIN_PASSWORD`, finish the setup wizard (needs the worker: proves Redis queue works).
- [ ] Realtime works: browser devtools shows a `socket.io` websocket with status 101 and no "Invalid origin"/"Unauthorized" in logs; the setup wizard progress bar moves.
- [ ] Create a Customer and a Sales Invoice; print it to PDF (chromium/wkhtmltopdf path).
- [ ] Upload an attachment (public and private).
- [ ] `docker compose restart erpnext` → logs say "App versions unchanged; skipping migrate"; data still there.
- [ ] `docker compose down && docker compose up` → data still there.
- [ ] `docker stats`: ERPNext memory at idle: ______ MB, MariaDB ______ MB, Redis ______ MB.
- [ ] Inside: `docker compose exec erpnext ps -o user,pid,rss,cmd -e` → everything except supervisord runs as `frappe`.
- [ ] Backup: `docker compose exec erpnext backup.sh --now` then `backup.sh --list` → folder with database.sql.gz, files.tgz, private-files.tgz, site_config_backup.json.
- [ ] Retention: run `backup.sh --now` 4 times with `BACKUP_KEEP=3` → only 3 remain.
- [ ] Daemon: set `BACKUP_TIME` to 2 minutes from now (UTC), restart, see the nightly backup run.
- [ ] Restore: create a record, run `restore.sh <folder> --yes`, record is gone, older data is back, worker/scheduler running again, maintenance mode off.
- [ ] Restore into a **fresh** stack (`docker compose down -v`, up, then restore) → log in with the OLD admin password; open an Email Account / any saved password field → no decryption error (encryption_key carried over).
- [ ] S3: with a test R2/B2/MinIO bucket set `BACKUP_S3_*` + `AWS_*`, `backup.sh --now` → `restic` init + snapshot; `backup.sh --list` shows it; `restore.sh s3:latest --yes` works.
- [ ] Migrate path: build with `ERPNEXT_IMAGE=frappe/erpnext:v16.55.0@sha256:15a1270f7d8d674de5facd16c3390665a12bd632f5abb846bdd67b61d7461d84`, create site, then rebuild with the default pin → logs show pre-migrate backup + `bench migrate`.
- [ ] Major guard: fake it by editing `sites/.railway/erp.local.versions` to `erpnext=15.0.0` → container refuses to start with the "major version" message. Restore the file.
- [ ] SITE_NAME guard: change `SITE_NAME` → container refuses to start; change back → OK.
- [ ] Watchdog: `docker compose stop redis` for ~2 min → worker/socket.io crash-loop until FATAL → logs show `[watchdog] a process went FATAL` → container exits; `docker compose start redis` → container restarts (restart policy) and waits for Redis before starting processes.
- [ ] Non-root reopen check: nginx logs errors to stderr fine (no `open() "/dev/stdout" failed (13: Permission denied)`).
- [ ] Wrong DB password → clear "Access denied" error, not an endless loop.

## C. Railway deploy

Build the template exactly as in `railway-template.md`, deploy it into a **new, separate
test project** (never a project that runs anything else).

- [ ] All three services deploy; ERPNext healthcheck passes within 900 s.
- [ ] Volume ownership: no permission errors in logs (root-owned volume got chowned).
- [ ] App opens on the generated `*.up.railway.app` domain over HTTPS; no mixed-content warnings.
- [ ] Admin login with the generated `ADMIN_PASSWORD` (Variables tab of ERPNext).
- [ ] Setup wizard completes; realtime websocket connects (status 101) through Railway's edge.
- [ ] Create a record → **Redeploy** ERPNext → record still there; logs show "skipping migrate".
- [ ] Restart MariaDB → ERPNext recovers without manual action.
- [ ] `railway ssh` into ERPNext → `backup.sh --now`, `backup.sh --list` work; env vars (`DB_ROOT_PASSWORD`) visible in the ssh shell (needed by `restore.sh`).
- [ ] `restore.sh <folder> --yes` works from the ssh shell.
- [ ] Optional: Railway Bucket or R2 as `BACKUP_S3_REPOSITORY` → upload works.
- [ ] Client IP: ERPNext → Activity Log / login history shows your real IP, not a Railway proxy IP
      (validates `UPSTREAM_REAL_IP_ADDRESS=0.0.0.0/0` + `X-Forwarded-For`).
- [ ] Custom domain (optional): add one, set `FRAPPE_HOST_NAME`, redeploy → site works on both domains.
- [ ] Memory graph after 1–2 h idle: ERPNext ______ MB, MariaDB ______ MB, Redis ______ MB → update README cost table.
- [ ] Usage page: estimated monthly cost ______ → update README.
- [ ] Delete the whole test project.

## Known untested assumptions (verify in B/C)

- Railway mounts volumes root-owned; the entrypoint chowns `sites/` to `frappe` (uid 1000, gid 0).
- Railway's Redis `REDIS_URL` is `redis://default:<password>@redis.railway.internal:6379`; Frappe (redis-py, node-redis) accepts the password in the URL.
- Hostnames only for DB/Redis: a raw IPv6 literal (`[fd12::1]`) in `REDIS_URL` is not supported by the wait step.
- socket.io auth loops back to `http://127.0.0.1:8000` (nginx rewrites Origin/Host for `/socket.io`); confirm no "Invalid origin" behind Railway's edge.
- restic against Railway Buckets (S3-compatible) was not tried; R2/B2/AWS are standard restic targets.
- First boot fits in the 900 s healthcheck window on Railway's shared CPUs.

## Local run results (2026-11-21, OrbStack)
- PASS: `docker compose up --build`: image builds, MariaDB healthy, site created on first boot, container healthy.
- PASS: all supervisord programs RUNNING (web, socketio, worker, scheduler, nginx, backup, watchdog).
- PASS: `/` → 200; Administrator login via API; ERPNext + Frappe 16.60.x installed; created a Customer via REST.
- PASS: socket.io polling endpoint → 200.
- PASS: nightly backup loop wrote a backup folder to `sites/.backups`; `backup.sh --now` / `--list` work.
- PASS: `docker compose restart` → healthy again, Customer still present.
- Measured RAM idle: ERPNext container ~525 MB, MariaDB ~285 MB, Redis ~15 MB → **~0.83 GB**, roughly $8–10/month RAM on Railway.
- Not tested: `restore.sh`, S3/restic off-site copy, browser realtime in desk UI, PDF print, image-version migrate path.

## Local backup/restore results (2026-11-21, OrbStack, SeaweedFS as S3 stand-in)
- PASS: `backup.sh --now` → local folder + restic init + encrypted snapshot in S3; `--list` shows both.
- PASS: `restore.sh <folder> --yes` → record created after the backup is gone, older record back; all supervisord programs RUNNING; maintenance mode off.
- PASS: disaster recovery: `docker compose down -v` (DB + site volume wiped), fresh boot, `restore.sh s3:latest --yes` → old record back, admin login works, no decryption errors in logs.
- PASS: retention with BACKUP_KEEP=3: after 4 more manual backups only the newest 3 manual folders remain (plus the separate pre-restore safety backup, which is kept outside the count).

## Railway deploy results (2026-11-21, Hobby plan, project created 19:19 UTC, deleted 19:35 UTC)
- PASS: both services build from this GitHub repo (MariaDB with Root Directory `/mariadb`, ERPNext with `/`); volumes at `/var/lib/mysql` and `/home/frappe/frappe-bench/sites` attach fine (root-owned volume handled by the entrypoint).
- PASS: references `${{MariaDB.RAILWAY_PRIVATE_DOMAIN}}`, `${{MariaDB.MARIADB_ROOT_PASSWORD}}`, `${{Redis.REDIS_URL}}` (Railway Redis URL format parsed correctly), `${{secret(...)}}`.
- PASS: first boot "Creating site 'erp.local'… Setup complete." within the 900 s healthcheck window (build + site ≈ 10 min); all supervisord programs RUNNING; worker processing jobs.
- PASS (public domain): `/api/method/ping` → pong, `/login` 200, socket.io polling 200, public sign-up rejected ("Sign Up is disabled").
- Measured RAM on Railway (idle, fresh site): ERPNext ~690 MB, MariaDB ~290 MB, Redis ~19 MB → ~1.0 GB ≈ $10/month RAM.
- Note: supervisord lines appear twice in Railway logs (log noise only).
- Not re-tested on Railway (passed locally): Administrator login, restore, S3 backup copy.
