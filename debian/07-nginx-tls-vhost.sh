#!/usr/bin/env bash

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# ****************************************************************************************************
# Own the site's Nginx vhost and Let's Encrypt/certbot TLS issuance as a
# standalone, re-runnable step, separate from directory-structure provisioning
# (06-folder-structure.sh) and database provisioning (05-postgresql-database.sh).
#
# Standalone and re-runnable: no dependency on 05-postgresql-database.sh having
# run, and it never touches Postgres. It does depend on 06-folder-structure.sh
# having already created ${BASE_DIR}/current/public -- checked below rather
# than assumed, since a vhost pointed at a webroot that doesn't exist yet would
# only fail later, deep into the certbot request, with a much less obvious
# error. Vhost files are always fully rewritten via temp-file-then-move and
# certbot itself is idempotent, so re-running this script alone is how you
# change the server name, redo the renewal verification, or recover from a
# manually broken vhost.
# ****************************************************************************************************

# Every operation below needs elevation, so fail before prompting for
# anything if sudo is unavailable. Only sudo capability is required -- no
# check on which user is running this script.
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

# Nginx must already be installed and usable because this script writes and enables site config.
if ! sudo nginx -t >/dev/null 2>&1; then
	echo "nginx is not installed or configuration test failed." >&2
	exit 1
fi

# Certbot is required for obtaining the certificate via webroot challenge.
if ! command -v certbot >/dev/null 2>&1; then
	echo "certbot is required for Let's Encrypt webroot setup but is not installed." >&2
	exit 1
fi

echo "Reminder: configure your domain DNS record(s) before running this setup."
echo "Point A/AAAA records to this server first, or Let's Encrypt validation can fail."

# ---- Collect input ----

# Primary site identifier used to locate the webroot and root the vhost.
read -r -p "Site name (example: app.mysite.com): " SITE_NAME

if [[ -z "${SITE_NAME}" ]]; then
	echo "Site name cannot be empty." >&2
	exit 1
fi

# Keep hostname/domain-like values strict since this becomes a path segment.
if [[ ! "${SITE_NAME}" =~ ^[a-zA-Z0-9.-]+$ ]]; then
	echo "Site name can only contain letters, numbers, dots, and hyphens." >&2
	exit 1
fi

# Allow distinct HTTP server_name and certificate domain when needed.
read -r -p "Server name for Nginx (default: ${SITE_NAME}): " SERVER_NAME
SERVER_NAME="${SERVER_NAME:-$SITE_NAME}"

read -r -p "Let's Encrypt certificate domain (default: ${SITE_NAME}): " LE_DOMAIN
LE_DOMAIN="${LE_DOMAIN:-$SITE_NAME}"

if [[ ! "${LE_DOMAIN}" =~ ^[a-zA-Z0-9.-]+$ ]]; then
	echo "Let's Encrypt domain can only contain letters, numbers, dots, and hyphens." >&2
	exit 1
fi

read -r -p "Email for Let's Encrypt notices: " LE_EMAIL

if [[ -z "${LE_EMAIL}" ]]; then
	echo "Let's Encrypt email cannot be empty." >&2
	exit 1
fi

# ---- Derive paths and check the one hard ordering dependency ----

BASE_DIR="/var/www/${SITE_NAME}"
CURRENT_LINK="${BASE_DIR}/current"
SHARED_DIR="${BASE_DIR}/shared"

# The webroot this vhost roots at, and that certbot serves the ACME challenge
# from, must already exist. Fail here with an actionable message rather than
# writing a vhost that points at nothing and letting the certbot request fail
# with a confusing error further down.
if [[ ! -d "${CURRENT_LINK}/public" ]]; then
	echo "${CURRENT_LINK}/public does not exist." >&2
	echo "Run 06-folder-structure.sh for '${SITE_NAME}' first, then re-run this script." >&2
	exit 1
fi

NGINX_AVAILABLE="/etc/nginx/sites-available/${SITE_NAME}.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/${SITE_NAME}.conf"
PHP_FPM_SOCK="/run/php/php8.5-fpm.sock"

# This vhost serves certbot's HTTP-01 challenge, so the certificate domain must
# be a name Nginx routes here -- otherwise the ACME request falls through to the
# default server and validation 404s. It is also the name the issued certificate
# is valid for, so it has to be served by the HTTPS block as well.
SERVER_NAMES="${SERVER_NAME}"
if [[ "${LE_DOMAIN}" != "${SERVER_NAME}" ]]; then
	SERVER_NAMES="${SERVER_NAME} ${LE_DOMAIN}"
fi

# Prefer expected PHP-FPM socket; fall back to first detected socket on system.
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

# ---- Write HTTP-only vhost, enable it, request the certificate ----

echo "Writing Nginx config: ${NGINX_AVAILABLE}"
# Write through a temp file first, then atomically replace destination.
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

# Enable site by linking from sites-available into sites-enabled. mktemp creates
# the file 0600, which survives the move -- reset it to the 0644 convention so
# the vhost is readable to an admin inspecting sites-available as a normal user.
sudo mv "${TMP_NGINX_CONFIG}" "${NGINX_AVAILABLE}"
sudo chmod 644 "${NGINX_AVAILABLE}"
sudo ln -sfn "${NGINX_AVAILABLE}" "${NGINX_ENABLED}"

echo "Testing Nginx configuration..."
# Validate config before any reload to avoid taking down existing traffic.
sudo nginx -t

echo "Reloading Nginx..."
sudo systemctl reload nginx

echo "Requesting Let's Encrypt certificate for ${LE_DOMAIN} using webroot..."
# Webroot mode proves domain control using HTTP challenge files under current/public.
sudo certbot certonly \
	--webroot \
	-w "${CURRENT_LINK}/public" \
	-d "${LE_DOMAIN}" \
	--email "${LE_EMAIL}" \
	--agree-tos \
	--non-interactive

# ---- Rewrite the vhost as HTTP+HTTPS now that the certificate exists ----

echo "Writing HTTPS-enabled Nginx config: ${NGINX_AVAILABLE}"
# Replace the HTTP-only config with a dual-server HTTP+HTTPS configuration.
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

	# Cache static assets aggressively; deploys are content-addressed by release path.
	# Nginx stops inheriting the server-level add_header directives as soon as a
	# location defines one of its own, so the security headers are repeated here
	# or static assets would be served without them.
	location ~* \.(?:css|js|jpg|jpeg|gif|png|webp|svg|ico|ttf|otf|woff|woff2)$ {
		expires 7d;
		access_log off;
		add_header Cache-Control "public, immutable";
		add_header X-Frame-Options "SAMEORIGIN" always;
		add_header X-Content-Type-Options "nosniff" always;
		add_header Referrer-Policy "strict-origin-when-cross-origin" always;
	}

	# Block access to hidden files except the ACME challenge directory.
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

# ---- Verify auto-renewal ----

echo "Verifying Let's Encrypt auto-renewal..."
# Debian's certbot package manages renewal via a systemd timer, not cron --
# a cert nobody renews will silently expire in 90 days, so this still fails the
# run loudly. It records the failure rather than exiting here, though: renewal
# verification is orthogonal to the vhost already being live, and aborting
# mid-check would drop the certbot.timer result on the floor. The recorded
# result is reported and exited on at the very end.
RENEWAL_VERIFIED=1

if ! systemctl is-enabled --quiet certbot.timer; then
	echo "Warning: certbot.timer is not enabled; automatic renewal will not run."
	echo "Enable it with: sudo systemctl enable --now certbot.timer"
	RENEWAL_VERIFIED=0
fi

echo "Running a renewal dry run for ${LE_DOMAIN}..."
# Proves the renewal would actually succeed right now (webroot path, vhost,
# and cert are all still valid) rather than just confirming a schedule exists.
if ! sudo certbot renew --dry-run --cert-name "${LE_DOMAIN}"; then
	echo "Warning: renewal dry run failed for ${LE_DOMAIN}."
	RENEWAL_VERIFIED=0
fi

# ---- Final summary ----

echo "Done."
echo "Site: ${SITE_NAME}"
echo "Nginx server_name: ${SERVER_NAMES}"
echo "Let's Encrypt domain: ${LE_DOMAIN}"
echo "Nginx vhost: ${NGINX_AVAILABLE}"
echo "PHP-FPM socket: ${PHP_FPM_SOCK}"

# The site is fully provisioned either way, but an unverified renewal path
# means the certificate silently expires in 90 days, so this still exits
# non-zero.
if [[ "${RENEWAL_VERIFIED}" -ne 1 ]]; then
	echo
	echo "Setup completed, but Let's Encrypt auto-renewal could not be verified."
	echo "Fix the renewal warnings above before relying on automatic renewal."
	exit 1
fi
