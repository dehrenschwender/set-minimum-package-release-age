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

PLATFORM_NAME="macOS"
# pnpm and vlt switch to $XDG_CONFIG_HOME/<tool> when it is set, even on macOS.
if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    PNPM_CONFIG_DIR="$XDG_CONFIG_HOME/pnpm"
    VLT_CONFIG_DIR="$XDG_CONFIG_HOME/vlt"
else
    PNPM_CONFIG_DIR="$HOME/Library/Preferences/pnpm"
    VLT_CONFIG_DIR="$HOME/Library/Preferences/vlt"
fi
PNPM_CONFIG_PATH="$PNPM_CONFIG_DIR/config.yaml"
PNPM_RC_PATH="$PNPM_CONFIG_DIR/rc"
VLT_CONFIG_PATH="$VLT_CONFIG_DIR/vlt.json"
POETRY_CONFIG_PATH="${POETRY_CONFIG_DIR:-$HOME/Library/Application Support/pypoetry}/config.toml"
PDM_CONFIG_PATH="${PDM_CONFIG_FILE:-$HOME/Library/Application Support/pdm/config.toml}"
PIXI_PLATFORM_GLOBAL_MANIFEST_PATH="$HOME/Library/Application Support/pixi/manifests/pixi-global.toml"
# pip ignores XDG_CONFIG_HOME on macOS. It reads a single user file: the first
# existing directory of $XDG_DATA_HOME/pip (pip 26.2+) and
# ~/Library/Application Support/pip, falling back to ~/.config/pip.
if [[ -n "${XDG_DATA_HOME:-}" && -d "$XDG_DATA_HOME/pip" ]]; then
    PIP_CONFIG_PATH="$XDG_DATA_HOME/pip/pip.conf"
elif [[ -d "$HOME/Library/Application Support/pip" ]]; then
    PIP_CONFIG_PATH="$HOME/Library/Application Support/pip/pip.conf"
else
    PIP_CONFIG_PATH="$HOME/.config/pip/pip.conf"
fi

platform_date_days_ago_rfc3339() {
    date -v-"$1"d +%Y-%m-%dT00:00:00Z
}

# macOS schedules the daily vlt refresh with a launchd agent instead of cron.
VLT_REFRESH_SCHEDULER="launchd"

platform_vlt_refresh_script_path() {
    printf '%s\n' "$SCRIPT_DIR/set_package_min_age_macos.sh"
}

source "$SCRIPT_DIR/lib/set_package_min_age_common.sh"

main "$@"
