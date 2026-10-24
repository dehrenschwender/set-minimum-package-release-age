#!/usr/bin/env bash

# Shell compatibility: the platform scripts must run (or refuse cleanly) from
# bash, zsh, and sh, and the generated Deno wrapper must work in bash and zsh.
# Shells that are not installed are skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

PLATFORM_SCRIPTS=(set_package_min_age_linux.sh set_package_min_age_macos.sh)

available_shells() {
    local shell_name
    for shell_name in "$@"; do
        if command -v "$shell_name" >/dev/null 2>&1; then
            printf '%s\n' "$shell_name"
        fi
    done
}

test_platform_scripts_run_from_any_shell() {
    setup_test_env
    local script shell_name output

    for script in "${PLATFORM_SCRIPTS[@]}"; do
        while IFS= read -r shell_name; do
            output=$("$shell_name" "$PROJECT_ROOT/$script" --help 2>&1) \
                || fail "$shell_name $script --help exited non-zero: $output"
            assert_contains "$output" "Usage: $script"
        done < <(available_shells bash zsh sh dash)
    done
    cleanup_test_env
}

test_platform_scripts_refuse_to_be_sourced() {
    setup_test_env
    local script shell_name output

    for script in "${PLATFORM_SCRIPTS[@]}"; do
        while IFS= read -r shell_name; do
            # The calling shell must survive and see a non-zero status. Plain POSIX
            # shells (dash, BusyBox sh) cannot detect sourcing, so they get the
            # generic "run with bash" refusal instead.
            output=$("$shell_name" -c ". '$PROJECT_ROOT/$script'; echo \"alive:\$?\"" 2>&1) || true
            assert_contains "$output" "Run this script with bash"
            assert_contains "$output" "alive:1"
        done < <(available_shells bash zsh sh dash)
    done
    cleanup_test_env
}

test_deno_wrapper_works_in_bash_and_zsh() {
    setup_test_env
    load_common_library
    parse_args 7
    setup_deno >/dev/null

    local wrapper="$HOME/.config/set-package-min-age/deno.sh" shell_name output

    while IFS= read -r shell_name; do
        install_fake_version_binary deno "deno 2.9.3 (stable, release, aarch64-apple-darwin)"
        output=$("$shell_name" -c ". '$wrapper'; deno add npm:chalk; deno install; deno run main.ts")
        assert_contains "$output" "ARGS: add npm:chalk"
        assert_contains "$output" "ARGS: install --minimum-dependency-age=P7D"
        assert_contains "$output" "ARGS: run main.ts"

        install_fake_version_binary deno "deno 2.10.0-rc.1 (canary)"
        output=$("$shell_name" -c ". '$wrapper'; deno add npm:chalk 'with space'")
        assert_contains "$output" "ARGS: add --minimum-dependency-age=P7D npm:chalk with space"
    done < <(available_shells bash zsh)
    cleanup_test_env
}

test_rc_source_line_defines_deno_function() {
    setup_test_env
    load_common_library
    parse_args 7
    setup_deno >/dev/null

    if command -v zsh >/dev/null 2>&1; then
        assert_eq "deno: function" "$(zsh -c ". '$HOME/.zshrc'; whence -w deno")"
    fi
    assert_eq "function" "$(bash -c ". '$HOME/.bashrc'; type -t deno")"
    cleanup_test_env
}

run_test "platform_scripts_run_from_any_shell" test_platform_scripts_run_from_any_shell || true
run_test "platform_scripts_refuse_to_be_sourced" test_platform_scripts_refuse_to_be_sourced || true
run_test "deno_wrapper_works_in_bash_and_zsh" test_deno_wrapper_works_in_bash_and_zsh || true
run_test "rc_source_line_defines_deno_function" test_rc_source_line_defines_deno_function || true
printf 'shells available: %s\n' "$(available_shells bash zsh sh dash | tr '\n' ' ')"
finish_tests
