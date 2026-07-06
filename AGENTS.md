# Project Memory

## Overview

This repository contains Bash scripts that configure a minimum package release age across Python, JavaScript, and Ruby package managers as a supply-chain mitigation.

Supported tools:

- `pip`
- `uv`
- `Poetry`
- `npm`
- `pnpm`
- `bun`
- `deno`
- `yarn classic (v1)` as a cache TTL workaround
- `yarn berry (v2+)` with native age-gate config
- `vlt`
- `Bundler`

The default age is 7 days. `--remove` removes managed settings. Repeatable exception flags exist for `uv`, `Poetry`, `npm`, `pnpm`, `bun`, `deno`, and Yarn Berry.

## Architecture

The repo uses a shared core plus thin wrappers:

- `lib/set_package_min_age_common.sh`
  - shared `usage`, `parse_args`, helper functions, per-tool `setup_*` / `remove_*`, `validate_configs`, and `main`
- `set_package_min_age_linux.sh`
  - Linux wrapper that sets the GNU-style adapters plus Linux pnpm, Poetry, and vlt paths
- `set_package_min_age_macos.sh`
  - macOS wrapper that sets the BSD-style adapters plus macOS pnpm, Poetry, and vlt paths

When changing common behavior, prefer editing the shared library. Wrapper changes should stay limited to platform-specific path, date, and cron differences.

Validation is config-based for every supported tool. `validate_configs()` checks the actual files written by the scripts for:

- `pip`
- `uv`
- `Poetry`
- `npm`
- `pnpm`
- `bun`
- `deno`
- `yarn classic (v1)`
- `yarn berry (v2+)`
- `vlt`
- `Bundler`

This is intentional: it avoids relying on inconsistent CLI config getters and ensures every managed config file, including `bun`, `deno`, Poetry, and Bundler, is validated.

## Package Manager Policy

This repository currently has no dependency-managed application ecosystem manifests (`package.json`, Python manifests, `Gemfile`, `go.mod`, `Cargo.toml`, Maven, or Gradle files).

If dependency manifests are added later:

- Use `pnpm` for JavaScript or TypeScript projects.
- Use `uv` for Python projects.
- Use Bundler for Ruby projects.
- Keep standard tooling for Go, Rust, Java, and Kotlin.
- Commit lockfiles with manifest changes.

## Dependency Policy

No project dependencies are currently recorded.

If dependencies are added later:

- Pin dependency manifest versions exactly.
- Do not downgrade dependencies.
- Regenerate lockfiles after manifest changes.
- Record major dependency version bumps under `Known Issues / TODOs` for manual review.

## Last Dependency Update

2026-07-06: Dependency maintenance scan found no dependency-managed ecosystems, manifests, lockfiles, CI install workflows, or Ansible/service dependency surfaces. No package-manager migrations or dependency updates were performed.

2026-07-06: Package-manager support refresh added Poetry and Bundler cooldown support, added npm exception support, updated pip/uv/Deno to relative duration settings, updated documented runtime version gates, and replaced `Makefile` with `justfile`.

Recorded package changes: none recorded.

## Agent Instructions

- Always preserve unrelated user changes.
- Always update `AGENTS.md` when repository maintenance changes project assumptions.
- Never hand-edit generated adapter output when canonical sources exist.
- If dependency work was performed, lockfiles must be regenerated and committed with manifest changes.
- Major dependency version bumps must be recorded under `Known Issues / TODOs`.
- `CLAUDE.md` must be a symlink to `AGENTS.md`, never a regular file.
- The scripts must stay idempotent.
- `--remove` must stay idempotent.
- Config changes must continue to be verified against backups, with rollback on unexpected diffs.
- Validation should remain aligned with the exact config lines the scripts manage, including exception entries where supported.
- Yarn Classic should remain documented as a workaround, not true publish-age enforcement.
- If a behavior exists in the shared core, test it there instead of duplicating logic in both wrappers.

## Validation

Syntax checks:

```bash
bash -n lib/set_package_min_age_common.sh
bash -n set_package_min_age_linux.sh
bash -n set_package_min_age_macos.sh
```

Preferred shortcuts:

```bash
just syntax-check
just test
just check
```

Full test suite:

```bash
bash tests/run.sh
```

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

## Known Issues / TODOs

- No known dependency issues.
- No major dependency version bumps pending review.
