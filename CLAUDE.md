# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A small collection of standalone Bash scripts for provisioning a Debian 13 VPS behind Nginx with PostgreSQL — either for a PHP/Laravel stack or a Node.js stack — and for deploying releases to it atomically. There is no application code, package manifest, or test framework — just operational shell scripts.

## Repository layout

- `debian-13/php-nginx-postgresql-setup.sh` — one-time base system setup for the PHP/Laravel path. Run as a sudo-capable user (not necessarily `deployer`). A thin orchestrator that runs the four standalone step files under `debian-13/php-nginx-postgresql-setup/` in order: `01-php.sh` (PHP 8.5 via Sury APT repo + FPM tuning), `02-nginx.sh` (Nginx), `03-postgresql.sh` (PostgreSQL 18 via PGDG APT repo with localhost TCP `scram-sha-256` auth and production tuning), and `04-deployer.sh` (creates the `deployer` user if absent — adding it to `sudo`, granting passwordless sudo via an `/etc/sudoers.d` drop-in, and installing an SSH key prompted for interactively or taken from `DEPLOYER_SSH_KEY` for unattended runs). Each step file has its own shebang, `set -euo pipefail`, and sudo-availability check, so it can also be run on its own — e.g. `bash debian-13/php-nginx-postgresql-setup/03-postgresql.sh` re-applies PostgreSQL setup/tuning without touching PHP, Nginx, or the deployer account. Does not install Composer — that remains a prerequisite this script assumes is handled separately. This script is intentionally generic — it does not touch any specific application's database.
- `debian-13/nodejs-nginx-postgresql-setup.sh` — one-time base system setup for the Node.js path. Creates the `deployer` user (adding it to `sudo`) if absent, then installs Node.js 24.x (via NodeSource APT repo), Nginx, and PostgreSQL 18 with the same localhost TCP `scram-sha-256` auth and production tuning as the PHP script. There is currently no Node.js-specific counterpart to `atomic-deployment-setup.sh` — that script's release layout and `.env` provisioning are still Laravel-specific.
- `debian-13/atomic-deployment-setup.sh` — per-site deployment bootstrap for the PHP/Laravel path. Must be run as the `deployer` user. Interactively prompts for site name, Nginx server name, Let's Encrypt domain/email, and Laravel PostgreSQL credentials (database name, username, password). Creates the atomic release directory layout, provisions the app's PostgreSQL role/database/extensions, writes `DB_*` values into the shared Laravel `.env`, writes an HTTP-only Nginx vhost, obtains a Let's Encrypt cert via webroot challenge, then rewrites the vhost as HTTP+HTTPS. Internally organized into numbered `GROUP` sections (preflight validation, input collection, structure creation, vhost/TLS, database provisioning, final permissions) — preserve that grouping when editing.

## Architecture: division of responsibility between the setup and deployment scripts

This split is deliberate and should be preserved when editing any of these scripts:

- **`php-nginx-postgresql-setup.sh`** / **`nodejs-nginx-postgresql-setup.sh`** each own *system-level* concerns for their stack: provisioning the `deployer` account, and installing the language runtime, Nginx, and PostgreSQL, plus generic PostgreSQL server auth (localhost TCP `scram-sha-256`) and tuning. Neither has knowledge of any specific site or app database. The `deployer` account belongs here rather than in `atomic-deployment-setup.sh` because that script must already be running *as* `deployer` before it starts, so it cannot bootstrap the account it depends on.
- **`atomic-deployment-setup.sh`** owns *per-site/app* concerns for the PHP/Laravel path: the atomic release directory structure, the site's Nginx vhost, TLS certificate issuance, and — importantly — the app-specific PostgreSQL role/database/extensions and the corresponding Laravel `.env` values. Laravel database provisioning lives here, not in the base setup script, so that database credentials are scoped to a single deployment run alongside the rest of that site's state.

### Atomic deployment layout created by `atomic-deployment-setup.sh`

```
/var/www/<site>/
  releases/<timestamp>/   # immutable per-release code; symlinks storage/, bootstrap/cache, .env into shared/
  shared/                 # persists across releases: .env, storage/, bootstrap/cache/, logs/
  current -> releases/<timestamp>  # symlink flipped on deploy; Nginx root always points here
```

Re-running the script against an existing site does not clobber an active deployment. If `current` already resolves to a directory, that release is *adopted* — `ACTIVE_RELEASE_DIR` is set to it, `current` is left pointing where it was, and no new release directory is minted. Everything downstream (the permission passes, the ACME webroot, the final summary) works off `ACTIVE_RELEASE_DIR`, so it always describes the release Nginx is actually serving. A dangling `current` counts as no deployment; a `current` that exists but is *not* a symlink is refused outright, because `ln -sfn` would silently create the link inside it rather than replace it.

## Working with these scripts

- There is no build, lint, or test tooling. The only verification step used in this repo's own change history is Bash syntax checking:
  ```bash
  bash -n debian-13/php-nginx-postgresql-setup.sh
  bash -n debian-13/php-nginx-postgresql-setup/01-php.sh
  bash -n debian-13/php-nginx-postgresql-setup/02-nginx.sh
  bash -n debian-13/php-nginx-postgresql-setup/03-postgresql.sh
  bash -n debian-13/php-nginx-postgresql-setup/04-deployer.sh
  bash -n debian-13/nodejs-nginx-postgresql-setup.sh
  bash -n debian-13/atomic-deployment-setup.sh
  ```
  Run this after editing any script before considering a change done.
- All three scripts use `set -euo pipefail` and validate preconditions (required commands, user identity, non-empty/pattern-matched input) up front with direct error messages and non-zero exits — match this style in any additions.
- `atomic-deployment-setup.sh` must be run as the `deployer` user; it checks `id -un` and exits otherwise.
- Destination files (Nginx configs, `.env`) are written to a `mktemp` temp file first and then moved/renamed into place, so a failed write never leaves a half-written config live. Preserve this pattern for any new generated file.
- Identifiers used in SQL or shell interpolation (site name, DB name, DB username) are validated against strict regexes (`^[a-zA-Z0-9.-]+$` for hostnames, `^[a-zA-Z_][a-zA-Z0-9_]*$` for SQL identifiers) before use — never interpolate unvalidated user input into the `psql` heredocs or Nginx config.
- These scripts are meant to be read and run directly on a target server (e.g. `bash debian-13/php-nginx-postgresql-setup.sh`), not executed as part of any CI/automation in this repo.
