# Generic deployment script (`debian/09-deployment.sh`)

## Purpose

A standalone, generic (non-Laravel-specific) deploy script. Given a repo,
branch, and target directory, it clones the branch into a new timestamped
release, swaps `current` to point at it, and prunes old releases beyond a
keep-count. A `--rollback` mode flips `current` back to the previous
release.

This is deliberately minimal: no composer/npm/artisan build steps, no
shared-file symlinking (`.env`, `storage/`, etc.), no user or ownership
handling. It only clones, swaps a symlink, and prunes. It does not replace
or modify `debian/08-laravel-deployment.sh`, which remains the
Laravel-specific generator flow.

## Usage

```
deployment.sh --repo <url> --branch <branch> --dir <path> [--keep N]
deployment.sh --rollback --dir <path>
```

- `--repo` — git URL (SSH or HTTPS). Required for deploy mode. Only
  validated as non-empty; no SSH-only restriction, since this script is
  generic and not tied to the deploy-key workflow the Laravel generator
  assumes.
- `--branch` — branch to deploy. Required for deploy mode.
- `--dir` — base directory. Required always. Must already contain a
  `releases/` directory — the script deploys, it does not provision, and
  fails with an actionable message (e.g. "run `mkdir -p <dir>/releases`
  first") if that layout isn't there yet.
- `--keep` — number of releases to retain after pruning. Optional,
  default `5`. Must be a positive integer.
- `--rollback` — mode switch. Only `--dir` is required alongside it;
  `--repo`, `--branch`, and `--keep` are ignored/rejected in this mode.

## Deploy flow

1. Parse and validate flags:
   - Required flags for the mode are present and non-empty.
   - `--keep` (or its default) is a positive integer.
   - `<dir>/releases` exists as a directory.
   - `<dir>/current` is either absent or already a symlink (error out if
     it exists as some other file/directory type).
2. `git clone --branch <branch> --single-branch --depth 1 <repo>
   <dir>/releases/<timestamp>`, where `<timestamp>` is
   `date +%Y%m%d%H%M%S`.
3. `ln -sfn <dir>/releases/<timestamp> <dir>/current`.
4. Prune release directories beyond `--keep`: list `<dir>/releases`
   entries, sort descending by name (timestamps sort lexically), keep the
   newest N, `rm -rf` the rest.
5. Print a summary: target dir, branch deployed, new release path,
   releases kept.

## Rollback flow

1. Validate `<dir>/current` is a symlink; error out if not.
2. Resolve the release directory `current` currently points at, and find
   the next-older release directory by sorted name under
   `<dir>/releases`.
3. Error out if there is no older release to roll back to.
4. `ln -sfn` `<dir>/current` to that previous release directory.
5. Print a summary of the rollback (`from -> to`).

## Error handling

`set -euo pipefail`. All precondition failures print an actionable
message to stderr and exit 1. Style matches this repo's existing
conventions: `#!/usr/bin/env bash`, tab indentation, uppercase snake case
for script-level variables, quoted expansions, kebab-case filename.

## Testing

- `bash -n debian/09-deployment.sh`
- `shellcheck debian/09-deployment.sh`

There is no disposable server available in this session to exercise the
actual `git clone` / symlink-swap / rollback behavior end-to-end: syntax
and static analysis are what can be verified here. This limitation will
be called out explicitly rather than claiming the deploy/rollback flow
was run live.

## Out of scope

- Provisioning `releases/`/`current` layout (that's `06-folder-structure.sh`'s
  job for Laravel sites; generic callers are expected to `mkdir -p` it).
- Any build step (composer, npm, artisan, etc.).
- Shared/persistent file linking (`.env`, uploads, etc.).
- Service reload/restart after deploy.
- User or ownership/permission handling.
