#!/usr/bin/env bash

set -euo pipefail

if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required but not installed." >&2
	exit 1
fi


curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg

echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt/ $(lsb_release -sc)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt update

sudo apt install -y postgresql-18 postgresql-client-18

sudo systemctl enable --now postgresql

if systemctl is-active --quiet postgresql; then
	echo "PostgreSQL is active."
else
	echo "PostgreSQL installation check failed: service is not active." >&2
	exit 1
fi

if psql --version 2>/dev/null | grep -Eq '^psql \(PostgreSQL\) 18(\.|$)'; then
	psql --version
else
	echo "PostgreSQL installation check failed: expected psql version 18." >&2
	exit 1
fi

PG_HBA_CONF="/etc/postgresql/18/main/pg_hba.conf"

sudo sed -Ei \
	-e "s|^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+127\\.0\\.0\\.1/32[[:space:]]+.*$|host    all             all             127.0.0.1/32            scram-sha-256|" \
	-e "s|^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+::1/128[[:space:]]+.*$|host    all             all             ::1/128                 scram-sha-256|" \
	"$PG_HBA_CONF"

if ! sudo grep -Eq '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32[[:space:]]+scram-sha-256([[:space:]]|$)' "$PG_HBA_CONF"; then
	echo 'host    all             all             127.0.0.1/32            scram-sha-256' | sudo tee -a "$PG_HBA_CONF" > /dev/null
fi

if ! sudo grep -Eq '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+::1/128[[:space:]]+scram-sha-256([[:space:]]|$)' "$PG_HBA_CONF"; then
	echo 'host    all             all             ::1/128                 scram-sha-256' | sudo tee -a "$PG_HBA_CONF" > /dev/null
fi


PG_TUNING_CONF="/etc/postgresql/18/main/conf.d/99-production-tuning.conf"

cat <<'EOF' | sudo tee "$PG_TUNING_CONF" > /dev/null

listen_addresses = 'localhost'
max_connections = 80

shared_buffers = 1GB                  # 25% of total system memory
effective_cache_size = 2500MB         # ~60-70% of total system memory
work_mem = 8MB                        # Per-operation sort memory
maintenance_work_mem = 256MB          # For index creation and vacuuming

max_parallel_workers_per_gather = 0
max_parallel_workers = 0
max_parallel_maintenance_workers = 0

wal_compression = on
checkpoint_timeout = 15min
max_wal_size = 2GB                    # Conservative for a 50GB storage limit
min_wal_size = 512MB

random_page_cost = 1.1                # Fast random I/O parity with sequential
effective_io_concurrency = 200        # NVMe queue depth handling

shared_preload_libraries = 'pg_stat_statements'
log_min_duration_statement = 500      # Log queries taking longer than 500ms

autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02

autovacuum_vacuum_cost_delay = 10ms
EOF

sudo systemctl restart postgresql

if systemctl is-active --quiet postgresql; then
	echo "PostgreSQL restarted with production tuning."
else
	echo "PostgreSQL restart failed after applying tuning." >&2
	exit 1
fi

if sudo -u postgres pg_isready -q; then
	echo "PostgreSQL is ready for connections."
else
	echo "PostgreSQL readiness check failed after tuning." >&2
	exit 1
fi
