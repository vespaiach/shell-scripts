#!/usr/bin/env bash

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# Every operation in this script needs elevation, so fail before touching
# anything if sudo is unavailable.
if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required but not installed." >&2
	exit 1
fi

# ****************************************************************************************************
# Install Nginx web server.
# ****************************************************************************************************

# Install Nginx web server.
sudo apt install -y nginx

# Enable Nginx at boot and start it now.
sudo systemctl enable --now nginx

# Verify Nginx service is running.
if systemctl is-active --quiet nginx; then
	echo "Nginx is active."
else
	echo "Nginx installation check failed: service is not active." >&2
	exit 1
fi
