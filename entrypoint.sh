#!/usr/bin/env bash
# railway-entrypoint.sh: boot the single-container ERPNext v16 service.
#
# Phase 1 (root):   fix ownership of the Railway volume mounted on sites/.
# Phase 2 (frappe): wait for MariaDB + Redis, write common_site_config.json,
#                   create the site on first boot, migrate when the image
#                   version changed.
# Phase 3 (root):   render the nginx config and exec supervisord, which runs
#                   gunicorn, socket.io, worker, scheduler, nginx and the
#                   nightly backup loop as the frappe user.
#
# Any arguments are run as the frappe user instead of supervisord (debugging),
# e.g. `docker compose run --rm erpnext bash`.

set -Eeuo pipefail

BENCH_DIR=/home/frappe/frappe-bench
SITES_DIR="$BENCH_DIR/sites"
STATE_DIR="$SITES_DIR/.railway"
SELF=/usr/local/bin/railway-entrypoint.sh

log() { printf '[entrypoint] %s\n' "$*"; }
warn() { printf '[entrypoint] WARNING: %s\n' "$*" >&2; }
die() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Defaults (exported so supervisord's %(ENV_X)s expansion and child
# processes see them).
# ---------------------------------------------------------------------------
export PORT="${PORT:-8080}"
export SITE_NAME="${SITE_NAME:-erp.local}"
export DB_PORT="${DB_PORT:-3306}"
export DB_ROOT_USER="${DB_ROOT_USER:-root}"
export REDIS_CACHE_URL="${REDIS_CACHE_URL:-${REDIS_URL:-}}"
export REDIS_QUEUE_URL="${REDIS_QUEUE_URL:-${REDIS_URL:-}}"
export GUNICORN_WORKERS="${GUNICORN_WORKERS:-1}"
export GUNICORN_THREADS="${GUNICORN_THREADS:-4}"
export GUNICORN_TIMEOUT="${GUNICORN_TIMEOUT:-120}"
export GUNICORN_MAX_REQUESTS="${GUNICORN_MAX_REQUESTS:-5000}"
export GUNICORN_MAX_REQUESTS_JITTER="${GUNICORN_MAX_REQUESTS_JITTER:-500}"
export WORKER_QUEUES="${WORKER_QUEUES:-long,default,short}"
export AUTO_MIGRATE="${AUTO_MIGRATE:-true}"
export DEPENDENCY_TIMEOUT="${DEPENDENCY_TIMEOUT:-300}"
export CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-50m}"
export PROXY_READ_TIMEOUT="${PROXY_READ_TIMEOUT:-120}"
export TRUST_UPSTREAM_FORWARDED_PROTO="${TRUST_UPSTREAM_FORWARDED_PROTO:-on}"
export UPSTREAM_REAL_IP_ADDRESS="${UPSTREAM_REAL_IP_ADDRESS:-0.0.0.0/0}"
export UPSTREAM_REAL_IP_HEADER="${UPSTREAM_REAL_IP_HEADER:-X-Forwarded-For}"
export UPSTREAM_REAL_IP_RECURSIVE="${UPSTREAM_REAL_IP_RECURSIVE:-off}"

run_as_frappe() {
	if [ "$(id -u)" = "0" ]; then
		HOME=/home/frappe USER=frappe LOGNAME=frappe \
			setpriv --reuid=frappe --regid=0 --init-groups -- "$@"
	else
		"$@"
	fi
}

link_assets() {
	# Same as upstream resources/core/main-entrypoint.sh: assets are baked into
	# the image, the volume only gets a symlink to them.
	rm -rf "$SITES_DIR/assets"
	ln -s "$BENCH_DIR/assets" "$SITES_DIR/assets"
}

is_true() {
	case "${1,,}" in
	1 | true | yes | on) return 0 ;;
	*) return 1 ;;
	esac
}

validate_env() {
	[[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT must be a number (got '$PORT')"
	[[ "$DB_PORT" =~ ^[0-9]+$ ]] || die "DB_PORT must be a number (got '$DB_PORT')"
	[[ "$SITE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
		die "SITE_NAME may only contain letters, digits, dots and dashes (got '$SITE_NAME')"
	for v in GUNICORN_WORKERS GUNICORN_THREADS GUNICORN_TIMEOUT GUNICORN_MAX_REQUESTS GUNICORN_MAX_REQUESTS_JITTER DEPENDENCY_TIMEOUT; do
		[[ "${!v}" =~ ^[0-9]+$ ]] || die "$v must be a number (got '${!v}')"
	done
	[[ "$WORKER_QUEUES" =~ ^[a-z_,]+$ ]] || die "WORKER_QUEUES must look like 'long,default,short'"
	case "$TRUST_UPSTREAM_FORWARDED_PROTO" in on | off) ;; *) die "TRUST_UPSTREAM_FORWARDED_PROTO must be on or off" ;; esac
	if [ -f "$BENCH_DIR/sites/apps.txt" ] && grep -qx "$SITE_NAME" "$BENCH_DIR/sites/apps.txt"; then
		die "SITE_NAME cannot be the name of an app ($SITE_NAME)"
	fi
}

# ===========================================================================
# Phase 2: runs as frappe
# ===========================================================================

# host:port from redis://[user:pass@]host[:port][/db]
redis_host_port() {
	local rest="${1#*://}"
	rest="${rest##*@}"
	rest="${rest%%/*}"
	rest="${rest%%\?*}"
	case "$rest" in
	*:*) printf '%s' "$rest" ;;
	*) printf '%s:6379' "$rest" ;;
	esac
}

wait_for_db() {
	local deadline=$((SECONDS + DEPENDENCY_TIMEOUT)) out
	log "Waiting for MariaDB at $DB_HOST:$DB_PORT (timeout ${DEPENDENCY_TIMEOUT}s)..."
	while true; do
		if out=$(MYSQL_PWD="$DB_ROOT_PASSWORD" mariadb --host="$DB_HOST" --port="$DB_PORT" \
			--user="$DB_ROOT_USER" --connect-timeout=5 --batch --skip-column-names \
			-e 'SELECT VERSION()' 2>&1); then
			log "MariaDB is up (version $out)."
			return 0
		fi
		if [[ "$out" == *"Access denied"* ]]; then
			die "MariaDB rejected the root credentials. Check DB_ROOT_PASSWORD (it must equal MARIADB_ROOT_PASSWORD on the MariaDB service, and MariaDB keeps the password it was first initialised with)."
		fi
		((SECONDS < deadline)) || die "MariaDB not reachable after ${DEPENDENCY_TIMEOUT}s: $out"
		sleep 3
	done
}

wait_for_redis() {
	local name="$1" url="$2" hp
	hp=$(redis_host_port "$url")
	log "Waiting for $name at $hp..."
	wait-for-it --quiet --timeout="$DEPENDENCY_TIMEOUT" "$hp" ||
		die "$name ($hp) not reachable after ${DEPENDENCY_TIMEOUT}s"
}

write_common_site_config() {
	# Same keys the upstream `configurator` service sets with `bench set-config -g`
	# (frappe_docker compose.yaml), written in one atomic jq pass.
	local cfg="$SITES_DIR/common_site_config.json" tmp chromium=""
	[ -s "$cfg" ] || echo '{}' >"$cfg"
	if [ -x /usr/lib/chromium/chromium-headless-shell ]; then
		chromium=/usr/lib/chromium/chromium-headless-shell
	fi
	tmp=$(mktemp "$SITES_DIR/.common_site_config.XXXXXX")
	jq --arg db_host "$DB_HOST" \
		--argjson db_port "$DB_PORT" \
		--arg redis_cache "$REDIS_CACHE_URL" \
		--arg redis_queue "$REDIS_QUEUE_URL" \
		--arg chromium "$chromium" \
		'. + {
			db_host: $db_host,
			db_port: $db_port,
			redis_cache: $redis_cache,
			redis_queue: $redis_queue,
			redis_socketio: $redis_queue,
			socketio_port: 9000
		} + (if $chromium != "" then {chromium_path: $chromium} else {} end)' \
		"$cfg" >"$tmp"
	chmod 0660 "$tmp"
	mv -f "$tmp" "$cfg"
}

set_json_key() {
	# set_json_key <file> <key> <string value>
	local file="$1" key="$2" value="$3" tmp
	tmp=$(mktemp "$(dirname "$file")/.cfg.XXXXXX")
	jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$file" >"$tmp"
	chmod 0660 "$tmp"
	mv -f "$tmp" "$file"
}

app_versions() {
	# "app=version" for every installed app, one per line (sorted, stable).
	local app ver
	while read -r app; do
		[ -n "$app" ] || continue
		ver=$(awk -F'"' '/^__version__ = /{print $2; exit}' "$BENCH_DIR/apps/$app/$app/__init__.py" 2>/dev/null || true)
		printf '%s=%s\n' "$app" "${ver:-unknown}"
	done <"$SITES_DIR/apps.txt" | sort
}

major_of() { # major_of "<versions text>" <app>
	printf '%s\n' "$1" | awk -F'[=.]' -v app="$2" '$1 == app && !f {print $2; f = 1}'
}

create_site() {
	local site_dir="$SITES_DIR/$SITE_NAME" admin_pw="${ADMIN_PASSWORD:-}" force=()
	if [ -z "$admin_pw" ]; then
		admin_pw=$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')
		(umask 077 && printf '%s\n' "$admin_pw" >"$STATE_DIR/admin-password")
		warn "ADMIN_PASSWORD was empty: generated one and saved it to $STATE_DIR/admin-password (on the volume). Read it with: cat $STATE_DIR/admin-password"
	fi
	if [ -e "$site_dir" ]; then
		# Only reached when our own earlier creation attempt was interrupted
		# (the .creating marker exists), so the site never held user data.
		warn "Found an unfinished site from an interrupted first boot; recreating it (--force)."
		force=(--force)
	fi
	touch "$STATE_DIR/$SITE_NAME.creating"
	log "Creating site '$SITE_NAME' with ERPNext. This takes 3-10 minutes on first boot..."
	bench new-site "$SITE_NAME" \
		--mariadb-user-host-login-scope='%' \
		--admin-password "$admin_pw" \
		--db-root-username "$DB_ROOT_USER" \
		--db-root-password "$DB_ROOT_PASSWORD" \
		--install-app erpnext \
		--set-default \
		"${force[@]}"
	app_versions >"$STATE_DIR/$SITE_NAME.versions"
	touch "$STATE_DIR/$SITE_NAME.ready"
	rm -f "$STATE_DIR/$SITE_NAME.creating"
	# Secure default: no public self sign-up (already the v16 default; enforced once
	# here, admins can change it later in Website Settings).
	bench --site "$SITE_NAME" execute frappe.db.set_single_value \
		--args '["Website Settings", "disable_signup", 1]' >/dev/null ||
		warn "Could not disable website sign-up; do it in Website Settings."
	log "Site '$SITE_NAME' created. Log in as 'Administrator' with ADMIN_PASSWORD and finish the setup wizard."
}

ensure_site() {
	local site_dir="$SITES_DIR/$SITE_NAME" other
	mkdir -p "$STATE_DIR"

	# Refuse to silently create a second, empty site when SITE_NAME was changed.
	for other in "$STATE_DIR"/*.ready; do
		[ -e "$other" ] || continue
		other=$(basename "$other" .ready)
		if [ "$other" != "$SITE_NAME" ]; then
			die "This volume already holds site '$other' but SITE_NAME is '$SITE_NAME'. Set SITE_NAME back to '$other' (the site name is internal; the public URL does not depend on it)."
		fi
	done

	if [ -f "$STATE_DIR/$SITE_NAME.ready" ]; then
		[ -f "$site_dir/site_config.json" ] ||
			die "Marker says site '$SITE_NAME' exists but $site_dir/site_config.json is missing. Restore the volume or remove $STATE_DIR/$SITE_NAME.ready to create a fresh site."
		return 0
	fi

	if [ ! -f "$site_dir/site_config.json" ] || [ -f "$STATE_DIR/$SITE_NAME.creating" ]; then
		create_site
		return 0
	fi

	# A site we did not create (e.g. volume copied from another setup).
	log "Found existing site '$SITE_NAME' without our marker; checking it..."
	local installed
	installed=$(bench --site "$SITE_NAME" list-apps 2>/dev/null || true)
	if grep -qw erpnext <<<"$installed"; then
		touch "$STATE_DIR/$SITE_NAME.ready"
		log "Existing ERPNext site adopted."
	else
		die "sites/$SITE_NAME exists but ERPNext is not installed in it (or its database is unreachable). Not touching it. Fix or remove it manually."
	fi
}

maybe_migrate() {
	local vfile="$STATE_DIR/$SITE_NAME.versions" old new old_major new_major
	new=$(app_versions)
	old=$(cat "$vfile" 2>/dev/null || true)
	[ "$old" != "$new" ] || {
		log "App versions unchanged; skipping migrate."
		return 0
	}

	old_major=$(major_of "$old" erpnext)
	new_major=$(major_of "$new" erpnext)
	if [ -n "$old_major" ] && [ -n "$new_major" ] && [ "$old_major" != "$new_major" ]; then
		die "Site data is ERPNext v$old_major but this image is v$new_major. Major version upgrades are not supported by this template; pin the image back to v$old_major (see README)."
	fi

	if ! is_true "$AUTO_MIGRATE"; then
		warn "App versions changed but AUTO_MIGRATE=false; run 'bench --site $SITE_NAME migrate' yourself."
		return 0
	fi

	log "App versions changed:"
	# shellcheck disable=SC2086 # split one app per line on purpose
	printf '  was: %s\n' ${old:-"(unknown)"}
	# shellcheck disable=SC2086
	printf '  now: %s\n' $new
	log "Taking a database backup before migrating..."
	/usr/local/bin/backup.sh --now --db-only --reason pre-migrate ||
		die "Pre-migrate backup failed; not migrating. Fix the backup error (see above) or set AUTO_MIGRATE=false."
	log "Running bench migrate..."
	bench --site "$SITE_NAME" migrate
	printf '%s\n' "$new" >"$vfile"
	log "Migrate finished."
}

configure_host_name() {
	local cfg="$SITES_DIR/$SITE_NAME/site_config.json" want="${FRAPPE_HOST_NAME:-}" have
	if [ -z "$want" ] && [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
		want="https://$RAILWAY_PUBLIC_DOMAIN"
	fi
	[ -n "$want" ] || return 0
	have=$(jq -r '.host_name // empty' "$cfg")
	if [ "$have" != "$want" ]; then
		set_json_key "$cfg" host_name "$want"
		log "host_name set to $want (used in emails, print links and PDFs)."
	fi
}

setup_as_frappe() {
	cd "$BENCH_DIR"
	umask 0002
	link_assets
	ls -1 apps >"$SITES_DIR/apps.txt"
	validate_env

	[ -n "${DB_HOST:-}" ] || die "DB_HOST is not set (Railway: \${{MariaDB.RAILWAY_PRIVATE_DOMAIN}})."
	[ -n "${DB_ROOT_PASSWORD:-}" ] || die "DB_ROOT_PASSWORD is not set (Railway: \${{MariaDB.MARIADB_ROOT_PASSWORD}})."
	[ -n "$REDIS_CACHE_URL" ] || die "REDIS_URL (or REDIS_CACHE_URL) is not set (Railway: \${{Redis.REDIS_URL}})."
	[ -n "$REDIS_QUEUE_URL" ] || die "REDIS_URL (or REDIS_QUEUE_URL) is not set (Railway: \${{Redis.REDIS_URL}})."

	wait_for_db
	wait_for_redis "Redis (cache)" "$REDIS_CACHE_URL"
	if [ "$REDIS_QUEUE_URL" != "$REDIS_CACHE_URL" ]; then
		wait_for_redis "Redis (queue)" "$REDIS_QUEUE_URL"
	fi

	write_common_site_config
	ensure_site

	# Keep `bench` without --site pointed at our site.
	set_json_key "$SITES_DIR/common_site_config.json" default_site "$SITE_NAME"
	configure_host_name
	maybe_migrate
	log "Setup complete."
}

# ===========================================================================
# Phase 1 / 3: root
# ===========================================================================

render_nginx() {
	# shellcheck disable=SC2016 # the list is literal on purpose
	envsubst '${PORT} ${SITE_NAME} ${CLIENT_MAX_BODY_SIZE} ${PROXY_READ_TIMEOUT} ${TRUST_UPSTREAM_FORWARDED_PROTO} ${UPSTREAM_REAL_IP_ADDRESS} ${UPSTREAM_REAL_IP_HEADER} ${UPSTREAM_REAL_IP_RECURSIVE}' \
		</templates/nginx/railway.conf.template >/etc/nginx/railway.conf
	# Test as frappe so any temp dirs nginx creates belong to the runtime user.
	run_as_frappe nginx -q -t -c /etc/nginx/railway.conf || die "nginx config test failed"
}

main() {
	if [ "${1:-}" = "__setup" ]; then
		setup_as_frappe
		return 0
	fi

	if [ "$(id -u)" = "0" ]; then
		mkdir -p "$SITES_DIR"
		# Railway mounts volumes owned by root; hand everything to frappe.
		# Only touches files that are not already owned by frappe.
		find "$SITES_DIR" -xdev ! -user frappe -exec chown -h frappe:0 {} + 2>/dev/null ||
			warn "could not chown every file under $SITES_DIR"
		chmod 0775 "$SITES_DIR"
	fi

	if [ "$#" -gt 0 ]; then
		run_as_frappe bash -c "cd '$BENCH_DIR' && rm -rf sites/assets && ln -s '$BENCH_DIR/assets' sites/assets" || true
		cd "$BENCH_DIR"
		if [ "$(id -u)" = "0" ]; then
			exec env HOME=/home/frappe USER=frappe LOGNAME=frappe \
				setpriv --reuid=frappe --regid=0 --init-groups -- "$@"
		fi
		exec "$@"
	fi

	[ "$(id -u)" = "0" ] || die "The container must start as root (it drops to the frappe user itself). Do not set RAILWAY_RUN_UID or a docker 'user:'."

	run_as_frappe "$SELF" __setup
	render_nginx
	log "Starting supervisord (web on :$PORT, socket.io, worker, scheduler, backups)..."
	exec supervisord -c /etc/supervisor/supervisord.conf
}

main "$@"
