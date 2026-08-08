# Split php-nginx-postgresql-setup.sh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `debian-13/php-nginx-postgresql-setup.sh` into four standalone, idempotent step files plus a thin orchestrator, so any single step (PHP, Nginx, PostgreSQL, or the deployer user) can be re-run on its own.

**Architecture:** Move each of the current script's four logical steps verbatim into its own script under a new `debian-13/php-nginx-postgresql-setup/` directory. Each step file gets its own shebang, `set -euo pipefail`, and sudo-availability preflight check, making it independently runnable via `bash <file>`. The top-level `debian-13/php-nginx-postgresql-setup.sh` becomes a thin orchestrator that resolves its own directory and invokes the four step files in order as subprocesses.

**Tech Stack:** Bash (Debian 13 target). No build/test framework — verification is `bash -n` syntax checking, per this repo's existing convention.

## Global Constraints

- No behavioral changes to provisioning logic — package versions (PHP 8.5, PostgreSQL 18), tuning values, validation regexes, and error messages must be copied verbatim from the current script. This is a structural move only.
- Every step file must be independently runnable: own `#!/usr/bin/env bash`, own `set -euo pipefail`, own copy of the sudo-availability check.
- Scope is `debian-13/php-nginx-postgresql-setup.sh` only. Do not touch `debian-13/nodejs-nginx-postgresql-setup.sh` or `debian-13/atomic-deployment-setup.sh`.
- The only verification available is `bash -n <file>` (per `CLAUDE.md`) — there is no test runner, linter, or CI in this repo.
- Reference for "current script": `debian-13/php-nginx-postgresql-setup.sh` as of commit `0fadcc8` (the tip of this branch before this plan's changes begin). Use `git show 0fadcc8:debian-13/php-nginx-postgresql-setup.sh` if you need to re-check original content.

---

### Task 1: Create `01-php.sh` (PHP 8.5 install + FPM production tuning)

**Files:**
- Create: `debian-13/php-nginx-postgresql-setup/01-php.sh`

**Interfaces:**
- Consumes: nothing (first step; only depends on the sudo-availability check in its own preamble).
- Produces: nothing consumed by other step files — steps are independent aside from the orchestrator's execution order.

- [ ] **Step 1: Create the directory and write the file**

Create `debian-13/php-nginx-postgresql-setup/01-php.sh` with exactly this content:

```bash
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
# Install PHP 8.5 and its common extensions from the Sury repository.
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
# Configure PHP-FPM for production workloads and tune its process manager settings.
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n debian-13/php-nginx-postgresql-setup/01-php.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add debian-13/php-nginx-postgresql-setup/01-php.sh
git commit -m "Extract PHP 8.5 install + FPM tuning into standalone step file"
```

---

### Task 2: Create `02-nginx.sh` (Nginx install)

**Files:**
- Create: `debian-13/php-nginx-postgresql-setup/02-nginx.sh`

**Interfaces:**
- Consumes: nothing (independent of Task 1's output).
- Produces: nothing consumed by other step files.

- [ ] **Step 1: Write the file**

Create `debian-13/php-nginx-postgresql-setup/02-nginx.sh` with exactly this content:

```bash
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n debian-13/php-nginx-postgresql-setup/02-nginx.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add debian-13/php-nginx-postgresql-setup/02-nginx.sh
git commit -m "Extract Nginx install into standalone step file"
```

---

### Task 3: Create `03-postgresql.sh` (PostgreSQL 18 install + auth + tuning)

**Files:**
- Create: `debian-13/php-nginx-postgresql-setup/03-postgresql.sh`

**Interfaces:**
- Consumes: nothing (independent of Tasks 1-2's output).
- Produces: nothing consumed by other step files.

- [ ] **Step 1: Write the file**

Create `debian-13/php-nginx-postgresql-setup/03-postgresql.sh` with exactly this content:

```bash
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
# Install and configure PostgreSQL 18 database server.
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n debian-13/php-nginx-postgresql-setup/03-postgresql.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add debian-13/php-nginx-postgresql-setup/03-postgresql.sh
git commit -m "Extract PostgreSQL 18 install/auth/tuning into standalone step file"
```

---

### Task 4: Create `04-deployer.sh` (deployer user: sudo, SSH key)

**Files:**
- Create: `debian-13/php-nginx-postgresql-setup/04-deployer.sh`

**Interfaces:**
- Consumes: nothing (independent of Tasks 1-3's output). Reads `DEPLOYER_SSH_KEY` from the environment if set, same as today.
- Produces: nothing consumed by other step files.

- [ ] **Step 1: Write the file**

Create `debian-13/php-nginx-postgresql-setup/04-deployer.sh` with exactly this content:

```bash
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
# Create the deployer user with passwordless sudo and SSH key access.
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
# operator added by hand, and should not accumulate duplicates of the same key
# if the comment/options differ between runs.
DEPLOYER_SSH_KEY_TYPE="$(printf '%s\n' "${DEPLOYER_SSH_KEY}" | awk '{print $1}')"
DEPLOYER_SSH_KEY_BLOB="$(printf '%s\n' "${DEPLOYER_SSH_KEY}" | awk '{print $2}')"
DEPLOYER_SSH_KEY_BLOB_RE="${DEPLOYER_SSH_KEY_BLOB//+/\\+}"

if sudo grep -Eq "(^|[[:space:]])${DEPLOYER_SSH_KEY_TYPE}[[:space:]]+${DEPLOYER_SSH_KEY_BLOB_RE}([[:space:]]|$)" "${AUTH_KEYS}"; then
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n debian-13/php-nginx-postgresql-setup/04-deployer.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add debian-13/php-nginx-postgresql-setup/04-deployer.sh
git commit -m "Extract deployer user setup into standalone step file"
```

---

### Task 5: Rewrite the orchestrator (`debian-13/php-nginx-postgresql-setup.sh`)

**Files:**
- Modify: `debian-13/php-nginx-postgresql-setup.sh` (full rewrite — replace entire file content)

**Interfaces:**
- Consumes: the four step files created in Tasks 1-4, located relative to its own path at `php-nginx-postgresql-setup/01-php.sh` through `04-deployer.sh`.
- Produces: nothing (this is the top-level entry point).

- [ ] **Step 1: Replace the file content**

Overwrite `debian-13/php-nginx-postgresql-setup.sh` so its entire content is exactly:

```bash
#!/usr/bin/env bash

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# Every operation in this script needs elevation, so fail before touching
# anything if sudo is unavailable.
if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required but not installed." >&2
	exit 1
fi

# Resolve this script's own directory so the step files below are found
# regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS_DIR="${SCRIPT_DIR}/php-nginx-postgresql-setup"

# Step 1: Install PHP 8.5 and configure FPM for production.
bash "${STEPS_DIR}/01-php.sh"

# Step 2: Install Nginx.
bash "${STEPS_DIR}/02-nginx.sh"

# Step 3: Install and configure PostgreSQL 18.
bash "${STEPS_DIR}/03-postgresql.sh"

# Step 4: Create the deployer user.
bash "${STEPS_DIR}/04-deployer.sh"
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n debian-13/php-nginx-postgresql-setup.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Sanity-check the file count and total line count dropped**

Run: `wc -l debian-13/php-nginx-postgresql-setup.sh debian-13/php-nginx-postgresql-setup/*.sh`
Expected: the orchestrator is short (roughly 20 lines) and the four step files together account for the bulk of the original 421 lines (plus the small repeated preamble in each).

- [ ] **Step 4: Commit**

```bash
git add debian-13/php-nginx-postgresql-setup.sh
git commit -m "Turn php-nginx-postgresql-setup.sh into a thin step orchestrator"
```

---

### Task 6: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the final file layout from Tasks 1-5.
- Produces: nothing (documentation only).

- [ ] **Step 1: Update the repository-layout bullet**

In the `## Repository layout` section, find the bullet that starts with `` `debian-13/php-nginx-postgresql-setup.sh` — one-time base system setup for the PHP/Laravel path. `` and replace its full text (the entire bullet, up to but not including the next `` - `debian-13/nodejs-nginx-postgresql-setup.sh` `` bullet) with:

```markdown
- `debian-13/php-nginx-postgresql-setup.sh` — one-time base system setup for the PHP/Laravel path. Run as a sudo-capable user (not necessarily `deployer`). A thin orchestrator that runs the four standalone step files under `debian-13/php-nginx-postgresql-setup/` in order: `01-php.sh` (PHP 8.5 via Sury APT repo + FPM tuning), `02-nginx.sh` (Nginx), `03-postgresql.sh` (PostgreSQL 18 via PGDG APT repo with localhost TCP `scram-sha-256` auth and production tuning), and `04-deployer.sh` (creates the `deployer` user if absent — adding it to `sudo`, granting passwordless sudo via an `/etc/sudoers.d` drop-in, and installing an SSH key prompted for interactively or taken from `DEPLOYER_SSH_KEY` for unattended runs). Each step file has its own shebang, `set -euo pipefail`, and sudo-availability check, so it can also be run on its own — e.g. `bash debian-13/php-nginx-postgresql-setup/03-postgresql.sh` re-applies PostgreSQL setup/tuning without touching PHP, Nginx, or the deployer account. Does not install Composer — that remains a prerequisite this script assumes is handled separately. This script is intentionally generic — it does not touch any specific application's database.
```

- [ ] **Step 2: Update the `bash -n` verification snippet**

In the `## Working with these scripts` section, replace:

```bash
bash -n debian-13/php-nginx-postgresql-setup.sh
bash -n debian-13/nodejs-nginx-postgresql-setup.sh
bash -n debian-13/atomic-deployment-setup.sh
```

with:

```bash
bash -n debian-13/php-nginx-postgresql-setup.sh
bash -n debian-13/php-nginx-postgresql-setup/01-php.sh
bash -n debian-13/php-nginx-postgresql-setup/02-nginx.sh
bash -n debian-13/php-nginx-postgresql-setup/03-postgresql.sh
bash -n debian-13/php-nginx-postgresql-setup/04-deployer.sh
bash -n debian-13/nodejs-nginx-postgresql-setup.sh
bash -n debian-13/atomic-deployment-setup.sh
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Document the php-nginx-postgresql-setup.sh step-file split"
```

---

### Task 7: Final verification sweep

**Files:** none (verification only)

**Interfaces:** none

- [ ] **Step 1: Syntax-check every script in the repo**

Run:
```bash
bash -n debian-13/php-nginx-postgresql-setup.sh
bash -n debian-13/php-nginx-postgresql-setup/01-php.sh
bash -n debian-13/php-nginx-postgresql-setup/02-nginx.sh
bash -n debian-13/php-nginx-postgresql-setup/03-postgresql.sh
bash -n debian-13/php-nginx-postgresql-setup/04-deployer.sh
bash -n debian-13/nodejs-nginx-postgresql-setup.sh
bash -n debian-13/atomic-deployment-setup.sh
```
Expected: no output from any command, all exit code 0.

- [ ] **Step 2: Confirm no content was lost in the move**

Run this to compare the concatenation of the four new step files' functional content against the original script's line count (accounting for the ~10-line preamble now repeated 4 times, once per file, that wasn't repeated in the original):

```bash
git show 0fadcc8:debian-13/php-nginx-postgresql-setup.sh | wc -l
cat debian-13/php-nginx-postgresql-setup/*.sh | wc -l
```
Expected: the new total is roughly the original 421 lines plus about 30 extra lines (3 added preambles — the 4th step's preamble replaces the original single preamble, so only 3 are net-new), not less. A significantly smaller number indicates dropped content and should be investigated by diffing the relevant step file against `git show 0fadcc8:debian-13/php-nginx-postgresql-setup.sh` directly.

- [ ] **Step 3: Confirm the directory listing matches the design**

Run: `ls debian-13/ debian-13/php-nginx-postgresql-setup/`
Expected (note `php-nginx-postgresql-setup` the directory sorts before `php-nginx-postgresql-setup.sh` the file, since it's a strict prefix of that name):
```
debian-13/:
atomic-deployment-setup.sh
nodejs-nginx-postgresql-setup.sh
php-nginx-postgresql-setup
php-nginx-postgresql-setup.sh

debian-13/php-nginx-postgresql-setup/:
01-php.sh
02-nginx.sh
03-postgresql.sh
04-deployer.sh
```

No commit needed for this task — it's verification only.
