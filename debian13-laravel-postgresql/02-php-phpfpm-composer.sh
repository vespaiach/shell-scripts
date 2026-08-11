#!/usr/bin/env bash
#
# Summary: Installs PHP + PHP-FPM and common extensions from the Sury APT repository, installs
#   Composer via its signature-verified installer, and applies production PHP-FPM limits
#   (memory/upload sizes) and pool tuning (dynamic process manager sizing).
# Input:   Optional positional arg <php-version>, defaults to 8.5. Requires 'gpg' to be present
#          (installed by 01-packages-deployer-ssh.sh).
# Output:  php<version>-fpm running and active with a verified socket, Composer on PATH, and
#          /etc/php/<version>/fpm/conf.d/99-production-limits.ini +
#          .../pool.d/99-www-production-pm.conf written.

set -euo pipefail

if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required but not installed." >&2
	exit 1
fi

if ! command -v gpg >/dev/null 2>&1; then
	echo "gpg is required but not installed; run 01-packages-deployer.sh first, or 'sudo apt install -y gpg'." >&2
	exit 1
fi

PHP_VERSION="${1:-8.5}"


SURY_KEYRING="$(mktemp)"
curl -fsSL -o "${SURY_KEYRING}" https://packages.sury.org/php/apt.gpg

if ! gpg --show-keys --with-colons "${SURY_KEYRING}" >/dev/null 2>&1; then
	rm -f "${SURY_KEYRING}"
	echo "Downloaded Sury signing key is not a valid OpenPGP keyring; refusing to install it." >&2
	exit 1
fi

sudo install -m 0644 -o root -g root "${SURY_KEYRING}" /usr/share/keyrings/sury-php.gpg
rm -f "${SURY_KEYRING}"

echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/sury-php.list

sudo apt update

sudo apt install -y php${PHP_VERSION} php${PHP_VERSION}-cli php${PHP_VERSION}-common

sudo apt install -y php${PHP_VERSION}-{fpm,mysql,curl,mbstring,xml,zip,gd,intl}

sudo apt install -y php${PHP_VERSION}-pgsql php${PHP_VERSION}-bcmath

if php -v > /dev/null 2>&1; then
	php -v
else
	echo "PHP installation check failed: 'php -v' returned an error." >&2
	exit 1
fi

if systemctl is-active --quiet php${PHP_VERSION}-fpm; then
	echo "php${PHP_VERSION}-fpm is active."
else
	echo "PHP-FPM check failed: php${PHP_VERSION}-fpm service is not active." >&2
	exit 1
fi

if [ -S /run/php/php${PHP_VERSION}-fpm.sock ]; then
	echo "php${PHP_VERSION}-fpm socket exists: /run/php/php${PHP_VERSION}-fpm.sock"
else
	echo "PHP-FPM socket check failed: /run/php/php${PHP_VERSION}-fpm.sock not found." >&2
	exit 1
fi


COMPOSER_SETUP="$(mktemp)"
curl -fsSL -o "${COMPOSER_SETUP}" https://getcomposer.org/installer

EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', '${COMPOSER_SETUP}');")"

if [[ "${EXPECTED_SIGNATURE}" != "${ACTUAL_SIGNATURE}" ]]; then
	rm -f "${COMPOSER_SETUP}"
	echo "Composer installer signature mismatch; refusing to run it." >&2
	exit 1
fi

sudo php "${COMPOSER_SETUP}" --install-dir=/usr/local/bin --filename=composer
rm -f "${COMPOSER_SETUP}"

if command -v composer >/dev/null 2>&1; then
	composer --version
else
	echo "Composer installation check failed: 'composer' not found on PATH." >&2
	exit 1
fi


PHP_FPM_LIMITS_INI="/etc/php/${PHP_VERSION}/fpm/conf.d/99-production-limits.ini"

cat <<'EOF' | sudo tee "$PHP_FPM_LIMITS_INI" > /dev/null
; Custom production limits for PHP-FPM
memory_limit = 512M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 120
max_input_time = 120
EOF

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

sudo systemctl restart php${PHP_VERSION}-fpm

if systemctl is-active --quiet php${PHP_VERSION}-fpm; then
	echo "php${PHP_VERSION}-fpm restarted with production PHP limits and pool tuning."
else
	echo "PHP-FPM restart failed after applying production limits and pool tuning." >&2
	exit 1
fi
