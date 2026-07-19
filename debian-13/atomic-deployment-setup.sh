#!/usr/bin/env bash

set -euo pipefail

if [[ "$(id -un)" != "deployer" ]]; then
	echo "Please run this script as user 'deployer'."
	exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required but not installed."
	exit 1
fi

if ! sudo -n true 2>/dev/null; then
	echo "User 'deployer' needs sudo privileges to complete setup."
	echo "You may be prompted for your sudo password during execution."
	if ! sudo true; then
		echo "Unable to obtain sudo privileges."
		exit 1
	fi
fi

if ! command -v nginx >/dev/null 2>&1; then
	echo "nginx is not installed."
	exit 1
fi

read -r -p "Site name (example: app.mysite.com): " SITE_NAME

if [[ -z "${SITE_NAME}" ]]; then
	echo "Site name cannot be empty."
	exit 1
fi

if [[ ! "${SITE_NAME}" =~ ^[a-zA-Z0-9.-]+$ ]]; then
	echo "Site name can only contain letters, numbers, dots, and hyphens."
	exit 1
fi

read -r -p "Server name for Nginx (default: ${SITE_NAME}): " SERVER_NAME
SERVER_NAME="${SERVER_NAME:-$SITE_NAME}"

BASE_DIR="/var/www/${SITE_NAME}"
RELEASES_DIR="${BASE_DIR}/releases"
SHARED_DIR="${BASE_DIR}/shared"
CURRENT_LINK="${BASE_DIR}/current"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
FIRST_RELEASE_DIR="${RELEASES_DIR}/${TIMESTAMP}"
SHARED_STORAGE_DIR="${SHARED_DIR}/storage"
SHARED_BOOTSTRAP_CACHE_DIR="${SHARED_DIR}/bootstrap/cache"
SHARED_ENV_FILE="${SHARED_DIR}/.env"
WEB_GROUP="www-data"

if ! getent group "${WEB_GROUP}" >/dev/null 2>&1; then
	echo "Required group '${WEB_GROUP}' does not exist."
	echo "Create it or update WEB_GROUP in this script."
	exit 1
fi

echo "Creating atomic deployment structure in ${BASE_DIR}..."
sudo mkdir -p "${RELEASES_DIR}" \
				 "${SHARED_DIR}/logs" \
				 "${SHARED_STORAGE_DIR}/app" \
				 "${SHARED_STORAGE_DIR}/framework/cache" \
				 "${SHARED_STORAGE_DIR}/framework/sessions" \
				 "${SHARED_STORAGE_DIR}/framework/views" \
				 "${SHARED_STORAGE_DIR}/logs" \
				 "${SHARED_BOOTSTRAP_CACHE_DIR}" \
				 "${FIRST_RELEASE_DIR}/public"

sudo touch "${SHARED_ENV_FILE}"
sudo chown -R deployer:"${WEB_GROUP}" "${BASE_DIR}"

if [[ ! -L "${CURRENT_LINK}" ]]; then
	ln -sfn "${FIRST_RELEASE_DIR}" "${CURRENT_LINK}"
fi

mkdir -p "${FIRST_RELEASE_DIR}/bootstrap"

ln -sfn "${SHARED_STORAGE_DIR}" "${FIRST_RELEASE_DIR}/storage"
ln -sfn "${SHARED_BOOTSTRAP_CACHE_DIR}" "${FIRST_RELEASE_DIR}/bootstrap/cache"
ln -sfn "${SHARED_ENV_FILE}" "${FIRST_RELEASE_DIR}/.env"

echo "Setting Laravel directory permissions..."
sudo chmod 755 "${BASE_DIR}" "${RELEASES_DIR}" "${SHARED_DIR}"

if [[ -d "${FIRST_RELEASE_DIR}" ]]; then
	sudo find "${FIRST_RELEASE_DIR}" -type d -exec chmod 755 {} \;
	sudo find "${FIRST_RELEASE_DIR}" -type f -exec chmod 644 {} \;
fi

sudo find "${SHARED_STORAGE_DIR}" -type d -exec chmod 2775 {} \;
sudo find "${SHARED_STORAGE_DIR}" -type f -exec chmod 664 {} \;
sudo find "${SHARED_BOOTSTRAP_CACHE_DIR}" -type d -exec chmod 2775 {} \;
sudo find "${SHARED_BOOTSTRAP_CACHE_DIR}" -type f -exec chmod 664 {} \;
sudo chmod 2775 "${SHARED_DIR}/logs" "${SHARED_STORAGE_DIR}" "${SHARED_BOOTSTRAP_CACHE_DIR}"
sudo chmod 640 "${SHARED_ENV_FILE}"

NGINX_AVAILABLE="/etc/nginx/sites-available/${SITE_NAME}.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/${SITE_NAME}.conf"
PHP_FPM_SOCK="/run/php/php8.5-fpm.sock"

if [[ ! -S "${PHP_FPM_SOCK}" ]]; then
	DETECTED_SOCK="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | head -n 1 || true)"
	if [[ -n "${DETECTED_SOCK}" ]]; then
		PHP_FPM_SOCK="${DETECTED_SOCK}"
	fi
fi

if [[ ! -S "${PHP_FPM_SOCK}" ]]; then
	echo "Warning: could not detect a PHP-FPM socket."
	echo "Nginx config will use ${PHP_FPM_SOCK}. Adjust it if needed."
fi

echo "Writing Nginx config: ${NGINX_AVAILABLE}"
TMP_NGINX_CONFIG="$(mktemp)"
cat > "${TMP_NGINX_CONFIG}" <<EOF
server {
		listen 80;
		listen [::]:80;
		server_name ${SERVER_NAME};
		root ${CURRENT_LINK}/public;
		server_tokens off;

		add_header X-Frame-Options "SAMEORIGIN" always;
		add_header X-Content-Type-Options "nosniff" always;
		add_header Referrer-Policy "strict-origin-when-cross-origin" always;

		index index.php;

		charset utf-8;
		error_page 404 /index.php;

		access_log ${SHARED_DIR}/logs/access.log;
		error_log ${SHARED_DIR}/logs/error.log;

		location / {
				try_files \$uri \$uri/ /index.php?\$query_string;
		}

		location = /favicon.ico { access_log off; log_not_found off; }
		location = /robots.txt  { access_log off; log_not_found off; }

    	location ~ ^/index\.php(/|$) {
				include snippets/fastcgi-php.conf;
				fastcgi_pass unix:${PHP_FPM_SOCK};
				fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
				include fastcgi_params;
				fastcgi_hide_header X-Powered-By;
		}

		location ~ \.php$ {
				return 404;
		}

		location ~* \.(?:css|js|jpg|jpeg|gif|png|webp|svg|ico|ttf|otf|woff|woff2)$ {
				expires 7d;
				access_log off;
				add_header Cache-Control "public, immutable";
		}

		location ~ /\.(?!well-known).* {
				deny all;
		}
}
EOF

sudo mv "${TMP_NGINX_CONFIG}" "${NGINX_AVAILABLE}"
sudo ln -sfn "${NGINX_AVAILABLE}" "${NGINX_ENABLED}"

echo "Testing Nginx configuration..."
sudo nginx -t

echo "Reloading Nginx..."
sudo systemctl reload nginx

echo "Done."
echo "Site: ${SITE_NAME}"
echo "Base directory: ${BASE_DIR}"
echo "Current release: ${FIRST_RELEASE_DIR}"
echo "Nginx server_name: ${SERVER_NAME}"
echo "Shared env file: ${SHARED_ENV_FILE}"
echo "Permission summary:"
sudo stat -c '%a %U:%G %n' "${BASE_DIR}" "${RELEASES_DIR}" "${SHARED_DIR}" "${SHARED_STORAGE_DIR}" "${SHARED_BOOTSTRAP_CACHE_DIR}" "${SHARED_ENV_FILE}"
