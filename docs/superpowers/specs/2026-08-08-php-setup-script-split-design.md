# Split `php-nginx-postgresql-setup.sh` into reusable step files

## Problem

`debian-13/php-nginx-postgresql-setup.sh` is a single 421-line script that runs five
provisioning steps back to back (PHP 8.5 + FPM tuning, Nginx, PostgreSQL 18 + auth +
tuning, deployer user). To re-apply or re-verify just one step (e.g. re-apply
PostgreSQL tuning after editing a value) an operator has to re-run the entire script,
re-doing every earlier step along the way. There's no way to run a single step in
isolation.

## Goal

Split the script into independently runnable, idempotent step files, orchestrated by
a thin top-level script that preserves today's single-command behavior
(`bash debian-13/php-nginx-postgresql-setup.sh` still does everything, in order).

Scope: `php-nginx-postgresql-setup.sh` only. `nodejs-nginx-postgresql-setup.sh` and
`atomic-deployment-setup.sh` are untouched by this change (a separate future pass can
address the duplication between the PHP and Node.js setup scripts).

## Design

### File layout

```
debian-13/
  php-nginx-postgresql-setup.sh          # thin orchestrator (kept at current path)
  php-nginx-postgresql-setup/
    01-php.sh                            # PHP 8.5 install + FPM production tuning
    02-nginx.sh                          # Nginx install
    03-postgresql.sh                     # PostgreSQL 18 install + auth + tuning
    04-deployer.sh                       # deployer user: sudo group, passwordless sudo, SSH key
```

Each step file is a complete, standalone script:

- Own `#!/usr/bin/env bash` shebang.
- Own `set -euo pipefail`.
- Own copy of the current script's sudo-availability preflight check (fail fast
  before touching anything if `sudo` isn't installed).
- The provisioning logic for that step, moved verbatim (including existing
  comments) from the current single-file script — no behavioral changes.

This makes every step directly runnable on its own, e.g.
`bash debian-13/php-nginx-postgresql-setup/03-postgresql.sh` re-applies PostgreSQL
setup/tuning without touching PHP, Nginx, or the deployer account.

### Orchestrator behavior (`php-nginx-postgresql-setup.sh`)

1. Same top-of-file sudo-availability check as today (fail fast before invoking
   anything).
2. Resolve its own directory so step files are found regardless of the caller's
   working directory:
   ```bash
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   ```
3. Run each step file in order as a subprocess, with a comment above each call
   (matching the descriptive `# Step N: ...` comment banner already at the top of
   that step file) so the orchestrator's own source stays as readable as the
   current single-file script:
   ```bash
   # Step 1: Install PHP 8.5 and configure FPM for production.
   bash "${SCRIPT_DIR}/php-nginx-postgresql-setup/01-php.sh"

   # Step 2: Install Nginx.
   bash "${SCRIPT_DIR}/php-nginx-postgresql-setup/02-nginx.sh"

   # Step 3: Install and configure PostgreSQL 18.
   bash "${SCRIPT_DIR}/php-nginx-postgresql-setup/03-postgresql.sh"

   # Step 4: Create the deployer user.
   bash "${SCRIPT_DIR}/php-nginx-postgresql-setup/04-deployer.sh"
   ```
   Note this is source-level commenting, not a new runtime `echo` banner — the
   current script never printed step boundaries to the console either (the
   `Step N:` text was always a comment, not an `echo`), so this preserves existing
   behavior exactly rather than adding new console output.
4. `set -euo pipefail` in the orchestrator means a failing step (non-zero exit from
   the `bash` subprocess call) stops the whole run immediately, matching today's
   single-file behavior.
5. No special plumbing for environment variables or stdin: `DEPLOYER_SSH_KEY` (used
   by the deployer step for unattended runs) and an interactive terminal (used for
   the SSH-key prompt) both pass through to subprocesses unchanged, since `bash
   child.sh` inherits the parent's exported environment and file descriptors.

### Idempotency

Pure move, not a rewrite — the existing logic in every step is already idempotent on
rerun, and that property is preserved as-is:

- **01-php.sh** — `apt install` calls are naturally idempotent; the FPM
  limits/pool `.conf` files are overwritten with identical content and PHP-FPM is
  restarted (safe every run).
- **02-nginx.sh** — `apt install` + `systemctl enable --now` are idempotent.
- **03-postgresql.sh** — repo/key setup overwrites identical content; the
  `pg_hba.conf` `sed` + fallback `grep`/append avoids duplicate lines; the tuning
  `.conf` is overwritten with identical content each run.
- **04-deployer.sh** — already explicitly guards every mutation (`id` check before
  `useradd`, `visudo -c` validation before installing the sudoers drop-in, a `grep`
  check before appending the SSH key so reruns don't duplicate it).

No new idempotency work is required.

### CLAUDE.md updates

- The repository-layout bullet for `debian-13/php-nginx-postgresql-setup.sh`
  is rewritten to describe the orchestrator + 4-file subdirectory structure instead
  of a single file.
- The `bash -n` syntax-check snippet under "Working with these scripts" expands from
  3 files to all 5 (orchestrator + 4 step files):
  ```bash
  bash -n debian-13/php-nginx-postgresql-setup.sh
  bash -n debian-13/php-nginx-postgresql-setup/01-php.sh
  bash -n debian-13/php-nginx-postgresql-setup/02-nginx.sh
  bash -n debian-13/php-nginx-postgresql-setup/03-postgresql.sh
  bash -n debian-13/php-nginx-postgresql-setup/04-deployer.sh
  bash -n debian-13/nodejs-nginx-postgresql-setup.sh
  bash -n debian-13/atomic-deployment-setup.sh
  ```

## Out of scope

- Any change to `nodejs-nginx-postgresql-setup.sh` or the duplication between it and
  the PHP script's Nginx/PostgreSQL steps.
- Any change to `atomic-deployment-setup.sh`.
- Any behavioral/logic change to the provisioning steps themselves (package
  versions, tuning values, validation regexes, etc.) — this is a structural split
  only.

## Testing

No build/lint/test tooling exists in this repo. Verification is `bash -n` syntax
checking on all 5 files, per CLAUDE.md's existing convention.
