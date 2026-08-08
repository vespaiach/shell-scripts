# Repository Guidelines

## Project Structure & Module Organization

This repository contains Bash scripts for provisioning Debian servers. All maintained scripts live in `debian/`:

- `*-setup.sh` files configure focused services or complete PHP/Node.js stacks.
- `deployer-creation.sh` and `atomic-deployment-setup.sh` manage deployment users and releases.

There is no application source tree, asset directory, or automated test suite. Keep logic in focused scripts rather than unrelated top-level files.

## Build, Test, and Development Commands

The project has no build step. Validate changes from the repository root:

```bash
bash -n debian/*.sh
shellcheck debian/*.sh
```

`bash -n` checks syntax without executing actions; `shellcheck` performs static analysis. Use `git diff --check` for whitespace errors.

Run scripts only on a disposable Debian host; they install packages, modify `/etc`, manage services, and may prompt for credentials. Example: `bash debian/php-phpfpm-setup.sh 8.5`.

## Coding Style & Naming Conventions

Use `#!/usr/bin/env bash` and enable `set -euo pipefail` near the top. Indent blocks with tabs, quote expansions (`"${PHP_VERSION}"`), and use uppercase snake case for script-level variables. Name scripts in lowercase kebab case, such as `postgresql-setup.sh`. Prefer preflight checks, actionable errors sent to stderr, and comments explaining operational risk.

Each new script must be standalone and independently executable. Do not rely on state created by another repository script unless the prerequisite is checked and clearly reported. Scripts must also be safely rerunnable: detect existing users, packages, files, and configuration before changing them, and make repeated runs converge on the same result without duplicate entries or failures.

## Testing Guidelines

Every change must pass `bash -n`; fix or document ShellCheck findings. With no test framework, exercise changes on a clean Debian VM and verify package versions, service state, configuration syntax, and safe reruns. Never test against production first.

## Commit & Pull Request Guidelines

Use short, imperative, sentence-case subjects, for example `Extract Nginx install into standalone step file`. Keep commits focused. Pull requests should identify affected scripts, host-level side effects, prerequisites, validation performed, and rollback or compatibility concerns. Link relevant issues; include terminal output only when it clarifies behavior.

## Security & Configuration Tips

Never commit private keys, passwords, `.env` files, or production host details. Validate user input before using it in paths, package names, SQL, or service configuration. Preserve least-privilege permissions and validate sensitive files (for example with `visudo`) before installation.
