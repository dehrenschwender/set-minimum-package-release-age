#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=lib/set_package_min_age_ui.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/set_package_min_age_ui.sh"

PLATFORM_NAME="${PLATFORM_NAME:-Unknown}"

# Config locations follow the same environment overrides the tools themselves
# honor. Most of them switch to $XDG_CONFIG_HOME when it is set and then ignore
# the default location, so writing to the default would silently do nothing.
# Platform wrappers set the macOS/Linux-specific defaults before sourcing this.
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
PIP_CONFIG_PATH="${PIP_CONFIG_PATH:-$CONFIG_HOME/pip/pip.conf}"
UV_CONFIG_PATH="${UV_CONFIG_PATH:-$CONFIG_HOME/uv/uv.toml}"
POETRY_CONFIG_PATH="${POETRY_CONFIG_PATH:-${POETRY_CONFIG_DIR:-$CONFIG_HOME/pypoetry}/config.toml}"
NPMRC_PATH="${NPMRC_PATH:-${NPM_CONFIG_USERCONFIG:-${npm_config_userconfig:-$HOME/.npmrc}}}"
PNPM_CONFIG_PATH="${PNPM_CONFIG_PATH:-$CONFIG_HOME/pnpm/config.yaml}"
PNPM_RC_PATH="${PNPM_RC_PATH:-$CONFIG_HOME/pnpm/rc}"
if [[ -z "${BUNFIG_PATH:-}" ]]; then
    if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
        BUNFIG_PATH="$XDG_CONFIG_HOME/.bunfig.toml"
    else
        BUNFIG_PATH="$HOME/.bunfig.toml"
    fi
fi
YARNRC_PATH="${YARNRC_PATH:-$HOME/.yarnrc}"
YARNRC_YML_PATH="${YARNRC_YML_PATH:-$HOME/.yarnrc.yml}"
VLT_CONFIG_PATH="${VLT_CONFIG_PATH:-$CONFIG_HOME/vlt/vlt.json}"
if [[ -z "${BUNDLER_CONFIG_PATH:-}" ]]; then
    if [[ -n "${BUNDLE_USER_CONFIG:-}" ]]; then
        BUNDLER_CONFIG_PATH="$BUNDLE_USER_CONFIG"
    elif [[ -n "${BUNDLE_USER_HOME:-}" ]]; then
        BUNDLER_CONFIG_PATH="$BUNDLE_USER_HOME/config"
    else
        BUNDLER_CONFIG_PATH="$HOME/.bundle/config"
    fi
fi
if [[ -z "${HEX_CONFIG_PATH:-}" ]]; then
    if [[ -n "${HEX_HOME:-}" ]]; then
        HEX_CONFIG_PATH="$HEX_HOME/hex.config"
    elif [[ "${MIX_XDG:-}" == "1" || "${MIX_XDG:-}" == "true" ]]; then
        HEX_CONFIG_PATH="$CONFIG_HOME/hex/hex.config"
    else
        HEX_CONFIG_PATH="$HOME/.hex/hex.config"
    fi
fi
PDM_CONFIG_PATH="${PDM_CONFIG_PATH:-${PDM_CONFIG_FILE:-$CONFIG_HOME/pdm/config.toml}}"
MISE_CONFIG_PATH="${MISE_CONFIG_PATH:-${MISE_GLOBAL_CONFIG_FILE:-${MISE_CONFIG_DIR:-$CONFIG_HOME/mise}/config.toml}}"
if [[ -z "${CARGO_CONFIG_PATH:-}" ]]; then
    # Cargo prefers the legacy extension-less file when only that one exists.
    if [[ -f "${CARGO_HOME:-$HOME/.cargo}/config" && ! -f "${CARGO_HOME:-$HOME/.cargo}/config.toml" ]]; then
        CARGO_CONFIG_PATH="${CARGO_HOME:-$HOME/.cargo}/config"
    else
        CARGO_CONFIG_PATH="${CARGO_HOME:-$HOME/.cargo}/config.toml"
    fi
fi
# pixi uses the first existing manifest among $PIXI_HOME (default ~/.pixi) and the
# platform config dir, and creates it under $PIXI_HOME when none exists yet.
PIXI_PLATFORM_GLOBAL_MANIFEST_PATH="${PIXI_PLATFORM_GLOBAL_MANIFEST_PATH:-$CONFIG_HOME/pixi/manifests/pixi-global.toml}"
if [[ -z "${PIXI_GLOBAL_MANIFEST_PATH:-}" ]]; then
    PIXI_GLOBAL_MANIFEST_PATH="${PIXI_HOME:-$HOME/.pixi}/manifests/pixi-global.toml"
    if [[ ! -f "$PIXI_GLOBAL_MANIFEST_PATH" && -f "$PIXI_PLATFORM_GLOBAL_MANIFEST_PATH" ]]; then
        PIXI_GLOBAL_MANIFEST_PATH="$PIXI_PLATFORM_GLOBAL_MANIFEST_PATH"
    fi
fi
WRAPPER_DIR="$HOME/.config/set-package-min-age"
# How the daily vlt `before` refresh is scheduled: "cron" (Linux) or "launchd"
# (macOS, where writing a crontab needs Full Disk Access and cron skips runs
# missed while the Mac sleeps).
VLT_REFRESH_SCHEDULER="${VLT_REFRESH_SCHEDULER:-cron}"
VLT_LAUNCHD_LABEL="com.set-minimum-package-release-age.vlt-refresh"
VLT_LAUNCHD_PLIST_PATH="${VLT_LAUNCHD_PLIST_PATH:-$HOME/Library/LaunchAgents/$VLT_LAUNCHD_LABEL.plist}"
TOOL_VERSION_TIMEOUT_SECONDS="${TOOL_VERSION_TIMEOUT_SECONDS:-5}"

# Every managed tool key, in report order. Results rows are built from this list.
ALL_TOOL_KEYS=(pip uv uv-cron poetry pdm npm pnpm bun deno pixi yarn-classic yarn-berry vlt vlt-cron bundler hex cargo mise)

REMOVE_MODE=false
REMOVE_SCOPED_MODE=false
CUSTOM_DAYS=""
MIN_AGE_DAYS=7
BACKUP_SUFFIX=""
REMOVE_TOOLS=()
UV_EXCEPTIONS=()
POETRY_EXCEPTIONS=()
POETRY_SOURCE_EXCEPTIONS=()
NPM_EXCEPTIONS=()
PNPM_EXCEPTIONS=()
BUN_EXCEPTIONS=()
YARN_EXCEPTIONS=()
MISE_EXCEPTIONS=()
PIXI_EXCEPTIONS=()
HEX_EXCEPTIONS=()
CARGO_EXCEPTIONS=()
TOOL_DETECTION_CACHE=""
# True while main() collects per-tool results for the summary.
NORMAL_MODE_REPORTING=false
# "apply" or "remove"; selects headings and summary wording.
RUN_MODE="apply"
PREFLIGHT_WARN_TOOLS=()
PREFLIGHT_WARN_DETAILS=()
ROLLBACK_NOTES=()
RESULT_TOOL_KEYS=()
RESULT_CONFIG_STATUSES=()
RESULT_CONFIG_DETAILS=()
RESULT_VALIDATION_STATUSES=()
RESULT_VALIDATION_DETAILS=()
FAILED_TOOLS=()
SKIPPED_TOOLS=()
UPDATED_TOOLS=()
VALIDATED_TOOLS=()
VALIDATION_FAILED_TOOLS=()
PREFLIGHT_FAILED_TOOLS=()
PREFLIGHT_FAILED_DETAILS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [DAYS]

Set a minimum package release age across pip, uv, Poetry, PDM, npm, pnpm, bun, deno, pixi,
yarn, vlt, Bundler, Hex, Cargo, and mise.

Arguments:
  DAYS                    Minimum age in days (default: 7). Accepts "14" or "14d".

Options:
  --exception SPEC        Add a native exception in the form:
                          uv:<package>=false
                          uv:<package>=<duration-or-rfc3339>
                          poetry:<package>
                          poetry-source:<source-name-or-url>
                          npm:<package-or-glob>
                          pnpm:<selector>
                          bun:<package>
                          yarn-berry:<pattern>
                          mise:<tool-or-backend>
                          pixi:<package>[<version-spec>]   (pixi global manifest)
                          hex:<repository>                 (for example hexpm:myorg)
                          cargo:<registry>                 (exempts the whole registry)
  --remove                Remove all settings previously added by this script.
  --remove-tool TOOL      Remove settings only for a specific managed tool. May be provided
                          multiple times.
  -h, --help              Show this help message and exit.

Examples:
  $(basename "$0")                         # Set minimum age to 7 days (default)
  $(basename "$0") 14                      # Set minimum age to 14 days
  $(basename "$0") 1d                      # Set minimum age to 1 day
  $(basename "$0") --exception uv:foo=false 14
  $(basename "$0") --exception poetry:internal-lib --exception npm:'@myorg/*'
  $(basename "$0") --exception pnpm:webpack --exception bun:typescript
  $(basename "$0") --exception yarn-berry:'@myorg/*'
  $(basename "$0") --remove-tool uv --remove-tool uv-cron
  $(basename "$0") --remove                # Remove all settings
EOF
    exit 0
}

array_contains() {
    local needle="$1"
    shift
    local item

    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done

    return 1
}

tool_config_path() {
    case "$1" in
        pip) printf '%s\n' "$PIP_CONFIG_PATH" ;;
        uv) printf '%s\n' "$UV_CONFIG_PATH" ;;
        uv-cron) printf '%s\n' "crontab" ;;
        poetry) printf '%s\n' "$POETRY_CONFIG_PATH" ;;
        npm) printf '%s\n' "$NPMRC_PATH" ;;
        pnpm) pnpm_active_config_path ;;
        bun) printf '%s\n' "$BUNFIG_PATH" ;;
        yarn-classic) printf '%s\n' "$YARNRC_PATH" ;;
        yarn-berry) printf '%s\n' "$YARNRC_YML_PATH" ;;
        deno) printf '%s\n' "$HOME/.config/set-package-min-age/deno.sh" ;;
        pixi) printf '%s\n' "$PIXI_GLOBAL_MANIFEST_PATH" ;;
        vlt) printf '%s\n' "$VLT_CONFIG_PATH" ;;
        vlt-cron)
            if [[ "$VLT_REFRESH_SCHEDULER" == "launchd" ]]; then
                printf '%s\n' "$VLT_LAUNCHD_PLIST_PATH"
            else
                printf '%s\n' "crontab"
            fi
            ;;
        bundler) printf '%s\n' "$BUNDLER_CONFIG_PATH" ;;
        hex) printf '%s\n' "$HEX_CONFIG_PATH" ;;
        pdm) printf '%s\n' "$PDM_CONFIG_PATH" ;;
        cargo) printf '%s\n' "$CARGO_CONFIG_PATH" ;;
        mise) printf '%s\n' "$MISE_CONFIG_PATH" ;;
        *) return 1 ;;
    esac
}

tool_supports_native_exceptions() {
    case "$1" in
        uv|poetry|npm|pnpm|bun|yarn-berry|mise|pixi|hex|cargo) return 0 ;;
        *) return 1 ;;
    esac
}

parse_exception_spec() {
    local spec="$1"
    local target value

    if [[ "$spec" != *:* || "$spec" == :* || "$spec" == *: ]]; then
        echo "Error: --exception must use the format target:value." >&2
        exit 1
    fi

    target=${spec%%:*}
    value=${spec#*:}

    case "$target" in
        uv)
            if [[ "$value" != *=* || "$value" == =* || "$value" == *= ]]; then
                echo "Error: uv exceptions must use package=false or package=<duration-or-rfc3339>." >&2
                exit 1
            fi
            UV_EXCEPTIONS+=("$value")
            ;;
        poetry)
            if [[ -z "$value" ]]; then
                echo "Error: poetry exceptions require a package name." >&2
                exit 1
            fi
            POETRY_EXCEPTIONS+=("$value")
            ;;
        poetry-source)
            if [[ -z "$value" ]]; then
                echo "Error: poetry-source exceptions require a source name or URL." >&2
                exit 1
            fi
            POETRY_SOURCE_EXCEPTIONS+=("$value")
            ;;
        npm)
            if [[ -z "$value" ]]; then
                echo "Error: npm exceptions require a package name or glob." >&2
                exit 1
            fi
            NPM_EXCEPTIONS+=("$value")
            ;;
        pnpm)
            if [[ -z "$value" ]]; then
                echo "Error: pnpm exceptions require a selector." >&2
                exit 1
            fi
            PNPM_EXCEPTIONS+=("$value")
            ;;
        bun)
            if [[ -z "$value" ]]; then
                echo "Error: bun exceptions require a package name." >&2
                exit 1
            fi
            BUN_EXCEPTIONS+=("$value")
            ;;
        yarn-berry)
            if [[ -z "$value" ]]; then
                echo "Error: yarn-berry exceptions require a package pattern." >&2
                exit 1
            fi
            YARN_EXCEPTIONS+=("$value")
            ;;
        mise)
            if [[ -z "$value" ]]; then
                echo "Error: mise exceptions require a tool or backend pattern." >&2
                exit 1
            fi
            MISE_EXCEPTIONS+=("$value")
            ;;
        pixi)
            # <package> exempts every version; <package><spec> (for example
            # polars==1.43.1) exempts only matching versions.
            if ! [[ "$value" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*([=!<>~*].*)?$ ]] || [[ "$value" == *[\"\\]* ]]; then
                echo "Error: pixi exceptions must be <package> or <package><version-spec>, for example polars or polars==1.43.1." >&2
                exit 1
            fi
            PIXI_EXCEPTIONS+=("$value")
            ;;
        hex)
            if [[ -z "$value" || "$value" == *[\"\\,[:space:]]* ]]; then
                echo "Error: hex exceptions require a repository name such as hexpm:myorg." >&2
                exit 1
            fi
            HEX_EXCEPTIONS+=("$value")
            ;;
        cargo)
            if ! [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]]; then
                echo "Error: cargo exceptions require a registry name (letters, digits, - and _)." >&2
                exit 1
            fi
            CARGO_EXCEPTIONS+=("$value")
            ;;
        pip|pdm|yarn-classic|deno|vlt|bundler)
            echo "Error: $target does not support native exceptions." >&2
            exit 1
            ;;
        *)
            echo "Error: Unknown exception target: $target" >&2
            exit 1
            ;;
    esac
}

parse_remove_tool() {
    local tool="$1"

    case "$tool" in
        pip|uv|uv-cron|poetry|pdm|npm|pnpm|bun|deno|pixi|yarn-classic|yarn-berry|vlt|vlt-cron|bundler|hex|cargo|mise)
            ;;
        *)
            echo "Error: Unknown remove tool: $tool" >&2
            exit 1
            ;;
    esac

    if ! array_contains "$tool" "${REMOVE_TOOLS[@]-}"; then
        REMOVE_TOOLS+=("$tool")
    fi
}

parse_args() {
    REMOVE_MODE=false
    REMOVE_SCOPED_MODE=false
    CUSTOM_DAYS=""
    MIN_AGE_DAYS=7
    REMOVE_TOOLS=()
    UV_EXCEPTIONS=()
    POETRY_EXCEPTIONS=()
    POETRY_SOURCE_EXCEPTIONS=()
    NPM_EXCEPTIONS=()
    PNPM_EXCEPTIONS=()
    BUN_EXCEPTIONS=()
    YARN_EXCEPTIONS=()
    MISE_EXCEPTIONS=()
    PIXI_EXCEPTIONS=()
    HEX_EXCEPTIONS=()
    CARGO_EXCEPTIONS=()
    TOOL_DETECTION_CACHE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remove)
                REMOVE_MODE=true
                shift
                ;;
            --exception)
                if [[ $# -lt 2 || -z "${2:-}" ]]; then
                    echo "Error: --exception requires a value." >&2
                    exit 1
                fi
                parse_exception_spec "$2"
                shift 2
                ;;
            --remove-tool)
                if [[ $# -lt 2 || -z "${2:-}" ]]; then
                    echo "Error: --remove-tool requires a value." >&2
                    exit 1
                fi
                REMOVE_SCOPED_MODE=true
                parse_remove_tool "$2"
                shift 2
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

    if [[ "$REMOVE_MODE" == true && "$REMOVE_SCOPED_MODE" == true ]]; then
        echo "Error: --remove cannot be combined with --remove-tool." >&2
        exit 1
    fi

    if [[ ( "$REMOVE_MODE" == true || "$REMOVE_SCOPED_MODE" == true ) && -n "$CUSTOM_DAYS" ]]; then
        echo "Error: removal modes cannot be combined with a days argument." >&2
        exit 1
    fi

    if [[ "$REMOVE_MODE" == true || "$REMOVE_SCOPED_MODE" == true ]]; then
        if [[ ${#UV_EXCEPTIONS[@]} -gt 0 || ${#POETRY_EXCEPTIONS[@]} -gt 0 || ${#POETRY_SOURCE_EXCEPTIONS[@]} -gt 0 || ${#NPM_EXCEPTIONS[@]} -gt 0 || ${#PNPM_EXCEPTIONS[@]} -gt 0 || ${#BUN_EXCEPTIONS[@]} -gt 0 || ${#YARN_EXCEPTIONS[@]} -gt 0 || ${#MISE_EXCEPTIONS[@]} -gt 0 || ${#PIXI_EXCEPTIONS[@]} -gt 0 || ${#HEX_EXCEPTIONS[@]} -gt 0 || ${#CARGO_EXCEPTIONS[@]} -gt 0 ]]; then
            echo "Error: removal modes cannot be combined with --exception." >&2
            exit 1
        fi
    fi

    if [[ -n "$CUSTOM_DAYS" ]]; then
        CUSTOM_DAYS="${CUSTOM_DAYS%d}"
        if ! [[ "$CUSTOM_DAYS" =~ ^[1-9][0-9]*$ ]]; then
            echo "Error: Days must be a positive integer, got: '$CUSTOM_DAYS'" >&2
            exit 1
        fi
        MIN_AGE_DAYS="$CUSTOM_DAYS"
    fi

    BACKUP_SUFFIX=".bak.$(date +%Y%m%d%H%M%S)"
}

result_tool_display_name() {
    case "$1" in
        pip) printf '%s\n' "pip" ;;
        uv) printf '%s\n' "uv" ;;
        uv-cron) printf '%s\n' "uv cron" ;;
        poetry) printf '%s\n' "Poetry" ;;
        npm) printf '%s\n' "npm" ;;
        pnpm) printf '%s\n' "pnpm" ;;
        bun) printf '%s\n' "bun" ;;
        yarn-classic) printf '%s\n' "yarn v1" ;;
        yarn-berry) printf '%s\n' "yarn v2+" ;;
        deno) printf '%s\n' "deno" ;;
        pixi) printf '%s\n' "pixi" ;;
        vlt) printf '%s\n' "vlt" ;;
        vlt-cron) vlt_refresh_display_name ;;
        bundler) printf '%s\n' "Bundler" ;;
        hex) printf '%s\n' "Hex" ;;
        pdm) printf '%s\n' "PDM" ;;
        cargo) printf '%s\n' "Cargo" ;;
        mise) printf '%s\n' "mise" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

init_results_table() {
    local tool_key

    RESULT_TOOL_KEYS=("${ALL_TOOL_KEYS[@]}")
    RESULT_CONFIG_STATUSES=()
    RESULT_CONFIG_DETAILS=()
    RESULT_VALIDATION_STATUSES=()
    RESULT_VALIDATION_DETAILS=()
    for tool_key in "${RESULT_TOOL_KEYS[@]}"; do
        RESULT_CONFIG_STATUSES+=("--")
        RESULT_CONFIG_DETAILS+=("")
        RESULT_VALIDATION_STATUSES+=("--")
        RESULT_VALIDATION_DETAILS+=("")
    done
}

result_row_index() {
    local idx

    for idx in "${!ALL_TOOL_KEYS[@]}"; do
        if [[ "${ALL_TOOL_KEYS[$idx]}" == "$1" ]]; then
            printf '%s\n' "$idx"
            return 0
        fi
    done

    return 1
}

record_result_config() {
    local tool_key="$1"
    local status="$2"
    local detail="$3"
    local idx

    idx=$(result_row_index "$tool_key") || return 1
    RESULT_CONFIG_STATUSES[$idx]="$status"
    RESULT_CONFIG_DETAILS[$idx]="$detail"
}

record_result_validation() {
    local tool_key="$1"
    local status="$2"
    local detail="$3"
    local idx

    idx=$(result_row_index "$tool_key") || return 1
    RESULT_VALIDATION_STATUSES[$idx]="$status"
    RESULT_VALIDATION_DETAILS[$idx]="$detail"
}

emit_config_status() {
    local tool_display="$1"
    local tool_key="$2"
    local status="$3"
    local detail="$4"

    # The legacy uv cron cleanup is only worth a row when it removed something.
    if [[ "$NORMAL_MODE_REPORTING" == true && "$RUN_MODE" == "apply" && "$tool_key" == "uv-cron" && "$status" == "ok" ]]; then
        return 0
    fi

    if [[ "$NORMAL_MODE_REPORTING" == true ]]; then
        record_result_config "$tool_key" "$status" "$detail"
    fi
    ui_change_row "$tool_display" "$status" "$detail"
}

# Validation rows are only printed when something does not match; main() prints
# the overall count afterwards.
emit_validation_status() {
    local tool_display="$1"
    local tool_key="$2"
    local status="$3"
    local detail="$4"

    if [[ "$NORMAL_MODE_REPORTING" == true ]]; then
        record_result_validation "$tool_key" "$status" "$detail"
    fi
    if [[ "$status" == "FAIL" ]]; then
        ui_status_row fail "$tool_display" "mismatch" "$detail"
    fi
}

run_progress_step() {
    local tool_key="$1"
    shift 2

    if tool_is_blocked "$tool_key"; then
        emit_config_status "$(result_tool_display_name "$tool_key")" "$tool_key" "blocked" \
            "$(blocked_tool_reason "$tool_key")"
        return 0
    fi

    "$@"
}

# Counts recorded config results by status, for example "3 added · 1 blocked".
summary_counts_text() {
    local added=0 updated=0 removed=0 unchanged=0 skipped=0 blocked=0 failed=0 status
    local -a parts=()

    for status in "${RESULT_CONFIG_STATUSES[@]-}"; do
        case "$status" in
            added) added=$((added + 1)) ;;
            updated) updated=$((updated + 1)) ;;
            removed) removed=$((removed + 1)) ;;
            ok) unchanged=$((unchanged + 1)) ;;
            skipped) skipped=$((skipped + 1)) ;;
            blocked) blocked=$((blocked + 1)) ;;
            FAIL) failed=$((failed + 1)) ;;
        esac
    done

    [[ $added -eq 0 ]] || parts+=("$added added")
    [[ $updated -eq 0 ]] || parts+=("$updated updated")
    [[ $removed -eq 0 ]] || parts+=("$removed removed")
    [[ $unchanged -eq 0 ]] || parts+=("$unchanged unchanged")
    [[ $skipped -eq 0 ]] || parts+=("$skipped skipped")
    [[ $blocked -eq 0 ]] || parts+=("$blocked blocked")
    parts+=("$failed failed")
    ui_join "${parts[@]}"
}

# Lists the files this run added to, updated, or removed settings from.
print_changed_files() {
    local idx status printed=false

    ui_heading "Changed files"
    for idx in "${!RESULT_TOOL_KEYS[@]}"; do
        status="${RESULT_CONFIG_STATUSES[$idx]}"
        case "$status" in
            added | updated | removed)
                ui_path_row "$(result_tool_display_name "${RESULT_TOOL_KEYS[$idx]}")" "$(tool_config_path "${RESULT_TOOL_KEYS[$idx]}")"
                printed=true
                ;;
        esac
    done
    if [[ "$printed" == false ]]; then
        ui_text "No files changed."
    fi
}

# Blocked tools, rollbacks, validation errors, and warnings, at the very end so
# they are the last thing on screen. Returns 1 when a tool was blocked.
print_needs_attention() {
    local idx name status detail had_items=false
    local name_indent
    name_indent=$(ui_text_column)

    if [[ ${#PREFLIGHT_FAILED_TOOLS[@]} -eq 0 && ${#VALIDATION_FAILED_TOOLS[@]} -eq 0 && ${#PREFLIGHT_WARN_TOOLS[@]} -eq 0 ]] \
        && ! array_contains "FAIL" "${RESULT_CONFIG_STATUSES[@]-}"; then
        return 0
    fi

    ui_heading "Needs attention"

    for idx in "${!PREFLIGHT_FAILED_TOOLS[@]}"; do
        ui_status_row fail "$(result_tool_display_name "${PREFLIGHT_FAILED_TOOLS[$idx]}")" "blocked" "${PREFLIGHT_FAILED_DETAILS[$idx]}"
        ui_note "$name_indent" "Left unchanged. Upgrade it (or drop its --exception) and rerun."
        had_items=true
    done

    for idx in "${!RESULT_TOOL_KEYS[@]}"; do
        status="${RESULT_CONFIG_STATUSES[$idx]}"
        if [[ "$status" == "FAIL" ]]; then
            ui_status_row fail "$(result_tool_display_name "${RESULT_TOOL_KEYS[$idx]}")" "failed" "${RESULT_CONFIG_DETAILS[$idx]}"
            ui_note "$name_indent" "The file was left as it was before this run."
            had_items=true
        fi
    done

    for idx in "${!RESULT_TOOL_KEYS[@]}"; do
        if [[ "${RESULT_VALIDATION_STATUSES[$idx]}" == "FAIL" ]]; then
            ui_status_row fail "$(result_tool_display_name "${RESULT_TOOL_KEYS[$idx]}")" "mismatch" "${RESULT_VALIDATION_DETAILS[$idx]}"
            had_items=true
        fi
    done

    for idx in "${!PREFLIGHT_WARN_TOOLS[@]}"; do
        ui_status_row warn "${PREFLIGHT_WARN_TOOLS[$idx]}" "warning" "${PREFLIGHT_WARN_DETAILS[$idx]}"
        had_items=true
    done

    if [[ ${#PREFLIGHT_FAILED_TOOLS[@]} -gt 0 ]]; then
        printf '\n'
        if [[ ${#PREFLIGHT_FAILED_TOOLS[@]} -eq 1 ]]; then
            ui_text "Exit status 1 because 1 tool is blocked."
        else
            ui_text "Exit status 1 because ${#PREFLIGHT_FAILED_TOOLS[@]} tools are blocked."
        fi
        return 1
    fi
    return 0
}

pip_uploaded_prior_to_value() {
    printf 'P%sD\n' "$MIN_AGE_DAYS"
}

pip_detail_text() {
    local value="$1"
    printf 'uploaded-prior-to = %s (%sd window)' "$value" "$MIN_AGE_DAYS"
}

# Detail for an "updated" row. When the age itself is unchanged, only the
# managed exception lines differed, so say that instead of "X --> X".
format_change_detail() {
    local current="$1"
    local new_value="$2"
    local detail="$3"

    if [[ "$current" == "$new_value" ]]; then
        printf '%s (exceptions changed)' "$detail"
    else
        printf '%s --> %s' "$current" "$detail"
    fi
}

exception_count_suffix() {
    local count="$1"
    local label="$2"

    if [[ "$count" -gt 0 ]]; then
        printf '; %s=%s' "$label" "$count"
        return
    fi

    printf ''
}

# Bash's `type -P` searches PATH for an executable file like `which`, but needs
# no external binary (Fedora and many containers do not ship `which`).
resolve_tool_path() {
    local path=""

    path=$(type -P "$1" 2>/dev/null) || return 1
    [[ -n "$path" ]] || return 1

    printf '%s\n' "$path"
}

extract_semver() {
    local raw="$1"

    if [[ "$raw" =~ ([0-9]+(\.[0-9]+)+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    if [[ "$raw" =~ ^([0-9]+)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

detect_command_version() {
    local tool="$1"
    local path="$2"
    local raw_version=""

    case "$tool" in
        uv)
            raw_version=$(run_command_with_timeout "$path" --version || run_command_with_timeout "$path" self version || true)
            ;;
        *)
            raw_version=$(run_command_with_timeout "$path" --version || true)
            ;;
    esac

    extract_semver "$raw_version" || true
}

# Runs a command with stdout captured and a hard time limit. A one-shot watchdog
# sleeps for the limit and kills the command, so waiting costs no polling and a
# fast command returns immediately. stdin is /dev/null so prompts (for example a
# Corepack download prompt) cannot block. Returns 124 on timeout.
run_command_with_timeout() {
    local output_file command_pid watchdog_pid status

    output_file=$(mktemp "${TMPDIR:-/tmp}/set-package-min-age.XXXXXX")
    "$@" </dev/null >"$output_file" 2>/dev/null &
    command_pid=$!

    (
        trap 'kill "$sleep_pid" 2>/dev/null; exit 0' TERM
        sleep "$TOOL_VERSION_TIMEOUT_SECONDS" &
        sleep_pid=$!
        wait "$sleep_pid"
        kill -0 "$command_pid" 2>/dev/null || exit 0
        : >"$output_file.timeout"
        kill -TERM "$command_pid" 2>/dev/null || exit 0
        sleep 0.2
        kill -KILL "$command_pid" 2>/dev/null || true
    ) </dev/null >/dev/null 2>&1 &
    watchdog_pid=$!

    if wait "$command_pid" 2>/dev/null; then
        status=0
    else
        status=$?
    fi

    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    if [[ -f "$output_file.timeout" ]]; then
        status=124
    fi

    cat "$output_file"
    rm -f "$output_file" "$output_file.timeout"
    return "$status"
}

detect_hex_version() {
    local mix_path="$1"
    local raw_version=""

    raw_version=$(run_command_with_timeout "$mix_path" hex.info) || return 1
    if [[ "$raw_version" =~ Hex:[[:space:]]*([0-9]+(\.[0-9]+)+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    extract_semver "$raw_version" || true
}

# Prints one "label|installed|path|version" row for the first command found.
probe_tool() {
    local label="$1"
    shift
    local cmd tool_path tool_version

    for cmd in "$@"; do
        if tool_path=$(resolve_tool_path "$cmd"); then
            tool_version=$(detect_command_version "$cmd" "$tool_path")
            printf '%s|yes|%s|%s\n' "$label" "$tool_path" "${tool_version:-unknown}"
            return 0
        fi
    done

    printf '%s|no|not found|n/a\n' "$label"
}

probe_hex() {
    local tool_path tool_version

    if tool_path=$(resolve_tool_path "mix"); then
        if tool_version=$(detect_hex_version "$tool_path") && [[ -n "$tool_version" ]]; then
            printf 'Hex|yes|%s|%s\n' "$tool_path" "$tool_version"
        else
            printf 'Hex|no|%s|n/a\n' "$tool_path"
        fi
    else
        printf 'Hex|no|not found|n/a\n'
    fi
}

probe_yarn() {
    local yarn_path yarn_version yarn_major

    if ! yarn_path=$(resolve_tool_path "yarn"); then
        printf 'yarn v1|no|not found|n/a\n'
        printf 'yarn v2+|no|not found|n/a\n'
        return 0
    fi

    yarn_version=$(detect_command_version "yarn" "$yarn_path")
    if [[ "$yarn_version" =~ ^([0-9]+) ]]; then
        yarn_major="${BASH_REMATCH[1]}"
        if [[ "$yarn_major" == "1" ]]; then
            printf 'yarn v1|yes|%s|%s\n' "$yarn_path" "$yarn_version"
            printf 'yarn v2+|no|%s|%s\n' "$yarn_path" "$yarn_version"
            return 0
        fi
        if [[ "$yarn_major" -ge 2 ]]; then
            printf 'yarn v1|no|%s|%s\n' "$yarn_path" "$yarn_version"
            printf 'yarn v2+|yes|%s|%s\n' "$yarn_path" "$yarn_version"
            return 0
        fi
    fi

    printf 'yarn v1|no|%s|%s\n' "$yarn_path" "${yarn_version:-unknown}"
    printf 'yarn v2+|no|%s|%s\n' "$yarn_path" "${yarn_version:-unknown}"
}

# Probes all tools in parallel (total time is roughly the slowest single probe,
# not the sum) and prints their rows in a fixed order.
detect_supported_tool_installations() {
    local probes=(
        "probe_tool pip pip pip3"
        "probe_tool uv uv"
        "probe_tool Poetry poetry"
        "probe_tool PDM pdm"
        "probe_tool npm npm"
        "probe_tool pnpm pnpm"
        "probe_tool bun bun"
        "probe_tool deno deno"
        "probe_tool pixi pixi"
        "probe_tool vlt vlt"
        "probe_tool Bundler bundle"
        "probe_hex"
        "probe_tool Cargo cargo"
        "probe_tool mise mise"
        "probe_yarn"
    )
    local result_dir idx probe

    result_dir=$(mktemp -d "${TMPDIR:-/tmp}/set-package-min-age-detect.XXXXXX")
    for idx in "${!probes[@]}"; do
        probe="${probes[$idx]}"
        # Word splitting is intended: each entry is "function arg...".
        # shellcheck disable=SC2086
        ( $probe >"$result_dir/$idx" ) &
    done
    wait

    for idx in "${!probes[@]}"; do
        cat "$result_dir/$idx" 2>/dev/null || true
    done
    rm -rf "$result_dir"
}

# Callers usually read the cache through $(...), which runs in a subshell, so a
# lazily filled cache would be thrown away and every lookup would re-probe all
# tools. main() fills it once in the parent shell via load_tool_detection_cache.
load_tool_detection_cache() {
    if [[ -z "$TOOL_DETECTION_CACHE" ]]; then
        TOOL_DETECTION_CACHE=$(detect_supported_tool_installations)
    fi
}

get_tool_detection_cache() {
    load_tool_detection_cache
    printf '%s\n' "$TOOL_DETECTION_CACHE"
}

lookup_detected_tool_field() {
    local target_tool="$1"
    local field="$2"
    local tool installed path version

    while IFS='|' read -r tool installed path version; do
        if [[ "$tool" == "$target_tool" ]]; then
            case "$field" in
                installed) printf '%s\n' "$installed" ;;
                path) printf '%s\n' "$path" ;;
                version) printf '%s\n' "$version" ;;
                *) return 1 ;;
            esac
            return 0
        fi
    done <<< "$(get_tool_detection_cache)"

    return 1
}

version_gte() {
    local actual="${1%%[-+]*}"
    local required="${2%%[-+]*}"
    local actual_parts required_parts
    local idx limit actual_part required_part

    IFS='.' read -r -a actual_parts <<< "$actual"
    IFS='.' read -r -a required_parts <<< "$required"

    limit=${#actual_parts[@]}
    if [[ ${#required_parts[@]} -gt $limit ]]; then
        limit=${#required_parts[@]}
    fi

    for ((idx = 0; idx < limit; idx++)); do
        actual_part=${actual_parts[idx]:-0}
        required_part=${required_parts[idx]:-0}

        if ((10#$actual_part > 10#$required_part)); then
            return 0
        fi
        if ((10#$actual_part < 10#$required_part)); then
            return 1
        fi
    done

    return 0
}

pnpm_exception_is_pattern() {
    [[ "$1" == *"*"* ]]
}

pnpm_exception_is_version_selector() {
    local selector="$1"

    if [[ "$selector" == *"||"* ]]; then
        return 0
    fi

    if [[ "$selector" == @* ]]; then
        [[ "$selector" =~ ^@[^/]+/[^@]+@.+$ ]]
        return
    fi

    [[ "$selector" =~ ^[^@[:space:]]+@.+$ ]]
}

pnpm_active_config_is_yaml() {
    local installed version

    installed=$(lookup_detected_tool_field "pnpm" installed 2>/dev/null || printf 'no')
    version=$(lookup_detected_tool_field "pnpm" version 2>/dev/null || printf 'unknown')

    if [[ "$installed" == "yes" && -n "$version" && "$version" != "unknown" ]] \
        && ! version_gte "$version" "11.0.0"; then
        return 1
    fi

    return 0
}

pnpm_active_config_path() {
    if pnpm_active_config_is_yaml; then
        printf '%s\n' "$PNPM_CONFIG_PATH"
        return
    fi

    printf '%s\n' "$PNPM_RC_PATH"
}

pnpm_active_config_label() {
    if pnpm_active_config_is_yaml; then
        printf '%s\n' "config.yaml"
        return
    fi

    printf '%s\n' "legacy rc"
}

record_preflight_ok() {
    local tool="$1"
    local installed="$2"
    local version="$3"
    local path="$4"
    ui_tool_row changed "$tool" "$version" "$path"
}

# Tools that are not installed are collected and listed on one line by
# print_not_installed_tools, so they don't take a row each.
record_preflight_skip() {
    local tool="$1"
    local installed="$2"
    local version="$3"
    local path="$4"
    local detail="$5"

    if [[ "$installed" != "yes" ]]; then
        if ! array_contains "$tool" "${UI_NOT_INSTALLED[@]-}"; then
            UI_NOT_INSTALLED+=("$tool")
        fi
        return 0
    fi
    ui_tool_row skip "$tool" "$version" "$path" "$detail"
}

record_preflight_warn() {
    local tool="$1"
    local installed="$2"
    local version="$3"
    local path="$4"
    local detail="$5"
    ui_tool_row warn "$tool" "$version" "$path" "$detail"
    PREFLIGHT_WARN_TOOLS+=("$tool")
    PREFLIGHT_WARN_DETAILS+=("$detail (installed: $version)")
}

record_preflight_fail() {
    local tool="$1"
    local installed="$2"
    local version="$3"
    local path="$4"
    local detail="$5"
    local tool_key="${6:-$tool}"
    ui_tool_row fail "$tool" "$version" "$path" "$detail; blocked, other tools continue"
    PREFLIGHT_FAILED_TOOLS+=("$tool_key")
    PREFLIGHT_FAILED_DETAILS+=("$detail (installed: $version)")
}

print_not_installed_tools() {
    if [[ ${#UI_NOT_INSTALLED[@]} -eq 0 ]]; then
        return 0
    fi
    local list="" tool
    for tool in "${UI_NOT_INSTALLED[@]}"; do
        list+="${list:+, }$tool"
    done
    ui_bullet skip "Not installed: ${list}. Their settings are still written for when you install them."
}

# A tool whose preflight failed is "blocked": its config is left untouched while
# every other tool is still configured, and the run exits non-zero at the end.
tool_is_blocked() {
    array_contains "$1" "${PREFLIGHT_FAILED_TOOLS[@]-}"
}

blocked_tool_reason() {
    local idx

    for idx in "${!PREFLIGHT_FAILED_TOOLS[@]}"; do
        if [[ "${PREFLIGHT_FAILED_TOOLS[$idx]}" == "$1" ]]; then
            printf '%s\n' "${PREFLIGHT_FAILED_DETAILS[$idx]}"
            return 0
        fi
    done
}

ensure_tool_version() {
    local tool="$1"
    local required="$2"
    local feature="$3"
    local fail_key="${4:-$tool}"
    local installed version path

    installed=$(lookup_detected_tool_field "$tool" installed)
    version=$(lookup_detected_tool_field "$tool" version)
    path=$(lookup_detected_tool_field "$tool" path)

    if [[ "$installed" != "yes" ]]; then
        record_preflight_skip "$tool" "$installed" "$version" "$path" "$feature skipped; tool not installed"
        return 0
    fi

    if [[ -z "$version" || "$version" == "unknown" ]]; then
        record_preflight_fail "$tool" "$installed" "$version" "$path" "$feature requires version detection; installed version could not be determined" "$fail_key"
        return 1
    fi

    if version_gte "$version" "$required"; then
        record_preflight_ok "$tool" "$installed" "$version" "$path" "$feature requires >= $required"
        return 0
    fi

    record_preflight_fail "$tool" "$installed" "$version" "$path" "$feature requires >= $required" "$fail_key"
    return 1
}

print_tool_overview() {
    load_tool_detection_cache
    local tool installed path version

    UI_NOT_INSTALLED=()
    ui_heading "Tools"
    while IFS='|' read -r tool installed path version; do
        if [[ "$installed" == "yes" ]]; then
            ui_tool_row changed "$tool" "$version" "$path"
        elif ! array_contains "$tool" "${UI_NOT_INSTALLED[@]-}"; then
            UI_NOT_INSTALLED+=("$tool")
        fi
    done < <(get_tool_detection_cache)
    if [[ ${#UI_NOT_INSTALLED[@]} -gt 0 ]]; then
        local list="" item
        for item in "${UI_NOT_INSTALLED[@]}"; do
            list+="${list:+, }$item"
        done
        ui_bullet skip "Not installed: ${list}."
    fi
}

backup_if_exists() {
    local file="$1"
    if [[ -f "$file" && -s "$file" ]]; then
        cp "$file" "${file}${BACKUP_SUFFIX}"
    fi
}

# Prints the non-empty lines that differ between two files, without diff markers.
# Uses unified output (-U0): BusyBox diff (Alpine) has no classic "<"/">" format,
# so parsing that would see no changes and never roll back.
changed_lines() {
    diff -U0 "$1" "$2" 2>/dev/null | awk '
        NR > 2 && /^[-+]/ {
            line = substr($0, 2)
            sub(/^[[:space:]]+/, "", line)
            if (line != "") {
                print line
            }
        }
    ' || true
}

verify_file_changes() {
    local file="$1"
    local expected_pattern="$2"
    local backup="${file}${BACKUP_SUFFIX}"

    if [[ ! -f "$backup" ]]; then
        return 0
    fi

    local diff_output
    diff_output=$(diff "$backup" "$file" 2>/dev/null || true)

    if [[ -z "$diff_output" ]]; then
        rm -f "$backup"
        return 0
    fi

    local content_lines
    content_lines=$(changed_lines "$backup" "$file")

    if [[ -z "$content_lines" ]]; then
        rm -f "$backup"
        return 0
    fi

    local unexpected
    unexpected=$(printf '%s\n' "$content_lines" | grep -v "$expected_pattern" || true)

    if [[ -n "$unexpected" ]]; then
        local line
        ui_init
        ui_note 6 "Unexpected changes in $(ui_shorten_path "$file" 60); the backup was restored:" "$UI_C_RED"
        printf '%s\n' "$diff_output" | while IFS= read -r line; do
            ui_note 8 "$line"
        done
        cp "$backup" "$file"
        rm -f "$backup"
        return 1
    fi

    rm -f "$backup"
    return 0
}

verify_and_finalize() {
    local file="$1"
    local tool_name="$2"
    local expected_pattern="$3"

    if verify_file_changes "$file" "$expected_pattern"; then
        UPDATED_TOOLS+=("$tool_name")
        return 0
    fi

    FAILED_TOOLS+=("$tool_name")
    return 1
}

ensure_file_exists() {
    local file="$1"
    mkdir -p "$(dirname "$file")"
    touch "$file"
}

write_file_from_command() {
    local file="$1"
    shift
    local tmp
    tmp=$(mktemp)
    "$@" > "$tmp"
    mv "$tmp" "$file"
}

replace_or_append_line() {
    local file="$1"
    local match_regex="$2"
    local line="$3"

    write_file_from_command "$file" awk -v match_regex="$match_regex" -v replacement="$line" '
        BEGIN { replaced = 0 }
        $0 ~ match_regex {
            if (!replaced) {
                print replacement
                replaced = 1
            }
            next
        }
        { print }
        END {
            if (!replaced) {
                print replacement
            }
        }
    ' "$file"
}

remove_matching_lines() {
    local file="$1"
    local match_regex="$2"

    write_file_from_command "$file" awk -v match_regex="$match_regex" '
        $0 ~ match_regex { next }
        { print }
    ' "$file"
}

remove_yaml_top_level_key() {
    local file="$1"
    local key="$2"

    write_file_from_command "$file" awk -v key="$key" '
        $0 ~ "^" key ":[[:space:]]*" {
            skip = 1
            next
        }
        skip && $0 ~ /^[^[:space:]#][^:]*:/ {
            skip = 0
        }
        skip { next }
        { print }
    ' "$file"
}

upsert_yaml_scalar() {
    local file="$1"
    local key="$2"
    local value="$3"

    remove_yaml_top_level_key "$file" "$key"
    printf '%s: %s\n' "$key" "$value" >> "$file"
}

upsert_yaml_array() {
    local file="$1"
    local key="$2"
    shift 2
    local item

    remove_yaml_top_level_key "$file" "$key"
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    printf '%s: %s\n' "$key" "$(yaml_flow_array "$@")" >> "$file"
}

# Replaces the key in [section] or adds it at the end of that section, before
# any blank lines that separate it from the next section.
upsert_line_in_section() {
    local file="$1"
    local section_line="$2"
    local key_regex="$3"
    local line="$4"

    write_file_from_command "$file" awk \
        -v section_line="$section_line" \
        -v key_regex="$key_regex" \
        -v replacement="$line" '
        BEGIN {
            in_section = 0
            section_found = 0
            key_written = 0
            blanks = ""
        }
        function flush_blanks() {
            printf "%s", blanks
            blanks = ""
        }
        function finish_section() {
            if (in_section && !key_written) {
                print replacement
                key_written = 1
            }
            flush_blanks()
            in_section = 0
        }
        $0 == section_line {
            section_found = 1
            in_section = 1
            key_written = 0
            print
            next
        }
        in_section && /^\[/ {
            finish_section()
            print
            next
        }
        in_section && /^[[:space:]]*$/ {
            blanks = blanks $0 "\n"
            next
        }
        in_section && $0 ~ key_regex {
            flush_blanks()
            if (!key_written) {
                print replacement
                key_written = 1
            }
            next
        }
        in_section {
            flush_blanks()
            print
            next
        }
        { print }
        END {
            if (in_section) {
                finish_section()
            }
            if (!section_found) {
                print ""
                print section_line
                print replacement
            }
        }
    ' "$file"
}

section_has_content() {
    local file="$1"
    local section_line="$2"
    local line

    line=$(awk -v section_line="$section_line" '
        $0 == section_line { in_section = 1; next }
        in_section && /^\[/ { exit }
        in_section && $0 !~ /^[[:space:]]*$/ { print; exit }
    ' "$file")

    [[ -n "$line" ]]
}

strip_file_if_whitespace_only() {
    local file="$1"
    if [[ -f "$file" ]] && ! grep -q '[^[:space:]]' "$file" 2>/dev/null; then
        : > "$file"
    fi
}

cleanup_empty_file() {
    local file="$1"
    if [[ -f "$file" ]] && ! grep -q '[^[:space:]]' "$file" 2>/dev/null; then
        rm -f "$file"
    fi
}

cleanup_yaml_marker_only_file() {
    local file="$1"
    if [[ -f "$file" ]] && ! grep -vE '^[[:space:]]*(---)?[[:space:]]*$' "$file" >/dev/null 2>&1; then
        rm -f "$file"
    fi
}

toml_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

yaml_quote() {
    local value="$1"
    value=${value//\'/\'\'}
    printf "'%s'" "$value"
}

yaml_flow_array() {
    local result="["
    local index=0
    local item
    for item in "$@"; do
        if [[ $index -gt 0 ]]; then
            result+=", "
        fi
        result+="$(yaml_quote "$item")"
        index=$((index + 1))
    done
    result+="]"
    printf '%s' "$result"
}

json_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

json_flow_array() {
    local result="["
    local index=0
    local item
    for item in "$@"; do
        if [[ $index -gt 0 ]]; then
            result+=", "
        fi
        result+="$(json_quote "$item")"
        index=$((index + 1))
    done
    result+="]"
    printf '%s' "$result"
}

shell_quote() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

upsert_vlt_before_config() {
    local file="$1"
    local before_date="$2"

    write_file_from_command "$file" awk -v before_date="$before_date" '
        function print_before_line(indent, comma) {
            print indent "\"before\": \"" before_date "\"" comma
        }
        {
            lines[NR] = $0
            if (!config_start && match($0, /^[[:space:]]*"config"[[:space:]]*:[[:space:]]*\{/)) {
                config_start = NR
                config_indent = substr($0, 1, index($0, "\"") - 1)
                config_child_indent = config_indent "  "
            } else if (config_start && !config_end && NR > config_start && $0 ~ "^" config_indent "}[,]?[[:space:]]*$") {
                config_end = NR
            }
            if (config_start && !config_end && NR > config_start && $0 ~ /^[[:space:]]*"before"[[:space:]]*:/) {
                before_line = NR
            }
            if ($0 ~ /^[[:space:]]*}[,]?[[:space:]]*$/) {
                root_end = NR
            }
        }
        END {
            if (NR == 0) {
                print "{"
                print "  \"config\": {"
                print_before_line("    ", "")
                print "  }"
                print "}"
                exit
            }

            if (before_line) {
                for (i = 1; i <= NR; i++) {
                    if (i == before_line) {
                        comma = lines[i] ~ /,[[:space:]]*$/ ? "," : ""
                        print_before_line(config_child_indent, comma)
                    } else {
                        print lines[i]
                    }
                }
                exit
            }

            if (config_start && config_end) {
                has_config_items = 0
                for (i = config_start + 1; i < config_end; i++) {
                    if (lines[i] !~ /^[[:space:]]*$/) {
                        has_config_items = 1
                    }
                }
                for (i = 1; i <= NR; i++) {
                    if (i == config_start) {
                        print lines[i]
                        print_before_line(config_child_indent, has_config_items ? "," : "")
                        continue
                    }
                    print lines[i]
                }
                exit
            }

            if (root_end) {
                has_top_items = 0
                for (i = 1; i < root_end; i++) {
                    if (lines[i] !~ /^[[:space:]]*$/ && lines[i] !~ /^[[:space:]]*\{[[:space:]]*$/) {
                        has_top_items = 1
                    }
                }
                for (i = 1; i <= NR; i++) {
                    if (i == 1 && lines[i] ~ /^[[:space:]]*\{[[:space:]]*$/) {
                        print lines[i]
                        print "  \"config\": {"
                        print_before_line("    ", "")
                        print "  }" (has_top_items ? "," : "")
                        continue
                    }
                    print lines[i]
                }
                exit
            }

            for (i = 1; i <= NR; i++) {
                print lines[i]
            }
        }
    ' "$file"
}

remove_vlt_before_config() {
    local file="$1"

    write_file_from_command "$file" awk '
        function strip_comma(line) {
            sub(/,[[:space:]]*$/, "", line)
            return line
        }
        {
            lines[NR] = $0
            if (!config_start && match($0, /^[[:space:]]*"config"[[:space:]]*:[[:space:]]*\{/)) {
                config_start = NR
                config_indent = substr($0, 1, index($0, "\"") - 1)
            } else if (config_start && !config_end && NR > config_start && $0 ~ "^" config_indent "}[,]?[[:space:]]*$") {
                config_end = NR
            }
            if (config_start && !config_end && NR > config_start && $0 ~ /^[[:space:]]*"before"[[:space:]]*:/) {
                before_line = NR
            }
        }
        END {
            if (!before_line) {
                for (i = 1; i <= NR; i++) {
                    print lines[i]
                }
                exit
            }

            has_other_config = 0
            for (i = config_start + 1; i < config_end; i++) {
                if (i != before_line && lines[i] !~ /^[[:space:]]*$/) {
                    has_other_config = 1
                }
            }

            has_other_top = 0
            for (i = 1; i <= NR; i++) {
                if (i >= config_start && i <= config_end) {
                    continue
                }
                if (lines[i] !~ /^[[:space:]]*[{}][,]?[[:space:]]*$/ && lines[i] !~ /^[[:space:]]*$/) {
                    has_other_top = 1
                }
            }

            if (!has_other_config && !has_other_top) {
                exit
            }

            if (!has_other_config) {
                prev = 0
                following = 0
                for (i = config_start - 1; i >= 1; i--) {
                    if (lines[i] !~ /^[[:space:]]*$/ && lines[i] !~ /^[[:space:]]*\{[[:space:]]*$/) {
                        prev = i
                        break
                    }
                }
                for (i = config_end + 1; i <= NR; i++) {
                    if (lines[i] !~ /^[[:space:]]*$/ && lines[i] !~ /^[[:space:]]*}[,]?[[:space:]]*$/) {
                        following = i
                        break
                    }
                }
                if (prev && !following) {
                    lines[prev] = strip_comma(lines[prev])
                }
                for (i = 1; i <= NR; i++) {
                    if (i >= config_start && i <= config_end) {
                        continue
                    }
                    print lines[i]
                }
                exit
            }

            prev = 0
            following = 0
            for (i = config_start + 1; i < before_line; i++) {
                if (lines[i] !~ /^[[:space:]]*$/) {
                    prev = i
                }
            }
            for (i = before_line + 1; i < config_end; i++) {
                if (lines[i] !~ /^[[:space:]]*$/) {
                    following = i
                    break
                }
            }
            if (prev && !following) {
                lines[prev] = strip_comma(lines[prev])
            }
            for (i = 1; i <= NR; i++) {
                if (i == before_line) {
                    continue
                }
                print lines[i]
            }
        }
    ' "$file"
}

toml_array() {
    local result="["
    local index=0
    local item
    for item in "$@"; do
        if [[ $index -gt 0 ]]; then
            result+=", "
        fi
        result+="$(toml_quote "$item")"
        index=$((index + 1))
    done
    result+="]"
    printf '%s' "$result"
}

build_uv_exception_line() {
    local line="exclude-newer-package = { "
    local index=0
    local rule package_name package_value

    for rule in "${UV_EXCEPTIONS[@]}"; do
        package_name=${rule%%=*}
        package_value=${rule#*=}
        if [[ $index -gt 0 ]]; then
            line+=", "
        fi
        line+="$(toml_quote "$package_name") = "
        if [[ "$package_value" == "false" ]]; then
            line+="false"
        else
            line+="$(toml_quote "$package_value")"
        fi
        index=$((index + 1))
    done

    line+=" }"
    printf '%s' "$line"
}

current_lines_or_empty() {
    local file="$1"
    local match_regex="$2"
    grep "$match_regex" "$file" 2>/dev/null || true
}

# Blocked tools were not configured, so their existing files are not judged.
record_validation_blocked() {
    local tool_display="$1"
    local tool_key="$2"

    if ! tool_is_blocked "$tool_key"; then
        return 1
    fi
    emit_validation_status "$tool_display" "$tool_key" "blocked" "not validated"
}

record_validation_ok() {
    local tool_display="$1"
    local detail="$2"
    local tool_key="${3:-$tool_display}"
    record_validation_blocked "$tool_display" "$tool_key" && return 0
    emit_validation_status "$tool_display" "$tool_key" "ok" "$detail"
    VALIDATED_TOOLS+=("$tool_key")
}

record_validation_fail() {
    local tool_display="$1"
    local detail="$2"
    local tool_key="${3:-$tool_display}"
    record_validation_blocked "$tool_display" "$tool_key" && return 0
    emit_validation_status "$tool_display" "$tool_key" "FAIL" "$detail"
    VALIDATION_FAILED_TOOLS+=("$tool_key")
}

record_validation_skip() {
    local tool_display="$1"
    local detail="$2"
    local tool_key="${3:-$tool_display}"
    record_validation_blocked "$tool_display" "$tool_key" && return 0
    emit_validation_status "$tool_display" "$tool_key" "--" "$detail"
}

date_days_ago_rfc3339() {
    if declare -F platform_date_days_ago_rfc3339 >/dev/null; then
        platform_date_days_ago_rfc3339 "$1"
        return
    fi
    date -d "$1 days ago" +%Y-%m-%dT00:00:00Z
}

run_preflight_checks() {
    load_tool_detection_cache
    local status=0
    local required_pnpm_version="10.16.0"
    local pnpm_feature="minimum-release-age"
    local selector
    local installed version path

    PREFLIGHT_FAILED_TOOLS=()
    PREFLIGHT_FAILED_DETAILS=()

    ensure_tool_version "pip" "26.1.0" "uploaded-prior-to duration" || status=1

    if [[ ${#UV_EXCEPTIONS[@]} -gt 0 ]]; then
        ensure_tool_version "uv" "0.9.25" "exclude-newer-package overrides" || status=1
    else
        ensure_tool_version "uv" "0.9.17" "relative exclude-newer" || status=1
    fi

    installed=$(lookup_detected_tool_field "Poetry" installed)
    version=$(lookup_detected_tool_field "Poetry" version)
    path=$(lookup_detected_tool_field "Poetry" path)
    if [[ "$installed" == "yes" ]]; then
        if [[ -z "$version" || "$version" == "unknown" ]]; then
            record_preflight_fail "Poetry" "$installed" "$version" "$path" "solver.min-release-age requires version detection; installed version could not be determined" "poetry"
            status=1
        elif version_gte "$version" "2.4.0"; then
            record_preflight_ok "Poetry" "$installed" "$version" "$path" "solver.min-release-age requires >= 2.4.0"
        else
            record_preflight_fail "Poetry" "$installed" "$version" "$path" "solver.min-release-age requires >= 2.4.0" "poetry"
            status=1
        fi
    else
        record_preflight_skip "Poetry" "$installed" "$version" "$path" "not installed; config can still be written"
    fi

    ensure_tool_version "PDM" "2.27.0" "strategy.exclude-newer" "pdm" || status=1

    if [[ ${#NPM_EXCEPTIONS[@]} -gt 0 ]]; then
        ensure_tool_version "npm" "11.17.0" "min-release-age-exclude" || status=1
    else
        ensure_tool_version "npm" "11.10.0" "min-release-age" || status=1
    fi

    for selector in "${PNPM_EXCEPTIONS[@]-}"; do
        if pnpm_exception_is_version_selector "$selector"; then
            required_pnpm_version="10.19.0"
            pnpm_feature="minimum-release-age exceptions"
            break
        fi
        if pnpm_exception_is_pattern "$selector"; then
            required_pnpm_version="10.17.0"
            pnpm_feature="minimum-release-age exceptions"
        fi
    done

    ensure_tool_version "pnpm" "$required_pnpm_version" "$pnpm_feature" || status=1


    installed=$(lookup_detected_tool_field "bun" installed)
    version=$(lookup_detected_tool_field "bun" version)
    path=$(lookup_detected_tool_field "bun" path)
    if [[ "$installed" == "yes" ]]; then
        if [[ -z "$version" || "$version" == "unknown" ]]; then
            record_preflight_fail "bun" "$installed" "$version" "$path" "minimumReleaseAge requires version detection; installed version could not be determined" "bun"
            status=1
        elif version_gte "$version" "1.3.0"; then
            record_preflight_ok "bun" "$installed" "$version" "$path" "minimumReleaseAge requires >= 1.3.0"
        else
            record_preflight_fail "bun" "$installed" "$version" "$path" "minimumReleaseAge requires >= 1.3.0" "bun"
            status=1
        fi
    else
        record_preflight_skip "bun" "$installed" "$version" "$path" "not installed; config can still be written"
    fi

    installed=$(lookup_detected_tool_field "vlt" installed)
    version=$(lookup_detected_tool_field "vlt" version)
    path=$(lookup_detected_tool_field "vlt" path)
    if [[ "$installed" == "yes" ]]; then
        record_preflight_ok "vlt" "$installed" "$version" "$path" "before config supported; no documented minimum version"
    else
        record_preflight_skip "vlt" "$installed" "$version" "$path" "not installed; config can still be written"
    fi

    installed=$(lookup_detected_tool_field "Bundler" installed)
    version=$(lookup_detected_tool_field "Bundler" version)
    path=$(lookup_detected_tool_field "Bundler" path)
    if [[ "$installed" == "yes" ]]; then
        if [[ -z "$version" || "$version" == "unknown" ]]; then
            record_preflight_warn "Bundler" "$installed" "$version" "$path" "cooldown requires version detection; config can still be written"
        elif version_gte "$version" "4.0.13"; then
            record_preflight_ok "Bundler" "$installed" "$version" "$path" "cooldown requires >= 4.0.13"
        else
            record_preflight_warn "Bundler" "$installed" "$version" "$path" "cooldown requires >= 4.0.13; config can still be written"
        fi
    else
        record_preflight_skip "Bundler" "$installed" "$version" "$path" "not installed; config can still be written"
    fi

    installed=$(lookup_detected_tool_field "yarn v1" installed)
    version=$(lookup_detected_tool_field "yarn v1" version)
    path=$(lookup_detected_tool_field "yarn v1" path)
    if [[ "$installed" == "yes" ]]; then
        record_preflight_ok "yarn v1" "$installed" "$version" "$path" "cache-min workaround; no native age gate"
    else
        record_preflight_skip "yarn v1" "$installed" "$version" "$path" "not installed"
    fi

    installed=$(lookup_detected_tool_field "yarn v2+" installed)
    version=$(lookup_detected_tool_field "yarn v2+" version)
    path=$(lookup_detected_tool_field "yarn v2+" path)
    if [[ "$installed" == "yes" ]]; then
        if [[ -z "$version" || "$version" == "unknown" ]]; then
            record_preflight_fail "yarn v2+" "$installed" "$version" "$path" "npmMinimalAgeGate requires version detection; installed version could not be determined" "yarn-berry"
            status=1
        elif version_gte "$version" "4.10.0"; then
            record_preflight_ok "yarn v2+" "$installed" "$version" "$path" "npmMinimalAgeGate requires >= 4.10.0"
        else
            record_preflight_fail "yarn v2+" "$installed" "$version" "$path" "npmMinimalAgeGate requires >= 4.10.0" "yarn-berry"
            status=1
        fi
    else
        record_preflight_skip "yarn v2+" "$installed" "$version" "$path" "not installed; config may still be written"
    fi

    ensure_tool_version "deno" "2.6.0" "minimumDependencyAge" || status=1
    # Older pixi rejects unknown manifest keys, so setup_pixi skips instead of writing.
    installed=$(lookup_detected_tool_field "pixi" installed)
    version=$(lookup_detected_tool_field "pixi" version)
    path=$(lookup_detected_tool_field "pixi" path)
    if [[ "$installed" != "yes" ]]; then
        record_preflight_skip "pixi" "$installed" "$version" "$path" "not installed; pixi global manifest skipped"
    elif [[ -n "$version" && "$version" != "unknown" ]] && version_gte "$version" "$PIXI_GLOBAL_EXCLUDE_NEWER_MIN_VERSION"; then
        record_preflight_ok "pixi" "$installed" "$version" "$path" "pixi global exclude-newer requires >= $PIXI_GLOBAL_EXCLUDE_NEWER_MIN_VERSION"
    else
        record_preflight_warn "pixi" "$installed" "$version" "$path" "pixi global exclude-newer requires >= $PIXI_GLOBAL_EXCLUDE_NEWER_MIN_VERSION; will be skipped"
    fi

    installed=$(lookup_detected_tool_field "Hex" installed)
    version=$(lookup_detected_tool_field "Hex" version)
    path=$(lookup_detected_tool_field "Hex" path)
    if [[ "$installed" == "yes" ]]; then
        if [[ -z "$version" || "$version" == "unknown" ]]; then
            record_preflight_fail "Hex" "$installed" "$version" "$path" "cooldown requires version detection; installed version could not be determined" "hex"
            status=1
        elif version_gte "$version" "2.5.0"; then
            record_preflight_ok "Hex" "$installed" "$version" "$path" "cooldown requires >= 2.5.0"
        else
            record_preflight_fail "Hex" "$installed" "$version" "$path" "cooldown requires >= 2.5.0" "hex"
            status=1
        fi
    else
        record_preflight_skip "Hex" "$installed" "$version" "$path" "not installed; config can still be written"
    fi

    # Cargo silently ignores the key before 1.100, so older installs only warn.
    installed=$(lookup_detected_tool_field "Cargo" installed)
    version=$(lookup_detected_tool_field "Cargo" version)
    path=$(lookup_detected_tool_field "Cargo" path)
    if [[ "$installed" == "yes" ]]; then
        if [[ -z "$version" || "$version" == "unknown" ]]; then
            record_preflight_warn "Cargo" "$installed" "$version" "$path" "global-min-publish-age requires version detection; config can still be written"
        elif version_gte "$version" "1.100.0"; then
            record_preflight_ok "Cargo" "$installed" "$version" "$path" "global-min-publish-age requires >= 1.100.0"
        else
            record_preflight_warn "Cargo" "$installed" "$version" "$path" "global-min-publish-age requires >= 1.100.0; config can still be written"
        fi
    else
        record_preflight_skip "Cargo" "$installed" "$version" "$path" "not installed; config can still be written"
    fi

    if [[ ${#MISE_EXCEPTIONS[@]} -gt 0 ]]; then
        ensure_tool_version "mise" "2026.6.2" "minimum_release_age_excludes" || status=1
    else
        ensure_tool_version "mise" "2026.4.22" "minimum_release_age" || status=1
    fi

    return "$status"
}

run_remove_tools() {
    local tool

    for tool in "$@"; do
        case "$tool" in
            pip) remove_pip ;;
            uv) remove_uv ;;
            uv-cron) remove_cron_uv ;;
            poetry) remove_poetry ;;
            npm) remove_npm ;;
            pnpm) remove_pnpm ;;
            bun) remove_bun ;;
            yarn-classic) remove_yarn_classic ;;
            yarn-berry) remove_yarn_berry ;;
            deno) remove_deno ;;
            pixi) remove_pixi ;;
            vlt) remove_vlt ;;
            vlt-cron) remove_cron_vlt ;;
            bundler) remove_bundler ;;
            hex) remove_hex ;;
            pdm) remove_pdm ;;
            cargo) remove_cargo ;;
            mise) remove_mise ;;
        esac
    done
}

setup_pip() {
    local pip_conf="$PIP_CONFIG_PATH"
    local pip_conf_dir
    pip_conf_dir=$(dirname "$pip_conf")
    local uploaded_prior_to desired_line detail status current current_value

    uploaded_prior_to=$(pip_uploaded_prior_to_value)
    desired_line="uploaded-prior-to = ${uploaded_prior_to}"
    detail=$(pip_detail_text "$uploaded_prior_to")

    mkdir -p "$pip_conf_dir"

    if grep -q "^${desired_line}$" "$pip_conf" 2>/dev/null \
        && ! grep -q '^[[:space:]]*min-age[[:space:]]*=' "$pip_conf" 2>/dev/null; then
        emit_config_status "pip" "pip" "ok" "$detail"
        SKIPPED_TOOLS+=("pip")
        return 0
    fi

    backup_if_exists "$pip_conf"
    ensure_file_exists "$pip_conf"

    status="added"
    if grep -q '^[[:space:]]*uploaded-prior-to[[:space:]]*=' "$pip_conf" 2>/dev/null; then
        current_value=$(grep '^[[:space:]]*uploaded-prior-to[[:space:]]*=' "$pip_conf" | sed -n 1p | sed 's/.*= *//')
        status="updated"
        detail="${current_value} --> ${detail}"
    elif grep -q '^[[:space:]]*min-age[[:space:]]*=' "$pip_conf" 2>/dev/null; then
        current=$(grep '^[[:space:]]*min-age[[:space:]]*=' "$pip_conf" | sed -n 1p | sed 's/.*= *//')
        status="updated"
        detail="min-age = ${current} --> ${detail}"
    fi

    upsert_line_in_section "$pip_conf" "[install]" '^[[:space:]]*uploaded-prior-to[[:space:]]*=' "$desired_line"
    remove_matching_lines "$pip_conf" '^[[:space:]]*min-age[[:space:]]*='
    if grep -q '^\[global\]' "$pip_conf" 2>/dev/null && ! section_has_content "$pip_conf" "[global]"; then
        remove_matching_lines "$pip_conf" '^\\[global\\]$'
    fi

    if verify_and_finalize "$pip_conf" "pip" 'uploaded-prior-to\|min-age\|\[install\]\|\[global\]'; then
        emit_config_status "pip" "pip" "$status" "$detail"
    else
        emit_config_status "pip" "pip" "FAIL" "$detail"
    fi
}

setup_uv() {
    local uv_conf="$UV_CONFIG_PATH"
    local uv_conf_dir
    uv_conf_dir=$(dirname "$uv_conf")
    local exclude_newer_value desired_exception_line current_exceptions desired_exceptions detail status current

    exclude_newer_value="P${MIN_AGE_DAYS}D"
    desired_exceptions=""
    if [[ ${#UV_EXCEPTIONS[@]} -gt 0 ]]; then
        desired_exceptions=$(build_uv_exception_line)
    fi

    mkdir -p "$uv_conf_dir"
    touch "$uv_conf"

    current_exceptions=$(current_lines_or_empty "$uv_conf" '^exclude-newer-package[[:space:]]*=')
    if grep -q "^exclude-newer = \"${exclude_newer_value}\"$" "$uv_conf" 2>/dev/null \
        && [[ "$current_exceptions" == "$desired_exceptions" ]]; then
        emit_config_status "uv" "uv" "ok" "exclude-newer = \"${exclude_newer_value}\"$(exception_count_suffix "${#UV_EXCEPTIONS[@]}" "exceptions")"
        SKIPPED_TOOLS+=("uv")
        return 0
    fi

    backup_if_exists "$uv_conf"

    status="added"
    detail="exclude-newer = \"${exclude_newer_value}\"$(exception_count_suffix "${#UV_EXCEPTIONS[@]}" "exceptions")"
    if grep -q '^exclude-newer[[:space:]]*=' "$uv_conf" 2>/dev/null; then
        current=$(grep '^exclude-newer[[:space:]]*=' "$uv_conf" | sed -n 1p | sed 's/.*= *//')
        status="updated"
        detail=$(format_change_detail "$current" "\"${exclude_newer_value}\"" "$detail")
    fi
    replace_or_append_line "$uv_conf" '^exclude-newer[[:space:]]*=' "exclude-newer = \"${exclude_newer_value}\""

    if [[ ${#UV_EXCEPTIONS[@]} -gt 0 ]]; then
        desired_exception_line=$(build_uv_exception_line)
        replace_or_append_line "$uv_conf" '^exclude-newer-package[[:space:]]*=' "$desired_exception_line"
    else
        remove_matching_lines "$uv_conf" '^exclude-newer-package[[:space:]]*='
    fi

    if verify_and_finalize "$uv_conf" "uv" 'exclude-newer'; then
        emit_config_status "uv" "uv" "$status" "$detail"
    else
        emit_config_status "uv" "uv" "FAIL" "$detail"
    fi
}

setup_poetry() {
    local poetry_conf="$POETRY_CONFIG_PATH"
    local desired_age_line="min-release-age = ${MIN_AGE_DAYS}"
    # Exclusions must be TOML arrays: Poetry only splits comma strings from env
    # vars and `poetry config`, so a string in config.toml is silently ignored.
    local desired_package_exceptions=""
    local desired_source_exceptions=""
    local current_package_exceptions current_source_exceptions detail status current

    ensure_file_exists "$poetry_conf"

    if [[ ${#POETRY_EXCEPTIONS[@]} -gt 0 ]]; then
        desired_package_exceptions="min-release-age-exclude = $(toml_array "${POETRY_EXCEPTIONS[@]}")"
    fi
    if [[ ${#POETRY_SOURCE_EXCEPTIONS[@]} -gt 0 ]]; then
        desired_source_exceptions="min-release-age-exclude-source = $(toml_array "${POETRY_SOURCE_EXCEPTIONS[@]}")"
    fi

    current_package_exceptions=$(current_lines_or_empty "$poetry_conf" '^min-release-age-exclude[[:space:]]*=')
    current_source_exceptions=$(current_lines_or_empty "$poetry_conf" '^min-release-age-exclude-source[[:space:]]*=')

    if grep -q "^${desired_age_line}$" "$poetry_conf" 2>/dev/null \
        && [[ "$current_package_exceptions" == "$desired_package_exceptions" ]] \
        && [[ "$current_source_exceptions" == "$desired_source_exceptions" ]]; then
        emit_config_status "Poetry" "poetry" "ok" "min-release-age = ${MIN_AGE_DAYS}$(exception_count_suffix "${#POETRY_EXCEPTIONS[@]}" "package-exceptions")$(exception_count_suffix "${#POETRY_SOURCE_EXCEPTIONS[@]}" "source-exceptions")"
        SKIPPED_TOOLS+=("poetry")
        return 0
    fi

    backup_if_exists "$poetry_conf"

    status="added"
    detail="min-release-age = ${MIN_AGE_DAYS}$(exception_count_suffix "${#POETRY_EXCEPTIONS[@]}" "package-exceptions")$(exception_count_suffix "${#POETRY_SOURCE_EXCEPTIONS[@]}" "source-exceptions")"
    if grep -q '^min-release-age[[:space:]]*=' "$poetry_conf" 2>/dev/null; then
        current=$(grep '^min-release-age[[:space:]]*=' "$poetry_conf" | sed -n 1p | sed 's/.*= *//')
        status="updated"
        detail=$(format_change_detail "$current" "$MIN_AGE_DAYS" "$detail")
    fi

    upsert_line_in_section "$poetry_conf" "[solver]" '^min-release-age[[:space:]]*=' "$desired_age_line"
    if [[ ${#POETRY_EXCEPTIONS[@]} -gt 0 ]]; then
        upsert_line_in_section "$poetry_conf" "[solver]" '^min-release-age-exclude[[:space:]]*=' "$desired_package_exceptions"
    else
        remove_matching_lines "$poetry_conf" '^min-release-age-exclude[[:space:]]*='
    fi
    if [[ ${#POETRY_SOURCE_EXCEPTIONS[@]} -gt 0 ]]; then
        upsert_line_in_section "$poetry_conf" "[solver]" '^min-release-age-exclude-source[[:space:]]*=' "$desired_source_exceptions"
    else
        remove_matching_lines "$poetry_conf" '^min-release-age-exclude-source[[:space:]]*='
    fi

    if verify_and_finalize "$poetry_conf" "poetry" 'min-release-age\|\[solver\]'; then
        emit_config_status "Poetry" "poetry" "$status" "$detail"
    else
        emit_config_status "Poetry" "poetry" "FAIL" "$detail"
    fi
}

CRON_MARKER="# set-minimum-package-release-age: uv exclude-newer"
VLT_CRON_MARKER="# set-minimum-package-release-age: vlt before"

vlt_refresh_display_name() {
    if [[ "$VLT_REFRESH_SCHEDULER" == "launchd" ]]; then
        printf '%s\n' "vlt launchd"
    else
        printf '%s\n' "vlt cron"
    fi
}

setup_cron_vlt() {
    if [[ "$VLT_REFRESH_SCHEDULER" == "launchd" ]]; then
        setup_vlt_launchd
    else
        setup_vlt_crontab
    fi
}

setup_vlt_crontab() {
    local cron_cmd current_entries

    if ! crontab_available; then
        emit_config_status "vlt cron" "vlt-cron" "FAIL" "crontab not available; vlt before date will not refresh"
        FAILED_TOOLS+=("cron-vlt")
        return 0
    fi

    cron_cmd=$(platform_build_vlt_cron_command "$MIN_AGE_DAYS" "$VLT_CONFIG_PATH")
    current_entries=$(crontab -l 2>/dev/null | grep -F "$VLT_CRON_MARKER" || true)

    if [[ "$current_entries" == "$cron_cmd" ]]; then
        emit_config_status "vlt cron" "vlt-cron" "ok" "daily job installed"
        SKIPPED_TOOLS+=("cron-vlt")
        return 0
    fi

    # Replace stale entries (for example, a different age or script path) so the
    # nightly refresh never resets vlt back to an old window.
    { crontab -l 2>/dev/null | grep -vF "$VLT_CRON_MARKER" || true; printf '%s\n' "$cron_cmd"; } | crontab_write

    if [[ "$(crontab -l 2>/dev/null | grep -F "$VLT_CRON_MARKER" || true)" == "$cron_cmd" ]]; then
        if [[ -n "$current_entries" ]]; then
            emit_config_status "vlt cron" "vlt-cron" "updated" "daily at midnight (crontab -l to verify)"
        else
            emit_config_status "vlt cron" "vlt-cron" "added" "daily at midnight (crontab -l to verify)"
        fi
        UPDATED_TOOLS+=("cron-vlt")
    else
        emit_config_status "vlt cron" "vlt-cron" "FAIL" "could not install cron job"
        FAILED_TOOLS+=("cron-vlt")
    fi
}

xml_escape() {
    local value="$1"
    value=${value//&/&amp;}
    value=${value//</&lt;}
    value=${value//>/&gt;}
    value=${value//\"/&quot;}
    printf '%s' "$value"
}

build_vlt_launchd_plist() {
    local script_path
    script_path=$(platform_vlt_refresh_script_path)
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${VLT_LAUNCHD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$(xml_escape "$script_path")</string>
        <string>${MIN_AGE_DAYS}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>SET_MINIMUM_PACKAGE_RELEASE_AGE_REFRESH_VLT</key>
        <string>1</string>
        <key>VLT_CONFIG_PATH</key>
        <string>$(xml_escape "$VLT_CONFIG_PATH")</string>
    </dict>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>0</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF
}

launchd_target() {
    printf 'gui/%s/%s\n' "$(id -u)" "$VLT_LAUNCHD_LABEL"
}

launchd_job_loaded() {
    command -v launchctl >/dev/null 2>&1 && launchctl print "$(launchd_target)" >/dev/null 2>&1
}

# Loads (or reloads) the agent in the current login session. Fails without a GUI
# session (for example over SSH); the plist then loads at the next login.
launchd_load_job() {
    command -v launchctl >/dev/null 2>&1 || return 1
    launchctl bootout "$(launchd_target)" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$VLT_LAUNCHD_PLIST_PATH" >/dev/null 2>&1
}

# Older releases scheduled the vlt refresh with cron on macOS too. Prints a note
# for the status detail when a legacy entry was found.
cleanup_legacy_vlt_crontab_on_launchd() {
    if ! crontab_available || ! crontab_has_marker "$VLT_CRON_MARKER"; then
        return 0
    fi

    { crontab -l 2>/dev/null | grep -vF "$VLT_CRON_MARKER" || true; } | crontab_write
    if crontab_has_marker "$VLT_CRON_MARKER"; then
        printf '%s' "; old vlt crontab line could not be removed, delete it with crontab -e"
    else
        printf '%s' "; removed old vlt crontab entry"
    fi
}

setup_vlt_launchd() {
    local display desired note status="added" detail

    display=$(vlt_refresh_display_name)
    desired=$(build_vlt_launchd_plist)
    note=$(cleanup_legacy_vlt_crontab_on_launchd)

    if [[ -f "$VLT_LAUNCHD_PLIST_PATH" && "$(cat "$VLT_LAUNCHD_PLIST_PATH")" == "$desired" ]]; then
        if launchd_job_loaded; then
            emit_config_status "$display" "vlt-cron" "ok" "daily job loaded${note}"
            SKIPPED_TOOLS+=("cron-vlt")
            return 0
        fi
        status="updated"
    elif [[ -f "$VLT_LAUNCHD_PLIST_PATH" ]]; then
        status="updated"
    fi

    mkdir -p "$(dirname "$VLT_LAUNCHD_PLIST_PATH")"
    write_file_from_command "$VLT_LAUNCHD_PLIST_PATH" build_vlt_launchd_plist
    if [[ "$(cat "$VLT_LAUNCHD_PLIST_PATH" 2>/dev/null)" != "$desired" ]]; then
        emit_config_status "$display" "vlt-cron" "FAIL" "could not write launchd agent${note}"
        FAILED_TOOLS+=("cron-vlt")
        return 0
    fi

    if launchd_load_job; then
        detail="daily at midnight and at login (launchctl print $(launchd_target))"
    else
        detail="daily at midnight; loads at next login"
    fi
    emit_config_status "$display" "vlt-cron" "$status" "${detail}${note}"
    UPDATED_TOOLS+=("cron-vlt")
}

remove_vlt_launchd() {
    local display had_state=false note

    display=$(vlt_refresh_display_name)
    if [[ -f "$VLT_LAUNCHD_PLIST_PATH" ]] || launchd_job_loaded; then
        had_state=true
    fi
    note=$(cleanup_legacy_vlt_crontab_on_launchd)
    if [[ -n "$note" ]]; then
        had_state=true
    fi

    if [[ "$had_state" == false ]]; then
        emit_config_status "$display" "vlt-cron" "ok" "launchd agent not present"
        SKIPPED_TOOLS+=("cron-vlt")
        return 0
    fi

    if command -v launchctl >/dev/null 2>&1; then
        launchctl bootout "$(launchd_target)" >/dev/null 2>&1 || true
    fi
    rm -f "$VLT_LAUNCHD_PLIST_PATH"

    if [[ -f "$VLT_LAUNCHD_PLIST_PATH" ]] || launchd_job_loaded; then
        emit_config_status "$display" "vlt-cron" "FAIL" "could not remove launchd agent${note}"
        FAILED_TOOLS+=("cron-vlt")
        return 0
    fi
    emit_config_status "$display" "vlt-cron" "removed" "launchd agent${note}"
    UPDATED_TOOLS+=("cron-vlt")
}

setup_npm() {
    local npmrc="$NPMRC_PATH"
    local desired_line="min-release-age=${MIN_AGE_DAYS}"
    local desired_exceptions="" current_exceptions item detail status current

    touch "$npmrc"

    if [[ ${#NPM_EXCEPTIONS[@]} -gt 0 ]]; then
        for item in "${NPM_EXCEPTIONS[@]}"; do
            desired_exceptions+=$'min-release-age-exclude[]='
            desired_exceptions+="$item"
            desired_exceptions+=$'\n'
        done
        desired_exceptions=${desired_exceptions%$'\n'}
    fi

    current_exceptions=$(current_lines_or_empty "$npmrc" '^min-release-age-exclude')
    if grep -q "^${desired_line}$" "$npmrc" 2>/dev/null \
        && [[ "$current_exceptions" == "$desired_exceptions" ]]; then
        emit_config_status "npm" "npm" "ok" "${desired_line}$(exception_count_suffix "${#NPM_EXCEPTIONS[@]}" "exceptions")"
        SKIPPED_TOOLS+=("npm")
        return 0
    fi

    backup_if_exists "$npmrc"

    status="added"
    detail="${desired_line}$(exception_count_suffix "${#NPM_EXCEPTIONS[@]}" "exceptions")"
    if grep -q '^min-release-age=' "$npmrc" 2>/dev/null; then
        current=$(grep '^min-release-age=' "$npmrc" | sed -n 1p | sed 's/.*=//')
        status="updated"
        detail=$(format_change_detail "$current" "$MIN_AGE_DAYS" "${MIN_AGE_DAYS}$(exception_count_suffix "${#NPM_EXCEPTIONS[@]}" "exceptions")")
    fi

    replace_or_append_line "$npmrc" '^min-release-age=' "$desired_line"
    remove_matching_lines "$npmrc" '^min-release-age-exclude'
    if [[ ${#NPM_EXCEPTIONS[@]} -gt 0 ]]; then
        for item in "${NPM_EXCEPTIONS[@]}"; do
            printf 'min-release-age-exclude[]=%s\n' "$item" >> "$npmrc"
        done
    fi
    # A before= line in the same file takes precedence over min-release-age.
    if grep -q '^[[:space:]]*before[[:space:]]*=' "$npmrc" 2>/dev/null; then
        detail+="; warning: before= in this file overrides min-release-age"
    fi
    if verify_and_finalize "$npmrc" "npm" 'min-release-age'; then
        emit_config_status "npm" "npm" "$status" "$detail"
    else
        emit_config_status "npm" "npm" "FAIL" "$detail"
    fi
}

setup_pnpm() {
    load_tool_detection_cache
    local pnpm_config
    local min_age_minutes=$(( MIN_AGE_DAYS * 1440 ))
    local desired_line desired_exceptions current_age current_exceptions item detail status current

    pnpm_config=$(pnpm_active_config_path)
    ensure_file_exists "$pnpm_config"

    if pnpm_active_config_is_yaml; then
        desired_line="minimumReleaseAge: ${min_age_minutes}"
    else
        desired_line="minimum-release-age=${min_age_minutes}"
    fi

    current_age=$(current_lines_or_empty "$pnpm_config" '^minimumReleaseAge:[[:space:]]*')
    if [[ -z "$current_age" ]]; then
        current_age=$(current_lines_or_empty "$pnpm_config" '^minimum-release-age=')
    fi

    desired_exceptions=""
    if [[ ${#PNPM_EXCEPTIONS[@]} -gt 0 ]]; then
        if pnpm_active_config_is_yaml; then
            desired_exceptions="minimumReleaseAgeExclude: $(yaml_flow_array "${PNPM_EXCEPTIONS[@]}")"
        else
            for item in "${PNPM_EXCEPTIONS[@]}"; do
                desired_exceptions+=$'minimum-release-age-exclude[]='
                desired_exceptions+="$item"
                desired_exceptions+=$'\n'
            done
            desired_exceptions=${desired_exceptions%$'\n'}
        fi
    fi

    current_exceptions=$(current_lines_or_empty "$pnpm_config" '^minimumReleaseAgeExclude:')
    if [[ -z "$current_exceptions" ]]; then
        current_exceptions=$(current_lines_or_empty "$pnpm_config" '^minimum-release-age-exclude')
    fi

    if grep -q "^${desired_line}$" "$pnpm_config" 2>/dev/null \
        && [[ "$current_exceptions" == "$desired_exceptions" ]]; then
        emit_config_status "pnpm" "pnpm" "ok" "${desired_line} ($(pnpm_active_config_label))$(exception_count_suffix "${#PNPM_EXCEPTIONS[@]}" "exceptions")"
        SKIPPED_TOOLS+=("pnpm")
        return 0
    fi

    backup_if_exists "$pnpm_config"

    status="added"
    detail="${desired_line} ($(pnpm_active_config_label))$(exception_count_suffix "${#PNPM_EXCEPTIONS[@]}" "exceptions")"
    if [[ -n "$current_age" ]]; then
        current=$(printf '%s\n' "$current_age" | sed -n 1p | sed 's/^[^:=]*[:=] *//')
        status="updated"
        detail=$(format_change_detail "$current" "$min_age_minutes" "${min_age_minutes} ($(pnpm_active_config_label))$(exception_count_suffix "${#PNPM_EXCEPTIONS[@]}" "exceptions")")
    fi

    if pnpm_active_config_is_yaml; then
        if [[ -f "$PNPM_RC_PATH" ]] \
            && { grep -q '^minimum-release-age=' "$PNPM_RC_PATH" 2>/dev/null || grep -q '^minimum-release-age-exclude' "$PNPM_RC_PATH" 2>/dev/null; }; then
            backup_if_exists "$PNPM_RC_PATH"
            remove_matching_lines "$PNPM_RC_PATH" '^minimum-release-age='
            remove_matching_lines "$PNPM_RC_PATH" '^minimum-release-age-exclude'
            strip_file_if_whitespace_only "$PNPM_RC_PATH"
            if ! verify_file_changes "$PNPM_RC_PATH" 'minimum-release-age'; then
                FAILED_TOOLS+=("pnpm")
                emit_config_status "pnpm" "pnpm" "FAIL" "$detail"
                return 0
            fi
            cleanup_empty_file "$PNPM_RC_PATH"
        fi
        upsert_yaml_scalar "$pnpm_config" "minimumReleaseAge" "$min_age_minutes"
        if [[ ${#PNPM_EXCEPTIONS[@]} -gt 0 ]]; then
            upsert_yaml_array "$pnpm_config" "minimumReleaseAgeExclude" "${PNPM_EXCEPTIONS[@]}"
        else
            remove_yaml_top_level_key "$pnpm_config" "minimumReleaseAgeExclude"
        fi
        remove_matching_lines "$pnpm_config" '^minimum-release-age='
        remove_matching_lines "$pnpm_config" '^minimum-release-age-exclude'
    else
        replace_or_append_line "$pnpm_config" '^minimum-release-age=' "$desired_line"
        remove_matching_lines "$pnpm_config" '^minimum-release-age-exclude'
        if [[ ${#PNPM_EXCEPTIONS[@]} -gt 0 ]]; then
            for item in "${PNPM_EXCEPTIONS[@]}"; do
                printf 'minimum-release-age-exclude[]=%s\n' "$item" >> "$pnpm_config"
            done
        fi
    fi

    if verify_and_finalize "$pnpm_config" "pnpm" 'minimumReleaseAge\|minimum-release-age'; then
        emit_config_status "pnpm" "pnpm" "$status" "$detail"
    else
        emit_config_status "pnpm" "pnpm" "FAIL" "$detail"
    fi
}

setup_bun() {
    local bunfig="$BUNFIG_PATH"
    local min_age_seconds=$(( MIN_AGE_DAYS * 86400 ))
    local desired_age_line="minimumReleaseAge = ${min_age_seconds}"
    local desired_exceptions_line=""
    local detail status current

    touch "$bunfig"
    if [[ ${#BUN_EXCEPTIONS[@]} -gt 0 ]]; then
        desired_exceptions_line="minimumReleaseAgeExcludes = $(toml_array "${BUN_EXCEPTIONS[@]}")"
    fi

    local current_exceptions
    current_exceptions=$(current_lines_or_empty "$bunfig" '^minimumReleaseAgeExcludes[[:space:]]*=')

    if grep -q "^${desired_age_line}$" "$bunfig" 2>/dev/null \
        && [[ "$current_exceptions" == "$desired_exceptions_line" ]]; then
        emit_config_status "bun" "bun" "ok" "${desired_age_line}$(exception_count_suffix "${#BUN_EXCEPTIONS[@]}" "exceptions")"
        SKIPPED_TOOLS+=("bun")
        return 0
    fi

    backup_if_exists "$bunfig"

    status="added"
    detail="${desired_age_line}$(exception_count_suffix "${#BUN_EXCEPTIONS[@]}" "exceptions")"
    if grep -q '^minimumReleaseAge[[:space:]]*=' "$bunfig" 2>/dev/null; then
        current=$(grep '^minimumReleaseAge[[:space:]]*=' "$bunfig" | sed -n 1p | sed 's/.*= *//')
        status="updated"
        detail=$(format_change_detail "$current" "$min_age_seconds" "${min_age_seconds}$(exception_count_suffix "${#BUN_EXCEPTIONS[@]}" "exceptions")")
    fi

    upsert_line_in_section "$bunfig" "[install]" '^minimumReleaseAge[[:space:]]*=' "$desired_age_line"

    if [[ ${#BUN_EXCEPTIONS[@]} -gt 0 ]]; then
        upsert_line_in_section "$bunfig" "[install]" '^minimumReleaseAgeExcludes[[:space:]]*=' "$desired_exceptions_line"
    else
        remove_matching_lines "$bunfig" '^minimumReleaseAgeExcludes[[:space:]]*='
    fi

    if verify_and_finalize "$bunfig" "bun" 'minimumReleaseAge\|minimumReleaseAgeExcludes\|\[install\]'; then
        emit_config_status "bun" "bun" "$status" "$detail"
    else
        emit_config_status "bun" "bun" "FAIL" "$detail"
    fi
}

setup_yarn_classic() {
    local yarnrc="$YARNRC_PATH"
    local min_age_seconds=$(( MIN_AGE_DAYS * 86400 ))
    local desired_line="cache-min ${min_age_seconds}"
    local detail status current

    touch "$yarnrc"

    if grep -q "^${desired_line}$" "$yarnrc" 2>/dev/null; then
        emit_config_status "yarn v1" "yarn-classic" "ok" "$desired_line"
        SKIPPED_TOOLS+=("yarn-classic")
        return 0
    fi

    backup_if_exists "$yarnrc"

    status="added"
    detail="$desired_line"
    if grep -q '^cache-min' "$yarnrc" 2>/dev/null; then
        current=$(grep '^cache-min' "$yarnrc" | sed -n 1p | awk '{print $2}')
        status="updated"
        detail="${current} --> ${min_age_seconds}"
    fi

    replace_or_append_line "$yarnrc" '^cache-min ' "$desired_line"
    if verify_and_finalize "$yarnrc" "yarn-classic" 'cache-min'; then
        emit_config_status "yarn v1" "yarn-classic" "$status" "$detail"
    else
        emit_config_status "yarn v1" "yarn-classic" "FAIL" "$detail"
    fi
}

setup_yarn_berry() {
    local yarnrc_yml="$YARNRC_YML_PATH"
    local desired_gate_line="npmMinimalAgeGate: $(yaml_quote "${MIN_AGE_DAYS}d")"
    local desired_exceptions_line=""
    local current_exceptions
    local detail status current

    touch "$yarnrc_yml"
    if [[ ${#YARN_EXCEPTIONS[@]} -gt 0 ]]; then
        desired_exceptions_line="npmPreapprovedPackages: $(yaml_flow_array "${YARN_EXCEPTIONS[@]}")"
    fi
    current_exceptions=$(current_lines_or_empty "$yarnrc_yml" '^npmPreapprovedPackages:')

    if grep -q "^${desired_gate_line}$" "$yarnrc_yml" 2>/dev/null \
        && [[ "$current_exceptions" == "$desired_exceptions_line" ]]; then
        emit_config_status "yarn v2+" "yarn-berry" "ok" "npmMinimalAgeGate: ${MIN_AGE_DAYS}d$(exception_count_suffix "${#YARN_EXCEPTIONS[@]}" "exceptions")"
        SKIPPED_TOOLS+=("yarn-berry")
        return 0
    fi

    backup_if_exists "$yarnrc_yml"

    status="added"
    detail="npmMinimalAgeGate: ${MIN_AGE_DAYS}d$(exception_count_suffix "${#YARN_EXCEPTIONS[@]}" "exceptions")"
    if grep -q '^npmMinimalAgeGate:' "$yarnrc_yml" 2>/dev/null; then
        current=$(grep '^npmMinimalAgeGate:' "$yarnrc_yml" | sed -n 1p | sed 's/^[^:]*: *//')
        status="updated"
        detail=$(format_change_detail "$current" "$(yaml_quote "${MIN_AGE_DAYS}d")" "${MIN_AGE_DAYS}d$(exception_count_suffix "${#YARN_EXCEPTIONS[@]}" "exceptions")")
    fi

    replace_or_append_line "$yarnrc_yml" '^npmMinimalAgeGate:' "$desired_gate_line"
    if [[ ${#YARN_EXCEPTIONS[@]} -gt 0 ]]; then
        replace_or_append_line "$yarnrc_yml" '^npmPreapprovedPackages:' "$desired_exceptions_line"
    else
        remove_matching_lines "$yarnrc_yml" '^npmPreapprovedPackages:'
    fi

    if verify_and_finalize "$yarnrc_yml" "yarn-berry" 'npmMinimalAgeGate\|npmPreapprovedPackages'; then
        emit_config_status "yarn v2+" "yarn-berry" "$status" "$detail"
    else
        emit_config_status "yarn v2+" "yarn-berry" "FAIL" "$detail"
    fi
}

DENO_WRAPPER_MARKER="# set-minimum-package-release-age: deno wrapper"
PIXI_WRAPPER_MARKER="# set-minimum-package-release-age: pixi wrapper"
WRAPPER_RC_DIFF_PATTERN='set-minimum-package-release-age\|set-package-min-age'

shell_rc_files() {
    # zsh reads $ZDOTDIR/.zshrc instead of ~/.zshrc when ZDOTDIR is set.
    printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.bashrc"
}

deno_source_line() {
    printf '%s' '[ -f "$HOME/.config/set-package-min-age/deno.sh" ] && . "$HOME/.config/set-package-min-age/deno.sh"'
}

pixi_source_line() {
    printf '%s' '[ -f "$HOME/.config/set-package-min-age/pixi.sh" ] && . "$HOME/.config/set-package-min-age/pixi.sh"'
}

build_deno_wrapper_content() {
    local age="$1"
    local marker="$2"
    cat <<EOF
${marker}
# minimum-release-age: ${age}d
# install/update/outdated/cache accept the flag since Deno 2.6; add/remove only
# since 2.9.4, so older Deno runs those two unchanged instead of erroring.
__set_pkg_min_age_deno_supports_add_flag() {
    local version major minor patch
    version=\$(command deno --version 2>/dev/null | awk 'NR == 1 { print \$2 }')
    IFS=. read -r major minor patch <<< "\${version%%[-+]*}"
    [[ "\${major:-0}" =~ ^[0-9]+\$ && "\${minor:-0}" =~ ^[0-9]+\$ && "\${patch:-0}" =~ ^[0-9]+\$ ]] || return 1
    (( major > 2 || (major == 2 && (minor > 9 || (minor == 9 && patch >= 4))) ))
}
deno() {
    case "\${1:-}" in
        install|update|outdated|cache)
            command deno "\$1" --minimum-dependency-age=P${age}D "\${@:2}"
            ;;
        add|remove)
            if __set_pkg_min_age_deno_supports_add_flag; then
                command deno "\$1" --minimum-dependency-age=P${age}D "\${@:2}"
            else
                command deno "\$@"
            fi
            ;;
        *)
            command deno "\$@"
            ;;
    esac
}
EOF
}

verify_rc_diff_or_rollback() {
    local rc_file="$1"
    local backup="${rc_file}${BACKUP_SUFFIX}"

    if [[ ! -f "$backup" ]]; then
        return 0
    fi

    local diff_output content_lines unexpected
    diff_output=$(diff "$backup" "$rc_file" 2>/dev/null || true)

    if [[ -z "$diff_output" ]]; then
        rm -f "$backup"
        return 0
    fi

    content_lines=$(changed_lines "$backup" "$rc_file")
    if [[ -z "$content_lines" ]]; then
        rm -f "$backup"
        return 0
    fi

    unexpected=$(printf '%s\n' "$content_lines" | grep -v "$WRAPPER_RC_DIFF_PATTERN" || true)
    if [[ -n "$unexpected" ]]; then
        cp "$backup" "$rc_file"
        rm -f "$backup"
        return 1
    fi

    rm -f "$backup"
    return 0
}

manage_rc_source_line() {
    local rc_file="$1"
    local marker="$2"
    local source_line="$3"

    ensure_file_exists "$rc_file"

    if grep -Fxq "$marker" "$rc_file" 2>/dev/null \
        && grep -Fxq "$source_line" "$rc_file" 2>/dev/null; then
        return 0
    fi

    backup_if_exists "$rc_file"

    write_file_from_command "$rc_file" awk \
        -v marker="$marker" \
        -v source_line="$source_line" '
        $0 == marker { next }
        $0 == source_line { next }
        { print }
    ' "$rc_file"

    printf '%s\n%s\n' "$marker" "$source_line" >> "$rc_file"

    verify_rc_diff_or_rollback "$rc_file"
}

remove_rc_source_line() {
    local rc_file="$1"
    local marker="$2"
    local source_line="$3"

    if [[ ! -f "$rc_file" ]]; then
        return 0
    fi

    if ! grep -Fxq "$marker" "$rc_file" 2>/dev/null \
        && ! grep -Fxq "$source_line" "$rc_file" 2>/dev/null; then
        return 0
    fi

    backup_if_exists "$rc_file"

    write_file_from_command "$rc_file" awk \
        -v marker="$marker" \
        -v source_line="$source_line" '
        $0 == marker { next }
        $0 == source_line { next }
        { print }
    ' "$rc_file"

    verify_rc_diff_or_rollback "$rc_file"
}

setup_wrapper_tool() {
    local tool_key="$1"
    local tool_display="$2"
    local marker="$3"
    local wrapper_file="$4"
    local source_line="$5"
    local detail="$6"
    local current_age desired_age_marker status="added" rc all_ok=true rc_status=0

    desired_age_marker="# minimum-release-age: ${MIN_AGE_DAYS}d"

    mkdir -p "$(dirname "$wrapper_file")"

    if [[ -f "$wrapper_file" ]] \
        && grep -Fxq "$marker" "$wrapper_file" 2>/dev/null \
        && grep -Fxq "$desired_age_marker" "$wrapper_file" 2>/dev/null; then
        while IFS= read -r rc; do
            if [[ ! -f "$rc" ]] \
                || ! grep -Fxq "$marker" "$rc" 2>/dev/null \
                || ! grep -Fxq "$source_line" "$rc" 2>/dev/null; then
                all_ok=false
                break
            fi
        done < <(shell_rc_files)
        if [[ "$all_ok" == true ]]; then
            emit_config_status "$tool_display" "$tool_key" "ok" "$detail"
            SKIPPED_TOOLS+=("$tool_key")
            return 0
        fi
    fi

    if [[ -f "$wrapper_file" ]] && grep -q '^# minimum-release-age:' "$wrapper_file" 2>/dev/null; then
        current_age=$(grep '^# minimum-release-age:' "$wrapper_file" | sed -n 1p | sed 's/^# minimum-release-age: *//')
        if [[ -n "$current_age" && "$current_age" != "${MIN_AGE_DAYS}d" ]]; then
            status="updated"
            detail="${current_age} --> ${detail}"
        fi
    fi

    write_file_from_command "$wrapper_file" build_deno_wrapper_content "$MIN_AGE_DAYS" "$marker"

    while IFS= read -r rc; do
        if ! manage_rc_source_line "$rc" "$marker" "$source_line"; then
            rc_status=1
        fi
    done < <(shell_rc_files)

    if [[ "$rc_status" -ne 0 ]]; then
        emit_config_status "$tool_display" "$tool_key" "FAIL" "$detail"
        FAILED_TOOLS+=("$tool_key")
        return 0
    fi

    emit_config_status "$tool_display" "$tool_key" "$status" "$detail"
    UPDATED_TOOLS+=("$tool_key")
}

setup_deno() {
    setup_wrapper_tool "deno" "deno" "$DENO_WRAPPER_MARKER" \
        "$HOME/.config/set-package-min-age/deno.sh" \
        "$(deno_source_line)" \
        "--minimum-dependency-age=P${MIN_AGE_DAYS}D"
}

PIXI_GLOBAL_EXCLUDE_NEWER_MIN_VERSION="0.82.0"

# Older releases installed a pixi shell wrapper that passed --exclude-newer to
# install/add/update/upgrade, but pixi never accepted that flag there and every
# wrapped command failed. Remove it quietly wherever it is still present.
cleanup_legacy_pixi_wrapper() {
    local wrapper_file="$WRAPPER_DIR/pixi.sh" rc status=0

    LEGACY_PIXI_WRAPPER_REMOVED=false
    if [[ -f "$wrapper_file" ]]; then
        rm -f "$wrapper_file"
        LEGACY_PIXI_WRAPPER_REMOVED=true
    fi
    rmdir "$WRAPPER_DIR" 2>/dev/null || true

    while IFS= read -r rc; do
        if [[ -f "$rc" ]] && grep -Fxq "$PIXI_WRAPPER_MARKER" "$rc" 2>/dev/null; then
            LEGACY_PIXI_WRAPPER_REMOVED=true
            remove_rc_source_line "$rc" "$PIXI_WRAPPER_MARKER" "$(pixi_source_line)" || status=1
        fi
    done < <(shell_rc_files)

    return "$status"
}

legacy_pixi_wrapper_present() {
    local rc

    [[ -f "$WRAPPER_DIR/pixi.sh" ]] && return 0
    while IFS= read -r rc; do
        if [[ -f "$rc" ]] && grep -Fxq "$PIXI_WRAPPER_MARKER" "$rc" 2>/dev/null; then
            return 0
        fi
    done < <(shell_rc_files)
    return 1
}

# Splits a pixi exception into its package name and version spec ("*" = all).
pixi_exemption_toml_entry() {
    local spec="$1" name version_spec

    [[ "$spec" =~ ^([A-Za-z0-9_][A-Za-z0-9._-]*)(.*)$ ]]
    name="${BASH_REMATCH[1]}"
    version_spec="${BASH_REMATCH[2]:-*}"
    printf '%s = %s' "$(toml_quote "$name")" "$(toml_quote "$version_spec")"
}

pixi_global_exclude_newer_line() {
    local cutoff entries="" spec

    cutoff=$(toml_quote "${MIN_AGE_DAYS}d")
    if [[ ${#PIXI_EXCEPTIONS[@]} -eq 0 ]]; then
        printf 'exclude-newer = %s\n' "$cutoff"
        return
    fi

    for spec in "${PIXI_EXCEPTIONS[@]}"; do
        [[ -n "$entries" ]] && entries+=", "
        entries+=$(pixi_exemption_toml_entry "$spec")
    done
    printf 'exclude-newer = { cutoff = %s, exemptions = { %s } }\n' "$cutoff" "$entries"
}

# True for a root exclude-newer line this script may replace: any plain string,
# or the exact inline-table shape it writes. Other tables are user-managed.
pixi_line_is_managed() {
    [[ "$1" =~ ^exclude-newer[[:space:]]*=[[:space:]]*\" ]] \
        || [[ "$1" =~ ^exclude-newer\ =\ \{\ cutoff\ =\ \"[0-9]+d\",\ exemptions\ =\ \{\ \"[^\"]+\"\ =\ .+\ \}\ \}$ ]]
}

remove_toml_root_exact_line() {
    local file="$1"
    local line="$2"

    write_file_from_command "$file" awk -v target="$line" '
        BEGIN { in_root = 1 }
        /^[[:space:]]*\[/ { in_root = 0 }
        in_root && $0 == target { next }
        { print }
    ' "$file"
}

# Prints the root-level exclude-newer line (before any [table]) if present.
current_pixi_global_exclude_newer() {
    awk '/^[[:space:]]*\[/ { exit } /^exclude-newer[[:space:]]*=/ { print; exit }' "$1" 2>/dev/null || true
}

pixi_supports_global_exclude_newer() {
    local installed version

    installed=$(lookup_detected_tool_field "pixi" installed 2>/dev/null || printf 'no')
    version=$(lookup_detected_tool_field "pixi" version 2>/dev/null || printf 'unknown')
    [[ "$installed" == "yes" && -n "$version" && "$version" != "unknown" ]] \
        && version_gte "$version" "$PIXI_GLOBAL_EXCLUDE_NEWER_MIN_VERSION"
}

upsert_toml_root_line() {
    local file="$1"
    local match_regex="$2"
    local line="$3"

    write_file_from_command "$file" awk -v match_regex="$match_regex" -v replacement="$line" '
        BEGIN { done = 0; in_root = 1 }
        in_root && /^[[:space:]]*\[/ {
            if (!done) {
                print replacement
                print ""
                done = 1
            }
            in_root = 0
        }
        in_root && $0 ~ match_regex {
            if (!done) {
                print replacement
                done = 1
            }
            next
        }
        { print }
        END {
            if (!done) {
                print replacement
            }
        }
    ' "$file"
}

remove_toml_root_lines() {
    local file="$1"
    local match_regex="$2"

    write_file_from_command "$file" awk -v match_regex="$match_regex" '
        BEGIN { in_root = 1 }
        /^[[:space:]]*\[/ { in_root = 0 }
        in_root && $0 ~ match_regex { next }
        { print }
    ' "$file"
}

# pixi has no user-level setting for workspaces; the pixi global manifest is the
# only user-level place that accepts exclude-newer (pixi 0.82.0+).
setup_pixi() {
    load_tool_detection_cache
    local manifest="$PIXI_GLOBAL_MANIFEST_PATH"
    local desired_line current detail note="" status="added"

    desired_line=$(pixi_global_exclude_newer_line)
    detail="pixi global exclude-newer = ${MIN_AGE_DAYS}d$(exception_count_suffix "${#PIXI_EXCEPTIONS[@]}" "exemptions")"

    if ! cleanup_legacy_pixi_wrapper; then
        emit_config_status "pixi" "pixi" "FAIL" "could not remove legacy pixi shell wrapper from rc files"
        FAILED_TOOLS+=("pixi")
        return 0
    fi
    if [[ "$LEGACY_PIXI_WRAPPER_REMOVED" == true ]]; then
        note="; removed broken legacy shell wrapper"
    fi

    if [[ "$(lookup_detected_tool_field "pixi" installed 2>/dev/null || printf 'no')" != "yes" ]]; then
        emit_config_status "pixi" "pixi" "skipped" "pixi not installed${note}"
        SKIPPED_TOOLS+=("pixi")
        return 0
    fi
    if ! pixi_supports_global_exclude_newer; then
        emit_config_status "pixi" "pixi" "skipped" "pixi global exclude-newer requires pixi >= ${PIXI_GLOBAL_EXCLUDE_NEWER_MIN_VERSION}${note}"
        SKIPPED_TOOLS+=("pixi")
        return 0
    fi

    # pixi builds a missing manifest from the existing global installs, so never
    # create it here; that could hide those environments from pixi.
    if [[ ! -f "$manifest" ]]; then
        emit_config_status "pixi" "pixi" "skipped" "no pixi global manifest yet; run a pixi global command, then rerun${note}"
        SKIPPED_TOOLS+=("pixi")
        return 0
    fi

    current=$(current_pixi_global_exclude_newer "$manifest")
    if [[ "$current" == "$desired_line" ]]; then
        emit_config_status "pixi" "pixi" "ok" "${detail}${note}"
        SKIPPED_TOOLS+=("pixi")
        return 0
    fi
    if [[ -n "$current" ]] && ! pixi_line_is_managed "$current"; then
        emit_config_status "pixi" "pixi" "skipped" "custom exclude-newer table left unchanged${note}"
        SKIPPED_TOOLS+=("pixi")
        return 0
    fi

    backup_if_exists "$manifest"
    if [[ -n "$current" ]]; then
        status="updated"
        detail="${current#*= } --> ${detail}"
    fi

    upsert_toml_root_line "$manifest" '^exclude-newer[[:space:]]*=' "$desired_line"
    if verify_and_finalize "$manifest" "pixi" 'exclude-newer'; then
        emit_config_status "pixi" "pixi" "$status" "${detail}${note}"
    else
        emit_config_status "pixi" "pixi" "FAIL" "${detail}${note}"
    fi
}

setup_vlt() {
    local before_date desired_line current detail status

    before_date=$(date_days_ago_rfc3339 "$MIN_AGE_DAYS")
    desired_line="\"before\": \"${before_date}\""
    detail="before = ${before_date} (${MIN_AGE_DAYS}d window)"

    ensure_file_exists "$VLT_CONFIG_PATH"

    if grep -q "^[[:space:]]*${desired_line}[,]*[[:space:]]*$" "$VLT_CONFIG_PATH" 2>/dev/null; then
        emit_config_status "vlt" "vlt" "ok" "$detail"
        SKIPPED_TOOLS+=("vlt")
        return 0
    fi

    backup_if_exists "$VLT_CONFIG_PATH"

    status="added"
    if grep -q '^[[:space:]]*"before"[[:space:]]*:' "$VLT_CONFIG_PATH" 2>/dev/null; then
        current=$(grep '^[[:space:]]*"before"[[:space:]]*:' "$VLT_CONFIG_PATH" | sed -n 1p | sed 's/.*: *"//; s/".*//')
        status="updated"
        detail="${current} --> ${before_date} (${MIN_AGE_DAYS}d window)"
    fi

    upsert_vlt_before_config "$VLT_CONFIG_PATH" "$before_date"
    if verify_and_finalize "$VLT_CONFIG_PATH" "vlt" '"before"\|"config"\|^[{}][,]*$'; then
        emit_config_status "vlt" "vlt" "$status" "$detail"
    else
        emit_config_status "vlt" "vlt" "FAIL" "$detail"
    fi
}

setup_bundler() {
    local bundler_conf="$BUNDLER_CONFIG_PATH"
    local desired_line="BUNDLE_COOLDOWN: \"${MIN_AGE_DAYS}\""
    local detail status current

    ensure_file_exists "$bundler_conf"
    if ! grep -q '[^[:space:]]' "$bundler_conf" 2>/dev/null; then
        printf '%s\n' '---' > "$bundler_conf"
    fi

    if grep -q "^${desired_line}$" "$bundler_conf" 2>/dev/null; then
        emit_config_status "Bundler" "bundler" "ok" "cooldown = ${MIN_AGE_DAYS}d"
        SKIPPED_TOOLS+=("bundler")
        return 0
    fi

    backup_if_exists "$bundler_conf"

    status="added"
    detail="cooldown = ${MIN_AGE_DAYS}d"
    if grep -q '^BUNDLE_COOLDOWN:' "$bundler_conf" 2>/dev/null; then
        current=$(grep '^BUNDLE_COOLDOWN:' "$bundler_conf" | sed -n 1p | sed 's/^[^:]*: *//; s/"//g')
        status="updated"
        detail="${current} --> ${MIN_AGE_DAYS}d"
    fi

    replace_or_append_line "$bundler_conf" '^BUNDLE_COOLDOWN:' "$desired_line"
    if verify_and_finalize "$bundler_conf" "bundler" 'BUNDLE_COOLDOWN\|---'; then
        emit_config_status "Bundler" "bundler" "$status" "$detail"
    else
        emit_config_status "Bundler" "bundler" "FAIL" "$detail"
    fi
}

hex_exclude_repos_line() {
    local term="" repo

    for repo in "${HEX_EXCEPTIONS[@]}"; do
        [[ -n "$term" ]] && term+=","
        term+="<<\"${repo}\">>"
    done
    printf '{cooldown_exclude_repos,[%s]}.\n' "$term"
}

# cooldown_exclude_repos is only managed when hex exceptions are passed; a list
# maintained by hand (or with `mix hex.config`) is otherwise left alone.
setup_hex() {
    local hex_conf="$HEX_CONFIG_PATH"
    local desired_line="{cooldown,<<\"${MIN_AGE_DAYS}d\">>}."
    local desired_exclude="" current_exclude=""
    local detail current status

    detail="cooldown = ${MIN_AGE_DAYS}d$(exception_count_suffix "${#HEX_EXCEPTIONS[@]}" "repo-exclusions")"
    ensure_file_exists "$hex_conf"

    if [[ ${#HEX_EXCEPTIONS[@]} -gt 0 ]]; then
        desired_exclude=$(hex_exclude_repos_line)
        current_exclude=$(grep '^[{]cooldown_exclude_repos,' "$hex_conf" 2>/dev/null || true)
        # Hex wraps long terms across lines; rewriting only the first line of such
        # a term would corrupt the file, so leave it to the user.
        if [[ -n "$current_exclude" && "$current_exclude" != *"}." ]]; then
            emit_config_status "Hex" "hex" "FAIL" "multi-line cooldown_exclude_repos in hex.config; edit it with mix hex.config"
            FAILED_TOOLS+=("hex")
            return 0
        fi
    fi

    if grep -Fqx "$desired_line" "$hex_conf" 2>/dev/null && [[ "$current_exclude" == "$desired_exclude" ]]; then
        emit_config_status "Hex" "hex" "ok" "$detail"
        SKIPPED_TOOLS+=("hex")
        return 0
    fi

    backup_if_exists "$hex_conf"
    status="added"
    if grep -q '^[{]cooldown,' "$hex_conf" 2>/dev/null; then
        current=$(grep '^[{]cooldown,' "$hex_conf" | sed -n 1p | sed 's/.*<<"//; s/d">>.*//')
        status="updated"
        detail=$(format_change_detail "$current" "$MIN_AGE_DAYS" "$detail")
    fi

    replace_or_append_line "$hex_conf" '^[{]cooldown,' "$desired_line"
    if [[ -n "$desired_exclude" ]]; then
        replace_or_append_line "$hex_conf" '^[{]cooldown_exclude_repos,' "$desired_exclude"
    fi
    if verify_and_finalize "$hex_conf" "hex" '^[{]cooldown'; then
        emit_config_status "Hex" "hex" "$status" "$detail"
    else
        emit_config_status "Hex" "hex" "FAIL" "$detail"
    fi
}

# Shared flow for tools whose whole managed state is one age line, plus an
# optional exceptions line, inside a single TOML section.
# Args: tool_key display file section age_key age_value detail [list_key list_value]
setup_toml_section_age() {
    local tool_key="$1" tool_display="$2" file="$3" section="$4" age_key="$5" age_value="$6" detail="$7"
    local list_key="${8:-}" list_value="${9:-}"
    local age_line="${age_key} = ${age_value}"
    local list_line="" current_list="" current status="added"

    if [[ -n "$list_key" && -n "$list_value" ]]; then
        list_line="${list_key} = ${list_value}"
    fi

    ensure_file_exists "$file"
    if [[ -n "$list_key" ]]; then
        current_list=$(current_lines_or_empty "$file" "^${list_key}[[:space:]]*=")
    fi

    if grep -Fqx "$age_line" "$file" 2>/dev/null && [[ "$current_list" == "$list_line" ]]; then
        emit_config_status "$tool_display" "$tool_key" "ok" "$detail"
        SKIPPED_TOOLS+=("$tool_key")
        return 0
    fi

    backup_if_exists "$file"

    if grep -q "^${age_key}[[:space:]]*=" "$file" 2>/dev/null; then
        current=$(grep "^${age_key}[[:space:]]*=" "$file" | sed -n 1p | sed 's/^[^=]*= *//')
        status="updated"
        detail=$(format_change_detail "$current" "$age_value" "$detail")
    fi

    upsert_line_in_section "$file" "[${section}]" "^${age_key}[[:space:]]*=" "$age_line"
    if [[ -n "$list_line" ]]; then
        upsert_line_in_section "$file" "[${section}]" "^${list_key}[[:space:]]*=" "$list_line"
    elif [[ -n "$list_key" ]]; then
        remove_matching_lines "$file" "^${list_key}[[:space:]]*="
    fi

    if verify_and_finalize "$file" "$tool_key" "${age_key}\\|\\[${section}\\]${list_key:+\\|${list_key}}"; then
        emit_config_status "$tool_display" "$tool_key" "$status" "$detail"
    else
        emit_config_status "$tool_display" "$tool_key" "FAIL" "$detail"
    fi
}

# Args: tool_key display file section age_key [list_key]
remove_toml_section_age() {
    local tool_key="$1" tool_display="$2" file="$3" section="$4" age_key="$5" list_key="${6:-}"
    local current

    if ! grep -q "^${age_key}[[:space:]]*=" "$file" 2>/dev/null \
        && { [[ -z "$list_key" ]] || ! grep -q "^${list_key}[[:space:]]*=" "$file" 2>/dev/null; }; then
        emit_config_status "$tool_display" "$tool_key" "ok" "${age_key} not present"
        SKIPPED_TOOLS+=("$tool_key")
        return 0
    fi

    current=$(grep "^${age_key}[[:space:]]*=" "$file" 2>/dev/null | sed -n 1p | sed 's/^[^=]*= *//' || true)

    backup_if_exists "$file"
    remove_matching_lines "$file" "^${age_key}[[:space:]]*="
    if [[ -n "$list_key" ]]; then
        remove_matching_lines "$file" "^${list_key}[[:space:]]*="
    fi
    if grep -Fqx "[${section}]" "$file" 2>/dev/null && ! section_has_content "$file" "[${section}]"; then
        write_file_from_command "$file" awk -v section_line="[${section}]" '$0 != section_line { print }' "$file"
    fi

    strip_file_if_whitespace_only "$file"
    if verify_and_finalize "$file" "$tool_key" "${age_key}\\|\\[${section}\\]${list_key:+\\|${list_key}}"; then
        emit_config_status "$tool_display" "$tool_key" "removed" "${age_key} = ${current:-unset}"
    else
        emit_config_status "$tool_display" "$tool_key" "FAIL" "${age_key} = ${current:-unset}"
    fi
    cleanup_empty_file "$file"
}

# Args: display tool_key file age_line [list_key expected_list_line]
validate_toml_section_age() {
    local tool_display="$1" tool_key="$2" file="$3" age_line="$4" list_key="${5:-}" expected_list="${6:-}"
    local current_list=""

    if [[ ! -f "$file" ]]; then
        record_validation_skip "$tool_display" "config not present" "$tool_key"
        return 0
    fi

    if [[ -n "$list_key" ]]; then
        current_list=$(current_lines_or_empty "$file" "^${list_key}[[:space:]]*=")
    fi

    if grep -Fqx "$age_line" "$file" 2>/dev/null && [[ "$current_list" == "$expected_list" ]]; then
        record_validation_ok "$tool_display" "$age_line" "$tool_key"
    else
        record_validation_fail "$tool_display" "${age_line%% *} settings do not match" "$tool_key"
    fi
}

pdm_exclude_newer_value() {
    toml_quote "${MIN_AGE_DAYS}d"
}

cargo_min_publish_age_value() {
    toml_quote "${MIN_AGE_DAYS} days"
}

mise_minimum_release_age_value() {
    toml_quote "${MIN_AGE_DAYS}d"
}

mise_exceptions_value() {
    if [[ ${#MISE_EXCEPTIONS[@]} -gt 0 ]]; then
        toml_array "${MISE_EXCEPTIONS[@]}"
    fi
}

setup_pdm() {
    setup_toml_section_age "pdm" "PDM" "$PDM_CONFIG_PATH" "strategy" "exclude-newer" \
        "$(pdm_exclude_newer_value)" "exclude-newer = ${MIN_AGE_DAYS}d"
}

remove_pdm() {
    remove_toml_section_age "pdm" "PDM" "$PDM_CONFIG_PATH" "strategy" "exclude-newer"
}

CARGO_EXCEPTION_MARKER="# set-minimum-package-release-age exception"

cargo_exception_line() {
    printf 'min-publish-age = "0" %s\n' "$CARGO_EXCEPTION_MARKER"
}

# Prints the registries that currently carry a line written by this script.
# Cargo never rewrites config.toml, so the trailing marker comment is reliable.
cargo_managed_registries() {
    awk -v marker="$(cargo_exception_line)" '
        /^[[:space:]]*\[/ {
            section = $0
            sub(/^[[:space:]]*\[[[:space:]]*/, "", section)
            sub(/[[:space:]]*\].*$/, "", section)
            next
        }
        $0 == marker && section ~ /^registries\./ {
            print substr(section, length("registries.") + 1)
        }
    ' "$1" 2>/dev/null | sort -u
}

cargo_desired_registries() {
    if [[ ${#CARGO_EXCEPTIONS[@]} -gt 0 ]]; then
        printf '%s\n' "${CARGO_EXCEPTIONS[@]}" | sort -u
    fi
}

# A registry defined inline (`[registries] name = { ... }` or a dotted
# `registries.name.key`) cannot also get a [registries.name] table: TOML would
# reject the duplicate key and break every cargo command.
cargo_registry_defined_inline() {
    local file="$1" name="$2"

    awk -v name="$name" '
        /^[[:space:]]*\[/ { in_registries = ($0 ~ /^[[:space:]]*\[[[:space:]]*registries[[:space:]]*\]/); next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (in_registries && (index(line, name "=") == 1 || index(line, name " ") == 1 || index(line, "\"" name "\"") == 1)) { found = 1 }
            if (index(line, "registries." name ".") == 1) { found = 1 }
        }
        END { exit found ? 0 : 1 }
    ' "$file" 2>/dev/null
}

# Drops [registries.*] headers left with no content after removing managed lines.
remove_empty_cargo_registry_sections() {
    local file="$1"

    write_file_from_command "$file" awk '
        function flush() {
            if (held != "") {
                if (has_content) {
                    printf "%s", held
                }
                held = ""
            }
        }
        /^[[:space:]]*\[/ {
            flush()
            if ($0 ~ /^[[:space:]]*\[[[:space:]]*registries\./) {
                held = $0 "\n"
                has_content = 0
                next
            }
        }
        held != "" {
            held = held $0 "\n"
            if ($0 !~ /^[[:space:]]*$/) {
                has_content = 1
            }
            next
        }
        { print }
        END { flush() }
    ' "$file"
}

setup_cargo() {
    local file="$CARGO_CONFIG_PATH"
    local age_line="global-min-publish-age = $(cargo_min_publish_age_value)"
    local detail current status="added" registry

    detail="global-min-publish-age = ${MIN_AGE_DAYS} days$(exception_count_suffix "${#CARGO_EXCEPTIONS[@]}" "registry-exemptions")"
    ensure_file_exists "$file"

    for registry in "${CARGO_EXCEPTIONS[@]-}"; do
        [[ -n "$registry" ]] || continue
        if cargo_registry_defined_inline "$file" "$registry"; then
            emit_config_status "Cargo" "cargo" "FAIL" "registry ${registry} is defined inline; add min-publish-age = \"0\" to it manually"
            FAILED_TOOLS+=("cargo")
            return 0
        fi
    done

    if grep -Fqx "$age_line" "$file" 2>/dev/null \
        && [[ "$(cargo_managed_registries "$file")" == "$(cargo_desired_registries)" ]]; then
        emit_config_status "Cargo" "cargo" "ok" "$detail"
        SKIPPED_TOOLS+=("cargo")
        return 0
    fi

    backup_if_exists "$file"
    if grep -q '^global-min-publish-age[[:space:]]*=' "$file" 2>/dev/null; then
        current=$(grep '^global-min-publish-age[[:space:]]*=' "$file" | sed -n 1p | sed 's/^[^=]*= *//')
        status="updated"
        detail=$(format_change_detail "$current" "$(cargo_min_publish_age_value)" "$detail")
    fi

    upsert_line_in_section "$file" "[registry]" '^global-min-publish-age[[:space:]]*=' "$age_line"
    remove_matching_lines "$file" "^min-publish-age = \"0\" ${CARGO_EXCEPTION_MARKER}\$"
    for registry in "${CARGO_EXCEPTIONS[@]-}"; do
        [[ -n "$registry" ]] || continue
        upsert_line_in_section "$file" "[registries.${registry}]" '^min-publish-age[[:space:]]*=' "$(cargo_exception_line)"
    done
    remove_empty_cargo_registry_sections "$file"

    if verify_and_finalize "$file" "cargo" 'global-min-publish-age\|\[registry\]\|min-publish-age\|\[registries\.'; then
        emit_config_status "Cargo" "cargo" "$status" "$detail"
    else
        emit_config_status "Cargo" "cargo" "FAIL" "$detail"
    fi
}

remove_cargo() {
    local file="$CARGO_CONFIG_PATH" current

    if ! grep -q '^global-min-publish-age[[:space:]]*=' "$file" 2>/dev/null \
        && [[ -z "$(cargo_managed_registries "$file")" ]]; then
        emit_config_status "Cargo" "cargo" "ok" "global-min-publish-age not present"
        SKIPPED_TOOLS+=("cargo")
        return 0
    fi

    current=$(grep '^global-min-publish-age[[:space:]]*=' "$file" 2>/dev/null | sed -n 1p | sed 's/^[^=]*= *//' || true)
    backup_if_exists "$file"
    remove_matching_lines "$file" '^global-min-publish-age[[:space:]]*='
    remove_matching_lines "$file" "^min-publish-age = \"0\" ${CARGO_EXCEPTION_MARKER}\$"
    remove_empty_cargo_registry_sections "$file"
    if grep -Fqx "[registry]" "$file" 2>/dev/null && ! section_has_content "$file" "[registry]"; then
        write_file_from_command "$file" awk '$0 != "[registry]" { print }' "$file"
    fi

    strip_file_if_whitespace_only "$file"
    if verify_and_finalize "$file" "cargo" 'global-min-publish-age\|\[registry\]\|min-publish-age\|\[registries\.'; then
        emit_config_status "Cargo" "cargo" "removed" "global-min-publish-age = ${current:-unset}"
    else
        emit_config_status "Cargo" "cargo" "FAIL" "global-min-publish-age = ${current:-unset}"
    fi
    cleanup_empty_file "$file"
}

setup_mise() {
    setup_toml_section_age "mise" "mise" "$MISE_CONFIG_PATH" "settings" "minimum_release_age" \
        "$(mise_minimum_release_age_value)" \
        "minimum_release_age = ${MIN_AGE_DAYS}d$(exception_count_suffix "${#MISE_EXCEPTIONS[@]}" "exceptions")" \
        "minimum_release_age_excludes" "$(mise_exceptions_value)"
}

remove_mise() {
    remove_toml_section_age "mise" "mise" "$MISE_CONFIG_PATH" "settings" "minimum_release_age" \
        "minimum_release_age_excludes"
}

remove_pip() {
    local pip_conf="$PIP_CONFIG_PATH"
    local current detail
    local uploaded_prior_to

    uploaded_prior_to=$(pip_uploaded_prior_to_value)
    detail=$(pip_detail_text "$uploaded_prior_to")

    if ! grep -q '^[[:space:]]*uploaded-prior-to[[:space:]]*=' "$pip_conf" 2>/dev/null \
        && ! grep -q '^[[:space:]]*min-age[[:space:]]*=' "$pip_conf" 2>/dev/null; then
        emit_config_status "pip" "pip" "ok" "uploaded-prior-to not present"
        SKIPPED_TOOLS+=("pip")
        return 0
    fi

    if grep -q '^[[:space:]]*uploaded-prior-to[[:space:]]*=' "$pip_conf" 2>/dev/null; then
        current=$(grep '^[[:space:]]*uploaded-prior-to[[:space:]]*=' "$pip_conf" | sed -n 1p | sed 's/.*= *//')
        detail="uploaded-prior-to = ${current}"
    elif grep -q '^[[:space:]]*min-age[[:space:]]*=' "$pip_conf" 2>/dev/null; then
        current=$(grep '^[[:space:]]*min-age[[:space:]]*=' "$pip_conf" | sed -n 1p | sed 's/.*= *//')
        detail="min-age = ${current}"
    fi

    backup_if_exists "$pip_conf"
    remove_matching_lines "$pip_conf" '^[[:space:]]*(uploaded-prior-to|min-age)[[:space:]]*='

    if grep -q '^\[global\]' "$pip_conf" 2>/dev/null && ! section_has_content "$pip_conf" "[global]"; then
        remove_matching_lines "$pip_conf" '^\\[global\\]$'
    fi
    if grep -q '^\[install\]' "$pip_conf" 2>/dev/null && ! section_has_content "$pip_conf" "[install]"; then
        remove_matching_lines "$pip_conf" '^\\[install\\]$'
    fi

    strip_file_if_whitespace_only "$pip_conf"
    if verify_and_finalize "$pip_conf" "pip" 'uploaded-prior-to\|min-age\|\[install\]\|\[global\]'; then
        emit_config_status "pip" "pip" "removed" "$detail"
    else
        emit_config_status "pip" "pip" "FAIL" "$detail"
    fi
    cleanup_empty_file "$pip_conf"
}

remove_uv() {
    local uv_conf="$UV_CONFIG_PATH"

    if ! grep -q '^exclude-newer[[:space:]]*=' "$uv_conf" 2>/dev/null \
        && ! grep -q '^exclude-newer-package[[:space:]]*=' "$uv_conf" 2>/dev/null; then
        emit_config_status "uv" "uv" "ok" "exclude-newer settings not present"
        SKIPPED_TOOLS+=("uv")
        return 0
    fi

    backup_if_exists "$uv_conf"
    remove_matching_lines "$uv_conf" '^exclude-newer(-package)?[[:space:]]*='

    strip_file_if_whitespace_only "$uv_conf"
    if verify_and_finalize "$uv_conf" "uv" 'exclude-newer'; then
        emit_config_status "uv" "uv" "removed" "exclude-newer settings"
    else
        emit_config_status "uv" "uv" "FAIL" "exclude-newer settings"
    fi
    cleanup_empty_file "$uv_conf"
}

remove_poetry() {
    local poetry_conf="$POETRY_CONFIG_PATH"

    if ! grep -q '^min-release-age[[:space:]]*=' "$poetry_conf" 2>/dev/null \
        && ! grep -q '^min-release-age-exclude[[:space:]]*=' "$poetry_conf" 2>/dev/null \
        && ! grep -q '^min-release-age-exclude-source[[:space:]]*=' "$poetry_conf" 2>/dev/null; then
        emit_config_status "Poetry" "poetry" "ok" "min-release-age settings not present"
        SKIPPED_TOOLS+=("poetry")
        return 0
    fi

    backup_if_exists "$poetry_conf"
    remove_matching_lines "$poetry_conf" '^min-release-age[[:space:]]*='
    remove_matching_lines "$poetry_conf" '^min-release-age-exclude[[:space:]]*='
    remove_matching_lines "$poetry_conf" '^min-release-age-exclude-source[[:space:]]*='

    if grep -q '^\[solver\]' "$poetry_conf" 2>/dev/null && ! section_has_content "$poetry_conf" "[solver]"; then
        remove_matching_lines "$poetry_conf" '^\\[solver\\]$'
    fi

    strip_file_if_whitespace_only "$poetry_conf"
    if verify_and_finalize "$poetry_conf" "poetry" 'min-release-age\|\[solver\]'; then
        emit_config_status "Poetry" "poetry" "removed" "min-release-age settings"
    else
        emit_config_status "Poetry" "poetry" "FAIL" "min-release-age settings"
    fi
    cleanup_empty_file "$poetry_conf"
}

crontab_available() {
    command -v crontab >/dev/null 2>&1
}

# Reads the crontab once and matches in bash. `crontab -l | grep -q` is unsafe
# under pipefail: grep exits at the first match, crontab can then die of SIGPIPE,
# and the pipeline reports "not found" even though the line is there.
crontab_has_marker() {
    local contents
    contents=$(crontab -l 2>/dev/null) || return 1
    [[ "$contents" == *"$1"* ]]
}

# Writes stdin as the new crontab. A failed write is reported by the caller's
# post-check instead of aborting the whole run under `set -e`.
crontab_write() {
    crontab - 2>/dev/null || true
}

remove_cron_marker_entry() {
    local tool_key="$1"
    local tool_display="$2"
    local summary_key="$3"
    local marker="$4"
    local new_crontab

    if ! crontab_available || ! crontab_has_marker "$marker"; then
        emit_config_status "$tool_display" "$tool_key" "ok" "cron job not present"
        SKIPPED_TOOLS+=("$summary_key")
        return 0
    fi

    new_crontab=$(crontab -l 2>/dev/null | grep -vF "$marker" || true)
    if [[ -n "$new_crontab" ]]; then
        printf '%s\n' "$new_crontab" | crontab_write
    else
        crontab -r 2>/dev/null || true
    fi

    if ! crontab_has_marker "$marker"; then
        emit_config_status "$tool_display" "$tool_key" "removed" "daily cron job"
        UPDATED_TOOLS+=("$summary_key")
    else
        emit_config_status "$tool_display" "$tool_key" "FAIL" "could not remove cron job"
        FAILED_TOOLS+=("$summary_key")
    fi
}

# Older releases installed a daily uv refresh job; relative exclude-newer made it
# unnecessary, so normal runs and removal only clean it up.
remove_cron_uv() {
    remove_cron_marker_entry "uv-cron" "uv cron" "cron-uv" "$CRON_MARKER"
}

remove_cron_vlt() {
    if [[ "$VLT_REFRESH_SCHEDULER" == "launchd" ]]; then
        remove_vlt_launchd
    else
        remove_cron_marker_entry "vlt-cron" "vlt cron" "cron-vlt" "$VLT_CRON_MARKER"
    fi
}

remove_npm() {
    local npmrc="$NPMRC_PATH"
    local current

    if ! grep -q '^min-release-age=' "$npmrc" 2>/dev/null \
        && ! grep -q '^min-release-age-exclude' "$npmrc" 2>/dev/null; then
        emit_config_status "npm" "npm" "ok" "min-release-age not present"
        SKIPPED_TOOLS+=("npm")
        return 0
    fi

    current=$(grep '^min-release-age=' "$npmrc" 2>/dev/null | sed -n 1p | sed 's/.*=//' || true)

    backup_if_exists "$npmrc"
    remove_matching_lines "$npmrc" '^min-release-age='
    remove_matching_lines "$npmrc" '^min-release-age-exclude'

    strip_file_if_whitespace_only "$npmrc"
    if verify_and_finalize "$npmrc" "npm" 'min-release-age'; then
        emit_config_status "npm" "npm" "removed" "min-release-age=${current:-unset}"
    else
        emit_config_status "npm" "npm" "FAIL" "min-release-age=${current:-unset}"
    fi
    cleanup_empty_file "$npmrc"
}

remove_pnpm() {
    load_tool_detection_cache
    local pnpm_config
    pnpm_config=$(pnpm_active_config_path)

    if ! grep -q '^minimumReleaseAge:' "$pnpm_config" 2>/dev/null \
        && ! grep -q '^minimumReleaseAgeExclude:' "$pnpm_config" 2>/dev/null \
        && ! grep -q '^minimum-release-age=' "$pnpm_config" 2>/dev/null \
        && ! grep -q '^minimum-release-age-exclude' "$pnpm_config" 2>/dev/null; then
        emit_config_status "pnpm" "pnpm" "ok" "minimum-release-age settings not present"
        SKIPPED_TOOLS+=("pnpm")
        return 0
    fi

    backup_if_exists "$pnpm_config"
    remove_yaml_top_level_key "$pnpm_config" "minimumReleaseAge"
    remove_yaml_top_level_key "$pnpm_config" "minimumReleaseAgeExclude"
    remove_matching_lines "$pnpm_config" '^minimum-release-age='
    remove_matching_lines "$pnpm_config" '^minimum-release-age-exclude'

    strip_file_if_whitespace_only "$pnpm_config"
    if verify_and_finalize "$pnpm_config" "pnpm" 'minimumReleaseAge\|minimum-release-age'; then
        emit_config_status "pnpm" "pnpm" "removed" "minimum-release-age settings ($(pnpm_active_config_label))"
    else
        emit_config_status "pnpm" "pnpm" "FAIL" "minimum-release-age settings"
    fi
    cleanup_empty_file "$pnpm_config"
}

remove_bun() {
    local bunfig="$BUNFIG_PATH"

    if ! grep -q '^minimumReleaseAge[[:space:]]*=' "$bunfig" 2>/dev/null \
        && ! grep -q '^minimumReleaseAgeExcludes[[:space:]]*=' "$bunfig" 2>/dev/null; then
        emit_config_status "bun" "bun" "ok" "minimumReleaseAge settings not present"
        SKIPPED_TOOLS+=("bun")
        return 0
    fi

    backup_if_exists "$bunfig"
    remove_matching_lines "$bunfig" '^minimumReleaseAge[[:space:]]*='
    remove_matching_lines "$bunfig" '^minimumReleaseAgeExcludes[[:space:]]*='

    if grep -q '^\[install\]' "$bunfig" 2>/dev/null && ! section_has_content "$bunfig" "[install]"; then
        remove_matching_lines "$bunfig" '^\\[install\\]$'
    fi

    strip_file_if_whitespace_only "$bunfig"
    if verify_and_finalize "$bunfig" "bun" 'minimumReleaseAge\|minimumReleaseAgeExcludes\|\[install\]'; then
        emit_config_status "bun" "bun" "removed" "minimumReleaseAge settings"
    else
        emit_config_status "bun" "bun" "FAIL" "minimumReleaseAge settings"
    fi
    cleanup_empty_file "$bunfig"
}

remove_yarn_classic() {
    local yarnrc="$YARNRC_PATH"
    local current

    if ! grep -q '^cache-min ' "$yarnrc" 2>/dev/null; then
        emit_config_status "yarn v1" "yarn-classic" "ok" "cache-min not present"
        SKIPPED_TOOLS+=("yarn-classic")
        return 0
    fi

    current=$(grep '^cache-min ' "$yarnrc" | sed -n 1p | awk '{print $2}')

    backup_if_exists "$yarnrc"
    remove_matching_lines "$yarnrc" '^cache-min '

    strip_file_if_whitespace_only "$yarnrc"
    if verify_and_finalize "$yarnrc" "yarn-classic" 'cache-min'; then
        emit_config_status "yarn v1" "yarn-classic" "removed" "cache-min $current"
    else
        emit_config_status "yarn v1" "yarn-classic" "FAIL" "cache-min $current"
    fi
    cleanup_empty_file "$yarnrc"
}

remove_yarn_berry() {
    local yarnrc_yml="$YARNRC_YML_PATH"

    if ! grep -q '^npmMinimalAgeGate:' "$yarnrc_yml" 2>/dev/null \
        && ! grep -q '^npmPreapprovedPackages:' "$yarnrc_yml" 2>/dev/null; then
        emit_config_status "yarn v2+" "yarn-berry" "ok" "native age gate not present"
        SKIPPED_TOOLS+=("yarn-berry")
        return 0
    fi

    backup_if_exists "$yarnrc_yml"
    remove_matching_lines "$yarnrc_yml" '^npmMinimalAgeGate:'
    remove_matching_lines "$yarnrc_yml" '^npmPreapprovedPackages:'

    strip_file_if_whitespace_only "$yarnrc_yml"
    if verify_and_finalize "$yarnrc_yml" "yarn-berry" 'npmMinimalAgeGate\|npmPreapprovedPackages'; then
        emit_config_status "yarn v2+" "yarn-berry" "removed" "native age gate"
    else
        emit_config_status "yarn v2+" "yarn-berry" "FAIL" "native age gate"
    fi
    cleanup_empty_file "$yarnrc_yml"
}

remove_wrapper_tool() {
    local tool_key="$1"
    local tool_display="$2"
    local marker="$3"
    local wrapper_file="$4"
    local source_line="$5"
    local current_age="" rc rc_status=0 had_state=false

    if [[ -f "$wrapper_file" ]]; then
        had_state=true
        if grep -q '^# minimum-release-age:' "$wrapper_file" 2>/dev/null; then
            current_age=$(grep '^# minimum-release-age:' "$wrapper_file" | sed -n 1p | sed 's/^# minimum-release-age: *//')
        fi
    fi

    while IFS= read -r rc; do
        if [[ -f "$rc" ]] && grep -Fxq "$marker" "$rc" 2>/dev/null; then
            had_state=true
            break
        fi
    done < <(shell_rc_files)

    if [[ "$had_state" == false ]]; then
        emit_config_status "$tool_display" "$tool_key" "ok" "wrapper not present"
        SKIPPED_TOOLS+=("$tool_key")
        return 0
    fi

    if [[ -f "$wrapper_file" ]]; then
        rm -f "$wrapper_file"
    fi

    rmdir "$HOME/.config/set-package-min-age" 2>/dev/null || true

    while IFS= read -r rc; do
        if ! remove_rc_source_line "$rc" "$marker" "$source_line"; then
            rc_status=1
        fi
    done < <(shell_rc_files)

    if [[ "$rc_status" -ne 0 ]]; then
        emit_config_status "$tool_display" "$tool_key" "FAIL" "wrapper${current_age:+: $current_age}"
        FAILED_TOOLS+=("$tool_key")
        return 0
    fi

    emit_config_status "$tool_display" "$tool_key" "removed" "wrapper${current_age:+: $current_age}"
    UPDATED_TOOLS+=("$tool_key")
}

remove_deno() {
    remove_wrapper_tool "deno" "deno" "$DENO_WRAPPER_MARKER" \
        "$HOME/.config/set-package-min-age/deno.sh" \
        "$(deno_source_line)"
}

remove_pixi() {
    load_tool_detection_cache
    local manifest="$PIXI_GLOBAL_MANIFEST_PATH" current="" had_wrapper=false

    if legacy_pixi_wrapper_present; then
        had_wrapper=true
    fi
    if [[ -f "$manifest" ]]; then
        current=$(current_pixi_global_exclude_newer "$manifest")
    fi
    # Only remove what this script writes, never a custom table.
    if [[ -n "$current" ]] && ! pixi_line_is_managed "$current"; then
        current=""
    fi

    if [[ "$had_wrapper" == false && -z "$current" ]]; then
        emit_config_status "pixi" "pixi" "ok" "exclude-newer not present"
        SKIPPED_TOOLS+=("pixi")
        return 0
    fi

    if ! cleanup_legacy_pixi_wrapper; then
        emit_config_status "pixi" "pixi" "FAIL" "could not remove legacy pixi shell wrapper from rc files"
        FAILED_TOOLS+=("pixi")
        return 0
    fi

    if [[ -z "$current" ]]; then
        emit_config_status "pixi" "pixi" "removed" "legacy shell wrapper"
        UPDATED_TOOLS+=("pixi")
        return 0
    fi

    backup_if_exists "$manifest"
    remove_toml_root_exact_line "$manifest" "$current"
    if verify_and_finalize "$manifest" "pixi" 'exclude-newer'; then
        emit_config_status "pixi" "pixi" "removed" "pixi global ${current}"
    else
        emit_config_status "pixi" "pixi" "FAIL" "pixi global ${current}"
    fi
}

remove_vlt() {
    local current detail

    if ! grep -q '^[[:space:]]*"before"[[:space:]]*:' "$VLT_CONFIG_PATH" 2>/dev/null; then
        emit_config_status "vlt" "vlt" "ok" "before setting not present"
        SKIPPED_TOOLS+=("vlt")
        return 0
    fi

    current=$(grep '^[[:space:]]*"before"[[:space:]]*:' "$VLT_CONFIG_PATH" | sed -n 1p | sed 's/.*: *"//; s/".*//')
    detail="before = ${current}"

    backup_if_exists "$VLT_CONFIG_PATH"
    remove_vlt_before_config "$VLT_CONFIG_PATH"

    strip_file_if_whitespace_only "$VLT_CONFIG_PATH"
    if verify_and_finalize "$VLT_CONFIG_PATH" "vlt" '"before"\|"config"\|^[{}][,]*$'; then
        emit_config_status "vlt" "vlt" "removed" "$detail"
    else
        emit_config_status "vlt" "vlt" "FAIL" "$detail"
    fi
    cleanup_empty_file "$VLT_CONFIG_PATH"
}

remove_bundler() {
    local bundler_conf="$BUNDLER_CONFIG_PATH"
    local current

    if ! grep -q '^BUNDLE_COOLDOWN:' "$bundler_conf" 2>/dev/null; then
        emit_config_status "Bundler" "bundler" "ok" "cooldown not present"
        SKIPPED_TOOLS+=("bundler")
        return 0
    fi

    current=$(grep '^BUNDLE_COOLDOWN:' "$bundler_conf" | sed -n 1p | sed 's/^[^:]*: *//; s/"//g')

    backup_if_exists "$bundler_conf"
    remove_yaml_top_level_key "$bundler_conf" "BUNDLE_COOLDOWN"

    if verify_and_finalize "$bundler_conf" "bundler" 'BUNDLE_COOLDOWN\|---'; then
        emit_config_status "Bundler" "bundler" "removed" "cooldown = ${current}d"
    else
        emit_config_status "Bundler" "bundler" "FAIL" "cooldown = ${current}d"
    fi
    cleanup_yaml_marker_only_file "$bundler_conf"
}

remove_hex() {
    local hex_conf="$HEX_CONFIG_PATH"
    local current

    if ! grep -q '^[{]cooldown,' "$hex_conf" 2>/dev/null; then
        emit_config_status "Hex" "hex" "ok" "cooldown not present"
        SKIPPED_TOOLS+=("hex")
        return 0
    fi

    current=$(grep '^[{]cooldown,' "$hex_conf" | sed -n 1p | sed 's/.*<<"//; s/d">>.*//')
    backup_if_exists "$hex_conf"
    remove_matching_lines "$hex_conf" '^[{]cooldown,'

    if verify_and_finalize "$hex_conf" "hex" '^[{]cooldown,'; then
        emit_config_status "Hex" "hex" "removed" "cooldown = ${current}d"
    else
        emit_config_status "Hex" "hex" "FAIL" "cooldown = ${current}d"
    fi
    cleanup_empty_file "$hex_conf"
}

validate_configs() {
    load_tool_detection_cache
    local pip_conf="$PIP_CONFIG_PATH"
    local uv_conf="$UV_CONFIG_PATH"
    local poetry_conf="$POETRY_CONFIG_PATH"
    local npmrc="$NPMRC_PATH"
    local pnpm_config
    local bunfig="$BUNFIG_PATH"
    local yarnrc="$YARNRC_PATH"
    local yarnrc_yml="$YARNRC_YML_PATH"
    local bundler_conf="$BUNDLER_CONFIG_PATH"
    local hex_conf="$HEX_CONFIG_PATH"
    local expected_vlt_before="\"before\": \"$(date_days_ago_rfc3339 "$MIN_AGE_DAYS")\""
    local expected_pip_line="uploaded-prior-to = $(pip_uploaded_prior_to_value)"
    local expected_uv_date="exclude-newer = \"P${MIN_AGE_DAYS}D\""
    local expected_poetry_age="min-release-age = ${MIN_AGE_DAYS}"
    local expected_pnpm_age="minimum-release-age=$(( MIN_AGE_DAYS * 1440 ))"
    local expected_bun_age="minimumReleaseAge = $(( MIN_AGE_DAYS * 86400 ))"
    local expected_yarn_v1_age="cache-min $(( MIN_AGE_DAYS * 86400 ))"
    local expected_yarn_v2_age="npmMinimalAgeGate: $(yaml_quote "${MIN_AGE_DAYS}d")"
    local expected_bundler_age="BUNDLE_COOLDOWN: \"${MIN_AGE_DAYS}\""
    local expected_hex_age="{cooldown,<<\"${MIN_AGE_DAYS}d\">>}."
    local expected_uv_exceptions=""
    local expected_poetry_exceptions=""
    local expected_poetry_source_exceptions=""
    local expected_npm_exceptions=""
    local expected_bun_exceptions=""
    local expected_yarn_exceptions=""
    local expected_pnpm_exceptions=""
    local current_exceptions current_source_exceptions item

    pnpm_config=$(pnpm_active_config_path)

    if pnpm_active_config_is_yaml; then
        expected_pnpm_age="minimumReleaseAge: $(( MIN_AGE_DAYS * 1440 ))"
    fi

    if [[ ${#UV_EXCEPTIONS[@]} -gt 0 ]]; then
        expected_uv_exceptions=$(build_uv_exception_line)
    fi
    if [[ ${#POETRY_EXCEPTIONS[@]} -gt 0 ]]; then
        expected_poetry_exceptions="min-release-age-exclude = $(toml_array "${POETRY_EXCEPTIONS[@]}")"
    fi
    if [[ ${#POETRY_SOURCE_EXCEPTIONS[@]} -gt 0 ]]; then
        expected_poetry_source_exceptions="min-release-age-exclude-source = $(toml_array "${POETRY_SOURCE_EXCEPTIONS[@]}")"
    fi
    if [[ ${#NPM_EXCEPTIONS[@]} -gt 0 ]]; then
        for item in "${NPM_EXCEPTIONS[@]}"; do
            expected_npm_exceptions+=$'min-release-age-exclude[]='
            expected_npm_exceptions+="$item"
            expected_npm_exceptions+=$'\n'
        done
        expected_npm_exceptions=${expected_npm_exceptions%$'\n'}
    fi
    if [[ ${#BUN_EXCEPTIONS[@]} -gt 0 ]]; then
        expected_bun_exceptions="minimumReleaseAgeExcludes = $(toml_array "${BUN_EXCEPTIONS[@]}")"
    fi
    if [[ ${#YARN_EXCEPTIONS[@]} -gt 0 ]]; then
        expected_yarn_exceptions="npmPreapprovedPackages: $(yaml_flow_array "${YARN_EXCEPTIONS[@]}")"
    fi
    if [[ ${#PNPM_EXCEPTIONS[@]} -gt 0 ]]; then
        if pnpm_active_config_is_yaml; then
            expected_pnpm_exceptions="minimumReleaseAgeExclude: $(yaml_flow_array "${PNPM_EXCEPTIONS[@]}")"
        else
            for item in "${PNPM_EXCEPTIONS[@]}"; do
                expected_pnpm_exceptions+=$'minimum-release-age-exclude[]='
                expected_pnpm_exceptions+="$item"
                expected_pnpm_exceptions+=$'\n'
            done
            expected_pnpm_exceptions=${expected_pnpm_exceptions%$'\n'}
        fi
    fi

    if [[ -f "$pip_conf" ]]; then
        if grep -Fqx "$expected_pip_line" "$pip_conf" 2>/dev/null \
            && ! grep -q '^[[:space:]]*min-age[[:space:]]*=' "$pip_conf" 2>/dev/null; then
            record_validation_ok "pip" "uploaded-prior-to matches" "pip"
        else
            record_validation_fail "pip" "uploaded-prior-to setting does not match" "pip"
        fi
    else
        record_validation_skip "pip" "config not present" "pip"
    fi

    if [[ -f "$uv_conf" ]]; then
        current_exceptions=$(current_lines_or_empty "$uv_conf" '^exclude-newer-package[[:space:]]*=')
        if grep -Fqx "$expected_uv_date" "$uv_conf" 2>/dev/null \
            && [[ "$current_exceptions" == "$expected_uv_exceptions" ]]; then
            record_validation_ok "uv" "exclude-newer settings match" "uv"
        else
            record_validation_fail "uv" "exclude-newer settings do not match" "uv"
        fi
    else
        record_validation_skip "uv" "config not present" "uv"
    fi

    if [[ -f "$poetry_conf" ]]; then
        current_exceptions=$(current_lines_or_empty "$poetry_conf" '^min-release-age-exclude[[:space:]]*=')
        current_source_exceptions=$(current_lines_or_empty "$poetry_conf" '^min-release-age-exclude-source[[:space:]]*=')
        if grep -Fqx "$expected_poetry_age" "$poetry_conf" 2>/dev/null \
            && [[ "$current_exceptions" == "$expected_poetry_exceptions" ]] \
            && [[ "$current_source_exceptions" == "$expected_poetry_source_exceptions" ]]; then
            record_validation_ok "Poetry" "min-release-age settings match" "poetry"
        else
            record_validation_fail "Poetry" "min-release-age settings do not match" "poetry"
        fi
    else
        record_validation_skip "Poetry" "config not present" "poetry"
    fi

    if [[ -f "$npmrc" ]]; then
        current_exceptions=$(current_lines_or_empty "$npmrc" '^min-release-age-exclude')
        if grep -Fqx "min-release-age=${MIN_AGE_DAYS}" "$npmrc" 2>/dev/null \
            && [[ "$current_exceptions" == "$expected_npm_exceptions" ]]; then
            record_validation_ok "npm" "min-release-age=${MIN_AGE_DAYS}" "npm"
        else
            record_validation_fail "npm" "min-release-age settings do not match" "npm"
        fi
    else
        record_validation_skip "npm" "config not present" "npm"
    fi

    if [[ -f "$PNPM_RC_PATH" && "$pnpm_config" != "$PNPM_RC_PATH" ]] \
        && { grep -q '^minimum-release-age=' "$PNPM_RC_PATH" 2>/dev/null || grep -q '^minimum-release-age-exclude' "$PNPM_RC_PATH" 2>/dev/null; }; then
        record_validation_fail "pnpm" "legacy rc still has minimum-release-age settings" "pnpm"
    elif [[ -f "$pnpm_config" ]]; then
        current_exceptions=$(current_lines_or_empty "$pnpm_config" '^minimumReleaseAgeExclude:')
        if [[ -z "$current_exceptions" ]]; then
            current_exceptions=$(current_lines_or_empty "$pnpm_config" '^minimum-release-age-exclude')
        fi
        if grep -Fqx "$expected_pnpm_age" "$pnpm_config" 2>/dev/null \
            && [[ "$current_exceptions" == "$expected_pnpm_exceptions" ]]; then
            record_validation_ok "pnpm" "$expected_pnpm_age" "pnpm"
        else
            record_validation_fail "pnpm" "minimum-release-age settings do not match" "pnpm"
        fi
    else
        record_validation_skip "pnpm" "config not present" "pnpm"
    fi

    if [[ -f "$bunfig" ]]; then
        current_exceptions=$(current_lines_or_empty "$bunfig" '^minimumReleaseAgeExcludes[[:space:]]*=')
        if grep -Fqx "$expected_bun_age" "$bunfig" 2>/dev/null \
            && [[ "$current_exceptions" == "$expected_bun_exceptions" ]]; then
            record_validation_ok "bun" "$expected_bun_age" "bun"
        else
            record_validation_fail "bun" "minimumReleaseAge settings do not match" "bun"
        fi
    else
        record_validation_skip "bun" "config not present" "bun"
    fi

    if [[ -f "$yarnrc" ]]; then
        if grep -Fqx "$expected_yarn_v1_age" "$yarnrc" 2>/dev/null; then
            record_validation_ok "yarn v1" "$expected_yarn_v1_age" "yarn-classic"
        else
            record_validation_fail "yarn v1" "expected $expected_yarn_v1_age" "yarn-classic"
        fi
    else
        record_validation_skip "yarn v1" "config not present" "yarn-classic"
    fi

    if [[ -f "$yarnrc_yml" ]]; then
        current_exceptions=$(current_lines_or_empty "$yarnrc_yml" '^npmPreapprovedPackages:')
        if grep -Fqx "$expected_yarn_v2_age" "$yarnrc_yml" 2>/dev/null \
            && [[ "$current_exceptions" == "$expected_yarn_exceptions" ]]; then
            record_validation_ok "yarn v2+" "native age gate matches" "yarn-berry"
        else
            record_validation_fail "yarn v2+" "native age gate settings do not match" "yarn-berry"
        fi
    else
        record_validation_skip "yarn v2+" "config not present" "yarn-berry"
    fi

    validate_wrapper_tool "deno" "deno" "$DENO_WRAPPER_MARKER" \
        "$HOME/.config/set-package-min-age/deno.sh" \
        "$(deno_source_line)" \
        "--minimum-dependency-age=P${MIN_AGE_DAYS}D"

    validate_pixi

    if [[ -f "$VLT_CONFIG_PATH" ]]; then
        if grep -Fq "$expected_vlt_before" "$VLT_CONFIG_PATH" 2>/dev/null; then
            record_validation_ok "vlt" "before matches" "vlt"
        else
            record_validation_fail "vlt" "before setting does not match" "vlt"
        fi
    else
        record_validation_skip "vlt" "config not present" "vlt"
    fi

    if [[ -f "$bundler_conf" ]]; then
        if grep -Fqx "$expected_bundler_age" "$bundler_conf" 2>/dev/null; then
            record_validation_ok "Bundler" "cooldown matches" "bundler"
        else
            record_validation_fail "Bundler" "cooldown setting does not match" "bundler"
        fi
    else
        record_validation_skip "Bundler" "config not present" "bundler"
    fi

    if [[ -f "$hex_conf" ]]; then
        if grep -Fqx "$expected_hex_age" "$hex_conf" 2>/dev/null \
            && { [[ ${#HEX_EXCEPTIONS[@]} -eq 0 ]] || grep -Fqx "$(hex_exclude_repos_line)" "$hex_conf" 2>/dev/null; }; then
            record_validation_ok "Hex" "cooldown matches" "hex"
        else
            record_validation_fail "Hex" "cooldown setting does not match" "hex"
        fi
    else
        record_validation_skip "Hex" "config not present" "hex"
    fi

    validate_new_toml_tools
}

validate_new_toml_tools() {
    local mise_list=""

    if [[ ${#MISE_EXCEPTIONS[@]} -gt 0 ]]; then
        mise_list="minimum_release_age_excludes = $(mise_exceptions_value)"
    fi

    validate_toml_section_age "PDM" "pdm" "$PDM_CONFIG_PATH" "exclude-newer = $(pdm_exclude_newer_value)"
    if [[ -f "$CARGO_CONFIG_PATH" ]] && grep -Fqx "global-min-publish-age = $(cargo_min_publish_age_value)" "$CARGO_CONFIG_PATH" \
        && [[ "$(cargo_managed_registries "$CARGO_CONFIG_PATH")" != "$(cargo_desired_registries)" ]]; then
        record_validation_fail "Cargo" "registry exemptions do not match" "cargo"
    else
        validate_toml_section_age "Cargo" "cargo" "$CARGO_CONFIG_PATH" "global-min-publish-age = $(cargo_min_publish_age_value)"
    fi
    validate_toml_section_age "mise" "mise" "$MISE_CONFIG_PATH" "minimum_release_age = $(mise_minimum_release_age_value)" \
        "minimum_release_age_excludes" "$mise_list"
}

validate_pixi() {
    local manifest="$PIXI_GLOBAL_MANIFEST_PATH" current

    if legacy_pixi_wrapper_present; then
        record_validation_fail "pixi" "broken legacy shell wrapper still installed" "pixi"
        return 0
    fi
    if [[ ! -f "$manifest" ]] || ! pixi_supports_global_exclude_newer; then
        record_validation_skip "pixi" "pixi global manifest not managed" "pixi"
        return 0
    fi

    current=$(current_pixi_global_exclude_newer "$manifest")
    if [[ "$current" == "$(pixi_global_exclude_newer_line)" ]]; then
        record_validation_ok "pixi" "pixi global exclude-newer matches" "pixi"
    elif [[ -n "$current" ]] && ! pixi_line_is_managed "$current"; then
        record_validation_skip "pixi" "custom exclude-newer table" "pixi"
    else
        record_validation_fail "pixi" "pixi global exclude-newer does not match" "pixi"
    fi
}

validate_wrapper_tool() {
    local tool_display="$1"
    local tool_key="$2"
    local marker="$3"
    local wrapper_file="$4"
    local source_line="$5"
    local expected_flag="$6"
    local desired_age_marker="# minimum-release-age: ${MIN_AGE_DAYS}d"
    local rc rc_ok=false

    if [[ ! -f "$wrapper_file" ]]; then
        record_validation_skip "$tool_display" "wrapper not present" "$tool_key"
        return 0
    fi

    if ! grep -Fxq "$marker" "$wrapper_file" 2>/dev/null \
        || ! grep -Fxq "$desired_age_marker" "$wrapper_file" 2>/dev/null \
        || ! grep -Fq -- "$expected_flag" "$wrapper_file" 2>/dev/null; then
        record_validation_fail "$tool_display" "wrapper contents do not match" "$tool_key"
        return 0
    fi

    while IFS= read -r rc; do
        if [[ -f "$rc" ]] \
            && grep -Fxq "$marker" "$rc" 2>/dev/null \
            && grep -Fxq "$source_line" "$rc" 2>/dev/null; then
            rc_ok=true
            break
        fi
    done < <(shell_rc_files)

    if [[ "$rc_ok" == true ]]; then
        record_validation_ok "$tool_display" "wrapper sourced from rc" "$tool_key"
    else
        record_validation_fail "$tool_display" "no rc file sources the wrapper" "$tool_key"
    fi
}

finish_report() {
    local summary validated=0 total=0 idx

    for idx in "${!RESULT_VALIDATION_STATUSES[@]}"; do
        case "${RESULT_VALIDATION_STATUSES[$idx]}" in
            ok) validated=$((validated + 1)); total=$((total + 1)) ;;
            FAIL) total=$((total + 1)) ;;
        esac
    done

    ui_heading "Summary"
    summary=$(summary_counts_text)
    if [[ "$RUN_MODE" == "apply" ]]; then
        summary=$(ui_join "$summary" "$validated/$total verified")
    fi
    ui_text "$summary"

    print_changed_files
    if ! print_needs_attention; then
        printf '\n'
        return 1
    fi
    printf '\n'
    ui_text "$(ui_paint "$UI_C_GREEN" "Done.")"
    printf '\n'
}

main() {
    parse_args "$@"

    if [[ "${SET_MINIMUM_PACKAGE_RELEASE_AGE_REFRESH_VLT:-}" == "1" ]]; then
        setup_vlt
        return
    fi

    # Re-detect width, color, and symbols for this run.
    ui_reset
    NORMAL_MODE_REPORTING=false
    RESULT_TOOL_KEYS=()
    RESULT_CONFIG_STATUSES=()
    RESULT_CONFIG_DETAILS=()
    RESULT_VALIDATION_STATUSES=()
    RESULT_VALIDATION_DETAILS=()
    FAILED_TOOLS=()
    SKIPPED_TOOLS=()
    UPDATED_TOOLS=()
    VALIDATED_TOOLS=()
    VALIDATION_FAILED_TOOLS=()
    PREFLIGHT_FAILED_TOOLS=()
    PREFLIGHT_FAILED_DETAILS=()
    PREFLIGHT_WARN_TOOLS=()
    PREFLIGHT_WARN_DETAILS=()
    UI_NOT_INSTALLED=()

    if [[ "$REMOVE_MODE" == true || "$REMOVE_SCOPED_MODE" == true ]]; then
        RUN_MODE="remove"
        printf '\n'
        if [[ "$REMOVE_MODE" == true ]]; then
            ui_header "set-minimum-package-release-age" "$PLATFORM_NAME" "remove all managed settings"
        else
            ui_header "set-minimum-package-release-age" "$PLATFORM_NAME" "remove: $(ui_comma_list "${REMOVE_TOOLS[@]}")"
        fi
        print_tool_overview

        NORMAL_MODE_REPORTING=true
        init_results_table
        ui_heading "Removing"
        if [[ "$REMOVE_MODE" == true ]]; then
            run_remove_tools "${ALL_TOOL_KEYS[@]}"
        else
            run_remove_tools "${REMOVE_TOOLS[@]}"
        fi
        finish_report || true
        NORMAL_MODE_REPORTING=false
        return 0
    fi

    RUN_MODE="apply"
    printf '\n'
    ui_header "set-minimum-package-release-age" "$PLATFORM_NAME" "minimum age ${MIN_AGE_DAYS} days"

    ui_heading "Tools"
    load_tool_detection_cache
    run_preflight_checks || true
    print_not_installed_tools

    NORMAL_MODE_REPORTING=true
    init_results_table

    ui_heading "Changes"
    run_progress_step pip config setup_pip
    run_progress_step uv config setup_uv
    run_progress_step uv-cron cleanup remove_cron_uv
    run_progress_step poetry config setup_poetry
    run_progress_step pdm config setup_pdm
    run_progress_step npm config setup_npm
    run_progress_step pnpm config setup_pnpm
    run_progress_step bun config setup_bun
    run_progress_step deno config setup_deno
    run_progress_step pixi config setup_pixi
    run_progress_step yarn-classic config setup_yarn_classic
    run_progress_step yarn-berry config setup_yarn_berry
    run_progress_step vlt config setup_vlt
    run_progress_step vlt-cron config setup_cron_vlt
    run_progress_step bundler config setup_bundler
    run_progress_step hex config setup_hex
    run_progress_step cargo config setup_cargo
    run_progress_step mise config setup_mise

    validate_configs
    local status=0
    finish_report || status=1
    NORMAL_MODE_REPORTING=false
    return "$status"
}
