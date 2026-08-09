# Laravel Deployment Generator — Design

## Problem

The repo's existing scripts provision server infrastructure for a Laravel site
(`01`–`06`, `atomic-deployment-setup.sh`) and the atomic `releases/shared/current`
directory layout (`06-folder-structure.sh`, `atomic-deployment-setup.sh`). None
of them actually pull application source from GitHub into that layout. There is
currently no repeatable way to deploy (or redeploy) a Laravel codebase into an
already-provisioned site.

## Goals

- A generator script that, given a site's identity and its GitHub repo, writes
  a standalone, re-runnable `laravel-deployment.sh` into that site's directory.
- The generated script does the actual work on every invocation: clone a
  branch into a new timestamped release, build it, and atomically swap
  `current` onto it, following the same zero-downtime pattern already
  established by `structure-setup.sh` / `atomic-deployment-setup.sh`.
- Support rolling back to the previous release without a full redeploy.

## Non-goals

- Provisioning Nginx, TLS, PHP-FPM, or PostgreSQL — those remain the job of
  the existing scripts.
- Creating or managing SSH deploy keys — the generated script assumes
  `deployer` already has working SSH access to the repo.
- Rolling back database migrations — rollback is a `current` symlink flip
  only.

## Two scripts

### 1. `debian/laravel-deployment-generator.sh` (run once per site)

Run interactively-free, with flags, by an operator with sudo:

```
--site <name>          required, e.g. app.mysite.com
--repo <ssh-url>        required, e.g. git@github.com:org/repo.git
--keep-releases <n>     optional, default 5
```

Branch is **not** a generator-time input — see below.

**Preflight** (fail fast, before writing anything):
- `sudo` available.
- `--site` matches the same strict hostname/domain-like pattern used by
  `structure-setup.sh` (`^[a-zA-Z0-9.-]+$`).
- `--repo` looks like an SSH GitHub URL (`git@github.com:owner/repo.git`
  shape) — this is an SSH-only deploy-key workflow, not HTTPS.
- `--keep-releases` is a positive integer; warn (don't fail) if `< 2`, since
  rollback needs at least one older release on disk to roll back to.
- `/var/www/<site>/{releases,shared,current}` already exist and look like the
  layout `structure-setup.sh` produces (`releases/` and `shared/` are
  directories; `current` is absent or a symlink). If missing, hard-stop with
  "run structure-setup.sh first" — this script does not duplicate that setup.

**Action:** render `/var/www/<site>/laravel-deployment.sh` from a heredoc
template with `SITE_NAME`, `REPO_URL`, and `KEEP_RELEASES` baked in as
constants, then `chown deployer:www-data` and `chmod 750` it. Overwrites any
existing file at that path unconditionally — consistent with this repo's
re-runnable convention (e.g. `structure-setup.sh` converging on rerun rather
than refusing).

### 2. Generated `/var/www/<site>/laravel-deployment.sh`

Must be run as `deployer` (hard stop otherwise, matching
`atomic-deployment-setup.sh`'s existing convention) — `deployer` owns the
tree and holds the GitHub SSH deploy key.

**Usage:**
```
./laravel-deployment.sh              # deploy 'main'
./laravel-deployment.sh <branch>     # deploy <branch>
./laravel-deployment.sh --rollback   # roll back to the previous release
```
`BRANCH="${1:-main}"` when the first arg isn't `--rollback`.

**Deploy mode:**
1. Preflight: `git`, `composer`, `php` on `PATH`; `/var/www/<site>/{releases,shared}`
   still present; shared `.env` file still present.
2. `NEW_RELEASE_DIR="${RELEASES_DIR}/$(date +%Y%m%d%H%M%S)"`; `git clone
   --branch "${BRANCH}" --single-branch --depth 1 "${REPO_URL}"
   "${NEW_RELEASE_DIR}"`.
3. Remove any `.env`, `storage`, `bootstrap/cache` the clone brought (a repo
   might ship placeholder versions); symlink each to the shared equivalents
   (`SHARED_ENV_FILE`, `SHARED_STORAGE_DIR`, `SHARED_BOOTSTRAP_CACHE_DIR`) —
   same targets `structure-setup.sh` already created.
4. `composer install --no-dev --optimize-autoloader --no-interaction` (runs
   inside `NEW_RELEASE_DIR`; `.env` is already symlinked in by step 3, so any
   post-install artisan hooks have DB config available).
5. `php artisan migrate --force`.
6. `php artisan config:cache && php artisan route:cache && php artisan view:cache`.
7. If `package.json` exists at the release root: `npm ci && npm run build`.
   Skipped entirely otherwise — not every Laravel app ships frontend assets.
8. Permission pass on `NEW_RELEASE_DIR` only (755 dirs / 644 files), mirroring
   `structure-setup.sh`'s `set_core_permissions` — must happen before the
   swap so Nginx/PHP-FPM can read the release the instant `current` points at
   it.
9. Atomic swap: `sudo ln -sfn "${NEW_RELEASE_DIR}" "${CURRENT_LINK}"`.
10. Reload PHP-FPM: detect the active `php*-fpm` systemd service (same
    detection approach `atomic-deployment-setup.sh` uses for the socket path)
    and `sudo systemctl reload` it.
11. Prune releases beyond `KEEP_RELEASES`, oldest first, by directory name
    (timestamps sort lexicographically) — never touches the release `current`
    points at, which is always the newest.
12. Print a summary: site, branch deployed, new release path, permission
    summary — matching the final-summary style of `structure-setup.sh`.

**Failure handling:** `set -euo pipefail` means any failure through step 8
aborts before `current` is touched — the old release keeps serving
unaffected. The partial `NEW_RELEASE_DIR` is left on disk (not
auto-deleted) so a failed deploy can be inspected; the next successful deploy
or a manual `rm -rf` cleans it up. This mirrors the repo's existing
"actionable errors, no silent cleanup" style.

**Rollback mode** (`--rollback`):
1. Resolve what `current` points at.
2. List `RELEASES_DIR` entries sorted descending, find the first one older
   than the current target.
3. If none exists, error clearly: "no older release to roll back to" and
   exit non-zero.
4. `sudo ln -sfn "${PREVIOUS_RELEASE_DIR}" "${CURRENT_LINK}"`.
5. Reload PHP-FPM (same detection/reload as step 10 above).
6. Print a summary: rolled back from `<release>` to `<release>`.

**Caveat, stated in-script as a comment** (same honesty convention as
`database-setup.sh`'s password-rotation caveat): rollback only flips the
`current` symlink. It does not run any migration rollback (`artisan
migrate:rollback`) and does not revert `.env`. If the deploy being rolled
back away from included a schema migration, the previous release's code may
not be compatible with the current schema — that has to be handled by hand.

**Privilege model:** `git`, `composer`, `npm`, `artisan`, and the symlink
operations run directly as `deployer` (who already owns the tree per
`structure-setup.sh`'s `chown -R deployer:www-data`). Only the `current`
symlink swap and the PHP-FPM reload go through `sudo`, matching
`atomic-deployment-setup.sh`'s existing mix of sudo/non-sudo calls.

## Testing

Per `AGENTS.md`: `bash -n` both scripts, run `shellcheck`, and exercise on a
disposable Debian VM that already has `structure-setup.sh` applied — verify a
fresh deploy, a redeploy (second release, prune behavior once past
`--keep-releases`), a rollback, and the hard-stop paths (wrong user, missing
structure, non-SSH repo URL).
