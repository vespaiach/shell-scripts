# Parameterize the PHP version in `01-php.sh`

## Problem

`debian-13/php-nginx-postgresql-setup/01-php.sh` hardcodes PHP `8.5` in roughly
ten places: apt package names (`php8.5`, `php8.5-cli`, `php8.5-common`, the
extension brace list, `php8.5-pgsql`, `php8.5-bcmath`), the `php8.5-fpm`
service name and socket path, and the two `/etc/php/8.5/fpm/...` config file
paths. Bumping to a newer PHP version currently requires editing the script
in every one of those spots.

## Goal

Let the caller pick the PHP version at invocation time, while preserving
today's behavior (installs 8.5) when no version is given.

Scope: `01-php.sh` only.

## Design

### Version input

Positional CLI argument, first (and only) argument to the script:

```bash
bash 01-php.sh 8.4
```

Right after the existing sudo-availability check, add:

```bash
PHP_VERSION="${1:-8.5}"
```

No format validation — an invalid value (e.g. a version Sury doesn't
publish) surfaces naturally as an `apt install` failure under
`set -euo pipefail`, the same way a bad hardcoded value would today.

### Interpolation sites

Every hardcoded `8.5` becomes `${PHP_VERSION}`:

- `sudo apt install -y php${PHP_VERSION} php${PHP_VERSION}-cli php${PHP_VERSION}-common`
- `sudo apt install -y php${PHP_VERSION}-{fpm,mysql,curl,mbstring,xml,zip,gd,intl}`
- `sudo apt install -y php${PHP_VERSION}-pgsql php${PHP_VERSION}-bcmath`
- `systemctl is-active --quiet php${PHP_VERSION}-fpm` (both occurrences)
- `[ -S /run/php/php${PHP_VERSION}-fpm.sock ]` and its echo message
- `PHP_FPM_LIMITS_INI="/etc/php/${PHP_VERSION}/fpm/conf.d/99-production-limits.ini"`
- `PHP_FPM_POOL_PM_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/99-www-production-pm.conf"`
- `sudo systemctl restart php${PHP_VERSION}-fpm`

### Comments

Section-banner and inline comments that currently name "PHP 8.5" explicitly
(e.g. `# Install PHP 8.5 and its common extensions...`,
`# php8.5: the main PHP runtime package.`) are reworded to be
version-agnostic, since the actual version is now a runtime value rather
than fixed text (e.g. `# Install PHP and its common extensions...`,
`# php${PHP_VERSION}: the main PHP runtime package.` where the comment sits
directly above the interpolated line, or fully generic text where it
doesn't).

### Idempotency

Unaffected — reruns with the same version argument remain idempotent exactly
as today (apt install, overwrite-identical-content conf files, service
restart). Rerunning with a *different* version installs that version
alongside the previous one (apt does not remove the old packages); this is
existing single-version behavior extended to a parameter, not a new concern
this change needs to solve.

## Out of scope

- `debian-13/php-nginx-postgresql-setup.sh` (the orchestrator): keeps calling
  `bash "${STEPS_DIR}/01-php.sh"` with no arguments, so a full orchestrated
  run continues to install 8.5 by default. Passing a version through the
  orchestrator is a possible future change, not part of this one.
- `debian-13/atomic-deployment-setup.sh`: its hardcoded
  `PHP_FPM_SOCK="/run/php/php8.5-fpm.sock"` is untouched. If `01-php.sh` is
  ever run with a non-8.5 version, that script's Nginx vhost will point at
  the wrong FPM socket — a known, accepted gap for this change.
- Any change to `02-nginx.sh`, `03-postgresql.sh`, or `04-deployer.sh`.
- Input validation of the version argument.

## Documentation updates

`CLAUDE.md`'s description of `01-php.sh` gains a note that it accepts an
optional PHP-version argument (defaulting to 8.5).

## Testing

`bash -n debian-13/php-nginx-postgresql-setup/01-php.sh`, per this repo's
existing convention (no build/lint/test tooling exists otherwise).
