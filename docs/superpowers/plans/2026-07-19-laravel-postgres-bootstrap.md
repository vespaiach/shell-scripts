# Laravel PostgreSQL Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Laravel-specific PostgreSQL bootstrap from the base system setup script into the atomic deployment script, prompting for database name, username, and password and wiring those values into PostgreSQL and the shared Laravel `.env`.

**Architecture:** Keep PostgreSQL server installation and localhost TCP auth in `debian-13/php-nginx-postgresql-setup.sh`. Add app-specific database provisioning and `.env` mutation to `debian-13/atomic-deployment-setup.sh`, where other app deployment state is already created.

**Tech Stack:** Bash, PostgreSQL 18, Debian service layout, Laravel `.env` configuration

---

### Task 1: Remove Laravel bootstrap output from the base setup script

**Files:**

- Modify: `debian-13/php-nginx-postgresql-setup.sh`
- Test: `debian-13/php-nginx-postgresql-setup.sh`

- [ ] **Step 1: Remove the Laravel-specific heredoc output block**

Delete the final `cat <<'EOF'` block that prints PostgreSQL follow-up steps for Laravel, leaving the script focused on package installation, PostgreSQL auth setup, and Composer installation.

- [ ] **Step 2: Run syntax validation for the base setup script**

Run: `bash -n /Users/toannguyen/scripts/debian-13/php-nginx-postgresql-setup.sh`
Expected: command exits with status 0 and no syntax errors.

### Task 2: Add interactive PostgreSQL bootstrap to the atomic deployment script

**Files:**

- Modify: `debian-13/atomic-deployment-setup.sh`
- Test: `debian-13/atomic-deployment-setup.sh`

- [ ] **Step 1: Prompt for Laravel database values**

Add prompts near the existing site and TLS prompts for:

- `DB_DATABASE`
- `DB_USERNAME`
- `DB_PASSWORD`

Use `read -r -s -p` for the password, then print a newline after the silent prompt.

- [ ] **Step 2: Validate database identifiers and prerequisites**

Add checks that:

- database name matches `^[a-zA-Z_][a-zA-Z0-9_]*$`
- username matches `^[a-zA-Z_][a-zA-Z0-9_]*$`
- password is non-empty
- `psql` is available before provisioning

Expected failure messages should be direct and exit non-zero.

- [ ] **Step 3: Provision the PostgreSQL role, database, and extensions**

Add a `sudo -u postgres psql` heredoc that:

- creates the role if it does not exist
- always ensures the role has LOGIN and the prompted password
- creates the database if it does not exist
- ensures the database owner is the prompted username
- enables `pgcrypto` and `pg_trgm` in the target database

- [ ] **Step 4: Update the shared Laravel `.env` file**

Strip any existing `DB_CONNECTION`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, and `DB_PASSWORD` lines from `${SHARED_ENV_FILE}` and append the PostgreSQL values:

```env
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=<prompted database name>
DB_USERNAME=<prompted username>
DB_PASSWORD=<prompted password>
```

Preserve all unrelated `.env` entries.

- [ ] **Step 5: Add final summary output**

Extend the script’s completion summary to print the configured database name and username, but do not print the password.

- [ ] **Step 6: Run syntax validation for the atomic deployment script**

Run: `bash -n /Users/toannguyen/scripts/debian-13/atomic-deployment-setup.sh`
Expected: command exits with status 0 and no syntax errors.

### Task 3: Final verification

**Files:**

- Test: `debian-13/php-nginx-postgresql-setup.sh`
- Test: `debian-13/atomic-deployment-setup.sh`

- [ ] **Step 1: Re-run syntax validation on both scripts together**

Run: `bash -n /Users/toannguyen/scripts/debian-13/php-nginx-postgresql-setup.sh && bash -n /Users/toannguyen/scripts/debian-13/atomic-deployment-setup.sh`
Expected: both checks exit 0.

- [ ] **Step 2: Review the changed slices for scope**

Confirm the base setup script contains only generic PostgreSQL setup while the atomic deployment script now owns Laravel-specific database provisioning and `.env` configuration.
