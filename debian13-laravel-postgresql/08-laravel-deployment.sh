#!/usr/bin/env bash
#
# Summary: Generates a standalone, re-runnable deploy.sh into /var/www/<site>/deploy.sh; this
#   script itself does not deploy anything. The generated deploy.sh (run as 'deployer') clones a
#   branch over SSH into a new timestamped release, symlinks storage/bootstrap-cache/.env into the
#   shared tree (failing fast if shared/.env is missing), runs composer install, php artisan
#   migrate --force, npm ci && npm run build when package.json is present, caches
#   config/routes/views, swaps 'current', reloads PHP-FPM, and prunes releases beyond --keep.
#   'deploy.sh --rollback' just flips 'current' to the previous release (no migration rollback,
#   no .env change -- both releases already share the same .env symlink).
# Input:   --repo <git@...ssh-url> (required, validated SSH GitHub-style URL), --keep N
#          (optional, default 5); interactive prompt for site name (validated hostname).
#          Requires the releases/shared layout 05-folders-permissions-env.sh already created.
# Output:  An installed, executable /var/www/<site>/deploy.sh (mode 750, deployer:deployer).

set -euo pipefail


usage() {
	cat <<EOF
Usage:
  $(basename "$0") --repo <url> [--keep N]

  You will be prompted for the site name; the generated deploy.sh is
  written to /var/www/<site name>/deploy.sh.

  --repo      GitHub repo SSH URL (example: git@github.com:owner/repo.git).
              Must already have the releases/shared/current layout that
              05-folder-structure.sh creates. Required.
  --keep      Releases to keep after each deploy. Default: 5. Values below
              2 leave no release to roll back to.
EOF
}

REPO_URL=""
KEEP_RELEASES=5

while [[ $# -gt 0 ]]; do
	case "$1" in
		--repo)
			REPO_URL="${2:-}"
			shift 2
			;;
		--keep)
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


if [[ -z "${REPO_URL}" ]]; then
	echo "--repo is required." >&2
	usage >&2
	exit 1
fi

if [[ ! "${REPO_URL}" =~ ^git@[a-zA-Z0-9.-]+:[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+\.git$ ]]; then
	echo "Repo must be an SSH GitHub URL, e.g. git@github.com:owner/repo.git" >&2
	exit 1
fi

if [[ ! "${KEEP_RELEASES}" =~ ^[1-9][0-9]*$ ]]; then
	echo "--keep must be a positive integer." >&2
	exit 1
fi

if [[ "${KEEP_RELEASES}" -lt 2 ]]; then
	echo "Warning: keeping ${KEEP_RELEASES} release(s); rollback needs at least one older release on disk." >&2
fi


is_valid_hostname() {
	[[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}

read -r -p "Site name (e.g., app.mysite.com): " SITE_NAME

if [[ -z "${SITE_NAME}" ]]; then
	echo "Site name cannot be empty." >&2
	exit 1
fi

if ! is_valid_hostname "${SITE_NAME}"; then
	echo "Site name must be a hostname: dot-separated labels of letters, numbers, and inner hyphens (example: app.mysite.com)." >&2
	exit 1
fi


BASE_DIR="/var/www/${SITE_NAME}"
RELEASES_DIR="${BASE_DIR}/releases"
SHARED_DIR="${BASE_DIR}/shared"
CURRENT_LINK="${BASE_DIR}/current"
DEPLOY_SCRIPT_PATH="${BASE_DIR}/deploy.sh"
WEB_GROUP="www-data"
DEPLOYER_GROUP="deployer"

if [[ ! -d "${RELEASES_DIR}" || ! -d "${SHARED_DIR}" ]]; then
	echo "${BASE_DIR} does not have the expected releases/shared layout." >&2
	echo "Run 05-folder-structure.sh for '${SITE_NAME}' first, then re-run this script." >&2
	exit 1
fi

if [[ ! -e "${SHARED_DIR}/.env" ]]; then
	echo "${SHARED_DIR}/.env does not exist." >&2
	echo "Run 05-folder-structure.sh for '${SITE_NAME}' first, then re-run this script." >&2
	exit 1
fi

if [[ -e "${CURRENT_LINK}" && ! -L "${CURRENT_LINK}" ]]; then
	echo "${CURRENT_LINK} exists but is not a symlink." >&2
	echo "05-folder-structure.sh should have created it as one -- check ${BASE_DIR} manually." >&2
	exit 1
fi

if ! getent group "${WEB_GROUP}" >/dev/null 2>&1; then
	echo "Required group '${WEB_GROUP}' does not exist." >&2
	echo "Create it or update WEB_GROUP in this script." >&2
	exit 1
fi

if ! getent passwd deployer >/dev/null 2>&1; then
	echo "Required user 'deployer' does not exist." >&2
	echo "Run 01-packages-and-deployer.sh first." >&2
	exit 1
fi

if ! getent group "${DEPLOYER_GROUP}" >/dev/null 2>&1; then
	echo "Required group '${DEPLOYER_GROUP}' does not exist." >&2
	echo "Expected 'useradd -m deployer' to have created it; check the deployer account." >&2
	exit 1
fi


echo "Rendering ${DEPLOY_SCRIPT_PATH}..."

TMP_DEPLOY_SCRIPT="$(mktemp)"
cat > "${TMP_DEPLOY_SCRIPT}" <<'DEPLOY_TEMPLATE_EOF'

set -euo pipefail


BASE_DIR="__BASE_DIR__"
REPO_URL="__REPO_URL__"
KEEP_RELEASES=__KEEP_RELEASES__

if [[ "$(id -un)" != "deployer" ]]; then
	echo "Please run this script as user 'deployer'." >&2
	exit 1
fi

if ! command -v git >/dev/null 2>&1 || ! command -v composer >/dev/null 2>&1 || ! command -v php >/dev/null 2>&1; then
	echo "git, composer, and php must all be on PATH." >&2
	exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required but not installed." >&2
	exit 1
fi

if ! sudo -n true 2>/dev/null; then
	echo "This script needs passwordless sudo (chown, systemctl reload) to complete a deploy." >&2
	exit 1
fi

RELEASES_DIR="${BASE_DIR}/releases"
SHARED_DIR="${BASE_DIR}/shared"
CURRENT_LINK="${BASE_DIR}/current"
SHARED_STORAGE_DIR="${SHARED_DIR}/storage"
SHARED_BOOTSTRAP_CACHE_DIR="${SHARED_DIR}/bootstrap/cache"
SHARED_ENV_FILE="${SHARED_DIR}/.env"
WEB_GROUP="www-data"

if [[ ! -d "${RELEASES_DIR}" || ! -d "${SHARED_DIR}" ]]; then
	echo "${BASE_DIR} is missing the expected releases/shared layout." >&2
	echo "Run 05-folder-structure.sh for this directory first, then re-run this script." >&2
	exit 1
fi

if [[ ! -e "${SHARED_ENV_FILE}" ]]; then
	echo "${SHARED_ENV_FILE} does not exist." >&2
	echo "Run 05-folder-structure.sh for this directory first, then re-run this script." >&2
	exit 1
fi



ROLLBACK=0
BRANCH="main"

if [[ "${1:-}" == "--rollback" ]]; then
	ROLLBACK=1
elif [[ $# -gt 0 ]]; then
	BRANCH="$1"
fi


detect_php_fpm_service() {
	systemctl list-units --type=service --state=active --no-legend 'php*-fpm.service' 2>/dev/null \
		| awk '{print $1}' \
		| head -n 1 \
		|| true
}

reload_php_fpm() {
	local service
	service="$(detect_php_fpm_service)"
	if [[ -z "${service}" ]]; then
		echo "Warning: no active php*-fpm service detected; skipping reload." >&2
		return
	fi
	echo "Reloading ${service}..."
	sudo systemctl reload "${service}"
}


if [[ "${ROLLBACK}" -eq 1 ]]; then
	if [[ ! -L "${CURRENT_LINK}" ]]; then
		echo "${CURRENT_LINK} is not a symlink; nothing to roll back." >&2
		exit 1
	fi

	CURRENT_RELEASE="$(cd "${CURRENT_LINK}" && pwd -P)"
	CURRENT_RELEASE_NAME="$(basename "${CURRENT_RELEASE}")"

	PREVIOUS_RELEASE_NAME="$(find "${RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
		| sort -r \
		| awk -v cur="${CURRENT_RELEASE_NAME}" 'seen{print; exit} $0==cur{seen=1}')"

	if [[ -z "${PREVIOUS_RELEASE_NAME}" ]]; then
		echo "No older release to roll back to." >&2
		exit 1
	fi

	PREVIOUS_RELEASE_DIR="${RELEASES_DIR}/${PREVIOUS_RELEASE_NAME}"

	echo "Regenerating cached config/routes/views for ${PREVIOUS_RELEASE_NAME}..."
	(cd "${PREVIOUS_RELEASE_DIR}" && php artisan config:cache && php artisan route:cache && php artisan view:cache)

	echo "Rolling back current from ${CURRENT_RELEASE_NAME} to ${PREVIOUS_RELEASE_NAME}..."
	ln -sfn "${PREVIOUS_RELEASE_DIR}" "${CURRENT_LINK}"
	reload_php_fpm

	echo "Done."
	echo "Rolled back: ${CURRENT_RELEASE_NAME} -> ${PREVIOUS_RELEASE_NAME}"
	echo "Note: this only moved the current symlink. No migration rollback ran"
	echo "and .env was not reverted -- reconcile the schema by hand if the"
	echo "release you rolled back away from included one."
	exit 0
fi


NEW_RELEASE_DIR="${RELEASES_DIR}/$(date +%Y%m%d%H%M%S)"

echo "Deploying branch '${BRANCH}' to ${NEW_RELEASE_DIR}..."
git clone --branch "${BRANCH}" --single-branch --depth 1 "${REPO_URL}" "${NEW_RELEASE_DIR}"

rm -rf "${NEW_RELEASE_DIR}/storage" "${NEW_RELEASE_DIR}/bootstrap/cache"
mkdir -p "${NEW_RELEASE_DIR}/bootstrap"
ln -sfn "${SHARED_STORAGE_DIR}" "${NEW_RELEASE_DIR}/storage"
ln -sfn "${SHARED_BOOTSTRAP_CACHE_DIR}" "${NEW_RELEASE_DIR}/bootstrap/cache"
ln -sfn "${SHARED_ENV_FILE}" "${NEW_RELEASE_DIR}/.env"

echo "Installing Composer dependencies..."
(cd "${NEW_RELEASE_DIR}" && composer install --no-dev --optimize-autoloader --no-interaction)

echo "Running database migrations..."
(cd "${NEW_RELEASE_DIR}" && php artisan migrate --force)

if [[ -f "${NEW_RELEASE_DIR}/package.json" ]]; then
	echo "Building frontend assets..."
	(cd "${NEW_RELEASE_DIR}" && npm ci && npm run build)
else
	echo "No package.json found; skipping frontend asset build."
fi

echo "Setting release permissions..."
sudo chown -R deployer:"${WEB_GROUP}" "${NEW_RELEASE_DIR}"
chmod 755 "${NEW_RELEASE_DIR}"
find "${NEW_RELEASE_DIR}" -type d -exec chmod 755 {} +
find "${NEW_RELEASE_DIR}" -type f -exec chmod 644 {} +

echo "Caching config/routes/views..."
(cd "${NEW_RELEASE_DIR}" && php artisan config:cache && php artisan route:cache && php artisan view:cache)

echo "Swapping current -> ${NEW_RELEASE_DIR}..."
ln -sfn "${NEW_RELEASE_DIR}" "${CURRENT_LINK}"

reload_php_fpm

echo "Pruning releases beyond ${KEEP_RELEASES}..."
mapfile -t OLD_RELEASES < <(find "${RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | tail -n +$((KEEP_RELEASES + 1)))
for old in "${OLD_RELEASES[@]}"; do
	echo "Removing old release ${old}..."
	rm -rf "${RELEASES_DIR:?}/${old}"
done

echo "Done."
echo "Site: $(basename "${BASE_DIR}")"
echo "Branch deployed: ${BRANCH}"
echo "New release: ${NEW_RELEASE_DIR}"
echo "Permission summary:"
stat -c '%a %U:%G %n' "${BASE_DIR}" "${RELEASES_DIR}" "${NEW_RELEASE_DIR}"
DEPLOY_TEMPLATE_EOF

sed -i \
	-e "s|__BASE_DIR__|${BASE_DIR}|g" \
	-e "s|__REPO_URL__|${REPO_URL}|g" \
	-e "s|__KEEP_RELEASES__|${KEEP_RELEASES}|g" \
	"${TMP_DEPLOY_SCRIPT}"

sudo install -m 750 -o deployer -g "${DEPLOYER_GROUP}" "${TMP_DEPLOY_SCRIPT}" "${DEPLOY_SCRIPT_PATH}"
rm -f "${TMP_DEPLOY_SCRIPT}"

echo "Done."
echo "Site: ${SITE_NAME}"
echo "Repo: ${REPO_URL}"
echo "Keep releases: ${KEEP_RELEASES}"
echo "Deployment script: ${DEPLOY_SCRIPT_PATH}"
echo "Run it as 'deployer': ${DEPLOY_SCRIPT_PATH} [branch]"
echo "Roll back with: ${DEPLOY_SCRIPT_PATH} --rollback"
