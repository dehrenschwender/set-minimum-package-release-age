#!/usr/bin/env bash
# shellcheck disable=SC2128
# This script needs bash outside POSIX mode. It refuses to be sourced, because
# `set -euo pipefail` would leak into the calling interactive shell, and when
# started as `zsh script.sh` or `sh script.sh` it re-runs itself with bash.
spm_sourced=0
[ "${BASH_SOURCE:-$0}" = "$0" ] || spm_sourced=1
case "${ZSH_EVAL_CONTEXT:-}" in *file*) spm_sourced=1 ;; esac
if [ "$spm_sourced" = 1 ]; then
    printf '%s\n' "Run this script with bash instead of sourcing it." >&2
    unset spm_sourced
    return 1
fi
if [ -z "${BASH_VERSION:-}" ] || case ":${SHELLOPTS:-}:" in *:posix:*) true ;; *) false ;; esac; then
    # Only re-exec when $0 is this script; a shell sourcing it has its own name in $0.
    case "${0##*/}" in
        set_package_min_age_*.sh) exec bash "$0" "$@" ;;
    esac
    printf '%s\n' "Run this script with bash." >&2
    return 1 2>/dev/null || exit 1
fi
unset spm_sourced

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PLATFORM_NAME="Linux"
# Linux tool paths all follow XDG_CONFIG_HOME, which the shared library resolves.

platform_date_days_ago_rfc3339() {
    date -d "$1 days ago" +%Y-%m-%dT00:00:00Z
}

# cron runs without the login shell environment, so pin the resolved vlt path.
platform_build_vlt_cron_command() {
    local min_age="$1"
    local vlt_conf="$2"
    local script_path="$SCRIPT_DIR/set_package_min_age_linux.sh"
    printf '0 0 * * * SET_MINIMUM_PACKAGE_RELEASE_AGE_REFRESH_VLT=1 VLT_CONFIG_PATH=%s /bin/bash %s %s >/dev/null 2>&1 %s' "$(shell_quote "$vlt_conf")" "$(shell_quote "$script_path")" "$min_age" "$VLT_CRON_MARKER"
}

source "$SCRIPT_DIR/lib/set_package_min_age_common.sh"

main "$@"
