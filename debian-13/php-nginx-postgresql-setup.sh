#!/usr/bin/env bash

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# Every operation in this script needs elevation, so fail before touching
# anything if sudo is unavailable.
if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required but not installed." >&2
	exit 1
fi

# Resolve this script's own directory so the step files below are found
# regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS_DIR="${SCRIPT_DIR}/php-nginx-postgresql-setup"

# Step 1: Install PHP 8.5 and configure FPM for production.
bash "${STEPS_DIR}/01-php.sh"

# Step 2: Install Nginx.
bash "${STEPS_DIR}/02-nginx.sh"

# Step 3: Install and configure PostgreSQL 18.
bash "${STEPS_DIR}/03-postgresql.sh"

# Step 4: Create the deployer user.
bash "${STEPS_DIR}/04-deployer.sh"
