# Design: `debian-13/deployment/structure-setup.sh`

## Context

This is one of three standalone scripts replacing `debian-13/atomic-deployment-setup.sh`
(the old single 578-line script that provisioned the whole PHP/Laravel atomic
deployment). The three live side by side in `debian-13/deployment/`:

```
debian-13/deployment/
  structure-setup.sh   # this doc — atomic release/shared/current layout + permissions + .env
  nginx-tls-setup.sh   # Nginx vhost + Let's Encrypt/certbot
  database-setup.sh    # PostgreSQL role/database/extensions
```

`debian-13/atomic-deployment-setup.sh` is deleted. Each script is fully
self-contained — its own shebang, `set -euo pipefail`, preflight checks, prompts,
and helper functions. None of the three source each other or a shared lib, and none
pass state between each other via env vars or files; every script prompts for
everything it needs, even if a sibling script just asked for the same value. This
keeps each one copy-paste-independent of its siblings.

## Goal

Own the atomic release/shared/current directory layout, the Laravel-specific
storage/bootstrap-cache structure, the shared `.env` file, and the full permission
model for a site — as a single, self-contained creation step, separate from Nginx/TLS
and from PostgreSQL provisioning (those are the other two scripts).

## Prompts

- Site name (derives `BASE_DIR=/var/www/<site>`, `RELEASES_DIR`, `SHARED_DIR`,
  `CURRENT_LINK`).
- Laravel PostgreSQL database name, username, password — written into `.env` only.
  This script never touches Postgres itself; that's `database-setup.sh`'s job.

## Preflight

- Sudo present and usable (`sudo -n true`, falling back to an interactive `sudo true`
  prompt). No check on *which* user is running the script — only that they can sudo.
  Ownership written to disk stays hardcoded to `deployer:www-data` regardless of the
  executing user, matching the account the base setup script provisions and the
  `www-data` web-server group.
- `www-data` group exists.

## Does, in order

1. **Hard stop if `/var/www/<site>` already exists in any form.** This is a
   create-only script: it refuses outright rather than adopting, updating, or
   otherwise touching an existing site directory. No `current`-symlink adoption
   branch, no dangling-symlink handling — those only existed in the old script to
   make re-runs safe, and re-runs are not a supported use of this script.
2. Mint a new timestamped release directory.
3. Create the generic skeleton (`releases/`, `shared/logs/`, the release's
   `public/`) and the Laravel-specific skeleton (`shared/storage/...`,
   `shared/bootstrap/cache/`).
4. Create the shared `.env` file, lock it to `640` immediately.
5. `chown -R deployer:www-data` the whole site tree.
6. Point `current` at the release, symlink `storage/`, `bootstrap/cache/`, and
   `.env` from the release into the shared tree.
7. Write `DB_CONNECTION`/`DB_HOST`/`DB_PORT`/`DB_DATABASE`/`DB_USERNAME`/`DB_PASSWORD`
   into the freshly created `.env`.
8. Full permission pass: core structural perms (`755` on base/releases/shared dirs,
   conventional `755`/`644` across the release tree) plus Laravel runtime perms
   (`2775`/`664` with setgid on `storage/` and `bootstrap/cache/`), and re-lock
   `.env` to `640`.

## One-time execution, by design — not idempotent

Unlike the other two scripts, this one is intentionally *not* safe to re-run:
running it a second time for the same site is a hard failure (step 1), not a no-op.
This is deliberate — it removes any risk of silently reprovisioning permissions or
clobbering `.env` on a site that's already live.

One consequence worth knowing: if `database-setup.sh` is later used to rotate the
database password, that new password lives in Postgres but `.env` is never
rewritten after initial creation, so the operator must update `.env` by hand in that
case — this script provides no built-in way to do it after the site has been
created.

## Verification

- `bash -n debian-13/deployment/structure-setup.sh` (matches the repo's existing
  verification convention — no other lint/test tooling exists).
- Manual read-through comparing this script's logic against Groups 1, 2, 5, and 6 of
  the old `atomic-deployment-setup.sh` to confirm no behavior was dropped or
  reordered in a way that breaks a dependency (e.g. directories must exist before
  `chown -R`; `.env` must be locked to `640` immediately after creation, before any
  content is written).

## Documentation updates

`CLAUDE.md`'s repository layout and architecture sections get rewritten to describe
`structure-setup.sh` in place of the relevant parts of the old
`atomic-deployment-setup.sh` description, including:
- The new file path and what it owns.
- That it's create-only and hard-stops if `/var/www/<site>` already exists — the one
  script of the three that is *not* safe to re-run (contrast with
  `nginx-tls-setup.sh` and `database-setup.sh`, which remain safe to re-run).
- That the deployer-identity check from the old script is gone here: it only
  requires the executing user to have sudo, not to literally be logged in as
  `deployer`. Ownership of created files is still hardcoded to `deployer:www-data`.
- That it's fully self-contained by design (no shared lib, no cross-script state
  passing) so it can be copied and run elsewhere independently of its siblings.
