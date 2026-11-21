#!/usr/bin/env bash
# restore.sh: restore an ERPNext backup into the running container.
#
#   restore.sh <backup> [--yes] [--allow-downgrade] [--skip-safety-backup]
#
# <backup> is one of:
#   20261121T020000Z-nightly   a folder name from `backup.sh --list`
#   /path/to/folder            any folder holding bench backup files
#   s3:latest                  newest snapshot in BACKUP_S3_REPOSITORY
#   s3:<snapshot-id>           a specific restic snapshot
#
# What it does: takes a safety DB backup, turns on maintenance mode, stops
# the worker + scheduler, copies the backup's encryption_key into
# site_config.json, runs `bench restore` (database + public + private files),
# runs `bench migrate`, then brings everything back.
# Run it from a shell inside the container (e.g. `railway ssh`).

set -Eeuo pipefail

if [ "$(id -u)" = "0" ]; then
	exec env HOME=/home/frappe USER=frappe LOGNAME=frappe \
		setpriv --reuid=frappe --regid=0 --init-groups -- "$0" "$@"
fi

BENCH_DIR=/home/frappe/frappe-bench
SITE_NAME="${SITE_NAME:-erp.local}"
BACKUP_DIR="${BACKUP_DIR:-$BENCH_DIR/sites/.backups}"
SITE_CONFIG="$BENCH_DIR/sites/$SITE_NAME/site_config.json"
DB_ROOT_USER="${DB_ROOT_USER:-root}"

log() { printf '[restore] %s\n' "$*"; }
die() {
	printf '[restore] ERROR: %s\n' "$*" >&2
	exit 1
}

usage() {
	sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
}

src="" assume_yes=false allow_downgrade=false safety=true
while [ "$#" -gt 0 ]; do
	case "$1" in
	--yes | -y) assume_yes=true ;;
	--allow-downgrade) allow_downgrade=true ;;
	--skip-safety-backup) safety=false ;;
	-h | --help) usage ;;
	-*) die "unknown option $1" ;;
	*)
		[ -z "$src" ] || die "only one backup may be given"
		src="$1"
		;;
	esac
	shift
done
[ -n "$src" ] || usage
[ -n "${DB_ROOT_PASSWORD:-}" ] || die "DB_ROOT_PASSWORD is not set in this shell."
[ -f "$SITE_CONFIG" ] || die "Site '$SITE_NAME' not found ($SITE_CONFIG). The container must have finished its first boot."

cd "$BENCH_DIR"

# ---------------------------------------------------------------------------
# 1. Locate the backup files
# ---------------------------------------------------------------------------
tmp_dir=""
cleanup_tmp() { [ -z "$tmp_dir" ] || rm -rf -- "$tmp_dir"; }
trap cleanup_tmp EXIT

case "$src" in
s3:*)
	[ -n "${BACKUP_S3_REPOSITORY:-}" ] || die "BACKUP_S3_REPOSITORY is not set."
	[ -n "${BACKUP_S3_PASSWORD:-}" ] || die "BACKUP_S3_PASSWORD is not set."
	export RESTIC_REPOSITORY="$BACKUP_S3_REPOSITORY" RESTIC_PASSWORD="$BACKUP_S3_PASSWORD"
	export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/tmp/restic-cache}"
	snapshot="${src#s3:}"
	tmp_dir=$(mktemp -d "${RESTORE_TMP:-/tmp}/erpnext-restore.XXXXXX")
	log "Downloading snapshot '$snapshot' from $RESTIC_REPOSITORY ..."
	if [ "$snapshot" = "latest" ]; then
		restic restore latest --host "${RESTIC_HOST:-erpnext-railway}" --tag erpnext --target "$tmp_dir"
	else
		restic restore "$snapshot" --target "$tmp_dir"
	fi
	db_file=$(find "$tmp_dir" -type f \( -name '*-database.sql.gz' -o -name '*-database.sql' \) | sort | tail -n1)
	[ -n "$db_file" ] || die "No *-database.sql(.gz) in that snapshot."
	dir=$(dirname "$db_file")
	;;
*/*) dir="$src" ;;
*) dir="$BACKUP_DIR/$src" ;;
esac
[ -d "$dir" ] || die "Backup folder not found: $dir (see: backup.sh --list)"

db_file="" public_files="" private_files="" conf_file=""
for f in "$dir"/*; do
	case "$f" in
	*-database.sql.gz | *-database.sql) db_file="$f" ;;
	*-private-files.tgz | *-private-files.tar) private_files="$f" ;;
	*-files.tgz | *-files.tar) public_files="$f" ;;
	*-site_config_backup.json) conf_file="$f" ;;
	esac
done
[ -n "$db_file" ] || die "No *-database.sql(.gz) file in $dir"

log "Restore plan for site '$SITE_NAME':"
log "  database:      $db_file"
log "  public files:  ${public_files:-(none, current files are kept)}"
log "  private files: ${private_files:-(none, current files are kept)}"
log "  site config:   ${conf_file:-(none: encryption_key NOT restored, saved passwords may not decrypt)}"
log "This REPLACES the current database of '$SITE_NAME'."

if ! $assume_yes; then
	[ -t 0 ] || die "Not a terminal; re-run with --yes to confirm."
	read -r -p "Type the site name ($SITE_NAME) to continue: " answer
	[ "$answer" = "$SITE_NAME" ] || die "Aborted."
fi

# ---------------------------------------------------------------------------
# 2. Safety backup, maintenance mode, stop background processes
# ---------------------------------------------------------------------------
if $safety; then
	log "Taking a safety backup of the current database..."
	/usr/local/bin/backup.sh --now --db-only --reason pre-restore ||
		die "Safety backup failed; nothing was changed. Use --skip-safety-backup to override."
fi

have_supervisor=false
if supervisorctl pid >/dev/null 2>&1; then
	have_supervisor=true
fi

on_error() {
	printf '[restore] ERROR: restore failed. The site is still in maintenance mode.\n' >&2
	printf '[restore] The pre-restore backup is in %s (newest *-pre-restore folder).\n' "$BACKUP_DIR" >&2
	printf '[restore] Fix the error above and re-run, or restore that safety backup.\n' >&2
}
trap 'on_error' ERR

bench --site "$SITE_NAME" set-maintenance-mode on
if $have_supervisor; then
	log "Stopping worker and scheduler..."
	supervisorctl stop erpnext-worker erpnext-scheduler || true
fi

apply_keys() {
	# Bring over encryption_key (needed to decrypt saved passwords) and, if the
	# backup was encrypted, backup_encryption_key.
	[ -n "$conf_file" ] || return 0
	local key tmp
	for key in encryption_key backup_encryption_key; do
		if jq -e --arg k "$key" '.[$k] // empty' "$conf_file" >/dev/null; then
			tmp=$(mktemp "$(dirname "$SITE_CONFIG")/.cfg.XXXXXX")
			jq --arg k "$key" --slurpfile src "$conf_file" '.[$k] = $src[0][$k]' "$SITE_CONFIG" >"$tmp"
			chmod 0660 "$tmp"
			mv -f "$tmp" "$SITE_CONFIG"
		fi
	done
}

# ---------------------------------------------------------------------------
# 3. Restore + migrate
# ---------------------------------------------------------------------------
apply_keys

restore_args=(--site "$SITE_NAME" restore "$db_file"
	--db-root-username "$DB_ROOT_USER" --db-root-password "$DB_ROOT_PASSWORD")
[ -z "$public_files" ] || restore_args+=(--with-public-files "$public_files")
[ -z "$private_files" ] || restore_args+=(--with-private-files "$private_files")
if $allow_downgrade; then
	restore_args+=(--force)
fi

log "Running bench restore (this can take a while)..."
bench "${restore_args[@]}" </dev/null

apply_keys
log "Running bench migrate..."
bench --site "$SITE_NAME" migrate
bench --site "$SITE_NAME" clear-cache

# ---------------------------------------------------------------------------
# 4. Bring everything back
# ---------------------------------------------------------------------------
trap - ERR
bench --site "$SITE_NAME" set-maintenance-mode off
if $have_supervisor; then
	log "Restarting web, socket.io, worker and scheduler..."
	supervisorctl restart erpnext-web erpnext-socketio || true
	supervisorctl start erpnext-worker erpnext-scheduler || true
fi
log "Restore finished. Log in with the Administrator password from the BACKUP (not ADMIN_PASSWORD)."
