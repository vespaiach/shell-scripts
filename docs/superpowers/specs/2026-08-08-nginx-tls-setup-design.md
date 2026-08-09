# Design: `debian-13/deployment/nginx-tls-setup.sh`

## Context

This is one of three standalone scripts replacing `debian-13/atomic-deployment-setup.sh`
(the old single 578-line script that provisioned the whole PHP/Laravel atomic
deployment). The three live side by side in `debian-13/deployment/`:

```
debian-13/deployment/
  structure-setup.sh   # atomic release/shared/current layout + permissions + .env
  nginx-tls-setup.sh   # this doc — Nginx vhost + Let's Encrypt/certbot
  database-setup.sh    # PostgreSQL role/database/extensions
```

`debian-13/atomic-deployment-setup.sh` is deleted. Each script is fully
self-contained — its own shebang, `set -euo pipefail`, preflight checks, prompts,
and helper functions. None of the three source each other or a shared lib, and none
pass state between each other via env vars or files; every script prompts for
everything it needs, even if a sibling script just asked for the same value. This
keeps each one copy-paste-independent of its siblings.

## Goal

Own the site's Nginx vhost and Let's Encrypt/certbot TLS issuance as a standalone,
re-runnable step, separate from directory-structure provisioning
(`structure-setup.sh`) and database provisioning (`database-setup.sh`). An operator
should be able to re-run just this script to change the server name, recover a
broken vhost, or redo the renewal verification, without touching anything else.

## Prompts

- Site name (derives `BASE_DIR=/var/www/<site>` and `CURRENT_LINK`, needed to locate
  the webroot and to root the vhost).
- Nginx server name (default: site name).
- Let's Encrypt certificate domain (default: site name).
- Let's Encrypt notification email.

## Preflight

- Sudo present and usable (`sudo -n true`, falling back to an interactive `sudo
  true` prompt). No check on *which* user is running the script — only that they can
  sudo.
- `nginx -t` passes (Nginx must already be installed and configured correctly).
- Certbot present.
- **`${BASE_DIR}/current/public` must already exist** — if not, exit with a message
  telling the operator to run `structure-setup.sh` for this site first, rather than
  writing a vhost that points at a webroot that doesn't exist yet. This is the one
  hard ordering dependency between any of the three scripts.

## Does, in order

1. Detect the PHP-FPM socket (prefer `php8.5-fpm.sock`, fall back to the first
   detected `php*-fpm.sock`, warn if none found).
2. Write an HTTP-only vhost (redirects to HTTPS, serves the ACME challenge path),
   enable it, `nginx -t`, reload.
3. Request the Let's Encrypt certificate via webroot (`certbot certonly`).
4. Rewrite the vhost as HTTP+HTTPS (with the PHP-FPM `fastcgi_pass` block, security
   headers, static-asset caching, hidden-file blocking), `nginx -t`, reload.
5. Verify auto-renewal: `certbot.timer` enabled, and a `certbot renew --dry-run` for
   this domain succeeds. Records success/failure but doesn't abort the script over
   it — reported and exited on at the very end, same as the old script.

## Idempotent — safe to re-run

Vhost files are always fully rewritten via temp-file-then-move, so re-running with
the same or updated inputs (e.g. an added server alias) converges to the same
result. Certbot itself is idempotent — `certonly` against an existing valid,
non-expiring certificate does not reissue it. Safe to re-run to change the server
name, redo the renewal check, or recover from a manually broken vhost.

## Verification

- `bash -n debian-13/deployment/nginx-tls-setup.sh` (matches the repo's existing
  verification convention — no other lint/test tooling exists).
- Manual read-through comparing this script's logic against Group 3 of the old
  `atomic-deployment-setup.sh` to confirm no behavior was dropped or reordered
  (e.g. the HTTP-only vhost must be live and reloaded before the webroot challenge
  is requested).

## Documentation updates

`CLAUDE.md`'s repository layout and architecture sections get rewritten to describe
`nginx-tls-setup.sh` in place of the relevant parts of the old
`atomic-deployment-setup.sh` description, including:
- The new file path and what it owns.
- Its hard precondition on `structure-setup.sh` having already run for the site
  (`${BASE_DIR}/current/public` must exist).
- That it remains safe to re-run, like both of its siblings.
- That the deployer-identity check from the old script is gone here: it only
  requires the executing user to have sudo, not to literally be logged in as
  `deployer`.
- That it's fully self-contained by design (no shared lib, no cross-script state
  passing) so it can be copied and run elsewhere independently of its siblings.
