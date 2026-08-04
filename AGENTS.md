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
- `yarn classic (v1)` as a cache TTL workaround
- `yarn berry (v2+)` with native age-gate config
- `deno` via a shell wrapper that injects `--minimum-dependency-age` independently of project or npm configuration
- `pixi` via a shell wrapper that injects `--exclude-newer` (no user-level config exists)
- `vlt`
- `Bundler`
- `Hex`

The default age is 7 days. `--remove` removes managed settings. Repeatable exception flags exist for `uv`, `Poetry`, `npm`, `pnpm`, `bun`, and Yarn Berry. The Deno and Pixi wrappers do not support `--exception`; those tools only accept per-package exceptions through their project files (`deno.json`, `pixi.toml`). Hex supports repository exclusions through its separate `cooldown_exclude_repos` setting, which this repo preserves but does not manage.

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
- `deno` (managed wrapper file + a source line in `~/.zshrc` or `~/.bashrc`)
- `pixi` (managed wrapper file + a source line in `~/.zshrc` or `~/.bashrc`)
- `yarn classic (v1)`
- `yarn berry (v2+)`
- `vlt`
- `Bundler`
- `Hex`

This is intentional: it avoids relying on inconsistent CLI config getters and ensures every managed config file, including `bun`, the Deno and Pixi wrappers, Poetry, Bundler, and Hex, is validated.

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

2026-08-04: Package-manager support re-verification against upstream docs/releases. Corrected the Yarn Berry gate from `4.12.0` to `4.10.0`: `npmMinimalAgeGate` and `npmPreapprovedPackages` shipped in Yarn `4.10.0` (yarnpkg/berry#6901, released 2025-09-18), confirmed via the GitHub compare API showing the feature commit contained in the `@yarnpkg/cli/4.10.0` tag. Yarn `4.15.0` made the gate default to `1d` and `4.17.0` added per-`npmScope` overrides, neither of which changes the `npmMinimalAgeGate: "7d"` value written here. Re-confirmed unchanged: pip 26.1 relative `uploaded-prior-to`, uv 0.9.17 relative `exclude-newer`, Poetry 2.4.0 integer-day `min-release-age`, npm 11.10 base gate / 12.0 excludes, pnpm 10.16/10.17/10.19 tiers, bun 1.3, Deno 2.6, Pixi 0.47 timestamp / 0.67 relative, Bundler 4.0.13, Hex 2.5. No new mainstream package manager gained a native client-side age gate: Cargo still ships only a nightly-only `-Z unstable-options` `cargo generate-lockfile --publish-time <timestamp>` (tracking rust-lang/cargo#16271; timestamp-based, no user-level config), so it remains intentionally unsupported; Conda/Mamba, Go, NuGet/dotnet, Composer, Maven/Gradle, RubyGems `gem`, Homebrew, Swift PM, and CPAN still lack native cooldowns.

2026-08-04: Tool version detection is now bounded to 5 seconds per command after a Yarn executable hung indefinitely before the readiness table could render. Timed-out probes continue as unknown/not detected so the script can report readiness instead of freezing.

2026-08-04: Dependency maintenance scan found no dependency-managed ecosystems, manifests, lockfiles, or CI install workflows. Primary documentation review added Hex 2.5+ native cooldown support, corrected npm package exclusions to require npm 12 while retaining the npm 11.10 base gate, and corrected the Pixi wrapper's relative-duration minimum to 0.67.0. Cargo native cooldown remains accepted but not yet implemented upstream; Conda, Go, Maven/Gradle, NuGet, and Composer still lack native client-side cooldowns.

2026-07-26: Dependency maintenance scan found no dependency-managed ecosystems, manifests, lockfiles, or CI install workflows. Primary documentation review confirmed no additional mainstream package manager with a suitable client-side age gate, corrected Deno's minimum to 2.6.0 and documented its 2.9 default, and set Pixi's original timestamp cutoff minimum to 0.47.0. Bundler's managed cooldown remains available from 4.0.13; older or unknown installed versions warn while the config is still written for a future upgrade.

2026-07-06: Dependency maintenance scan found no dependency-managed ecosystems, manifests, lockfiles, CI install workflows, or Ansible/service dependency surfaces. No package-manager migrations or dependency updates were performed.

2026-07-06: Package-manager support refresh added Poetry and Bundler cooldown support, added npm exception support, updated pip/uv/Deno to relative duration settings, updated documented runtime version gates, and replaced `Makefile` with `justfile`.

Recorded package changes: none recorded.

2026-07-07: Bundler preflight now treats installed Bundler versions below `4.0.13` or with unknown detected versions as non-fatal warnings. The script still writes and validates `BUNDLE_COOLDOWN` for future Bundler upgrades, while documenting that cooldown enforcement only works on Bundler `4.0.13+`.

Recorded package changes: none recorded.

2026-07-07: Normal runs now stream a `Progress` table after tool readiness. Each managed config step prints a `start` row and then its live result, validation prints live per-tool results, and the final merged `Results` table is still emitted for summary.

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
- Bundler cooldown should remain documented as requiring Bundler `4.0.13+`; unsupported installed Bundler versions should warn rather than block other package-manager configuration.
- Hex cooldown should remain documented as requiring Hex `2.5.0+` and applying only during fresh dependency resolution, not unchanged lockfile installs.
- Normal runs should continue to stream progress after readiness so users are not left waiting silently before final results.
- Tool version probes must remain bounded so one broken package manager cannot prevent readiness output.
- Deno and Pixi should remain documented as shell-wrapper workarounds. Deno 2.8+ also reads the npm setting from `.npmrc`, but the wrapper preserves an independently managed age on Deno 2.6+; Pixi still has no user-level setting.
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
