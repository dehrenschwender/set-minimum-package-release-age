# Set Minimum Package Release Age

Bash scripts that configure a minimum package release age across Python, JavaScript, and Ruby package managers. The default is 7 days, configurable via CLI argument. This helps reduce supply-chain risk by preferring package versions that have been published long enough to be noticed and pulled if they are malicious.

The repo now uses a shared core library plus thin platform wrappers:

- `set_package_min_age_linux.sh`
- `set_package_min_age_macos.sh`
- `lib/set_package_min_age_common.sh`

## Supported Package Managers

| Ecosystem | Tool | Mode | Config |
|---|---|---|---|
| Python | `pip` | upload-time age gate via relative `uploaded-prior-to` | `~/.config/pip/pip.conf` |
| Python | `uv` | native relative age gate + per-package exceptions | `~/.config/uv/uv.toml` |
| Python | `Poetry` | native age gate + package/source exceptions | `~/.config/pypoetry/config.toml` (Linux) / `~/Library/Application Support/pypoetry/config.toml` (macOS) |
| JavaScript | `npm` | native age gate + package/glob excludes | `~/.npmrc` |
| JavaScript | `pnpm` | native age gate + selectors to exclude | pnpm 11+: `~/.config/pnpm/config.yaml` (Linux) / `~/Library/Preferences/pnpm/config.yaml` (macOS); pnpm 10: platform legacy `rc` |
| JavaScript | `bun` | native age gate + package excludes | `~/.bunfig.toml` |
| JavaScript | `deno` | native age gate + package excludes | `~/deno.json` |
| JavaScript | `yarn classic (v1)` | cache TTL workaround, not a true publish-age gate | `~/.yarnrc` |
| JavaScript | `yarn berry (v2+)` | native age gate + preapproved package patterns | `~/.yarnrc.yml` |
| JavaScript | `vlt` | native before-date gate | `~/.config/vlt/vlt.json` (Linux) / `~/Library/Preferences/vlt/vlt.json` (macOS) |
| Ruby | `Bundler` | native cooldown | `~/.bundle/config` |

## Feature Matrix

| Tool | Native Age Gate | Native Exceptions | Workaround Only | Scoped Removal | Runtime Version Enforcement |
|---|---|---|---|---|---|
| `pip` | yes | no | no | yes | yes |
| `uv` | yes | yes | no | yes | yes |
| `Poetry` | yes | yes | no | yes | yes |
| `npm` | yes | yes | no | yes | yes |
| `pnpm` | yes | yes | no | yes | yes |
| `bun` | yes | yes | no | yes | yes |
| `deno` | yes | yes | no | yes | yes |
| `yarn classic (v1)` | no | no | `cache-min` TTL workaround | yes | no |
| `yarn berry (v2+)` | yes | yes | no | yes | yes |
| `vlt` | yes | no | no | yes | no documented minimum |
| `Bundler` | yes | no | no | yes | yes |

## Version Notes

- `pip` relative upload-time gating requires pip `26.1+` and is written as `uploaded-prior-to = P7D` under `[install]`.
- `uv` relative `exclude-newer` durations require uv `0.9.17+`.
- `Poetry` `solver.min-release-age`, package excludes, and source excludes require Poetry `2.4.0+`.
- `npm` `min-release-age` and `min-release-age-exclude[]` require npm `11.10.0+`.
- `pnpm` `minimumReleaseAge` requires pnpm `10.16.0+`.
- `pnpm` exclusion patterns require pnpm `10.17.0+`.
- `pnpm` version-selector exclusions require pnpm `10.19.0+`.
- pnpm `11.0.0+` global settings are written to `config.yaml` using YAML keys; older pnpm releases keep using the legacy platform `rc` path.
- Yarn Berry `npmMinimalAgeGate` and `npmPreapprovedPackages` require Yarn `4.12.0+` for the current documented age gate behavior.
- `bun` `minimumReleaseAge` / `minimumReleaseAgeExcludes` require Bun `1.3.0+`.
- `deno` `minimumDependencyAge` requires Deno `2.6.0+`.
- `vlt` uses `before`; the current implementation supports the config, but this repo does not pin an official minimum introducing version.
- `Bundler` `cooldown` requires Bundler `4.0.13+`.
- Yarn Classic only supports `cache-min`, which is a cache freshness workaround rather than native publish-date filtering.

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
bash set_package_min_age_macos.sh --exception "deno:npm:chalk" --exception "deno:jsr:@std/assert"
bash set_package_min_age_macos.sh --exception "yarn-berry:@myorg/*"
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
bash set_package_min_age_linux.sh --exception "deno:npm:chalk" --exception "deno:jsr:@std/assert"
bash set_package_min_age_linux.sh --exception "yarn-berry:@myorg/*"
bash set_package_min_age_linux.sh --remove-tool yarn-berry
bash set_package_min_age_linux.sh --remove-tool bundler
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
- `--exception deno:SPECIFIER`
  - package specifier to bypass the age gate; must start with `npm:` or `jsr:`
- `--exception yarn-berry:PATTERN`
  - pattern added to Yarn Berry `npmPreapprovedPackages`

Unsupported exception targets:

- `pip`
- `vlt`
- `yarn-classic`
- `bundler`

Examples:

```bash
bash set_package_min_age_linux.sh 7 \
  --exception "uv:setuptools=false" \
  --exception "poetry:internal-lib" \
  --exception "npm:@myorg/*" \
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
- `poetry`
- `npm`
- `pnpm`
- `bun`
- `deno`
- `yarn-classic`
- `yarn-berry`
- `vlt`
- `vlt-cron`
- `bundler`

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
5. Runs a preflight version check for installed tools whose native age-gate features have documented minimum versions.
6. Validates every supported tool by checking the config written for that tool.
7. Diffs the modified file against the backup and rolls back unexpected changes.
8. Prints tool readiness with detected binary paths, then a merged results table covering both config changes and validation status.

`pip` is written as a relative `uploaded-prior-to = P7D` value under `[install]`.

`uv` is written as a relative `exclude-newer = "P7D"` value. Older managed uv cron entries are removed as legacy cleanup because relative durations no longer need date refresh jobs.

`Poetry` is written under `[solver]` in Poetry's global `config.toml`.

`deno` is written with a relative `minimumDependencyAge` ISO duration, such as `P7D`. Deno uses project config files, so the scripts manage `~/deno.json` as a home-level default for projects below `HOME`; set `DENO_CONFIG_PATH` if you want to manage a different project config.

`vlt` is written with an absolute `before` timestamp under `config`, so the scripts also manage a daily cron job that reruns the wrapper in a refresh mode for the VLT config only.

`Bundler` is written as a global `BUNDLE_COOLDOWN` value in `~/.bundle/config`.

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

Preferred shortcuts:

```bash
just syntax-check
just test
just check
```

## License

See [LICENSE](LICENSE) for details.
