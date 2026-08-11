#!/usr/bin/env bash

set -euo pipefail


usage() {
	cat <<EOF
Usage:
  $(basename "$0") --repo <url> --branch <branch> --dir <path> [--keep N]
  $(basename "$0") --rollback --dir <path>

  --repo      Git URL to clone (SSH or HTTPS). Required unless --rollback.
  --branch    Branch to deploy. Required unless --rollback.
  --dir       Base directory containing a releases/ directory and, after
              the first deploy, a current symlink. Always required.
  --keep      Number of releases to retain after pruning. Default: 5.
  --rollback  Roll 'current' back to the dist/ subdirectory of the release
              immediately older than the one it points at now, instead of
              deploying.
EOF
}

REPO=""
BRANCH=""
TARGET_DIR=""
KEEP_RELEASES=5
ROLLBACK=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--repo)
			REPO="${2:-}"
			shift 2
			;;
		--branch)
			BRANCH="${2:-}"
			shift 2
			;;
		--dir)
			TARGET_DIR="${2:-}"
			shift 2
			;;
		--keep)
			KEEP_RELEASES="${2:-}"
			shift 2
			;;
		--rollback)
			ROLLBACK=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 1
			;;
	esac
done


if [[ -z "${TARGET_DIR}" ]]; then
	echo "--dir is required." >&2
	usage >&2
	exit 1
fi

if [[ "${ROLLBACK}" -eq 0 ]]; then
	if [[ -z "${REPO}" ]]; then
		echo "--repo is required." >&2
		usage >&2
		exit 1
	fi

	if [[ -z "${BRANCH}" ]]; then
		echo "--branch is required." >&2
		usage >&2
		exit 1
	fi

	if [[ ! "${KEEP_RELEASES}" =~ ^[1-9][0-9]*$ ]]; then
		echo "--keep must be a positive integer." >&2
		exit 1
	fi
fi


RELEASES_DIR="${TARGET_DIR}/releases"
CURRENT_LINK="${TARGET_DIR}/current"

if [[ ! -d "${RELEASES_DIR}" ]]; then
	echo "${RELEASES_DIR} does not exist." >&2
	echo "This script deploys, it does not provision -- run 'mkdir -p ${RELEASES_DIR}' first." >&2
	exit 1
fi

if [[ -e "${CURRENT_LINK}" && ! -L "${CURRENT_LINK}" ]]; then
	echo "${CURRENT_LINK} exists but is not a symlink." >&2
	exit 1
fi


if [[ "${ROLLBACK}" -eq 1 ]]; then
	if [[ ! -L "${CURRENT_LINK}" ]]; then
		echo "${CURRENT_LINK} is not a symlink; nothing to roll back." >&2
		exit 1
	fi

	CURRENT_RELEASE_DIST="$(cd "${CURRENT_LINK}" && pwd -P)"
	CURRENT_RELEASE_NAME="$(basename "$(dirname "${CURRENT_RELEASE_DIST}")")"

	PREVIOUS_RELEASE_NAME="$(find "${RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
		| sort -r \
		| awk -v cur="${CURRENT_RELEASE_NAME}" 'seen{print; exit} $0==cur{seen=1}')"

	if [[ -z "${PREVIOUS_RELEASE_NAME}" ]]; then
		echo "No older release to roll back to." >&2
		exit 1
	fi

	PREVIOUS_RELEASE_DIST="${RELEASES_DIR}/${PREVIOUS_RELEASE_NAME}/dist"

	if [[ ! -d "${PREVIOUS_RELEASE_DIST}" ]]; then
		echo "${PREVIOUS_RELEASE_DIST} does not exist; cannot roll back to it." >&2
		exit 1
	fi

	echo "Rolling back current from ${CURRENT_RELEASE_NAME} to ${PREVIOUS_RELEASE_NAME}..."
	ln -sfn "${PREVIOUS_RELEASE_DIST}" "${CURRENT_LINK}"

	echo "Done."
	echo "Rolled back: ${CURRENT_RELEASE_NAME} -> ${PREVIOUS_RELEASE_NAME}"
	exit 0
fi


NEW_RELEASE_DIR="${RELEASES_DIR}/$(date +%Y%m%d%H%M%S)"

echo "Deploying branch '${BRANCH}' to ${NEW_RELEASE_DIR}..."
git clone --branch "${BRANCH}" --single-branch --depth 1 "${REPO}" "${NEW_RELEASE_DIR}"

NEW_RELEASE_DIST="${NEW_RELEASE_DIR}/dist"
if [[ ! -d "${NEW_RELEASE_DIST}" ]]; then
	echo "${NEW_RELEASE_DIST} does not exist in the cloned branch; not swapping current." >&2
	exit 1
fi

echo "Swapping current -> ${NEW_RELEASE_DIST}..."
ln -sfn "${NEW_RELEASE_DIST}" "${CURRENT_LINK}"

echo "Pruning releases beyond ${KEEP_RELEASES}..."
mapfile -t OLD_RELEASES < <(find "${RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | tail -n +$((KEEP_RELEASES + 1)))
for old in "${OLD_RELEASES[@]}"; do
	echo "Removing old release ${old}..."
	rm -rf "${RELEASES_DIR:?}/${old}"
done

echo "Done."
echo "Target: ${TARGET_DIR}"
echo "Branch deployed: ${BRANCH}"
echo "New release: ${NEW_RELEASE_DIR}"
echo "Releases kept: ${KEEP_RELEASES}"
