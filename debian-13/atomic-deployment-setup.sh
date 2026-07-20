#!/usr/bin/env bash

# Exit on error (-e), undefined variable (-u), and failed pipeline segment (pipefail)
# so partial setup does not proceed silently.
set -euo pipefail

# ===== GROUP 0: Preflight validation =====
# Fail fast on missing preconditions before prompting for any input or
# creating any state, so a misconfigured host is caught immediately
# instead of mid-setup.

# This bootstrap is intentionally constrained to the deployer account to keep
# ownership and permissions predictable for future deployments.
if [[ "$(id -un)" != "deployer" ]]; then
	echo "Please run this script as user 'deployer'."
	exit 1
fi

# Most filesystem and service operations require elevation.
if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required but not installed."
	exit 1
fi

# Validate sudo access up front to fail early instead of mid-setup.
if ! sudo -n true 2>/dev/null; then
	echo "User 'deployer' needs sudo privileges to complete setup."
	echo "You may be prompted for your sudo password during execution."
	if ! sudo true; then
		echo "Unable to obtain sudo privileges."
		exit 1
	fi
fi

# Nginx must already be installed and usable because this script writes and enables site config.
if ! sudo nginx -t >/dev/null 2>&1; then
	echo "nginx is not installed or configuration test failed."
	exit 1
fi

# Certbot is required for obtaining the initial certificate via webroot challenge.
if ! command -v certbot >/dev/null 2>&1; then
	echo "certbot is required for Let's Encrypt webroot setup but is not installed."
	echo "Install certbot and rerun this script."
	exit 1
fi

echo "Reminder: configure your domain DNS record(s) before running this setup."
echo "Point A/AAAA records to this server first, or Let's Encrypt validation can fail."

# ===== Shared helper: set_core_permissions() =====
# Sets the structural permissions Nginx needs to read and serve the current
# release's public/ directory: 755 on the base/releases/shared directories,
# and conventional 755 (dirs) / 644 (files) across the first release tree.
# Called once by Group 2 (right after the structure is created, so Group 3's
# Let's Encrypt webroot challenge can succeed) and again by Group 6 (as part
# of the final, authoritative permission pass) -- kept as one function so
# the two call sites can't drift out of sync.
set_core_permissions() {
	sudo chmod 755 "${BASE_DIR}" "${RELEASES_DIR}" "${SHARED_DIR}"

	if [[ -d "${FIRST_RELEASE_DIR}" ]]; then
		sudo find "${FIRST_RELEASE_DIR}" -type d -exec chmod 755 {} \;
		sudo find "${FIRST_RELEASE_DIR}" -type f -exec chmod 644 {} \;
	fi
}

# ===== GROUP 1: Collect user's input =====
# Gathers everything needed for the rest of the script up front: site
# identity, Nginx/TLS naming, and Laravel database credentials. Validated
# here, before any state is created, so a bad value fails fast rather than
# leaving a half-provisioned site.

# Primary site identifier used for directory layout and default hostnames.
read -r -p "Site name (example: app.mysite.com): " SITE_NAME

if [[ -z "${SITE_NAME}" ]]; then
	echo "Site name cannot be empty."
	exit 1
fi

# Keep hostname/domain-like values strict to avoid invalid Nginx/certbot input.
if [[ ! "${SITE_NAME}" =~ ^[a-zA-Z0-9.-]+$ ]]; then
	echo "Site name can only contain letters, numbers, dots, and hyphens."
	exit 1
fi

# Allow distinct HTTP server_name and certificate domain when needed.
read -r -p "Server name for Nginx (default: ${SITE_NAME}): " SERVER_NAME
SERVER_NAME="${SERVER_NAME:-$SITE_NAME}"

read -r -p "Let's Encrypt certificate domain (default: ${SITE_NAME}): " LE_DOMAIN
LE_DOMAIN="${LE_DOMAIN:-$SITE_NAME}"

if [[ ! "${LE_DOMAIN}" =~ ^[a-zA-Z0-9.-]+$ ]]; then
	echo "Let's Encrypt domain can only contain letters, numbers, dots, and hyphens."
	exit 1
fi

read -r -p "Email for Let's Encrypt notices: " LE_EMAIL

if [[ -z "${LE_EMAIL}" ]]; then
	echo "Let's Encrypt email cannot be empty."
	exit 1
fi

read -r -p "Laravel PostgreSQL database name: " DB_DATABASE

if [[ -z "${DB_DATABASE}" ]]; then
	echo "Database name cannot be empty."
	exit 1
fi

read -r -p "Laravel PostgreSQL username: " DB_USERNAME

if [[ -z "${DB_USERNAME}" ]]; then
	echo "Database username cannot be empty."
	exit 1
fi

read -r -s -p "Laravel PostgreSQL password: " DB_PASSWORD
echo

if [[ -z "${DB_PASSWORD}" ]]; then
	echo "Database password cannot be empty."
	exit 1
fi

if [[ ! "${DB_DATABASE}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
	echo "Database name must start with a letter or underscore and contain only letters, numbers, and underscores."
	exit 1
fi

if [[ ! "${DB_USERNAME}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
	echo "Database username must start with a letter or underscore and contain only letters, numbers, and underscores."
	exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
	echo "psql is required to provision the Laravel database but is not installed."
	exit 1
fi

# ===== GROUP 2: Create atomic deployment structure =====
# Builds the release/shared/current layout documented in CLAUDE.md, and
# provisions the shared .env file that will later hold the Laravel DB_*
# values (Group 5). Only the permissions needed for the rest of this
# script to work are set here -- Nginx (Group 3) must be able to read and
# serve the release's public/ directory during the Let's Encrypt webroot
# challenge, and .env must never sit at default touch permissions even
# while empty. Laravel runtime permissions (storage/, bootstrap/cache/)
# aren't needed until an app is actually deployed, so those are deferred
# to the final permission pass in Group 6.

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

# Web server group must exist so deployed files can be shared with Nginx/PHP-FPM.
if ! getent group "${WEB_GROUP}" >/dev/null 2>&1; then
	echo "Required group '${WEB_GROUP}' does not exist."
	echo "Create it or update WEB_GROUP in this script."
	exit 1
fi

echo "Creating atomic deployment structure in ${BASE_DIR}..."
# Create full directory skeleton, including first empty release public/ path so
# Nginx can serve ACME challenge files immediately.
sudo mkdir -p "${RELEASES_DIR}" \
				 "${SHARED_DIR}/logs" \
				 "${SHARED_STORAGE_DIR}/app" \
				 "${SHARED_STORAGE_DIR}/framework/cache" \
				 "${SHARED_STORAGE_DIR}/framework/sessions" \
				 "${SHARED_STORAGE_DIR}/framework/views" \
				 "${SHARED_STORAGE_DIR}/logs" \
				 "${SHARED_BOOTSTRAP_CACHE_DIR}" \
				 "${FIRST_RELEASE_DIR}/public"

# Ensure shared .env exists, lock it down immediately (even empty, it must
# never sit at default touch permissions), then hand ownership of the whole
# tree to deployer:www-data so the rest of this script can operate without sudo.
sudo touch "${SHARED_ENV_FILE}"
sudo chmod 640 "${SHARED_ENV_FILE}"
sudo chown -R deployer:"${WEB_GROUP}" "${BASE_DIR}"

# Initialize current symlink only if absent (preserves existing deployments).
if [[ ! -L "${CURRENT_LINK}" ]]; then
	ln -sfn "${FIRST_RELEASE_DIR}" "${CURRENT_LINK}"
fi

# Bootstrap tree is commonly expected by Laravel for cache symlink target.
mkdir -p "${FIRST_RELEASE_DIR}/bootstrap"

# Link release-local paths to persistent shared targets.
ln -sfn "${SHARED_STORAGE_DIR}" "${FIRST_RELEASE_DIR}/storage"
ln -sfn "${SHARED_BOOTSTRAP_CACHE_DIR}" "${FIRST_RELEASE_DIR}/bootstrap/cache"
ln -sfn "${SHARED_ENV_FILE}" "${FIRST_RELEASE_DIR}/.env"

echo "Setting core deployment permissions..."
# Nginx (running as www-data) must be able to traverse and read the release's
# public/ directory before Group 3 requests a Let's Encrypt certificate.
set_core_permissions

# ===== GROUP 3: Configure Nginx server and issue Let's Encrypt SSL =====
# Depends on Group 2 having already made current/public readable by
# www-data. Writes an HTTP-only vhost first (so certbot's webroot challenge
# has somewhere to serve the ACME token from), then rewrites it to a dual
# HTTP+HTTPS vhost once the certificate exists.

NGINX_AVAILABLE="/etc/nginx/sites-available/${SITE_NAME}.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/${SITE_NAME}.conf"
PHP_FPM_SOCK="/run/php/php8.5-fpm.sock"

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

echo "Writing Nginx config: ${NGINX_AVAILABLE}"
# Write through a temp file first, then atomically replace destination.
TMP_NGINX_CONFIG="$(mktemp)"
cat > "${TMP_NGINX_CONFIG}" <<EOF
server {
	listen 80;
	listen [::]:80;
	server_name ${SERVER_NAME};
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

# Enable site by linking from sites-available into sites-enabled.
sudo mv "${TMP_NGINX_CONFIG}" "${NGINX_AVAILABLE}"
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

echo "Writing HTTPS-enabled Nginx config: ${NGINX_AVAILABLE}"
# Replace initial HTTP-only config with dual-server HTTP+HTTPS configuration.
TMP_NGINX_SSL_CONFIG="$(mktemp)"
cat > "${TMP_NGINX_SSL_CONFIG}" <<EOF
server {
	listen 80;
	listen [::]:80;
	server_name ${SERVER_NAME};
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
	listen 443 ssl http2;
	listen [::]:443 ssl http2;
	server_name ${SERVER_NAME};
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
	location ~* \.(?:css|js|jpg|jpeg|gif|png|webp|svg|ico|ttf|otf|woff|woff2)$ {
		expires 7d;
		access_log off;
		add_header Cache-Control "public, immutable";
	}

	# Block access to hidden files except ACME challenge directory.
	location ~ /\.(?!well-known).* {
		deny all;
	}
}
EOF

sudo mv "${TMP_NGINX_SSL_CONFIG}" "${NGINX_AVAILABLE}"

echo "Testing Nginx configuration with SSL..."
sudo nginx -t

echo "Reloading Nginx with SSL..."
sudo systemctl reload nginx

# ===== GROUP 4: Create database role, database, and extensions =====
# Independent of Nginx/SSL, so this runs after Group 3 purely to match the
# requested group ordering -- no functional dependency between them.

echo "Provisioning PostgreSQL database ${DB_DATABASE} for role ${DB_USERNAME}..."

sudo -u postgres psql -v ON_ERROR_STOP=1 \
	--set=db_name="${DB_DATABASE}" \
	--set=db_user="${DB_USERNAME}" \
	--set=db_password="${DB_PASSWORD}" <<'SQL'
DO $$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'db_user') THEN
		EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', :'db_user', :'db_password');
	ELSE
		EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'db_user', :'db_password');
	END IF;
END
$$;

SELECT format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8''', :'db_name', :'db_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db_name')
\gexec

SELECT format('ALTER DATABASE %I OWNER TO %I', :'db_name', :'db_user')
\gexec
SQL

sudo -u postgres psql -v ON_ERROR_STOP=1 --dbname="${DB_DATABASE}" <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL

# ===== GROUP 5: Create/update shared .env file =====
# Writes the DB_* values collected in Group 1 and provisioned in Group 4
# into the shared .env file created in Group 2, replacing any prior DB_*
# lines while preserving everything else. Immediately re-locks .env down
# to 640 after rewriting it, since it now holds the plaintext DB password.

escape_env_double_quoted() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	value="${value//\$/\\$}"
	printf '%s' "$value"
}

echo "Updating shared Laravel environment file..."

TMP_ENV_FILE="$(mktemp)"

grep -Ev '^(DB_CONNECTION|DB_HOST|DB_PORT|DB_DATABASE|DB_USERNAME|DB_PASSWORD)=' "${SHARED_ENV_FILE}" > "${TMP_ENV_FILE}" || true

cat <<EOF >> "${TMP_ENV_FILE}"
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD="$(escape_env_double_quoted "${DB_PASSWORD}")"
EOF

mv "${TMP_ENV_FILE}" "${SHARED_ENV_FILE}"
chown deployer:"${WEB_GROUP}" "${SHARED_ENV_FILE}"
chmod 640 "${SHARED_ENV_FILE}"

# ===== GROUP 6: Check and update permissions (final pass) =====
# The authoritative permission pass, run last. Groups 2 and 5 already set
# the minimum permissions needed for Nginx to serve the site and for .env
# to never sit exposed -- this group re-asserts those (catching any drift)
# and, for the first time, sets the Laravel runtime permissions that only
# matter once an application is actually deployed onto this structure.

echo "Performing final permission check and update..."

# Re-assert ownership across the entire deployment tree in case anything drifted.
sudo chown -R deployer:"${WEB_GROUP}" "${BASE_DIR}"

# Re-assert the core structural permissions set in Group 2.
set_core_permissions

# Shared writable runtime paths use setgid (2xxx) so new files inherit web group.
# Not required for this script's own execution, so it's deferred here.
sudo find "${SHARED_STORAGE_DIR}" -type d -exec chmod 2775 {} \;
sudo find "${SHARED_STORAGE_DIR}" -type f -exec chmod 664 {} \;
sudo find "${SHARED_BOOTSTRAP_CACHE_DIR}" -type d -exec chmod 2775 {} \;
sudo find "${SHARED_BOOTSTRAP_CACHE_DIR}" -type f -exec chmod 664 {} \;
sudo chmod 2775 "${SHARED_DIR}/logs" "${SHARED_STORAGE_DIR}" "${SHARED_BOOTSTRAP_CACHE_DIR}"

# .env holds the plaintext DB password -- keep it owner/group readable only.
sudo chmod 640 "${SHARED_ENV_FILE}"

# Final setup summary for quick verification and handoff notes.
echo "Done."
echo "Site: ${SITE_NAME}"
echo "Base directory: ${BASE_DIR}"
echo "Current release: ${FIRST_RELEASE_DIR}"
echo "Nginx server_name: ${SERVER_NAME}"
echo "Let's Encrypt domain: ${LE_DOMAIN}"
echo "Laravel database: ${DB_DATABASE}"
echo "Laravel database user: ${DB_USERNAME}"
echo "Shared env file: ${SHARED_ENV_FILE}"
echo "Permission summary:"
sudo stat -c '%a %U:%G %n' "${BASE_DIR}" "${RELEASES_DIR}" "${SHARED_DIR}" "${SHARED_STORAGE_DIR}" "${SHARED_BOOTSTRAP_CACHE_DIR}" "${SHARED_ENV_FILE}"
