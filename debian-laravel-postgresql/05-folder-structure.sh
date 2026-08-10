#!/usr/bin/env bash

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# ****************************************************************************************************
# Create the atomic release/shared/current directory layout, the Laravel-specific
# storage/bootstrap-cache structure, the shared .env file, and the full
# permission model for a site.
#
# Standalone and re-runnable: no dependency on nginx-tls-setup.sh or
# database-setup.sh having run, and this script never touches Postgres itself.
# Re-running against a site that already has a live deployment adopts the
# release current/ points at instead of minting a new one or refusing to run,
# then re-applies the permission pass -- so repeated runs converge on the same
# result rather than failing or duplicating state.
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

WEB_GROUP="www-data"

# Web server group must exist so deployed files can be shared with Nginx/PHP-FPM.
if ! getent group "${WEB_GROUP}" >/dev/null 2>&1; then
	echo "Required group '${WEB_GROUP}' does not exist." >&2
	echo "Create it or update WEB_GROUP in this script." >&2
	exit 1
fi

# ---- Collect input ----

# Primary site identifier used for the directory layout.
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

# ---- Derive paths ----

BASE_DIR="/var/www/${SITE_NAME}"
RELEASES_DIR="${BASE_DIR}/releases"
SHARED_DIR="${BASE_DIR}/shared"
CURRENT_LINK="${BASE_DIR}/current"
SHARED_STORAGE_DIR="${SHARED_DIR}/storage"
SHARED_BOOTSTRAP_CACHE_DIR="${SHARED_DIR}/bootstrap/cache"
SHARED_ENV_FILE="${SHARED_DIR}/.env"

# ---- Create, or adopt, the release structure ----

# A non-symlink at current/ is not a layout this script can safely converge:
# 'ln -sfn' does not overwrite a real directory, it silently creates the link
# *inside* it, leaving current/ still not pointing at a release.
if [[ -e "${CURRENT_LINK}" && ! -L "${CURRENT_LINK}" ]]; then
	echo "${CURRENT_LINK} exists but is not a symlink." >&2
	echo "Move it aside before running this script." >&2
	exit 1
fi

# Re-running against a site that already has a live deployment must not mint an
# orphan release directory or repoint current/. Adopt whatever current/
# resolves to instead, so the permission pass below applies to the release
# actually being served. A dangling current/ counts as no deployment and is
# repointed below like a fresh site.
if [[ -L "${CURRENT_LINK}" && -d "${CURRENT_LINK}" ]]; then
	ADOPTED_EXISTING_RELEASE=1
	ACTIVE_RELEASE_DIR="$(cd "${CURRENT_LINK}" && pwd -P)"
	echo "Existing deployment detected; adopting current release ${ACTIVE_RELEASE_DIR}."
else
	ADOPTED_EXISTING_RELEASE=0
	ACTIVE_RELEASE_DIR="${RELEASES_DIR}/$(date +%Y%m%d%H%M%S)"
fi

echo "Creating atomic deployment structure in ${BASE_DIR}..."
# mkdir -p is a no-op on directories that already exist, so this converges
# whether or not the release was just adopted.
sudo mkdir -p "${RELEASES_DIR}" \
				 "${SHARED_DIR}/logs" \
				 "${SHARED_STORAGE_DIR}/app" \
				 "${SHARED_STORAGE_DIR}/framework/cache" \
				 "${SHARED_STORAGE_DIR}/framework/sessions" \
				 "${SHARED_STORAGE_DIR}/framework/views" \
				 "${SHARED_STORAGE_DIR}/logs" \
				 "${SHARED_BOOTSTRAP_CACHE_DIR}" \
				 "${ACTIVE_RELEASE_DIR}/public"

# Seed the shared .env with a bare template on first creation only -- an
# existing .env may already hold real secrets from a prior run, so a rerun
# must never overwrite its content. Placeholders (e.g. {{APP_KEY}}) are left
# for the deployer to fill in by hand; this script does no substitution.
if [[ ! -e "${SHARED_ENV_FILE}" ]]; then
	sudo tee "${SHARED_ENV_FILE}" >/dev/null <<'ENV_TEMPLATE'
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
fi
sudo chmod 640 "${SHARED_ENV_FILE}"
sudo chown -R deployer:"${WEB_GROUP}" "${BASE_DIR}"

# Point current/ at this run's release and wire its release-local paths to the
# shared tree. Skipped entirely when an existing deployment was adopted: that
# release is live and already wired, and blindly re-linking over a real
# directory would nest the symlink inside it rather than replace it.
if [[ "${ADOPTED_EXISTING_RELEASE}" -eq 0 ]]; then
	sudo ln -sfn "${ACTIVE_RELEASE_DIR}" "${CURRENT_LINK}"

	# Bootstrap tree is commonly expected by Laravel for cache symlink target.
	sudo mkdir -p "${ACTIVE_RELEASE_DIR}/bootstrap"

	# Link release-local paths to persistent shared targets.
	sudo ln -sfn "${SHARED_STORAGE_DIR}" "${ACTIVE_RELEASE_DIR}/storage"
	sudo ln -sfn "${SHARED_BOOTSTRAP_CACHE_DIR}" "${ACTIVE_RELEASE_DIR}/bootstrap/cache"
	sudo ln -sfn "${SHARED_ENV_FILE}" "${ACTIVE_RELEASE_DIR}/.env"
fi

# ---- Final permission pass ----
# The authoritative permission pass, run last and unconditionally so a rerun
# catches any drift: core structural perms for Nginx/PHP-FPM to traverse and
# read the release tree, plus the Laravel runtime perms (setgid so new files
# inherit the web group) on the shared writable paths.

echo "Performing final permission check and update..."

# Re-assert ownership across the entire deployment tree in case anything drifted.
sudo chown -R deployer:"${WEB_GROUP}" "${BASE_DIR}"

sudo chmod 755 "${BASE_DIR}" "${RELEASES_DIR}" "${SHARED_DIR}"
sudo find "${ACTIVE_RELEASE_DIR}" -type d -exec chmod 755 {} \;
sudo find "${ACTIVE_RELEASE_DIR}" -type f -exec chmod 644 {} \;

sudo find "${SHARED_STORAGE_DIR}" -type d -exec chmod 2775 {} \;
sudo find "${SHARED_STORAGE_DIR}" -type f -exec chmod 664 {} \;
sudo find "${SHARED_BOOTSTRAP_CACHE_DIR}" -type d -exec chmod 2775 {} \;
sudo find "${SHARED_BOOTSTRAP_CACHE_DIR}" -type f -exec chmod 664 {} \;
sudo chmod 2775 "${SHARED_DIR}/logs" "${SHARED_STORAGE_DIR}" "${SHARED_BOOTSTRAP_CACHE_DIR}"

# .env may hold secrets -- keep it owner/group readable only.
sudo chmod 640 "${SHARED_ENV_FILE}"

# Final setup summary for quick verification and handoff notes.
echo "Done."
echo "Site: ${SITE_NAME}"
echo "Base directory: ${BASE_DIR}"
echo "Current release: ${ACTIVE_RELEASE_DIR}"
echo "Shared env file: ${SHARED_ENV_FILE}"
echo "Permission summary:"
sudo stat -c '%a %U:%G %n' "${BASE_DIR}" "${RELEASES_DIR}" "${SHARED_DIR}" "${SHARED_STORAGE_DIR}" "${SHARED_BOOTSTRAP_CACHE_DIR}" "${SHARED_ENV_FILE}"
