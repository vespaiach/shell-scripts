# Parameterize PHP version in 01-php.sh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `debian-13/php-nginx-postgresql-setup/01-php.sh` install a caller-chosen PHP version instead of a version hardcoded to 8.5.

**Architecture:** Add `PHP_VERSION="${1:-8.5}"` right after the existing sudo-availability check, then replace every hardcoded `8.5` in the file with `${PHP_VERSION}` (package names, service/socket names, and the two `/etc/php/8.5/...` config paths). Reword the handful of comments that name "PHP 8.5" as fixed text so they stay accurate now that the version is a runtime value.

**Tech Stack:** Bash (`set -euo pipefail`), apt, systemctl.

## Global Constraints

- Scope is `debian-13/php-nginx-postgresql-setup/01-php.sh` and its `CLAUDE.md` description only. Do not modify `php-nginx-postgresql-setup.sh` (orchestrator), `atomic-deployment-setup.sh`, `02-nginx.sh`, `03-postgresql.sh`, or `04-deployer.sh`.
- The orchestrator keeps invoking `01-php.sh` with no arguments — it must continue to work unmodified and install PHP 8.5 by default.
- No format validation of the version argument — an invalid value should surface naturally as an `apt install` (or later) failure under `set -euo pipefail`, exactly as an invalid hardcoded value would today.
- No other behavioral change: package list, FPM tuning values, verification logic, and control flow stay exactly as they are today, only the version becomes a variable.
- Verification is `bash -n debian-13/php-nginx-postgresql-setup/01-php.sh` — no other build/lint/test tooling exists in this repo.

---

### Task 1: Parameterize the PHP version in 01-php.sh

**Files:**
- Modify: `debian-13/php-nginx-postgresql-setup/01-php.sh` (full rewrite below)
- Modify: `CLAUDE.md:11`

**Interfaces:**
- Produces: `01-php.sh` now accepts an optional first positional argument (PHP version, e.g. `8.4`); `PHP_VERSION` shell variable, defaulting to `8.5` via `${1:-8.5}`. No other script consumes this — the orchestrator calls `01-php.sh` with zero arguments and relies on the default.

- [ ] **Step 1: Replace the full contents of `01-php.sh`**

Replace the entire file with this content (byte-for-byte, including the leading tab indentation inside the `if` blocks — copy exactly):

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

# PHP version to install, e.g. "8.4". Defaults to 8.5 when not given.
PHP_VERSION="${1:-8.5}"

# ****************************************************************************************************
# Install PHP and its common extensions from the Sury repository.
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

# php${PHP_VERSION}: the main PHP runtime package.
# php${PHP_VERSION}-cli: command-line interface used to run PHP scripts, cron jobs, and tools like Composer.
# php${PHP_VERSION}-common: shared core files/modules required by most PHP packages.
# Install core PHP packages.
sudo apt install -y php${PHP_VERSION} php${PHP_VERSION}-cli php${PHP_VERSION}-common

# Install common PHP extensions.
sudo apt install -y php${PHP_VERSION}-{fpm,mysql,curl,mbstring,xml,zip,gd,intl}

# php${PHP_VERSION}-bcmath: arbitrary precision math support for accurate decimal/big-number calculations.
# Install additional PHP extensions.
sudo apt install -y php${PHP_VERSION}-pgsql php${PHP_VERSION}-bcmath

# Verify PHP installation. Exit with an error if PHP is not available.
if php -v > /dev/null 2>&1; then
	# Print version details when verification succeeds.
	php -v
else
	echo "PHP installation check failed: 'php -v' returned an error." >&2
	exit 1
fi

# Verify PHP-FPM service is running for PHP request processing via Nginx.
if systemctl is-active --quiet php${PHP_VERSION}-fpm; then
	echo "php${PHP_VERSION}-fpm is active."
else
	echo "PHP-FPM check failed: php${PHP_VERSION}-fpm service is not active." >&2
	exit 1
fi

# Verify the PHP-FPM Unix socket exists.
if [ -S /run/php/php${PHP_VERSION}-fpm.sock ]; then
	echo "php${PHP_VERSION}-fpm socket exists: /run/php/php${PHP_VERSION}-fpm.sock"
else
	echo "PHP-FPM socket check failed: /run/php/php${PHP_VERSION}-fpm.sock not found." >&2
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
PHP_FPM_LIMITS_INI="/etc/php/${PHP_VERSION}/fpm/conf.d/99-production-limits.ini"

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
PHP_FPM_POOL_PM_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/99-www-production-pm.conf"

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
sudo systemctl restart php${PHP_VERSION}-fpm

if systemctl is-active --quiet php${PHP_VERSION}-fpm; then
	echo "php${PHP_VERSION}-fpm restarted with production PHP limits and pool tuning."
else
	echo "PHP-FPM restart failed after applying production limits and pool tuning." >&2
	exit 1
fi
```

- [ ] **Step 2: Syntax-check the rewritten file**

Run: `bash -n debian-13/php-nginx-postgresql-setup/01-php.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Update the `CLAUDE.md` description of `01-php.sh`**

In `CLAUDE.md`, on the line describing the repository layout (currently line 11), find this exact substring:

```
`01-php.sh` (PHP 8.5 via Sury APT repo + FPM tuning), `02-nginx.sh`
```

Replace it with:

```
`01-php.sh` (PHP via Sury APT repo + FPM tuning; accepts an optional PHP version as its first argument — e.g. `bash 01-php.sh 8.4` — defaulting to `8.5` when omitted), `02-nginx.sh`
```

- [ ] **Step 4: Commit**

```bash
git add debian-13/php-nginx-postgresql-setup/01-php.sh CLAUDE.md
git commit -m "$(cat <<'EOF'
Parameterize PHP version in 01-php.sh

01-php.sh now takes an optional PHP version as its first positional
argument, defaulting to 8.5 when omitted, instead of hardcoding 8.5
throughout the script.
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage:** All spec requirements (positional arg with 8.5 default, all ten interpolation sites, comment rewording, no validation, orchestrator/atomic-deployment-setup.sh untouched, CLAUDE.md note) are covered by Task 1's full-file replacement and CLAUDE.md edit.
- **Scope:** Single task — the script rewrite and its doc line are one deliverable; no reason to split them across separate reviewer gates.
- **Out of scope reminder for the implementer:** do not touch the orchestrator or `atomic-deployment-setup.sh`, even though grep will show `atomic-deployment-setup.sh:246` also hardcodes `php8.5-fpm.sock` — that mismatch is a known, accepted gap per the spec's Out of Scope section.
