# 08-laravel-deployment.sh site-name prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `08-laravel-deployment.sh` prompt for the site name (like `05-folder-structure.sh` and `06-nginx-tls-vhost.sh`) instead of deriving `BASE_DIR` from the caller's current directory, and correct the AGENTS.md documentation to match.

**Architecture:** Single-file bash script edit (reorder the sudo preflight check, add a validated `SITE_NAME` prompt, derive `BASE_DIR` from it) plus a documentation edit to two AGENTS.md bullets. No new files, no test framework -- verification is `bash -n` + `shellcheck` + manual `--help` sanity check, per this repo's existing testing convention.

**Tech Stack:** Bash (`set -euo pipefail`), `shellcheck`.

## Global Constraints

- Tabs for indentation, `"${VAR}"` quoting, uppercase snake case script-level variables (AGENTS.md Coding Style).
- Every change must pass `bash -n` and `shellcheck` with no new findings (AGENTS.md Testing Guidelines / Build commands).
- `--repo` (required) and `--keep` (optional, default 5) stay CLI flags -- do not convert to prompts.
- `SITE_NAME` must be validated with the strict hostname check `05-folder-structure.sh` uses (non-empty, dot-separated labels of letters/numbers/inner hyphens) before it is used to build `BASE_DIR`.
- The sudo-availability check must run after argument parsing (so `-h`/`--help` stays a zero-side-effect no-op) but before `--repo`/`--keep` value validation and before the `SITE_NAME` prompt.
- Commit messages: short, imperative, sentence-case subjects (AGENTS.md Commit Guidelines).

---

### Task 1: Rewrite the input/validation flow in `08-laravel-deployment.sh`

**Files:**
- Modify: `debian13-laravel-postgresql/08-laravel-deployment.sh` (full-file rewrite -- the reordering touches nearly every section)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: nothing consumed by Task 2 (Task 2 only touches `AGENTS.md`); both tasks are independent and can be reviewed separately.

- [ ] **Step 1: Write the new file content**

Overwrite `debian13-laravel-postgresql/08-laravel-deployment.sh` with this exact content (tabs for indentation, matching the rest of the file):

```bash
#!/usr/bin/env bash

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# ****************************************************************************************************
# Generate a standalone, re-runnable deploy.sh for a site whose atomic
# releases/shared/current layout has already been created by
# 05-folder-structure.sh. The generated script is what actually clones a
# branch from GitHub into a new release and swaps current onto it; this
# script only writes that file out. The operator is prompted for the site
# name, matching 05-folder-structure.sh and 06-nginx-tls-vhost.sh -- this
# script can be run from any directory.
# ****************************************************************************************************

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

# ---- Preflight: sudo ----
# Checked immediately after argument parsing, before validating --repo/--keep
# or prompting for the site name, so a misconfigured host is reported before
# the operator has typed anything -- matching 05-folder-structure.sh and
# 06-nginx-tls-vhost.sh. -h/--help above still exits with zero side effects,
# since it is handled during argument parsing, before this check runs.

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

# ---- Validate arguments ----

if [[ -z "${REPO_URL}" ]]; then
	echo "--repo is required." >&2
	usage >&2
	exit 1
fi

# SSH-only deploy-key workflow -- an HTTPS URL would fail at first deploy
# instead of at generation time, so reject it here.
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

# ---- Collect site name ----
# Validated as a strict hostname, same as 05-folder-structure.sh: SITE_NAME
# becomes part of BASE_DIR below, and the generated deploy.sh later runs
# 'sudo chown -R' under that path, so a leading '-' or a '..' segment here is
# a real hazard, not just cosmetic.

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

# ---- Derive paths and check the site's existing structure ----

BASE_DIR="/var/www/${SITE_NAME}"
RELEASES_DIR="${BASE_DIR}/releases"
SHARED_DIR="${BASE_DIR}/shared"
CURRENT_LINK="${BASE_DIR}/current"
DEPLOY_SCRIPT_PATH="${BASE_DIR}/deploy.sh"
WEB_GROUP="www-data"
DEPLOYER_GROUP="deployer"

# 05-folder-structure.sh must have already created the atomic layout -- this
# script only writes the deploy script, it does not provision directories.
if [[ ! -d "${RELEASES_DIR}" || ! -d "${SHARED_DIR}" ]]; then
	echo "${BASE_DIR} does not have the expected releases/shared layout." >&2
	echo "Run 05-folder-structure.sh for '${SITE_NAME}' first, then re-run this script." >&2
	exit 1
fi

if [[ -e "${CURRENT_LINK}" && ! -L "${CURRENT_LINK}" ]]; then
	echo "${CURRENT_LINK} exists but is not a symlink." >&2
	echo "05-folder-structure.sh should have created it as one -- check ${BASE_DIR} manually." >&2
	exit 1
fi

# Web server group must exist so the releases the installed deploy script
# later chowns can be shared with Nginx/PHP-FPM. The deploy script itself is
# owned deployer:deployer instead -- see the install step below.
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

# ---- Render deploy.sh ----
# Rendered as a literal (single-quoted) heredoc so none of the generated
# script's own $variables need escaping, then the placeholder tokens below
# are swapped for real values with sed. REPO_URL and KEEP_RELEASES are
# validated above and BASE_DIR is built from a validated SITE_NAME, so none
# contain '|', making it safe as the sed delimiter.

echo "Rendering ${DEPLOY_SCRIPT_PATH}..."

TMP_DEPLOY_SCRIPT="$(mktemp)"
cat > "${TMP_DEPLOY_SCRIPT}" <<'DEPLOY_TEMPLATE_EOF'
#!/usr/bin/env bash

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# Generated by 08-laravel-deployment.sh for '__BASE_DIR__'.
# Rerun the generator and enter this site name again to regenerate --
# BASE_DIR/REPO_URL/KEEP_RELEASES below are overwritten on every
# regeneration; do not hand-edit them.

BASE_DIR="__BASE_DIR__"
REPO_URL="__REPO_URL__"
KEEP_RELEASES=__KEEP_RELEASES__

# This deploy script relies on 'deployer' owning the release tree and
# holding the GitHub SSH deploy key -- same convention as
# atomic-deployment-setup.sh.
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

if [[ ! -d "${RELEASES_DIR}" || ! -d "${SHARED_DIR}" || ! -s "${SHARED_ENV_FILE}" ]]; then
	echo "${BASE_DIR} is missing the expected releases/shared/.env layout, or .env is empty." >&2
	echo "Run 05-folder-structure.sh for this directory first, then populate ${SHARED_ENV_FILE} (APP_KEY, DB_*, etc.) before deploying." >&2
	exit 1
fi

# ---- Mode selection ----
# Usage:
#   deploy.sh              deploy 'main'
#   deploy.sh <branch>     deploy <branch>
#   deploy.sh --rollback   roll current back to the previous release

ROLLBACK=0
BRANCH="main"

if [[ "${1:-}" == "--rollback" ]]; then
	ROLLBACK=1
elif [[ $# -gt 0 ]]; then
	BRANCH="$1"
fi

# ---- Shared helper: reload_php_fpm() ----
# Detects whichever php*-fpm systemd service is active and reloads it. Used
# by both deploy and rollback so the two modes can't drift out of sync.

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

# ---- Rollback mode ----
# Only flips the current symlink to the release immediately older than the
# one it points at now. Does not run any migration rollback and does not
# revert .env -- if the release being rolled back away from included a
# schema migration, the restored code may not match the current schema, and
# that has to be handled by hand.

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

# ---- Deploy mode ----

NEW_RELEASE_DIR="${RELEASES_DIR}/$(date +%Y%m%d%H%M%S)"

echo "Deploying branch '${BRANCH}' to ${NEW_RELEASE_DIR}..."
git clone --branch "${BRANCH}" --single-branch --depth 1 "${REPO_URL}" "${NEW_RELEASE_DIR}"

# The clone may bring its own .env / storage / bootstrap/cache -- replace
# them with links into the shared tree 05-folder-structure.sh already manages.
rm -rf "${NEW_RELEASE_DIR}/.env" "${NEW_RELEASE_DIR}/storage" "${NEW_RELEASE_DIR}/bootstrap/cache"
mkdir -p "${NEW_RELEASE_DIR}/bootstrap"
ln -sfn "${SHARED_ENV_FILE}" "${NEW_RELEASE_DIR}/.env"
ln -sfn "${SHARED_STORAGE_DIR}" "${NEW_RELEASE_DIR}/storage"
ln -sfn "${SHARED_BOOTSTRAP_CACHE_DIR}" "${NEW_RELEASE_DIR}/bootstrap/cache"

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
# Only the group change needs sudo: deployer already owns everything it just
# cloned, but changing the group to www-data needs root since deployer isn't
# a member of that group (same reasoning as 05-folder-structure.sh).
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n debian13-laravel-postgresql/08-laravel-deployment.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Verify no new shellcheck findings**

Run: `shellcheck debian13-laravel-postgresql/08-laravel-deployment.sh`
Expected: same result as running it against the pre-change version (clean, or only pre-existing findings that already existed before this task -- there should be none new, since the edit only reorders existing validated blocks and adds a hostname-regex check copied verbatim from `05-folder-structure.sh`, which itself passes shellcheck clean).

- [ ] **Step 4: Sanity-check --help stays a no-op**

Run: `bash debian13-laravel-postgresql/08-laravel-deployment.sh --help`
Expected: prints the usage text (mentioning the site-name prompt and `/var/www/<site name>/deploy.sh`) and exits 0, without attempting any sudo check or prompting for input. Also run `bash debian13-laravel-postgresql/08-laravel-deployment.sh` (no args) and confirm it fails fast on the sudo check or the missing `--repo` check before ever reaching `read -r -p`, by observing the order of output/prompts.

- [ ] **Step 5: Commit**

```bash
git add debian13-laravel-postgresql/08-laravel-deployment.sh
git commit -m "Prompt for site name in 08-laravel-deployment.sh instead of deriving it from cwd"
```

---

### Task 2: Update AGENTS.md to match the new 08 behavior, and fix the stale 06 claim

**Files:**
- Modify: `AGENTS.md:31-39` (06-nginx-tls-vhost.sh bullet)
- Modify: `AGENTS.md:46-54` (08-laravel-deployment.sh bullet)

**Interfaces:**
- Consumes: nothing from Task 1 (pure documentation change; independent of the script edit landing first, though it describes Task 1's resulting behavior).
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Fix the 06-nginx-tls-vhost.sh bullet**

In `AGENTS.md`, replace:

```
- `06-nginx-tls-vhost.sh` owns the site's Nginx vhost and Let's Encrypt/certbot TLS issuance -- also
  standalone and re-runnable, with no dependency on `07-database.sh` having run. Run it from inside the
  site's base directory (`/var/www/<site>`); it prompts for the site name and uses it as typed, with no
  default and no format validation. Its one hard precondition is `05-folder-structure.sh` having already run
  for the site: it exits immediately if `current/public` doesn't exist, rather than writing a vhost that
  points at a webroot that isn't there. Vhost files are always fully rewritten via temp-file-then-move
  (first HTTP-only for the ACME challenge, then rewritten again with the HTTPS server block once the
  certificate exists) and certbot itself is idempotent, so it's safe to re-run to change the server name,
  redo the renewal verification, or recover from a manually broken vhost.
```

with:

```
- `06-nginx-tls-vhost.sh` owns the site's Nginx vhost and Let's Encrypt/certbot TLS issuance -- also
  standalone and re-runnable, with no dependency on `07-database.sh` having run. It prompts for the site
  name and uses it as typed, with no default and no format validation; it does not depend on or check the
  caller's current directory, so it can be run from anywhere. Its one hard precondition is
  `05-folder-structure.sh` having already run for the site: it exits immediately if `current/public`
  doesn't exist, rather than writing a vhost that points at a webroot that isn't there. Vhost files are
  always fully rewritten via temp-file-then-move (first HTTP-only for the ACME challenge, then rewritten
  again with the HTTPS server block once the certificate exists) and certbot itself is idempotent, so it's
  safe to re-run to change the server name, redo the renewal verification, or recover from a manually
  broken vhost.
```

- [ ] **Step 2: Fix the 08-laravel-deployment.sh bullet**

In `AGENTS.md`, replace:

```
- `08-laravel-deployment.sh --repo <git@...>` [`--keep N`] generates a standalone, re-runnable `deploy.sh`
  into the site's base directory (run this script from inside `/var/www/<site>`, matching
  `06-nginx-tls-vhost.sh`'s convention -- the site is identified by the current directory, not a flag).
  Requires the `releases`/`shared` layout `05-folder-structure.sh` already created. The generated
  `deploy.sh` (run as `deployer`) clones a branch over SSH into a new timestamped release, symlinks
  `.env`/`storage`/`bootstrap/cache` into the shared tree, runs `composer install`, `php artisan migrate
  --force`, an `npm ci && npm run build` when `package.json` is present, caches config/routes/views, swaps
  `current`, reloads PHP-FPM, and prunes releases beyond `--keep` (default 5). `deploy.sh --rollback` just
  flips `current` to the previous release -- it runs no migration rollback and does not revert `.env`.
```

with:

```
- `08-laravel-deployment.sh --repo <git@...>` [`--keep N`] prompts for the site name, matching
  `05-folder-structure.sh` and `06-nginx-tls-vhost.sh`'s convention -- it does not depend on the caller's
  current directory -- and generates a standalone, re-runnable `deploy.sh` into that site's base directory
  (`/var/www/<site name>`). Requires the `releases`/`shared` layout `05-folder-structure.sh` already
  created for that site. The generated `deploy.sh` (run as `deployer`) clones a branch over SSH into a new
  timestamped release, symlinks `.env`/`storage`/`bootstrap/cache` into the shared tree, runs `composer
  install`, `php artisan migrate --force`, an `npm ci && npm run build` when `package.json` is present,
  caches config/routes/views, swaps `current`, reloads PHP-FPM, and prunes releases beyond `--keep`
  (default 5). `deploy.sh --rollback` just flips `current` to the previous release -- it runs no migration
  rollback and does not revert `.env`.
```

- [ ] **Step 3: Verify**

Run: `git diff AGENTS.md`
Expected: only the two bullets above changed; no other lines touched.

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md
git commit -m "Correct AGENTS.md to describe 06/08's site-name prompt instead of cwd convention"
```

---

## Self-Review Notes

- **Spec coverage:** SITE_NAME prompt + validation (Task 1 Step 1), BASE_DIR from SITE_NAME (Task 1 Step 1), sudo-check reordering (Task 1 Step 1 + verified in Step 4), --repo/--keep unchanged (Task 1 Step 1, untouched blocks), usage/comment text updates (Task 1 Step 1), deploy.sh template header reword (Task 1 Step 1), error messages referencing SITE_NAME (Task 1 Step 1), AGENTS.md 08 bullet (Task 2 Step 2), AGENTS.md 06 stale-claim fix (Task 2 Step 1). All spec sections covered.
- **Placeholder scan:** none found -- both tasks contain literal file content and literal old/new strings.
- **Type consistency:** N/A (bash script, no typed interfaces between tasks; the two tasks are independent).
