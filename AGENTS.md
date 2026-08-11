# Repository Guidelines

## Project Structure & Module Organization

This repository contains Bash scripts for provisioning Debian 13 (trixie) servers for Laravel/PostgreSQL
sites. All maintained scripts live in `debian13-laravel-postgresql/`, run in this order for a first-time
host + site setup:

- `01-packages-deployer.sh` installs base packages (curl, git, gpg, certbot, python3-certbot-nginx, ...)
  and creates the `deployer` user with passwordless sudo and SSH-key-only access. This is the only script
  that provisions the host account other scripts run as; it is idempotent (detects an existing user,
  sudoers drop-in, and authorized key before changing anything).
- `02-php-phpfpm-composer.sh <php-version>` installs PHP (default `8.5`) and common extensions from the
  Sury APT repository, installs Composer via its signed installer, and applies production PHP-FPM limits
  and pool tuning. Requires `gpg`, which `01-packages-deployer.sh` installs -- Debian 13 verifies APT
  signatures with Sequoia's `sqv` instead of `gpgv`, so `gnupg` is no longer pulled in by default and this
  script fails fast with an actionable message if run standalone on a minimal host.
- `03-nginx.sh` installs Nginx, stopping Apache first if it holds port 80. No-ops if Nginx is already
  installed.
- `04-postgresql.sh` installs PostgreSQL 18 from the PGDG APT repository, switches localhost TCP auth to
  `scram-sha-256` in `pg_hba.conf`, and applies conservative production tuning sized for a small VPS
  (1 vCPU / 4GB RAM).
- `05-folder-structure.sh` owns the atomic release/shared/current directory layout, the Laravel-specific
  `storage`/`bootstrap/cache` structure, the shared `.env` file, and the full permission model for a site
  -- standalone and re-runnable, with no dependency on `04-postgresql.sh`, `06-nginx-tls-vhost.sh`, or
  `07-database.sh` having run, and it never touches Postgres itself (`DB_*` values are written into
  `.env` only, as placeholders). Re-running against a site that already has a live deployment adopts the
  release `current` already points at instead of minting a new one, then reconverges `.env` and the
  permission pass; the only hard stop left is `current` existing as something other than a symlink, which
  has to be moved aside by hand.
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
- `07-database.sh` owns Laravel PostgreSQL role/database/extension (`pgcrypto`, `pg_trgm`) provisioning as
  a standalone, re-runnable step -- usable on its own (e.g. purely to rotate the database password) with
  no dependency on any other script in this repo. Safe to re-run -- it unconditionally rotates the role's
  password on every run. Optionally takes a site name and, when given one, rewrites just the `DB_*` lines
  in that site's shared `.env` (written by `05-folder-structure.sh`) to match; leave it blank to update
  `.env` by hand instead.
- `08-laravel-deployment.sh --repo <git@...>` [`--keep N`] prompts for the site name, matching
  `05-folder-structure.sh` and `06-nginx-tls-vhost.sh`'s convention -- it does not depend on the caller's
  current directory -- and generates a standalone, re-runnable `deploy.sh` into that site's base directory
  (`/var/www/<site name>`). Requires the `releases`/`shared` layout `05-folder-structure.sh` already
  created for that site. The generated `deploy.sh` (run as `deployer`) clones a branch over SSH into a new
  timestamped release, symlinks `storage`/`bootstrap/cache` into the shared tree, runs `composer install`,
  `php artisan migrate --force`, an `npm ci && npm run build` when `package.json` is present, caches
  config/routes/views, swaps `current`, reloads PHP-FPM, and prunes releases beyond `--keep` (default 5).
  It deliberately does not touch `.env` -- wiring/populating each new release's `.env` (e.g. symlinking it
  to `shared/.env`) is a manual step the operator does before or after a deploy. `deploy.sh --rollback`
  just flips `current` to the previous release -- it runs no migration rollback and does not revert `.env`.
- `09-static-web-deployment.sh` is a standalone, generic deploy script -- unlike `08-laravel-deployment.sh`,
  it has no framework-specific steps (no composer/npm/artisan), no shared-file symlinking, and no
  user/ownership handling. Given `--repo`, `--branch`, and `--dir`, it clones the branch into a new
  timestamped release under `<dir>/releases`, swaps `<dir>/current` onto that release's `dist/`
  subdirectory, and prunes releases beyond `--keep` (default 5); it fails without swapping if `dist/`
  isn't present in the cloned branch. `--rollback --dir <path>` flips `current` back to the `dist/`
  subdirectory of the release immediately older than the one it points at now. It deploys, it does not
  provision -- `<dir>/releases` must already exist before the first run.

`nginx/` holds reference Nginx vhost templates (`laravel.conf.template`, `nodejs.conf.template`,
`reactjs.conf.template`, `static-web.conf.template`) with `__PLACEHOLDER__` tokens for stacks the numbered
scripts don't automate end-to-end (Node.js reverse proxy, React SPA, plain static site). These are
standalone references meant to be hand-installed (e.g. via `sed`) -- `06-nginx-tls-vhost.sh` does not read
from them; it writes the Laravel-flavored vhost inline itself. Each documents the same two-phase
HTTP-then-HTTPS certbot rollout `06-nginx-tls-vhost.sh` performs.

There is no application source tree, asset directory, or automated test suite. Keep logic in focused scripts rather than unrelated top-level files.

## Build, Test, and Development Commands

The project has no build step. Validate changes from the repository root:

```bash
bash -n debian13-laravel-postgresql/*.sh
shellcheck debian13-laravel-postgresql/*.sh
```

`bash -n` checks syntax without executing actions; `shellcheck` performs static analysis. Use `git diff --check` for whitespace errors.

Run scripts only on a disposable Debian host; they install packages, modify `/etc`, manage services, and may prompt for credentials. Example: `bash debian13-laravel-postgresql/02-php-phpfpm-composer.sh 8.5`.

## Coding Style & Naming Conventions

Use `#!/usr/bin/env bash` and enable `set -euo pipefail` near the top. Indent blocks with tabs, quote expansions (`"${PHP_VERSION}"`), and use uppercase snake case for script-level variables. Name scripts in lowercase kebab case, such as `04-postgresql.sh`. Prefer preflight checks, actionable errors sent to stderr, and comments explaining operational risk.

Each new script must be standalone and independently executable. Do not rely on state created by another repository script unless the prerequisite is checked and clearly reported. Scripts must also be safely rerunnable: detect existing users, packages, files, and configuration before changing them, and make repeated runs converge on the same result without duplicate entries or failures.

## Testing Guidelines

Every change must pass `bash -n`; fix or document ShellCheck findings. With no test framework, exercise changes on a clean Debian VM and verify package versions, service state, configuration syntax, and safe reruns. Never test against production first.

## Commit & Pull Request Guidelines

Use short, imperative, sentence-case subjects, for example `Extract Nginx install into standalone step file`. Keep commits focused. Pull requests should identify affected scripts, host-level side effects, prerequisites, validation performed, and rollback or compatibility concerns. Link relevant issues; include terminal output only when it clarifies behavior.

## Security & Configuration Tips

Never commit private keys, passwords, `.env` files, or production host details. Validate user input before using it in paths, package names, SQL, or service configuration. Preserve least-privilege permissions and validate sensitive files (for example with `visudo`) before installation.
