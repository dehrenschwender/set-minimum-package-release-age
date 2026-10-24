#!/usr/bin/env bash
# shellcheck shell=bash
#
# Terminal output for set-minimum-package-release-age.
#
# Every line fits the terminal: rows use fixed name/status columns, long text
# wraps with a hanging indent, paths are shortened in the middle, and narrow
# terminals switch to a stacked layout. Color is only used on a terminal (and
# never with NO_COLOR); without a UTF-8 locale the symbols fall back to ASCII.
# Only ASCII text is ever padded with printf, because printf pads by bytes.
#
# Overrides: COLUMNS (width), NO_COLOR / FORCE_COLOR, and
# SET_PACKAGE_MIN_AGE_GLYPHS=ascii|unicode.

UI_READY=false
UI_WIDTH=100
UI_COLOR=false
UI_UNICODE=false
UI_MIN_WIDTH=32
UI_MAX_WIDTH=120
UI_DEFAULT_WIDTH=100
UI_NAME_WIDTH=12
UI_STATUS_WIDTH=9
UI_VERSION_WIDTH=10
# Rows switch to the stacked layout when less than this is left for the text.
UI_MIN_TEXT_WIDTH=20
UI_STACK_INDENT=6

UI_NOT_INSTALLED=()

# Plain defaults so helpers are safe before ui_init runs; ui_init replaces them.
UI_G_CHANGED="*"
UI_G_SAME="="
UI_G_SKIP="-"
UI_G_WARN="!"
UI_G_FAIL="x"
UI_ARROW="->"
UI_SEP="|"
UI_ELLIPSIS="..."
UI_C_RESET=""
UI_C_BOLD=""
UI_C_DIM=""
UI_C_GREEN=""
UI_C_YELLOW=""
UI_C_RED=""

ui_init() {
    if [[ "$UI_READY" == true ]]; then
        return 0
    fi

    local width="" size="" locale_name stdout_tty=false
    if [[ -t 1 ]]; then
        stdout_tty=true
    fi

    if [[ "${COLUMNS:-}" =~ ^[0-9]+$ && "${COLUMNS}" -gt 0 ]]; then
        width="$COLUMNS"
    elif [[ "$stdout_tty" == true ]]; then
        size=$(stty size </dev/tty 2>/dev/null || true)
        if [[ "$size" =~ ^[0-9]+[[:space:]]+([0-9]+)$ ]]; then
            width="${BASH_REMATCH[1]}"
        fi
        if ! [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 ]]; then
            width=$(tput cols 2>/dev/null || true)
        fi
    fi
    if ! [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 ]]; then
        width="$UI_DEFAULT_WIDTH"
    fi
    if [[ "$width" -lt "$UI_MIN_WIDTH" ]]; then
        width="$UI_MIN_WIDTH"
    fi
    if [[ "$width" -gt "$UI_MAX_WIDTH" ]]; then
        width="$UI_MAX_WIDTH"
    fi
    UI_WIDTH="$width"

    UI_COLOR=false
    if [[ -n "${NO_COLOR:-}" ]]; then
        UI_COLOR=false
    elif [[ -n "${FORCE_COLOR:-}" && "${FORCE_COLOR}" != "0" ]]; then
        UI_COLOR=true
    elif [[ "$stdout_tty" == true && "${TERM:-dumb}" != "dumb" ]]; then
        UI_COLOR=true
    fi

    locale_name="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    case "${SET_PACKAGE_MIN_AGE_GLYPHS:-}" in
        ascii) UI_UNICODE=false ;;
        unicode) UI_UNICODE=true ;;
        *)
            case "$locale_name" in
                *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) UI_UNICODE=true ;;
                *) UI_UNICODE=false ;;
            esac
            ;;
    esac

    if [[ "$UI_UNICODE" == true ]]; then
        UI_G_CHANGED="✓"
        UI_G_SAME="·"
        UI_G_SKIP="–"
        UI_G_WARN="!"
        UI_G_FAIL="✗"
        UI_ARROW="→"
        UI_SEP="·"
        UI_ELLIPSIS="…"
    else
        UI_G_CHANGED="*"
        UI_G_SAME="="
        UI_G_SKIP="-"
        UI_G_WARN="!"
        UI_G_FAIL="x"
        UI_ARROW="->"
        UI_SEP="|"
        UI_ELLIPSIS="..."
    fi

    if [[ "$UI_COLOR" == true ]]; then
        UI_C_RESET=$'\033[0m'
        UI_C_BOLD=$'\033[1m'
        UI_C_DIM=$'\033[2m'
        UI_C_GREEN=$'\033[32m'
        UI_C_YELLOW=$'\033[33m'
        UI_C_RED=$'\033[31m'
    else
        UI_C_RESET=""
        UI_C_BOLD=""
        UI_C_DIM=""
        UI_C_GREEN=""
        UI_C_YELLOW=""
        UI_C_RED=""
    fi

    UI_READY=true
}

# Re-reads width, color, and glyph settings (for example after COLUMNS changed).
ui_reset() {
    UI_READY=false
    ui_init
}

ui_paint() {
    local color="$1"
    local text="$2"

    if [[ -z "$color" || -z "$text" ]]; then
        printf '%s' "$text"
        return 0
    fi
    printf '%s%s%s' "$color" "$text" "$UI_C_RESET"
}

ui_spaces() {
    printf '%*s' "$1" ''
}

# Pads ASCII text to a column width (text that is already wider is kept whole).
ui_pad() {
    printf '%-*s' "$2" "$1"
}

ui_kind_color() {
    case "$1" in
        changed) printf '%s' "$UI_C_GREEN" ;;
        warn) printf '%s' "$UI_C_YELLOW" ;;
        fail) printf '%s' "$UI_C_RED" ;;
        same | skip) printf '%s' "$UI_C_DIM" ;;
        *) printf '' ;;
    esac
}

ui_kind_glyph() {
    case "$1" in
        changed) printf '%s' "$UI_G_CHANGED" ;;
        same) printf '%s' "$UI_G_SAME" ;;
        skip) printf '%s' "$UI_G_SKIP" ;;
        warn) printf '%s' "$UI_G_WARN" ;;
        fail) printf '%s' "$UI_G_FAIL" ;;
        *) printf ' ' ;;
    esac
}

# Word-wraps TEXT to WIDTH characters, one line per output line. Words longer
# than WIDTH are split.
ui_wrap() {
    local width="$1"
    local text="$2"
    local line="" word
    local -a words=()

    if [[ "$width" -lt 8 ]]; then
        width=8
    fi

    read -r -a words <<< "$text" || true
    for word in "${words[@]-}"; do
        [[ -n "$word" ]] || continue
        while [[ ${#word} -gt $width ]]; do
            if [[ -n "$line" ]]; then
                printf '%s\n' "$line"
                line=""
            fi
            printf '%s\n' "${word:0:$width}"
            word="${word:$width}"
        done
        if [[ -z "$line" ]]; then
            line="$word"
        elif [[ $(( ${#line} + 1 + ${#word} )) -le $width ]]; then
            line+=" $word"
        else
            printf '%s\n' "$line"
            line="$word"
        fi
    done
    if [[ -n "$line" ]]; then
        printf '%s\n' "$line"
    fi
}

# Shortens a path to MAX characters: $HOME becomes ~, and the middle is
# replaced with an ellipsis so the start and the file name stay visible.
ui_shorten_path() {
    local path="$1"
    local max="$2"
    local head_len tail_len

    if [[ -n "${HOME:-}" && "$path" == "$HOME"/* ]]; then
        path="~${path#"$HOME"}"
    fi
    if [[ ${#path} -le $max ]]; then
        printf '%s' "$path"
        return 0
    fi
    if [[ $max -le $(( ${#UI_ELLIPSIS} + 4 )) ]]; then
        printf '%s%s' "$UI_ELLIPSIS" "${path: -$(( max - ${#UI_ELLIPSIS} ))}"
        return 0
    fi
    head_len=$(( (max - ${#UI_ELLIPSIS}) / 3 ))
    tail_len=$(( max - ${#UI_ELLIPSIS} - head_len ))
    printf '%s%s%s' "${path:0:$head_len}" "$UI_ELLIPSIS" "${path: -$tail_len}"
}

# Prints PREFIX followed by TEXT wrapped to the remaining width; continuation
# lines are indented by PREFIX_LEN. PREFIX may contain color codes, so its
# visible length is passed separately. Falls back to a stacked layout (text on
# the following lines) when too little room is left.
ui_print_prefixed() {
    local prefix="$1"
    local prefix_len="$2"
    local text="$3"
    local color="${4:-}"
    local avail indent first=true line

    avail=$(( UI_WIDTH - prefix_len ))
    indent=$(ui_spaces "$prefix_len")
    if [[ $avail -lt $UI_MIN_TEXT_WIDTH && -n "$text" ]]; then
        printf '%s\n' "$(ui_rstrip "$prefix")"
        first=false
        indent=$(ui_spaces "$UI_STACK_INDENT")
        avail=$(( UI_WIDTH - UI_STACK_INDENT ))
    fi

    if [[ -z "$text" ]]; then
        if [[ "$first" == true ]]; then
            printf '%s\n' "$(ui_rstrip "$prefix")"
        fi
        return 0
    fi

    while IFS= read -r line; do
        if [[ "$first" == true ]]; then
            printf '%s%s\n' "$prefix" "$(ui_paint "$color" "$line")"
            first=false
        else
            printf '%s%s\n' "$indent" "$(ui_paint "$color" "$line")"
        fi
    done < <(ui_wrap "$avail" "$text")
}

ui_rstrip() {
    local text="$1"
    printf '%s' "${text%"${text##*[![:space:]]}"}"
}

# Indented, wrapped note lines (used under a row).
ui_note() {
    local indent_len="$1"
    local text="$2"
    local color="${3:-$UI_C_DIM}"

    ui_init
    if [[ $(( UI_WIDTH - indent_len )) -lt $UI_MIN_TEXT_WIDTH ]]; then
        indent_len="$UI_STACK_INDENT"
    fi
    ui_print_prefixed "$(ui_spaces "$indent_len")" "$indent_len" "$text" "$color"
}

ui_heading() {
    ui_init
    printf '\n%s\n' "$(ui_paint "$UI_C_BOLD" "$1")"
}

# Title line: "set-minimum-package-release-age · macOS · minimum age 7 days".
ui_header() {
    ui_init
    local title="$1"
    shift
    local part line plain

    line="$(ui_paint "$UI_C_BOLD" "$title")"
    plain="$title"
    for part in "$@"; do
        if [[ $(( ${#plain} + ${#UI_SEP} + ${#part} + 2 )) -le $UI_WIDTH ]]; then
            line+=" $UI_SEP $part"
            plain+=" $UI_SEP $part"
        else
            printf '%s\n' "$line"
            line="$part"
            plain="$part"
        fi
    done
    printf '%s\n' "$line"
}

# One line per tool: "  ✓ pip         added     uploaded-prior-to = P7D".
ui_status_row() {
    ui_init
    local kind="$1"
    local name="$2"
    local label="$3"
    local text="$4"
    local color prefix prefix_len

    color=$(ui_kind_color "$kind")
    prefix="  $(ui_paint "$color" "$(ui_kind_glyph "$kind")") $(ui_pad "$name" "$UI_NAME_WIDTH") "
    prefix+="$(ui_paint "$color" "$label")$(ui_spaces $(( UI_STATUS_WIDTH - ${#label} > 0 ? UI_STATUS_WIDTH - ${#label} : 0 ))) "
    prefix_len=$(( 2 + 1 + 1 + UI_NAME_WIDTH + 1 + (${#label} > UI_STATUS_WIDTH ? ${#label} : UI_STATUS_WIDTH) + 1 ))
    ui_print_prefixed "$prefix" "$prefix_len" "${text// --> / $UI_ARROW }"
}

ui_status_kind() {
    case "$1" in
        added | updated | removed) printf 'changed' ;;
        ok) printf 'same' ;;
        skipped | "--") printf 'skip' ;;
        warn) printf 'warn' ;;
        blocked | FAIL) printf 'fail' ;;
        *) printf 'same' ;;
    esac
}

ui_status_label() {
    case "$1" in
        ok) printf 'unchanged' ;;
        FAIL) printf 'failed' ;;
        "--") printf 'skipped' ;;
        *) printf '%s' "$1" ;;
    esac
}

# A config change row for STATUS as used by emit_config_status.
ui_change_row() {
    local name="$1"
    local status="$2"
    local detail="$3"

    ui_status_row "$(ui_status_kind "$status")" "$name" "$(ui_status_label "$status")" "$detail"
}

# Tools section row: "  ✓ pip         26.2.2     /opt/homebrew/bin/pip3", plus an
# optional wrapped note underneath.
ui_tool_row() {
    ui_init
    local kind="$1"
    local name="$2"
    local version="$3"
    local path="$4"
    local note="${5:-}"
    local color prefix prefix_len avail note_indent

    color=$(ui_kind_color "$kind")
    prefix="  $(ui_paint "$color" "$(ui_kind_glyph "$kind")") $(ui_pad "$name" "$UI_NAME_WIDTH") $(ui_pad "$version" "$UI_VERSION_WIDTH") "
    prefix_len=$(( 2 + 1 + 1 + UI_NAME_WIDTH + 1 + (${#version} > UI_VERSION_WIDTH ? ${#version} : UI_VERSION_WIDTH) + 1 ))
    avail=$(( UI_WIDTH - prefix_len ))
    note_indent="$prefix_len"

    if [[ -z "$path" || "$path" == "not found" ]]; then
        printf '%s\n' "$(ui_rstrip "$prefix")"
    elif [[ $avail -ge 16 ]]; then
        printf '%s%s\n' "$prefix" "$(ui_paint "$UI_C_DIM" "$(ui_shorten_path "$path" "$avail")")"
    else
        printf '%s\n' "$(ui_rstrip "$prefix")"
        printf '%s%s\n' "$(ui_spaces "$UI_STACK_INDENT")" \
            "$(ui_paint "$UI_C_DIM" "$(ui_shorten_path "$path" $(( UI_WIDTH - UI_STACK_INDENT )))")"
    fi

    if [[ -n "$note" ]]; then
        ui_note "$note_indent" "$note" "$color"
    fi
}

# Two-column list row: "  pip         ~/.config/pip/pip.conf" (paths shortened).
ui_path_row() {
    ui_init
    local name="$1"
    local path="$2"
    local prefix_len=$(( 2 + UI_NAME_WIDTH + 1 ))

    if [[ $(( UI_WIDTH - prefix_len )) -ge 16 ]]; then
        printf '  %s %s\n' "$(ui_pad "$name" "$UI_NAME_WIDTH")" "$(ui_paint "$UI_C_DIM" "$(ui_shorten_path "$path" $(( UI_WIDTH - prefix_len )))")"
    else
        printf '  %s\n' "$name"
        printf '%s%s\n' "$(ui_spaces "$UI_STACK_INDENT")" "$(ui_paint "$UI_C_DIM" "$(ui_shorten_path "$path" $(( UI_WIDTH - UI_STACK_INDENT )))")"
    fi
}

# Wrapped text indented by two spaces.
ui_text() {
    ui_init
    ui_print_prefixed "  " 2 "$1" "${2:-}"
}

# Joins arguments with the separator glyph: "3 added · 1 updated".
ui_join() {
    local result="" item

    for item in "$@"; do
        [[ -n "$item" ]] || continue
        if [[ -n "$result" ]]; then
            result+=" $UI_SEP "
        fi
        result+="$item"
    done
    printf '%s' "$result"
}

# Joins arguments with ", ".
ui_comma_list() {
    local result="" item

    for item in "$@"; do
        result+="${result:+, }$item"
    done
    printf '%s' "$result"
}

# A symbol followed by wrapped text: "  – Not installed: Poetry, PDM".
ui_bullet() {
    ui_init
    local kind="$1"
    local text="$2"
    local color

    color=$(ui_kind_color "$kind")
    ui_print_prefixed "  $(ui_paint "$color" "$(ui_kind_glyph "$kind")") " 4 "$text"
}

# Column where row text starts (after symbol, name, and status columns).
ui_text_column() {
    printf '%s' $(( 2 + 1 + 1 + UI_NAME_WIDTH + 1 + UI_STATUS_WIDTH + 1 ))
}
