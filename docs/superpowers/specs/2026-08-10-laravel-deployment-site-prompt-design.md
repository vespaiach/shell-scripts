# 08-laravel-deployment.sh: prompt for site name instead of deriving it from cwd

## Problem

`08-laravel-deployment.sh` currently derives `BASE_DIR` from `pwd -P` and must be
run from inside `/var/www/<site>`. `05-folder-structure.sh` and
`06-nginx-tls-vhost.sh` already prompt for the site name interactively instead of
depending on the caller's current directory. `08-laravel-deployment.sh` should
match that convention.

## Behavior change

- Add a `read -r -p "Site name (e.g., app.mysite.com): " SITE_NAME` prompt.
- Validate `SITE_NAME` with the same strict hostname check
  `05-folder-structure.sh` uses (`is_valid_hostname`, non-empty): dot-separated
  labels of letters, numbers, and inner hyphens. This matters because
  `SITE_NAME` becomes part of a real filesystem path
  (`BASE_DIR=/var/www/${SITE_NAME}`) that the generated `deploy.sh` later runs
  `sudo chown -R` under -- an unvalidated `..` or leading `-` is a real hazard
  here, not just cosmetic. (06 does not validate `SITE_NAME`; we deliberately
  diverge from 06 on this one point and match 05 instead, since 05's rationale
  for validating applies equally here.)
- `BASE_DIR` becomes `/var/www/${SITE_NAME}` instead of `pwd -P`. The script no
  longer depends on, or cares about, the invocation directory.
- `--repo` (required) and `--keep` (optional, default 5) remain CLI flags,
  unchanged in validation or meaning.

## Ordering change

Move the sudo-availability check (`command -v sudo`, `sudo -n true` / prompt for
a password) to run immediately after argument parsing -- before `--repo`/`--keep`
value validation and before the new `SITE_NAME` prompt. This reverses the
current script's own stated rationale ("checked only now, after the cheaper
input/structure/group checks above, so a misconfigured... site is reported
without demanding a sudo password first") to instead match 05/06's philosophy:
fail immediately if sudo is unavailable, before asking the operator to type
anything.

`-h`/`--help` must still exit with zero side effects (no sudo check, no
prompt) -- argument parsing (including the immediate exit for `-h`/`--help` or
an unknown flag) stays the very first thing the script does.

Everything else keeps its current relative order, just shifted after the sudo
check: `--repo`/`--keep` validation -> prompt+validate `SITE_NAME` -> derive
`BASE_DIR` and friends -> releases/shared/current existence checks -> group
existence checks (`www-data`, `deployer` user, `deployer` group) -> render and
install `deploy.sh`.

## Text updates

- `usage()` and the top-of-file block comment: drop "run from inside
  `/var/www/<site>`, identified by cwd, not a flag" language; describe the
  interactive prompt instead.
- Directory-structure error messages (e.g. "Run 05-folder-structure.sh here
  first") get `SITE_NAME` woven in for clarity, matching 06's phrasing style
  ("Run 05-folder-structure.sh for '${SITE_NAME}' first...").
- The generated `deploy.sh`'s own header comment ("Rerun the generator from
  that directory to regenerate") gets reworded, since the generator no longer
  depends on the caller's directory.

## Unchanged

Repo URL format validation, keep-count validation, the
releases/shared/current existence and symlink checks, the `www-data`/`deployer`
group checks, the deploy.sh heredoc template and its `sed` substitution logic,
and the installed file's ownership/permissions (`deployer:deployer`, mode 750).

## Docs

- Update the `08-laravel-deployment.sh` bullet in `AGENTS.md` to describe the
  site-name prompt instead of the cwd convention.
- Also fix a pre-existing stale claim in the `06-nginx-tls-vhost.sh` bullet:
  AGENTS.md currently says to "run it from inside the site's base directory,"
  but the script (as of the last three commits) never checks `cwd` -- it only
  uses the prompted `SITE_NAME`. Correct this in the same edit since it's the
  same paragraph structure.

## Out of scope

- `--repo`/`--keep` do not become prompts; they stay flags (explicit user
  decision).
- No change to `05-folder-structure.sh` or `06-nginx-tls-vhost.sh` themselves.
- No change to what the generated `deploy.sh` actually does (clone, symlink
  shared files, composer install, migrate, npm build, cache, swap, reload,
  prune).
