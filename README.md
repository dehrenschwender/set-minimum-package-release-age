# Set Minimum Package Release Age

Bash scripts that configure a minimum package release age across Python, JavaScript, Ruby, Elixir/Erlang, and Rust package managers, plus the mise tool manager. The default is 7 days, configurable via CLI argument. This helps reduce supply-chain risk by preferring package versions that have been published long enough to be noticed and pulled if they are malicious.

The repo uses a shared core library plus thin platform wrappers:

- `set_package_min_age_linux.sh`
- `set_package_min_age_macos.sh`
- `lib/set_package_min_age_common.sh`
- `lib/set_package_min_age_ui.sh` (terminal output)

## Supported Environments

- **OS:** macOS and Linux (tested on Debian, Ubuntu, Fedora, and Alpine/BusyBox).
- **Shell:** the scripts are bash programs and run with bash 3.2+ (macOS `/bin/bash` included). You can start them from any shell: `bash script.sh`, `./script.sh`, `zsh script.sh`, and `sh script.sh` all work, because the script re-runs itself with bash when needed. Do not `source` them; they refuse, so `set -euo pipefail` cannot leak into your interactive shell.
- **Deno wrapper:** the generated shell function works in both bash and zsh and is sourced from `~/.bashrc` and `~/.zshrc` (or `$ZDOTDIR/.zshrc`).
- **Tools:** only standard POSIX utilities (`awk`, `sed`, `grep`, `diff`, `mktemp`, `date`); GNU, BSD/macOS, and BusyBox variants all work. `which` is not required.

## Supported Package Managers

| Ecosystem | Tool | Mode | Default config |
|---|---|---|---|
| Python | `pip` | upload-time age gate via relative `uploaded-prior-to` | Linux: `$XDG_CONFIG_HOME/pip/pip.conf`; macOS: see [Config Locations](#config-locations) |
| Python | `uv` | native relative age gate + per-package exceptions | `$XDG_CONFIG_HOME/uv/uv.toml` (default `~/.config/uv/uv.toml`) |
| Python | `Poetry` | native age gate + package/source exceptions | `~/.config/pypoetry/config.toml` (Linux) / `~/Library/Application Support/pypoetry/config.toml` (macOS) |
| Python | `PDM` | native relative `exclude-newer` | `~/.config/pdm/config.toml` (Linux) / `~/Library/Application Support/pdm/config.toml` (macOS) |
| Python | `pixi` | native `exclude-newer` + package exemptions, in the `pixi global` manifest only | the existing `pixi-global.toml` (`~/.pixi/manifests/` by default) |
| JavaScript | `npm` | native age gate + package/glob excludes | `~/.npmrc` |
| JavaScript | `pnpm` | native age gate + selectors to exclude | pnpm 11+: `config.yaml`; pnpm 10: legacy `rc` (`$XDG_CONFIG_HOME/pnpm/`, else `~/.config/pnpm/` on Linux and `~/Library/Preferences/pnpm/` on macOS) |
| JavaScript | `bun` | native age gate + package excludes | `$XDG_CONFIG_HOME/.bunfig.toml` when set, else `~/.bunfig.toml` |
| JavaScript | `yarn classic (v1)` | cache TTL workaround, not a true publish-age gate | `~/.yarnrc` |
| JavaScript | `yarn berry (v2+)` | native age gate + preapproved package patterns | `~/.yarnrc.yml` |
| JavaScript / Multi | `deno` | shell wrapper injecting `--minimum-dependency-age` (no user-level config exists) | `~/.config/set-package-min-age/deno.sh` (sourced from `~/.zshrc` and `~/.bashrc`) |
| JavaScript | `vlt` | native before-date gate, refreshed daily (launchd on macOS, cron on Linux) | `$XDG_CONFIG_HOME/vlt/vlt.json`, else `~/.config/vlt/vlt.json` (Linux) / `~/Library/Preferences/vlt/vlt.json` (macOS) |
| Ruby | `Bundler` | native cooldown | `~/.bundle/config` |
| Elixir / Erlang | `Hex` | native cooldown + repository exclusions | `~/.hex/hex.config` (or the `HEX_HOME` / `MIX_XDG` location) |
| Rust | `Cargo` | native `registry.global-min-publish-age` + registry exemptions | `$CARGO_HOME/config.toml` (default `~/.cargo/config.toml`) |
| Tool manager | `mise` | native `minimum_release_age` + tool/backend excludes | `~/.config/mise/config.toml` |

## Feature Matrix

| Tool | Native Age Gate | Native Exceptions | Workaround Only | Scoped Removal | Runtime Version Enforcement |
|---|---|---|---|---|---|
| `pip` | yes | no | no | yes | yes |
| `uv` | yes | yes | no | yes | yes |
| `Poetry` | yes | yes | no | yes | yes |
| `PDM` | yes | no (project config only) | no | yes | yes |
| `pixi` | yes (`pixi global` manifest) | yes (package exemptions) | no | yes | skipped below 0.82.0 |
| `npm` | yes | yes | no | yes | yes |
| `pnpm` | yes | yes | no | yes | yes |
| `bun` | yes | yes | no | yes | yes |
| `yarn classic (v1)` | no | no | `cache-min` TTL workaround | yes | no |
| `yarn berry (v2+)` | yes | yes | no | yes | yes |
| `deno` | yes (CLI flag) | no (project config only) | shell wrapper around `--minimum-dependency-age` | yes | yes (>= 2.6.0) |
| `vlt` | yes | no | no | yes | no documented minimum |
| `Bundler` | yes | no | no | yes | warning |
| `Hex` | yes | yes (repository exclusions) | no | yes | yes |
| `Cargo` | yes | yes (registry exemptions) | no | yes | warning |
| `mise` | yes | yes | no | yes | yes |

## Version Notes

- `pip` relative upload-time gating requires pip `26.1+` and is written as `uploaded-prior-to = P7D` under `[install]`. pip has no per-package exceptions.
- `uv` relative `exclude-newer` durations require uv `0.9.17+`; `exclude-newer-package` overrides (including `false`) require uv `0.9.25+`. The user-level `uv.toml` also applies to `uv tool install` and `uvx`, but a project `uv.toml` / `pyproject.toml` can override it.
- `Poetry` `solver.min-release-age`, `min-release-age-exclude`, and `min-release-age-exclude-source` require Poetry `2.4.0+`. The exclusions are written as TOML arrays; older releases of this script wrote comma-separated strings, which Poetry silently ignores in `config.toml`, and are migrated on the next run.
- `PDM` `strategy.exclude-newer` in global config requires PDM `2.27.0+`. It is written as `"7d"`, which PDM re-evaluates on every lock. Per-package overrides exist only in `pyproject.toml` or on the CLI.
- `pixi` has no user-level setting for workspaces; projects must set `exclude-newer` in `pixi.toml` themselves. The `pixi global` manifest accepts a root `exclude-newer = "7d"` from pixi `0.82.0+`. The script only edits a manifest that already exists, because pixi builds a missing one from your existing global installs, and it leaves a custom `exclude-newer = { cutoff = ..., exemptions = ... }` table alone. Older pixi rejects the key, so it is skipped there.
- Older releases of this script installed a pixi shell wrapper that added `--exclude-newer` to `pixi install/add/update/upgrade`. pixi never accepted that flag there, so the wrapper made those commands fail. Every run now removes it.
- `npm` `min-release-age` requires npm `11.10.0+`; `min-release-age-exclude[]` requires npm `11.17.0+` (also in npm 12). A `before=` line in the same `.npmrc` takes precedence over `min-release-age`; the script warns when it finds one.
- `pnpm` `minimumReleaseAge` requires pnpm `10.16.0+`; exclusion patterns require `10.17.0+`; version-selector exclusions require `10.19.0+`.
- pnpm `11.0.0+` (including pnpm 12) reads global settings from `config.yaml` using camelCase keys and only uses the legacy `rc` for registry/auth, so the script writes `config.yaml` there and the legacy `rc` for pnpm 10. Since pnpm 11, an explicitly set `minimumReleaseAge` also turns on `minimumReleaseAgeStrict`, so installs fail instead of falling back when no version in a range is old enough.
- Yarn Berry `npmMinimalAgeGate` and `npmPreapprovedPackages` were introduced in Yarn `4.10.0`, so the script gates on `4.10.0+`. Yarn `4.15.0+` defaults the gate to `1d`, and `4.17.0+` supports per-`npmScopes` gates. Known upstream bug (yarnpkg/berry#7192): a configured `npmScopes` entry without its own gate uses the `1d` default instead of the global `7d`. Yarn 6 (prerelease) keeps the same keys.
- `bun` `minimumReleaseAge` / `minimumReleaseAgeExcludes` require Bun `1.3.0+`.
- `vlt` only has an absolute `before` date (no relative setting as of vlt 1.6.0), so a daily scheduled job refreshes it (launchd on macOS, cron on Linux). Replacing it with a native setting is tracked in [#2](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/2).
- `Bundler` `cooldown` requires Bundler `4.0.13+`; older or unknown installed Bundler versions warn but do not stop the script. A global `BUNDLE_COOLDOWN` overrides per-source `cooldown:` values in a Gemfile. Once RubyGems 4.1 ships, `gem install` also reads this setting.
- Yarn Classic only supports `cache-min`, which is a cache freshness workaround rather than native publish-date filtering.
- Deno `--minimum-dependency-age` requires Deno `2.6.0+` for `install`, `update`, `outdated`, and `cache`. `deno add` / `deno remove` only accept it from Deno `2.9.4`; the wrapper checks the installed version at run time and passes those commands through unchanged on older Deno. Deno `2.8+` also reads `min-release-age` from `.npmrc` and `2.9+` defaults to 24 hours, but a project `deno.json` outranks both, so the wrapper stays.
- Hex `cooldown` requires Hex `2.5.0+`. It applies during fresh dependency resolution, not when installing an unchanged lockfile. Repository-wide exclusions (`cooldown_exclude_repos`) are written with `--exception hex:REPOSITORY`.
- Cargo `registry.global-min-publish-age` is stable from Cargo/Rust `1.100` (scheduled for 2026-11-12). Older Cargo ignores the key, so older versions warn and the config is still written for the upgrade. Locked versions are kept and `cargo install` is not affected.
- mise `minimum_release_age` requires mise `2026.4.22+`; `minimum_release_age_excludes` requires `2026.6.2+`. Exact pins and `mise.lock` entries bypass it.

## Config Locations

Each config path follows the same overrides the tool itself honors. Most tools switch to `$XDG_CONFIG_HOME` when it is set and then ignore their default file, so writing the default would silently do nothing.

- `XDG_CONFIG_HOME`: `uv`, `bun`, `pnpm`, `vlt`, `mise` (all platforms); `pip`, `Poetry`, `PDM` (Linux only).
- pip on macOS reads one user file: `$XDG_DATA_HOME/pip/pip.conf` if that directory exists (pip 26.2+), else `~/Library/Application Support/pip/pip.conf` if that directory exists, else `~/.config/pip/pip.conf`.
- Tool-specific overrides: `POETRY_CONFIG_DIR`, `PDM_CONFIG_FILE`, `NPM_CONFIG_USERCONFIG`, `BUNDLE_USER_CONFIG` / `BUNDLE_USER_HOME`, `HEX_HOME` / `MIX_XDG`, `CARGO_HOME` (and a legacy extension-less `config` file if it is the only one), `MISE_GLOBAL_CONFIG_FILE` / `MISE_CONFIG_DIR`, `PIXI_HOME`.
- The Deno wrapper source line goes into `$ZDOTDIR/.zshrc` when `ZDOTDIR` is set.

Run the script from the same environment you use for your package managers so it sees the same variables.

## Usage

### macOS

```bash
bash set_package_min_age_macos.sh
bash set_package_min_age_macos.sh 14
bash set_package_min_age_macos.sh 1d
bash set_package_min_age_macos.sh --exception "uv:setuptools=false"
bash set_package_min_age_macos.sh --exception "poetry:internal-lib" --exception "poetry-source:private-repo"
bash set_package_min_age_macos.sh --exception "npm:@myorg/*"
bash set_package_min_age_macos.sh --exception "pnpm:webpack" --exception "bun:typescript"
bash set_package_min_age_macos.sh --exception "yarn-berry:@myorg/*"
bash set_package_min_age_macos.sh --exception "mise:npm:*"
bash set_package_min_age_macos.sh --remove-tool uv --remove-tool uv-cron
bash set_package_min_age_macos.sh --remove-tool poetry --remove-tool bundler
bash set_package_min_age_macos.sh --remove
bash set_package_min_age_macos.sh --help
```

### Linux

```bash
bash set_package_min_age_linux.sh
bash set_package_min_age_linux.sh 14
bash set_package_min_age_linux.sh 1d
bash set_package_min_age_linux.sh --exception "uv:setuptools=false"
bash set_package_min_age_linux.sh --exception "poetry:internal-lib" --exception "poetry-source:private-repo"
bash set_package_min_age_linux.sh --exception "npm:@myorg/*"
bash set_package_min_age_linux.sh --exception "pnpm:webpack" --exception "bun:typescript"
bash set_package_min_age_linux.sh --exception "yarn-berry:@myorg/*"
bash set_package_min_age_linux.sh --exception "mise:trivy"
bash set_package_min_age_linux.sh --remove-tool yarn-berry
bash set_package_min_age_linux.sh --remove-tool cargo --remove-tool mise
bash set_package_min_age_linux.sh --remove
bash set_package_min_age_linux.sh --help
```

### Exception Flags

- `--exception uv:RULE`
  - format: `package=false` or `package=<duration-or-rfc3339>`
- `--exception poetry:PACKAGE`
  - package name to bypass Poetry `solver.min-release-age`
- `--exception poetry-source:SOURCE`
  - source name or URL to bypass Poetry `solver.min-release-age`
- `--exception npm:PACKAGE_OR_GLOB`
  - package name or minimatch glob added to npm `min-release-age-exclude[]`
- `--exception pnpm:SELECTOR`
  - package name, glob, or supported version selector
- `--exception bun:PACKAGE`
  - package name to bypass the age gate
- `--exception yarn-berry:PATTERN`
  - pattern added to Yarn Berry `npmPreapprovedPackages`
- `--exception mise:TOOL_OR_BACKEND`
  - registry name (`trivy`), backend wildcard (`npm:*`), or full backend ID added to mise `minimum_release_age_excludes`
- `--exception pixi:PACKAGE[VERSION_SPEC]`
  - `pixi:polars` exempts every version, `pixi:polars==1.43.1` only matching versions; written as `exemptions` in the pixi global manifest (`exclude-newer = { cutoff = "7d", exemptions = { "polars" = "*" } }`). A hand-written `exclude-newer` table is still left alone.
- `--exception hex:REPOSITORY`
  - repository name such as `hexpm:myorg`, written to Hex `cooldown_exclude_repos`. Hex has no per-package exclusions. The list is only managed when you pass `hex` exceptions; otherwise an existing list is preserved, and a list Hex wrapped across several lines is never rewritten.
- `--exception cargo:REGISTRY`
  - registry name such as `my-registry` or `crates-io`; writes `min-publish-age = "0"` under `[registries.<name>]` (tagged with a `# set-minimum-package-release-age exception` comment so only those lines are managed). Cargo has no per-package exemptions. Registries defined inline (`my-reg = { index = ... }`) are refused rather than turned into a duplicate key.

Unsupported exception targets (no user-level exclusion setting upstream):

- `pip`
- `pdm` (only `pyproject.toml` / CLI overrides)
- `deno` (only `deno.json`; no CLI flag)
- `vlt`
- `yarn-classic`
- `bundler` (only per-source `cooldown:` in a Gemfile, which the global setting overrides)

Examples:

```bash
bash set_package_min_age_linux.sh 7 \
  --exception "uv:setuptools=false" \
  --exception "poetry:internal-lib" \
  --exception "npm:@myorg/*" \
  --exception "pnpm:@myorg/*" \
  --exception "bun:typescript" \
  --exception "yarn-berry:@myorg/*" \
  --exception "mise:npm:*" \
  --exception "pixi:polars" \
  --exception "hex:hexpm:myorg" \
  --exception "cargo:my-registry"
```

### Scoped Removal

Use repeatable `--remove-tool` flags to remove settings for only selected managed tools:

- `pip`
- `uv`
- `uv-cron`
- `poetry`
- `pdm`
- `npm`
- `pnpm`
- `bun`
- `deno`
- `pixi`
- `yarn-classic`
- `yarn-berry`
- `vlt`
- `vlt-cron`
- `bundler`
- `hex`
- `cargo`
- `mise`

Examples:

```bash
bash set_package_min_age_linux.sh --remove-tool pip
bash set_package_min_age_linux.sh --remove-tool uv --remove-tool uv-cron
bash set_package_min_age_linux.sh --remove-tool poetry
bash set_package_min_age_linux.sh --remove-tool deno
bash set_package_min_age_linux.sh --remove-tool yarn-berry
bash set_package_min_age_linux.sh --remove-tool vlt --remove-tool vlt-cron
bash set_package_min_age_linux.sh --remove-tool bundler
```

## What The Scripts Do

For each supported tool, the script:

1. Checks whether the target setting is already correct.
2. Backs up the existing config before modifying it.
3. Adds or updates the age-gate setting using the unit each tool expects.
4. Adds native exception settings where that package manager supports them.
5. Runs a preflight version check for installed tools whose native age-gate features have documented minimum versions. Version probes run once per invocation, all in parallel, with stdin closed and a 5-second limit each, so a slow or broken manager (for example a Corepack download prompt) cannot block the readiness table. An installed version that is too old (or can't be detected) **blocks only that tool**: its config is left untouched and its rows show `blocked` with the reason, while every other tool is still configured and validated. The run then lists the blocked tools after the summary and exits with status 1, so upgrade the tool (or drop its `--exception`) and rerun. Bundler and Cargo only warn, because the config they ignore is still written for the upgrade, and pixi is skipped.
6. Validates every supported tool by checking the config written for that tool.
7. Diffs the modified file against the backup and rolls back unexpected changes.
8. Prints the detected tools, streams one line per tool as each change is applied, verifies the written files, and ends with a summary, the changed files, and anything that needs attention (see [Output](#output)).

`pip` is written as a relative `uploaded-prior-to = P7D` value under `[install]`.

`uv` is written as a relative `exclude-newer = "P7D"` value. Older managed uv cron entries are removed as legacy cleanup because relative durations no longer need date refresh jobs.

`Poetry` is written under `[solver]` in Poetry's global `config.toml`.

`PDM` is written as `exclude-newer = "7d"` under `[strategy]`.

`Cargo` is written as `global-min-publish-age = "7 days"` under `[registry]`; `--exception cargo:NAME` adds `min-publish-age = "0"` under `[registries.NAME]`.

`mise` is written as `minimum_release_age = "7d"` under `[settings]`.

`vlt` is written with an absolute `before` timestamp under `config`, so the scripts also schedule a daily job that reruns the wrapper in a refresh mode for the vlt config only. The job pins the resolved vlt config path (scheduled jobs do not see your shell's `XDG_CONFIG_HOME`) and is replaced when you rerun with a different age. The job runs the script from wherever you ran it, so run it from a checkout you keep.

- macOS: a launchd agent at `~/Library/LaunchAgents/com.set-minimum-package-release-age.vlt-refresh.plist`, run daily at midnight and at login (launchd also catches up on runs missed during sleep). Writing a crontab on macOS needs Full Disk Access (`crontab: ... Operation not permitted`), so cron is not used there; a vlt crontab line from older releases is removed. Without a GUI session (for example over SSH) the agent is written and loads at the next login.
- Linux: a crontab entry. If `crontab` is unavailable or the write fails, the step reports `FAIL` and the rest of the run continues.

The `vlt-cron` key in `--remove-tool` removes whichever scheduler the platform uses.

`Bundler` is written as a global `BUNDLE_COOLDOWN` value in `~/.bundle/config`.

`Hex` is written as a global `cooldown` term in Hex's `hex.config`, respecting `HEX_HOME` and `MIX_XDG` config locations; `--exception hex:REPOSITORY` also writes `cooldown_exclude_repos`.

`deno` is managed as a shell wrapper under `~/.config/set-package-min-age/`, sourced by both `~/.zshrc` and `~/.bashrc`. The wrapper shadows the `deno` command and injects `--minimum-dependency-age` for `install`, `update`, `outdated`, and `cache` (and `add` / `remove` on Deno 2.9.4+). Other subcommands, including `deno run`, fall through to the real binary unchanged.

### Shell Wrapper Caveats (deno)

- The wrapper only applies to interactive shells that source `~/.zshrc` or `~/.bashrc`. Non-interactive scripts and other shells (fish, nushell) are not covered.
- The wrapper can be bypassed deliberately with `command deno ...`.
- Per-package exceptions are not exposed by the wrapper flag; configure supported exceptions in the project's `deno.json` if needed.
- A new shell session is required after running the script for the wrapper to take effect (or `source ~/.zshrc` / `source ~/.bashrc` in an existing one).
- Replacing the wrapper with a native user-level setting, once Deno has one, is tracked in [#3](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/3).

## Output

A run prints these sections:

- **Tools:** installed tools with version and path. Version problems are explained underneath, and tools that aren't installed are listed on one line.
- **Changes:** one line per tool, printed as soon as that tool is done.
- **Summary:** counts and how many config files were verified.
- **Changed files:** only files this run actually touched.
- **Needs attention:** blocked tools, rollbacks, mismatches, and warnings. It comes last, so the things to act on are what you see at the end.

```text
set-minimum-package-release-age · macOS · minimum age 7 days

Tools
  ✓ pip          26.2.2     /opt/homebrew/bin/pip3
  ✗ npm          11.14.1    ~/.nvm/versions/node/v22.16.0/bin/npm
                            min-release-age-exclude requires >= 11.17.0; blocked, other
                            tools continue
  ! Bundler      1.17.2     /usr/bin/bundle
                            cooldown requires >= 4.0.13; config can still be written
  – Not installed: Poetry, PDM, Hex, mise. Their settings are still written for when you
    install them.

Changes
  ✓ pip          added     uploaded-prior-to = P7D (7d window)
  ✓ uv           updated   "2026-10-17T00:00:00Z" → exclude-newer = "P7D"
  ✗ npm          blocked   min-release-age-exclude requires >= 11.17.0 (installed: 11.14.1)
  – pixi         skipped   no pixi global manifest yet; run a pixi global command, then rerun
  ...

Summary
  14 added · 1 updated · 1 skipped · 1 blocked · 0 failed · 14/14 verified

Changed files
  pip          ~/.config/pip/pip.conf
  ...

Needs attention
  ✗ npm          blocked   min-release-age-exclude requires >= 11.17.0 (installed: 11.14.1)
                           Left unchanged. Upgrade it (or drop its --exception) and rerun.
  ! Bundler      warning   cooldown requires >= 4.0.13; config can still be written

  Exit status 1 because 1 tool is blocked.
```

The layout follows the terminal width (32 to 120 columns; wider terminals are capped at 120 for readability). Long text wraps with a hanging indent, long paths are shortened in the middle, and narrow terminals switch to a stacked layout. Color is used only when output goes to a terminal.

| Setting | Effect |
|---|---|
| `COLUMNS=80` | Use this width instead of the detected one. |
| `NO_COLOR=1` | Never use color. |
| `FORCE_COLOR=1` | Use color even when output is piped. |
| `SET_PACKAGE_MIN_AGE_GLYPHS=ascii` | Use ASCII symbols (`*` `=` `-` `!` `x`). ASCII is the default when the locale isn't UTF-8. |

## Exit Status

- `0`: every tool was configured (or already correct), skipped because it isn't applicable, or only warned.
- `1`: at least one tool was blocked by its version check (it is listed after the summary with the reason), or the arguments were invalid.

Rollbacks and validation errors are reported in the summary but do not change the exit status.

## Idempotence

Both scripts are safe to run repeatedly:

- If a setting is already correct, it is skipped.
- If a setting exists with a different value, it is updated.
- If a setting is missing, it is added.
- `--remove` is also idempotent and removes managed age-gate settings on repeated runs.
- `--remove-tool` is also idempotent and only removes the selected managed settings.

## Testing

Syntax checks:

```bash
bash -n lib/set_package_min_age_common.sh
bash -n set_package_min_age_linux.sh
bash -n set_package_min_age_macos.sh
```

Run the full pure-Bash test suite:

```bash
bash tests/run.sh
```

On macOS, also run it with the built-in bash 3.2, which cron and launchd use:

```bash
/bin/bash tests/run.sh
```

The test suite covers shared functions directly, runs both platform wrappers end-to-end with fake package-manager binaries, checks the output layout at widths from 32 to 200 columns in ASCII and Unicode (`tests/ui_test.sh`), and checks shell compatibility (`tests/shell_test.sh`: running from bash/zsh/sh/dash, refusing to be sourced, and the Deno wrapper in bash and zsh; shells that are not installed are skipped). It clears config-location variables such as `XDG_CONFIG_HOME` so your own environment does not leak into the tests, and every test gets fake `crontab` and `launchctl` binaries so the real schedulers are never touched. Tests run in parallel (one job per CPU by default) and print in declaration order; set `TEST_JOBS=1` to run them serially.

CI (`.github/workflows/test.yml`) runs the suite on Ubuntu and macOS (bash 5 and `/bin/bash` 3.2), and in Fedora, Alpine, and Debian containers.

Preferred shortcuts:

```bash
just syntax-check
just test
just check
```

## Not Yet Supported

These package managers have no usable user-level release-age setting yet (as of 2026-10-24). Each has an issue with the details and what would trigger adding support:

| Tool | Why not yet | Issue |
|---|---|---|
| Composer | cooldown only in 2.11.0-RC1; stable 2.10 has none | [#4](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/4) |
| mamba / micromamba | works in 2.10.0, but no installable 2.10 build exists yet; older versions silently ignore it | [#5](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/5) |
| conda | `exclude_newer` breaks every install with the default libmamba solver | [#6](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/6) |
| aube | user config works from 1.9.0, but 2.8.2 ignores the gate on a cold cache | [#7](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/7) |
| NuGet / dotnet | package update cooldown not released yet | [#8](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/8) |
| RubyGems `gem` | 4.1 (beta) reads the `BUNDLE_COOLDOWN` we already write; waiting for 4.1.0 | [#9](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/9) |
| Go modules | proposal on hold | [#11](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/11) |
| Maven | declined upstream | [#12](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/12) |
| Gradle | open upstream request | [#13](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/13) |
| Homebrew | declined upstream; cooldown is maintainer-side | [#14](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/14) |
| Dart / Flutter pub | proposal only, project-level | [#15](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/15) |
| Julia Pkg | open upstream request | [#16](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/16) |
| Swift Package Manager | no feature found | [#17](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/17) |
| CocoaPods | no feature found | [#18](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/18) |
| CPAN (cpanm / cpm) | no feature found | [#19](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/19) |
| Nix | no feature found | [#20](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/20) |
| aqua | publish dates now recorded (groundwork), no cooldown setting yet | [#21](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/21) |
| asdf | no feature found (mise is supported) | [#22](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/22) |

Tools that delegate to a supported manager are already covered through it: pipx, pip-tools and Hatch (pip / uv), and Corepack, Volta, ni, nypm, and the JSR CLI (the npm-compatible manager they run). pipx was verified with both backends ([#10](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/10)). An explicit `PIPX_COOLDOWN` / `--cooldown` overrides the pip setting, and a very long pip cooldown can block pipx's own `pip>=26.1` bootstrap.

## Issues and Follow-ups

Bugs, feature requests, and follow-up work are tracked in [GitHub issues](https://github.com/dehrenschwender/set-minimum-package-release-age/issues), for example replacing the vlt scheduled refresh ([#2](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/2)) and the Deno wrapper ([#3](https://github.com/dehrenschwender/set-minimum-package-release-age/issues/3)) once those tools gain native user-level settings.

## License

See [LICENSE](LICENSE) for details.
