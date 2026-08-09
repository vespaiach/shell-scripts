# Design: `debian-13/deployment/database-setup.sh`

## Context

This is one of three standalone scripts replacing `debian-13/atomic-deployment-setup.sh`
(the old single 578-line script that provisioned the whole PHP/Laravel atomic
deployment). The three live side by side in `debian-13/deployment/`:

```
debian-13/deployment/
  structure-setup.sh   # atomic release/shared/current layout + permissions + .env
  nginx-tls-setup.sh   # Nginx vhost + Let's Encrypt/certbot
  database-setup.sh    # this doc — PostgreSQL role/database/extensions
```

`debian-13/atomic-deployment-setup.sh` is deleted. Each script is fully
self-contained — its own shebang, `set -euo pipefail`, preflight checks, prompts,
and helper functions. None of the three source each other or a shared lib, and none
pass state between each other via env vars or files; every script prompts for
everything it needs, even if a sibling script just asked for the same value. This
keeps each one copy-paste-independent of its siblings.

## Goal

Own PostgreSQL role/database/extension provisioning for the site's Laravel app as a
standalone, re-runnable step — usable on its own (e.g. purely to rotate the database
password) with no dependency on `structure-setup.sh` or `nginx-tls-setup.sh` having
run at all.

## Prompts

- Laravel PostgreSQL database name.
- Laravel PostgreSQL username.
- Laravel PostgreSQL password.

## Preflight

- Sudo present and usable (`sudo -n true`, falling back to an interactive `sudo
  true` prompt). No check on *which* user is running the script — only that they can
  sudo.
- `psql` present.

## Does

Same flow as Group 4 of the old script:
1. Create the role if it doesn't exist, then unconditionally `ALTER ROLE ... WITH
   LOGIN PASSWORD` (so re-running rotates the password).
2. Create the database if it doesn't exist, then `ALTER DATABASE ... OWNER TO`.
3. Ensure the `pgcrypto` and `pg_trgm` extensions exist.

Same `\gexec`-based DDL and same stdin-based password passing (never argv) as
today, since that already avoids leaking the password via `/proc/<pid>/cmdline`.

## Idempotent — safe to re-run

Identical guards to the old script — already safe to re-run, e.g. purely to rotate
the database password. No dependency on the other two scripts; can run in any order
relative to them, including before either has ever run.

One consequence worth knowing (documented from the `structure-setup.sh` side too):
rotating the password here updates Postgres but does **not** update the Laravel
`.env` file — `structure-setup.sh` is create-only and won't rewrite `.env` after the
site exists, so the operator must update `.env` by hand after rotating a password
here.

## Verification

- `bash -n debian-13/deployment/database-setup.sh` (matches the repo's existing
  verification convention — no other lint/test tooling exists).
- Manual read-through comparing this script's logic against Group 4 of the old
  `atomic-deployment-setup.sh` to confirm no behavior was dropped, especially the
  stdin-based password passing.

## Documentation updates

`CLAUDE.md`'s repository layout and architecture sections get rewritten to describe
`database-setup.sh` in place of the relevant parts of the old
`atomic-deployment-setup.sh` description, including:
- The new file path and what it owns.
- That it has no ordering dependency on the other two scripts.
- That it remains safe to re-run, like both of its siblings, and the
  `.env`-goes-stale caveat when it's used to rotate a password after the site
  already exists — though rerunning `structure-setup.sh` with the new password
  is the built-in way to resync `.env` afterward.
- That the deployer-identity check from the old script is gone here: it only
  requires the executing user to have sudo, not to literally be logged in as
  `deployer`.
- That it's fully self-contained by design (no shared lib, no cross-script state
  passing) so it can be copied and run elsewhere independently of its siblings.
