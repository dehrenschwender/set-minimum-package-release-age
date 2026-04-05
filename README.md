# Set Minimum Package Release Age

Bash scripts that configure a minimum package release age across Python and JavaScript package managers. The default is 7 days, configurable via CLI argument. This helps reduce supply-chain risk by preferring package versions that have been published long enough to be noticed and pulled if they are malicious.

The repo now uses a shared core library plus thin platform wrappers:

- `set_package_min_age_linux.sh`
- `set_package_min_age_macos.sh`
- `lib/set_package_min_age_common.sh`

## Supported Package Managers

| Ecosystem | Tool | Mode | Config |
|---|---|---|---|
| Python | `pip` | native age gate | `~/.config/pip/pip.conf` |
| Python | `uv` | native age gate + per-package exceptions | `~/.config/uv/uv.toml` |
| JavaScript | `npm` | native age gate | `~/.npmrc` |
| JavaScript | `pnpm` | native age gate + selectors to exclude | `~/.config/pnpm/rc` (Linux) / `~/Library/Preferences/pnpm/rc` (macOS) |
| JavaScript | `bun` | native age gate + package excludes | `~/.bunfig.toml` |
| JavaScript | `yarn classic (v1)` | cache TTL workaround, not a true publish-age gate | `~/.yarnrc` |
| JavaScript | `yarn berry (v2+)` | native age gate + preapproved package patterns | `~/.yarnrc.yml` |

## Version Notes

- `npm` age gating requires npm `11.10.0+`.
- `pnpm` `minimumReleaseAge` requires pnpm `10.16.0+`.
- `pnpm` exclusion patterns require pnpm `10.17.0+`.
- `pnpm` version-selector exclusions require pnpm `10.19.0+`.
- Yarn Berry support uses `npmMinimalAgeGate` and `npmPreapprovedPackages` from current Yarn docs.
- Yarn Classic only supports `cache-min`, which is a cache freshness workaround rather than native publish-date filtering.

## Usage

### macOS

```bash
bash set_package_min_age_macos.sh
bash set_package_min_age_macos.sh 14
bash set_package_min_age_macos.sh 1d
bash set_package_min_age_macos.sh --uv-exception "setuptools=false"
bash set_package_min_age_macos.sh --pnpm-exception webpack --bun-exception typescript
bash set_package_min_age_macos.sh --yarn-exception "@myorg/*"
bash set_package_min_age_macos.sh --remove
bash set_package_min_age_macos.sh --help
```

### Linux

```bash
bash set_package_min_age_linux.sh
bash set_package_min_age_linux.sh 14
bash set_package_min_age_linux.sh 1d
bash set_package_min_age_linux.sh --uv-exception "setuptools=false"
bash set_package_min_age_linux.sh --pnpm-exception webpack --bun-exception typescript
bash set_package_min_age_linux.sh --yarn-exception "@myorg/*"
bash set_package_min_age_linux.sh --remove
bash set_package_min_age_linux.sh --help
```

### Exception Flags

- `--uv-exception RULE`
  - format: `package=false` or `package=<duration-or-rfc3339>`
- `--pnpm-exception SELECTOR`
  - package name, glob, or supported version selector
- `--bun-exception PACKAGE`
  - package name to bypass the age gate
- `--yarn-exception PATTERN`
  - pattern added to Yarn Berry `npmPreapprovedPackages`

Examples:

```bash
bash set_package_min_age_linux.sh 7 \
  --uv-exception "setuptools=false" \
  --pnpm-exception "@myorg/*" \
  --bun-exception typescript \
  --yarn-exception "@myorg/*"
```

## What The Scripts Do

For each supported tool, the script:

1. Checks whether the target setting is already correct.
2. Backs up the existing config before modifying it.
3. Adds or updates the age-gate setting using the unit each tool expects.
4. Adds native exception settings where that package manager supports them.
5. Validates every supported tool by checking the config written for that tool.
6. Diffs the modified file against the backup and rolls back unexpected changes.
7. Prints a summary of updated, skipped, failed, and validated tools.

`uv` is still written with an absolute `exclude-newer` timestamp, so the scripts also manage a daily cron job that refreshes the date.

## Idempotence

Both scripts are safe to run repeatedly:

- If a setting is already correct, it is skipped.
- If a setting exists with a different value, it is updated.
- If a setting is missing, it is added.
- `--remove` is also idempotent and removes managed age-gate settings on repeated runs.

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
