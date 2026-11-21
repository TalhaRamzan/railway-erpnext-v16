#!/usr/bin/env bash
# backup.sh: ERPNext backups for the single-container Railway template.
#
#   backup.sh --now [--db-only] [--reason NAME]  take one backup now
#   backup.sh --daemon                            nightly loop (run by supervisord)
#   backup.sh --list                              list local (and S3) backups
#
# Each backup is a folder under $BACKUP_DIR (on the Railway volume) holding
# exactly what `bench backup` produces:
#   <ts>-<site>-database.sql.gz        the database
#   <ts>-<site>-files.tgz              public files      (unless --db-only)
#   <ts>-<site>-private-files.tgz      private files     (unless --db-only)
#   <ts>-<site>-site_config_backup.json  site config incl. encryption_key
# Local copies are pruned to the newest $BACKUP_KEEP. If BACKUP_S3_REPOSITORY
# is set, each folder is also pushed (encrypted, deduplicated) to any
# S3-compatible bucket with restic, which ships in the official image.
#
# Environment (all optional):
#   SITE_NAME             site to back up (default erp.local)
#   BACKUP_ENABLED        nightly loop on/off (default true)
#   BACKUP_TIME           HH:MM, UTC (default 02:00)
#   BACKUP_KEEP           local nightly/manual backups to keep (default 3)
#   BACKUP_WITH_FILES     include uploaded files (default true)
#   BACKUP_DIR            default /home/frappe/frappe-bench/sites/.backups
#   BACKUP_MIN_FREE_MB    refuse to start a backup below this free space (default 1024)
#   BACKUP_S3_REPOSITORY  restic repo, e.g. s3:https://<endpoint>/<bucket>/erpnext
#   BACKUP_S3_PASSWORD    restic encryption password (KEEP A COPY OUTSIDE RAILWAY)
#   BACKUP_S3_KEEP        remote snapshots to keep per kind (default 14)
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_DEFAULT_REGION  bucket credentials

set -Eeuo pipefail

if [ "$(id -u)" = "0" ]; then
	# e.g. run from `railway ssh`: re-run as the frappe user.
	exec env HOME=/home/frappe USER=frappe LOGNAME=frappe \
		setpriv --reuid=frappe --regid=0 --init-groups -- "$0" "$@"
fi

BENCH_DIR=/home/frappe/frappe-bench
SITE_NAME="${SITE_NAME:-erp.local}"
BACKUP_ENABLED="${BACKUP_ENABLED:-true}"
BACKUP_TIME="${BACKUP_TIME:-02:00}"
BACKUP_KEEP="${BACKUP_KEEP:-3}"
BACKUP_WITH_FILES="${BACKUP_WITH_FILES:-true}"
BACKUP_DIR="${BACKUP_DIR:-$BENCH_DIR/sites/.backups}"
BACKUP_MIN_FREE_MB="${BACKUP_MIN_FREE_MB:-1024}"
BACKUP_S3_REPOSITORY="${BACKUP_S3_REPOSITORY:-}"
BACKUP_S3_PASSWORD="${BACKUP_S3_PASSWORD:-}"
BACKUP_S3_KEEP="${BACKUP_S3_KEEP:-14}"
SAFETY_KEEP=2 # pre-migrate / pre-restore backups kept locally

log() { printf '[backup] %s\n' "$*"; }
err() { printf '[backup] ERROR: %s\n' "$*" >&2; }

is_true() {
	case "${1,,}" in
	1 | true | yes | on) return 0 ;;
	*) return 1 ;;
	esac
}

for v in BACKUP_KEEP BACKUP_MIN_FREE_MB BACKUP_S3_KEEP; do
	[[ "${!v}" =~ ^[0-9]+$ ]] || {
		err "$v must be a number (got '${!v}')"
		exit 2
	}
done
((BACKUP_KEEP >= 1)) || BACKUP_KEEP=1

s3_enabled() { [ -n "$BACKUP_S3_REPOSITORY" ]; }

restic_env() {
	if [ -z "$BACKUP_S3_PASSWORD" ]; then
		err "BACKUP_S3_REPOSITORY is set but BACKUP_S3_PASSWORD is empty."
		return 1
	fi
	export RESTIC_REPOSITORY="$BACKUP_S3_REPOSITORY"
	export RESTIC_PASSWORD="$BACKUP_S3_PASSWORD"
	export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/tmp/restic-cache}"
	export RESTIC_HOST="${RESTIC_HOST:-erpnext-railway}"
}

free_mb() { df -Pk "$BACKUP_DIR" | awk 'NR == 2 {print int($4 / 1024)}'; }

# Completed backup folders of one kind, oldest first.
#   kind=full   -> nightly / manual
#   kind=safety -> pre-migrate / pre-restore
list_sets() {
	local kind="$1" d name
	for d in "$BACKUP_DIR"/*/; do
		[ -d "$d" ] || continue
		name=$(basename "$d")
		[[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z-[a-z-]+$ ]] || continue
		case "$kind:$name" in
		full:*-nightly | full:*-manual) printf '%s\n' "$d" ;;
		safety:*-pre-*) printf '%s\n' "$d" ;;
		esac
	done | sort
}

prune_kind() {
	local kind="$1" keep="$2" sets count i
	mapfile -t sets < <(list_sets "$kind")
	count=${#sets[@]}
	for ((i = 0; i < count - keep; i++)); do
		log "Pruning old local backup $(basename "${sets[$i]}")"
		rm -rf -- "${sets[$i]}"
	done
}

cleanup_incomplete() {
	local d
	for d in "$BACKUP_DIR"/.inprogress-*; do
		[ -e "$d" ] || continue
		log "Removing incomplete backup $(basename "$d")"
		rm -rf -- "$d"
	done
}

upload_s3() {
	local dir="$1" reason="$2"
	restic_env || return 1
	if ! restic cat config >/dev/null 2>&1; then
		log "Initialising restic repository $RESTIC_REPOSITORY"
		restic init
	fi
	log "Uploading $(basename "$dir") to $RESTIC_REPOSITORY"
	restic backup --host "$RESTIC_HOST" --tag erpnext --tag "site:$SITE_NAME" --tag "$reason" "$dir"
	restic forget --host "$RESTIC_HOST" --tag erpnext --group-by host,tags \
		--keep-last "$BACKUP_S3_KEEP" --prune
}

run_backup() {
	mkdir -p "$BACKUP_DIR"
	chmod 0770 "$BACKUP_DIR"
	# Serialise nightly, manual, pre-migrate and pre-restore backups. The lock
	# lives on fd 9 of a subshell, so it is released as soon as it returns.
	(
		if ! flock -w 3600 9; then
			err "Another backup is still running after 1h; giving up."
			exit 1
		fi
		run_backup_locked "$@"
	) 9>"$BACKUP_DIR/.lock"
}

run_backup_locked() {
	local db_only="$1" reason="$2" ts work final args desc="database + files"

	cleanup_incomplete

	if (($(free_mb) < BACKUP_MIN_FREE_MB)); then
		log "Low disk space ($(free_mb) MB free); pruning local backups down to 1 first."
		prune_kind full 1
		prune_kind safety 1
	fi
	if (($(free_mb) < BACKUP_MIN_FREE_MB)); then
		err "Only $(free_mb) MB free on the volume (< BACKUP_MIN_FREE_MB=$BACKUP_MIN_FREE_MB). Skipping backup. Grow the volume or lower BACKUP_KEEP."
		return 1
	fi

	ts=$(date -u +%Y%m%dT%H%M%SZ)
	work="$BACKUP_DIR/.inprogress-$ts-$reason"
	final="$BACKUP_DIR/$ts-$reason"
	mkdir -p "$work"

	args=(--site "$SITE_NAME" backup --backup-path "$work" --compress)
	if [ "$db_only" != "true" ] && is_true "$BACKUP_WITH_FILES"; then
		args+=(--with-files)
	else
		desc="database only"
	fi

	log "Starting $reason backup of $SITE_NAME ($desc)"
	if ! (cd "$BENCH_DIR" && bench "${args[@]}"); then
		rm -rf -- "$work"
		err "bench backup failed."
		return 1
	fi
	if ! compgen -G "$work/*-database.sql.gz" >/dev/null; then
		rm -rf -- "$work"
		err "bench backup produced no database dump."
		return 1
	fi
	mv -- "$work" "$final"
	log "Saved $(basename "$final") ($(du -sh "$final" | cut -f1))"

	case "$reason" in
	pre-*) prune_kind safety "$SAFETY_KEEP" ;;
	*) prune_kind full "$BACKUP_KEEP" ;;
	esac

	local status=0
	if s3_enabled; then
		if upload_s3 "$final" "$reason"; then
			log "Upload finished."
		else
			err "Upload to S3 failed; the local copy is kept."
			status=1
		fi
	fi
	date -u +%FT%TZ >"$BACKUP_DIR/last-success"
	printf '%s\n' "$(basename "$final")" >>"$BACKUP_DIR/last-success"
	return "$status"
}

seconds_until() {
	local now target
	now=$(date -u +%s)
	target=$(date -u -d "$(date -u +%F) $BACKUP_TIME" +%s)
	((target > now)) || target=$((target + 86400))
	echo $((target - now))
}

daemon() {
	if ! is_true "$BACKUP_ENABLED"; then
		log "BACKUP_ENABLED=$BACKUP_ENABLED: nightly backups are off."
		exec sleep infinity
	fi
	if ! [[ "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
		err "BACKUP_TIME must be HH:MM (24h, UTC); got '$BACKUP_TIME'. Using 02:00."
		BACKUP_TIME=02:00
	fi
	if s3_enabled; then
		log "Nightly backups at $BACKUP_TIME UTC, keeping $BACKUP_KEEP locally in $BACKUP_DIR and $BACKUP_S3_KEEP in S3."
	else
		log "Nightly backups at $BACKUP_TIME UTC, keeping $BACKUP_KEEP locally in $BACKUP_DIR (no off-site copy: set BACKUP_S3_REPOSITORY)."
	fi
	while true; do
		local wait_s
		wait_s=$(seconds_until)
		log "Next backup in $((wait_s / 3600))h$(((wait_s % 3600) / 60))m."
		sleep "$wait_s"
		run_backup false nightly || err "Nightly backup failed (will retry tomorrow)."
		sleep 60
	done
}

list_backups() {
	local d
	log "Local backups in $BACKUP_DIR:"
	for d in "$BACKUP_DIR"/*/; do
		[ -d "$d" ] || continue
		printf '  %-40s %s\n' "$(basename "$d")" "$(du -sh "$d" | cut -f1)"
	done
	if [ -f "$BACKUP_DIR/last-success" ]; then
		log "Last success: $(tr '\n' ' ' <"$BACKUP_DIR/last-success")"
	fi
	if s3_enabled; then
		restic_env
		log "Remote snapshots in $RESTIC_REPOSITORY:"
		restic snapshots --host "$RESTIC_HOST" --tag erpnext
	fi
}

usage() {
	sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
}

mode="" db_only=false reason=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	--now) mode=now ;;
	--daemon) mode=daemon ;;
	--list) mode=list ;;
	--db-only) db_only=true ;;
	--reason)
		reason="${2:-}"
		shift
		;;
	-h | --help) usage ;;
	*)
		err "unknown argument: $1"
		usage
		;;
	esac
	shift
done

case "$mode" in
now)
	reason="${reason:-manual}"
	[[ "$reason" =~ ^(manual|nightly|pre-[a-z]+)$ ]] || {
		err "--reason must be manual, nightly or pre-<word>"
		exit 2
	}
	run_backup "$db_only" "$reason"
	;;
daemon) daemon ;;
list) list_backups ;;
*) usage ;;
esac
