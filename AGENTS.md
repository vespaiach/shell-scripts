# Repository Guidelines

## Project Structure & Module Organization

This repository contains Bash scripts for provisioning Debian servers. All maintained scripts live in `debian/`:

- `*-setup.sh` and numbered `0N-*.sh` files configure focused services or complete PHP/Node.js stacks.
- `01-packages-and-deployer.sh` and `atomic-deployment-setup.sh` manage deployment users and releases.
- `05-postgresql-database.sh` owns Laravel PostgreSQL role/database/extension (`pgcrypto`, `pg_trgm`)
  provisioning as a standalone, re-runnable step -- usable on its own (e.g. purely to rotate the
  database password) with no dependency on any other script in this repo. Like the rest of the
  repo's newer scripts, its preflight only requires the executing user to have sudo, not to be
  logged in as `deployer`. Safe to re-run -- it unconditionally rotates the role's password on
  every run -- but rotating the password here updates PostgreSQL only; it does **not** rewrite a
  site's Laravel `.env`. Rerun `06-folder-structure.sh` with the new password to resync `.env`
  afterward if the site already exists.
- `06-folder-structure.sh` owns the atomic release/shared/current directory layout, the
  Laravel-specific `storage`/`bootstrap/cache` structure, the shared `.env` file, and the full
  permission model for a site -- also standalone and re-runnable, with no dependency on
  `05-postgresql-database.sh` or `07-nginx-tls-vhost.sh` having run, and it never touches Postgres
  itself (`DB_*` values are written into `.env` only). Re-running against a site that already has a
  live deployment adopts the release `current` already points at instead of minting a new one, then
  reconverges `.env` and the permission pass; the only hard stop left is `current` existing as
  something other than a symlink, which has to be moved aside by hand.
- `07-nginx-tls-vhost.sh` owns the site's Nginx vhost and Let's Encrypt/certbot TLS issuance --
  also standalone and re-runnable, with no dependency on `05-postgresql-database.sh` having run.
  Its one hard precondition is `06-folder-structure.sh` having already run for the site: it exits
  immediately if `/var/www/<site>/current/public` doesn't exist yet, rather than writing a vhost
  that points at a webroot that isn't there. Like its siblings, its preflight only requires sudo,
  not a `deployer` login. Vhost files are always fully rewritten via temp-file-then-move and
  certbot itself is idempotent, so it's safe to re-run to change the server name, redo the renewal
  verification, or recover from a manually broken vhost. This completes the planned three-way split
  of `atomic-deployment-setup.sh`'s monolithic flow into standalone structure/nginx-TLS/database
  steps. `atomic-deployment-setup.sh` still exists in this repo but is now superseded by the three
  split scripts above.
- `09-deployment.sh` is a standalone, generic deploy script -- unlike
  `08-laravel-deployment.sh`, it has no framework-specific steps (no
  composer/npm/artisan), no shared-file symlinking, and no user/ownership
  handling. Given `--repo`, `--branch`, and `--dir`, it clones the branch
  into a new timestamped release under `<dir>/releases`, swaps
  `<dir>/current` onto that release's `dist/` subdirectory, and prunes
  releases beyond `--keep` (default 5); it fails without swapping if
  `dist/` isn't present in the cloned branch. `--rollback --dir <path>`
  flips `current` back to the `dist/` subdirectory of the release
  immediately older than the one it points at now. It deploys, it does
  not provision -- `<dir>/releases` must already exist before the first
  run.

There is no application source tree, asset directory, or automated test suite. Keep logic in focused scripts rather than unrelated top-level files.

## Build, Test, and Development Commands

The project has no build step. Validate changes from the repository root:

```bash
bash -n debian/*.sh
shellcheck debian/*.sh
```

`bash -n` checks syntax without executing actions; `shellcheck` performs static analysis. Use `git diff --check` for whitespace errors.

Run scripts only on a disposable Debian host; they install packages, modify `/etc`, manage services, and may prompt for credentials. Example: `bash debian/02-php-and-phpfpm.sh 8.5`.

## Coding Style & Naming Conventions

Use `#!/usr/bin/env bash` and enable `set -euo pipefail` near the top. Indent blocks with tabs, quote expansions (`"${PHP_VERSION}"`), and use uppercase snake case for script-level variables. Name scripts in lowercase kebab case, such as `04-postgresql.sh`. Prefer preflight checks, actionable errors sent to stderr, and comments explaining operational risk.

Each new script must be standalone and independently executable. Do not rely on state created by another repository script unless the prerequisite is checked and clearly reported. Scripts must also be safely rerunnable: detect existing users, packages, files, and configuration before changing them, and make repeated runs converge on the same result without duplicate entries or failures.

## Testing Guidelines

Every change must pass `bash -n`; fix or document ShellCheck findings. With no test framework, exercise changes on a clean Debian VM and verify package versions, service state, configuration syntax, and safe reruns. Never test against production first.

## Commit & Pull Request Guidelines

Use short, imperative, sentence-case subjects, for example `Extract Nginx install into standalone step file`. Keep commits focused. Pull requests should identify affected scripts, host-level side effects, prerequisites, validation performed, and rollback or compatibility concerns. Link relevant issues; include terminal output only when it clarifies behavior.

## Security & Configuration Tips

Never commit private keys, passwords, `.env` files, or production host details. Validate user input before using it in paths, package names, SQL, or service configuration. Preserve least-privilege permissions and validate sensitive files (for example with `visudo`) before installation.
