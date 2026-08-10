#!/usr/bin/env bash

# Exit immediately on command errors and treat unset variables as errors.
set -euo pipefail

# ****************************************************************************************************
# Generic, standalone deploy script: clones a branch from GitHub into a new
# timestamped release under <dir>/releases, swaps <dir>/current onto it, and
# prunes releases beyond --keep. --rollback flips current back to the release
# immediately older than the one it points at now. Unlike
# 08-laravel-deployment.sh, this script has no framework-specific steps (no
# composer/npm/artisan), no shared-file symlinking, and no user/ownership
# handling -- it only clones and swaps a symlink. <dir>/releases must already
# exist; this script deploys, it does not provision.
# ****************************************************************************************************

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
  --rollback  Roll 'current' back to the release immediately older than the
              one it points at now, instead of deploying.
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

# ---- Validate arguments ----

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

# ---- Derive paths and validate target layout ----

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

echo "Arguments OK. ROLLBACK=${ROLLBACK} TARGET_DIR=${TARGET_DIR} KEEP_RELEASES=${KEEP_RELEASES}"
