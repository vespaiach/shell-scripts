# Atomic Deployment Script Grouping Design

Date: 2026-07-20

## Goal

Reorganize `debian-13/atomic-deployment-setup.sh` into clearly delimited, heavily commented groups so the script's flow reads as a sequence of named phases instead of one long flat list of statements. This is a structural/comment refactor: no prompts, validation regexes, SQL, Nginx config content, or directory layout change.

## Scope

- Regroup the existing script into 7 top-to-bottom sections (Group 0 through Group 6, see below).
- Add a banner comment before each group explaining what it does and, where non-obvious, why it's ordered where it is.
- Reorder the Nginx/SSL group ahead of the database group (today the database is provisioned first; the two are independent, so this is a pure reorder).
- Split permission-setting between an early inline subset (Group 2) and a comprehensive final pass (Group 6), per the "Permission split" section below.
- Factor the permission commands shared between Group 2 and Group 6 into one small helper function to avoid literal duplication.
- No new prompts, no new validation rules, no change to SQL, no change to Nginx config content, no change to the directory layout described in `CLAUDE.md`.

## Design

### Group order

```
0. Preflight validation
1. Collect user's input
2. Create atomic deployment structure
3. Configure Nginx server and issue Let's Encrypt SSL
4. Create database role, database, and extensions
5. Create/update shared .env file
6. Check and update permissions (final pass)
```

### Group 0: Preflight validation

Unchanged content, given its own banner. Covers: `deployer` user check, `sudo` availability and access, `nginx -t` availability, `certbot` availability.

### Group 1: Collect user's input

Unchanged prompts and validation, given a banner. Covers: site name, Nginx server name, Let's Encrypt domain/email, Laravel database name/username/password, including all existing regex validation and the `psql` availability check.

### Group 2: Create atomic deployment structure

Creates the directory skeleton, symlinks, and the empty shared `.env` file, per the layout documented in `CLAUDE.md`.

Sets only the permissions required for the rest of the script to function correctly before Group 6 runs:

- `chown -R deployer:www-data` on `BASE_DIR`.
- `chmod 755` on `BASE_DIR`, `RELEASES_DIR`, `SHARED_DIR`.
- `755`/`644` on the first release's directory tree (dirs/files respectively), via the shared `set_core_permissions()` helper (see below) — required so Nginx (running as `www-data`) can read and serve `current/public` during the Group 3 Let's Encrypt webroot challenge.
- `chmod 640` on the shared `.env` file immediately after `touch`, even though it's still empty at this point, for defense in depth (never leave it at default `touch` permissions, even briefly).

Explicitly does **not** set `storage/`/`bootstrap/cache/` setgid permissions here — those aren't needed until an application is actually deployed (a separate, out-of-scope script), so they move entirely into Group 6 with no functional risk to this script's own execution.

### Group 3: Configure Nginx server and issue Let's Encrypt SSL

Unchanged logic, given a banner: PHP-FPM socket detection, write HTTP-only vhost, enable site, `nginx -t`, reload, `certbot certonly --webroot`, rewrite vhost to HTTP+HTTPS, `nginx -t`, reload.

Comment explains that this depends on Group 2 having already made `current/public` readable by `www-data`.

### Group 4: Create database role, database, and extensions

Unchanged SQL and logic, given a banner. Moved to after Group 3 (today it runs before Nginx/SSL) — confirmed independent of the Nginx/SSL group, pure reorder.

### Group 5: Create/update shared .env file

Unchanged logic, given a banner: the `escape_env_double_quoted` helper (defined immediately above this group, since it's only used here), the temp-file rewrite of `DB_*` values, and the existing immediate `chmod 640` + `chown` on `.env` right after the write (already the pattern today — no change).

### Group 6: Check and update permissions (final pass)

The authoritative, final permissions pass, run after every other group has completed. Re-asserts everything Group 2 set (idempotent re-check, via the same `set_core_permissions()` helper) plus, for the first time:

- `storage/` and `bootstrap/cache/` setgid permissions (`2775` dirs / `664` files).
- A final `chown -R` / `chmod 640` re-assertion on `.env`.
- The existing closing `stat -c` permission summary printout (already present at the bottom of the script today), serving as the "check" half of "check and update."

Banner comment explains explicitly *why* some permissions were already set eagerly in Groups 2/5 (Nginx and secret-hygiene requirements that can't wait) while this group still re-verifies and completes the full set at the end (matching the requested "finally, check and update permissions for all" behavior).

### Shared helper: `set_core_permissions()`

A small helper function, defined near the top of the script alongside `escape_env_double_quoted`, encapsulating the `chmod 755`/`644` logic for `BASE_DIR`/`RELEASES_DIR`/`SHARED_DIR`/release-tree that both Group 2 and Group 6 need, so the two call sites can't drift out of sync. This does not wrap entire groups in functions (script otherwise stays a flat top-to-bottom sequence) — it's scoped the same way as the existing `escape_env_double_quoted` helper.

## Data flow

Unchanged from today, aside from the Group 3/Group 4 swap:

1. Group 0 validates the environment.
2. Group 1 gathers site, TLS, and database values interactively.
3. Group 2 creates the deployment layout and shared `.env` file, with minimal functional/secret-hygiene permissions applied inline.
4. Group 3 configures Nginx and obtains the TLS certificate (depends on Group 2's inline permissions for the webroot challenge to succeed).
5. Group 4 provisions the PostgreSQL role, database, and extensions.
6. Group 5 writes Laravel database configuration into the shared `.env` file.
7. Group 6 performs the final, comprehensive permission check-and-fix pass over the whole deployment tree, including `.env`, and prints the closing summary.

## Error handling

No changes to error handling — all existing `set -euo pipefail` behavior, precondition checks, and validation regexes are preserved exactly as they are today, just relocated under their respective group banners.

## Testing

- Run `bash -n debian-13/atomic-deployment-setup.sh` after edits.
- Diff the reordered script against the original to confirm no SQL, Nginx config content, prompt text, validation regex, or directory path changed — only ordering, comments, and the permission-timing split described above.
