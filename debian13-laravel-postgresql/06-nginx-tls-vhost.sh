#!/usr/bin/env bash
#
# Summary: Writes the site's Nginx vhost and issues a Let's Encrypt/certbot TLS certificate.
#   First writes an HTTP-only vhost (for the ACME challenge), requests the certificate via
#   certbot webroot, then rewrites the vhost again with a full HTTPS server block (TLS 1.2/1.3,
#   security headers, static-asset caching, PHP-FPM fastcgi_pass), and finally verifies certbot
#   auto-renewal. Standalone and re-runnable; hard precondition is that
#   05-folders-permissions-env.sh has already run (current/public must exist).
# Input:   Interactive prompts for site name, Nginx server name (default: site name), Let's
#          Encrypt domain (default: site name, validated hostname), and an email for Let's
#          Encrypt notices.
# Output:  /etc/nginx/sites-available/<site>.conf (enabled) serving TLS traffic, plus a live
#          certificate under /etc/letsencrypt/live/<domain>. Exits non-zero if renewal could
#          not be verified, even though setup itself completed.

set -euo pipefail


if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required but not installed." >&2
	exit 1
fi

if ! sudo -n true 2>/dev/null; then
	echo "This script needs sudo privileges to complete setup."
	echo "You may be prompted for your sudo password during execution."
	if ! sudo true; then
		echo "Unable to obtain sudo privileges." >&2
		exit 1
	fi
fi

if ! sudo nginx -t >/dev/null 2>&1; then
	echo "nginx is not installed or configuration test failed." >&2
	exit 1
fi

if ! command -v certbot >/dev/null 2>&1; then
	echo "certbot is required for Let's Encrypt webroot setup but is not installed." >&2
	exit 1
fi

echo "Reminder: configure your domain DNS record(s) before running this setup."
echo "Point A/AAAA records to this server first, or Let's Encrypt validation can fail."

is_valid_hostname() {
	[[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}


read -r -p "Site name (e.g., app.mysite.com): " SITE_NAME

BASE_DIR="/var/www/${SITE_NAME}"
CURRENT_LINK="${BASE_DIR}/current"
SHARED_DIR="${BASE_DIR}/shared"

read -r -p "Server name for Nginx (default: ${SITE_NAME}): " SERVER_NAME
SERVER_NAME="${SERVER_NAME:-$SITE_NAME}"

read -r -p "Let's Encrypt certificate domain (default: ${SITE_NAME}): " LE_DOMAIN
LE_DOMAIN="${LE_DOMAIN:-$SITE_NAME}"

if ! is_valid_hostname "${LE_DOMAIN}"; then
	echo "Let's Encrypt domain must be a hostname: dot-separated labels of letters, numbers, and inner hyphens (example: app.mysite.com)." >&2
	exit 1
fi

read -r -p "Email for Let's Encrypt notices: " LE_EMAIL

if [[ -z "${LE_EMAIL}" ]]; then
	echo "Let's Encrypt email cannot be empty." >&2
	exit 1
fi


if [[ ! -d "${CURRENT_LINK}/public" ]]; then
	echo "${CURRENT_LINK}/public does not exist." >&2
	echo "Run 05-folder-structure.sh for '${SITE_NAME}' first, then re-run this script." >&2
	exit 1
fi

NGINX_AVAILABLE="/etc/nginx/sites-available/${SITE_NAME}.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/${SITE_NAME}.conf"
PHP_FPM_SOCK="/run/php/php8.5-fpm.sock"

SERVER_NAMES="${SERVER_NAME}"
if [[ "${LE_DOMAIN}" != "${SERVER_NAME}" ]]; then
	SERVER_NAMES="${SERVER_NAME} ${LE_DOMAIN}"
fi

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
	server_name ${SERVER_NAMES};
	root ${CURRENT_LINK}/public;
	server_tokens off;

	access_log ${SHARED_DIR}/logs/access.log;
	error_log ${SHARED_DIR}/logs/error.log;

	location ^~ /.well-known/acme-challenge/ {
		default_type "text/plain";
		allow all;
		try_files \$uri =404;
	}

	location / {
		return 301 https://\$host\$request_uri;
	}
}
EOF

sudo mv "${TMP_NGINX_CONFIG}" "${NGINX_AVAILABLE}"
sudo chmod 644 "${NGINX_AVAILABLE}"
sudo ln -sfn "${NGINX_AVAILABLE}" "${NGINX_ENABLED}"

echo "Testing Nginx configuration..."
sudo nginx -t

echo "Reloading Nginx..."
sudo systemctl reload nginx

echo "Requesting Let's Encrypt certificate for ${LE_DOMAIN} using webroot..."
sudo certbot certonly \
	--webroot \
	-w "${CURRENT_LINK}/public" \
	-d "${LE_DOMAIN}" \
	--email "${LE_EMAIL}" \
	--agree-tos \
	--non-interactive


echo "Writing HTTPS-enabled Nginx config: ${NGINX_AVAILABLE}"
TMP_NGINX_SSL_CONFIG="$(mktemp)"
cat > "${TMP_NGINX_SSL_CONFIG}" <<EOF
server {
	listen 80;
	listen [::]:80;
	server_name ${SERVER_NAMES};
	root ${CURRENT_LINK}/public;
	server_tokens off;

	access_log ${SHARED_DIR}/logs/access.log;
	error_log ${SHARED_DIR}/logs/error.log;

	location ^~ /.well-known/acme-challenge/ {
		default_type "text/plain";
		allow all;
		try_files \$uri =404;
	}

	location / {
		return 301 https://\$host\$request_uri;
	}
}

server {
	listen 443 ssl;
	listen [::]:443 ssl;
	http2 on;
	server_name ${SERVER_NAMES};
	root ${CURRENT_LINK}/public;
	server_tokens off;

	ssl_certificate /etc/letsencrypt/live/${LE_DOMAIN}/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/${LE_DOMAIN}/privkey.pem;
	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_prefer_server_ciphers off;

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
		add_header X-Frame-Options "SAMEORIGIN" always;
		add_header X-Content-Type-Options "nosniff" always;
		add_header Referrer-Policy "strict-origin-when-cross-origin" always;
	}

	location ~ /\.(?!well-known).* {
		deny all;
	}
}
EOF

sudo mv "${TMP_NGINX_SSL_CONFIG}" "${NGINX_AVAILABLE}"
sudo chmod 644 "${NGINX_AVAILABLE}"

echo "Testing Nginx configuration with SSL..."
sudo nginx -t

echo "Reloading Nginx with SSL..."
sudo systemctl reload nginx


echo "Verifying Let's Encrypt auto-renewal..."
RENEWAL_VERIFIED=1

if ! systemctl is-enabled --quiet certbot.timer; then
	echo "Warning: certbot.timer is not enabled; automatic renewal will not run."
	echo "Enable it with: sudo systemctl enable --now certbot.timer"
	RENEWAL_VERIFIED=0
fi

echo "Running a renewal dry run for ${LE_DOMAIN}..."
if ! sudo certbot renew --dry-run --cert-name "${LE_DOMAIN}"; then
	echo "Warning: renewal dry run failed for ${LE_DOMAIN}."
	RENEWAL_VERIFIED=0
fi


echo "Done."
echo "Site: ${SITE_NAME}"
echo "Nginx server_name: ${SERVER_NAMES}"
echo "Let's Encrypt domain: ${LE_DOMAIN}"
echo "Nginx vhost: ${NGINX_AVAILABLE}"
echo "PHP-FPM socket: ${PHP_FPM_SOCK}"

if [[ "${RENEWAL_VERIFIED}" -ne 1 ]]; then
	echo
	echo "Setup completed, but Let's Encrypt auto-renewal could not be verified."
	echo "Fix the renewal warnings above before relying on automatic renewal."
	exit 1
fi
