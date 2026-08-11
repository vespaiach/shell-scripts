#!/usr/bin/env bash

set -euo pipefail


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

is_valid_hostname() {
	[[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}


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

read -r -p "Site name (e.g., app.mysite.com): " SITE_NAME

if [[ -n "${SITE_NAME}" ]] && ! is_valid_hostname "${SITE_NAME}"; then
	echo "Site name must be a hostname: dot-separated labels of letters, numbers, and inner hyphens (example: app.mysite.com)." >&2
	exit 1
fi


escape_psql_single_quoted() {
	local value="$1"
	local single_quote="'"
	value="${value//\\/\\\\}"
	value="${value//"${single_quote}"/\\"${single_quote}"}"
	printf '%s' "$value"
}

echo "Provisioning PostgreSQL database ${DB_DATABASE} for role ${DB_USERNAME}..."

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


if [[ -z "${SITE_NAME}" ]]; then
	echo "No site name given -- skipping .env sync. Update .env by hand if a site already exists."
else
	SHARED_ENV_FILE="/var/www/${SITE_NAME}/shared/.env"

	if [[ ! -e "${SHARED_ENV_FILE}" ]]; then
		echo "${SHARED_ENV_FILE} not found -- skipping .env sync." >&2
		echo "Run 04-folder-structure.sh for ${SITE_NAME} first, then re-run this script to sync .env." >&2
	else
		echo "Syncing DB_* values in ${SHARED_ENV_FILE}..."

		ENV_CONTENT="$(sudo cat "${SHARED_ENV_FILE}")"

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

		sudo chmod 640 "${SHARED_ENV_FILE}"
		sudo chown deployer:www-data "${SHARED_ENV_FILE}"

		echo ".env synced."
	fi
fi
