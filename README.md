# Debian 13 Laravel and PostgreSQL Provisioning

This repository contains Bash scripts for provisioning and deploying Laravel applications on a Debian 13 (trixie) server. The scripts install and configure a production-oriented stack built around Nginx, PHP-FPM, PostgreSQL, Composer, Node.js, and Let's Encrypt.

The main workflow creates a dedicated `deployer` account, prepares an atomic `releases`/`shared`/`current` directory layout, provisions a PostgreSQL database, configures HTTPS, and generates a reusable Laravel deployment script. A separate framework-agnostic script is included for static websites, together with reference Nginx templates for other application stacks.

> [!WARNING]
> These scripts install packages, modify files under `/etc`, manage system services, create users and databases, and write under `/var/www`. Review every script before running it and test on a disposable Debian 13 host before using it on a production server.

## Target stack

- Debian 13 (trixie)
- Nginx with Let's Encrypt TLS
- PHP 8.5 and PHP-FPM by default
- Composer
- PostgreSQL 18
- Node.js 24
- Laravel atomic releases with shared persistent data

PostgreSQL is tuned for a small VPS with approximately 1 vCPU and 4 GB RAM. Review the values in `04-postgresql.sh` before using the script on a differently sized server.

The generated Nginx vhost currently uses the PHP 8.5 FPM socket. If you pass another PHP version to `02-php-phpfpm-composer.sh`, update the socket in `06-nginx-tls-vhost.sh` as well.

## Before you begin

You need:

- A Debian 13 server with internet access and a user that can run `sudo`.
- An SSH public key for the new `deployer` account.
- A Git repository that the server can clone.
- A domain with its A and/or AAAA records pointing to the server before requesting TLS.
- A disposable host for initial testing. Do not test these scripts against production first.

The scripts perform prerequisite checks and are intended for controlled reruns, but review each script's rerun behavior before use. In particular, every run of `01-packages-deployer-ssh.sh` replaces the `deployer` user's GitHub SSH keypair. Any repository that trusted the previous public key must be updated with the newly printed key.

## Laravel server setup

Run the numbered scripts from the repository root. The recommended first-time sequence is:

```bash
DEPLOYER_SSH_KEY='ssh-ed25519 AAAA... you@example.com' \
  bash debian13-laravel-postgresql/01-packages-deployer-ssh.sh

bash debian13-laravel-postgresql/02-php-phpfpm-composer.sh 8.5
bash debian13-laravel-postgresql/03-nginx.sh
bash debian13-laravel-postgresql/04-postgresql.sh
bash debian13-laravel-postgresql/05-folders-permissions-env.sh
bash debian13-laravel-postgresql/06-nginx-tls-vhost.sh
bash debian13-laravel-postgresql/07-database.sh
bash debian13-laravel-postgresql/08-laravel-deployment.sh \
  --repo git@github.com:owner/repository.git \
  --keep 5
```

The scripts prompt for site-specific values such as the hostname, application name, database credentials, and Let's Encrypt email address.

After step 1, add the printed GitHub public key as a deploy key on the application repository. Step 8 only creates `/var/www/<site>/deploy.sh`; it does not deploy the application. Run the generated script as `deployer` to deploy a branch:

```bash
sudo -u deployer bash /var/www/app.example.com/deploy.sh main
```

If no branch is supplied, the deployment script uses `main`.

## Script reference

| Script | Purpose |
| --- | --- |
| [`01-packages-deployer-ssh.sh`](debian13-laravel-postgresql/01-packages-deployer-ssh.sh) | Installs base packages and Node.js 24, creates the `deployer` account, configures passwordless sudo and login SSH access, and generates a GitHub deploy key. |
| [`02-php-phpfpm-composer.sh`](debian13-laravel-postgresql/02-php-phpfpm-composer.sh) `[version]` | Installs PHP, PHP-FPM, common Laravel extensions, and signature-verified Composer; defaults to PHP 8.5. |
| [`03-nginx.sh`](debian13-laravel-postgresql/03-nginx.sh) | Installs and enables Nginx. It stops Apache when Apache owns port 80 and exits without changes when Nginx is already installed. |
| [`04-postgresql.sh`](debian13-laravel-postgresql/04-postgresql.sh) | Installs PostgreSQL 18, enables SCRAM authentication for localhost TCP connections, and applies small-VPS production tuning. |
| [`05-folders-permissions-env.sh`](debian13-laravel-postgresql/05-folders-permissions-env.sh) | Creates or reconverges the Laravel release layout, shared writable directories, production `.env`, ownership, and permissions. It does not modify PostgreSQL. |
| [`06-nginx-tls-vhost.sh`](debian13-laravel-postgresql/06-nginx-tls-vhost.sh) | Writes the site's Nginx vhost, obtains a Let's Encrypt certificate using the webroot challenge, enables HTTPS, and verifies renewal. Requires `<site>/current/public`. |
| [`07-database.sh`](debian13-laravel-postgresql/07-database.sh) | Creates or updates the PostgreSQL role and database, rotates the role password, enables `pgcrypto` and `pg_trgm`, and optionally synchronizes the site's shared `.env`. |
| [`08-laravel-deployment.sh`](debian13-laravel-postgresql/08-laravel-deployment.sh) | Generates `/var/www/<site>/deploy.sh` for atomic Laravel deployments and symlink-based rollback. Requires the layout and shared `.env` from step 5. |
| [`09-static-web-deployment.sh`](debian13-laravel-postgresql/09-static-web-deployment.sh) | Deploys a branch's existing `dist/` directory into a generic atomic release layout. It does not provision the target directory or build frontend assets. |

Several provisioning scripts are independently useful. For example, `07-database.sh` can rotate a database password without rerunning the site setup. Each script reports its required prerequisites when they are missing.

## Laravel release layout

For a site named `app.example.com`, the Laravel setup uses:

```text
/var/www/app.example.com/
├── current -> releases/<timestamp>
├── deploy.sh
├── releases/
│   └── <timestamp>/
└── shared/
    ├── .env
    ├── bootstrap/cache/
    ├── logs/
    └── storage/
```

Each release links its `.env`, `storage`, and `bootstrap/cache` paths into `shared`. A deployment clones a fresh release, installs dependencies, runs migrations, builds frontend assets when `package.json` exists, caches Laravel configuration/routes/views, and then swaps `current` to the new release.

Roll back to the immediately preceding retained release with:

```bash
sudo -u deployer bash /var/www/app.example.com/deploy.sh --rollback
```

Rollback changes only the `current` symlink. It does not reverse database migrations or restore an older `.env`.

## Static website deployment

The static deployment script expects the target's `releases/` directory to exist and the selected branch to contain an already-built `dist/` directory:

```bash
sudo mkdir -p /var/www/static.example.com/releases
sudo chown -R "$(id -un):$(id -gn)" /var/www/static.example.com

bash debian13-laravel-postgresql/09-static-web-deployment.sh \
  --repo git@github.com:owner/repository.git \
  --branch main \
  --dir /var/www/static.example.com \
  --keep 5
```

To roll back:

```bash
bash debian13-laravel-postgresql/09-static-web-deployment.sh \
  --rollback \
  --dir /var/www/static.example.com
```

## Nginx templates

The `nginx/` directory contains reference vhost templates for Laravel, Node.js, React SPAs, and plain static websites. They contain `__PLACEHOLDER__` tokens and are intended to be reviewed, rendered, and installed manually. The automated Laravel TLS script writes its own vhost and does not consume these templates.

## Development and validation

This repository has no build step or automated test suite. From the repository root, validate changes with:

```bash
bash -n debian13-laravel-postgresql/*.sh
shellcheck debian13-laravel-postgresql/*.sh
git diff --check
```

Syntax and static analysis cannot verify package installation, service configuration, TLS issuance, permissions, deployment, or rerun behavior. Exercise affected scripts on a clean disposable Debian 13 system and verify service state and configuration before promoting changes to production.

## Security notes

- Never commit private keys, passwords, production `.env` files, or host-specific secrets.
- Review the passwordless sudo access granted to `deployer` and restrict it further if your environment requires a tighter privilege model.
- Use repository deploy keys with only the access the deployment needs.
- Review generated `.env` placeholders and replace all application-specific database, mail, cache, queue, and integration settings before the first deployment.
- Keep at least two releases if rollback is required.
