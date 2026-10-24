#!/usr/bin/env bash

# Terminal output layout: every line must fit the terminal width (within the
# supported 32-120 column range), wrapped text must keep all of its words, and
# the important information must survive at every width.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

LAYOUT_WIDTHS=(32 40 50 60 80 100 120 200)

# Prints a UTF-8 locale bash can use to count characters, if there is one.
find_utf8_locale() {
    local candidate
    for candidate in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
        if [[ "$(LC_ALL="$candidate" bash -c 'x="✓…"; printf %s ${#x}' 2>/dev/null)" == "2" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

strip_ansi() {
    sed $'s/\x1b\\[[0-9;]*m//g'
}

# Fails if any line is wider than WIDTH characters or ends in whitespace.
assert_fits_width() {
    local output="$1"
    local width="$2"
    local label="$3"
    local line

    while IFS= read -r line; do
        if [[ ${#line} -gt $width ]]; then
            fail "$label: line is ${#line} wide (limit $width): [$line]"
        fi
        if [[ "$line" =~ [[:space:]]$ ]]; then
            fail "$label: trailing whitespace: [$line]"
        fi
    done <<< "$output"
}

effective_width() {
    local width="$1"
    if [[ $width -lt 32 ]]; then
        width=32
    elif [[ $width -gt 120 ]]; then
        width=120
    fi
    printf '%s' "$width"
}

# Renders a run with a blocked tool, warnings, long paths, a long update
# detail, and many exceptions, at the given width.
# Usage: render_scenario WIDTH [VAR=value...]; the settings are applied after
# setup_test_env, which otherwise resets them.
render_scenario() {
    local width="$1"
    shift
    (
        setup_test_env
        [[ $# -eq 0 ]] || export "$@"
        install_fake_crontab
        install_fake_detection_tools "4.12.0" 1 "11.14.1" "11.25.0" "1.4.3" "0.13.5" "26.2.2" 1 "1.6.0" 1 "2.9.8" 0 "" 1 "1.17.2" "0.83.0" 0
        install_fake_version_binary cargo "cargo 1.96.0 (30a34c682 2026-05-25)"
        mkdir -p "$HOME/.config/uv"
        printf 'exclude-newer = "2026-10-17T00:00:00Z"\n' > "$HOME/.config/uv/uv.toml"
        load_common_library
        export COLUMNS="$width"
        main 7 \
            --exception 'npm:@myorg/*' \
            --exception pnpm:webpack --exception 'pnpm:@very-long-organisation-name/*' \
            --exception 'pnpm:another-really-long-package-name-for-wrapping' \
            --exception mise:trivy 2>&1 || true
        cleanup_test_env
    )
}

render_remove_scenario() {
    local width="$1"
    shift
    (
        setup_test_env
        [[ $# -eq 0 ]] || export "$@"
        install_fake_crontab
        install_fake_detection_tools "4.12.0"
        load_common_library
        parse_args 7
        setup_pip >/dev/null
        setup_uv >/dev/null
        export COLUMNS="$width"
        main --remove-tool pip --remove-tool uv --remove-tool hex 2>&1 || true
        cleanup_test_env
    )
}

assert_scenario_content() {
    local output="$1"
    local label="$2"
    local flat

    flat=$(flatten_output "$output")
    for expected in \
        "Tools" "Changes" "Summary" "Changed files" "Needs attention" \
        "min-release-age-exclude requires >= 11.17.0 (installed: 11.14.1)" \
        "cooldown requires >= 4.0.13" \
        "Exit status 1 because 1 tool is blocked."; do
        [[ "$flat" == *"$expected"* ]] || fail "$label: missing [$expected] in: $flat"
    done
    for tool in pip uv Poetry npm pnpm bun deno pixi "yarn v2+" vlt Bundler Hex Cargo mise; do
        [[ "$flat" == *" $tool "* ]] || fail "$label: missing tool [$tool]"
    done
    # Every wrapped word of a long exception list is still present.
    [[ "$flat" == *"exceptions=3"* ]] || fail "$label: missing pnpm exception count"
}

test_layout_fits_every_width_ascii() {
    local width output
    for width in "${LAYOUT_WIDTHS[@]}"; do
        output=$(render_scenario "$width" SET_PACKAGE_MIN_AGE_GLYPHS=ascii)
        assert_fits_width "$output" "$(effective_width "$width")" "ascii width $width"
        assert_scenario_content "$output" "ascii width $width"
    done
}

test_layout_fits_every_width_unicode() {
    local locale_name width output
    if ! locale_name=$(find_utf8_locale); then
        printf 'skipped: no UTF-8 locale available\n'
        return 0
    fi
    for width in "${LAYOUT_WIDTHS[@]}"; do
        output=$(render_scenario "$width" LC_ALL="$locale_name" SET_PACKAGE_MIN_AGE_GLYPHS=unicode)
        (
            export LC_ALL="$locale_name"
            assert_fits_width "$output" "$(effective_width "$width")" "unicode width $width"
        )
        [[ "$output" == *"✗ npm"* ]] || fail "unicode width $width: expected unicode symbols"
        assert_scenario_content "$output" "unicode width $width"
    done
}

test_remove_layout_fits_every_width() {
    local width output
    for width in "${LAYOUT_WIDTHS[@]}"; do
        output=$(render_remove_scenario "$width" SET_PACKAGE_MIN_AGE_GLYPHS=ascii)
        assert_fits_width "$output" "$(effective_width "$width")" "remove width $width"
        assert_contains "$(flatten_output "$output")" "2 removed"
        assert_contains "$output" "Removing"
    done
}

test_columns_line_up_on_normal_widths() {
    local output line status_column=""
    output=$(render_scenario 100 SET_PACKAGE_MIN_AGE_GLYPHS=ascii)

    # In the Changes section the status word always starts in the same column.
    while IFS= read -r line; do
        if [[ "$line" =~ ^(\ \ [*=x!-]\ .{12}\ )(added|updated|unchanged|skipped|blocked|failed|removed)\  ]]; then
            if [[ -z "$status_column" ]]; then
                status_column=${#BASH_REMATCH[1]}
            fi
            [[ ${#BASH_REMATCH[1]} -eq $status_column ]] || fail "misaligned status column: [$line]"
        fi
    done <<< "$output"
    [[ -n "$status_column" ]] || fail "no Changes rows found"
}

test_color_only_when_requested() {
    local plain colored no_color
    plain=$(render_scenario 80)
    [[ "$plain" != *$'\033['* ]] || fail "expected no color when output is not a terminal"

    colored=$(render_scenario 80 FORCE_COLOR=1)
    [[ "$colored" == *$'\033['* ]] || fail "expected color with FORCE_COLOR=1"
    assert_fits_width "$(printf '%s\n' "$colored" | strip_ansi)" 80 "colored width 80"

    no_color=$(render_scenario 80 NO_COLOR=1 FORCE_COLOR=1)
    [[ "$no_color" != *$'\033['* ]] || fail "NO_COLOR must win over FORCE_COLOR"
}

test_width_detection_and_clamping() {
    setup_test_env
    load_common_library
    (COLUMNS=10; ui_reset; assert_eq 32 "$UI_WIDTH")
    (COLUMNS=500; ui_reset; assert_eq 120 "$UI_WIDTH")
    (COLUMNS=abc; ui_reset; assert_eq 100 "$UI_WIDTH")
    (unset COLUMNS; ui_reset; assert_eq 100 "$UI_WIDTH")
    (COLUMNS=73; ui_reset; assert_eq 73 "$UI_WIDTH")
    cleanup_test_env
}

test_wrap_and_shorten_helpers() {
    setup_test_env
    load_common_library
    ui_reset

    local text="alpha beta gamma delta-epsilon-zeta-eta-theta-iota-kappa lambda mu" line wrapped
    wrapped=$(ui_wrap 12 "$text")
    while IFS= read -r line; do
        [[ ${#line} -le 12 ]] || fail "wrapped line too long: [$line]"
    done <<< "$wrapped"
    # Long words are split, but no characters are lost.
    assert_eq "$(printf '%s' "$text" | tr -d ' ')" "$(printf '%s' "$wrapped" | tr -d ' \n')"
    assert_eq "" "$(ui_wrap 20 "")"

    local short
    short=$(ui_shorten_path "$HOME/.config/set-package-min-age/deno.sh" 200)
    assert_eq "~/.config/set-package-min-age/deno.sh" "$short"
    short=$(ui_shorten_path "/very/long/path/to/some/deeply/nested/directory/with/a/config.toml" 30)
    [[ ${#short} -le 30 ]] || fail "shortened path too long: $short"
    [[ "$short" == /very* && "$short" == *config.toml && "$short" == *"..."* ]] || fail "unexpected shortened path: $short"
    short=$(ui_shorten_path "/abcdefghijklmnopqrstuvwxyz/config.toml" 6)
    [[ ${#short} -le 6 ]] || fail "tiny shortened path too long: $short"
    cleanup_test_env
}

run_test "layout_fits_every_width_ascii" test_layout_fits_every_width_ascii || true
run_test "layout_fits_every_width_unicode" test_layout_fits_every_width_unicode || true
run_test "remove_layout_fits_every_width" test_remove_layout_fits_every_width || true
run_test "columns_line_up_on_normal_widths" test_columns_line_up_on_normal_widths || true
run_test "color_only_when_requested" test_color_only_when_requested || true
run_test "width_detection_and_clamping" test_width_detection_and_clamping || true
run_test "wrap_and_shorten_helpers" test_wrap_and_shorten_helpers || true
finish_tests
