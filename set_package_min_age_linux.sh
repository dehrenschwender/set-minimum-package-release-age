#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PLATFORM_NAME="Linux"
PNPM_RC_PATH="$HOME/.config/pnpm/rc"

platform_date_days_ago_rfc3339() {
    date -d "$1 days ago" +%Y-%m-%dT00:00:00Z
}

platform_build_uv_cron_command() {
    local min_age="$1"
    local uv_conf="$2"
    printf '%s' '0 0 * * * /bin/bash -c '"'"'D=$(date -d "'"${min_age}"' days ago" +\%Y-\%m-\%dT00:00:00Z); sed -i "s|^exclude-newer.*|exclude-newer = \"${D}\"|" '"${uv_conf}"''"'"' '"${CRON_MARKER}"
}

source "$SCRIPT_DIR/lib/set_package_min_age_common.sh"

main "$@"
