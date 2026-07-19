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
