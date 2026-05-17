#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PLATFORM_NAME="macOS"
PNPM_CONFIG_PATH="$HOME/Library/Preferences/pnpm/config.yaml"
PNPM_RC_PATH="$HOME/Library/Preferences/pnpm/rc"
VLT_CONFIG_PATH="$HOME/Library/Preferences/vlt/vlt.json"

platform_date_days_ago_rfc3339() {
    date -v-"$1"d +%Y-%m-%dT00:00:00Z
}

platform_build_uv_cron_command() {
    local min_age="$1"
    local uv_conf="$2"
    printf '%s' '0 0 * * * /bin/bash -c '"'"'D=$(date -v-'"${min_age}"'d +\%Y-\%m-\%dT00:00:00Z); sed -i "" "s|^exclude-newer.*|exclude-newer = \"${D}\"|" '"${uv_conf}"''"'"' '"${CRON_MARKER}"
}

platform_build_vlt_cron_command() {
    local min_age="$1"
    local script_path="$SCRIPT_DIR/set_package_min_age_macos.sh"
    printf '0 0 * * * SET_MINIMUM_PACKAGE_RELEASE_AGE_REFRESH_VLT=1 /bin/bash %s %s >/dev/null 2>&1 %s' "$(shell_quote "$script_path")" "$min_age" "$VLT_CRON_MARKER"
}

source "$SCRIPT_DIR/lib/set_package_min_age_common.sh"

main "$@"
