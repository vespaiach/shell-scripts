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
# Create the deployer user with passwordless sudo and SSH key access.
# ****************************************************************************************************

DEPLOYER_USER="deployer"

# atomic-deployment-setup.sh refuses to run as anyone else, so this account has
# to exist before any site can be provisioned on this host.
if id "${DEPLOYER_USER}" >/dev/null 2>&1; then
	echo "User '${DEPLOYER_USER}' already exists."
else
	echo "Creating user '${DEPLOYER_USER}'..."
	# No password is set, so the account is reachable by SSH key only. That is
	# also why the sudoers grant below has to be NOPASSWD: with no password to
	# type, a password-prompting sudo would be unusable rather than merely
	# inconvenient.
	sudo useradd -m -s /bin/bash "${DEPLOYER_USER}"
fi

# Run unconditionally rather than only for freshly created accounts: usermod -aG
# is idempotent, and a deployer that predates this script may not be in the
# group yet.
sudo usermod -aG sudo "${DEPLOYER_USER}"

# Resolve the home directory and primary group from the passwd/group database
# instead of assuming /home/deployer and a deployer:deployer pair -- a
# pre-existing account may have been created with either one different.
DEPLOYER_HOME="$(getent passwd "${DEPLOYER_USER}" | cut -d: -f6)"
DEPLOYER_GROUP="$(id -gn "${DEPLOYER_USER}")"

if [[ -z "${DEPLOYER_HOME}" ]]; then
	echo "Could not determine the home directory for '${DEPLOYER_USER}'." >&2
	exit 1
fi

# ---- Passwordless sudo ----

SUDOERS_FILE="/etc/sudoers.d/90-${DEPLOYER_USER}"

# A drop-in is only honoured if the main sudoers file pulls the directory in.
# Without this check the grant below would appear to succeed and silently do
# nothing, leaving deployer with an unusable password-prompting sudo.
if ! sudo grep -Eq '^[[:space:]]*[@#]includedir[[:space:]]+/etc/sudoers\.d([[:space:]]*(#.*)?)?$' /etc/sudoers; then
	echo "/etc/sudoers does not include /etc/sudoers.d; refusing to write a drop-in that would be ignored." >&2
	exit 1
fi

echo "Granting passwordless sudo to '${DEPLOYER_USER}'..."
TMP_SUDOERS="$(mktemp)"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${DEPLOYER_USER}" > "${TMP_SUDOERS}"

# Validate before installing. A malformed file in sudoers.d breaks sudo for
# every user on the host, including the one running this script, so this is
# checked while the content is still a throwaway temp file.
if ! sudo visudo -c -q -f "${TMP_SUDOERS}"; then
	rm -f "${TMP_SUDOERS}"
	echo "Generated sudoers drop-in failed validation; not installing it." >&2
	exit 1
fi

# install(1) sets ownership and the required 0440 mode as it copies -- sudo
# ignores any file in sudoers.d that is group- or world-writable, which is
# exactly what the 0600 temp file would become after a plain mv + chmod race.
sudo install -m 0440 -o root -g root "${TMP_SUDOERS}" "${SUDOERS_FILE}"
rm -f "${TMP_SUDOERS}"

# ---- SSH access ----

echo "Configuring SSH access for '${DEPLOYER_USER}'..."

SSH_DIR="${DEPLOYER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

# Lets the key be supplied non-interactively for unattended provisioning
# (cloud-init, CI). Left empty, the script prompts for it below.
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


# A pre-existing account may have no home directory. Creating .ssh below would
# then create the home too, owned by root, which sshd's StrictModes rejects.
if [[ ! -d "${DEPLOYER_HOME}" ]]; then
	sudo mkdir -p "${DEPLOYER_HOME}"
	sudo chmod 755 "${DEPLOYER_HOME}"
	sudo chown "${DEPLOYER_USER}:${DEPLOYER_GROUP}" "${DEPLOYER_HOME}"
fi

sudo mkdir -p "${SSH_DIR}"
sudo touch "${AUTH_KEYS}"

# An existing authorized_keys that does not end in a newline would otherwise get
# the appended key glued onto its last line, corrupting both.
if sudo test -s "${AUTH_KEYS}" && [[ -n "$(sudo tail -c 1 "${AUTH_KEYS}")" ]]; then
	printf '\n' | sudo tee -a "${AUTH_KEYS}" > /dev/null
fi

# Append rather than overwrite: re-running this script must not drop keys an
# operator added by hand, and should not accumulate duplicates of the same key
# if the comment/options differ between runs.
DEPLOYER_SSH_KEY_TYPE="$(printf '%s\n' "${DEPLOYER_SSH_KEY}" | awk '{print $1}')"
DEPLOYER_SSH_KEY_BLOB="$(printf '%s\n' "${DEPLOYER_SSH_KEY}" | awk '{print $2}')"
DEPLOYER_SSH_KEY_BLOB_RE="${DEPLOYER_SSH_KEY_BLOB//+/\\+}"

if sudo grep -Eq "(^|[[:space:]])${DEPLOYER_SSH_KEY_TYPE}[[:space:]]+${DEPLOYER_SSH_KEY_BLOB_RE}([[:space:]]|$)" "${AUTH_KEYS}"; then
	echo "SSH key is already authorized for '${DEPLOYER_USER}'."
else
	printf '%s\n' "${DEPLOYER_SSH_KEY}" | sudo tee -a "${AUTH_KEYS}" > /dev/null
	echo "Authorized SSH key for '${DEPLOYER_USER}'."
fi

# sshd ignores keys from a group- or world-writable ~/.ssh or authorized_keys.
sudo chmod 700 "${SSH_DIR}"
sudo chmod 600 "${AUTH_KEYS}"
sudo chown -R "${DEPLOYER_USER}:${DEPLOYER_GROUP}" "${SSH_DIR}"

if ! sudo test -s "${AUTH_KEYS}"; then
	echo "SSH check failed: ${AUTH_KEYS} is empty." >&2
	exit 1
fi

# Prove the sudo grant works instead of assuming it: sudo -n fails outright if
# the drop-in was not picked up, which is the whole failure mode worth catching
# here while the operator still has a working session.
if sudo -u "${DEPLOYER_USER}" sudo -n true 2>/dev/null; then
	echo "User '${DEPLOYER_USER}' has passwordless sudo."
else
	echo "Passwordless sudo check failed for '${DEPLOYER_USER}'." >&2
	exit 1
fi
