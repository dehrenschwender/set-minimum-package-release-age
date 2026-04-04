# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bash scripts that configure a minimum package release age (default 7 days, configurable via CLI argument) across Python (pip, uv) and JavaScript (npm, pnpm, bun, yarn) package managers as a supply chain attack mitigation. A `--remove` flag allows clean removal of all settings.

Two platform-specific scripts exist due to `sed -i` syntax differences and pnpm config path differences:
- `set_package_min_age_macos.sh` — uses BSD `sed -i ''`, pnpm config at `~/Library/Preferences/pnpm/rc`
- `set_package_min_age_linux.sh` — uses GNU `sed -i`, pnpm config at `~/.config/pnpm/rc`

## Validation

```bash
bash -n set_package_min_age_macos.sh
bash -n set_package_min_age_linux.sh
```

There are no tests beyond syntax checking. To functionally test:
- Run `bash set_package_min_age_macos.sh` and inspect the output summary (skipped/updated/rolled-back categories)
- Run `bash set_package_min_age_macos.sh 3d` to verify custom days work (output should say "minimum age: 3 days")
- Run `bash set_package_min_age_macos.sh --remove` to verify removal (output should show removed/not-present categories)
- Run `bash set_package_min_age_macos.sh --help` to verify usage output

## Script Architecture

Each script follows the same structure:

1. **`usage()` and argument parsing** — handles optional `DAYS` positional argument (default 7), `--remove` flag, and `-h`/`--help`; validates input and sets `MIN_AGE_DAYS` and `REMOVE_MODE`
2. **`backup_if_exists()`** — copies existing config before modification (only if file is non-empty)
3. **`verify_and_finalize()`** — diffs backup vs modified file, checks all changed lines match an expected grep pattern, rolls back on unexpected changes, cleans up backup on success
4. **Per-tool `setup_*()` functions** — each checks if already correctly set (skip), set to wrong value (update), or missing (add), then calls `verify_and_finalize`
5. **Per-tool `remove_*()` functions** — each checks if the setting exists (skip if not), backs up, removes the setting line(s) via `sed`, and calls `verify_and_finalize`; also handles empty-section cleanup (pip `[global]`, bun `[install]`) and empty-file cleanup
6. **Main section** — branches on `REMOVE_MODE`: calls `remove_*()` functions (skip validation) or `setup_*()` functions + `validate_configs()`
7. **End-of-run summary** — in set mode: skipped/updated/rolled-back; in remove mode: not-present/removed/failed

When modifying setup or remove functions, both scripts must be kept in sync — they are identical except for `sed -i` syntax and the pnpm config path.

## Key Design Constraints

- Scripts must be idempotent — running twice produces no changes on the second run
- `--remove` is also idempotent — running twice shows all settings as "not present" on the second run
- Scripts must never destroy existing config — only the specific setting line is touched
- Every modification (both set and remove) is verified against the backup; unexpected diffs trigger automatic rollback
- Each tool's `verify_and_finalize` call includes a grep pattern covering all expected diff lines (e.g. `'min-age\|\[global\]'` for pip)
- `--remove` uses generic patterns (e.g. `^min-age`, not `^min-age = 7d`) so it works regardless of what day count was originally used
