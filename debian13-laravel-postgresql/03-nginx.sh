#!/usr/bin/env bash
#
# Summary: Installs Nginx. No-ops if already installed. If port 80 is held by Apache, stops
#   Apache first; if held by anything else, fails with diagnostics rather than guessing.
# Input:   None.
# Output:  Nginx installed, enabled, and active on port 80.

set -euo pipefail

if [[ "$(dpkg-query --show --showformat='${Status}' nginx 2>/dev/null || true)" == "install ok installed" ]]; then
	echo "Nginx is already installed. Nothing to do."
	exit 0
fi

if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required but not installed." >&2
	exit 1
fi

if ! command -v ss >/dev/null 2>&1; then
	echo "ss is required to check whether port 80 is available." >&2
	exit 1
fi

port_80_is_in_use() {
	sudo ss --no-header --listening --tcp --numeric 'sport = :80' | grep --quiet .
}

if port_80_is_in_use; then
	if sudo systemctl is-active --quiet apache2; then
		echo "Port 80 is in use by Apache. Stopping Apache."
		sudo systemctl stop apache2
	else
		echo "Port 80 is in use, but Apache is not active. Cannot install Nginx." >&2
		sudo ss --listening --tcp --numeric --processes 'sport = :80' >&2
		exit 1
	fi

	if port_80_is_in_use; then
		echo "Port 80 is still in use after stopping Apache. Cannot install Nginx." >&2
		sudo ss --listening --tcp --numeric --processes 'sport = :80' >&2
		exit 1
	fi
fi


sudo apt install -y nginx

sudo systemctl enable --now nginx

if systemctl is-active --quiet nginx; then
	echo "Nginx is active."
else
	echo "Nginx installation check failed: service is not active." >&2
	exit 1
fi
