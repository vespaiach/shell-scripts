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
# Install Composer using the official signed installer.
# ****************************************************************************************************

# 08-laravel-deployment.sh requires 'composer' on PATH before it can run, so it
# has to be installed here rather than left to individual site provisioning.
COMPOSER_SETUP="$(mktemp)"
curl -fsSL -o "${COMPOSER_SETUP}" https://getcomposer.org/installer

# Verify the installer against Composer's published signature before executing
# it as PHP -- an unverified installer script is arbitrary code execution.
EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', '${COMPOSER_SETUP}');")"

if [[ "${EXPECTED_SIGNATURE}" != "${ACTUAL_SIGNATURE}" ]]; then
	rm -f "${COMPOSER_SETUP}"
	echo "Composer installer signature mismatch; refusing to run it." >&2
	exit 1
fi

sudo php "${COMPOSER_SETUP}" --install-dir=/usr/local/bin --filename=composer
rm -f "${COMPOSER_SETUP}"

# Verify Composer installation. Exit with an error if Composer is not available.
if command -v composer >/dev/null 2>&1; then
	composer --version
else
	echo "Composer installation check failed: 'composer' not found on PATH." >&2
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
