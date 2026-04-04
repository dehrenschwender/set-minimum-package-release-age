#!/usr/bin/env bash
# set_package_min_age_linux.sh
# Sets a minimum package age of 7 days for pip, uv (Python) and npm/pnpm/bun/yarn (JavaScript)
# Linux version — safe to run multiple times
# Run with: bash set_package_min_age_linux.sh

set -euo pipefail

MIN_AGE_DAYS=7
BACKUP_SUFFIX=".bak.$(date +%Y%m%d%H%M%S)"
FAILED_TOOLS=()
SKIPPED_TOOLS=()
UPDATED_TOOLS=()

# Back up an existing file before modifying it
backup_if_exists() {
    local file="$1"
    if [[ -f "$file" && -s "$file" ]]; then
        cp "$file" "${file}${BACKUP_SUFFIX}"
    fi
}

# Verify that only expected changes were made, roll back if not
# Args: $1 = file path, $2 = tool name, $3 = grep pattern matching all expected diff lines
verify_and_finalize() {
    local file="$1"
    local tool_name="$2"
    local expected_pattern="$3"
    local backup="${file}${BACKUP_SUFFIX}"

    # If no backup exists, the file was newly created — nothing to verify against
    if [[ ! -f "$backup" ]]; then
        echo "    [verify] ✓ New file — no previous config to diff against"
        UPDATED_TOOLS+=("$tool_name")
        return 0
    fi

    # Compute diff between backup and modified file
    local diff_output
    diff_output=$(diff "$backup" "$file" 2>/dev/null || true)

    # No diff means the file is identical (already configured)
    if [[ -z "$diff_output" ]]; then
        echo "    [verify] ✓ No changes were needed"
        rm -f "$backup"
        UPDATED_TOOLS+=("$tool_name")
        return 0
    fi

    # Show the diff to the user
    echo "    [verify] Diff (backup → modified):"
    echo "$diff_output" | sed 's/^/             /'
    echo ""

    # Extract only the content lines from the diff (lines starting with < or >)
    # Skip blank content lines (e.g. from printf adding a leading newline)
    local content_lines
    content_lines=$(echo "$diff_output" | grep '^[<>]' | sed 's/^[<>] *//' | grep -v '^$' || true)

    if [[ -z "$content_lines" ]]; then
        echo "    [verify] ✓ Only whitespace changes — OK"
        rm -f "$backup"
        UPDATED_TOOLS+=("$tool_name")
        return 0
    fi

    # Check that every changed content line matches the expected pattern
    local unexpected
    unexpected=$(echo "$content_lines" | grep -v "$expected_pattern" || true)

    if [[ -n "$unexpected" ]]; then
        echo "    [verify] ✗ UNEXPECTED CHANGES — rolling back ${file}"
        echo "    Unexpected lines:"
        echo "$unexpected" | sed 's/^/             /'
        cp "$backup" "$file"
        rm -f "$backup"
        FAILED_TOOLS+=("$tool_name")
        return 1
    fi

    echo "    [verify] ✓ All changes match expected pattern — backup removed"
    rm -f "$backup"
    UPDATED_TOOLS+=("$tool_name")
    return 0
}

echo "==> Setting minimum package age to ${MIN_AGE_DAYS} days (Linux)..."

# ─────────────────────────────────────────────
# Python – pip
# Config file: ~/.config/pip/pip.conf  (XDG)
# Expected:    min-age = 7d  under [global]
# ─────────────────────────────────────────────
setup_pip() {
    local pip_conf_dir="$HOME/.config/pip"
    local pip_conf="$pip_conf_dir/pip.conf"

    mkdir -p "$pip_conf_dir"

    # Check if already correctly configured
    if grep -q "^min-age = ${MIN_AGE_DAYS}d$" "$pip_conf" 2>/dev/null; then
        echo "    [pip] Already set to ${MIN_AGE_DAYS}d in $pip_conf — skipping"
        SKIPPED_TOOLS+=("pip")
        return 0
    fi

    backup_if_exists "$pip_conf"

    if grep -q '^\[global\]' "$pip_conf" 2>/dev/null; then
        if grep -q 'min-age' "$pip_conf" 2>/dev/null; then
            local current
            current=$(grep '^[[:space:]]*min-age' "$pip_conf" | head -1 | sed 's/.*= *//')
            echo "    [pip] Current value: min-age = $current → updating to ${MIN_AGE_DAYS}d"
            sed -i "s/^[[:space:]]*min-age.*/min-age = ${MIN_AGE_DAYS}d/" "$pip_conf"
        else
            echo "    [pip] Adding min-age = ${MIN_AGE_DAYS}d to existing [global] section"
            sed -i "/^\[global\]/a\\
min-age = ${MIN_AGE_DAYS}d" "$pip_conf"
        fi
    else
        echo "    [pip] Creating [global] section with min-age = ${MIN_AGE_DAYS}d"
        printf '\n[global]\nmin-age = %sd\n' "$MIN_AGE_DAYS" >> "$pip_conf"
    fi

    verify_and_finalize "$pip_conf" "pip" 'min-age\|\[global\]' || true
}

# ─────────────────────────────────────────────
# Python – uv
# Config file: ~/.config/uv/uv.toml  (XDG)
# Expected:    exclude-newer = "<RFC 3339 date 7 days ago>"
# Note:        uv requires an absolute date, not a relative duration.
#              Re-run this script periodically to keep the date current.
# ─────────────────────────────────────────────
setup_uv() {
    local uv_conf_dir="$HOME/.config/uv"
    local uv_conf="$uv_conf_dir/uv.toml"
    # Compute date N days ago in RFC 3339 format (GNU date)
    local exclude_newer_date
    exclude_newer_date=$(date -d "${MIN_AGE_DAYS} days ago" +%Y-%m-%dT00:00:00Z)

    mkdir -p "$uv_conf_dir"
    touch "$uv_conf"

    # Check if already set (any date is acceptable — we always update to keep it current)
    if grep -q '^exclude-newer' "$uv_conf" 2>/dev/null; then
        local current
        current=$(grep '^exclude-newer' "$uv_conf" | head -1 | sed 's/.*= *//')
        echo "    [uv] Current value: exclude-newer = $current → updating to \"${exclude_newer_date}\""
        echo "    [uv] (uv requires an absolute date; re-run this script periodically to keep it current)"

        backup_if_exists "$uv_conf"
        sed -i "s|^exclude-newer.*|exclude-newer = \"${exclude_newer_date}\"|" "$uv_conf"
    else
        echo "    [uv] Adding exclude-newer = \"${exclude_newer_date}\""
        echo "    [uv] (uv requires an absolute date; re-run this script periodically to keep it current)"

        backup_if_exists "$uv_conf"
        echo "exclude-newer = \"${exclude_newer_date}\"" >> "$uv_conf"
    fi

    verify_and_finalize "$uv_conf" "uv" 'exclude-newer' || true
}

# ─────────────────────────────────────────────
# JavaScript – pnpm
# Config file: ~/.config/pnpm/rc  (Linux)
# Expected:    minimum-release-age=10080  (7 days in minutes)
# ─────────────────────────────────────────────
setup_pnpm() {
    local min_age_minutes=$(( MIN_AGE_DAYS * 1440 ))
    local pnpm_rc="$HOME/.config/pnpm/rc"

    mkdir -p "$HOME/.config/pnpm"
    touch "$pnpm_rc"

    # Check if already correctly configured
    if grep -q "^minimum-release-age=${min_age_minutes}$" "$pnpm_rc" 2>/dev/null; then
        echo "    [pnpm] Already set to ${min_age_minutes}min (${MIN_AGE_DAYS}d) in $pnpm_rc — skipping"
        SKIPPED_TOOLS+=("pnpm")
        return 0
    fi

    backup_if_exists "$pnpm_rc"

    if grep -q '^minimum-release-age' "$pnpm_rc" 2>/dev/null; then
        local current
        current=$(grep '^minimum-release-age' "$pnpm_rc" | head -1 | sed 's/.*=//')
        echo "    [pnpm] Current value: minimum-release-age=$current → updating to ${min_age_minutes}"
        sed -i "s/^minimum-release-age.*/minimum-release-age=${min_age_minutes}/" "$pnpm_rc"
    else
        echo "    [pnpm] Adding minimum-release-age=${min_age_minutes} (${MIN_AGE_DAYS}d)"
        echo "minimum-release-age=${min_age_minutes}" >> "$pnpm_rc"
    fi

    verify_and_finalize "$pnpm_rc" "pnpm" 'minimum-release-age' || true
}

# ─────────────────────────────────────────────
# JavaScript – bun
# Config file: ~/.bunfig.toml
# Expected:    minimumReleaseAge = 604800  under [install]
# ─────────────────────────────────────────────
setup_bun() {
    local bunfig="$HOME/.bunfig.toml"
    local min_age_seconds=$(( MIN_AGE_DAYS * 86400 ))

    touch "$bunfig"

    # Check if already correctly configured
    if grep -q "^minimumReleaseAge = ${min_age_seconds}" "$bunfig" 2>/dev/null; then
        echo "    [bun] Already set to ${min_age_seconds}s (${MIN_AGE_DAYS}d) in $bunfig — skipping"
        SKIPPED_TOOLS+=("bun")
        return 0
    fi

    backup_if_exists "$bunfig"

    if grep -q 'minimumReleaseAge' "$bunfig" 2>/dev/null; then
        local current
        current=$(grep 'minimumReleaseAge' "$bunfig" | head -1 | sed 's/.*= *//')
        echo "    [bun] Current value: minimumReleaseAge = $current → updating to ${min_age_seconds}"
        sed -i "s/^minimumReleaseAge.*/minimumReleaseAge = ${min_age_seconds}/" "$bunfig"
    else
        if grep -q '^\[install\]' "$bunfig" 2>/dev/null; then
            echo "    [bun] Adding minimumReleaseAge = ${min_age_seconds} to existing [install] section"
            sed -i "/^\[install\]/a\\
minimumReleaseAge = ${min_age_seconds}" "$bunfig"
        else
            echo "    [bun] Creating [install] section with minimumReleaseAge = ${min_age_seconds}"
            printf '\n[install]\nminimumReleaseAge = %s # seconds (%d days)\n' \
                "$min_age_seconds" "$MIN_AGE_DAYS" >> "$bunfig"
        fi
    fi

    verify_and_finalize "$bunfig" "bun" 'minimumReleaseAge\|\[install\]' || true
}

# ─────────────────────────────────────────────
# JavaScript – npm
# Config file: ~/.npmrc
# Expected:    min-release-age=7
# ─────────────────────────────────────────────
setup_npm() {
    local npmrc="$HOME/.npmrc"

    touch "$npmrc"

    # Check if already correctly configured
    if grep -q "^min-release-age=${MIN_AGE_DAYS}$" "$npmrc" 2>/dev/null; then
        echo "    [npm] Already set to ${MIN_AGE_DAYS}d in $npmrc — skipping"
        SKIPPED_TOOLS+=("npm")
        return 0
    fi

    backup_if_exists "$npmrc"

    if grep -q '^min-release-age' "$npmrc" 2>/dev/null; then
        local current
        current=$(grep '^min-release-age' "$npmrc" | head -1 | sed 's/.*=//')
        echo "    [npm] Current value: min-release-age=$current → updating to ${MIN_AGE_DAYS}"
        sed -i "s/^min-release-age.*/min-release-age=${MIN_AGE_DAYS}/" "$npmrc"
    else
        echo "    [npm] Adding min-release-age=${MIN_AGE_DAYS}"
        echo "min-release-age=${MIN_AGE_DAYS}" >> "$npmrc"
    fi

    verify_and_finalize "$npmrc" "npm" 'min-release-age' || true
}

# ─────────────────────────────────────────────
# JavaScript – yarn (classic v1)
# Config file: ~/.yarnrc
# Expected:    cache-min 604800
# ─────────────────────────────────────────────
setup_yarn_classic() {
    local yarnrc="$HOME/.yarnrc"
    local min_age_seconds=$(( MIN_AGE_DAYS * 86400 ))

    touch "$yarnrc"

    # Check if already correctly configured
    if grep -q "^cache-min ${min_age_seconds}$" "$yarnrc" 2>/dev/null; then
        echo "    [yarn v1] Already set to ${min_age_seconds}s (${MIN_AGE_DAYS}d) in $yarnrc — skipping"
        SKIPPED_TOOLS+=("yarn-classic")
        return 0
    fi

    backup_if_exists "$yarnrc"

    if grep -q '^cache-min' "$yarnrc" 2>/dev/null; then
        local current
        current=$(grep '^cache-min' "$yarnrc" | head -1 | awk '{print $2}')
        echo "    [yarn v1] Current value: cache-min $current → updating to ${min_age_seconds}"
        sed -i "s/^cache-min.*/cache-min ${min_age_seconds}/" "$yarnrc"
    else
        echo "    [yarn v1] Adding cache-min ${min_age_seconds} (${MIN_AGE_DAYS}d)"
        echo "cache-min ${min_age_seconds}" >> "$yarnrc"
    fi

    verify_and_finalize "$yarnrc" "yarn-classic" 'cache-min' || true
}

# ─────────────────────────────────────────────
# JavaScript – yarn berry (v2+)
# Config file: ~/.yarnrc.yml
# Expected:    advisory comment block
# ─────────────────────────────────────────────
setup_yarn_berry() {
    local yarnrc_yml="$HOME/.yarnrc.yml"

    touch "$yarnrc_yml"

    # Check if already present
    if grep -q '^# min-package-age' "$yarnrc_yml" 2>/dev/null; then
        echo "    [yarn berry] Advisory comment already present in $yarnrc_yml — skipping"
        SKIPPED_TOOLS+=("yarn-berry")
        return 0
    fi

    backup_if_exists "$yarnrc_yml"

    cat >> "$yarnrc_yml" <<EOF

# min-package-age: ${MIN_AGE_DAYS} days
# Yarn Berry (v2+) does not have a built-in cache-min setting.
# To enforce a minimum package age, set the environment variable:
#   YARN_CACHE_FOLDER_MAX_AGE=${MIN_AGE_DAYS}d
# or manage cache TTL via your CI/CD configuration.
EOF
    echo "    [yarn berry] Added advisory comment to $yarnrc_yml"

    verify_and_finalize "$yarnrc_yml" "yarn-berry" 'min-package-age\|Yarn Berry\|YARN_CACHE_FOLDER\|cache TTL\|CI/CD' || true
}

# ─────────────────────────────────────────────
# Run setup functions
# ─────────────────────────────────────────────
echo ""
echo "── Python (pip) ──────────────────────────"
setup_pip

echo ""
echo "── Python (uv) ───────────────────────────"
setup_uv

echo ""
echo "── JavaScript (npm) ──────────────────────"
setup_npm

echo ""
echo "── JavaScript (pnpm) ─────────────────────"
setup_pnpm

echo ""
echo "── JavaScript (bun) ──────────────────────"
setup_bun

echo ""
echo "── JavaScript (yarn classic v1) ──────────"
setup_yarn_classic

echo ""
echo "── JavaScript (yarn berry v2+) ───────────"
setup_yarn_berry

echo ""
echo "─────────────────────────────────────────────"
echo ""

# Summary
if [[ ${#SKIPPED_TOOLS[@]} -gt 0 ]]; then
    echo "⏭  Already configured (no changes made):"
    for tool in "${SKIPPED_TOOLS[@]}"; do
        echo "  - $tool"
    done
    echo ""
fi

if [[ ${#UPDATED_TOOLS[@]} -gt 0 ]]; then
    echo "✅  Updated successfully:"
    for tool in "${UPDATED_TOOLS[@]}"; do
        echo "  - $tool"
    done
    echo ""
fi

if [[ ${#FAILED_TOOLS[@]} -gt 0 ]]; then
    echo "⚠️  Rolled back (unexpected changes detected):"
    for tool in "${FAILED_TOOLS[@]}"; do
        echo "  ✗ $tool"
    done
    echo ""
fi

echo "Config files:"
echo "  pip   → $HOME/.config/pip/pip.conf"
echo "  uv    → $HOME/.config/uv/uv.toml"
echo "  npm   → $HOME/.npmrc"
echo "  pnpm  → $HOME/.config/pnpm/rc"
echo "  bun   → $HOME/.bunfig.toml"
echo "  yarn  → $HOME/.yarnrc  and  $HOME/.yarnrc.yml"
