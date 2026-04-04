# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bash scripts that configure a minimum package release age of 7 days across Python (pip, uv) and JavaScript (npm, pnpm, bun, yarn) package managers as a supply chain attack mitigation.

Two platform-specific scripts exist due to `sed -i` syntax differences and pnpm config path differences:
- `set_package_min_age_macos.sh` — uses BSD `sed -i ''`, pnpm config at `~/Library/Preferences/pnpm/rc`
- `set_package_min_age_linux.sh` — uses GNU `sed -i`, pnpm config at `~/.config/pnpm/rc`

## Validation

```bash
bash -n set_package_min_age_macos.sh
bash -n set_package_min_age_linux.sh
```

There are no tests beyond syntax checking. To functionally test, run the script and inspect the output summary (skipped/updated/rolled-back categories).

## Script Architecture

Each script follows the same structure:

1. **`backup_if_exists()`** — copies existing config before modification (only if file is non-empty)
2. **`verify_and_finalize()`** — diffs backup vs modified file, checks all changed lines match an expected grep pattern, rolls back on unexpected changes, cleans up backup on success
3. **Per-tool `setup_*()` functions** — each checks if already correctly set (skip), set to wrong value (update), or missing (add), then calls `verify_and_finalize`
4. **End-of-run summary** — reports tools in three categories: skipped (already configured), updated, rolled back

When modifying setup functions, both scripts must be kept in sync — they are identical except for `sed -i` syntax and the pnpm config path.

## Key Design Constraints

- Scripts must be idempotent — running twice produces no changes on the second run
- Scripts must never destroy existing config — only the specific setting line is touched
- Every modification is verified against the backup; unexpected diffs trigger automatic rollback
- Each tool's `verify_and_finalize` call includes a grep pattern covering all expected diff lines (e.g. `'min-age\|\[global\]'` for pip)
