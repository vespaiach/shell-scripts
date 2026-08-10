# 08-laravel-deployment.sh: derive site from directory, rename output to deploy.sh

## Problem

`08-laravel-deployment.sh` currently requires `--site <name>` on the command
line, builds `BASE_DIR="/var/www/${SITE_NAME}"` from it, and writes the
runtime deploy script to `${BASE_DIR}/laravel-deployment.sh`. The operator
has to retype the site name even though the script is always run against a
directory that already exists (created by `05-folder-structure.sh`).

## Decisions

- **Drop `--site`.** `BASE_DIR="$(pwd -P)"` — the operator `cd`s into
  `/var/www/<site>` before running the script. The existing preflight checks
  (`releases/` and `shared/` must exist, `current` must be a symlink if
  present) move from name-based to directory-based but are otherwise
  unchanged.
- **No `SITE_NAME` variable at all.** It was only ever used to reconstruct
  `BASE_DIR` (now known directly) and for cosmetic log lines. Considered
  deriving a display name from `APP_URL` in the shared `.env`, but that adds
  a dependency on `.env` formatting/placeholder state to print a label —
  rejected as unnecessary coupling. Cosmetic labels use
  `$(basename "${BASE_DIR}")` instead.
- **Rename the generated file** from `laravel-deployment.sh` to `deploy.sh`
  (`${BASE_DIR}/deploy.sh`). The generated template no longer takes a
  `__SITE_NAME__` placeholder; `BASE_DIR` is baked into the generated script
  as a literal absolute path (already known at generation time), so the
  runtime `deploy.sh` has no name-reconstruction logic either.
- **Ownership of `deploy.sh` becomes `deployer:deployer`** (mode `750`),
  changed from `deployer:www-data`. Nothing serves this file to Nginx/PHP-FPM
  — it's invoked directly by the `deployer` user — so `www-data` group access
  serves no purpose. Add a preflight `getent group deployer` check (mirrors
  the existing `WEB_GROUP` check) since the install now depends on that group
  existing.
- **Unchanged:** `WEB_GROUP="www-data"` stays and is still used inside the
  generated `deploy.sh` for `chown -R deployer:www-data` on each release
  directory — Nginx/PHP-FPM still need group read access to the *cloned
  code*, just not to the deploy script itself. `--repo` and `--keep` flags
  are unchanged.
- **Stale reference fix (in-scope only where touched):** lines inside
  `08-laravel-deployment.sh` that say `06-folder-structure.sh` are corrected
  to the current filename `05-folder-structure.sh` as part of editing those
  same lines. Identical stale references in `06-nginx-tls-vhost.sh` and
  `07-database.sh` are left alone — out of scope for this change.

## New usage

```
cd /var/www/<site>
/path/to/08-laravel-deployment.sh --repo <url> [--keep N]
```

## Testing

- `bash -n debian-laravel-postgresql/08-laravel-deployment.sh`
- `shellcheck debian-laravel-postgresql/08-laravel-deployment.sh`
- Manual read-through of the rendered heredoc template to confirm no
  leftover `__SITE_NAME__` token and correct literal `BASE_DIR`.
