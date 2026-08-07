#!/usr/bin/env bash


# Create a deployer user if it does not exist, and add it to the sudo group.
DEPLOYER="deployer"

if id "$DEPLOYER" &>/dev/null; then
    echo "User '$DEPLOYER' exists."
else
    echo "User '$DEPLOYER' does not exist."
    sudo useradd -m -s /bin/bash "$DEPLOYER"
	sudo usermod -aG sudo "$DEPLOYER"
fi

# ****************************************************************************************************
# Install Node.js 24.x
# ****************************************************************************************************

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# Refresh package index.
sudo apt update

# Install required tools for repository management and package downloads.
sudo apt install -y ca-certificates curl lsb-release


# Install Node.js 24.x runtime for production workloads.
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs

# Verify Node.js installation. Exit with an error if Node.js is not available.
if node -v > /dev/null 2>&1; then
	node -v
else
	echo "Node.js installation check failed: 'node -v' returned an error." >&2
	exit 1
fi

# ****************************************************************************************************
# Install Nginx web server.
# ****************************************************************************************************

# Install Nginx web server.
sudo apt install -y nginx

# Enable Nginx at boot and start it now.
sudo systemctl enable --now nginx

# Verify Nginx service is running.
if systemctl is-active --quiet nginx; then
	echo "Nginx is active."
else
	echo "Nginx installation check failed: service is not active." >&2
	exit 1
fi

# ****************************************************************************************************
# Step 4: Install and configure PostgreSQL 18 database server.
# ****************************************************************************************************

curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg

# Add PostgreSQL Global Development Group repository for current Debian codename.
echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt/ $(lsb_release -sc)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list

# Refresh package index after adding PostgreSQL repository.
sudo apt update

# Install PostgreSQL 18 server and client.
sudo apt install -y postgresql-18 postgresql-client-18

# Enable PostgreSQL at boot and ensure it is running now.
sudo systemctl enable --now postgresql

# Verify PostgreSQL service is running.
if systemctl is-active --quiet postgresql; then
	echo "PostgreSQL is active."
else
	echo "PostgreSQL installation check failed: service is not active." >&2
	exit 1
fi

# Verify PostgreSQL client version is 18.
if psql --version 2>/dev/null | grep -Eq '^psql \(PostgreSQL\) 18(\.|$)'; then
	psql --version
else
	echo "PostgreSQL installation check failed: expected psql version 18." >&2
	exit 1
fi

# Ensure PostgreSQL allows localhost TCP password authentication for app users.
# This keeps local Unix socket auth unchanged while making Laravel's
# DB_HOST=127.0.0.1 path use password-based authentication.
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


# Apply conservative PostgreSQL tuning for small production VPS instances.
# Values below are a practical baseline for workloads similar to KVM1-class plans.
PG_TUNING_CONF="/etc/postgresql/18/main/conf.d/99-production-tuning.conf"

cat <<'EOF' | sudo tee "$PG_TUNING_CONF" > /dev/null
# ==========================================
# PostgreSQL Production Baseline Configuration
# Optimized for: 1 vCPU, 4GB RAM, NVMe SSD
# ==========================================

# ------------------------------------------
# Connection Settings
# ------------------------------------------
# CAUTION: If your app server is on a separate VPS, change this to
# your private IP or '*' and secure it via pg_hba.conf
listen_addresses = 'localhost'
max_connections = 80

# ------------------------------------------
# Memory Tuning (Optimized for 4GB Total RAM)
# ------------------------------------------
shared_buffers = 1GB                  # 25% of total system memory
effective_cache_size = 2500MB         # ~60-70% of total system memory
work_mem = 8MB                        # Per-operation sort memory
maintenance_work_mem = 256MB          # For index creation and vacuuming

# ------------------------------------------
# 1 vCPU / Single-Core Optimizations
# ------------------------------------------
# Explicitly disable parallel execution since there are no extra
# CPU cores to coordinate or run worker processes.
max_parallel_workers_per_gather = 0
max_parallel_workers = 0
max_parallel_maintenance_workers = 0

# ------------------------------------------
# WAL and Checkpoint Tuning
# ------------------------------------------
wal_compression = on
checkpoint_timeout = 15min
max_wal_size = 2GB                    # Conservative for a 50GB storage limit
min_wal_size = 512MB

# ------------------------------------------
# Storage and Planner Hints for NVMe SSD
# ------------------------------------------
random_page_cost = 1.1                # Fast random I/O parity with sequential
effective_io_concurrency = 200        # NVMe queue depth handling

# ------------------------------------------
# Monitoring and Slow Query Visibility
# ------------------------------------------
shared_preload_libraries = 'pg_stat_statements'
log_min_duration_statement = 500      # Log queries taking longer than 500ms

# ------------------------------------------
# Autovacuum Tuning (Aggressive but throttled)
# ------------------------------------------
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02

# Throttles background vacuuming slightly so it yields to your web application
# on the single shared CPU core.
autovacuum_vacuum_cost_delay = 10ms
EOF

# Restart PostgreSQL so tuning values are applied.
sudo systemctl restart postgresql

if systemctl is-active --quiet postgresql; then
	echo "PostgreSQL restarted with production tuning."
else
	echo "PostgreSQL restart failed after applying tuning." >&2
	exit 1
fi

# Validate PostgreSQL is accepting local connections after restart.
if sudo -u postgres pg_isready -q; then
	echo "PostgreSQL is ready for connections."
else
	echo "PostgreSQL readiness check failed after tuning." >&2
	exit 1
fi
