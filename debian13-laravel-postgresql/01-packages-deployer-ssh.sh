#!/usr/bin/env bash
#
# Summary: Installs base packages (curl, git, gpg, ca-certificates, lsb-release, certbot,
#   python3-certbot-nginx), creates the 'deployer' user if missing, adds it to the 'sudo' group,
#   and (re)installs a validated passwordless-sudo drop-in. Authorizes one SSH public key for
#   login access (skipping the append if that exact key is already present), then generates a
#   fresh ed25519 keypair for 'deployer' to use as a GitHub deploy key -- this step is NOT
#   idempotent: an existing keypair is deleted and regenerated on every run, invalidating any
#   repository access that trusted the old public key until the new one is re-added to GitHub.
#   Requires /etc/sudoers to include /etc/sudoers.d, or it refuses to write a drop-in that would
#   be ignored.
# Input:   DEPLOYER_SSH_KEY env var, or a login SSH public key pasted at an interactive prompt
#          (fails if stdin isn't a terminal and the env var is unset).
# Output:  A 'deployer' system user in the 'sudo' group, with a passwordless sudoers drop-in
#          (/etc/sudoers.d/90-deployer), the given SSH key authorized in
#          ~deployer/.ssh/authorized_keys, and a new GitHub deploy keypair at
#          ~deployer/.ssh/id_ed25519[.pub] (public key printed to stdout for adding to GitHub).

set -euo pipefail

if ! command -v sudo >/dev/null 2>&1; then
	echo "sudo is required but not installed." >&2
	exit 1
fi

sudo apt update
sudo apt install -y curl git gpg ca-certificates lsb-release certbot python3-certbot-nginx 7z
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - && \
sudo apt install -y nodejs

DEPLOYER_USER="deployer"

if id "${DEPLOYER_USER}" >/dev/null 2>&1; then
	echo "User '${DEPLOYER_USER}' already exists."
else
	echo "Creating user '${DEPLOYER_USER}'..."
	sudo useradd -m -s /bin/bash "${DEPLOYER_USER}"
fi

sudo usermod -aG sudo "${DEPLOYER_USER}"

DEPLOYER_HOME="$(getent passwd "${DEPLOYER_USER}" | cut -d: -f6)"
DEPLOYER_GROUP="$(id -gn "${DEPLOYER_USER}")"

if [[ -z "${DEPLOYER_HOME}" ]]; then
	echo "Could not determine the home directory for '${DEPLOYER_USER}'." >&2
	exit 1
fi
SUDOERS_FILE="/etc/sudoers.d/90-${DEPLOYER_USER}"

if ! sudo grep -Eq '^[[:space:]]*[@#]includedir[[:space:]]+/etc/sudoers\.d([[:space:]]*(#.*)?)?$' /etc/sudoers; then
	echo "/etc/sudoers does not include /etc/sudoers.d; refusing to write a drop-in that would be ignored." >&2
	exit 1
fi

echo "Granting passwordless sudo to '${DEPLOYER_USER}'..."
TMP_SUDOERS="$(mktemp)"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${DEPLOYER_USER}" > "${TMP_SUDOERS}"

if ! sudo visudo -c -q -f "${TMP_SUDOERS}"; then
	rm -f "${TMP_SUDOERS}"
	echo "Generated sudoers drop-in failed validation; not installing it." >&2
	exit 1
fi

sudo install -m 0440 -o root -g root "${TMP_SUDOERS}" "${SUDOERS_FILE}"
rm -f "${TMP_SUDOERS}"

echo "Configuring SSH access for '${DEPLOYER_USER}'..."

SSH_DIR="${DEPLOYER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

DEPLOYER_SSH_KEY="${DEPLOYER_SSH_KEY:-}"

if [[ -n "${DEPLOYER_SSH_KEY}" ]]; then
	echo "Using the SSH key supplied via DEPLOYER_SSH_KEY."
elif [[ -t 0 ]]; then
	if ! read -r -p "Paste the public SSH key for '${DEPLOYER_USER}': " DEPLOYER_SSH_KEY; then
		echo "No SSH key provided." >&2
		exit 1
	fi
else
	echo "No SSH key available: stdin is not a terminal, so the key cannot be prompted for." >&2
	echo "Set DEPLOYER_SSH_KEY to the public key and rerun." >&2
	exit 1
fi

if [[ ! -d "${DEPLOYER_HOME}" ]]; then
	sudo mkdir -p "${DEPLOYER_HOME}"
	sudo chmod 755 "${DEPLOYER_HOME}"
	sudo chown "${DEPLOYER_USER}:${DEPLOYER_GROUP}" "${DEPLOYER_HOME}"
fi

sudo mkdir -p "${SSH_DIR}"
sudo touch "${AUTH_KEYS}"

if sudo test -s "${AUTH_KEYS}" && [[ -n "$(sudo tail -c 1 "${AUTH_KEYS}")" ]]; then
	printf '\n' | sudo tee -a "${AUTH_KEYS}" > /dev/null
fi

DEPLOYER_SSH_KEY_TYPE="$(printf '%s\n' "${DEPLOYER_SSH_KEY}" | awk '{print $1}')"
DEPLOYER_SSH_KEY_BLOB="$(printf '%s\n' "${DEPLOYER_SSH_KEY}" | awk '{print $2}')"
DEPLOYER_SSH_KEY_BLOB_RE="${DEPLOYER_SSH_KEY_BLOB//+/\\+}"

if sudo grep -Eq "(^|[[:space:]])${DEPLOYER_SSH_KEY_TYPE}[[:space:]]+${DEPLOYER_SSH_KEY_BLOB_RE}([[:space:]]|$)" "${AUTH_KEYS}"; then
	echo "SSH key is already authorized for '${DEPLOYER_USER}'."
else
	printf '%s\n' "${DEPLOYER_SSH_KEY}" | sudo tee -a "${AUTH_KEYS}" > /dev/null
	echo "Authorized SSH key for '${DEPLOYER_USER}'."
fi
sudo chmod 700 "${SSH_DIR}"
sudo chmod 600 "${AUTH_KEYS}"
sudo chown -R "${DEPLOYER_USER}:${DEPLOYER_GROUP}" "${SSH_DIR}"

if ! sudo test -s "${AUTH_KEYS}"; then
	echo "SSH check failed: ${AUTH_KEYS} is empty." >&2
	exit 1
fi

if sudo -u "${DEPLOYER_USER}" sudo -n true 2>/dev/null; then
	echo "User '${DEPLOYER_USER}' has passwordless sudo."
else
	echo "Passwordless sudo check failed for '${DEPLOYER_USER}'." >&2
	exit 1
fi

echo "Generating a GitHub SSH keypair for '${DEPLOYER_USER}'..."

GITHUB_SSH_KEY="${SSH_DIR}/id_ed25519"

if sudo test -e "${GITHUB_SSH_KEY}" || sudo test -e "${GITHUB_SSH_KEY}.pub"; then
	echo "'${GITHUB_SSH_KEY}' already exists and is about to be replaced." >&2
	echo "Any repository trusting the old key will lose GitHub access until the new public key below is added to GitHub." >&2
	sudo rm -f "${GITHUB_SSH_KEY}" "${GITHUB_SSH_KEY}.pub"
fi

sudo -u "${DEPLOYER_USER}" ssh-keygen -t ed25519 -f "${GITHUB_SSH_KEY}" -N "" -C "${DEPLOYER_USER}@$(hostname)"

echo "Add the following public key to GitHub (as a repository Deploy Key or under a machine account) so '${DEPLOYER_USER}' can clone over SSH:"
sudo cat "${GITHUB_SSH_KEY}.pub"
