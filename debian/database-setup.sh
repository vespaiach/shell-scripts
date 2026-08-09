#!/usr/bin/env bash

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# ****************************************************************************************************
# Provision the Laravel app's PostgreSQL role, database, and extensions.
#
# Standalone and re-runnable: no dependency on structure-setup.sh or
# nginx-tls-setup.sh having run, and can be used on its own purely to rotate
# the database password. Re-running updates Postgres but does not touch a
# site's .env -- if the site already exists, update .env by hand afterward.
# ****************************************************************************************************

# Every operation below needs elevation, so fail before prompting for
# anything if sudo is unavailable. Only sudo capability is required -- no
# check on which user is running this script.
if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required but not installed." >&2
	exit 1
fi

if ! sudo -n true 2>/dev/null; then
	echo "This script needs sudo privileges to complete setup."
	echo "You may be prompted for your sudo password during execution."
	if ! sudo true; then
		echo "Unable to obtain sudo privileges." >&2
		exit 1
	fi
fi

if ! command -v psql >/dev/null 2>&1; then
	echo "psql is required to provision the Laravel database but is not installed." >&2
	exit 1
fi

# ---- Collect input ----

read -r -p "Laravel PostgreSQL database name: " DB_DATABASE

if [[ -z "${DB_DATABASE}" ]]; then
	echo "Database name cannot be empty." >&2
	exit 1
fi

if [[ ! "${DB_DATABASE}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
	echo "Database name must start with a letter or underscore and contain only letters, numbers, and underscores." >&2
	exit 1
fi

read -r -p "Laravel PostgreSQL username: " DB_USERNAME

if [[ -z "${DB_USERNAME}" ]]; then
	echo "Database username cannot be empty." >&2
	exit 1
fi

if [[ ! "${DB_USERNAME}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
	echo "Database username must start with a letter or underscore and contain only letters, numbers, and underscores." >&2
	exit 1
fi

read -r -s -p "Laravel PostgreSQL password: " DB_PASSWORD
echo

if [[ -z "${DB_PASSWORD}" ]]; then
	echo "Database password cannot be empty." >&2
	exit 1
fi

# ---- Create role, database, and extensions ----

# Escape a value for use inside single quotes in a psql backslash-command
# argument: psql unescapes \\ and \' there, so both have to be backslashed.
escape_psql_single_quoted() {
	local value="$1"
	# A literal single quote cannot be written inline in the pattern here --
	# bash consumes it as an opening quote -- so it goes through a variable.
	local single_quote="'"
	value="${value//\\/\\\\}"
	value="${value//"${single_quote}"/\\"${single_quote}"}"
	printf '%s' "$value"
}

echo "Provisioning PostgreSQL database ${DB_DATABASE} for role ${DB_USERNAME}..."

# The role/database DDL is built with format() and run through \gexec rather
# than a DO block: psql does not interpolate :'variables' inside dollar-quoted
# strings, so :'db_user' inside DO $$ ... $$ would reach the server verbatim
# and fail with a syntax error.
#
# db_name and db_user are validated identifiers and safe to pass as
# arguments, but the password is fed in over stdin via \set -- anything in
# argv is readable by any local user in /proc/<pid>/cmdline for as long as
# psql runs. ALTER ROLE runs unconditionally so re-running this script
# rotates the password.
{
	printf '\\set db_password %s\n' "'$(escape_psql_single_quoted "${DB_PASSWORD}")'"
	cat <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'db_user', :'db_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'db_user')
\gexec

SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'db_user', :'db_password')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8''', :'db_name', :'db_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db_name')
\gexec

SELECT format('ALTER DATABASE %I OWNER TO %I', :'db_name', :'db_user')
\gexec
SQL
} | sudo -u postgres psql -v ON_ERROR_STOP=1 \
	--set=db_name="${DB_DATABASE}" \
	--set=db_user="${DB_USERNAME}"

sudo -u postgres psql -v ON_ERROR_STOP=1 --dbname="${DB_DATABASE}" <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL

echo "Done."
echo "Database: ${DB_DATABASE}"
echo "Database user: ${DB_USERNAME}"
