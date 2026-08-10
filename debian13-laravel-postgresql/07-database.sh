#!/usr/bin/env bash

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# ****************************************************************************************************
# Provision the Laravel app's PostgreSQL role, database, and extensions.
#
# Standalone and re-runnable: no dependency on 04-folder-structure.sh or
# 06-nginx-tls-vhost.sh having run, and can be used on its own purely to
# rotate the database password. If a site name is given, this also syncs the
# DB_* values in that site's shared .env (written by 04-folder-structure.sh)
# to match -- leave the site name blank to skip and update .env by hand
# instead. Only the DB_* lines are rewritten; everything else in .env is left
# untouched.
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

# Validate a value that is used as both a hostname and a path segment.
#
# A plain "letters, numbers, dots, and hyphens" character check is not enough
# here: '.' and '..' consist entirely of allowed characters, so they pass it,
# and SHARED_ENV_FILE then points outside the site tree -- '..' resolves
# /var/www/<site>/shared/.env to /var/shared/.env, which this script would
# create and write live database credentials into. Requiring real hostname
# labels (alphanumeric at both ends, hyphens only inside, joined by single
# dots) rejects '.' and '..' along with a leading '-'.
is_valid_hostname() {
	[[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}

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

# Optional: site whose shared .env should be synced with the DB_* values
# below. Leave blank to skip -- this script has no other need for a site.
read -r -p "Site name (e.g., app.mysite.com): " SITE_NAME

if [[ -n "${SITE_NAME}" ]] && ! is_valid_hostname "${SITE_NAME}"; then
	echo "Site name must be a hostname: dot-separated labels of letters, numbers, and inner hyphens (example: app.mysite.com)." >&2
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

# ---- Sync the site's .env, if requested ----

if [[ -z "${SITE_NAME}" ]]; then
	echo "No site name given -- skipping .env sync. Update .env by hand if a site already exists."
else
	SHARED_ENV_FILE="/var/www/${SITE_NAME}/shared/.env"

	if [[ ! -e "${SHARED_ENV_FILE}" ]]; then
		echo "${SHARED_ENV_FILE} not found -- skipping .env sync." >&2
		echo "Run 04-folder-structure.sh for ${SITE_NAME} first, then re-run this script to sync .env." >&2
	else
		echo "Syncing DB_* values in ${SHARED_ENV_FILE}..."

		# Read the whole file through sudo first (it's 640, owner deployer)
		# rather than reading and writing it in the same pipeline -- piping
		# `sudo cat file | ... | sudo tee file` would race tee's truncation
		# against cat still reading the same path.
		ENV_CONTENT="$(sudo cat "${SHARED_ENV_FILE}")"

		# Only the DB_* lines are touched; every other line, including
		# comments and blank lines, passes through unchanged. Values come in
		# via ENVIRON rather than awk -v so no escaping is needed for
		# whatever characters end up in DB_PASSWORD.
		UPDATED_ENV_CONTENT="$(
			DB_CONNECTION="pgsql" \
			DB_HOST="127.0.0.1" \
			DB_PORT="5432" \
			DB_DATABASE="${DB_DATABASE}" \
			DB_USERNAME="${DB_USERNAME}" \
			DB_PASSWORD="${DB_PASSWORD}" \
			awk '
				BEGIN {
					n = split("DB_CONNECTION DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD", keys, " ")
				}
				{
					replaced = 0
					for (i = 1; i <= n; i++) {
						k = keys[i]
						if (index($0, k "=") == 1) {
							print k "=" ENVIRON[k]
							seen[k] = 1
							replaced = 1
							break
						}
					}
					if (!replaced) print $0
				}
				END {
					for (i = 1; i <= n; i++) {
						k = keys[i]
						if (!(k in seen)) print k "=" ENVIRON[k]
					}
				}
			' <<<"${ENV_CONTENT}"
		)"

		printf '%s\n' "${UPDATED_ENV_CONTENT}" | sudo tee "${SHARED_ENV_FILE}" >/dev/null

		# .env may hold secrets -- keep it owner/group readable only, same as
		# the final permission pass in 04-folder-structure.sh.
		sudo chmod 640 "${SHARED_ENV_FILE}"
		sudo chown deployer:www-data "${SHARED_ENV_FILE}"

		echo ".env synced."
	fi
fi
