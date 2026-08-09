# Laravel Deployment Generator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `debian/laravel-deployment-generator.sh`, a flag-driven script that writes a standalone, re-runnable `/var/www/<site>/laravel-deployment.sh` for deploying a Laravel app from GitHub into the existing atomic `releases/shared/current` layout.

**Architecture:** One generator script validates input and an already-provisioned site structure, then renders the deploy script from an embedded literal template (placeholder tokens swapped via `sed`) and installs it with `sudo install`. The generated script itself is deploy-mode-by-default / `--rollback`-mode-on-flag, runs only as `deployer`, and does the actual git-clone-to-atomic-swap work on every invocation.

**Tech Stack:** Bash (`set -euo pipefail`), git, Composer, PHP artisan, npm (conditional), systemd (`systemctl reload`), `shellcheck` for linting — no other dependencies, matching the rest of `debian/`.

## Global Constraints

- `#!/usr/bin/env bash` + `set -euo pipefail` at the top of every script (repo convention, `AGENTS.md`).
- Tab indentation; quote all expansions (`"${VAR}"`); uppercase snake case for script-level variables; kebab-case filenames.
- Validate with `bash -n debian/*.sh` and `shellcheck debian/*.sh`; fix or document findings (`AGENTS.md`).
- Standalone and re-runnable: no dependency on another script's runtime state beyond an explicitly checked prerequisite (`AGENTS.md`, spec Non-goals).
- Generator flags: `--site <name>` (required, `^[a-zA-Z0-9.-]+$`), `--repo <ssh-url>` (required, SSH GitHub URL only — no HTTPS), `--keep-releases <n>` (optional, default `5`, must be a positive integer, warn if `< 2`).
- Generator hard-stops if `/var/www/<site>/{releases,shared}` don't already exist (i.e. `structure-setup.sh` hasn't run) — it does not provision that layout itself.
- Generator overwrites any existing `laravel-deployment.sh` at that path unconditionally.
- Generated script usage: `./laravel-deployment.sh` deploys `main`; `./laravel-deployment.sh <branch>` deploys `<branch>`; `./laravel-deployment.sh --rollback` rolls `current` back to the previous release. Must run as `deployer` (hard stop otherwise).
- Rollback only flips the `current` symlink — no migration rollback, no `.env` revert.
- Spec: [docs/superpowers/specs/2026-08-09-laravel-deployment-generator-design.md](../specs/2026-08-09-laravel-deployment-generator-design.md)

---

## Task 1: Generator CLI — flags, validation, preflight

**Files:**
- Create: `debian/laravel-deployment-generator.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a runnable script with variables `SITE_NAME`, `REPO_URL`, `KEEP_RELEASES`, `WEB_GROUP`, `BASE_DIR`, `RELEASES_DIR`, `SHARED_DIR`, `CURRENT_LINK`, `DEPLOY_SCRIPT_PATH` set and validated by the time execution reaches the final line. Task 2 replaces only the final two `echo` lines.

- [ ] **Step 1: Write the generator's CLI parsing, validation, and preflight**

Create `debian/laravel-deployment-generator.sh`:

```bash
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
```

- [ ] **Step 2: Check syntax**

Run: `bash -n debian/laravel-deployment-generator.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Lint**

Run: `shellcheck debian/laravel-deployment-generator.sh`
Expected: no findings. If shellcheck reports anything, fix it in the file above and re-run until clean (per `AGENTS.md`: "fix or document ShellCheck findings").

- [ ] **Step 4: Make it executable and exercise every validation branch**

Run:
```bash
chmod +x debian/laravel-deployment-generator.sh

debian/laravel-deployment-generator.sh; echo "exit=$?"
debian/laravel-deployment-generator.sh --help; echo "exit=$?"
debian/laravel-deployment-generator.sh --nope; echo "exit=$?"
debian/laravel-deployment-generator.sh --site 'bad name!' --repo git@github.com:owner/repo.git; echo "exit=$?"
debian/laravel-deployment-generator.sh --site example.com; echo "exit=$?"
debian/laravel-deployment-generator.sh --site example.com --repo https://github.com/owner/repo.git; echo "exit=$?"
debian/laravel-deployment-generator.sh --site example.com --repo git@github.com:owner/repo.git --keep-releases abc; echo "exit=$?"
debian/laravel-deployment-generator.sh --site example.com --repo git@github.com:owner/repo.git --keep-releases 1; echo "exit=$?"
```

Expected, in order:
1. No args → `exit=1`, stderr contains `--site is required.`
2. `--help` → `exit=0`, stdout contains `Usage:`
3. `--nope` → `exit=1`, stderr contains `Unknown argument: --nope`
4. Bad site chars → `exit=1`, stderr contains `Site name can only contain`
5. Missing `--repo` → `exit=1`, stderr contains `--repo is required.`
6. HTTPS repo URL → `exit=1`, stderr contains `must be an SSH GitHub URL`
7. Non-numeric `--keep-releases` → `exit=1`, stderr contains `must be a positive integer`
8. Valid flags, but `/var/www/example.com` doesn't exist on the dev machine running this check → `exit=1`, stderr contains `does not have the expected releases/shared layout` (the `--keep-releases 1` warning line will also appear first; that's expected and fine)

This dev machine has no `/var/www`, no `deployer` user, and no cached sudo credential, so every case above fails before touching the filesystem or prompting for a password — safe to run here. The genuine happy path (real `/var/www/<site>` structure present) can only be exercised on a Debian host per `AGENTS.md`; that's covered by the manual verification checklist in Task 3.

- [ ] **Step 5: Commit**

```bash
git add debian/laravel-deployment-generator.sh
git commit -m "Add laravel-deployment-generator.sh CLI parsing and preflight"
```

---

## Task 2: Render and install the generated `laravel-deployment.sh`

**Files:**
- Modify: `debian/laravel-deployment-generator.sh` (replace the final two `echo` lines from Task 1)

**Interfaces:**
- Consumes: `SITE_NAME`, `REPO_URL`, `KEEP_RELEASES`, `WEB_GROUP`, `DEPLOY_SCRIPT_PATH` from Task 1.
- Produces: `/var/www/<site>/laravel-deployment.sh` on disk when run against a real, provisioned site — the deliverable the whole feature exists to produce. No other task consumes this script's output programmatically.

- [ ] **Step 1: Replace the placeholder ending with the render + install logic**

In `debian/laravel-deployment-generator.sh`, replace:

```bash
echo "Preflight checks passed for site '${SITE_NAME}'."
echo "Would write deployment script to: ${DEPLOY_SCRIPT_PATH}"
```

with:

```bash
# ---- Render laravel-deployment.sh ----
# Rendered as a literal (single-quoted) heredoc so none of the generated
# script's own $variables need escaping, then the three placeholder tokens
# below are swapped for real values with sed. All three values are already
# validated above and contain none of '|', so '|' is safe as the sed
# delimiter.

echo "Rendering ${DEPLOY_SCRIPT_PATH}..."

TMP_DEPLOY_SCRIPT="$(mktemp)"
cat > "${TMP_DEPLOY_SCRIPT}" <<'DEPLOY_TEMPLATE_EOF'
#!/usr/bin/env bash

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# Generated by laravel-deployment-generator.sh for site '__SITE_NAME__'.
# Rerun the generator to regenerate -- SITE_NAME/REPO_URL/KEEP_RELEASES below
# are overwritten on every regeneration; do not hand-edit them.

SITE_NAME="__SITE_NAME__"
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

BASE_DIR="/var/www/${SITE_NAME}"
RELEASES_DIR="${BASE_DIR}/releases"
SHARED_DIR="${BASE_DIR}/shared"
CURRENT_LINK="${BASE_DIR}/current"
SHARED_STORAGE_DIR="${SHARED_DIR}/storage"
SHARED_BOOTSTRAP_CACHE_DIR="${SHARED_DIR}/bootstrap/cache"
SHARED_ENV_FILE="${SHARED_DIR}/.env"
WEB_GROUP="www-data"

if [[ ! -d "${RELEASES_DIR}" || ! -d "${SHARED_DIR}" || ! -f "${SHARED_ENV_FILE}" ]]; then
	echo "${BASE_DIR} is missing the expected releases/shared/.env layout." >&2
	echo "Run structure-setup.sh for '${SITE_NAME}' first." >&2
	exit 1
fi

# ---- Mode selection ----
# Usage:
#   laravel-deployment.sh              deploy 'main'
#   laravel-deployment.sh <branch>     deploy <branch>
#   laravel-deployment.sh --rollback   roll current back to the previous release

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
		| head -n 1
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
# them with links into the shared tree structure-setup.sh already manages.
rm -rf "${NEW_RELEASE_DIR}/.env" "${NEW_RELEASE_DIR}/storage" "${NEW_RELEASE_DIR}/bootstrap/cache"
mkdir -p "${NEW_RELEASE_DIR}/bootstrap"
ln -sfn "${SHARED_ENV_FILE}" "${NEW_RELEASE_DIR}/.env"
ln -sfn "${SHARED_STORAGE_DIR}" "${NEW_RELEASE_DIR}/storage"
ln -sfn "${SHARED_BOOTSTRAP_CACHE_DIR}" "${NEW_RELEASE_DIR}/bootstrap/cache"

echo "Installing Composer dependencies..."
(cd "${NEW_RELEASE_DIR}" && composer install --no-dev --optimize-autoloader --no-interaction)

echo "Running database migrations..."
(cd "${NEW_RELEASE_DIR}" && php artisan migrate --force)

echo "Caching config/routes/views..."
(cd "${NEW_RELEASE_DIR}" && php artisan config:cache && php artisan route:cache && php artisan view:cache)

if [[ -f "${NEW_RELEASE_DIR}/package.json" ]]; then
	echo "Building frontend assets..."
	(cd "${NEW_RELEASE_DIR}" && npm ci && npm run build)
else
	echo "No package.json found; skipping frontend asset build."
fi

echo "Setting release permissions..."
# Only the group change needs sudo: deployer already owns everything it just
# cloned, but changing the group to www-data needs root since deployer isn't
# a member of that group (same reasoning as structure-setup.sh).
sudo chown -R deployer:"${WEB_GROUP}" "${NEW_RELEASE_DIR}"
chmod 755 "${NEW_RELEASE_DIR}"
find "${NEW_RELEASE_DIR}" -type d -exec chmod 755 {} \;
find "${NEW_RELEASE_DIR}" -type f -exec chmod 644 {} \;

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
echo "Site: ${SITE_NAME}"
echo "Branch deployed: ${BRANCH}"
echo "New release: ${NEW_RELEASE_DIR}"
echo "Permission summary:"
stat -c '%a %U:%G %n' "${BASE_DIR}" "${RELEASES_DIR}" "${NEW_RELEASE_DIR}"
DEPLOY_TEMPLATE_EOF

sed -i \
	-e "s|__SITE_NAME__|${SITE_NAME}|g" \
	-e "s|__REPO_URL__|${REPO_URL}|g" \
	-e "s|__KEEP_RELEASES__|${KEEP_RELEASES}|g" \
	"${TMP_DEPLOY_SCRIPT}"

sudo install -m 750 -o deployer -g "${WEB_GROUP}" "${TMP_DEPLOY_SCRIPT}" "${DEPLOY_SCRIPT_PATH}"
rm -f "${TMP_DEPLOY_SCRIPT}"

echo "Done."
echo "Site: ${SITE_NAME}"
echo "Repo: ${REPO_URL}"
echo "Keep releases: ${KEEP_RELEASES}"
echo "Deployment script: ${DEPLOY_SCRIPT_PATH}"
echo "Run it as 'deployer': ${DEPLOY_SCRIPT_PATH} [branch]"
echo "Roll back with: ${DEPLOY_SCRIPT_PATH} --rollback"
```

- [ ] **Step 2: Check syntax and lint the full generator**

Run:
```bash
bash -n debian/laravel-deployment-generator.sh
shellcheck debian/laravel-deployment-generator.sh
```
Expected: both clean (no output / no findings). Fix anything shellcheck flags before continuing.

- [ ] **Step 3: Syntax-check and lint the embedded template on its own**

The template is embedded as literal text, so it can be extracted and checked independently of running the generator (which needs a real `/var/www/<site>` tree it can't have here):

```bash
awk '/<<.DEPLOY_TEMPLATE_EOF./{flag=1; next} /^DEPLOY_TEMPLATE_EOF$/{flag=0} flag' \
	debian/laravel-deployment-generator.sh > /tmp/rendered-laravel-deployment.sh

bash -n /tmp/rendered-laravel-deployment.sh
shellcheck /tmp/rendered-laravel-deployment.sh
rm -f /tmp/rendered-laravel-deployment.sh
```
Expected: `bash -n` exits 0 with no output (the `__SITE_NAME__` / `__REPO_URL__` / `__KEEP_RELEASES__` placeholders are just string content at this point, so they don't affect syntax validity); `shellcheck` reports no findings. Fix the template in Step 1 and re-run if either fails.

- [ ] **Step 4: Re-run Task 1's validation test matrix to confirm nothing regressed**

Run the same eight invocations from Task 1 Step 4. Expected: identical results — all eight still fail before reaching the new render/install code, since none of them have a real `/var/www/<site>` structure to pass the preflight checks.

- [ ] **Step 5: Commit**

```bash
git add debian/laravel-deployment-generator.sh
git commit -m "Render and install the generated laravel-deployment.sh"
```

---

## Task 3: Document the new script and run the repo-wide validation pass

**Files:**
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing consumed by other tasks — this is the final documentation/validation pass.

- [ ] **Step 1: Add a bullet describing the new script to `AGENTS.md`**

In `AGENTS.md`, the "Project Structure & Module Organization" section currently ends its bullet list with the `structure-setup.sh` paragraph (the one ending "...has to be moved aside by hand."). Add this new bullet directly after it, before the "There is no application source tree..." paragraph:

```markdown
- `laravel-deployment-generator.sh` writes a standalone, re-runnable
  `laravel-deployment.sh` into `/var/www/<site>/` for a site whose
  releases/shared/current layout `structure-setup.sh` already created. Takes
  `--site`, `--repo` (SSH GitHub URL only), and an optional `--keep-releases`
  (default 5) flag, and hard-stops if the site's structure is missing --
  it does not provision that layout itself. The generated script must run as
  `deployer`: `./laravel-deployment.sh [branch]` (defaults to `main`) clones
  that branch into a new timestamped release, runs Composer, migrations, and
  an asset build, then atomically swaps `current` onto it; `./laravel-deployment.sh
  --rollback` flips `current` back to the previous release on disk without
  touching migrations or `.env`. Safe to re-run -- every deploy clones a
  fresh release rather than mutating one in place, and releases beyond
  `--keep-releases` are pruned automatically.
```

- [ ] **Step 2: Run the full repo validation AGENTS.md documents**

Run:
```bash
bash -n debian/*.sh
shellcheck debian/*.sh
```
Expected: both clean across every script in `debian/`, including the two new ones.

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "Document laravel-deployment-generator.sh in AGENTS.md"
```

- [ ] **Step 4: Record the manual verification checklist**

This cannot be automated in this environment (no disposable Debian host, no real `deployer` user, no real `/var/www`). Before relying on this in production, run through it on a disposable Debian VM that already has `structure-setup.sh` applied for a test site with a real GitHub repo and deploy key configured for `deployer`:

1. `debian/laravel-deployment-generator.sh --site <site> --repo <ssh-url>` → confirm `/var/www/<site>/laravel-deployment.sh` is written, owned `deployer:www-data`, mode `750`.
2. As `deployer`: `/var/www/<site>/laravel-deployment.sh` (no args) → confirm it deploys `main`: new `releases/<timestamp>/`, Composer/migrate/cache steps succeed, `current` now points at the new release, PHP-FPM reloaded, site serves the new code.
3. As `deployer`: `/var/www/<site>/laravel-deployment.sh some-other-branch` → confirm a second release is created from that branch and `current` swaps to it.
4. Re-run the generator with `--keep-releases 1` and deploy again → confirm pruning deletes the oldest release beyond the configured count, and never deletes the one `current` points at.
5. As `deployer`: `/var/www/<site>/laravel-deployment.sh --rollback` → confirm `current` flips back to the previous release and PHP-FPM reloads; confirm it errors clearly when there's no older release to roll back to (e.g. run rollback twice in a row).
6. Confirm the hard-stops: run the generated script as a non-`deployer` user (expect refusal); run the generator against a site with no `structure-setup.sh` layout (expect refusal); run the generator with an HTTPS `--repo` URL (expect refusal).

No commit for this step — it's a verification record, not a code change. Report the results back before considering the feature production-ready.
