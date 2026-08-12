#!/usr/bin/env bash
#
# Summary: Builds the atomic release/shared/current Laravel directory layout under
#   /var/www/<site>, generates a shared .env from an inline template (fresh APP_KEY, DB
#   placeholders) if one doesn't exist, symlinks storage/bootstrap-cache/.env into the release,
#   and applies the full ownership/permission pass. If 'current' already points at a real
#   release, adopts it and just reconverges .env/permissions instead of minting a new release.
#   Standalone and re-runnable; never touches Postgres itself.
# Input:   Interactive prompts for site name (validated hostname) and APP_NAME.
# Output:  Directory tree, shared .env, and 'current' symlink under /var/www/<site>, plus a
#          printed permission summary.

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

WEB_GROUP="www-data"

if ! getent group "${WEB_GROUP}" >/dev/null 2>&1; then
	echo "Required group '${WEB_GROUP}' does not exist." >&2
	echo "Create it or update WEB_GROUP in this script." >&2
	exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
	echo "openssl is required to generate APP_KEY but is not installed." >&2
	exit 1
fi

is_valid_hostname() {
	[[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}


read -r -p "Site name (example: app.mysite.com): " SITE_NAME

if [[ -z "${SITE_NAME}" ]]; then
	echo "Site name cannot be empty." >&2
	exit 1
fi

if ! is_valid_hostname "${SITE_NAME}"; then
	echo "Site name must be a hostname: dot-separated labels of letters, numbers, and inner hyphens (example: app.mysite.com)." >&2
	exit 1
fi

read -r -p "Application name (APP_NAME): " APP_NAME

if [[ -z "${APP_NAME}" ]]; then
	echo "Application name cannot be empty." >&2
	exit 1
fi


BASE_DIR="/var/www/${SITE_NAME}"
RELEASES_DIR="${BASE_DIR}/releases"
SHARED_DIR="${BASE_DIR}/shared"
CURRENT_LINK="${BASE_DIR}/current"
SHARED_STORAGE_DIR="${SHARED_DIR}/storage"
SHARED_BOOTSTRAP_CACHE_DIR="${SHARED_DIR}/bootstrap/cache"
SHARED_ENV_FILE="${SHARED_DIR}/.env"


APP_URL="https://${SITE_NAME}"

APP_KEY="base64:$(openssl rand -base64 32)"


if [[ -e "${CURRENT_LINK}" && ! -L "${CURRENT_LINK}" ]]; then
	echo "${CURRENT_LINK} exists but is not a symlink." >&2
	echo "Move it aside before running this script." >&2
	exit 1
fi

if [[ -L "${CURRENT_LINK}" && -d "${CURRENT_LINK}" ]]; then
	ADOPTED_EXISTING_RELEASE=1
	ACTIVE_RELEASE_DIR="$(cd "${CURRENT_LINK}" && pwd -P)"
	echo "Existing deployment detected; adopting current release ${ACTIVE_RELEASE_DIR}."
else
	ADOPTED_EXISTING_RELEASE=0
	ACTIVE_RELEASE_DIR="${RELEASES_DIR}/$(date +%Y%m%d%H%M%S)"
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
				 "${ACTIVE_RELEASE_DIR}/public"

if [[ ! -e "${SHARED_ENV_FILE}" ]]; then
	ENV_TEMPLATE_CONTENT="$(cat <<'ENV_TEMPLATE'
APP_NAME={{APP_NAME}}
APP_ENV=production
APP_KEY={{APP_KEY}}
APP_DEBUG=false
APP_URL={{APP_URL}}

APP_LOCALE=en
APP_FALLBACK_LOCALE=en
APP_FAKER_LOCALE=en_US

APP_MAINTENANCE_DRIVER=file

BCRYPT_ROUNDS=12

REGISTRATION_LINK_TTL=1440

LOG_CHANNEL=stack
LOG_STACK=single
LOG_DEPRECATIONS_CHANNEL=null
LOG_LEVEL=debug

DB_CONNECTION=pgsql
DB_HOST={{DB_HOST}}
DB_PORT=5432
DB_DATABASE={{DB_DATABASE}}
DB_USERNAME={{DB_USERNAME}}
DB_PASSWORD={{DB_PASSWORD}}

SESSION_DRIVER=database
SESSION_LIFETIME=120
SESSION_ENCRYPT=false
SESSION_PATH=/
SESSION_DOMAIN=null

BROADCAST_CONNECTION=log
FILESYSTEM_DISK=local
QUEUE_CONNECTION=database

CACHE_STORE=file

MEMCACHED_HOST=

REDIS_CLIENT=
REDIS_HOST=
REDIS_PASSWORD=
REDIS_PORT=

MAIL_MAILER=smtp
MAIL_HOST={{MAIL_HOST}}
MAIL_PORT={{MAIL_PORT}}
MAIL_USERNAME={{MAIL_USERNAME}}
MAIL_PASSWORD={{MAIL_PASSWORD}}
MAIL_ENCRYPTION={{MAIL_ENCRYPTION}}
MAIL_FROM_ADDRESS="{{MAIL_FROM_ADDRESS}}"
MAIL_FROM_NAME="${APP_NAME}"

AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_DEFAULT_REGION=
AWS_BUCKET=
AWS_USE_PATH_STYLE_ENDPOINT=

VITE_APP_NAME="${APP_NAME}"
ENV_TEMPLATE
)"

	APP_NAME="${APP_NAME}" \
	APP_KEY="${APP_KEY}" \
	APP_URL="${APP_URL}" \
	DB_HOST="localhost" \
	awk '
		BEGIN {
			n = split("APP_NAME APP_KEY APP_URL DB_HOST", keys, " ")
		}
		{
			replaced = 0
			for (i = 1; i <= n; i++) {
				k = keys[i]
				if (index($0, k "=") == 1) {
					print k "=" ENVIRON[k]
					replaced = 1
					break
				}
			}
			if (!replaced) print $0
		}
	' <<<"${ENV_TEMPLATE_CONTENT}" | sudo tee "${SHARED_ENV_FILE}" >/dev/null
fi
sudo chmod 640 "${SHARED_ENV_FILE}"
sudo chown -R deployer:"${WEB_GROUP}" "${BASE_DIR}"

if [[ "${ADOPTED_EXISTING_RELEASE}" -eq 0 ]]; then
	sudo ln -sfn "${ACTIVE_RELEASE_DIR}" "${CURRENT_LINK}"

	sudo mkdir -p "${ACTIVE_RELEASE_DIR}/bootstrap"

	sudo ln -sfn "${SHARED_STORAGE_DIR}" "${ACTIVE_RELEASE_DIR}/storage"
	sudo ln -sfn "${SHARED_BOOTSTRAP_CACHE_DIR}" "${ACTIVE_RELEASE_DIR}/bootstrap/cache"
	sudo ln -sfn "${SHARED_ENV_FILE}" "${ACTIVE_RELEASE_DIR}/.env"
fi


echo "Performing final permission check and update..."

sudo chown -R deployer:"${WEB_GROUP}" "${BASE_DIR}"

sudo chmod 755 "${BASE_DIR}" "${RELEASES_DIR}" "${SHARED_DIR}"
sudo find "${ACTIVE_RELEASE_DIR}" -type d -exec chmod 755 {} \;
sudo find "${ACTIVE_RELEASE_DIR}" -type f -exec chmod 644 {} \;

sudo find "${SHARED_STORAGE_DIR}" -type d -exec chmod 2775 {} \;
sudo find "${SHARED_STORAGE_DIR}" -type f -exec chmod 664 {} \;
sudo find "${SHARED_BOOTSTRAP_CACHE_DIR}" -type d -exec chmod 2775 {} \;
sudo find "${SHARED_BOOTSTRAP_CACHE_DIR}" -type f -exec chmod 664 {} \;
sudo chmod 2775 "${SHARED_DIR}/logs" "${SHARED_STORAGE_DIR}" "${SHARED_BOOTSTRAP_CACHE_DIR}"

sudo chmod 640 "${SHARED_ENV_FILE}"

echo "Done."
echo "Site: ${SITE_NAME}"
echo "Base directory: ${BASE_DIR}"
echo "Current release: ${ACTIVE_RELEASE_DIR}"
echo "Shared env file: ${SHARED_ENV_FILE}"
echo "Permission summary:"
sudo stat -c '%a %U:%G %n' "${BASE_DIR}" "${RELEASES_DIR}" "${SHARED_DIR}" "${SHARED_STORAGE_DIR}" "${SHARED_BOOTSTRAP_CACHE_DIR}" "${SHARED_ENV_FILE}"
