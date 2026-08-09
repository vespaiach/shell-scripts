#!/usr/bin/env bash

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# ****************************************************************************************************
# Generate a standalone, re-runnable laravel-deployment.sh for a site whose
# atomic releases/shared/current layout has already been created by
# structure-setup.sh. The generated script is what actually clones a branch
# from GitHub into a new release and swaps current onto it; this script only
# writes that file out.
# ****************************************************************************************************

usage() {
	cat <<'USAGE'
Usage: laravel-deployment-generator.sh --site <name> --repo <ssh-url> [--keep-releases <n>]

  --site <name>          Site identifier, e.g. app.mysite.com. Must already
                          have the releases/shared/current layout that
                          structure-setup.sh creates.
  --repo <ssh-url>        GitHub repo to deploy, over SSH, e.g.
                          git@github.com:owner/repo.git
  --keep-releases <n>     Releases to retain after each deploy. Defaults to
                          5. Values below 2 leave no release to roll back to.
  -h, --help              Show this help text.
USAGE
}

SITE_NAME=""
REPO_URL=""
KEEP_RELEASES=5

while [[ $# -gt 0 ]]; do
	case "$1" in
		--site)
			SITE_NAME="${2:-}"
			shift 2
			;;
		--repo)
			REPO_URL="${2:-}"
			shift 2
			;;
		--keep-releases)
			KEEP_RELEASES="${2:-}"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 1
			;;
	esac
done

# ---- Validate input ----

if [[ -z "${SITE_NAME}" ]]; then
	echo "--site is required." >&2
	exit 1
fi

if [[ ! "${SITE_NAME}" =~ ^[a-zA-Z0-9.-]+$ ]]; then
	echo "Site name can only contain letters, numbers, dots, and hyphens." >&2
	exit 1
fi

if [[ -z "${REPO_URL}" ]]; then
	echo "--repo is required." >&2
	exit 1
fi

# SSH-only deploy-key workflow -- an HTTPS URL would fail at first deploy
# instead of at generation time, so reject it here.
if [[ ! "${REPO_URL}" =~ ^git@[a-zA-Z0-9.-]+:[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+\.git$ ]]; then
	echo "--repo must be an SSH GitHub URL, e.g. git@github.com:owner/repo.git" >&2
	exit 1
fi

if [[ ! "${KEEP_RELEASES}" =~ ^[0-9]+$ ]] || [[ "${KEEP_RELEASES}" -lt 1 ]]; then
	echo "--keep-releases must be a positive integer." >&2
	exit 1
fi

if [[ "${KEEP_RELEASES}" -lt 2 ]]; then
	echo "Warning: --keep-releases is ${KEEP_RELEASES}; rollback needs at least one older release on disk." >&2
fi

# ---- Derive paths and check the site's existing structure ----

BASE_DIR="/var/www/${SITE_NAME}"
RELEASES_DIR="${BASE_DIR}/releases"
SHARED_DIR="${BASE_DIR}/shared"
CURRENT_LINK="${BASE_DIR}/current"
DEPLOY_SCRIPT_PATH="${BASE_DIR}/laravel-deployment.sh"
WEB_GROUP="www-data"

# structure-setup.sh must have already created the atomic layout -- this
# script only writes the deploy script, it does not provision directories.
if [[ ! -d "${RELEASES_DIR}" || ! -d "${SHARED_DIR}" ]]; then
	echo "${BASE_DIR} does not have the expected releases/shared layout." >&2
	echo "Run structure-setup.sh for '${SITE_NAME}' first." >&2
	exit 1
fi

if [[ -e "${CURRENT_LINK}" && ! -L "${CURRENT_LINK}" ]]; then
	echo "${CURRENT_LINK} exists but is not a symlink." >&2
	echo "structure-setup.sh should have created it as one -- check ${BASE_DIR} manually." >&2
	exit 1
fi

# Web server group must exist so the installed deploy script -- and the
# releases it later chowns -- can be shared with Nginx/PHP-FPM.
if ! getent group "${WEB_GROUP}" >/dev/null 2>&1; then
	echo "Required group '${WEB_GROUP}' does not exist." >&2
	echo "Create it or update WEB_GROUP in this script." >&2
	exit 1
fi

# ---- Preflight: sudo ----
# Checked only now, after the cheaper input/structure/group checks above, so
# a misconfigured or not-yet-provisioned site is reported without demanding
# a sudo password first.

if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required but not installed." >&2
	exit 1
fi

if ! sudo -n true 2>/dev/null; then
	echo "This script needs sudo privileges to install the deployment script."
	echo "You may be prompted for your sudo password during execution."
	if ! sudo true; then
		echo "Unable to obtain sudo privileges." >&2
		exit 1
	fi
fi

echo "Preflight checks passed for site '${SITE_NAME}'."
echo "Would write deployment script to: ${DEPLOY_SCRIPT_PATH}"
