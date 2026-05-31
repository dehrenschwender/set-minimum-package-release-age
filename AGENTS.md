# AGENTS.md

This file provides guidance to coding agents working in this repository.

## Project Overview

Bash scripts that configure a minimum package release age across Python and JavaScript package managers as a supply-chain mitigation.

Supported tools:

- `pip`
- `uv`
- `npm`
- `pnpm`
- `bun`
- `deno`
- `yarn classic (v1)` as a cache TTL workaround
- `yarn berry (v2+)` with native age-gate config
- `vlt`

The default age is 7 days. `--remove` removes managed settings. Repeatable exception flags exist for `uv`, `pnpm`, `bun`, `deno`, and Yarn Berry.

## Architecture

The repo uses a shared core plus thin wrappers:

- `lib/set_package_min_age_common.sh`
  - shared `usage`, `parse_args`, helper functions, per-tool `setup_*` / `remove_*`, `validate_configs`, and `main`
- `set_package_min_age_linux.sh`
  - Linux wrapper that sets the GNU-style adapters and Linux pnpm path
- `set_package_min_age_macos.sh`
  - macOS wrapper that sets the BSD-style adapters and macOS pnpm path

When changing common behavior, prefer editing the shared library. Wrapper changes should stay limited to platform-specific path, date, and cron differences.

## Validation

Syntax checks:

```bash
bash -n lib/set_package_min_age_common.sh
bash -n set_package_min_age_linux.sh
bash -n set_package_min_age_macos.sh
```

Preferred shortcuts:

```bash
make syntax-check
make test
make check
```

Full test suite:

```bash
bash tests/run.sh
```

Validation is config-based for every supported tool. `validate_configs()` checks the actual files written by the scripts for:

- `pip`
- `uv`
- `npm`
- `pnpm`
- `bun`
- `deno`
- `yarn classic (v1)`
- `yarn berry (v2+)`
- `vlt`

This is intentional: it avoids relying on inconsistent CLI config getters and ensures `bun` and `deno` are validated too.

## Test Layout

- `tests/common_test.sh`
  - direct function coverage for the shared library
- `tests/linux_wrapper_test.sh`
  - Linux wrapper integration coverage
- `tests/macos_wrapper_test.sh`
  - macOS wrapper integration coverage
- `tests/test_helper.sh`
  - test harness helpers and fake binaries

The tests use a temporary `HOME`, fake manager binaries, and a fake `crontab`, so they should not modify the real machine state.

## Key Constraints

- The scripts must stay idempotent.
- `--remove` must stay idempotent.
- Config changes must continue to be verified against backups, with rollback on unexpected diffs.
- Validation should remain aligned with the exact config lines the scripts manage, including exception entries where supported.
- Yarn Classic should remain documented as a workaround, not true publish-age enforcement.
- If a behavior exists in the shared core, test it there instead of duplicating logic in both wrappers.
