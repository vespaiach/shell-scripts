#!/usr/bin/env bash

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# Refresh package index.
sudo apt update

# Install required tools for repository management and package downloads.
sudo apt install -y ca-certificates curl lsb-release

# Download and install the Sury PHP repository GPG key.
curl -fsSL https://packages.sury.org/php/apt.gpg | sudo gpg --dearmor -o /usr/share/keyrings/sury-php.gpg

# Add the Sury PHP APT repository for the current Debian codename.
echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/sury-php.list

# Refresh package index after adding the new repository.
sudo apt update

# php8.5: the main PHP runtime package.
# php8.5-cli: command-line interface used to run PHP scripts, cron jobs, and tools like Composer.
# php8.5-common: shared core files/modules required by most PHP packages.
# Install core PHP 8.5 packages.
sudo apt install -y php8.5 php8.5-cli php8.5-common

# Install common PHP 8.5 extensions.
sudo apt install -y php8.5-{fpm,mysql,curl,mbstring,xml,zip,gd,intl}

# php8.5-bcmath: arbitrary precision math support for accurate decimal/big-number calculations.
# Install additional PHP 8.5 extensions.
sudo apt install -y php8.5-pgsql php8.5-bcmath

# Verify PHP installation. Exit with an error if PHP is not available.
if php -v > /dev/null 2>&1; then
	# Print version details when verification succeeds.
	php -v
else
	echo "PHP installation check failed: 'php -v' returned an error." >&2
	exit 1
fi

# Verify PHP-FPM service is running for PHP request processing via Nginx.
if systemctl is-active --quiet php8.5-fpm; then
	echo "php8.5-fpm is active."
else
	echo "PHP-FPM check failed: php8.5-fpm service is not active." >&2
	exit 1
fi

# Verify the PHP-FPM Unix socket exists.
if [ -S /run/php/php8.5-fpm.sock ]; then
	echo "php8.5-fpm socket exists: /run/php/php8.5-fpm.sock"
else
	echo "PHP-FPM socket check failed: /run/php/php8.5-fpm.sock not found." >&2
	exit 1
fi

# Increase PHP limits for production workloads using a dedicated override file.
# Production apps commonly handle larger request bodies, file uploads, and
# longer-running operations (for example: exports, image processing, imports,
# and queue-driven jobs). Defaults are often conservative and can cause
# premature timeouts or rejected uploads under normal peak traffic.
# Do not edit php.ini directly; keep local overrides in conf.d.
PHP_FPM_LIMITS_INI="/etc/php/8.5/fpm/conf.d/99-production-limits.ini"

cat <<'EOF' | sudo tee "$PHP_FPM_LIMITS_INI" > /dev/null
; Custom production limits for PHP-FPM
memory_limit = 512M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 120
max_input_time = 120
EOF

# Tune PHP-FPM process manager settings using a dedicated pool override file.
# Keep these values separate from the default www.conf for easier maintenance.
PHP_FPM_POOL_PM_CONF="/etc/php/8.5/fpm/pool.d/99-www-production-pm.conf"

cat <<'EOF' | sudo tee "$PHP_FPM_POOL_PM_CONF" > /dev/null
[www]
pm = dynamic
pm.max_children = 25
pm.start_servers = 5
pm.min_spare_servers = 3
pm.max_spare_servers = 10
pm.max_requests = 500
EOF

# Reload PHP-FPM so limit changes take effect.
sudo systemctl restart php8.5-fpm

if systemctl is-active --quiet php8.5-fpm; then
	echo "php8.5-fpm restarted with production PHP limits and pool tuning."
else
	echo "PHP-FPM restart failed after applying production limits and pool tuning." >&2
	exit 1
fi



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



# Add PostgreSQL APT repository key for PostgreSQL 18 packages.
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



sudo apt install -y unzip git

# Download Composer installer and expected signature for integrity verification.
curl -fsSL https://composer.github.io/installer.sig -o /tmp/composer-setup.sig
curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php

# Verify installer signature before running it.
EXPECTED_SIGNATURE="$(cat /tmp/composer-setup.sig)"
ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"

if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
	echo "Composer installer signature verification failed." >&2
	rm -f /tmp/composer-setup.php /tmp/composer-setup.sig
	exit 1
fi

# Install Composer globally so the command is available as 'composer'.
sudo php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer

# Clean up temporary installer files.
rm -f /tmp/composer-setup.php /tmp/composer-setup.sig

# Verify Composer installation and print version.
if composer --version > /dev/null 2>&1; then
	composer --version
else
	echo "Composer installation check failed: 'composer --version' returned an error." >&2
	exit 1
fi
