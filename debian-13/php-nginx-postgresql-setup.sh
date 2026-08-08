#!/usr/bin/env bash

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# Every operation in this script needs elevation, so fail before touching
# anything if sudo is unavailable.
if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required but not installed." >&2
	exit 1
fi

# ****************************************************************************************************
# Step 1: Install PHP 8.5 and its common extensions from the Sury repository.
# ****************************************************************************************************

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

# ****************************************************************************************************
# Step 2: Configure PHP-FPM for production workloads and tune its process manager settings.
# ****************************************************************************************************

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

# ****************************************************************************************************
# Step 3: Install Nginx web server.
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
# ****************************************************************************************************
# Step 5: Create the deployer user with passwordless sudo and SSH key access.
# ****************************************************************************************************

DEPLOYER_USER="deployer"

# atomic-deployment-setup.sh refuses to run as anyone else, so this account has
# to exist before any site can be provisioned on this host.
if id "${DEPLOYER_USER}" >/dev/null 2>&1; then
	echo "User '${DEPLOYER_USER}' already exists."
else
	echo "Creating user '${DEPLOYER_USER}'..."
	# No password is set, so the account is reachable by SSH key only. That is
	# also why the sudoers grant below has to be NOPASSWD: with no password to
	# type, a password-prompting sudo would be unusable rather than merely
	# inconvenient.
	sudo useradd -m -s /bin/bash "${DEPLOYER_USER}"
fi

# Run unconditionally rather than only for freshly created accounts: usermod -aG
# is idempotent, and a deployer that predates this script may not be in the
# group yet.
sudo usermod -aG sudo "${DEPLOYER_USER}"

# Resolve the home directory and primary group from the passwd/group database
# instead of assuming /home/deployer and a deployer:deployer pair -- a
# pre-existing account may have been created with either one different.
DEPLOYER_HOME="$(getent passwd "${DEPLOYER_USER}" | cut -d: -f6)"
DEPLOYER_GROUP="$(id -gn "${DEPLOYER_USER}")"

if [[ -z "${DEPLOYER_HOME}" ]]; then
	echo "Could not determine the home directory for '${DEPLOYER_USER}'." >&2
	exit 1
fi

# ---- Passwordless sudo ----

SUDOERS_FILE="/etc/sudoers.d/90-${DEPLOYER_USER}"

# A drop-in is only honoured if the main sudoers file pulls the directory in.
# Without this check the grant below would appear to succeed and silently do
# nothing, leaving deployer with an unusable password-prompting sudo.
if ! sudo grep -Eq '^[[:space:]]*[@#]includedir[[:space:]]+/etc/sudoers\.d([[:space:]]*(#.*)?)?$' /etc/sudoers; then
	echo "/etc/sudoers does not include /etc/sudoers.d; refusing to write a drop-in that would be ignored." >&2
	exit 1
fi

echo "Granting passwordless sudo to '${DEPLOYER_USER}'..."
TMP_SUDOERS="$(mktemp)"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${DEPLOYER_USER}" > "${TMP_SUDOERS}"

# Validate before installing. A malformed file in sudoers.d breaks sudo for
# every user on the host, including the one running this script, so this is
# checked while the content is still a throwaway temp file.
if ! sudo visudo -c -q -f "${TMP_SUDOERS}"; then
	rm -f "${TMP_SUDOERS}"
	echo "Generated sudoers drop-in failed validation; not installing it." >&2
	exit 1
fi

# install(1) sets ownership and the required 0440 mode as it copies -- sudo
# ignores any file in sudoers.d that is group- or world-writable, which is
# exactly what the 0600 temp file would become after a plain mv + chmod race.
sudo install -m 0440 -o root -g root "${TMP_SUDOERS}" "${SUDOERS_FILE}"
rm -f "${TMP_SUDOERS}"

# ---- SSH access ----

echo "Configuring SSH access for '${DEPLOYER_USER}'..."

SSH_DIR="${DEPLOYER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

# Lets the key be supplied non-interactively for unattended provisioning
# (cloud-init, CI). Left empty, the script prompts for it below.
DEPLOYER_SSH_KEY="${DEPLOYER_SSH_KEY:-}"

if [[ -n "${DEPLOYER_SSH_KEY}" ]]; then
	echo "Using the SSH key supplied via DEPLOYER_SSH_KEY."
elif [[ -t 0 ]]; then
	if ! read -r -p "Paste the public SSH key for '${DEPLOYER_USER}': " DEPLOYER_SSH_KEY; then
		echo "No SSH key provided." >&2
		exit 1
	fi
else
	echo "No SSH key available: stdin is not a terminal, so the key cannot be prompted for." >&2
	echo "Set DEPLOYER_SSH_KEY to the public key and rerun." >&2
	exit 1
fi

# Matches the key-type and base64 blob at the start of an OpenSSH public key.
# Every key reaching this point was typed by a human, so it is checked before
# installation: a typo or an empty value would otherwise leave the account with
# an authorized_keys that grants nobody access.
SSH_KEY_PATTERN='^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]]|$)'

if [[ ! "${DEPLOYER_SSH_KEY}" =~ ${SSH_KEY_PATTERN} ]]; then
	echo "That does not look like an OpenSSH public key (expected e.g. 'ssh-ed25519 AAAA... comment')." >&2
	echo "Note this is the *public* key (.pub) -- never paste a private key here." >&2
	exit 1
fi

# A pre-existing account may have no home directory. Creating .ssh below would
# then create the home too, owned by root, which sshd's StrictModes rejects.
if [[ ! -d "${DEPLOYER_HOME}" ]]; then
	sudo mkdir -p "${DEPLOYER_HOME}"
	sudo chmod 755 "${DEPLOYER_HOME}"
	sudo chown "${DEPLOYER_USER}:${DEPLOYER_GROUP}" "${DEPLOYER_HOME}"
fi

sudo mkdir -p "${SSH_DIR}"
sudo touch "${AUTH_KEYS}"

# An existing authorized_keys that does not end in a newline would otherwise get
# the appended key glued onto its last line, corrupting both.
if sudo test -s "${AUTH_KEYS}" && [[ -n "$(sudo tail -c 1 "${AUTH_KEYS}")" ]]; then
	printf '\n' | sudo tee -a "${AUTH_KEYS}" > /dev/null
fi

# Append rather than overwrite: re-running this script must not drop keys an
# operator added by hand, and must not accumulate duplicates of its own.
if sudo grep -qxF -- "${DEPLOYER_SSH_KEY}" "${AUTH_KEYS}"; then
	echo "SSH key is already authorized for '${DEPLOYER_USER}'."
else
	printf '%s\n' "${DEPLOYER_SSH_KEY}" | sudo tee -a "${AUTH_KEYS}" > /dev/null
	echo "Authorized SSH key for '${DEPLOYER_USER}'."
fi

# sshd ignores keys from a group- or world-writable ~/.ssh or authorized_keys.
sudo chmod 700 "${SSH_DIR}"
sudo chmod 600 "${AUTH_KEYS}"
sudo chown -R "${DEPLOYER_USER}:${DEPLOYER_GROUP}" "${SSH_DIR}"

if ! sudo test -s "${AUTH_KEYS}"; then
	echo "SSH check failed: ${AUTH_KEYS} is empty." >&2
	exit 1
fi

# Prove the sudo grant works instead of assuming it: sudo -n fails outright if
# the drop-in was not picked up, which is the whole failure mode worth catching
# here while the operator still has a working session.
if sudo -u "${DEPLOYER_USER}" sudo -n true 2>/dev/null; then
	echo "User '${DEPLOYER_USER}' has passwordless sudo."
else
	echo "Passwordless sudo check failed for '${DEPLOYER_USER}'." >&2
	exit 1
fi
