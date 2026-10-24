# Project Memory

## Overview

This repository contains Bash scripts that configure a minimum package release age across Python, JavaScript, Ruby, Elixir/Erlang, and Rust package managers, plus the mise tool manager, as a supply-chain mitigation.

Supported tools:

- `pip`
- `uv`
- `Poetry`
- `PDM`
- `npm`
- `pnpm`
- `bun`
- `yarn classic (v1)` as a cache TTL workaround
- `yarn berry (v2+)` with native age-gate config
- `deno` via a shell wrapper that injects `--minimum-dependency-age` independently of project or npm configuration
- `pixi` via a root `exclude-newer` in the existing `pixi global` manifest (pixi 0.82.0+; workspaces have no user-level setting)
- `vlt` (absolute `before` date refreshed daily by a launchd agent on macOS or cron on Linux)
- `Bundler`
- `Hex`
- `Cargo`
- `mise`

The default age is 7 days. `--remove` removes managed settings. Repeatable exception flags exist for `uv`, `Poetry`, `npm`, `pnpm`, `bun`, Yarn Berry, `mise`, `pixi` (package exemptions in the global manifest), Hex (repository exclusions via `cooldown_exclude_repos`), and Cargo (registry exemptions via `[registries.<name>] min-publish-age = "0"`). pip, PDM, Deno, vlt, Yarn Classic, and Bundler have no user-level exclusion setting (PDM and Deno only accept them in project files). Hex `cooldown_exclude_repos` is only managed when `hex` exceptions are passed; otherwise it is preserved. Cargo exemption lines carry a `# set-minimum-package-release-age exception` marker, and only marked lines are managed.

## Architecture

The repo uses a shared core plus thin wrappers:

- `lib/set_package_min_age_ui.sh`
  - all terminal rendering (`ui_*`): width detection and clamping (32-120), wrapping with hanging indents, middle-shortened paths, the stacked layout for narrow terminals, color (only on a TTY, never with `NO_COLOR`), and ASCII fallbacks
  - sourced by the shared library; tool logic should call `emit_config_status`, `record_preflight_*`, or `ui_*` helpers instead of printing directly
- `lib/set_package_min_age_common.sh`
  - shared `usage`, `parse_args`, config path resolution, helper functions, per-tool `setup_*` / `remove_*`, `validate_configs`, and `main`
  - `ALL_TOOL_KEYS` is the single ordered tool list used for the results table and full removal
  - `setup_toml_section_age` / `remove_toml_section_age` / `validate_toml_section_age` cover tools whose managed state is one line (plus an optional list) in one TOML section (PDM, Cargo, mise)
  - the vlt refresh scheduler: `cron` backend (Linux) or `launchd` backend (macOS), selected by `VLT_REFRESH_SCHEDULER`
- `set_package_min_age_linux.sh`
  - Linux wrapper with the GNU `date` adapter and vlt cron line builder; Linux paths all come from the shared XDG-aware defaults
- `set_package_min_age_macos.sh`
  - macOS wrapper with the BSD `date` adapter, macOS pnpm, vlt, pip, Poetry, PDM, and pixi paths, and `VLT_REFRESH_SCHEDULER=launchd`
- Both wrappers start with the same bash guard (re-run with bash from zsh/sh, refuse to be sourced).

When changing common behavior, prefer editing the shared library. Wrapper changes should stay limited to platform-specific path, date, and scheduler differences.

Validation is config-based for every supported tool. `validate_configs()` checks the actual files written by the scripts for:

- `pip`
- `uv`
- `Poetry`
- `PDM`
- `npm`
- `pnpm`
- `bun`
- `deno` (managed wrapper file + a source line in `~/.zshrc`/`$ZDOTDIR/.zshrc` or `~/.bashrc`)
- `pixi` (root `exclude-newer`, including exemptions, in the pixi global manifest; fails if the broken legacy wrapper is still installed)
- `yarn classic (v1)`
- `yarn berry (v2+)`
- `vlt`
- `Bundler`
- `Hex` (including `cooldown_exclude_repos` when `hex` exceptions are passed)
- `Cargo` (including the marked registry exemption lines)
- `mise`

Tools blocked by a failed version check are reported as `blocked` instead of being validated.

This is intentional: it avoids relying on inconsistent CLI config getters and ensures every managed config file, including `bun`, the Deno wrapper, the pixi global manifest, Poetry, PDM, Bundler, Hex, Cargo, and mise, is validated.

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

2026-10-24: Package-manager re-verification against upstream source, docs, and real binaries (pip 26.2.1, uv 0.13.5, npm 11.13.0, pnpm 12.15.0, bun 1.4.3, Bundler, Cargo 1.96 run against a temporary `HOME`). No dependency-managed ecosystems exist, so no packages were updated. Fixes:
- Config paths now follow each tool's own overrides. uv, bun, pnpm, vlt, and mise use `$XDG_CONFIG_HOME` on every platform and then ignore their default file, so the old hardcoded paths were silently ineffective there. pip on macOS reads only one user file (`$XDG_DATA_HOME/pip`, then `~/Library/Application Support/pip` if either directory exists, else `~/.config/pip`). Also honored: `POETRY_CONFIG_DIR`, `PDM_CONFIG_FILE`, `NPM_CONFIG_USERCONFIG`, `BUNDLE_USER_CONFIG` / `BUNDLE_USER_HOME`, `CARGO_HOME`, `MISE_*`, `PIXI_HOME`, and `ZDOTDIR`.
- The pixi shell wrapper was removed: no pixi version accepts `--exclude-newer` on install/add/update/upgrade, so it broke those commands. Runs now delete it and write a root `exclude-newer` into the existing `pixi global` manifest on pixi 0.82.0+ (never creating the manifest, never overwriting a custom table).
- Poetry exclusions are written as TOML arrays; comma strings in `config.toml` are ignored by Poetry and are migrated.
- Deno `add` / `remove` only accept `--minimum-dependency-age` from 2.9.4; the wrapper checks the version at run time. `cache` is now wrapped too.
- npm `min-release-age-exclude` minimum lowered to 11.17.0 (backport). uv exceptions now require 0.9.25.
- vlt cron entries are replaced when the age or path changes and pin the resolved vlt path; a missing or failing `crontab` reports `FAIL` instead of aborting the run.
- macOS now schedules the daily vlt refresh with a launchd agent (`~/Library/LaunchAgents/com.set-minimum-package-release-age.vlt-refresh.plist`) instead of cron: writing a crontab on macOS requires Full Disk Access and failed with `Operation not permitted`. Legacy macOS vlt crontab lines are removed. Linux keeps cron. "Updated" rows now say "(exceptions changed)" instead of "X --> X" when only exceptions differ.
- A tool that fails its version check no longer stops the whole run: only that tool is left unchanged (`blocked`), the rest are configured, and the run exits 1 listing the blocked tools and reasons.
- Tool detection now runs once per invocation and probes all tools in parallel (it previously re-probed every tool on each lookup because the cache was filled in subshells; a real run went from ~33 s to ~0.7 s). The timeout helper uses a one-shot watchdog instead of 5 ms polling and closes stdin so prompts cannot hang.
- Removed the beads issue tracker (`.beads/` and its `.gitignore` entries). Its two open tickets were migrated to GitHub issues #2 (vlt scheduled refresh) and #3 (Deno wrapper).
- Redesigned the terminal output (`lib/set_package_min_age_ui.sh`). It has Tools, Changes, Summary, Changed files, and Needs attention sections; each tool gets one Changes row instead of start, result, validation, and results-table rows. The layout is width-aware and tested at 32-200 columns.
- Opened GitHub issues #4–#22, one per unsupported package manager, each with the reason it isn't supported and what would change that.
- Added exceptions for pixi (package exemptions), Hex (`cooldown_exclude_repos`), and Cargo (registry exemptions). pip, PDM, Deno, vlt, Yarn Classic, and Bundler have no user-level exclusion setting.
- Scripts now run from bash, zsh, `sh`, and dash, refuse to be sourced, and are tested on Ubuntu, macOS (bash 5 and 3.2), Fedora, Alpine, and Debian in CI.
Added: PDM 2.27.0+ (`[strategy] exclude-newer`), Cargo (`[registry] global-min-publish-age`, stable in Cargo 1.100 scheduled for 2026-11-12; older Cargo ignores the key and warns), and mise 2026.4.22+ (`[settings] minimum_release_age`, excludes from 2026.6.2). Still not added: Composer (cooldown only in 2.11.0-RC1), mamba/micromamba (`exclude_newer` in `~/.mambarc` since 2.10.0, released 2026-10-23), conda 26.9 (breaks the default libmamba solver), aube (gate exists, first version unconfirmed), NuGet (unreleased), RubyGems `gem` (4.1 prerelease; will read Bundler's cooldown). Go, Maven, Gradle, Homebrew, Dart pub, Julia Pkg, Swift PM, CocoaPods, CPAN, and Nix still lack a native client-side cooldown.

Recorded package changes: none recorded.

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
- Track bugs and follow-up work in GitHub issues (https://github.com/dehrenschwender/set-minimum-package-release-age/issues). The beads tracker was removed; do not reintroduce `.beads/`.
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
- Normal runs should continue to stream progress after readiness so users are not left waiting silently before final results: one Changes row per tool as soon as that tool is done, then Summary, Changed files, and Needs attention last.
- Output must fit the terminal: never pad multibyte text with printf (it pads bytes), keep new rows on the `ui_*` helpers, and keep `tests/ui_test.sh` passing at every width. `main` calls `ui_reset` so each run re-detects width, color, and symbols.
- A failed preflight blocks only that tool (`PREFLIGHT_FAILED_TOOLS`): `run_progress_step` skips it, validation reports it as `blocked` instead of judging its untouched file, every other tool is still configured, and `main` lists the blocked tools after the summary and returns 1. Preflight failure keys must match `ALL_TOOL_KEYS`.
- Tool version probes must remain bounded so one broken package manager cannot prevent readiness output.
- Functions that read detection results must fill the cache in the parent shell (`load_tool_detection_cache`) before any `$(...)` lookup; a cache filled inside a subshell is lost and re-probes every tool.
- Tests must never reach the real `crontab` or `launchctl`; `setup_test_env` installs fakes for both and new scheduler code must keep that guarantee.
- Tests run with a hermetic `PATH` (`TEST_BIN_DIR` plus `TEST_SYSTEM_BIN`, which links every system utility except the package managers and schedulers in `TEST_HIDDEN_SYSTEM_COMMANDS`). Add any newly supported tool's command names there, or a machine that ships it (for example `/usr/bin/pip` on GitHub's Ubuntu runner) breaks the tests.
- Shell code must stay compatible with macOS `/bin/bash` 3.2 (no `wait -n`, `mapfile`, `${var,,}`, or `declare -A`); cron and launchd run the wrapper with `/bin/bash`.
- Keep the code portable across GNU, BSD/macOS, and BusyBox userlands (CI covers Ubuntu, macOS, Fedora, Alpine, Debian):
  - find commands with `type -P`, never `which` (Fedora and containers lack it);
  - parse `diff -U0` output, never the classic `<`/`>` format (BusyBox diff is unified-only);
  - never pipe into `grep -q` or `head` under `pipefail` (an early exit can SIGPIPE the writer and flip the result or abort under `set -e`); capture output first or use `sed -n 1p`;
  - awk scripts must work with mawk and BusyBox awk.
- The platform scripts start with a guard that re-runs them with bash when started from zsh/sh and refuses to be sourced; keep it POSIX-parsable and before `set -euo pipefail`. The generated Deno wrapper must keep working in both bash and zsh (`tests/shell_test.sh`).
- Deno should remain documented as a shell-wrapper workaround. Deno 2.8+ also reads the npm setting from `.npmrc`, but a project `deno.json` outranks it, so the wrapper preserves an independently managed age on Deno 2.6+.
- Never reintroduce a pixi CLI-flag wrapper; pixi workspace commands do not accept `--exclude-newer`. Only edit an existing pixi global manifest, and only on pixi 0.82.0+.
- Config paths must follow the same environment overrides the tool honors (`XDG_CONFIG_HOME` and tool-specific variables); writing a file the tool ignores while validation reports `ok` is a silent failure.
- Cargo cooldown should remain documented as requiring Cargo `1.100+`; older Cargo warns rather than blocks because it ignores the key.
- Verify upstream claims against real binaries where possible (temporary `HOME`, and a `crontab` shim first on `PATH` so the real crontab is untouched); the test suite only uses fake binaries.
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
/bin/bash tests/run.sh   # macOS: also verify bash 3.2
```

Linux check from macOS (each distro's userland differs: mawk, gawk without `which`, BusyBox):

```bash
docker run --rm -v "$PWD:/repo:ro" alpine:latest sh -c 'apk add -q bash zsh && cp -R /repo /work && cd /work && bash tests/run.sh'
```

CI: `.github/workflows/test.yml` (Ubuntu, macOS with bash 5 and 3.2, Fedora, Alpine, Debian).

## Test Layout

- `tests/common_test.sh`
  - direct function coverage for the shared library
- `tests/linux_wrapper_test.sh`
  - Linux wrapper integration coverage
- `tests/macos_wrapper_test.sh`
  - macOS wrapper integration coverage
- `tests/ui_test.sh`
  - output layout at 32-200 columns (ASCII and Unicode): lines fit the width, no trailing whitespace, aligned columns, key information present, and color only when requested
- `tests/shell_test.sh`
  - running the scripts from bash/zsh/sh/dash, refusing to be sourced, and the Deno wrapper in bash and zsh
- `tests/test_helper.sh`
  - test harness helpers and fake binaries

The tests use a temporary `HOME`, fake manager binaries, and fake `crontab` and `launchctl` binaries, so they should not modify the real machine state. `run_test` runs tests in parallel (`TEST_JOBS`, default CPU count) and `finish_tests` prints buffered output in order, so tests must not share state outside their own `TEST_ROOT`.

## Known Issues / TODOs

- No known dependency issues.
- No major dependency version bumps pending review.
- GitHub #2: vlt (1.6.0) still only accepts an absolute `before` date, so it is the one tool that needs a scheduled refresh (launchd on macOS, cron on Linux). Never write a relative value: `@vltpkg/pick-manifest` parses it with `new Date(before)`, so `7d`/`P7D` becomes an invalid date and every version is rejected. Watch vltpkg/vltpkg#1503 (relative publish-date filter request, open) and drop the scheduler once a relative setting ships. The uv cron is already gone; only legacy-entry cleanup remains.
- GitHub #3: Deno has no user-level minimum dependency age setting, so the shell wrapper remains; replace it once Deno ships one.
- Yarn Berry 4.17+ upstream bug (yarnpkg/berry#7192): `npmScopes` entries without their own gate use the `1d` default, not the global `npmMinimalAgeGate`.
- Unsupported package managers each have a GitHub issue with the reason and the trigger for adding support (#4–#22): Composer #4, mamba/micromamba #5, conda #6, aube #7, NuGet #8, RubyGems `gem` #9, pipx #10, Go #11, Maven #12, Gradle #13, Homebrew #14, Dart pub #15, Julia Pkg #16, Swift PM #17, CocoaPods #18, CPAN #19, Nix #20, aqua #21, asdf #22. Keep the README "Not Yet Supported" table in sync when one is added or closed.
- Also revisit pixi workspace config if a user-level setting appears.
