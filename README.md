# Set Minimum Package Release Age

Bash scripts that configure a minimum package release age across Python and JavaScript package managers. The default is 7 days, configurable via CLI argument. This helps reduce supply-chain risk by preferring package versions that have been published long enough to be noticed and pulled if they are malicious.

The repo now uses a shared core library plus thin platform wrappers:

- `set_package_min_age_linux.sh`
- `set_package_min_age_macos.sh`
- `lib/set_package_min_age_common.sh`

## Supported Package Managers

| Ecosystem | Tool | Mode | Config |
|---|---|---|---|
| Python | `pip` | upload-time age gate via `uploaded-prior-to` | `~/.config/pip/pip.conf` |
| Python | `uv` | native age gate + per-package exceptions | `~/.config/uv/uv.toml` |
| JavaScript | `npm` | native age gate | `~/.npmrc` |
| JavaScript | `pnpm` | native age gate + selectors to exclude | pnpm 11+: `~/.config/pnpm/config.yaml` (Linux) / `~/Library/Preferences/pnpm/config.yaml` (macOS); pnpm 10: platform legacy `rc` |
| JavaScript | `bun` | native age gate + package excludes | `~/.bunfig.toml` |
| JavaScript | `deno` | native age gate + package excludes | `~/deno.json` |
| JavaScript | `yarn classic (v1)` | cache TTL workaround, not a true publish-age gate | `~/.yarnrc` |
| JavaScript | `yarn berry (v2+)` | native age gate + preapproved package patterns | `~/.yarnrc.yml` |
| JavaScript | `vlt` | native before-date gate | `~/.config/vlt/vlt.json` (Linux) / `~/Library/Preferences/vlt/vlt.json` (macOS) |

## Feature Matrix

| Tool | Native Age Gate | Native Exceptions | Workaround Only | Scoped Removal | Runtime Version Enforcement |
|---|---|---|---|---|---|
| `pip` | yes | no | no | yes | yes |
| `uv` | yes | yes | no | yes | no |
| `npm` | yes | no | no | yes | yes |
| `pnpm` | yes | yes | no | yes | yes |
| `bun` | yes | yes | no | yes | no documented minimum |
| `deno` | yes | yes | no | yes | no documented minimum |
| `yarn classic (v1)` | no | no | `cache-min` TTL workaround | yes | no |
| `yarn berry (v2+)` | yes | yes | no | yes | yes |
| `vlt` | yes | no | no | yes | no documented minimum |

## Version Notes

- `pip` upload-time gating requires pip `26.0+` and is written as `uploaded-prior-to` under `[install]`.
- `npm` age gating requires npm `11.10.0+`.
- `pnpm` `minimumReleaseAge` requires pnpm `10.16.0+`.
- `pnpm` exclusion patterns require pnpm `10.17.0+`.
- `pnpm` version-selector exclusions require pnpm `10.19.0+`.
- pnpm `11.0.0+` global settings are written to `config.yaml` using YAML keys; older pnpm releases keep using the legacy platform `rc` path.
- Yarn Berry `npmMinimalAgeGate` and `npmPreapprovedPackages` require Yarn `4.10.0+`.
- `uv` uses `exclude-newer` / `exclude-newer-package`; the current docs confirm support, but this repo does not pin an official minimum introducing version.
- `bun` uses `minimumReleaseAge` / `minimumReleaseAgeExcludes`; the current docs confirm support, but this repo does not pin an official minimum introducing version.
- `deno` uses `minimumDependencyAge`; the current docs confirm support, but this repo does not pin an official minimum introducing version.
- `vlt` uses `before`; the current implementation supports the config, but this repo does not pin an official minimum introducing version.
- Yarn Classic only supports `cache-min`, which is a cache freshness workaround rather than native publish-date filtering.

## Usage

### macOS

```bash
bash set_package_min_age_macos.sh
bash set_package_min_age_macos.sh 14
bash set_package_min_age_macos.sh 1d
bash set_package_min_age_macos.sh --exception "uv:setuptools=false"
bash set_package_min_age_macos.sh --exception "pnpm:webpack" --exception "bun:typescript"
bash set_package_min_age_macos.sh --exception "deno:npm:chalk" --exception "deno:jsr:@std/assert"
bash set_package_min_age_macos.sh --exception "yarn-berry:@myorg/*"
bash set_package_min_age_macos.sh --remove-tool uv --remove-tool uv-cron
bash set_package_min_age_macos.sh --remove
bash set_package_min_age_macos.sh --help
```

### Linux

```bash
bash set_package_min_age_linux.sh
bash set_package_min_age_linux.sh 14
bash set_package_min_age_linux.sh 1d
bash set_package_min_age_linux.sh --exception "uv:setuptools=false"
bash set_package_min_age_linux.sh --exception "pnpm:webpack" --exception "bun:typescript"
bash set_package_min_age_linux.sh --exception "deno:npm:chalk" --exception "deno:jsr:@std/assert"
bash set_package_min_age_linux.sh --exception "yarn-berry:@myorg/*"
bash set_package_min_age_linux.sh --remove-tool yarn-berry
bash set_package_min_age_linux.sh --remove
bash set_package_min_age_linux.sh --help
```

### Exception Flags

- `--exception uv:RULE`
  - format: `package=false` or `package=<duration-or-rfc3339>`
- `--exception pnpm:SELECTOR`
  - package name, glob, or supported version selector
- `--exception bun:PACKAGE`
  - package name to bypass the age gate
- `--exception deno:SPECIFIER`
  - package specifier to bypass the age gate; must start with `npm:` or `jsr:`
- `--exception yarn-berry:PATTERN`
  - pattern added to Yarn Berry `npmPreapprovedPackages`

Unsupported exception targets:

- `pip`
- `npm`
- `vlt`
- `yarn-classic`

Examples:

```bash
bash set_package_min_age_linux.sh 7 \
  --exception "uv:setuptools=false" \
  --exception "pnpm:@myorg/*" \
  --exception "bun:typescript" \
  --exception "deno:npm:chalk" \
  --exception "yarn-berry:@myorg/*"
```

### Scoped Removal

Use repeatable `--remove-tool` flags to remove settings for only selected managed tools:

- `pip`
- `uv`
- `uv-cron`
- `npm`
- `pnpm`
- `bun`
- `deno`
- `yarn-classic`
- `yarn-berry`
- `vlt`
- `vlt-cron`

Examples:

```bash
bash set_package_min_age_linux.sh --remove-tool pip
bash set_package_min_age_linux.sh --remove-tool uv --remove-tool uv-cron
bash set_package_min_age_linux.sh --remove-tool deno
bash set_package_min_age_linux.sh --remove-tool yarn-berry
bash set_package_min_age_linux.sh --remove-tool vlt --remove-tool vlt-cron
```

## What The Scripts Do

For each supported tool, the script:

1. Checks whether the target setting is already correct.
2. Backs up the existing config before modifying it.
3. Adds or updates the age-gate setting using the unit each tool expects.
4. Adds native exception settings where that package manager supports them.
5. Runs a preflight version check for installed tools whose native age-gate features have documented minimum versions.
6. Validates every supported tool by checking the config written for that tool.
7. Diffs the modified file against the backup and rolls back unexpected changes.
8. Prints tool readiness with detected binary paths, then a merged results table covering both config changes and validation status.

`pip` is written as an absolute `uploaded-prior-to` timestamp under `[install]`.

`uv` is still written with an absolute `exclude-newer` timestamp, so the scripts also manage a daily cron job that refreshes the date.

`deno` is written with a relative `minimumDependencyAge` value in minutes. Deno uses project config files, so the scripts manage `~/deno.json` as a home-level default for projects below `HOME`; set `DENO_CONFIG_PATH` if you want to manage a different project config.

`vlt` is written with an absolute `before` timestamp under `config`, so the scripts also manage a daily cron job that reruns the wrapper in a refresh mode for the VLT config only.

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

The test suite covers shared functions directly and also runs both platform wrappers end-to-end with fake package-manager and `crontab` binaries.

## License

See [LICENSE](LICENSE) for details.
