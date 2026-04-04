#!/usr/bin/env bash
# set_package_min_age_macos.sh
# Sets a minimum package release age for pip, uv (Python) and npm/pnpm/bun/yarn (JavaScript)
# macOS version -- safe to run multiple times
# Run with: bash set_package_min_age_macos.sh [--remove] [DAYS]

set -euo pipefail

# ─────────────────────────────────────────────
# Usage and argument parsing
# ─────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [DAYS]

Set a minimum package release age across pip, uv, npm, pnpm, bun, and yarn.

Arguments:
  DAYS          Minimum age in days (default: 7). Accepts "14" or "14d".

Options:
  --remove      Remove all settings previously added by this script.
  -h, --help    Show this help message and exit.

Examples:
  $(basename "$0")            # Set minimum age to 7 days (default)
  $(basename "$0") 14         # Set minimum age to 14 days
  $(basename "$0") 1d         # Set minimum age to 1 day
  $(basename "$0") --remove   # Remove all settings
EOF
    exit 0
}

REMOVE_MODE=false
CUSTOM_DAYS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remove)
            REMOVE_MODE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 1
            ;;
        *)
            if [[ -n "$CUSTOM_DAYS" ]]; then
                echo "Error: Multiple day values provided." >&2
                exit 1
            fi
            CUSTOM_DAYS="$1"
            shift
            ;;
    esac
done

if [[ "$REMOVE_MODE" == true && -n "$CUSTOM_DAYS" ]]; then
    echo "Error: --remove cannot be combined with a days argument." >&2
    exit 1
fi

if [[ -n "$CUSTOM_DAYS" ]]; then
    CUSTOM_DAYS="${CUSTOM_DAYS%d}"
    if ! [[ "$CUSTOM_DAYS" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: Days must be a positive integer, got: '$CUSTOM_DAYS'" >&2
        exit 1
    fi
    MIN_AGE_DAYS="$CUSTOM_DAYS"
else
    MIN_AGE_DAYS=7
fi
BACKUP_SUFFIX=".bak.$(date +%Y%m%d%H%M%S)"
FAILED_TOOLS=()
SKIPPED_TOOLS=()
UPDATED_TOOLS=()
VALIDATED_TOOLS=()
VALIDATION_FAILED_TOOLS=()

# Print a consistent status line: tool, status, detail
print_status() {
    printf "  %-16s %-10s %s\n" "$1" "$2" "$3"
}

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

    if [[ ! -f "$backup" ]]; then
        UPDATED_TOOLS+=("$tool_name")
        return 0
    fi

    local diff_output
    diff_output=$(diff "$backup" "$file" 2>/dev/null || true)

    if [[ -z "$diff_output" ]]; then
        rm -f "$backup"
        UPDATED_TOOLS+=("$tool_name")
        return 0
    fi

    local content_lines
    content_lines=$(echo "$diff_output" | grep '^[<>]' | sed 's/^[<>] *//' | grep -v '^$' || true)

    if [[ -z "$content_lines" ]]; then
        rm -f "$backup"
        UPDATED_TOOLS+=("$tool_name")
        return 0
    fi

    local unexpected
    unexpected=$(echo "$content_lines" | grep -v "$expected_pattern" || true)

    if [[ -n "$unexpected" ]]; then
        print_status "" "ROLLBACK" "unexpected changes detected, restoring backup"
        echo "$diff_output" | sed 's/^/                              /'
        cp "$backup" "$file"
        rm -f "$backup"
        FAILED_TOOLS+=("$tool_name")
        return 1
    fi

    rm -f "$backup"
    UPDATED_TOOLS+=("$tool_name")
    return 0
}

# ─────────────────────────────────────────────
# Setup functions
# ─────────────────────────────────────────────

setup_pip() {
    local pip_conf_dir="$HOME/.config/pip"
    local pip_conf="$pip_conf_dir/pip.conf"

    mkdir -p "$pip_conf_dir"

    if grep -q "^min-age = ${MIN_AGE_DAYS}d$" "$pip_conf" 2>/dev/null; then
        print_status "pip" "ok" "min-age = ${MIN_AGE_DAYS}d"
        SKIPPED_TOOLS+=("pip")
        return 0
    fi

    backup_if_exists "$pip_conf"

    if grep -q '^\[global\]' "$pip_conf" 2>/dev/null; then
        if grep -q 'min-age' "$pip_conf" 2>/dev/null; then
            local current
            current=$(grep '^[[:space:]]*min-age' "$pip_conf" | head -1 | sed 's/.*= *//')
            print_status "pip" "updated" "$current --> ${MIN_AGE_DAYS}d"
            sed -i '' "s/^[[:space:]]*min-age.*/min-age = ${MIN_AGE_DAYS}d/" "$pip_conf"
        else
            print_status "pip" "added" "min-age = ${MIN_AGE_DAYS}d"
            sed -i '' "/^\[global\]/a\\
min-age = ${MIN_AGE_DAYS}d" "$pip_conf"
        fi
    else
        print_status "pip" "added" "min-age = ${MIN_AGE_DAYS}d (new [global] section)"
        printf '\n[global]\nmin-age = %sd\n' "$MIN_AGE_DAYS" >> "$pip_conf"
    fi

    verify_and_finalize "$pip_conf" "pip" 'min-age\|\[global\]' || true
}

setup_uv() {
    local uv_conf_dir="$HOME/.config/uv"
    local uv_conf="$uv_conf_dir/uv.toml"
    local exclude_newer_date
    exclude_newer_date=$(date -v-${MIN_AGE_DAYS}d +%Y-%m-%dT00:00:00Z)

    mkdir -p "$uv_conf_dir"
    touch "$uv_conf"

    if grep -q "^exclude-newer = \"${exclude_newer_date}\"" "$uv_conf" 2>/dev/null; then
        print_status "uv" "ok" "exclude-newer = \"${exclude_newer_date}\""
        SKIPPED_TOOLS+=("uv")
        return 0
    fi

    if grep -q '^exclude-newer' "$uv_conf" 2>/dev/null; then
        local current
        current=$(grep '^exclude-newer' "$uv_conf" | head -1 | sed 's/.*= *//')
        print_status "uv" "updated" "$current --> \"${exclude_newer_date}\""
        backup_if_exists "$uv_conf"
        sed -i '' "s|^exclude-newer.*|exclude-newer = \"${exclude_newer_date}\"|" "$uv_conf"
    else
        print_status "uv" "added" "exclude-newer = \"${exclude_newer_date}\""
        backup_if_exists "$uv_conf"
        echo "exclude-newer = \"${exclude_newer_date}\"" >> "$uv_conf"
    fi

    verify_and_finalize "$uv_conf" "uv" 'exclude-newer' || true
}

CRON_MARKER="# set-minimum-package-release-age: uv exclude-newer"

setup_cron_uv() {
    local uv_conf="$HOME/.config/uv/uv.toml"
    local min_age="${MIN_AGE_DAYS}"

    if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
        print_status "uv cron" "ok" "daily job installed"
        SKIPPED_TOOLS+=("cron-uv")
        return 0
    fi

    local cron_cmd
    cron_cmd='0 0 * * * /bin/bash -c '"'"'D=$(date -v-'"${min_age}"'d +\%Y-\%m-\%dT00:00:00Z); sed -i "" "s|^exclude-newer.*|exclude-newer = \"${D}\"|" '"${uv_conf}"''"'"' '"${CRON_MARKER}"

    ( crontab -l 2>/dev/null || true; echo "$cron_cmd" ) | crontab -

    if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
        print_status "uv cron" "added" "daily at midnight (crontab -l to verify)"
        UPDATED_TOOLS+=("cron-uv")
    else
        print_status "uv cron" "FAIL" "could not install cron job"
        FAILED_TOOLS+=("cron-uv")
    fi
}

setup_npm() {
    local npmrc="$HOME/.npmrc"

    touch "$npmrc"

    if grep -q "^min-release-age=${MIN_AGE_DAYS}$" "$npmrc" 2>/dev/null; then
        print_status "npm" "ok" "min-release-age=${MIN_AGE_DAYS}"
        SKIPPED_TOOLS+=("npm")
        return 0
    fi

    backup_if_exists "$npmrc"

    if grep -q '^min-release-age' "$npmrc" 2>/dev/null; then
        local current
        current=$(grep '^min-release-age' "$npmrc" | head -1 | sed 's/.*=//')
        print_status "npm" "updated" "$current --> ${MIN_AGE_DAYS}"
        sed -i '' "s/^min-release-age.*/min-release-age=${MIN_AGE_DAYS}/" "$npmrc"
    else
        print_status "npm" "added" "min-release-age=${MIN_AGE_DAYS}"
        echo "min-release-age=${MIN_AGE_DAYS}" >> "$npmrc"
    fi

    verify_and_finalize "$npmrc" "npm" 'min-release-age' || true
}

setup_pnpm() {
    local min_age_minutes=$(( MIN_AGE_DAYS * 1440 ))
    local pnpm_rc="$HOME/Library/Preferences/pnpm/rc"

    mkdir -p "$HOME/Library/Preferences/pnpm"
    touch "$pnpm_rc"

    if grep -q "^minimum-release-age=${min_age_minutes}$" "$pnpm_rc" 2>/dev/null; then
        print_status "pnpm" "ok" "minimum-release-age=${min_age_minutes}"
        SKIPPED_TOOLS+=("pnpm")
        return 0
    fi

    backup_if_exists "$pnpm_rc"

    if grep -q '^minimum-release-age' "$pnpm_rc" 2>/dev/null; then
        local current
        current=$(grep '^minimum-release-age' "$pnpm_rc" | head -1 | sed 's/.*=//')
        print_status "pnpm" "updated" "$current --> ${min_age_minutes}"
        sed -i '' "s/^minimum-release-age.*/minimum-release-age=${min_age_minutes}/" "$pnpm_rc"
    else
        print_status "pnpm" "added" "minimum-release-age=${min_age_minutes}"
        echo "minimum-release-age=${min_age_minutes}" >> "$pnpm_rc"
    fi

    verify_and_finalize "$pnpm_rc" "pnpm" 'minimum-release-age' || true
}

setup_bun() {
    local bunfig="$HOME/.bunfig.toml"
    local min_age_seconds=$(( MIN_AGE_DAYS * 86400 ))

    touch "$bunfig"

    if grep -q "^minimumReleaseAge = ${min_age_seconds}" "$bunfig" 2>/dev/null; then
        print_status "bun" "ok" "minimumReleaseAge = ${min_age_seconds}"
        SKIPPED_TOOLS+=("bun")
        return 0
    fi

    backup_if_exists "$bunfig"

    if grep -q 'minimumReleaseAge' "$bunfig" 2>/dev/null; then
        local current
        current=$(grep 'minimumReleaseAge' "$bunfig" | head -1 | sed 's/.*= *//')
        print_status "bun" "updated" "$current --> ${min_age_seconds}"
        sed -i '' "s/^minimumReleaseAge.*/minimumReleaseAge = ${min_age_seconds}/" "$bunfig"
    else
        if grep -q '^\[install\]' "$bunfig" 2>/dev/null; then
            print_status "bun" "added" "minimumReleaseAge = ${min_age_seconds}"
            sed -i '' "/^\[install\]/a\\
minimumReleaseAge = ${min_age_seconds}" "$bunfig"
        else
            print_status "bun" "added" "minimumReleaseAge = ${min_age_seconds} (new [install] section)"
            printf '\n[install]\nminimumReleaseAge = %s # seconds (%d days)\n' \
                "$min_age_seconds" "$MIN_AGE_DAYS" >> "$bunfig"
        fi
    fi

    verify_and_finalize "$bunfig" "bun" 'minimumReleaseAge\|\[install\]' || true
}

setup_yarn_classic() {
    local yarnrc="$HOME/.yarnrc"
    local min_age_seconds=$(( MIN_AGE_DAYS * 86400 ))

    touch "$yarnrc"

    if grep -q "^cache-min ${min_age_seconds}$" "$yarnrc" 2>/dev/null; then
        print_status "yarn v1" "ok" "cache-min ${min_age_seconds}"
        SKIPPED_TOOLS+=("yarn-classic")
        return 0
    fi

    backup_if_exists "$yarnrc"

    if grep -q '^cache-min' "$yarnrc" 2>/dev/null; then
        local current
        current=$(grep '^cache-min' "$yarnrc" | head -1 | awk '{print $2}')
        print_status "yarn v1" "updated" "$current --> ${min_age_seconds}"
        sed -i '' "s/^cache-min.*/cache-min ${min_age_seconds}/" "$yarnrc"
    else
        print_status "yarn v1" "added" "cache-min ${min_age_seconds}"
        echo "cache-min ${min_age_seconds}" >> "$yarnrc"
    fi

    verify_and_finalize "$yarnrc" "yarn-classic" 'cache-min' || true
}

setup_yarn_berry() {
    local yarnrc_yml="$HOME/.yarnrc.yml"

    touch "$yarnrc_yml"

    if grep -q '^# min-package-age' "$yarnrc_yml" 2>/dev/null; then
        print_status "yarn v2+" "ok" "advisory comment present"
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
    print_status "yarn v2+" "added" "advisory comment"

    verify_and_finalize "$yarnrc_yml" "yarn-berry" 'min-package-age\|Yarn Berry\|minimum package age\|YARN_CACHE_FOLDER\|cache TTL\|CI/CD' || true
}

# ─────────────────────────────────────────────
# Remove functions
# ─────────────────────────────────────────────

remove_pip() {
    local pip_conf="$HOME/.config/pip/pip.conf"

    if ! grep -q '^[[:space:]]*min-age' "$pip_conf" 2>/dev/null; then
        print_status "pip" "ok" "min-age not present"
        SKIPPED_TOOLS+=("pip")
        return 0
    fi

    local current
    current=$(grep '^[[:space:]]*min-age' "$pip_conf" | head -1 | sed 's/.*= *//')
    print_status "pip" "removed" "min-age = $current"

    backup_if_exists "$pip_conf"

    sed -i '' '/^[[:space:]]*min-age/d' "$pip_conf"

    # If [global] section is now empty, remove it
    if grep -q '^\[global\]' "$pip_conf" 2>/dev/null; then
        local has_content
        has_content=$(sed -n '/^\[global\]/,/^\[/{/^\[global\]/d;/^\[/d;/^$/d;/^[[:space:]]*$/d;p;}' "$pip_conf" | head -1)
        if [[ -z "$has_content" ]]; then
            sed -i '' '/^\[global\]/d' "$pip_conf"
        fi
    fi

    # Truncate if file is now whitespace-only (so diff still works)
    if [[ -f "$pip_conf" ]] && ! grep -q '[^[:space:]]' "$pip_conf" 2>/dev/null; then
        : > "$pip_conf"
    fi

    verify_and_finalize "$pip_conf" "pip" 'min-age\|\[global\]' || true

    # Clean up empty file after successful verification
    if [[ -f "$pip_conf" ]] && ! grep -q '[^[:space:]]' "$pip_conf" 2>/dev/null; then
        rm -f "$pip_conf"
    fi
}

remove_uv() {
    local uv_conf="$HOME/.config/uv/uv.toml"

    if ! grep -q '^exclude-newer' "$uv_conf" 2>/dev/null; then
        print_status "uv" "ok" "exclude-newer not present"
        SKIPPED_TOOLS+=("uv")
        return 0
    fi

    local current
    current=$(grep '^exclude-newer' "$uv_conf" | head -1 | sed 's/.*= *//')
    print_status "uv" "removed" "exclude-newer = $current"

    backup_if_exists "$uv_conf"
    sed -i '' '/^exclude-newer/d' "$uv_conf"

    if [[ -f "$uv_conf" ]] && ! grep -q '[^[:space:]]' "$uv_conf" 2>/dev/null; then
        : > "$uv_conf"
    fi

    verify_and_finalize "$uv_conf" "uv" 'exclude-newer' || true

    if [[ -f "$uv_conf" ]] && ! grep -q '[^[:space:]]' "$uv_conf" 2>/dev/null; then
        rm -f "$uv_conf"
    fi
}

remove_cron_uv() {
    if ! crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
        print_status "uv cron" "ok" "cron job not present"
        SKIPPED_TOOLS+=("cron-uv")
        return 0
    fi

    local new_crontab
    new_crontab=$(crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" || true)
    if [[ -n "$new_crontab" ]]; then
        echo "$new_crontab" | crontab -
    else
        crontab -r 2>/dev/null || true
    fi

    if ! crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
        print_status "uv cron" "removed" "daily cron job"
        UPDATED_TOOLS+=("cron-uv")
    else
        print_status "uv cron" "FAIL" "could not remove cron job"
        FAILED_TOOLS+=("cron-uv")
    fi
}

remove_npm() {
    local npmrc="$HOME/.npmrc"

    if ! grep -q '^min-release-age' "$npmrc" 2>/dev/null; then
        print_status "npm" "ok" "min-release-age not present"
        SKIPPED_TOOLS+=("npm")
        return 0
    fi

    local current
    current=$(grep '^min-release-age' "$npmrc" | head -1 | sed 's/.*=//')
    print_status "npm" "removed" "min-release-age=$current"

    backup_if_exists "$npmrc"
    sed -i '' '/^min-release-age/d' "$npmrc"

    if [[ -f "$npmrc" ]] && ! grep -q '[^[:space:]]' "$npmrc" 2>/dev/null; then
        : > "$npmrc"
    fi

    verify_and_finalize "$npmrc" "npm" 'min-release-age' || true

    if [[ -f "$npmrc" ]] && ! grep -q '[^[:space:]]' "$npmrc" 2>/dev/null; then
        rm -f "$npmrc"
    fi
}

remove_pnpm() {
    local pnpm_rc="$HOME/Library/Preferences/pnpm/rc"

    if ! grep -q '^minimum-release-age' "$pnpm_rc" 2>/dev/null; then
        print_status "pnpm" "ok" "minimum-release-age not present"
        SKIPPED_TOOLS+=("pnpm")
        return 0
    fi

    local current
    current=$(grep '^minimum-release-age' "$pnpm_rc" | head -1 | sed 's/.*=//')
    print_status "pnpm" "removed" "minimum-release-age=$current"

    backup_if_exists "$pnpm_rc"
    sed -i '' '/^minimum-release-age/d' "$pnpm_rc"

    if [[ -f "$pnpm_rc" ]] && ! grep -q '[^[:space:]]' "$pnpm_rc" 2>/dev/null; then
        : > "$pnpm_rc"
    fi

    verify_and_finalize "$pnpm_rc" "pnpm" 'minimum-release-age' || true

    if [[ -f "$pnpm_rc" ]] && ! grep -q '[^[:space:]]' "$pnpm_rc" 2>/dev/null; then
        rm -f "$pnpm_rc"
    fi
}

remove_bun() {
    local bunfig="$HOME/.bunfig.toml"

    if ! grep -q 'minimumReleaseAge' "$bunfig" 2>/dev/null; then
        print_status "bun" "ok" "minimumReleaseAge not present"
        SKIPPED_TOOLS+=("bun")
        return 0
    fi

    local current
    current=$(grep 'minimumReleaseAge' "$bunfig" | head -1 | sed 's/.*= *//')
    print_status "bun" "removed" "minimumReleaseAge = $current"

    backup_if_exists "$bunfig"
    sed -i '' '/^minimumReleaseAge/d' "$bunfig"

    # If [install] section is now empty, remove it
    if grep -q '^\[install\]' "$bunfig" 2>/dev/null; then
        local has_content
        has_content=$(sed -n '/^\[install\]/,/^\[/{/^\[install\]/d;/^\[/d;/^$/d;/^[[:space:]]*$/d;p;}' "$bunfig" | head -1)
        if [[ -z "$has_content" ]]; then
            sed -i '' '/^\[install\]/d' "$bunfig"
        fi
    fi

    if [[ -f "$bunfig" ]] && ! grep -q '[^[:space:]]' "$bunfig" 2>/dev/null; then
        : > "$bunfig"
    fi

    verify_and_finalize "$bunfig" "bun" 'minimumReleaseAge\|\[install\]' || true

    if [[ -f "$bunfig" ]] && ! grep -q '[^[:space:]]' "$bunfig" 2>/dev/null; then
        rm -f "$bunfig"
    fi
}

remove_yarn_classic() {
    local yarnrc="$HOME/.yarnrc"

    if ! grep -q '^cache-min' "$yarnrc" 2>/dev/null; then
        print_status "yarn v1" "ok" "cache-min not present"
        SKIPPED_TOOLS+=("yarn-classic")
        return 0
    fi

    local current
    current=$(grep '^cache-min' "$yarnrc" | head -1 | awk '{print $2}')
    print_status "yarn v1" "removed" "cache-min $current"

    backup_if_exists "$yarnrc"
    sed -i '' '/^cache-min/d' "$yarnrc"

    if [[ -f "$yarnrc" ]] && ! grep -q '[^[:space:]]' "$yarnrc" 2>/dev/null; then
        : > "$yarnrc"
    fi

    verify_and_finalize "$yarnrc" "yarn-classic" 'cache-min' || true

    if [[ -f "$yarnrc" ]] && ! grep -q '[^[:space:]]' "$yarnrc" 2>/dev/null; then
        rm -f "$yarnrc"
    fi
}

remove_yarn_berry() {
    local yarnrc_yml="$HOME/.yarnrc.yml"

    if ! grep -q '^# min-package-age' "$yarnrc_yml" 2>/dev/null; then
        print_status "yarn v2+" "ok" "advisory comment not present"
        SKIPPED_TOOLS+=("yarn-berry")
        return 0
    fi

    print_status "yarn v2+" "removed" "advisory comment"

    backup_if_exists "$yarnrc_yml"
    sed -i '' '/^# min-package-age/,/^# or manage cache TTL/d' "$yarnrc_yml"

    if [[ -f "$yarnrc_yml" ]] && ! grep -q '[^[:space:]]' "$yarnrc_yml" 2>/dev/null; then
        : > "$yarnrc_yml"
    fi

    verify_and_finalize "$yarnrc_yml" "yarn-berry" 'min-package-age\|Yarn Berry\|minimum package age\|YARN_CACHE_FOLDER\|cache TTL\|CI/CD' || true

    if [[ -f "$yarnrc_yml" ]] && ! grep -q '[^[:space:]]' "$yarnrc_yml" 2>/dev/null; then
        rm -f "$yarnrc_yml"
    fi
}

# ─────────────────────────────────────────────
# Config validation
# ─────────────────────────────────────────────
validate_configs() {
    local pip_cmd=""
    if command -v pip3 &>/dev/null; then
        pip_cmd="pip3"
    elif command -v pip &>/dev/null; then
        pip_cmd="pip"
    fi

    if [[ -n "$pip_cmd" ]]; then
        local pip_output
        if pip_output=$($pip_cmd config list 2>&1) && echo "$pip_output" | grep -q 'min-age'; then
            print_status "pip" "ok" "min-age found in parsed config"
            VALIDATED_TOOLS+=("pip")
        else
            print_status "pip" "FAIL" "could not read min-age from config"
            VALIDATION_FAILED_TOOLS+=("pip")
        fi
    else
        print_status "pip" "--" "not installed"
    fi

    if command -v uv &>/dev/null; then
        local uv_output
        if uv_output=$(uv self version 2>&1); then
            print_status "uv" "ok" "config parsed ($uv_output)"
            VALIDATED_TOOLS+=("uv")
        else
            print_status "uv" "FAIL" "config parse error"
            VALIDATION_FAILED_TOOLS+=("uv")
        fi
    else
        print_status "uv" "--" "not installed"
    fi

    if command -v npm &>/dev/null; then
        local npm_output
        npm_output=$(npm config list 2>/dev/null || true)
        if echo "$npm_output" | grep -q 'before'; then
            local npm_before
            npm_before=$(echo "$npm_output" | grep 'before' | head -1 | sed 's/.*= *//' | tr -d '"')
            print_status "npm" "ok" "min-release-age active (before=$npm_before)"
            VALIDATED_TOOLS+=("npm")
        else
            print_status "npm" "FAIL" "min-release-age not found in npm config"
            VALIDATION_FAILED_TOOLS+=("npm")
        fi
    else
        print_status "npm" "--" "not installed"
    fi

    if command -v pnpm &>/dev/null; then
        local pnpm_val
        pnpm_val=$(pnpm config get minimum-release-age 2>/dev/null || true)
        if [[ -n "$pnpm_val" && "$pnpm_val" != "undefined" ]]; then
            print_status "pnpm" "ok" "minimum-release-age=$pnpm_val"
            VALIDATED_TOOLS+=("pnpm")
        else
            print_status "pnpm" "FAIL" "minimum-release-age not found"
            VALIDATION_FAILED_TOOLS+=("pnpm")
        fi
    else
        print_status "pnpm" "--" "not installed"
    fi

    print_status "bun" "--" "no validation command available"

    if command -v yarn &>/dev/null; then
        local yarn_ver
        yarn_ver=$(yarn --version 2>/dev/null || true)
        if [[ "$yarn_ver" == 1.* ]]; then
            local yarn_output
            if yarn_output=$(yarn config list 2>&1); then
                print_status "yarn v1" "ok" "config parsed"
                VALIDATED_TOOLS+=("yarn-classic")
            else
                print_status "yarn v1" "FAIL" "config parse error"
                VALIDATION_FAILED_TOOLS+=("yarn-classic")
            fi
        else
            print_status "yarn v2+" "--" "advisory comment only"
        fi
    else
        print_status "yarn" "--" "not installed"
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────

if [[ "$REMOVE_MODE" == true ]]; then
    echo ""
    echo "  set-minimum-package-release-age (macOS) -- REMOVE MODE"
    echo ""
    echo "  Removing settings"
    echo "  ----------------------------------------------------------"
    printf "  %-16s %-10s %s\n" "TOOL" "STATUS" "DETAIL"
    echo "  ----------------------------------------------------------"

    remove_pip
    remove_uv
    remove_cron_uv
    remove_npm
    remove_pnpm
    remove_bun
    remove_yarn_classic
    remove_yarn_berry

    echo ""
    echo "  Summary"
    echo "  ----------------------------------------------------------"

    echo "  ${#SKIPPED_TOOLS[@]} not present, ${#UPDATED_TOOLS[@]} removed, ${#FAILED_TOOLS[@]} failed"

    if [[ ${#FAILED_TOOLS[@]} -gt 0 ]]; then
        echo ""
        echo "  Rolled back: ${FAILED_TOOLS[*]}"
    fi

    echo ""
    echo "  Config files"
    echo "  ----------------------------------------------------------"
    echo "  pip            $HOME/.config/pip/pip.conf"
    echo "  uv             $HOME/.config/uv/uv.toml"
    echo "  npm            $HOME/.npmrc"
    echo "  pnpm           $HOME/Library/Preferences/pnpm/rc"
    echo "  bun            $HOME/.bunfig.toml"
    echo "  yarn v1        $HOME/.yarnrc"
    echo "  yarn v2+       $HOME/.yarnrc.yml"
    echo ""
else
    echo ""
    echo "  set-minimum-package-release-age (macOS)"
    echo "  minimum age: ${MIN_AGE_DAYS} days"
    echo ""
    echo "  Configuration"
    echo "  ----------------------------------------------------------"
    printf "  %-16s %-10s %s\n" "TOOL" "STATUS" "DETAIL"
    echo "  ----------------------------------------------------------"

    setup_pip
    setup_uv
    setup_cron_uv
    setup_npm
    setup_pnpm
    setup_bun
    setup_yarn_classic
    setup_yarn_berry

    echo ""
    echo "  Validation"
    echo "  ----------------------------------------------------------"
    printf "  %-16s %-10s %s\n" "TOOL" "STATUS" "DETAIL"
    echo "  ----------------------------------------------------------"

    validate_configs

    echo ""
    echo "  Summary"
    echo "  ----------------------------------------------------------"

    local_total=$(( ${#SKIPPED_TOOLS[@]} + ${#UPDATED_TOOLS[@]} + ${#FAILED_TOOLS[@]} ))
    echo "  ${#SKIPPED_TOOLS[@]} unchanged, ${#UPDATED_TOOLS[@]} updated, ${#FAILED_TOOLS[@]} failed"
    echo "  ${#VALIDATED_TOOLS[@]} validated, ${#VALIDATION_FAILED_TOOLS[@]} validation errors"

    if [[ ${#FAILED_TOOLS[@]} -gt 0 ]]; then
        echo ""
        echo "  Rolled back: ${FAILED_TOOLS[*]}"
    fi

    if [[ ${#VALIDATION_FAILED_TOOLS[@]} -gt 0 ]]; then
        echo ""
        echo "  Validation errors: ${VALIDATION_FAILED_TOOLS[*]}"
    fi

    echo ""
    echo "  Config files"
    echo "  ----------------------------------------------------------"
    echo "  pip            $HOME/.config/pip/pip.conf"
    echo "  uv             $HOME/.config/uv/uv.toml"
    echo "  npm            $HOME/.npmrc"
    echo "  pnpm           $HOME/Library/Preferences/pnpm/rc"
    echo "  bun            $HOME/.bunfig.toml"
    echo "  yarn v1        $HOME/.yarnrc"
    echo "  yarn v2+       $HOME/.yarnrc.yml"
    echo ""
fi
