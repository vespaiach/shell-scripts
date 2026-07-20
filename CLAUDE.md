# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A small collection of standalone Bash scripts for provisioning a Debian 13 VPS to host a Laravel + PostgreSQL application behind Nginx, and for deploying releases to it atomically. There is no application code, package manifest, or test framework — just operational shell scripts and the design docs that drove their most recent change.

## Repository layout

- `debian-13/php-nginx-postgresql-setup.sh` — one-time base system setup. Run as a sudo-capable user (not necessarily `deployer`). Installs PHP 8.5 (via Sury APT repo) + FPM tuning, Nginx, PostgreSQL 18 (via PGDG APT repo) with localhost TCP `scram-sha-256` auth and production tuning, and Composer (with installer signature verification). This script is intentionally generic — it does not touch any specific application's database.
- `debian-13/atomic-deployment-setup.sh` — per-site deployment bootstrap. Must be run as the `deployer` user. Interactively prompts for site name, Nginx server name, Let's Encrypt domain/email, and Laravel PostgreSQL credentials (database name, username, password). Creates the atomic release directory layout, provisions the app's PostgreSQL role/database/extensions, writes `DB_*` values into the shared Laravel `.env`, writes an HTTP-only Nginx vhost, obtains a Let's Encrypt cert via webroot challenge, then rewrites the vhost as HTTP+HTTPS.
- `docs/superpowers/specs/` and `docs/superpowers/plans/` — design docs and step-by-step implementation plans for changes to the scripts above, written for the `superpowers` Claude Code skill workflow (spec first, then a checkbox-driven plan consumed by `superpowers:subagent-driven-development` / `superpowers:executing-plans`). When making a non-trivial change to either setup script, follow this repo's existing pattern: write a dated design doc under `docs/superpowers/specs/` and a corresponding checkbox plan under `docs/superpowers/plans/`.

## Architecture: division of responsibility between the two scripts

This split is deliberate and should be preserved when editing either script:

- **`php-nginx-postgresql-setup.sh`** owns *system-level* concerns: installing PHP/Nginx/PostgreSQL/Composer, and generic PostgreSQL server auth (localhost TCP `scram-sha-256`) and tuning. It has no knowledge of any specific site or app database.
- **`atomic-deployment-setup.sh`** owns *per-site/app* concerns: the atomic release directory structure, the site's Nginx vhost, TLS certificate issuance, and — importantly — the app-specific PostgreSQL role/database/extensions and the corresponding Laravel `.env` values. Laravel database provisioning lives here, not in the base setup script, so that database credentials are scoped to a single deployment run alongside the rest of that site's state.

### Atomic deployment layout created by `atomic-deployment-setup.sh`

```
/var/www/<site>/
  releases/<timestamp>/   # immutable per-release code; symlinks storage/, bootstrap/cache, .env into shared/
  shared/                 # persists across releases: .env, storage/, bootstrap/cache/, logs/
  current -> releases/<timestamp>  # symlink flipped on deploy; Nginx root always points here
```

`current` is only created if absent, so re-running the script against an existing site does not clobber an active deployment.

## Working with these scripts

- There is no build, lint, or test tooling. The only verification step used in this repo's own change history is Bash syntax checking:
  ```bash
  bash -n debian-13/php-nginx-postgresql-setup.sh
  bash -n debian-13/atomic-deployment-setup.sh
  ```
  Run this after editing either script before considering a change done.
- Both scripts use `set -euo pipefail` and validate preconditions (required commands, user identity, non-empty/pattern-matched input) up front with direct error messages and non-zero exits — match this style in any additions.
- `atomic-deployment-setup.sh` must be run as the `deployer` user; it checks `id -un` and exits otherwise.
- Destination files (Nginx configs, `.env`) are written to a `mktemp` temp file first and then moved/renamed into place, so a failed write never leaves a half-written config live. Preserve this pattern for any new generated file.
- Identifiers used in SQL or shell interpolation (site name, DB name, DB username) are validated against strict regexes (`^[a-zA-Z0-9.-]+$` for hostnames, `^[a-zA-Z_][a-zA-Z0-9_]*$` for SQL identifiers) before use — never interpolate unvalidated user input into the `psql` heredocs or Nginx config.
- These scripts are meant to be read and run directly on a target server (e.g. `bash debian-13/php-nginx-postgresql-setup.sh`), not executed as part of any CI/automation in this repo.
