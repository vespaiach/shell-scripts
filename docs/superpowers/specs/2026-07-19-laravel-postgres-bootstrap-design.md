# Laravel PostgreSQL Bootstrap Design

Date: 2026-07-19

## Goal

Move Laravel-specific PostgreSQL bootstrap steps out of `debian-13/php-nginx-postgresql-setup.sh` and into `debian-13/atomic-deployment-setup.sh`, so app database provisioning happens alongside app deployment setup.

## Scope

- Keep `debian-13/php-nginx-postgresql-setup.sh` focused on system package installation and generic PostgreSQL server configuration.
- Keep localhost TCP password auth enforcement for PostgreSQL in the base setup script.
- Add interactive Laravel database bootstrap to `debian-13/atomic-deployment-setup.sh`.
- Prompt the operator for database name, database username, and database password.
- Use the entered database username as the PostgreSQL role name.
- Write matching Laravel `DB_*` values into the shared `.env` file.

## Design

### Base setup script

`debian-13/php-nginx-postgresql-setup.sh` will:

- Continue installing PostgreSQL and configuring localhost TCP auth in `pg_hba.conf`.
- Remove the Laravel-specific post-install guidance block, since that behavior moves to the deployment script.

### Atomic deployment script

`debian-13/atomic-deployment-setup.sh` will:

- Prompt for:
    - `DB_DATABASE`
    - `DB_USERNAME`
    - `DB_PASSWORD`
- Validate `DB_DATABASE` and `DB_USERNAME` against a conservative identifier pattern such as letters, numbers, and underscores, starting with a letter or underscore.
- Keep `DB_PASSWORD` non-empty.
- Create or update the PostgreSQL role using the entered username.
- Create the PostgreSQL database owned by that role.
- Enable optional Laravel-friendly extensions in the application database:
    - `pgcrypto`
    - `pg_trgm`
- Update the shared `.env` file so it contains:
    - `DB_CONNECTION=pgsql`
    - `DB_HOST=127.0.0.1`
    - `DB_PORT=5432`
    - `DB_DATABASE=<prompted database name>`
    - `DB_USERNAME=<prompted username>`
    - `DB_PASSWORD=<prompted password>`

## Data flow

1. Operator runs the base setup script once to install PHP, Nginx, PostgreSQL, and Composer.
2. Operator runs the atomic deployment script as `deployer`.
3. The script gathers site, TLS, and database values interactively.
4. The script creates the deployment layout and shared `.env` file.
5. The script provisions the PostgreSQL role and database using `sudo -u postgres psql`.
6. The script writes Laravel database configuration to the shared `.env` file.
7. The script completes Nginx and certificate setup.

## Error handling

- Fail if PostgreSQL client tools are unavailable when provisioning the database.
- Fail if role or database names do not match the allowed pattern.
- Fail if the password is empty.
- Fail if SQL execution or `.env` update fails.
- Preserve existing non-database `.env` content while replacing prior `DB_*` values.

## Testing

- Run `bash -n` against both scripts after edits.
- Verify the atomic deployment script still parses cleanly with the new prompts and SQL block.
- Verify the base setup script still parses cleanly after removing the Laravel guidance block.
