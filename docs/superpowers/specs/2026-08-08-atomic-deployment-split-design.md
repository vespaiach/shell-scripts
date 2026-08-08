# Design: Split `atomic-deployment-setup.sh` into standalone, idempotent scripts

## Context

`debian-13/atomic-deployment-setup.sh` is a single 578-line script that provisions a
per-site atomic deployment for the PHP/Laravel path: the release/shared/current
directory layout, the site's Nginx vhost, TLS certificate issuance, PostgreSQL
role/database/extension provisioning, and the Laravel `.env` file. It already went
through one reorganization into commented `GROUP` sections, but it remains one file
that must be run start-to-finish.

## Goal

Break the script into standalone, independently runnable, idempotent scripts, so an
operator can re-run just the piece they need (e.g. rotate a DB password without
touching Nginx, or reissue a certificate without recreating the release structure)
instead of re-running — or hand-editing — the whole thing. This also lays groundwork
for reuse: pieces that are genuinely stack-agnostic (release layout, TLS/certbot
mechanics) are recognizable as such even though, for now, only the Laravel path
consumes them.

## Non-goals

- No Node.js counterpart script is being written now. `nodejs-nginx-postgresql-setup.sh`
  and `php-nginx-postgresql-setup.sh` are untouched.
- No cross-script state file or environment-variable short-circuiting. Every script
  prompts for what it needs, every time, even if a sibling script just asked for the
  same value. Simpler and more predictable than partial state-sharing.
- No shared helper library between the three scripts. Each is fully self-contained,
  including small duplicated helpers (escaping functions, the sudo-capability check),
  so any one of the three can be copied and run elsewhere without its siblings.
- No top-level wrapper script. `atomic-deployment-setup.sh` is retired outright. The
  three new scripts are the entire interface.

## File layout

```
debian-13/deployment/
  structure-setup.sh   # atomic release/shared/current layout + permissions + .env
  nginx-tls-setup.sh   # Nginx vhost + Let's Encrypt/certbot
  database-setup.sh    # PostgreSQL role/database/extensions
```

`debian-13/atomic-deployment-setup.sh` is deleted.

## Script 1: `structure-setup.sh`

**Prompts:** site name (derives `BASE_DIR=/var/www/<site>`, etc.); Laravel PostgreSQL
database name, username, password (written into `.env` only — this script never
touches Postgres itself).

**Preflight:** sudo present and usable (`sudo -n true`, falling back to an interactive
`sudo true` prompt); `www-data` group exists. No check on *which* user is running the
script — only that they can sudo. Ownership written to disk stays hardcoded to
`deployer:www-data` regardless of the executing user, matching the account the base
setup script provisions and the `www-data` web-server group — this is about loosening
who may *run* the script, not about changing who *owns* the resulting files.

**Does**, in order:
1. Validate `current` is either absent, a dangling symlink, or a symlink to a real
   release directory (refuse if it exists and is not a symlink — `ln -sfn` would nest
   inside it rather than replace it).
2. Adopt the existing release if `current` already resolves to one; otherwise mint a
   new timestamped release directory. (Same logic as today's Group 2.)
3. Create the generic skeleton (`releases/`, `shared/logs/`, the active release's
   `public/`) and the Laravel-specific skeleton (`shared/storage/...`,
   `shared/bootstrap/cache/`).
4. Create the shared `.env` file if absent, lock it to `640` immediately.
5. `chown -R deployer:www-data` the whole site tree.
6. If not adopting: point `current` at the release, symlink `storage/`,
   `bootstrap/cache/`, and `.env` from the release into the shared tree.
7. Write `DB_CONNECTION`/`DB_HOST`/`DB_PORT`/`DB_DATABASE`/`DB_USERNAME`/`DB_PASSWORD`
   into `.env`, replacing any prior `DB_*` lines and preserving everything else
   (temp-file-then-move, as today).
8. Full permission pass: core structural perms (`755` on base/releases/shared dirs,
   conventional `755`/`644` across the active release tree) plus Laravel runtime
   perms (`2775`/`664` with setgid on `storage/` and `bootstrap/cache/`), and
   re-lock `.env` to `640`.

**Idempotent:** every step above is safe to repeat. Re-running with the same site
name adopts the existing release rather than minting a new one; `.env` `DB_*` lines
are replaced, not duplicated; all `mkdir -p`/`chmod`/`chown` calls are naturally
repeatable. This makes the script usable on its own just to rotate DB credentials in
`.env`, or to re-assert permissions after manual drift, without touching Nginx or TLS.

## Script 2: `nginx-tls-setup.sh`

**Prompts:** site name; Nginx server name (default: site name); Let's Encrypt
certificate domain (default: site name); Let's Encrypt notification email.

**Preflight:** sudo present and usable; `nginx -t` passes; certbot present;
**`${BASE_DIR}/current/public` must already exist** — if not, exit with a message
telling the operator to run `structure-setup.sh` for this site first, rather than
writing a vhost that points at a webroot that doesn't exist yet.

**Does**, in order (same flow as today's Group 3):
1. Detect the PHP-FPM socket (prefer `php8.5-fpm.sock`, fall back to the first
   detected `php*-fpm.sock`, warn if none found).
2. Write an HTTP-only vhost (redirects to HTTPS, serves the ACME challenge path),
   enable it, `nginx -t`, reload.
3. Request the Let's Encrypt certificate via webroot (`certbot certonly`).
4. Rewrite the vhost as HTTP+HTTPS (with the PHP-FPM `fastcgi_pass` block, security
   headers, static-asset caching, hidden-file blocking), `nginx -t`, reload.
5. Verify auto-renewal: `certbot.timer` enabled, and a `certbot renew --dry-run`
   for this domain succeeds. Records success/failure but doesn't abort the script
   over it — reported and exited on at the very end, same as today.

**Idempotent:** vhost files are always fully rewritten via temp-file-then-move, so
re-running with the same or updated inputs (e.g. an added server alias) converges to
the same result. Certbot itself is idempotent — `certonly` against an existing valid,
non-expiring certificate does not reissue it. Safe to re-run to change the server
name, redo the renewal check, or recover from a manually broken vhost.

## Script 3: `database-setup.sh`

**Prompts:** Laravel PostgreSQL database name, username, password.

**Preflight:** sudo present and usable; `psql` present.

**Does** (same flow as today's Group 4): create the role if it doesn't exist, then
unconditionally `ALTER ROLE ... WITH LOGIN PASSWORD` (so re-running rotates the
password); create the database if it doesn't exist, then `ALTER DATABASE ... OWNER
TO`; ensure `pgcrypto` and `pg_trgm` extensions exist. Same `\gexec`-based DDL and
same stdin-based password passing (never argv) as today, since that already avoids
leaking the password via `/proc/<pid>/cmdline`.

**Idempotent:** identical guards to today — already safe to re-run, e.g. purely to
rotate the database password. No dependency on the other two scripts; can run in any
order relative to them.

## Verification

- `bash -n` on all three new files (matches the repo's existing verification
  convention — no other lint/test tooling exists).
- Manual read-through comparing each script's logic against the corresponding GROUP
  in the current `atomic-deployment-setup.sh` to confirm no behavior was dropped or
  reordered in a way that breaks a dependency (e.g. directories must exist before
  `chown -R`; `.env` must be locked to `640` immediately after creation, before any
  content is written).

## Documentation updates

`CLAUDE.md`'s repository layout and architecture sections get rewritten to describe
the three scripts under `debian-13/deployment/` in place of the single
`atomic-deployment-setup.sh` description, including:
- The new file paths and what each owns.
- That a fresh site needs all three run once each; only `nginx-tls-setup.sh` has a
  hard precondition (structure must exist first) — `database-setup.sh` has no
  ordering dependency on the other two.
- That each script is fully self-contained by design (no shared lib, no
  cross-script state passing) so that any one of them can be copied and run
  elsewhere independently.
- That the deployer-identity check from the old script is gone: the three scripts
  only require the executing user to have sudo, not to literally be logged in as
  `deployer`. Ownership of created files is still hardcoded to `deployer:www-data`.
