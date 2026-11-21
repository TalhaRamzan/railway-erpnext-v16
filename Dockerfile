# syntax=docker/dockerfile:1
#
# ERPNext v16 for Railway: one container, one volume.
#
# Railway attaches a volume to exactly one service, but Frappe's web server,
# socket.io server, background workers and scheduler all need the same
# `sites/` directory. So every Frappe process runs here under supervisord,
# and MariaDB + Redis run as separate Railway services.
#
# Base image: official frappe/erpnext image, pinned by tag AND digest
# (multi-arch index digest, verified against Docker Hub on 2026-11-21).
# To bump: change both the tag and the digest, then run TEST.md.

ARG ERPNEXT_IMAGE=frappe/erpnext:v16.60.0@sha256:3847babae025dae001e638b7fc5503c944fd968216b3074e60edfcc240fb2db6

FROM ${ERPNEXT_IMAGE}

USER root

# supervisord in its own virtualenv so it never touches the bench Python env.
# Pinned version + sha256 of the PyPI wheel (pure Python, no dependencies).
ARG SUPERVISOR_VERSION=4.3.0
ARG SUPERVISOR_SHA256=0bcb763fddafba410f35cbde226aa7f8514b9fb82eb05a0c85f6588d1c13f8db
RUN set -eux; \
    python3 -m venv /opt/supervisor; \
    printf 'supervisor==%s --hash=sha256:%s\n' "$SUPERVISOR_VERSION" "$SUPERVISOR_SHA256" > /tmp/supervisor-req.txt; \
    /opt/supervisor/bin/pip install --no-cache-dir --disable-pip-version-check --require-hashes -r /tmp/supervisor-req.txt; \
    rm -f /tmp/supervisor-req.txt; \
    ln -sf /opt/supervisor/bin/supervisord /usr/local/bin/supervisord; \
    ln -sf /opt/supervisor/bin/supervisorctl /usr/local/bin/supervisorctl; \
    # Fail the build early if a tool the scripts rely on is missing from the base image.
    for bin in bench node nginx envsubst jq mariadb setpriv flock restic curl wait-for-it; do \
        command -v "$bin" >/dev/null || { echo "missing required binary: $bin" >&2; exit 1; }; \
    done; \
    mkdir -p /etc/supervisor /templates/nginx

COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY nginx.conf.template /templates/nginx/railway.conf.template
COPY entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY backup.sh /usr/local/bin/backup.sh
COPY restore.sh /usr/local/bin/restore.sh
COPY supervisor-watchdog.sh /usr/local/bin/supervisor-watchdog.sh

RUN chmod 755 /usr/local/bin/railway-entrypoint.sh /usr/local/bin/backup.sh \
        /usr/local/bin/restore.sh /usr/local/bin/supervisor-watchdog.sh \
    && chmod 644 /etc/supervisor/supervisord.conf /templates/nginx/railway.conf.template

WORKDIR /home/frappe/frappe-bench

# The entrypoint starts as root only to fix ownership of the Railway volume
# (mounted root-owned), then runs all bench commands as the `frappe` user.
# supervisord drops every program to `frappe` as well.
ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD []
