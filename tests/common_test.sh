#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

reset_status_arrays() {
    FAILED_TOOLS=()
    SKIPPED_TOOLS=()
    UPDATED_TOOLS=()
    VALIDATED_TOOLS=()
    VALIDATION_FAILED_TOOLS=()
}

test_usage() {
    setup_test_env
    load_common_library

    local output status
    set +e
    output=$( ( usage ) 2>&1 )
    status=$?
    set -e

    assert_eq 0 "$status"
    assert_contains "$output" "--uv-exception RULE"
    assert_contains "$output" "--yarn-exception ITEM"
    cleanup_test_env
}

test_parse_args_success() {
    setup_test_env
    load_common_library

    parse_args
    assert_eq "7" "$MIN_AGE_DAYS"
    [[ "$REMOVE_MODE" == false ]] || fail "remove mode should be false by default"

    parse_args 14d --uv-exception "setuptools=false" --pnpm-exception webpack --bun-exception typescript --yarn-exception "@myorg/*"
    assert_eq "14" "$MIN_AGE_DAYS"
    assert_eq "1" "${#UV_EXCEPTIONS[@]}"
    assert_eq "1" "${#PNPM_EXCEPTIONS[@]}"
    assert_eq "1" "${#BUN_EXCEPTIONS[@]}"
    assert_eq "1" "${#YARN_EXCEPTIONS[@]}"
    assert_eq "setuptools=false" "${UV_EXCEPTIONS[0]}"
    cleanup_test_env
}

test_parse_args_failures() {
    setup_test_env
    load_common_library

    local output status

    set +e
    output=$( ( parse_args 0 ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "Days must be a positive integer"

    set +e
    output=$( ( parse_args 2 3 ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "Multiple day values provided"

    set +e
    output=$( ( parse_args --remove 7 ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "--remove cannot be combined"

    set +e
    output=$( ( parse_args --uv-exception badvalue ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "--uv-exception must use the format"

    set +e
    output=$( ( parse_args --wat ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "Unknown option"
    cleanup_test_env
}

test_backup_if_exists() {
    setup_test_env
    load_common_library
    parse_args

    local target="$HOME/test.conf"
    : > "$target"
    backup_if_exists "$target"
    assert_not_exists "${target}${BACKUP_SUFFIX}"

    printf 'data\n' > "$target"
    backup_if_exists "$target"
    assert_exists "${target}${BACKUP_SUFFIX}"
    cleanup_test_env
}

test_verify_and_finalize_success_paths() {
    setup_test_env
    load_common_library
    parse_args

    local file="$HOME/sample.conf"
    printf 'new-value\n' > "$file"
    reset_status_arrays
    verify_and_finalize "$file" "sample" 'new-value'
    assert_array_contains "sample" "${UPDATED_TOOLS[@]-}"

    printf 'old-value\n' > "$file"
    cp "$file" "${file}${BACKUP_SUFFIX}"
    printf 'new-value\n' > "$file"
    reset_status_arrays
    verify_and_finalize "$file" "sample2" 'old-value\|new-value'
    assert_array_contains "sample2" "${UPDATED_TOOLS[@]-}"
    assert_not_exists "${file}${BACKUP_SUFFIX}"
    cleanup_test_env
}

test_verify_and_finalize_rollback() {
    setup_test_env
    load_common_library
    parse_args

    local file="$HOME/sample.conf"
    printf 'before\n' > "$file"
    cp "$file" "${file}${BACKUP_SUFFIX}"
    printf 'after\n' > "$file"
    reset_status_arrays

    set +e
    verify_and_finalize "$file" "rollback" 'before'
    local status=$?
    set -e

    assert_eq 1 "$status"
    assert_file_contains "$file" "before"
    assert_array_contains "rollback" "${FAILED_TOOLS[@]-}"
    cleanup_test_env
}

test_setup_remove_pip() {
    setup_test_env
    load_common_library
    parse_args

    local pip_conf="$HOME/.config/pip/pip.conf"
    setup_pip
    assert_file_contains "$pip_conf" "[global]"
    assert_file_contains "$pip_conf" "min-age = 7d"

    reset_status_arrays
    setup_pip
    assert_array_contains "pip" "${SKIPPED_TOOLS[@]-}"

    printf '[global]\nmin-age = 2d\n' > "$pip_conf"
    reset_status_arrays
    setup_pip
    assert_file_contains "$pip_conf" "min-age = 7d"
    assert_array_contains "pip" "${UPDATED_TOOLS[@]-}"

    reset_status_arrays
    remove_pip
    assert_not_exists "$pip_conf"
    cleanup_test_env
}

test_setup_remove_uv() {
    setup_test_env
    install_fake_crontab
    load_common_library
    parse_args --uv-exception "setuptools=false" --uv-exception "@scope/pkg=30 days"

    local uv_conf="$HOME/.config/uv/uv.toml"
    setup_uv
    assert_file_contains "$uv_conf" 'exclude-newer = "2026-03-29T00:00:00Z"'
    assert_file_contains "$uv_conf" 'exclude-newer-package = { "setuptools" = false, "@scope/pkg" = "30 days" }'

    reset_status_arrays
    setup_uv
    assert_array_contains "uv" "${SKIPPED_TOOLS[@]-}"

    reset_status_arrays
    setup_cron_uv
    assert_exists "$TEST_CRONTAB_FILE"
    assert_file_contains "$TEST_CRONTAB_FILE" "$CRON_MARKER"

    reset_status_arrays
    setup_cron_uv
    assert_array_contains "cron-uv" "${SKIPPED_TOOLS[@]-}"

    reset_status_arrays
    remove_uv
    assert_not_exists "$uv_conf"

    reset_status_arrays
    remove_cron_uv
    assert_array_contains "cron-uv" "${UPDATED_TOOLS[@]-}"

    export TEST_CRONTAB_FAIL_WRITE=1
    reset_status_arrays
    set +e
    setup_cron_uv
    local status=$?
    set -e
    assert_eq 0 "$status"
    assert_array_contains "cron-uv" "${FAILED_TOOLS[@]-}"
    cleanup_test_env
}

test_setup_remove_npm() {
    setup_test_env
    load_common_library
    parse_args 9

    local npmrc="$HOME/.npmrc"
    setup_npm
    assert_file_contains "$npmrc" "min-release-age=9"

    printf 'min-release-age=2\n' > "$npmrc"
    reset_status_arrays
    setup_npm
    assert_file_contains "$npmrc" "min-release-age=9"

    reset_status_arrays
    remove_npm
    assert_not_exists "$npmrc"
    cleanup_test_env
}

test_setup_remove_pnpm() {
    setup_test_env
    load_common_library "Test" "$HOME/.config/pnpm/rc"
    parse_args 7 --pnpm-exception webpack --pnpm-exception "@myorg/*"

    setup_pnpm
    assert_file_contains "$PNPM_RC_PATH" "minimum-release-age=10080"
    assert_file_contains "$PNPM_RC_PATH" "minimum-release-age-exclude[]=webpack"
    assert_file_contains "$PNPM_RC_PATH" "minimum-release-age-exclude[]=@myorg/*"

    reset_status_arrays
    setup_pnpm
    assert_array_contains "pnpm" "${SKIPPED_TOOLS[@]-}"

    reset_status_arrays
    remove_pnpm
    assert_not_exists "$PNPM_RC_PATH"
    cleanup_test_env
}

test_setup_remove_bun() {
    setup_test_env
    load_common_library
    parse_args 3 --bun-exception "@types/node" --bun-exception typescript

    local bunfig="$HOME/.bunfig.toml"
    printf '[install]\nlinker = "isolated"\n' > "$bunfig"
    setup_bun
    assert_file_contains "$bunfig" '[install]'
    assert_file_contains "$bunfig" 'minimumReleaseAge = 259200'
    assert_file_contains "$bunfig" 'minimumReleaseAgeExcludes = ["@types/node", "typescript"]'

    reset_status_arrays
    setup_bun
    assert_array_contains "bun" "${SKIPPED_TOOLS[@]-}"

    reset_status_arrays
    remove_bun
    assert_file_contains "$bunfig" 'linker = "isolated"'
    assert_file_not_contains "$bunfig" 'minimumReleaseAge'

    printf '[install]\nminimumReleaseAge = 259200\n' > "$bunfig"
    reset_status_arrays
    remove_bun
    assert_not_exists "$bunfig"
    cleanup_test_env
}

test_setup_remove_yarn_classic() {
    setup_test_env
    load_common_library
    parse_args 2

    local yarnrc="$HOME/.yarnrc"
    setup_yarn_classic
    assert_file_contains "$yarnrc" 'cache-min 172800'

    reset_status_arrays
    setup_yarn_classic
    assert_array_contains "yarn-classic" "${SKIPPED_TOOLS[@]-}"

    reset_status_arrays
    remove_yarn_classic
    assert_not_exists "$yarnrc"
    cleanup_test_env
}

test_setup_remove_yarn_berry() {
    setup_test_env
    load_common_library
    parse_args 5 --yarn-exception "@myorg/*" --yarn-exception "@types/*"

    local yarnrc="$HOME/.yarnrc.yml"
    setup_yarn_berry
    assert_file_contains "$yarnrc" "npmMinimalAgeGate: '5d'"
    assert_file_contains "$yarnrc" "npmPreapprovedPackages: ['@myorg/*', '@types/*']"

    reset_status_arrays
    setup_yarn_berry
    assert_array_contains "yarn-berry" "${SKIPPED_TOOLS[@]-}"

    reset_status_arrays
    remove_yarn_berry
    assert_not_exists "$yarnrc"
    cleanup_test_env
}

test_validate_configs() {
    setup_test_env
    load_common_library
    parse_args 7 --uv-exception "setuptools=false" --pnpm-exception webpack --bun-exception typescript --yarn-exception "@myorg/*"
    install_fake_crontab

    setup_pip
    setup_uv
    setup_npm
    setup_pnpm
    setup_bun
    setup_yarn_classic
    setup_yarn_berry

    validate_configs
    assert_array_contains "pip" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "uv" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "npm" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "pnpm" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "yarn-classic" "${VALIDATED_TOOLS[@]-}"

    cleanup_test_env

    setup_test_env
    load_common_library
    validate_configs
    assert_eq "0" "${#VALIDATED_TOOLS[@]}"
    cleanup_test_env
}

test_validate_configs_yarn_berry() {
    setup_test_env
    load_common_library
    parse_args 4 --yarn-exception "@myorg/*"
    setup_yarn_berry

    validate_configs
    assert_array_contains "yarn-berry" "${VALIDATED_TOOLS[@]-}"
    cleanup_test_env
}

test_print_tool_overview_yarn_v1() {
    setup_test_env
    load_common_library
    install_fake_detection_tools "1.22.22"

    local output expected_yarn_path
    expected_yarn_path="$TEST_BIN_DIR/yarn"
    output=$(print_tool_overview)

    assert_contains "$output" "Tool overview"
    assert_contains "$output" "pip              yes"
    assert_contains "$output" "$TEST_BIN_DIR/pip3"
    assert_contains "$output" "bun              no         not found"
    assert_contains "$output" "yarn v1          yes        $expected_yarn_path"
    assert_contains "$output" "yarn v2+         no         $expected_yarn_path"
    cleanup_test_env
}

test_print_tool_overview_yarn_berry() {
    setup_test_env
    load_common_library
    install_fake_detection_tools "4.7.0"

    local output expected_yarn_path
    expected_yarn_path="$TEST_BIN_DIR/yarn"
    output=$(print_tool_overview)

    assert_contains "$output" "yarn v1          no         $expected_yarn_path"
    assert_contains "$output" "yarn v2+         yes        $expected_yarn_path"
    cleanup_test_env
}

test_main_output_includes_tool_overview() {
    setup_test_env
    install_fake_crontab
    install_fake_detection_tools "1.22.22"
    load_common_library

    local output
    output=$(main 4 --uv-exception "setuptools=false" --pnpm-exception webpack --bun-exception typescript --yarn-exception "@myorg/*")

    assert_contains "$output" "minimum age: 4 days"
    assert_contains "$output" "Tool overview"
    assert_contains "$output" "$TEST_BIN_DIR/pip3"
    assert_contains "$output" "bun              no         not found"
    assert_before "$output" "Tool overview" "Configuration"
    assert_contains "$output" "updated"
    assert_contains "$output" "validated"
    cleanup_test_env
}

test_main_remove_output_includes_tool_overview() {
    setup_test_env
    install_fake_crontab
    install_fake_detection_tools "1.22.22"
    load_common_library

    local output
    output=$(main --remove)

    assert_contains "$output" "REMOVE MODE"
    assert_contains "$output" "Tool overview"
    assert_before "$output" "Tool overview" "Removing settings"
    assert_contains "$output" "removed"
    cleanup_test_env
}

run_test "usage" test_usage || true
run_test "parse_args_success" test_parse_args_success || true
run_test "parse_args_failures" test_parse_args_failures || true
run_test "backup_if_exists" test_backup_if_exists || true
run_test "verify_and_finalize_success" test_verify_and_finalize_success_paths || true
run_test "verify_and_finalize_rollback" test_verify_and_finalize_rollback || true
run_test "setup_remove_pip" test_setup_remove_pip || true
run_test "setup_remove_uv" test_setup_remove_uv || true
run_test "setup_remove_npm" test_setup_remove_npm || true
run_test "setup_remove_pnpm" test_setup_remove_pnpm || true
run_test "setup_remove_bun" test_setup_remove_bun || true
run_test "setup_remove_yarn_classic" test_setup_remove_yarn_classic || true
run_test "setup_remove_yarn_berry" test_setup_remove_yarn_berry || true
run_test "validate_configs" test_validate_configs || true
run_test "validate_configs_yarn_berry" test_validate_configs_yarn_berry || true
run_test "print_tool_overview_yarn_v1" test_print_tool_overview_yarn_v1 || true
run_test "print_tool_overview_yarn_berry" test_print_tool_overview_yarn_berry || true
run_test "main_output_includes_tool_overview" test_main_output_includes_tool_overview || true
run_test "main_remove_output_includes_tool_overview" test_main_remove_output_includes_tool_overview || true

finish_tests
