#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

PLATFORM_NAME="${PLATFORM_NAME:-Unknown}"
PNPM_RC_PATH="${PNPM_RC_PATH:-$HOME/.config/pnpm/rc}"

REMOVE_MODE=false
REMOVE_SCOPED_MODE=false
CUSTOM_DAYS=""
MIN_AGE_DAYS=7
BACKUP_SUFFIX=""
REMOVE_TOOLS=()
UV_EXCEPTIONS=()
PNPM_EXCEPTIONS=()
BUN_EXCEPTIONS=()
YARN_EXCEPTIONS=()
TOOL_DETECTION_CACHE=""
FAILED_TOOLS=()
SKIPPED_TOOLS=()
UPDATED_TOOLS=()
VALIDATED_TOOLS=()
VALIDATION_FAILED_TOOLS=()
PREFLIGHT_FAILED_TOOLS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [DAYS]

Set a minimum package release age across pip, uv, npm, pnpm, bun, and yarn.

Arguments:
  DAYS                    Minimum age in days (default: 7). Accepts "14" or "14d".

Options:
  --exception SPEC        Add a native exception in the form:
                          uv:<package>=false
                          uv:<package>=<duration-or-rfc3339>
                          pnpm:<selector>
                          bun:<package>
                          yarn-berry:<pattern>
  --remove                Remove all settings previously added by this script.
  --remove-tool TOOL      Remove settings only for a specific managed tool. May be provided
                          multiple times.
  -h, --help              Show this help message and exit.

Examples:
  $(basename "$0")                         # Set minimum age to 7 days (default)
  $(basename "$0") 14                      # Set minimum age to 14 days
  $(basename "$0") 1d                      # Set minimum age to 1 day
  $(basename "$0") --exception uv:foo=false 14
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
        pip) printf '%s\n' "$HOME/.config/pip/pip.conf" ;;
        uv) printf '%s\n' "$HOME/.config/uv/uv.toml" ;;
        uv-cron) printf '%s\n' "crontab entry ($CRON_MARKER)" ;;
        npm) printf '%s\n' "$HOME/.npmrc" ;;
        pnpm) printf '%s\n' "$PNPM_RC_PATH" ;;
        bun) printf '%s\n' "$HOME/.bunfig.toml" ;;
        yarn-classic) printf '%s\n' "$HOME/.yarnrc" ;;
        yarn-berry) printf '%s\n' "$HOME/.yarnrc.yml" ;;
        *) return 1 ;;
    esac
}

tool_supports_native_exceptions() {
    case "$1" in
        uv|pnpm|bun|yarn-berry) return 0 ;;
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
        pip|npm|yarn-classic)
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
        pip|uv|uv-cron|npm|pnpm|bun|yarn-classic|yarn-berry)
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
    PNPM_EXCEPTIONS=()
    BUN_EXCEPTIONS=()
    YARN_EXCEPTIONS=()
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
        if [[ ${#UV_EXCEPTIONS[@]} -gt 0 || ${#PNPM_EXCEPTIONS[@]} -gt 0 || ${#BUN_EXCEPTIONS[@]} -gt 0 || ${#YARN_EXCEPTIONS[@]} -gt 0 ]]; then
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

print_status() {
    printf "  %-16s %-10s %s\n" "$1" "$2" "$3"
}

print_overview_status() {
    printf "  %-16s %-10s %-12s %s\n" "$1" "$2" "$3" "$4"
}

print_readiness_status() {
    printf "  %-16s %-10s %-12s %-10s %s\n" "$1" "$2" "$3" "$4" "$5"
}

resolve_tool_path_with_which() {
    local cmd="$1"
    local path=""

    path=$(which "$cmd" 2>/dev/null) || return 1
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
            raw_version=$("$path" --version 2>/dev/null || "$path" self version 2>/dev/null || true)
            ;;
        *)
            raw_version=$("$path" --version 2>/dev/null || true)
            ;;
    esac

    extract_semver "$raw_version" || true
}

detect_supported_tool_installations() {
    local tool_path=""
    local tool_version=""
    local yarn_path=""
    local yarn_version=""
    local yarn_major=""

    if tool_path=$(resolve_tool_path_with_which "pip"); then
        tool_version=$(detect_command_version "pip" "$tool_path")
        printf 'pip|yes|%s|%s\n' "$tool_path" "${tool_version:-unknown}"
    elif tool_path=$(resolve_tool_path_with_which "pip3"); then
        tool_version=$(detect_command_version "pip" "$tool_path")
        printf 'pip|yes|%s|%s\n' "$tool_path" "${tool_version:-unknown}"
    else
        printf 'pip|no|not found|n/a\n'
    fi

    if tool_path=$(resolve_tool_path_with_which "uv"); then
        tool_version=$(detect_command_version "uv" "$tool_path")
        printf 'uv|yes|%s|%s\n' "$tool_path" "${tool_version:-unknown}"
    else
        printf 'uv|no|not found|n/a\n'
    fi

    if tool_path=$(resolve_tool_path_with_which "npm"); then
        tool_version=$(detect_command_version "npm" "$tool_path")
        printf 'npm|yes|%s|%s\n' "$tool_path" "${tool_version:-unknown}"
    else
        printf 'npm|no|not found|n/a\n'
    fi

    if tool_path=$(resolve_tool_path_with_which "pnpm"); then
        tool_version=$(detect_command_version "pnpm" "$tool_path")
        printf 'pnpm|yes|%s|%s\n' "$tool_path" "${tool_version:-unknown}"
    else
        printf 'pnpm|no|not found|n/a\n'
    fi

    if tool_path=$(resolve_tool_path_with_which "bun"); then
        tool_version=$(detect_command_version "bun" "$tool_path")
        printf 'bun|yes|%s|%s\n' "$tool_path" "${tool_version:-unknown}"
    else
        printf 'bun|no|not found|n/a\n'
    fi

    if yarn_path=$(resolve_tool_path_with_which "yarn"); then
        yarn_version=$(detect_command_version "yarn" "$yarn_path")
        if [[ "$yarn_version" =~ ^([0-9]+) ]]; then
            yarn_major="${BASH_REMATCH[1]}"
            if [[ "$yarn_major" == "1" ]]; then
                printf 'yarn v1|yes|%s|%s\n' "$yarn_path" "${yarn_version:-unknown}"
                printf 'yarn v2+|no|%s|%s\n' "$yarn_path" "${yarn_version:-unknown}"
                return
            fi

            if [[ "$yarn_major" -ge 2 ]]; then
                printf 'yarn v1|no|%s|%s\n' "$yarn_path" "${yarn_version:-unknown}"
                printf 'yarn v2+|yes|%s|%s\n' "$yarn_path" "${yarn_version:-unknown}"
                return
            fi
        fi

        printf 'yarn v1|no|%s|%s\n' "$yarn_path" "${yarn_version:-unknown}"
        printf 'yarn v2+|no|%s|%s\n' "$yarn_path" "${yarn_version:-unknown}"
        return
    fi

    printf 'yarn v1|no|not found|n/a\n'
    printf 'yarn v2+|no|not found|n/a\n'
}

get_tool_detection_cache() {
    if [[ -z "$TOOL_DETECTION_CACHE" ]]; then
        TOOL_DETECTION_CACHE=$(detect_supported_tool_installations)
    fi
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

record_preflight_ok() {
    local tool="$1"
    local installed="$2"
    local version="$3"
    local detail="$4"
    print_readiness_status "$tool" "$installed" "$version" "ok" "$detail"
}

record_preflight_skip() {
    local tool="$1"
    local installed="$2"
    local version="$3"
    local detail="$4"
    print_readiness_status "$tool" "$installed" "$version" "--" "$detail"
}

record_preflight_fail() {
    local tool="$1"
    local installed="$2"
    local version="$3"
    local detail="$4"
    local tool_key="${5:-$tool}"
    print_readiness_status "$tool" "$installed" "$version" "FAIL" "$detail"
    PREFLIGHT_FAILED_TOOLS+=("$tool_key")
}

ensure_tool_version() {
    local tool="$1"
    local required="$2"
    local feature="$3"
    local fail_key="${4:-$tool}"
    local installed version

    installed=$(lookup_detected_tool_field "$tool" installed)
    version=$(lookup_detected_tool_field "$tool" version)

    if [[ "$installed" != "yes" ]]; then
        record_preflight_skip "$tool" "$installed" "$version" "$feature skipped; tool not installed"
        return 0
    fi

    if [[ -z "$version" || "$version" == "unknown" ]]; then
        record_preflight_fail "$tool" "$installed" "$version" "$feature requires version detection; installed version could not be determined" "$fail_key"
        return 1
    fi

    if version_gte "$version" "$required"; then
        record_preflight_ok "$tool" "$installed" "$version" "$feature requires >= $required"
        return 0
    fi

    record_preflight_fail "$tool" "$installed" "$version" "$feature requires >= $required" "$fail_key"
    return 1
}

print_tool_overview() {
    local tool installed path version

    echo "  Tool overview"
    echo "  ----------------------------------------------------------"
    print_overview_status "TOOL" "INSTALLED" "VERSION" "PATH"
    echo "  ----------------------------------------------------------"

    while IFS='|' read -r tool installed path version; do
        print_overview_status "$tool" "$installed" "$version" "$path"
    done < <(get_tool_detection_cache)

    echo ""
}

backup_if_exists() {
    local file="$1"
    if [[ -f "$file" && -s "$file" ]]; then
        cp "$file" "${file}${BACKUP_SUFFIX}"
    fi
}

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
        }
        function flush_pending() {
            if (in_section && !key_written) {
                print replacement
                key_written = 1
            }
        }
        $0 == section_line {
            section_found = 1
            in_section = 1
            key_written = 0
            print
            next
        }
        in_section && /^\[/ {
            flush_pending()
            in_section = 0
            print
            next
        }
        in_section && $0 ~ key_regex {
            if (!key_written) {
                print replacement
                key_written = 1
            }
            next
        }
        { print }
        END {
            if (in_section) {
                flush_pending()
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

record_validation_ok() {
    local tool_display="$1"
    local detail="$2"
    local tool_key="${3:-$tool_display}"
    print_status "$tool_display" "ok" "$detail"
    VALIDATED_TOOLS+=("$tool_key")
}

record_validation_fail() {
    local tool_display="$1"
    local detail="$2"
    local tool_key="${3:-$tool_display}"
    print_status "$tool_display" "FAIL" "$detail"
    VALIDATION_FAILED_TOOLS+=("$tool_key")
}

date_days_ago_rfc3339() {
    if declare -F platform_date_days_ago_rfc3339 >/dev/null; then
        platform_date_days_ago_rfc3339 "$1"
        return
    fi
    date -d "$1 days ago" +%Y-%m-%dT00:00:00Z
}

run_preflight_checks() {
    local status=0
    local required_pnpm_version="10.16.0"
    local pnpm_feature="minimum-release-age"
    local selector
    local installed version yarn_v1_installed yarn_v2_installed yarn_version

    PREFLIGHT_FAILED_TOOLS=()

    installed=$(lookup_detected_tool_field "pip" installed)
    version=$(lookup_detected_tool_field "pip" version)
    if [[ "$installed" == "yes" ]]; then
        record_preflight_ok "pip" "$installed" "$version" "no runtime gate"
    else
        record_preflight_skip "pip" "$installed" "$version" "not installed; config can still be written"
    fi

    installed=$(lookup_detected_tool_field "uv" installed)
    version=$(lookup_detected_tool_field "uv" version)
    if [[ "$installed" == "yes" ]]; then
        record_preflight_ok "uv" "$installed" "$version" "no runtime gate"
    else
        record_preflight_skip "uv" "$installed" "$version" "not installed; config can still be written"
    fi

    ensure_tool_version "npm" "11.10.0" "min-release-age" || status=1

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
    if [[ "$installed" == "yes" ]]; then
        record_preflight_ok "bun" "$installed" "$version" "no runtime gate"
    else
        record_preflight_skip "bun" "$installed" "$version" "not installed; config can still be written"
    fi

    installed=$(lookup_detected_tool_field "yarn v1" installed)
    version=$(lookup_detected_tool_field "yarn v1" version)
    if [[ "$installed" == "yes" ]]; then
        record_preflight_ok "yarn v1" "$installed" "$version" "cache-min workaround; no runtime gate"
    else
        record_preflight_skip "yarn v1" "$installed" "$version" "not installed"
    fi

    if [[ ${#YARN_EXCEPTIONS[@]} -gt 0 ]]; then
        yarn_v1_installed=$(lookup_detected_tool_field "yarn v1" installed)
        yarn_v2_installed=$(lookup_detected_tool_field "yarn v2+" installed)
        yarn_version=$(lookup_detected_tool_field "yarn v2+" version)
        version="$yarn_version"

        if [[ "$yarn_v2_installed" == "yes" ]]; then
            record_preflight_ok "yarn v2+" "$yarn_v2_installed" "$version" "native exceptions supported"
        elif [[ "$yarn_v1_installed" == "yes" ]]; then
            record_preflight_fail "yarn v2+" "$yarn_v2_installed" "$version" "yarn-berry exceptions require Yarn >= 2" "yarn-berry"
            status=1
        else
            record_preflight_skip "yarn v2+" "$yarn_v2_installed" "$version" "native exceptions requested; tool not installed"
        fi
    else
        installed=$(lookup_detected_tool_field "yarn v2+" installed)
        version=$(lookup_detected_tool_field "yarn v2+" version)
        if [[ "$installed" == "yes" ]]; then
            record_preflight_ok "yarn v2+" "$installed" "$version" "no runtime gate"
        else
            record_preflight_skip "yarn v2+" "$installed" "$version" "not installed; config may still be written"
        fi
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
            npm) remove_npm ;;
            pnpm) remove_pnpm ;;
            bun) remove_bun ;;
            yarn-classic) remove_yarn_classic ;;
            yarn-berry) remove_yarn_berry ;;
        esac
    done
}

print_config_files() {
    echo "  Config files"
    echo "  ----------------------------------------------------------"
    echo "  pip            $(tool_config_path pip)"
    echo "  uv             $(tool_config_path uv)"
    echo "  npm            $(tool_config_path npm)"
    echo "  pnpm           $(tool_config_path pnpm)"
    echo "  bun            $(tool_config_path bun)"
    echo "  yarn v1        $(tool_config_path yarn-classic)"
    echo "  yarn v2+       $(tool_config_path yarn-berry)"
    echo ""
}

setup_pip() {
    local pip_conf_dir="$HOME/.config/pip"
    local pip_conf="$pip_conf_dir/pip.conf"
    local desired_line="min-age = ${MIN_AGE_DAYS}d"

    mkdir -p "$pip_conf_dir"

    if grep -q "^${desired_line}$" "$pip_conf" 2>/dev/null; then
        print_status "pip" "ok" "$desired_line"
        SKIPPED_TOOLS+=("pip")
        return 0
    fi

    backup_if_exists "$pip_conf"
    ensure_file_exists "$pip_conf"

    if grep -q '^\[global\]' "$pip_conf" 2>/dev/null; then
        if grep -q '^[[:space:]]*min-age' "$pip_conf" 2>/dev/null; then
            local current
            current=$(grep '^[[:space:]]*min-age' "$pip_conf" | head -1 | sed 's/.*= *//')
            print_status "pip" "updated" "$current --> ${MIN_AGE_DAYS}d"
        else
            print_status "pip" "added" "$desired_line"
        fi
        upsert_line_in_section "$pip_conf" "[global]" '^[[:space:]]*min-age[[:space:]]*=' "$desired_line"
    else
        print_status "pip" "added" "$desired_line (new [global] section)"
        printf '\n[global]\n%s\n' "$desired_line" >> "$pip_conf"
    fi

    verify_and_finalize "$pip_conf" "pip" 'min-age\|\[global\]' || true
}

setup_uv() {
    local uv_conf_dir="$HOME/.config/uv"
    local uv_conf="$uv_conf_dir/uv.toml"
    local exclude_newer_date desired_exception_line current_exceptions desired_exceptions

    exclude_newer_date=$(date_days_ago_rfc3339 "$MIN_AGE_DAYS")
    desired_exceptions=""
    if [[ ${#UV_EXCEPTIONS[@]} -gt 0 ]]; then
        desired_exceptions=$(build_uv_exception_line)
    fi

    mkdir -p "$uv_conf_dir"
    touch "$uv_conf"

    current_exceptions=$(current_lines_or_empty "$uv_conf" '^exclude-newer-package[[:space:]]*=')
    if grep -q "^exclude-newer = \"${exclude_newer_date}\"$" "$uv_conf" 2>/dev/null \
        && [[ "$current_exceptions" == "$desired_exceptions" ]]; then
        print_status "uv" "ok" "exclude-newer = \"${exclude_newer_date}\""
        SKIPPED_TOOLS+=("uv")
        return 0
    fi

    backup_if_exists "$uv_conf"

    if grep -q '^exclude-newer[[:space:]]*=' "$uv_conf" 2>/dev/null; then
        local current
        current=$(grep '^exclude-newer[[:space:]]*=' "$uv_conf" | head -1 | sed 's/.*= *//')
        print_status "uv" "updated" "$current --> \"${exclude_newer_date}\""
    else
        print_status "uv" "added" "exclude-newer = \"${exclude_newer_date}\""
    fi
    replace_or_append_line "$uv_conf" '^exclude-newer[[:space:]]*=' "exclude-newer = \"${exclude_newer_date}\""

    if [[ ${#UV_EXCEPTIONS[@]} -gt 0 ]]; then
        desired_exception_line=$(build_uv_exception_line)
        if grep -q '^exclude-newer-package[[:space:]]*=' "$uv_conf" 2>/dev/null; then
            print_status "uv exceptions" "updated" "$desired_exception_line"
        else
            print_status "uv exceptions" "added" "$desired_exception_line"
        fi
        replace_or_append_line "$uv_conf" '^exclude-newer-package[[:space:]]*=' "$desired_exception_line"
    else
        remove_matching_lines "$uv_conf" '^exclude-newer-package[[:space:]]*='
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
    cron_cmd=$(platform_build_uv_cron_command "$min_age" "$uv_conf")

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
    local desired_line="min-release-age=${MIN_AGE_DAYS}"

    touch "$npmrc"

    if grep -q "^${desired_line}$" "$npmrc" 2>/dev/null; then
        print_status "npm" "ok" "$desired_line"
        SKIPPED_TOOLS+=("npm")
        return 0
    fi

    backup_if_exists "$npmrc"

    if grep -q '^min-release-age' "$npmrc" 2>/dev/null; then
        local current
        current=$(grep '^min-release-age' "$npmrc" | head -1 | sed 's/.*=//')
        print_status "npm" "updated" "$current --> ${MIN_AGE_DAYS}"
    else
        print_status "npm" "added" "$desired_line"
    fi

    replace_or_append_line "$npmrc" '^min-release-age=' "$desired_line"
    verify_and_finalize "$npmrc" "npm" 'min-release-age' || true
}

setup_pnpm() {
    local min_age_minutes=$(( MIN_AGE_DAYS * 1440 ))
    local desired_line="minimum-release-age=${min_age_minutes}"
    local desired_exceptions current_exceptions item

    ensure_file_exists "$PNPM_RC_PATH"
    desired_exceptions=""
    if [[ ${#PNPM_EXCEPTIONS[@]} -gt 0 ]]; then
        for item in "${PNPM_EXCEPTIONS[@]}"; do
            desired_exceptions+=$'minimum-release-age-exclude[]='
            desired_exceptions+="$item"
            desired_exceptions+=$'\n'
        done
        desired_exceptions=${desired_exceptions%$'\n'}
    fi
    current_exceptions=$(current_lines_or_empty "$PNPM_RC_PATH" '^minimum-release-age-exclude\[\]=')

    if grep -q "^${desired_line}$" "$PNPM_RC_PATH" 2>/dev/null \
        && [[ "$current_exceptions" == "$desired_exceptions" ]]; then
        print_status "pnpm" "ok" "$desired_line"
        SKIPPED_TOOLS+=("pnpm")
        return 0
    fi

    backup_if_exists "$PNPM_RC_PATH"

    if grep -q '^minimum-release-age=' "$PNPM_RC_PATH" 2>/dev/null; then
        local current
        current=$(grep '^minimum-release-age=' "$PNPM_RC_PATH" | head -1 | sed 's/.*=//')
        print_status "pnpm" "updated" "$current --> ${min_age_minutes}"
    else
        print_status "pnpm" "added" "$desired_line"
    fi
    replace_or_append_line "$PNPM_RC_PATH" '^minimum-release-age=' "$desired_line"

    remove_matching_lines "$PNPM_RC_PATH" '^minimum-release-age-exclude\\[\\]='
    if [[ ${#PNPM_EXCEPTIONS[@]} -gt 0 ]]; then
        for item in "${PNPM_EXCEPTIONS[@]}"; do
            printf 'minimum-release-age-exclude[]=%s\n' "$item" >> "$PNPM_RC_PATH"
        done
        print_status "pnpm exceptions" "added" "${#PNPM_EXCEPTIONS[@]} selector(s)"
    fi

    verify_and_finalize "$PNPM_RC_PATH" "pnpm" 'minimum-release-age' || true
}

setup_bun() {
    local bunfig="$HOME/.bunfig.toml"
    local min_age_seconds=$(( MIN_AGE_DAYS * 86400 ))
    local desired_age_line="minimumReleaseAge = ${min_age_seconds}"
    local desired_exceptions_line=""

    touch "$bunfig"
    if [[ ${#BUN_EXCEPTIONS[@]} -gt 0 ]]; then
        desired_exceptions_line="minimumReleaseAgeExcludes = $(toml_array "${BUN_EXCEPTIONS[@]}")"
    fi

    local current_exceptions
    current_exceptions=$(current_lines_or_empty "$bunfig" '^minimumReleaseAgeExcludes[[:space:]]*=')

    if grep -q "^${desired_age_line}$" "$bunfig" 2>/dev/null \
        && [[ "$current_exceptions" == "$desired_exceptions_line" ]]; then
        print_status "bun" "ok" "$desired_age_line"
        SKIPPED_TOOLS+=("bun")
        return 0
    fi

    backup_if_exists "$bunfig"

    if grep -q '^minimumReleaseAge[[:space:]]*=' "$bunfig" 2>/dev/null; then
        local current
        current=$(grep '^minimumReleaseAge[[:space:]]*=' "$bunfig" | head -1 | sed 's/.*= *//')
        print_status "bun" "updated" "$current --> ${min_age_seconds}"
    else
        print_status "bun" "added" "$desired_age_line"
    fi

    upsert_line_in_section "$bunfig" "[install]" '^minimumReleaseAge[[:space:]]*=' "$desired_age_line"

    if [[ ${#BUN_EXCEPTIONS[@]} -gt 0 ]]; then
        upsert_line_in_section "$bunfig" "[install]" '^minimumReleaseAgeExcludes[[:space:]]*=' "$desired_exceptions_line"
        print_status "bun exceptions" "added" "${#BUN_EXCEPTIONS[@]} package(s)"
    else
        remove_matching_lines "$bunfig" '^minimumReleaseAgeExcludes[[:space:]]*='
    fi

    verify_and_finalize "$bunfig" "bun" 'minimumReleaseAge\|minimumReleaseAgeExcludes\|\[install\]' || true
}

setup_yarn_classic() {
    local yarnrc="$HOME/.yarnrc"
    local min_age_seconds=$(( MIN_AGE_DAYS * 86400 ))
    local desired_line="cache-min ${min_age_seconds}"

    touch "$yarnrc"

    if grep -q "^${desired_line}$" "$yarnrc" 2>/dev/null; then
        print_status "yarn v1" "ok" "$desired_line"
        SKIPPED_TOOLS+=("yarn-classic")
        return 0
    fi

    backup_if_exists "$yarnrc"

    if grep -q '^cache-min' "$yarnrc" 2>/dev/null; then
        local current
        current=$(grep '^cache-min' "$yarnrc" | head -1 | awk '{print $2}')
        print_status "yarn v1" "updated" "$current --> ${min_age_seconds}"
    else
        print_status "yarn v1" "added" "$desired_line"
    fi

    replace_or_append_line "$yarnrc" '^cache-min ' "$desired_line"
    verify_and_finalize "$yarnrc" "yarn-classic" 'cache-min' || true
}

setup_yarn_berry() {
    local yarnrc_yml="$HOME/.yarnrc.yml"
    local desired_gate_line="npmMinimalAgeGate: $(yaml_quote "${MIN_AGE_DAYS}d")"
    local desired_exceptions_line=""
    local current_exceptions

    touch "$yarnrc_yml"
    if [[ ${#YARN_EXCEPTIONS[@]} -gt 0 ]]; then
        desired_exceptions_line="npmPreapprovedPackages: $(yaml_flow_array "${YARN_EXCEPTIONS[@]}")"
    fi
    current_exceptions=$(current_lines_or_empty "$yarnrc_yml" '^npmPreapprovedPackages:')

    if grep -q "^${desired_gate_line}$" "$yarnrc_yml" 2>/dev/null \
        && [[ "$current_exceptions" == "$desired_exceptions_line" ]]; then
        print_status "yarn v2+" "ok" "native age gate configured"
        SKIPPED_TOOLS+=("yarn-berry")
        return 0
    fi

    backup_if_exists "$yarnrc_yml"

    if grep -q '^npmMinimalAgeGate:' "$yarnrc_yml" 2>/dev/null; then
        local current
        current=$(grep '^npmMinimalAgeGate:' "$yarnrc_yml" | head -1 | sed 's/^[^:]*: *//')
        print_status "yarn v2+" "updated" "$current --> ${MIN_AGE_DAYS}d"
    else
        print_status "yarn v2+" "added" "native age gate"
    fi

    replace_or_append_line "$yarnrc_yml" '^npmMinimalAgeGate:' "$desired_gate_line"
    if [[ ${#YARN_EXCEPTIONS[@]} -gt 0 ]]; then
        replace_or_append_line "$yarnrc_yml" '^npmPreapprovedPackages:' "$desired_exceptions_line"
        print_status "yarn exceptions" "added" "${#YARN_EXCEPTIONS[@]} pattern(s)"
    else
        remove_matching_lines "$yarnrc_yml" '^npmPreapprovedPackages:'
    fi

    verify_and_finalize "$yarnrc_yml" "yarn-berry" 'npmMinimalAgeGate\|npmPreapprovedPackages' || true
}

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
    remove_matching_lines "$pip_conf" '^[[:space:]]*min-age[[:space:]]*='

    if grep -q '^\[global\]' "$pip_conf" 2>/dev/null && ! section_has_content "$pip_conf" "[global]"; then
        remove_matching_lines "$pip_conf" '^\\[global\\]$'
    fi

    strip_file_if_whitespace_only "$pip_conf"
    verify_and_finalize "$pip_conf" "pip" 'min-age\|\[global\]' || true
    cleanup_empty_file "$pip_conf"
}

remove_uv() {
    local uv_conf="$HOME/.config/uv/uv.toml"

    if ! grep -q '^exclude-newer[[:space:]]*=' "$uv_conf" 2>/dev/null \
        && ! grep -q '^exclude-newer-package[[:space:]]*=' "$uv_conf" 2>/dev/null; then
        print_status "uv" "ok" "exclude-newer settings not present"
        SKIPPED_TOOLS+=("uv")
        return 0
    fi

    print_status "uv" "removed" "exclude-newer settings"

    backup_if_exists "$uv_conf"
    remove_matching_lines "$uv_conf" '^exclude-newer(-package)?[[:space:]]*='

    strip_file_if_whitespace_only "$uv_conf"
    verify_and_finalize "$uv_conf" "uv" 'exclude-newer' || true
    cleanup_empty_file "$uv_conf"
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

    if ! grep -q '^min-release-age=' "$npmrc" 2>/dev/null; then
        print_status "npm" "ok" "min-release-age not present"
        SKIPPED_TOOLS+=("npm")
        return 0
    fi

    local current
    current=$(grep '^min-release-age=' "$npmrc" | head -1 | sed 's/.*=//')
    print_status "npm" "removed" "min-release-age=$current"

    backup_if_exists "$npmrc"
    remove_matching_lines "$npmrc" '^min-release-age='

    strip_file_if_whitespace_only "$npmrc"
    verify_and_finalize "$npmrc" "npm" 'min-release-age' || true
    cleanup_empty_file "$npmrc"
}

remove_pnpm() {
    if ! grep -q '^minimum-release-age=' "$PNPM_RC_PATH" 2>/dev/null \
        && ! grep -q '^minimum-release-age-exclude\[\]=' "$PNPM_RC_PATH" 2>/dev/null; then
        print_status "pnpm" "ok" "minimum-release-age settings not present"
        SKIPPED_TOOLS+=("pnpm")
        return 0
    fi

    print_status "pnpm" "removed" "minimum-release-age settings"

    backup_if_exists "$PNPM_RC_PATH"
    remove_matching_lines "$PNPM_RC_PATH" '^minimum-release-age='
    remove_matching_lines "$PNPM_RC_PATH" '^minimum-release-age-exclude\\[\\]='

    strip_file_if_whitespace_only "$PNPM_RC_PATH"
    verify_and_finalize "$PNPM_RC_PATH" "pnpm" 'minimum-release-age' || true
    cleanup_empty_file "$PNPM_RC_PATH"
}

remove_bun() {
    local bunfig="$HOME/.bunfig.toml"

    if ! grep -q '^minimumReleaseAge[[:space:]]*=' "$bunfig" 2>/dev/null \
        && ! grep -q '^minimumReleaseAgeExcludes[[:space:]]*=' "$bunfig" 2>/dev/null; then
        print_status "bun" "ok" "minimumReleaseAge settings not present"
        SKIPPED_TOOLS+=("bun")
        return 0
    fi

    print_status "bun" "removed" "minimumReleaseAge settings"

    backup_if_exists "$bunfig"
    remove_matching_lines "$bunfig" '^minimumReleaseAge[[:space:]]*='
    remove_matching_lines "$bunfig" '^minimumReleaseAgeExcludes[[:space:]]*='

    if grep -q '^\[install\]' "$bunfig" 2>/dev/null && ! section_has_content "$bunfig" "[install]"; then
        remove_matching_lines "$bunfig" '^\\[install\\]$'
    fi

    strip_file_if_whitespace_only "$bunfig"
    verify_and_finalize "$bunfig" "bun" 'minimumReleaseAge\|minimumReleaseAgeExcludes\|\[install\]' || true
    cleanup_empty_file "$bunfig"
}

remove_yarn_classic() {
    local yarnrc="$HOME/.yarnrc"

    if ! grep -q '^cache-min ' "$yarnrc" 2>/dev/null; then
        print_status "yarn v1" "ok" "cache-min not present"
        SKIPPED_TOOLS+=("yarn-classic")
        return 0
    fi

    local current
    current=$(grep '^cache-min ' "$yarnrc" | head -1 | awk '{print $2}')
    print_status "yarn v1" "removed" "cache-min $current"

    backup_if_exists "$yarnrc"
    remove_matching_lines "$yarnrc" '^cache-min '

    strip_file_if_whitespace_only "$yarnrc"
    verify_and_finalize "$yarnrc" "yarn-classic" 'cache-min' || true
    cleanup_empty_file "$yarnrc"
}

remove_yarn_berry() {
    local yarnrc_yml="$HOME/.yarnrc.yml"

    if ! grep -q '^npmMinimalAgeGate:' "$yarnrc_yml" 2>/dev/null \
        && ! grep -q '^npmPreapprovedPackages:' "$yarnrc_yml" 2>/dev/null; then
        print_status "yarn v2+" "ok" "native age gate not present"
        SKIPPED_TOOLS+=("yarn-berry")
        return 0
    fi

    print_status "yarn v2+" "removed" "native age gate"

    backup_if_exists "$yarnrc_yml"
    remove_matching_lines "$yarnrc_yml" '^npmMinimalAgeGate:'
    remove_matching_lines "$yarnrc_yml" '^npmPreapprovedPackages:'

    strip_file_if_whitespace_only "$yarnrc_yml"
    verify_and_finalize "$yarnrc_yml" "yarn-berry" 'npmMinimalAgeGate\|npmPreapprovedPackages' || true
    cleanup_empty_file "$yarnrc_yml"
}

validate_configs() {
    local pip_conf="$HOME/.config/pip/pip.conf"
    local uv_conf="$HOME/.config/uv/uv.toml"
    local npmrc="$HOME/.npmrc"
    local bunfig="$HOME/.bunfig.toml"
    local yarnrc="$HOME/.yarnrc"
    local yarnrc_yml="$HOME/.yarnrc.yml"
    local expected_uv_date="exclude-newer = \"$(date_days_ago_rfc3339 "$MIN_AGE_DAYS")\""
    local expected_pnpm_age="minimum-release-age=$(( MIN_AGE_DAYS * 1440 ))"
    local expected_bun_age="minimumReleaseAge = $(( MIN_AGE_DAYS * 86400 ))"
    local expected_yarn_v1_age="cache-min $(( MIN_AGE_DAYS * 86400 ))"
    local expected_yarn_v2_age="npmMinimalAgeGate: $(yaml_quote "${MIN_AGE_DAYS}d")"
    local expected_uv_exceptions=""
    local expected_bun_exceptions=""
    local expected_yarn_exceptions=""
    local expected_pnpm_exceptions=""
    local current_exceptions item

    if [[ ${#UV_EXCEPTIONS[@]} -gt 0 ]]; then
        expected_uv_exceptions=$(build_uv_exception_line)
    fi
    if [[ ${#BUN_EXCEPTIONS[@]} -gt 0 ]]; then
        expected_bun_exceptions="minimumReleaseAgeExcludes = $(toml_array "${BUN_EXCEPTIONS[@]}")"
    fi
    if [[ ${#YARN_EXCEPTIONS[@]} -gt 0 ]]; then
        expected_yarn_exceptions="npmPreapprovedPackages: $(yaml_flow_array "${YARN_EXCEPTIONS[@]}")"
    fi
    if [[ ${#PNPM_EXCEPTIONS[@]} -gt 0 ]]; then
        for item in "${PNPM_EXCEPTIONS[@]}"; do
            expected_pnpm_exceptions+=$'minimum-release-age-exclude[]='
            expected_pnpm_exceptions+="$item"
            expected_pnpm_exceptions+=$'\n'
        done
        expected_pnpm_exceptions=${expected_pnpm_exceptions%$'\n'}
    fi

    if [[ -f "$pip_conf" ]]; then
        if grep -Fqx "min-age = ${MIN_AGE_DAYS}d" "$pip_conf" 2>/dev/null; then
            record_validation_ok "pip" "min-age = ${MIN_AGE_DAYS}d" "pip"
        else
            record_validation_fail "pip" "expected min-age = ${MIN_AGE_DAYS}d" "pip"
        fi
    else
        print_status "pip" "--" "config not present"
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
        print_status "uv" "--" "config not present"
    fi

    if [[ -f "$npmrc" ]]; then
        if grep -Fqx "min-release-age=${MIN_AGE_DAYS}" "$npmrc" 2>/dev/null; then
            record_validation_ok "npm" "min-release-age=${MIN_AGE_DAYS}" "npm"
        else
            record_validation_fail "npm" "expected min-release-age=${MIN_AGE_DAYS}" "npm"
        fi
    else
        print_status "npm" "--" "config not present"
    fi

    if [[ -f "$PNPM_RC_PATH" ]]; then
        current_exceptions=$(current_lines_or_empty "$PNPM_RC_PATH" '^minimum-release-age-exclude\[\]=')
        if grep -Fqx "$expected_pnpm_age" "$PNPM_RC_PATH" 2>/dev/null \
            && [[ "$current_exceptions" == "$expected_pnpm_exceptions" ]]; then
            record_validation_ok "pnpm" "$expected_pnpm_age" "pnpm"
        else
            record_validation_fail "pnpm" "minimum-release-age settings do not match" "pnpm"
        fi
    else
        print_status "pnpm" "--" "config not present"
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
        print_status "bun" "--" "config not present"
    fi

    if [[ -f "$yarnrc" ]]; then
        if grep -Fqx "$expected_yarn_v1_age" "$yarnrc" 2>/dev/null; then
            record_validation_ok "yarn v1" "$expected_yarn_v1_age" "yarn-classic"
        else
            record_validation_fail "yarn v1" "expected $expected_yarn_v1_age" "yarn-classic"
        fi
    else
        print_status "yarn v1" "--" "config not present"
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
        print_status "yarn v2+" "--" "config not present"
    fi
}

main() {
    parse_args "$@"

    FAILED_TOOLS=()
    SKIPPED_TOOLS=()
    UPDATED_TOOLS=()
    VALIDATED_TOOLS=()
    VALIDATION_FAILED_TOOLS=()
    PREFLIGHT_FAILED_TOOLS=()

    if [[ "$REMOVE_MODE" == true ]]; then
        echo ""
        echo "  set-minimum-package-release-age (${PLATFORM_NAME}) -- REMOVE MODE"
        echo ""
        print_tool_overview
        echo "  Removing settings"
        echo "  ----------------------------------------------------------"
        printf "  %-16s %-10s %s\n" "TOOL" "STATUS" "DETAIL"
        echo "  ----------------------------------------------------------"

        run_remove_tools pip uv uv-cron npm pnpm bun yarn-classic yarn-berry

        echo ""
        echo "  Summary"
        echo "  ----------------------------------------------------------"
        echo "  ${#SKIPPED_TOOLS[@]} not present, ${#UPDATED_TOOLS[@]} removed, ${#FAILED_TOOLS[@]} failed"

        if [[ ${#FAILED_TOOLS[@]} -gt 0 ]]; then
            echo ""
            echo "  Rolled back: ${FAILED_TOOLS[*]}"
        fi

        echo ""
        print_config_files
        return
    fi

    if [[ "$REMOVE_SCOPED_MODE" == true ]]; then
        echo ""
        echo "  set-minimum-package-release-age (${PLATFORM_NAME}) -- REMOVE MODE (SCOPED)"
        echo ""
        print_tool_overview
        echo "  Removing selected settings"
        echo "  ----------------------------------------------------------"
        printf "  %-16s %-10s %s\n" "TOOL" "STATUS" "DETAIL"
        echo "  ----------------------------------------------------------"

        run_remove_tools "${REMOVE_TOOLS[@]}"

        echo ""
        echo "  Summary"
        echo "  ----------------------------------------------------------"
        echo "  ${#SKIPPED_TOOLS[@]} not present, ${#UPDATED_TOOLS[@]} removed, ${#FAILED_TOOLS[@]} failed"

        if [[ ${#FAILED_TOOLS[@]} -gt 0 ]]; then
            echo ""
            echo "  Rolled back: ${FAILED_TOOLS[*]}"
        fi

        echo ""
        print_config_files
        return
    fi

    echo ""
    echo "  set-minimum-package-release-age (${PLATFORM_NAME})"
    echo "  minimum age: ${MIN_AGE_DAYS} days"
    echo ""
    echo "  Tool readiness"
    echo "  ----------------------------------------------------------"
    printf "  %-16s %-10s %-12s %-10s %s\n" "TOOL" "INSTALLED" "VERSION" "STATUS" "DETAIL"
    echo "  ----------------------------------------------------------"

    if ! run_preflight_checks; then
        echo ""
        echo "  Preflight errors: ${PREFLIGHT_FAILED_TOOLS[*]}"
        echo ""
        return 1
    fi

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
    print_config_files
}
