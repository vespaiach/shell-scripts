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

1. **Adopt the existing release if `/var/www/<site>/current` already resolves to
   one, otherwise mint a new one.** If `current` exists but is not a symlink, hard
   stop — `ln -sfn` cannot safely repoint that, it would nest the link inside the
   real directory instead of replacing it, so the operator must move it aside
   first. If `current` is a symlink to a real directory, adopt that directory as
   the active release: no new release directory is minted, and step 6's symlinks
   are left untouched since that release is already wired. A dangling symlink (or
   no `current` at all) is treated as no deployment yet, same as a brand-new site.
2. Mint a new timestamped release directory (skipped when adopting).
3. Create the generic skeleton (`releases/`, `shared/logs/`, the release's
   `public/`) and the Laravel-specific skeleton (`shared/storage/...`,
   `shared/bootstrap/cache/`). Runs unconditionally — `mkdir -p` is a no-op on
   directories that already exist, so this converges whether or not the release
   was just adopted.
4. Create the shared `.env` file, lock it to `640` immediately. `touch` is a
   no-op on a file that already exists, so this never clobbers content.
5. `chown -R deployer:www-data` the whole site tree.
6. Point `current` at the release, symlink `storage/`, `bootstrap/cache/`, and
   `.env` from the release into the shared tree. Skipped when adopting an
   existing release (see step 1).
7. Write `DB_CONNECTION`/`DB_HOST`/`DB_PORT`/`DB_DATABASE`/`DB_USERNAME`/`DB_PASSWORD`
   into `.env`, replacing any prior `DB_*` lines while preserving everything else
   already there. Runs unconditionally, so a rerun with a new password converges
   `.env` to match it.
8. Full permission pass: core structural perms (`755` on base/releases/shared dirs,
   conventional `755`/`644` across the release tree) plus Laravel runtime perms
   (`2775`/`664` with setgid on `storage/` and `bootstrap/cache/`), and re-lock
   `.env` to `640`. Runs unconditionally so a rerun catches any drift.

## Idempotent by design

Unlike the original combined script's fully hands-off re-run behavior, this one
narrows re-runs to a single, well-defined convergence path: adopt whatever release
`current` already points at (step 1) rather than minting an orphan release or
repointing a live site, then re-apply the `.env` content and permission pass
unconditionally. Running it a second time for the same site is a no-op on the
directory layout and a controlled refresh of `.env` and permissions — not a hard
failure, and not a silent reprovision either, since the only things that change on
a rerun are exactly the values the operator just typed in.

One consequence worth knowing: because step 7 rewrites `DB_*` unconditionally, this
also gives the operator a built-in way to sync `.env` after `database-setup.sh`
rotates the database password — rerun this script with the new password — where
the prior create-only design had no such path.

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
- That it's safe to re-run, like its two siblings: a rerun against a site that
  already exists adopts the release `current` points at rather than minting an
  orphan release or refusing to run, then reconverges `.env` and permissions to
  match whatever was just typed in. The only hard stop left is `current` existing
  as something other than a symlink, which the operator has to move aside by hand.
- That the deployer-identity check from the old script is gone here: it only
  requires the executing user to have sudo, not to literally be logged in as
  `deployer`. Ownership of created files is still hardcoded to `deployer:www-data`.
- That it's fully self-contained by design (no shared lib, no cross-script state
  passing) so it can be copied and run elsewhere independently of its siblings.
