# MariaDB for ERPNext v16 on Railway.
#
# Same server flags as upstream frappe_docker (overrides/compose.mariadb.yaml),
# baked into a config file so no custom start command is needed on Railway.
# MariaDB 11.8 is the version frappe_docker ships with for v16.
# Pinned by tag AND multi-arch index digest (verified on Docker Hub 2026-11-21).
FROM mariadb:11.8.9@sha256:e1d5495f445654134f226f55a41ce0da227116f6f27f283101f405c794d841fc

COPY frappe.cnf /etc/mysql/conf.d/zz-frappe.cnf
RUN chmod 0644 /etc/mysql/conf.d/zz-frappe.cnf

# Lets the image upgrade system tables after a MariaDB patch bump (upstream does the same).
ENV MARIADB_AUTO_UPGRADE=1
