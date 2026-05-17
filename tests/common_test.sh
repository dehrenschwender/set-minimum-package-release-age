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
    PREFLIGHT_FAILED_TOOLS=()
}

prepare_scoped_remove_fixtures() {
    install_fake_crontab
    load_common_library
    parse_args 4 \
        --exception uv:setuptools=false \
        --exception pnpm:webpack \
        --exception 'yarn-berry:@myorg/*' \
        --exception bun:typescript
    setup_pip
    setup_uv
    setup_cron_uv
    setup_pnpm
    setup_bun
    setup_yarn_classic
    setup_yarn_berry
    setup_vlt
    setup_cron_vlt
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
    assert_contains "$output" "--exception SPEC"
    assert_contains "$output" "--remove-tool TOOL"
    cleanup_test_env
}

test_parse_args_success() {
    setup_test_env
    load_common_library

    parse_args
    assert_eq "7" "$MIN_AGE_DAYS"
    [[ "$REMOVE_MODE" == false ]] || fail "remove mode should be false by default"
    [[ "$REMOVE_SCOPED_MODE" == false ]] || fail "scoped remove mode should be false by default"

    parse_args 14d \
        --exception uv:setuptools=false \
        --exception pnpm:webpack \
        --exception bun:typescript \
        --exception 'yarn-berry:@myorg/*'
    assert_eq "14" "$MIN_AGE_DAYS"
    assert_eq "1" "${#UV_EXCEPTIONS[@]}"
    assert_eq "1" "${#PNPM_EXCEPTIONS[@]}"
    assert_eq "1" "${#BUN_EXCEPTIONS[@]}"
    assert_eq "1" "${#YARN_EXCEPTIONS[@]}"
    assert_eq "setuptools=false" "${UV_EXCEPTIONS[0]}"

    parse_args --remove-tool pip --remove-tool uv --remove-tool uv
    [[ "$REMOVE_SCOPED_MODE" == true ]] || fail "scoped remove mode should be true"
    assert_eq "2" "${#REMOVE_TOOLS[@]}"
    assert_eq "pip" "${REMOVE_TOOLS[0]}"
    assert_eq "uv" "${REMOVE_TOOLS[1]}"
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
    assert_contains "$output" "removal modes cannot be combined with a days argument"

    set +e
    output=$( ( parse_args --remove-tool pip 7 ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "removal modes cannot be combined with a days argument"

    set +e
    output=$( ( parse_args --remove --remove-tool pip ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "--remove cannot be combined with --remove-tool"

    set +e
    output=$( ( parse_args --exception uv:setuptools=false --remove ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "cannot be combined with --exception"

    set +e
    output=$( ( parse_args --exception pip:foo ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "does not support native exceptions"

    set +e
    output=$( ( parse_args --exception npm:foo ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "does not support native exceptions"

    set +e
    output=$( ( parse_args --exception uv:badvalue ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "uv exceptions must use package=false"

    set +e
    output=$( ( parse_args --exception pnpm: ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "--exception must use the format"

    set +e
    output=$( ( parse_args --exception bun: ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "--exception must use the format"

    set +e
    output=$( ( parse_args --exception yarn-berry: ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "--exception must use the format"

    set +e
    output=$( ( parse_args --remove-tool wat ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "Unknown remove tool"

    set +e
    output=$( ( parse_args --uv-exception badvalue ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "Unknown option"

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
    assert_file_contains "$pip_conf" "[install]"
    assert_file_contains "$pip_conf" "uploaded-prior-to = 2026-03-29T00:00:00Z"

    reset_status_arrays
    setup_pip
    assert_array_contains "pip" "${SKIPPED_TOOLS[@]-}"

    printf '[global]\nmin-age = 2d\n' > "$pip_conf"
    reset_status_arrays
    setup_pip
    assert_file_contains "$pip_conf" "uploaded-prior-to = 2026-03-29T00:00:00Z"
    assert_file_not_contains "$pip_conf" "min-age = 2d"
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
    parse_args --exception uv:setuptools=false --exception uv:@scope/pkg=30\ days

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
    parse_args 7 --exception pnpm:webpack --exception 'pnpm:@myorg/*'

    setup_pnpm
    assert_file_contains "$PNPM_CONFIG_PATH" "minimumReleaseAge: 10080"
    assert_file_contains "$PNPM_CONFIG_PATH" "minimumReleaseAgeExclude: ['webpack', '@myorg/*']"

    reset_status_arrays
    setup_pnpm
    assert_array_contains "pnpm" "${SKIPPED_TOOLS[@]-}"

    reset_status_arrays
    remove_pnpm
    assert_not_exists "$PNPM_CONFIG_PATH"
    cleanup_test_env
}

test_setup_remove_pnpm_legacy_rc() {
    setup_test_env
    load_common_library "Test" "$HOME/.config/pnpm/rc"
    PNPM_CONFIG_PATH="$HOME/.config/pnpm/config.yaml"
    parse_args 7 --exception pnpm:webpack --exception 'pnpm:@myorg/*'
    TOOL_DETECTION_CACHE="pnpm|yes|$TEST_BIN_DIR/pnpm|10.19.0"

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

test_setup_remove_vlt() {
    setup_test_env
    install_fake_crontab
    load_common_library
    parse_args 5

    setup_vlt
    assert_file_contains "$VLT_CONFIG_PATH" '"config": {'
    assert_file_contains "$VLT_CONFIG_PATH" '"before": "2026-03-29T00:00:00Z"'

    reset_status_arrays
    setup_vlt
    assert_array_contains "vlt" "${SKIPPED_TOOLS[@]-}"

    reset_status_arrays
    setup_cron_vlt
    assert_exists "$TEST_CRONTAB_FILE"
    assert_file_contains "$TEST_CRONTAB_FILE" "$VLT_CRON_MARKER"

    reset_status_arrays
    remove_vlt
    assert_not_exists "$VLT_CONFIG_PATH"

    reset_status_arrays
    remove_cron_vlt
    assert_array_contains "cron-vlt" "${UPDATED_TOOLS[@]-}"
    cleanup_test_env
}

test_setup_remove_bun() {
    setup_test_env
    load_common_library
    parse_args 3 --exception bun:@types/node --exception bun:typescript

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
    parse_args 5 --exception 'yarn-berry:@myorg/*' --exception 'yarn-berry:@types/*'

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
    parse_args 7 \
        --exception uv:setuptools=false \
        --exception pnpm:webpack \
        --exception bun:typescript \
        --exception 'yarn-berry:@myorg/*'
    install_fake_crontab

    setup_pip
    setup_uv
    setup_npm
    setup_pnpm
    setup_bun
    setup_yarn_classic
    setup_yarn_berry
    setup_vlt

    validate_configs
    assert_array_contains "pip" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "uv" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "npm" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "pnpm" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "bun" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "yarn-classic" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "yarn-berry" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "vlt" "${VALIDATED_TOOLS[@]-}"

    cleanup_test_env

    setup_test_env
    load_common_library
    validate_configs
    assert_eq "0" "${#VALIDATED_TOOLS[@]}"
    cleanup_test_env
}

test_print_tool_overview_yarn_v1() {
    setup_test_env
    load_common_library
    install_fake_detection_tools "1.22.22"

    local output expected_yarn_path
    expected_yarn_path="$TEST_BIN_DIR/yarn"
    output=$(print_tool_overview)

    assert_contains "$output" "VERSION"
    assert_contains "$output" "pip              yes        26.0"
    assert_contains "$output" "$TEST_BIN_DIR/pip3"
    assert_contains "$output" "npm              yes        11.10.0"
    assert_contains "$output" "bun              no         n/a          not found"
    assert_contains "$output" "vlt              yes        0.0.0"
    assert_contains "$output" "yarn v1          yes        1.22.22      $expected_yarn_path"
    assert_contains "$output" "yarn v2+         no         1.22.22      $expected_yarn_path"
    cleanup_test_env
}

test_print_tool_overview_yarn_berry() {
    setup_test_env
    load_common_library
    install_fake_detection_tools "4.7.0"

    local output expected_yarn_path
    expected_yarn_path="$TEST_BIN_DIR/yarn"
    output=$(print_tool_overview)

    assert_contains "$output" "yarn v1          no         4.7.0        $expected_yarn_path"
    assert_contains "$output" "yarn v2+         yes        4.7.0        $expected_yarn_path"
    cleanup_test_env
}

test_preflight_npm_version_failure() {
    setup_test_env
    install_fake_detection_tools "4.10.0" 0 "11.9.0"
    load_common_library

    local output status
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    assert_contains "$output" "Tool readiness"
    assert_contains "$output" "npm"
    assert_contains "$output" "min-release-age requires >= 11.10.0"
    assert_not_exists "$HOME/.npmrc"
    cleanup_test_env
}

test_preflight_pip_version_failure() {
    setup_test_env
    install_fake_detection_tools "4.10.0" 0 "11.10.0" "10.19.0" "1.3.2" "0.7.0" "25.9"
    load_common_library

    local output status
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    assert_contains "$output" "uploaded-prior-to requires >= 26.0"
    assert_not_exists "$HOME/.config/pip/pip.conf"
    cleanup_test_env
}

test_preflight_pnpm_base_version_failure() {
    setup_test_env
    install_fake_detection_tools "4.10.0" 0 "11.10.0" "10.15.0"
    load_common_library

    local output status
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    assert_contains "$output" "pnpm"
    assert_contains "$output" "minimum-release-age requires >= 10.16.0"
    assert_not_exists "$PNPM_RC_PATH"
    cleanup_test_env
}

test_preflight_pnpm_pattern_exception_version_failure() {
    setup_test_env
    install_fake_detection_tools "4.10.0" 0 "11.10.0" "10.16.5"
    load_common_library

    local output status
    set +e
    output=$(main 4 --exception 'pnpm:@myorg/*' 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    assert_contains "$output" "minimum-release-age exceptions requires >= 10.17.0"
    cleanup_test_env
}

test_preflight_pnpm_version_selector_failure() {
    setup_test_env
    install_fake_detection_tools "4.10.0" 0 "11.10.0" "10.18.0"
    load_common_library

    local output status
    set +e
    output=$(main 4 --exception pnpm:webpack@4.47.0 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    assert_contains "$output" "minimum-release-age exceptions requires >= 10.19.0"
    cleanup_test_env
}

test_preflight_yarn_berry_version_failure() {
    setup_test_env
    install_fake_detection_tools "4.9.9"
    load_common_library

    local output status
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    assert_contains "$output" "npmMinimalAgeGate requires >= 4.10.0"
    assert_not_exists "$HOME/.yarnrc.yml"
    cleanup_test_env
}

test_main_output_includes_readiness_and_results() {
    setup_test_env
    install_fake_crontab
    install_fake_detection_tools "4.10.0"
    load_common_library

    local output
    output=$(main 4 \
        --exception uv:setuptools=false \
        --exception pnpm:webpack \
        --exception bun:typescript \
        --exception 'yarn-berry:@myorg/*')

    assert_contains "$output" "minimum age: 4 days"
    assert_contains "$output" "Tool readiness"
    assert_contains "$output" "PATH"
    assert_contains "$output" "Results"
    assert_contains "$output" "pip              yes        26.0"
    assert_contains "$output" "$TEST_BIN_DIR/pip3"
    assert_contains "$output" "uploaded-prior-to requires >= 26.0"
    assert_contains "$output" "pnpm             yes        10.19.0"
    assert_contains "$output" "minimum-release-age requires >= 10.16.0"
    assert_contains "$output" "uv cron          added      --"
    assert_contains "$output" "vlt cron         added      --"
    assert_contains "$output" "uploaded-prior-to = 2026-03-29T00:00:00Z (4d window) | uploaded-prior-to matches"
    assert_contains "$output" "exclude-newer = \"2026-03-29T00:00:00Z\"; exceptions=1 | exclude-newer settings match"
    assert_contains "$output" "before = 2026-03-29T00:00:00Z (4d window) | before matches"
    assert_before "$output" "Tool readiness" "Results"
    [[ "$output" != *"Configuration"* ]] || fail "did not expect Configuration section"
    [[ "$output" != *"Validation"* ]] || fail "did not expect Validation section"
    [[ "$output" != *"uv exceptions"* ]] || fail "did not expect separate uv exceptions row"
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
    assert_contains "$output" "Tool readiness"
    assert_before "$output" "Tool readiness" "Removing settings"
    cleanup_test_env
}

test_main_scoped_remove_output_includes_tool_overview() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.10.0"

    local output
    output=$(main --remove-tool pip --remove-tool uv)

    assert_contains "$output" "REMOVE MODE (SCOPED)"
    assert_contains "$output" "Removing selected settings"
    assert_not_exists "$HOME/.config/pip/pip.conf"
    assert_not_exists "$HOME/.config/uv/uv.toml"
    assert_exists "$TEST_CRONTAB_FILE"
    cleanup_test_env
}

test_scoped_remove_only_pip() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.10.0"

    main --remove-tool pip >/dev/null

    assert_not_exists "$HOME/.config/pip/pip.conf"
    assert_exists "$HOME/.config/uv/uv.toml"
    assert_exists "$HOME/.yarnrc.yml"
    cleanup_test_env
}

test_scoped_remove_only_uv() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.10.0"

    main --remove-tool uv >/dev/null

    assert_not_exists "$HOME/.config/uv/uv.toml"
    assert_exists "$TEST_CRONTAB_FILE"
    cleanup_test_env
}

test_scoped_remove_only_uv_cron() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.10.0"

    main --remove-tool uv-cron >/dev/null

    assert_exists "$TEST_CRONTAB_FILE"
    assert_file_not_contains "$TEST_CRONTAB_FILE" "$CRON_MARKER"
    assert_file_contains "$TEST_CRONTAB_FILE" "$VLT_CRON_MARKER"
    assert_exists "$HOME/.config/uv/uv.toml"
    cleanup_test_env
}

test_scoped_remove_uv_and_uv_cron() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.10.0"

    main --remove-tool uv --remove-tool uv-cron >/dev/null

    assert_not_exists "$HOME/.config/uv/uv.toml"
    assert_exists "$TEST_CRONTAB_FILE"
    assert_file_not_contains "$TEST_CRONTAB_FILE" "$CRON_MARKER"
    assert_file_contains "$TEST_CRONTAB_FILE" "$VLT_CRON_MARKER"
    cleanup_test_env
}

test_scoped_remove_only_yarn_berry() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.10.0"

    main --remove-tool yarn-berry >/dev/null

    assert_not_exists "$HOME/.yarnrc.yml"
    assert_exists "$HOME/.yarnrc"
    cleanup_test_env
}

test_scoped_remove_only_vlt() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.10.0"

    main --remove-tool vlt >/dev/null

    assert_not_exists "$VLT_CONFIG_PATH"
    assert_exists "$TEST_CRONTAB_FILE"
    cleanup_test_env
}

test_scoped_remove_only_vlt_cron() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.10.0"

    main --remove-tool vlt-cron >/dev/null

    assert_not_exists "$TEST_CRONTAB_FILE"
    assert_exists "$VLT_CONFIG_PATH"
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
run_test "setup_remove_pnpm_legacy_rc" test_setup_remove_pnpm_legacy_rc || true
run_test "setup_remove_vlt" test_setup_remove_vlt || true
run_test "setup_remove_bun" test_setup_remove_bun || true
run_test "setup_remove_yarn_classic" test_setup_remove_yarn_classic || true
run_test "setup_remove_yarn_berry" test_setup_remove_yarn_berry || true
run_test "validate_configs" test_validate_configs || true
run_test "print_tool_overview_yarn_v1" test_print_tool_overview_yarn_v1 || true
run_test "print_tool_overview_yarn_berry" test_print_tool_overview_yarn_berry || true
run_test "preflight_npm_version_failure" test_preflight_npm_version_failure || true
run_test "preflight_pip_version_failure" test_preflight_pip_version_failure || true
run_test "preflight_pnpm_base_version_failure" test_preflight_pnpm_base_version_failure || true
run_test "preflight_pnpm_pattern_exception_version_failure" test_preflight_pnpm_pattern_exception_version_failure || true
run_test "preflight_pnpm_version_selector_failure" test_preflight_pnpm_version_selector_failure || true
run_test "preflight_yarn_berry_version_failure" test_preflight_yarn_berry_version_failure || true
run_test "main_output_includes_readiness_and_results" test_main_output_includes_readiness_and_results || true
run_test "main_remove_output_includes_tool_overview" test_main_remove_output_includes_tool_overview || true
run_test "main_scoped_remove_output_includes_tool_overview" test_main_scoped_remove_output_includes_tool_overview || true
run_test "scoped_remove_only_pip" test_scoped_remove_only_pip || true
run_test "scoped_remove_only_uv" test_scoped_remove_only_uv || true
run_test "scoped_remove_only_uv_cron" test_scoped_remove_only_uv_cron || true
run_test "scoped_remove_uv_and_uv_cron" test_scoped_remove_uv_and_uv_cron || true
run_test "scoped_remove_only_yarn_berry" test_scoped_remove_only_yarn_berry || true
run_test "scoped_remove_only_vlt" test_scoped_remove_only_vlt || true
run_test "scoped_remove_only_vlt_cron" test_scoped_remove_only_vlt_cron || true

finish_tests
