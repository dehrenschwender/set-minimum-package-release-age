# Set Minimum Package Release Age

Bash scripts that configure a minimum package release age of 7 days across Python and JavaScript package managers. This helps protect against supply chain attacks by ensuring you only install packages that have been published for at least a week.

Separate scripts are provided for macOS and Linux to handle platform-specific config paths and `sed` syntax differences.

## Supported Package Managers

### Python
- **pip** — sets `min-age` in `~/.config/pip/pip.conf`
- **uv** — sets `exclude-newer` in `~/.config/uv/uv.toml` (uses an absolute date; re-run periodically to keep current)

### JavaScript
- **npm** — sets `min-release-age` in `~/.npmrc`
- **pnpm** — sets `minimum-release-age` in the platform-specific pnpm rc file
- **bun** — sets `minimumReleaseAge` in `~/.bunfig.toml`
- **yarn classic (v1)** — sets `cache-min` in `~/.yarnrc`
- **yarn berry (v2+)** — adds an advisory comment to `~/.yarnrc.yml` (no built-in setting available)

## Usage

### macOS

```bash
bash set_package_min_age_macos.sh
```

### Linux

```bash
bash set_package_min_age_linux.sh
```

Both scripts are idempotent and safe to run multiple times:

- If a setting is **already correctly configured**, it is skipped entirely (no file modification)
- If a setting exists with a **different value**, the current value is shown and updated
- If a setting is **missing**, it is added

## What It Does

For each supported package manager, the script:

1. Checks if the setting is already correctly configured — skips if so
2. Backs up the existing config file before making any changes
3. Adds or updates the minimum release age setting to 7 days (converting to the unit each tool expects)
4. Diffs the modified file against the backup to verify only expected lines changed
5. If unexpected changes are detected, automatically **rolls back** to the backup
6. Prints a summary showing which tools were skipped, updated, or rolled back

## Platform Differences

| | macOS | Linux |
|---|---|---|
| `sed` in-place flag | `sed -i ''` | `sed -i` |
| pnpm config path | `~/Library/Preferences/pnpm/rc` | `~/.config/pnpm/rc` |

## Config Files Modified

| Tool | Config File |
|------|------------|
| pip | `~/.config/pip/pip.conf` |
| uv | `~/.config/uv/uv.toml` |
| npm | `~/.npmrc` |
| pnpm | `~/.config/pnpm/rc` (Linux) or `~/Library/Preferences/pnpm/rc` (macOS) |
| bun | `~/.bunfig.toml` |
| yarn v1 | `~/.yarnrc` |
| yarn v2+ | `~/.yarnrc.yml` |

## License

See [LICENSE](LICENSE) for details.
