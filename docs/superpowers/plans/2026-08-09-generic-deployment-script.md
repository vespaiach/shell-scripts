# Generic Deployment Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `debian/09-deployment.sh`, a standalone generic deploy script that clones a repo branch into a timestamped release, swaps a `current` symlink onto it, prunes old releases, and supports `--rollback`.

**Architecture:** A single self-contained bash script, following this repo's existing numbered-script convention. Built incrementally: argument parsing/validation first, then deploy mode, then rollback mode — each layer independently verified with `bash -n`, `shellcheck`, and a functional smoke test against a local scratch git repo (this repo has no unit test framework, so "tests" here are syntax/lint checks plus real invocations against throwaway fixtures in `$(mktemp -d)`, not a live Debian server).

**Tech Stack:** Bash (`set -euo pipefail`), git, coreutils (`find`, `awk`, `sort`, `ln`), shellcheck.

## Global Constraints

- `#!/usr/bin/env bash` and `set -euo pipefail` near the top (spec: Error handling; repo convention: AGENTS.md Coding Style).
- Tab indentation, quoted expansions, uppercase snake case for script-level variables (AGENTS.md Coding Style).
- Filename `debian/09-deployment.sh`, lowercase kebab case (spec: Placement; AGENTS.md Coding Style).
- No composer/npm/artisan steps, no shared-file symlinking, no user/ownership handling (spec: Out of scope).
- `<dir>/releases` must already exist; script deploys, does not provision — fail with an actionable message if missing (spec: Usage, `--dir`).
- Default `--keep` is `5` (spec: Usage, `--keep`).
- Validate with `bash -n debian/09-deployment.sh` and `shellcheck debian/09-deployment.sh` (spec: Testing; AGENTS.md Build/Test).

---

### Task 1: Script skeleton — usage, flag parsing, validation

**Files:**
- Create: `debian/09-deployment.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces (variables later tasks rely on, all set by end of this task's flag-parsing/validation block): `REPO` (string, git URL, empty in rollback mode), `BRANCH` (string, empty in rollback mode), `TARGET_DIR` (string, required), `KEEP_RELEASES` (positive integer, default `5`, unvalidated/unused in rollback mode), `ROLLBACK` (`0` or `1`), `RELEASES_DIR="${TARGET_DIR}/releases"`, `CURRENT_LINK="${TARGET_DIR}/current"`. Also produces the `usage()` function later tasks may call on their own error paths.

- [ ] **Step 1: Write the script skeleton with usage, flag parsing, and validation**

Create `debian/09-deployment.sh`:

```bash
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
```

The final `echo` is a temporary marker so this step is independently
verifiable; Task 2 replaces it with the deploy-mode body and Task 3 adds
the rollback-mode body above it.

- [ ] **Step 2: Make it executable and check syntax**

Run:
```bash
chmod +x debian/09-deployment.sh
bash -n debian/09-deployment.sh
```
Expected: no output (syntax OK).

- [ ] **Step 3: Run shellcheck**

Run: `shellcheck debian/09-deployment.sh`
Expected: no findings. If shellcheck is not installed, note that in the
task result instead of skipping silently.

- [ ] **Step 4: Functional smoke test of parsing/validation**

Run each of these and confirm the described behavior:

```bash
./debian/09-deployment.sh --help
# Expected: usage text, exit 0

./debian/09-deployment.sh
# Expected: "--dir is required." on stderr, exit 1

./debian/09-deployment.sh --dir /tmp/does-not-exist-xyz
# Expected: "--repo is required." on stderr, exit 1

TMP_DIR="$(mktemp -d)"
./debian/09-deployment.sh --repo x --branch main --dir "${TMP_DIR}"
# Expected: "<TMP_DIR>/releases does not exist." on stderr, exit 1

mkdir -p "${TMP_DIR}/releases"
./debian/09-deployment.sh --repo x --branch main --dir "${TMP_DIR}" --keep 0
# Expected: "--keep must be a positive integer." on stderr, exit 1

./debian/09-deployment.sh --repo x --branch main --dir "${TMP_DIR}"
# Expected: "Arguments OK. ROLLBACK=0 TARGET_DIR=<TMP_DIR> KEEP_RELEASES=5", exit 0

rm -rf "${TMP_DIR}"
```

- [ ] **Step 5: Commit**

```bash
git add debian/09-deployment.sh
git commit -m "Add deployment.sh skeleton with flag parsing and validation"
```

---

### Task 2: Deploy mode — clone, symlink swap, prune

**Files:**
- Modify: `debian/09-deployment.sh` (replace the `echo "Arguments OK...."` marker line at the end of the file with the deploy-mode body)

**Interfaces:**
- Consumes: `REPO`, `BRANCH`, `TARGET_DIR`, `KEEP_RELEASES`, `RELEASES_DIR`, `CURRENT_LINK` from Task 1.
- Produces: nothing new consumed by name elsewhere, but establishes the
  release-directory naming convention `RELEASES_DIR/<YYYYmmddHHMMSS>` that
  Task 3's rollback logic depends on.

- [ ] **Step 1: Replace the marker line with the deploy-mode body**

In `debian/09-deployment.sh`, replace this line (the last line of the file
from Task 1):

```bash
echo "Arguments OK. ROLLBACK=${ROLLBACK} TARGET_DIR=${TARGET_DIR} KEEP_RELEASES=${KEEP_RELEASES}"
```

with:

```bash
# ---- Deploy mode ----

NEW_RELEASE_DIR="${RELEASES_DIR}/$(date +%Y%m%d%H%M%S)"

echo "Deploying branch '${BRANCH}' to ${NEW_RELEASE_DIR}..."
git clone --branch "${BRANCH}" --single-branch --depth 1 "${REPO}" "${NEW_RELEASE_DIR}"

echo "Swapping current -> ${NEW_RELEASE_DIR}..."
ln -sfn "${NEW_RELEASE_DIR}" "${CURRENT_LINK}"

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
```

- [ ] **Step 2: Check syntax and lint**

Run:
```bash
bash -n debian/09-deployment.sh
shellcheck debian/09-deployment.sh
```
Expected: no output from `bash -n`; no findings from `shellcheck`.

- [ ] **Step 3: Functional test against a local scratch git repo**

This repo has no live server to deploy to, but git clone and symlink
operations work identically against a local repo, so exercise the real
logic end-to-end here:

```bash
SCRATCH="$(mktemp -d)"
SRC_REPO="${SCRATCH}/src"
TARGET_DIR="${SCRATCH}/target"

git init -q -b main "${SRC_REPO}"
echo "v1" > "${SRC_REPO}/VERSION"
git -C "${SRC_REPO}" add VERSION
git -C "${SRC_REPO}" -c user.email=t@example.com -c user.name=t commit -q -m "v1"

mkdir -p "${TARGET_DIR}/releases"

./debian/09-deployment.sh --repo "${SRC_REPO}" --branch main --dir "${TARGET_DIR}" --keep 2
cat "${TARGET_DIR}/current/VERSION"
# Expected: v1

echo "v2" > "${SRC_REPO}/VERSION"
git -C "${SRC_REPO}" add VERSION
git -C "${SRC_REPO}" -c user.email=t@example.com -c user.name=t commit -q -m "v2"

sleep 1
./debian/09-deployment.sh --repo "${SRC_REPO}" --branch main --dir "${TARGET_DIR}" --keep 2
cat "${TARGET_DIR}/current/VERSION"
# Expected: v2
ls "${TARGET_DIR}/releases" | wc -l
# Expected: 2

echo "v3" > "${SRC_REPO}/VERSION"
git -C "${SRC_REPO}" add VERSION
git -C "${SRC_REPO}" -c user.email=t@example.com -c user.name=t commit -q -m "v3"

sleep 1
./debian/09-deployment.sh --repo "${SRC_REPO}" --branch main --dir "${TARGET_DIR}" --keep 2
cat "${TARGET_DIR}/current/VERSION"
# Expected: v3
ls "${TARGET_DIR}/releases" | wc -l
# Expected: 2 (oldest release pruned)

rm -rf "${SCRATCH}"
```

The `sleep 1` calls guarantee distinct `date +%Y%m%d%H%M%S` release
directory names between successive deploys in the same test run.

- [ ] **Step 4: Commit**

```bash
git add debian/09-deployment.sh
git commit -m "Implement deploy mode: clone, symlink swap, and prune"
```

---

### Task 3: Rollback mode

**Files:**
- Modify: `debian/09-deployment.sh` (insert the rollback-mode body between
  the "Derive paths and validate target layout" block and the
  `# ---- Deploy mode ----` block added in Task 2)

**Interfaces:**
- Consumes: `ROLLBACK`, `RELEASES_DIR`, `CURRENT_LINK` from Task 1; relies
  on the `RELEASES_DIR/<YYYYmmddHHMMSS>` naming convention established by
  Task 2's deploy mode so lexical `sort -r` orders releases newest-first.
- Produces: nothing consumed elsewhere (this is the last mode added).

- [ ] **Step 1: Insert the rollback-mode body**

In `debian/09-deployment.sh`, immediately before the line:

```bash
# ---- Deploy mode ----
```

insert:

```bash
# ---- Rollback mode ----

if [[ "${ROLLBACK}" -eq 1 ]]; then
	if [[ ! -L "${CURRENT_LINK}" ]]; then
		echo "${CURRENT_LINK} is not a symlink; nothing to roll back." >&2
		exit 1
	fi

	CURRENT_RELEASE="$(cd "${CURRENT_LINK}" && pwd -P)"
	CURRENT_RELEASE_NAME="$(basename "${CURRENT_RELEASE}")"

	PREVIOUS_RELEASE_NAME="$(find "${RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
		| sort -r \
		| awk -v cur="${CURRENT_RELEASE_NAME}" 'seen{print; exit} $0==cur{seen=1}')"

	if [[ -z "${PREVIOUS_RELEASE_NAME}" ]]; then
		echo "No older release to roll back to." >&2
		exit 1
	fi

	PREVIOUS_RELEASE_DIR="${RELEASES_DIR}/${PREVIOUS_RELEASE_NAME}"

	echo "Rolling back current from ${CURRENT_RELEASE_NAME} to ${PREVIOUS_RELEASE_NAME}..."
	ln -sfn "${PREVIOUS_RELEASE_DIR}" "${CURRENT_LINK}"

	echo "Done."
	echo "Rolled back: ${CURRENT_RELEASE_NAME} -> ${PREVIOUS_RELEASE_NAME}"
	exit 0
fi
```

- [ ] **Step 2: Check syntax and lint**

Run:
```bash
bash -n debian/09-deployment.sh
shellcheck debian/09-deployment.sh
```
Expected: no output from `bash -n`; no findings from `shellcheck`.

- [ ] **Step 3: Functional test of rollback against a local scratch git repo**

```bash
SCRATCH="$(mktemp -d)"
SRC_REPO="${SCRATCH}/src"
TARGET_DIR="${SCRATCH}/target"

git init -q -b main "${SRC_REPO}"
echo "v1" > "${SRC_REPO}/VERSION"
git -C "${SRC_REPO}" add VERSION
git -C "${SRC_REPO}" -c user.email=t@example.com -c user.name=t commit -q -m "v1"

mkdir -p "${TARGET_DIR}/releases"
./debian/09-deployment.sh --repo "${SRC_REPO}" --branch main --dir "${TARGET_DIR}" --keep 5

sleep 1
echo "v2" > "${SRC_REPO}/VERSION"
git -C "${SRC_REPO}" add VERSION
git -C "${SRC_REPO}" -c user.email=t@example.com -c user.name=t commit -q -m "v2"
./debian/09-deployment.sh --repo "${SRC_REPO}" --branch main --dir "${TARGET_DIR}" --keep 5

cat "${TARGET_DIR}/current/VERSION"
# Expected: v2

./debian/09-deployment.sh --rollback --dir "${TARGET_DIR}"
cat "${TARGET_DIR}/current/VERSION"
# Expected: v1

./debian/09-deployment.sh --rollback --dir "${TARGET_DIR}"
# Expected: "No older release to roll back to." on stderr, exit 1

rm -rf "${SCRATCH}"
```

- [ ] **Step 4: Commit**

```bash
git add debian/09-deployment.sh
git commit -m "Implement rollback mode"
```

---

### Task 4: Document the script and final validation pass

**Files:**
- Modify: `AGENTS.md` (Project Structure & Module Organization section)

**Interfaces:**
- Consumes: nothing new — this task only documents the finished script.
- Produces: nothing consumed by other tasks (final task).

- [ ] **Step 1: Add a bullet for the new script in AGENTS.md**

In `AGENTS.md`, in the "Project Structure & Module Organization" bulleted
list (after the `07-nginx-tls-vhost.sh` bullet, before the closing
paragraph that starts "There is no application source tree..."), add:

```markdown
- `09-deployment.sh` is a standalone, generic deploy script -- unlike
  `08-laravel-deployment.sh`, it has no framework-specific steps (no
  composer/npm/artisan), no shared-file symlinking, and no user/ownership
  handling. Given `--repo`, `--branch`, and `--dir`, it clones the branch
  into a new timestamped release under `<dir>/releases`, swaps
  `<dir>/current` onto it, and prunes releases beyond `--keep` (default
  5). `--rollback --dir <path>` flips `current` back to the release
  immediately older than the one it points at now. It deploys, it does
  not provision -- `<dir>/releases` must already exist before the first
  run.
```

- [ ] **Step 2: Full-repo syntax and lint pass**

Run:
```bash
bash -n debian/*.sh
shellcheck debian/*.sh
```
Expected: no output from `bash -n` for any file; no new shellcheck
findings introduced by `09-deployment.sh` (pre-existing findings in other
files, if any, are out of scope for this change).

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "Document 09-deployment.sh in AGENTS.md"
```

## Self-Review Notes

- **Spec coverage:** Usage/flags (Task 1), deploy flow steps 1-5 (Tasks 1-2),
  rollback flow steps 1-5 (Task 3), error handling (Task 1, exercised in
  Task 1 Step 4 and Task 3 Step 3), testing commands (every task's syntax/lint
  steps), out-of-scope items (deliberately absent from all tasks) — all
  covered.
- **Placeholder scan:** no TBD/TODO markers; every step has literal code or
  literal commands and expected output.
- **Type consistency:** `REPO`/`BRANCH`/`TARGET_DIR`/`KEEP_RELEASES`/
  `ROLLBACK`/`RELEASES_DIR`/`CURRENT_LINK` are defined once in Task 1 and
  referenced with the same names and meaning in Tasks 2 and 3.
