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
    PREFLIGHT_FAILED_DETAILS=()
}

prepare_scoped_remove_fixtures() {
    install_fake_crontab
    install_fake_detection_tools "4.12.0"
    load_common_library
    parse_args 4 \
        --exception uv:setuptools=false \
        --exception poetry:internal-lib \
        --exception poetry-source:private-repo \
        --exception 'npm:@myorg/*' \
        --exception pnpm:webpack \
        --exception 'yarn-berry:@myorg/*' \
        --exception bun:typescript
    setup_pip
    setup_uv
    install_legacy_uv_cron_entry
    write_pixi_global_manifest
    setup_poetry
    setup_npm
    setup_pnpm
    setup_bun
    setup_yarn_classic
    setup_yarn_berry
    setup_deno
    setup_pixi
    setup_vlt
    setup_cron_vlt
    setup_bundler
}

test_setup_remove_pdm_cargo_mise() {
    setup_test_env
    install_fake_detection_tools "4.12.0"
    load_common_library
    parse_args 6 --exception mise:trivy --exception 'mise:npm:*'

    mkdir -p "$(dirname "$PDM_CONFIG_PATH")"
    printf '[strategy]\nupdate = "eager"\n' > "$PDM_CONFIG_PATH"
    setup_pdm
    setup_cargo
    setup_mise
    assert_file_contains "$PDM_CONFIG_PATH" 'exclude-newer = "6d"'
    assert_file_contains "$PDM_CONFIG_PATH" 'update = "eager"'
    assert_eq "1" "$(grep -c '^\[strategy\]' "$PDM_CONFIG_PATH")"
    assert_eq "$HOME/.cargo/config.toml" "$CARGO_CONFIG_PATH"
    assert_file_contains "$CARGO_CONFIG_PATH" '[registry]'
    assert_file_contains "$CARGO_CONFIG_PATH" 'global-min-publish-age = "6 days"'
    assert_eq "$HOME/.config/mise/config.toml" "$MISE_CONFIG_PATH"
    assert_file_contains "$MISE_CONFIG_PATH" '[settings]'
    assert_file_contains "$MISE_CONFIG_PATH" 'minimum_release_age = "6d"'
    assert_file_contains "$MISE_CONFIG_PATH" 'minimum_release_age_excludes = ["trivy", "npm:*"]'

    validate_configs >/dev/null
    assert_array_contains "pdm" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "cargo" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "mise" "${VALIDATED_TOOLS[@]-}"

    reset_status_arrays
    setup_pdm
    setup_cargo
    setup_mise
    assert_array_contains "pdm" "${SKIPPED_TOOLS[@]-}"
    assert_array_contains "cargo" "${SKIPPED_TOOLS[@]-}"
    assert_array_contains "mise" "${SKIPPED_TOOLS[@]-}"

    parse_args 2
    reset_status_arrays
    setup_mise
    assert_array_contains "mise" "${UPDATED_TOOLS[@]-}"
    assert_file_contains "$MISE_CONFIG_PATH" 'minimum_release_age = "2d"'
    assert_file_not_contains "$MISE_CONFIG_PATH" 'minimum_release_age_excludes'

    reset_status_arrays
    remove_pdm
    remove_cargo
    remove_mise
    assert_file_contains "$PDM_CONFIG_PATH" 'update = "eager"'
    assert_file_not_contains "$PDM_CONFIG_PATH" 'exclude-newer'
    assert_not_exists "$CARGO_CONFIG_PATH"
    assert_not_exists "$MISE_CONFIG_PATH"

    reset_status_arrays
    remove_pdm
    remove_cargo
    remove_mise
    assert_array_contains "pdm" "${SKIPPED_TOOLS[@]-}"
    assert_array_contains "cargo" "${SKIPPED_TOOLS[@]-}"
    assert_array_contains "mise" "${SKIPPED_TOOLS[@]-}"
    cleanup_test_env
}

test_cargo_uses_legacy_config_file_when_only_it_exists() {
    setup_test_env
    mkdir -p "$HOME/.cargo"
    printf '[net]\ngit-fetch-with-cli = true\n' > "$HOME/.cargo/config"
    load_common_library
    parse_args 3

    assert_eq "$HOME/.cargo/config" "$CARGO_CONFIG_PATH"
    setup_cargo
    assert_file_contains "$HOME/.cargo/config" 'global-min-publish-age = "3 days"'
    assert_file_contains "$HOME/.cargo/config" 'git-fetch-with-cli = true'
    assert_not_exists "$HOME/.cargo/config.toml"
    cleanup_test_env
}

test_preflight_new_tools() {
    setup_test_env
    install_fake_crontab
    install_fake_detection_tools "4.12.0"
    install_fake_version_binary cargo "cargo 1.96.0 (30a34c682 2026-05-25)"
    install_fake_version_binary pdm "PDM, version 2.29.3"
    install_fake_version_binary mise "2026.10.18 macos-arm64 (2026-10-23)"
    load_common_library

    local output status
    output=$(main 4 --exception mise:trivy)
    assert_contains "$output" "$(expect_tool_row '!' Cargo 1.96.0)"
    assert_contains "$(flatten_output "$output")" "global-min-publish-age requires >= 1.100.0; config can still be written"
    assert_contains "$output" "$(expect_tool_row '*' PDM 2.29.3)"
    assert_contains "$output" "$(expect_tool_row '*' mise 2026.10.18)"
    assert_file_contains "$HOME/.cargo/config.toml" 'global-min-publish-age = "4 days"'
    cleanup_test_env

    setup_test_env
    install_fake_detection_tools "4.12.0"
    install_fake_version_binary mise "2026.4.1 macos-arm64 (2026-04-01)"
    load_common_library
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "minimum_release_age requires >= 2026.4.22"
    assert_not_exists "$HOME/.config/mise/config.toml"
    cleanup_test_env

    setup_test_env
    install_fake_detection_tools "4.12.0"
    install_fake_version_binary pdm "PDM, version 2.26.0"
    load_common_library
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "strategy.exclude-newer requires >= 2.27.0"
    cleanup_test_env
}

test_vlt_cron_replaces_stale_entry() {
    setup_test_env
    install_fake_crontab
    load_common_library
    printf '0 1 * * * /usr/bin/true # unrelated user job\n' | crontab -

    parse_args 7
    setup_cron_vlt
    assert_file_contains "$TEST_CRONTAB_FILE" "echo 7 >>"

    parse_args 14
    reset_status_arrays
    setup_cron_vlt
    assert_array_contains "cron-vlt" "${UPDATED_TOOLS[@]-}"
    assert_file_contains "$TEST_CRONTAB_FILE" "echo 14 >>"
    assert_file_not_contains "$TEST_CRONTAB_FILE" "echo 7 >>"
    assert_file_contains "$TEST_CRONTAB_FILE" "unrelated user job"
    assert_eq "1" "$(grep -cF "$VLT_CRON_MARKER" "$TEST_CRONTAB_FILE")"

    reset_status_arrays
    setup_cron_vlt
    assert_array_contains "cron-vlt" "${SKIPPED_TOOLS[@]-}"
    cleanup_test_env
}

test_missing_crontab_does_not_abort_run() {
    setup_test_env
    install_fake_detection_tools "4.12.0"
    load_common_library
    rm -f "$TEST_BIN_DIR/crontab"
    # /usr/bin may provide a real crontab; hide it so only the test bin dir is used.
    local saved_path="$PATH"
    mkdir -p "$TEST_ROOT/sysbin"
    local tool
    for tool in bash sh env awk sed grep cat cp mv rm mkdir mktemp dirname basename touch diff head tr date sleep kill wc printf rmdir id getconf; do
        if command -v "$tool" >/dev/null 2>&1; then
            ln -sf "$(command -v "$tool")" "$TEST_ROOT/sysbin/$tool"
        fi
    done
    PATH="$TEST_BIN_DIR:$TEST_ROOT/sysbin"

    local output status
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e
    PATH="$saved_path"

    assert_eq 0 "$status"
    assert_contains "$output" "crontab not available"
    assert_contains "$output" "Summary"
    cleanup_test_env
}

test_vlt_launchd_refresh_job() {
    setup_test_env
    load_common_library
    VLT_REFRESH_SCHEDULER=launchd
    local plist="$VLT_LAUNCHD_PLIST_PATH" label="com.set-minimum-package-release-age.vlt-refresh"
    printf '0 0 * * * old-refresh %s\n0 1 * * * /usr/bin/true # unrelated user job\n' "$VLT_CRON_MARKER" | crontab -

    parse_args 7
    setup_cron_vlt
    assert_array_contains "cron-vlt" "${UPDATED_TOOLS[@]-}"
    assert_file_contains "$plist" "<string>$label</string>"
    assert_file_contains "$plist" "<string>7</string>"
    assert_file_contains "$plist" "<string>/opt/test &amp; co/set_package_min_age_test.sh</string>"
    assert_file_contains "$plist" "<string>$VLT_CONFIG_PATH</string>"
    assert_file_contains "$plist" "<key>RunAtLoad</key>"
    assert_file_contains "$TEST_ROOT/launchctl.log" "bootstrap gui/$(id -u) $plist"
    # The legacy cron entry is migrated away; unrelated jobs stay.
    assert_file_not_contains "$TEST_CRONTAB_FILE" "$VLT_CRON_MARKER"
    assert_file_contains "$TEST_CRONTAB_FILE" "unrelated user job"

    reset_status_arrays
    setup_cron_vlt
    assert_array_contains "cron-vlt" "${SKIPPED_TOOLS[@]-}"

    parse_args 14
    reset_status_arrays
    setup_cron_vlt
    assert_array_contains "cron-vlt" "${UPDATED_TOOLS[@]-}"
    assert_file_contains "$plist" "<string>14</string>"
    assert_file_not_contains "$plist" "<string>7</string>"

    reset_status_arrays
    remove_cron_vlt
    assert_array_contains "cron-vlt" "${UPDATED_TOOLS[@]-}"
    assert_not_exists "$plist"
    assert_not_exists "$TEST_ROOT/launchd/$label"

    reset_status_arrays
    remove_cron_vlt
    assert_array_contains "cron-vlt" "${SKIPPED_TOOLS[@]-}"

    # Without a GUI session bootstrap fails; the agent is still written for next login.
    export TEST_LAUNCHCTL_FAIL_BOOTSTRAP=1
    reset_status_arrays
    local output
    output=$(setup_cron_vlt)
    assert_contains "$output" "loads at next login"
    assert_exists "$plist"
    cleanup_test_env
}

test_update_detail_when_only_exceptions_change() {
    setup_test_env
    install_fake_detection_tools "4.12.0" 0 "12.0.1" "11.0.0"
    load_common_library
    parse_args 7
    setup_pnpm >/dev/null

    parse_args 7 --exception pnpm:webpack
    reset_status_arrays
    local output
    output=$(setup_pnpm)
    assert_contains "$output" "10080 (config.yaml); exceptions=1 (exceptions changed)"
    [[ "$output" != *"10080 --> 10080"* ]] || fail "did not expect X --> X detail: $output"
    cleanup_test_env
}

test_pixi_global_exemptions() {
    setup_test_env
    install_fake_detection_tools "4.12.0"
    load_common_library
    write_pixi_global_manifest
    local manifest="$PIXI_GLOBAL_MANIFEST_PATH"
    local table='exclude-newer = { cutoff = "7d", exemptions = { "polars" = "*", "ripgrep" = "==14.1.0" } }'

    parse_args 7 --exception pixi:polars --exception 'pixi:ripgrep==14.1.0'
    setup_pixi >/dev/null
    assert_file_contains "$manifest" "$table"
    assert_before "$(cat "$manifest")" "$table" '[envs.ripgrep]'
    validate_pixi >/dev/null
    assert_array_contains "pixi" "${VALIDATED_TOOLS[@]-}"

    reset_status_arrays
    setup_pixi >/dev/null
    assert_array_contains "pixi" "${SKIPPED_TOOLS[@]-}"

    # Dropping the exceptions turns the managed table back into the plain form.
    parse_args 7
    reset_status_arrays
    setup_pixi >/dev/null
    assert_array_contains "pixi" "${UPDATED_TOOLS[@]-}"
    assert_file_contains "$manifest" 'exclude-newer = "7d"'
    assert_file_not_contains "$manifest" 'exemptions'

    parse_args 7 --exception pixi:polars
    setup_pixi >/dev/null
    reset_status_arrays
    remove_pixi >/dev/null
    assert_array_contains "pixi" "${UPDATED_TOOLS[@]-}"
    assert_file_not_contains "$manifest" 'exclude-newer'
    assert_file_contains "$manifest" '[envs.ripgrep]'
    cleanup_test_env
}

test_hex_repo_exclusions() {
    setup_test_env
    load_common_library
    local hex_conf="$HEX_CONFIG_PATH"

    parse_args 7 --exception hex:hexpm:myorg --exception hex:internal
    setup_hex >/dev/null
    assert_file_contains "$hex_conf" '{cooldown,<<"7d">>}.'
    assert_file_contains "$hex_conf" '{cooldown_exclude_repos,[<<"hexpm:myorg">>,<<"internal">>]}.'
    validate_configs >/dev/null
    assert_array_contains "hex" "${VALIDATED_TOOLS[@]-}"

    reset_status_arrays
    setup_hex >/dev/null
    assert_array_contains "hex" "${SKIPPED_TOOLS[@]-}"

    # Without hex exceptions an existing exclusion list is preserved.
    parse_args 7
    reset_status_arrays
    setup_hex >/dev/null
    assert_array_contains "hex" "${SKIPPED_TOOLS[@]-}"
    assert_file_contains "$hex_conf" '{cooldown_exclude_repos,[<<"hexpm:myorg">>,<<"internal">>]}.'

    # A term Hex wrapped across lines is never rewritten.
    printf '{cooldown,<<"7d">>}.\n{cooldown_exclude_repos,[<<"hexpm:a">>,\n                         <<"hexpm:b">>]}.\n' > "$hex_conf"
    local before
    before=$(cat "$hex_conf")
    parse_args 7 --exception hex:hexpm:c
    reset_status_arrays
    setup_hex >/dev/null
    assert_array_contains "hex" "${FAILED_TOOLS[@]-}"
    assert_eq "$before" "$(cat "$hex_conf")"
    cleanup_test_env
}

test_cargo_registry_exemptions() {
    setup_test_env
    load_common_library
    local cargo_conf="$CARGO_CONFIG_PATH"
    local managed='min-publish-age = "0" # set-minimum-package-release-age exception'
    mkdir -p "$(dirname "$cargo_conf")"
    printf '[registries.my-reg]\nindex = "sparse+https://example.com/index/"\n\n[registries.other]\nindex = "sparse+https://other.example/"\nmin-publish-age = "1 days"\n' > "$cargo_conf"

    parse_args 7 --exception cargo:my-reg --exception cargo:crates-io
    setup_cargo >/dev/null
    assert_array_contains "cargo" "${UPDATED_TOOLS[@]-}"
    assert_file_contains "$cargo_conf" 'global-min-publish-age = "7 days"'
    assert_file_contains "$cargo_conf" 'index = "sparse+https://example.com/index/"'
    assert_file_contains "$cargo_conf" '[registries.crates-io]'
    assert_file_contains "$cargo_conf" 'min-publish-age = "1 days"'
    assert_eq "$(printf 'crates-io\nmy-reg')" "$(cargo_managed_registries "$cargo_conf")"
    validate_configs >/dev/null
    assert_array_contains "cargo" "${VALIDATED_TOOLS[@]-}"
    # Parse with tomllib (Python 3.11+) when available.
    if python3 -I -c 'import tomllib' >/dev/null 2>&1; then
        python3 -I -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$cargo_conf" \
            || fail "cargo config is not valid TOML: $(cat "$cargo_conf")"
    fi

    reset_status_arrays
    setup_cargo >/dev/null
    assert_array_contains "cargo" "${SKIPPED_TOOLS[@]-}"

    # Removing an exemption drops its line, and the section if the script created it.
    parse_args 7 --exception cargo:my-reg
    reset_status_arrays
    setup_cargo >/dev/null
    assert_file_not_contains "$cargo_conf" '[registries.crates-io]'
    assert_eq "my-reg" "$(cargo_managed_registries "$cargo_conf")"

    reset_status_arrays
    remove_cargo >/dev/null
    assert_file_not_contains "$cargo_conf" "$managed"
    assert_file_not_contains "$cargo_conf" 'global-min-publish-age'
    assert_file_contains "$cargo_conf" '[registries.my-reg]'
    assert_file_contains "$cargo_conf" 'index = "sparse+https://example.com/index/"'
    assert_file_contains "$cargo_conf" 'min-publish-age = "1 days"'

    # An inline registry definition cannot also get a table; refuse instead.
    printf '[registries]\nmy-reg = { index = "sparse+https://example.com/index/" }\n' > "$cargo_conf"
    local before
    before=$(cat "$cargo_conf")
    parse_args 7 --exception cargo:my-reg
    reset_status_arrays
    setup_cargo >/dev/null
    assert_array_contains "cargo" "${FAILED_TOOLS[@]-}"
    assert_eq "$before" "$(cat "$cargo_conf")"
    cleanup_test_env
}

test_new_exception_targets_parse() {
    setup_test_env
    load_common_library
    parse_args --exception pixi:polars --exception 'pixi:numpy>=2' --exception hex:hexpm:myorg --exception cargo:my_reg-1
    assert_eq "polars numpy>=2" "${PIXI_EXCEPTIONS[*]}"
    assert_eq "hexpm:myorg" "${HEX_EXCEPTIONS[*]}"
    assert_eq "my_reg-1" "${CARGO_EXCEPTIONS[*]}"

    local spec output
    for spec in 'pixi:==1.0' 'pixi:"x"' 'hex:a,b' 'cargo:a.b' 'cargo:my reg'; do
        output=$( ( parse_args --exception "$spec" ) 2>&1 ) && fail "expected $spec to be rejected"
        assert_contains "$output" "Error:"
    done
    output=$( ( parse_args --remove --exception cargo:my-reg ) 2>&1 ) && fail "expected removal + exception to be rejected"
    assert_contains "$output" "cannot be combined with --exception"
    cleanup_test_env
}

test_blocked_tool_does_not_stop_other_tools() {
    setup_test_env
    install_fake_detection_tools "4.12.0" 1 "11.14.1"
    load_common_library
    printf 'registry=https://registry.example/\nmin-release-age=3\n' > "$HOME/.npmrc"
    local npmrc_before
    npmrc_before=$(cat "$HOME/.npmrc")

    local output status
    set +e
    output=$(main 7 --exception 'npm:@myorg/*' --exception pnpm:webpack 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    # The blocked tool keeps its config exactly as it was...
    assert_eq "$npmrc_before" "$(cat "$HOME/.npmrc")"
    assert_contains "$output" "$(expect_change_row x npm blocked)min-release-age-exclude requires >= 11.17.0 (installed: 11.14.1)"
    [[ "$output" != *"mismatch"* ]] || fail "a blocked tool must not be reported as a validation mismatch"
    # ...while every other tool is still configured and validated.
    assert_file_contains "$HOME/.config/pip/pip.conf" "uploaded-prior-to = P7D"
    assert_file_contains "$HOME/.config/uv/uv.toml" 'exclude-newer = "P7D"'
    assert_file_contains "$PNPM_RC_PATH" "minimum-release-age-exclude[]=webpack"
    assert_file_contains "$HOME/.bundle/config" 'BUNDLE_COOLDOWN: "7"'
    assert_contains "$(flatten_output "$output")" "1 blocked | 0 failed"
    assert_before "$output" "Changed files" "Needs attention"
    assert_contains "$(flatten_output "$output")" "Left unchanged. Upgrade it (or drop its --exception) and rerun."
    assert_contains "$output" "Exit status 1 because 1 tool is blocked."
    cleanup_test_env
}

# Several blocked tools are all listed and none of them is touched.
test_multiple_blocked_tools_are_listed() {
    setup_test_env
    install_fake_detection_tools "4.12.0" 1 "11.14.1" "10.15.0"
    load_common_library
    local output status
    set +e
    output=$(main 7 --exception 'npm:@myorg/*' 2>&1)
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "$(expect_change_row x npm blocked)"
    assert_contains "$output" "$(expect_change_row x pnpm blocked)"
    assert_contains "$(flatten_output "$output")" "minimum-release-age requires >= 10.16.0 (installed: 10.15.0)"
    assert_contains "$output" "Exit status 1 because 2 tools are blocked."
    assert_not_exists "$HOME/.npmrc"
    assert_not_exists "$PNPM_RC_PATH"
    assert_file_contains "$HOME/.config/pip/pip.conf" "uploaded-prior-to = P7D"
    cleanup_test_env
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
        --exception poetry:internal-lib \
        --exception poetry-source:private-repo \
        --exception 'npm:@myorg/*' \
        --exception pnpm:webpack \
        --exception bun:typescript \
        --exception 'yarn-berry:@myorg/*'
    assert_eq "14" "$MIN_AGE_DAYS"
    assert_eq "1" "${#UV_EXCEPTIONS[@]}"
    assert_eq "1" "${#POETRY_EXCEPTIONS[@]}"
    assert_eq "1" "${#POETRY_SOURCE_EXCEPTIONS[@]}"
    assert_eq "1" "${#NPM_EXCEPTIONS[@]}"
    assert_eq "1" "${#PNPM_EXCEPTIONS[@]}"
    assert_eq "1" "${#BUN_EXCEPTIONS[@]}"
    assert_eq "1" "${#YARN_EXCEPTIONS[@]}"
    assert_eq "setuptools=false" "${UV_EXCEPTIONS[0]}"
    assert_eq "internal-lib" "${POETRY_EXCEPTIONS[0]}"
    assert_eq "private-repo" "${POETRY_SOURCE_EXCEPTIONS[0]}"
    assert_eq "@myorg/*" "${NPM_EXCEPTIONS[0]}"

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
    output=$( ( parse_args --exception uv:badvalue ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "uv exceptions must use package=false"

    set +e
    output=$( ( parse_args --exception poetry: ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "--exception must use the format"

    set +e
    output=$( ( parse_args --exception npm: ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "--exception must use the format"

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
    output=$( ( parse_args --exception deno:npm:chalk ) 2>&1 )
    status=$?
    set -e
    assert_eq 1 "$status"
    assert_contains "$output" "deno does not support native exceptions"

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
    assert_file_contains "$pip_conf" "uploaded-prior-to = P7D"

    reset_status_arrays
    setup_pip
    assert_array_contains "pip" "${SKIPPED_TOOLS[@]-}"

    printf '[global]\nmin-age = 2d\n' > "$pip_conf"
    reset_status_arrays
    setup_pip
    assert_file_contains "$pip_conf" "uploaded-prior-to = P7D"
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
    assert_file_contains "$uv_conf" 'exclude-newer = "P7D"'
    assert_file_contains "$uv_conf" 'exclude-newer-package = { "setuptools" = false, "@scope/pkg" = "30 days" }'

    reset_status_arrays
    setup_uv
    assert_array_contains "uv" "${SKIPPED_TOOLS[@]-}"

    install_legacy_uv_cron_entry
    assert_file_contains "$TEST_CRONTAB_FILE" "$CRON_MARKER"

    reset_status_arrays
    remove_uv
    assert_not_exists "$uv_conf"

    reset_status_arrays
    remove_cron_uv
    assert_array_contains "cron-uv" "${UPDATED_TOOLS[@]-}"
    assert_file_not_contains "$TEST_CRONTAB_FILE" "$CRON_MARKER"

    reset_status_arrays
    remove_cron_uv
    assert_array_contains "cron-uv" "${SKIPPED_TOOLS[@]-}"

    printf '0 1 * * * /usr/bin/true # unrelated user job\n' | crontab -
    install_legacy_uv_cron_entry
    export TEST_CRONTAB_FAIL_WRITE=1
    reset_status_arrays
    set +e
    remove_cron_uv
    local status=$?
    set -e
    assert_eq 0 "$status"
    assert_array_contains "cron-uv" "${FAILED_TOOLS[@]-}"

    unset TEST_CRONTAB_FAIL_WRITE
    reset_status_arrays
    remove_cron_uv
    assert_array_contains "cron-uv" "${UPDATED_TOOLS[@]-}"
    assert_file_contains "$TEST_CRONTAB_FILE" "unrelated user job"
    assert_file_not_contains "$TEST_CRONTAB_FILE" "$CRON_MARKER"
    cleanup_test_env
}

test_setup_remove_poetry() {
    setup_test_env
    load_common_library
    parse_args 11 --exception poetry:internal-lib --exception poetry:other-lib --exception poetry-source:private-repo

    setup_poetry
    assert_file_contains "$POETRY_CONFIG_PATH" "[solver]"
    assert_file_contains "$POETRY_CONFIG_PATH" "min-release-age = 11"
    assert_file_contains "$POETRY_CONFIG_PATH" 'min-release-age-exclude = ["internal-lib", "other-lib"]'
    assert_file_contains "$POETRY_CONFIG_PATH" 'min-release-age-exclude-source = ["private-repo"]'

    reset_status_arrays
    setup_poetry
    assert_array_contains "poetry" "${SKIPPED_TOOLS[@]-}"

    reset_status_arrays
    remove_poetry
    assert_not_exists "$POETRY_CONFIG_PATH"

    # Older releases wrote comma strings, which Poetry ignores; they are migrated.
    printf '[solver]\nmin-release-age = 11\nmin-release-age-exclude = "internal-lib,other-lib"\nmin-release-age-exclude-source = "private-repo"\n' > "$POETRY_CONFIG_PATH"
    reset_status_arrays
    setup_poetry
    assert_array_contains "poetry" "${UPDATED_TOOLS[@]-}"
    assert_file_contains "$POETRY_CONFIG_PATH" 'min-release-age-exclude = ["internal-lib", "other-lib"]'
    assert_file_not_contains "$POETRY_CONFIG_PATH" '"internal-lib,other-lib"'
    cleanup_test_env
}

test_setup_remove_npm() {
    setup_test_env
    load_common_library
    parse_args 9 --exception 'npm:@myorg/*' --exception npm:internal-lib

    local npmrc="$HOME/.npmrc"
    setup_npm
    assert_file_contains "$npmrc" "min-release-age=9"
    assert_file_contains "$npmrc" "min-release-age-exclude[]=@myorg/*"
    assert_file_contains "$npmrc" "min-release-age-exclude[]=internal-lib"

    printf 'min-release-age=2\n' > "$npmrc"
    reset_status_arrays
    setup_npm
    assert_file_contains "$npmrc" "min-release-age=9"
    assert_file_contains "$npmrc" "min-release-age-exclude[]=@myorg/*"

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

test_setup_remove_bundler() {
    setup_test_env
    install_fake_detection_tools "4.12.0"
    load_common_library
    parse_args 8

    setup_bundler
    assert_file_contains "$BUNDLER_CONFIG_PATH" "---"
    assert_file_contains "$BUNDLER_CONFIG_PATH" 'BUNDLE_COOLDOWN: "8"'

    reset_status_arrays
    setup_bundler
    assert_array_contains "bundler" "${SKIPPED_TOOLS[@]-}"

    reset_status_arrays
    remove_bundler
    assert_not_exists "$BUNDLER_CONFIG_PATH"
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

test_setup_remove_deno() {
    setup_test_env
    load_common_library
    parse_args 9

    local wrapper="$HOME/.config/set-package-min-age/deno.sh"
    local zshrc="$HOME/.zshrc"
    local bashrc="$HOME/.bashrc"

    setup_deno
    assert_file_contains "$wrapper" "$DENO_WRAPPER_MARKER"
    assert_file_contains "$wrapper" "# minimum-release-age: 9d"
    assert_file_contains "$wrapper" "--minimum-dependency-age=P9D"
    assert_file_contains "$zshrc" "$DENO_WRAPPER_MARKER"
    assert_file_contains "$zshrc" "set-package-min-age/deno.sh"
    assert_file_contains "$bashrc" "$DENO_WRAPPER_MARKER"

    reset_status_arrays
    setup_deno
    assert_array_contains "deno" "${SKIPPED_TOOLS[@]-}"

    parse_args 14
    reset_status_arrays
    setup_deno
    assert_file_contains "$wrapper" "# minimum-release-age: 14d"
    assert_file_contains "$wrapper" "--minimum-dependency-age=P14D"
    assert_array_contains "deno" "${UPDATED_TOOLS[@]-}"
    local zshrc_marker_count
    zshrc_marker_count=$(grep -Fxc "$DENO_WRAPPER_MARKER" "$zshrc")
    assert_eq "1" "$zshrc_marker_count"

    reset_status_arrays
    remove_deno
    assert_not_exists "$wrapper"
    assert_file_not_contains "$zshrc" "$DENO_WRAPPER_MARKER"
    assert_file_not_contains "$bashrc" "$DENO_WRAPPER_MARKER"
    assert_array_contains "deno" "${UPDATED_TOOLS[@]-}"

    reset_status_arrays
    remove_deno
    assert_array_contains "deno" "${SKIPPED_TOOLS[@]-}"
    cleanup_test_env
}

test_setup_remove_pixi() {
    setup_test_env
    install_fake_detection_tools "4.12.0"
    load_common_library
    parse_args 5

    local zshrc="$HOME/.zshrc"
    printf 'export KEEP=1\n' > "$zshrc"
    install_legacy_pixi_wrapper
    write_pixi_global_manifest

    setup_pixi
    assert_array_contains "pixi" "${UPDATED_TOOLS[@]-}"
    assert_not_exists "$HOME/.config/set-package-min-age/pixi.sh"
    assert_file_not_contains "$zshrc" "$PIXI_WRAPPER_MARKER"
    assert_file_contains "$zshrc" "export KEEP=1"
    assert_file_contains "$PIXI_GLOBAL_MANIFEST_PATH" 'exclude-newer = "5d"'
    assert_file_contains "$PIXI_GLOBAL_MANIFEST_PATH" '[envs.ripgrep]'
    # The root key must come before the first table or TOML would scope it.
    assert_before "$(cat "$PIXI_GLOBAL_MANIFEST_PATH")" 'exclude-newer = "5d"' '[envs.ripgrep]'

    reset_status_arrays
    setup_pixi
    assert_array_contains "pixi" "${SKIPPED_TOOLS[@]-}"

    parse_args 9
    reset_status_arrays
    setup_pixi
    assert_array_contains "pixi" "${UPDATED_TOOLS[@]-}"
    assert_file_contains "$PIXI_GLOBAL_MANIFEST_PATH" 'exclude-newer = "9d"'
    assert_eq "1" "$(grep -c '^exclude-newer' "$PIXI_GLOBAL_MANIFEST_PATH")"

    reset_status_arrays
    remove_pixi
    assert_array_contains "pixi" "${UPDATED_TOOLS[@]-}"
    assert_file_not_contains "$PIXI_GLOBAL_MANIFEST_PATH" 'exclude-newer'
    assert_file_contains "$PIXI_GLOBAL_MANIFEST_PATH" 'version = 1'
    assert_file_contains "$PIXI_GLOBAL_MANIFEST_PATH" '[envs.ripgrep]'

    reset_status_arrays
    remove_pixi
    assert_array_contains "pixi" "${SKIPPED_TOOLS[@]-}"
    cleanup_test_env
}

test_setup_pixi_never_creates_manifest_or_overwrites_custom_table() {
    setup_test_env
    install_fake_detection_tools "4.12.0"
    load_common_library
    parse_args 5

    setup_pixi
    assert_array_contains "pixi" "${SKIPPED_TOOLS[@]-}"
    assert_not_exists "$PIXI_GLOBAL_MANIFEST_PATH"

    mkdir -p "$(dirname "$PIXI_GLOBAL_MANIFEST_PATH")"
    printf 'version = 1\nexclude-newer = { cutoff = "3d", exemptions = { polars = "*" } }\n' > "$PIXI_GLOBAL_MANIFEST_PATH"
    reset_status_arrays
    setup_pixi
    assert_array_contains "pixi" "${SKIPPED_TOOLS[@]-}"
    assert_file_contains "$PIXI_GLOBAL_MANIFEST_PATH" 'cutoff = "3d"'

    reset_status_arrays
    remove_pixi
    assert_file_contains "$PIXI_GLOBAL_MANIFEST_PATH" 'cutoff = "3d"'
    cleanup_test_env
}

test_setup_deno_preserves_unrelated_rc_content() {
    setup_test_env
    load_common_library
    parse_args 7

    local zshrc="$HOME/.zshrc"
    local bashrc="$HOME/.bashrc"
    printf 'export PATH="$HOME/bin:$PATH"\nalias ll="ls -al"\n' > "$zshrc"
    printf 'export EDITOR=vim\n' > "$bashrc"

    setup_deno
    assert_file_contains "$zshrc" 'export PATH="$HOME/bin:$PATH"'
    assert_file_contains "$zshrc" 'alias ll="ls -al"'
    assert_file_contains "$zshrc" "$DENO_WRAPPER_MARKER"
    assert_file_contains "$bashrc" 'export EDITOR=vim'

    reset_status_arrays
    remove_deno
    assert_file_contains "$zshrc" 'export PATH="$HOME/bin:$PATH"'
    assert_file_contains "$zshrc" 'alias ll="ls -al"'
    assert_file_not_contains "$zshrc" "$DENO_WRAPPER_MARKER"
    assert_file_contains "$bashrc" 'export EDITOR=vim'
    cleanup_test_env
}

test_preflight_deno_version_failure() {
    setup_test_env
    install_fake_detection_tools "4.12.0" 0 "12.0.1" "10.19.0" "1.3.2" "0.11.24" "26.1" 1 "" 1 "2.5.4"
    load_common_library

    local output status
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    assert_contains "$output" "minimumDependencyAge requires >= 2.6.0"
    assert_not_exists "$HOME/.config/set-package-min-age/deno.sh"
    cleanup_test_env
}

test_preflight_pixi_old_version_skips_global_manifest() {
    setup_test_env
    install_fake_crontab
    install_fake_detection_tools "4.12.0" 0 "12.0.1" "10.19.0" "1.3.2" "0.11.24" "26.1" 1 "0.0.0" 1 "2.9.0" 1 "2.4.0" 1 "4.0.15" "0.81.0"
    load_common_library
    write_pixi_global_manifest

    local output status
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e

    assert_eq 0 "$status"
    assert_contains "$output" "pixi global exclude-newer requires >= 0.82.0; will be skipped"
    assert_file_not_contains "$PIXI_GLOBAL_MANIFEST_PATH" 'exclude-newer'
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
    install_fake_detection_tools "4.12.0"
    load_common_library
    parse_args 7 \
        --exception uv:setuptools=false \
        --exception poetry:internal-lib \
        --exception poetry-source:private-repo \
        --exception 'npm:@myorg/*' \
        --exception pnpm:webpack \
        --exception bun:typescript \
        --exception 'yarn-berry:@myorg/*'
    install_fake_crontab
    write_pixi_global_manifest

    setup_pip
    setup_uv
    setup_poetry
    setup_npm
    setup_pnpm
    setup_bun
    setup_yarn_classic
    setup_yarn_berry
    setup_deno
    setup_pixi
    setup_vlt
    setup_bundler
    setup_hex

    validate_configs
    assert_array_contains "pip" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "uv" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "poetry" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "npm" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "pnpm" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "bun" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "yarn-classic" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "yarn-berry" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "deno" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "pixi" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "vlt" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "bundler" "${VALIDATED_TOOLS[@]-}"
    assert_array_contains "hex" "${VALIDATED_TOOLS[@]-}"

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

    local output
    output=$(print_tool_overview)

    assert_contains "$output" "Tools"
    assert_contains "$output" "$(expect_tool_row '*' pip 26.1) $TEST_BIN_DIR/pip3"
    assert_contains "$output" "$(expect_tool_row '*' Poetry 2.4.0)"
    assert_contains "$output" "$(expect_tool_row '*' npm 12.0.1)"
    assert_contains "$output" "$(expect_tool_row '*' deno 2.8.0)"
    assert_contains "$output" "$(expect_tool_row '*' vlt 0.0.0)"
    assert_contains "$output" "$(expect_tool_row '*' Bundler 4.0.15)"
    assert_contains "$output" "$(expect_tool_row '*' 'yarn v1' 1.22.22) $TEST_BIN_DIR/yarn"
    assert_contains "$(flatten_output "$output")" "Not installed: PDM, bun, Cargo, mise, yarn v2+."
    cleanup_test_env
}

test_print_tool_overview_yarn_berry() {
    setup_test_env
    load_common_library
    install_fake_detection_tools "4.12.0"

    local output
    output=$(print_tool_overview)

    assert_contains "$output" "$(expect_tool_row '*' 'yarn v2+' 4.12.0) $TEST_BIN_DIR/yarn"
    assert_contains "$(flatten_output "$output")" "yarn v1"
    [[ "$output" != *"$(expect_tool_row '*' 'yarn v1' 4.12.0)"* ]] || fail "yarn v1 should not be listed as installed"
    cleanup_test_env
}

test_tool_detection_times_out_hanging_version_probe() {
    setup_test_env
    install_fake_detection_tools "4.12.0"
    cat > "$TEST_BIN_DIR/yarn" <<'EOF'
#!/usr/bin/env bash
while :; do
    :
done
EOF
    chmod +x "$TEST_BIN_DIR/yarn"
    TOOL_VERSION_TIMEOUT_SECONDS=1
    load_common_library

    local output started elapsed
    started=$SECONDS
    output=$(detect_supported_tool_installations)
    elapsed=$((SECONDS - started))

    assert_contains "$output" "yarn v1|no|$TEST_BIN_DIR/yarn|unknown"
    assert_contains "$output" "yarn v2+|no|$TEST_BIN_DIR/yarn|unknown"
    if [[ "$elapsed" -gt 3 ]]; then
        fail "hanging version probe took ${elapsed}s"
    fi
    cleanup_test_env
}

test_preflight_npm_version_failure() {
    setup_test_env
    install_fake_detection_tools "4.12.0" 0 "11.9.0"
    load_common_library

    local output status
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    assert_contains "$output" "$(expect_tool_row x npm 11.9.0)"
    assert_contains "$(flatten_output "$output")" "min-release-age requires >= 11.10.0"
    assert_not_exists "$HOME/.npmrc"
    cleanup_test_env
}

test_preflight_npm_exception_version_failure() {
    setup_test_env
    install_fake_detection_tools "4.12.0" 0 "11.16.0"
    load_common_library

    local output status
    set +e
    output=$(main 4 --exception npm:internal-package 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    assert_contains "$output" "min-release-age-exclude requires >= 11.17.0"
    assert_not_exists "$HOME/.npmrc"
    cleanup_test_env
}

test_setup_remove_hex() {
    setup_test_env
    load_common_library
    parse_args 7

    setup_hex
    assert_file_contains "$HEX_CONFIG_PATH" '{cooldown,<<"7d">>}.'

    reset_status_arrays
    setup_hex
    assert_array_contains "hex" "${SKIPPED_TOOLS[@]-}"

    reset_status_arrays
    remove_hex
    assert_not_exists "$HEX_CONFIG_PATH"
    cleanup_test_env
}

test_preflight_hex_version_failure() {
    setup_test_env
    install_fake_detection_tools "4.12.0" 0 "12.0.1" "10.19.0" "1.3.2" "0.11.24" "26.1" 1 "0.0.0" 1 "2.9.0" 1 "2.4.0" 1 "4.0.15" "0.67.0" 1 "2.4.1"
    load_common_library

    local output status
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    assert_contains "$output" "cooldown requires >= 2.5.0"
    assert_not_exists "$HEX_CONFIG_PATH"
    cleanup_test_env
}

test_preflight_pip_version_failure() {
    setup_test_env
    install_fake_detection_tools "4.12.0" 0 "12.0.1" "10.19.0" "1.3.2" "0.11.24" "26.0"
    load_common_library

    local output status
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    assert_contains "$output" "uploaded-prior-to duration requires >= 26.1.0"
    assert_not_exists "$HOME/.config/pip/pip.conf"
    cleanup_test_env
}

test_preflight_uv_version_failure() {
    setup_test_env
    install_fake_detection_tools "4.12.0" 0 "12.0.1" "10.19.0" "1.3.2" "0.9.16" "26.1"
    load_common_library

    local output status
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    assert_contains "$output" "relative exclude-newer requires >= 0.9.17"
    assert_not_exists "$HOME/.config/uv/uv.toml"
    cleanup_test_env
}

test_preflight_poetry_version_failure() {
    setup_test_env
    install_fake_detection_tools "4.12.0" 0 "12.0.1" "10.19.0" "1.3.2" "0.11.24" "26.1" 1 "0.0.0" 1 "2.8.0" 1 "2.3.9"
    load_common_library

    local output status
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    assert_contains "$output" "solver.min-release-age requires >= 2.4.0"
    assert_not_exists "$POETRY_CONFIG_PATH"
    cleanup_test_env
}

test_preflight_pnpm_base_version_failure() {
    setup_test_env
    install_fake_detection_tools "4.12.0" 0 "12.0.1" "10.15.0"
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
    install_fake_detection_tools "4.12.0" 0 "12.0.1" "10.16.5"
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
    install_fake_detection_tools "4.12.0" 0 "12.0.1" "10.18.0"
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

test_preflight_bun_version_failure() {
    setup_test_env
    install_fake_detection_tools "4.12.0" 1 "12.0.1" "10.19.0" "1.2.9"
    load_common_library

    local output status
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e

    assert_eq 1 "$status"
    assert_contains "$output" "minimumReleaseAge requires >= 1.3.0"
    assert_not_exists "$HOME/.bunfig.toml"
    cleanup_test_env
}

test_preflight_bundler_version_warning() {
    setup_test_env
    install_fake_detection_tools "4.12.0" 0 "12.0.1" "10.19.0" "1.3.2" "0.11.24" "26.1" 1 "0.0.0" 1 "2.8.0" 1 "2.4.0" 1 "4.0.12"
    install_fake_crontab
    load_common_library

    local output status
    set +e
    output=$(main 4 2>&1)
    status=$?
    set -e

    assert_eq 0 "$status"
    assert_contains "$output" "cooldown requires >= 4.0.13"
    assert_contains "$output" "warn"
    assert_file_contains "$BUNDLER_CONFIG_PATH" 'BUNDLE_COOLDOWN: "4"'
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
    install_fake_detection_tools "4.12.0"
    load_common_library

    local output flat
    output=$(main 4 \
        --exception uv:setuptools=false \
        --exception poetry:internal-lib \
        --exception poetry-source:private-repo \
        --exception 'npm:@myorg/*' \
        --exception pnpm:webpack \
        --exception bun:typescript \
        --exception 'yarn-berry:@myorg/*')
    flat=$(flatten_output "$output")

    assert_contains "$output" "set-minimum-package-release-age | Test | minimum age 4 days"
    assert_before "$output" "Tools" "Changes"
    assert_before "$output" "Changes" "Summary"
    assert_before "$output" "Summary" "Changed files"
    # Installed tools get one row each, with version and path.
    assert_contains "$output" "$(expect_tool_row '*' pip 26.1) $TEST_BIN_DIR/pip3"
    assert_contains "$output" "$(expect_tool_row '*' uv 0.11.24)"
    assert_contains "$output" "$(expect_tool_row '*' Poetry 2.4.0)"
    assert_contains "$output" "$(expect_tool_row '*' pnpm 10.19.0)"
    assert_contains "$output" "$(expect_tool_row '*' deno 2.8.0)"
    assert_contains "$output" "$(expect_tool_row '*' Bundler 4.0.15)"
    # Each tool appears once in Changes, with its value.
    assert_contains "$output" "$(expect_change_row '*' pip added)uploaded-prior-to = P4D (4d window)"
    assert_contains "$output" "$(expect_change_row '*' uv added)exclude-newer = \"P4D\"; exceptions=1"
    assert_contains "$output" "$(expect_change_row '*' Poetry added)min-release-age = 4; package-exceptions=1; source-exceptions=1"
    assert_contains "$output" "$(expect_change_row '*' npm added)min-release-age=4; exceptions=1"
    assert_contains "$output" "$(expect_change_row '*' deno added)--minimum-dependency-age=P4D"
    assert_contains "$output" "$(expect_change_row '*' vlt added)before = 2026-03-29T00:00:00Z (4d window)"
    assert_contains "$output" "$(expect_change_row '*' Bundler added)cooldown = 4d"
    assert_contains "$output" "$(expect_change_row '*' 'vlt cron' added)"
    # pip shows up once under Tools and once under Changes, never as extra rows.
    assert_eq 2 "$(grep -c '^  [*=x!-] pip ' <<< "$output")"
    # The no-op legacy uv cron cleanup and per-tool "ok" validation rows are not shown.
    [[ "$output" != *"uv cron"* ]] || fail "did not expect a uv cron row"
    [[ "$output" != *"mismatch"* ]] || fail "did not expect validation mismatches"
    [[ "$output" != *"Needs attention"* ]] || fail "did not expect a Needs attention section"
    assert_contains "$flat" "failed | 15/15 verified"
    assert_contains "$output" "  $(printf '%-12s' pip) ~/.config/pip/pip.conf"
    assert_contains "$output" "Done."
    cleanup_test_env
}

test_main_remove_output_includes_tool_overview() {
    setup_test_env
    install_fake_crontab
    install_fake_detection_tools "1.22.22"
    load_common_library

    local output
    output=$(main --remove)

    assert_contains "$output" "set-minimum-package-release-age | Test | remove all managed settings"
    assert_before "$output" "Tools" "Removing"
    assert_before "$output" "Removing" "Summary"
    assert_contains "$output" "No files changed."
    cleanup_test_env
}

test_main_scoped_remove_output_includes_tool_overview() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.12.0"

    local output
    output=$(main --remove-tool pip --remove-tool uv)

    assert_contains "$output" "remove: pip, uv"
    assert_contains "$output" "$(expect_change_row '*' pip removed)"
    assert_contains "$output" "$(expect_change_row '*' uv removed)"
    assert_contains "$(flatten_output "$output")" "2 removed | 0 failed"
    assert_not_exists "$HOME/.config/pip/pip.conf"
    assert_not_exists "$HOME/.config/uv/uv.toml"
    assert_exists "$TEST_CRONTAB_FILE"
    cleanup_test_env
}

test_scoped_remove_only_pip() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.12.0"

    main --remove-tool pip >/dev/null

    assert_not_exists "$HOME/.config/pip/pip.conf"
    assert_exists "$HOME/.config/uv/uv.toml"
    assert_exists "$HOME/.yarnrc.yml"
    cleanup_test_env
}

test_scoped_remove_only_uv() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.12.0"

    main --remove-tool uv >/dev/null

    assert_not_exists "$HOME/.config/uv/uv.toml"
    assert_exists "$TEST_CRONTAB_FILE"
    cleanup_test_env
}

test_scoped_remove_only_poetry() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.12.0"

    main --remove-tool poetry >/dev/null

    assert_not_exists "$POETRY_CONFIG_PATH"
    assert_exists "$HOME/.config/uv/uv.toml"
    assert_exists "$BUNDLER_CONFIG_PATH"
    cleanup_test_env
}

test_scoped_remove_only_uv_cron() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.12.0"

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
    install_fake_detection_tools "4.12.0"

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
    install_fake_detection_tools "4.12.0"

    main --remove-tool yarn-berry >/dev/null

    assert_not_exists "$HOME/.yarnrc.yml"
    assert_exists "$HOME/.yarnrc"
    cleanup_test_env
}

test_scoped_remove_only_deno() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.12.0"

    main --remove-tool deno >/dev/null

    assert_not_exists "$HOME/.config/set-package-min-age/deno.sh"
    assert_file_not_contains "$HOME/.zshrc" "$DENO_WRAPPER_MARKER"
    assert_file_contains "$PIXI_GLOBAL_MANIFEST_PATH" 'exclude-newer = "4d"'
    cleanup_test_env
}

test_scoped_remove_only_pixi() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.12.0"

    main --remove-tool pixi >/dev/null

    assert_file_not_contains "$PIXI_GLOBAL_MANIFEST_PATH" 'exclude-newer'
    assert_exists "$HOME/.config/set-package-min-age/deno.sh"
    assert_file_contains "$HOME/.zshrc" "$DENO_WRAPPER_MARKER"
    cleanup_test_env
}

test_scoped_remove_only_vlt() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.12.0"

    main --remove-tool vlt >/dev/null

    assert_not_exists "$VLT_CONFIG_PATH"
    assert_exists "$TEST_CRONTAB_FILE"
    cleanup_test_env
}

test_scoped_remove_only_vlt_cron() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.12.0"

    main --remove-tool vlt-cron >/dev/null

    assert_file_not_contains "$TEST_CRONTAB_FILE" "$VLT_CRON_MARKER"
    assert_file_contains "$TEST_CRONTAB_FILE" "$CRON_MARKER"
    assert_exists "$VLT_CONFIG_PATH"
    cleanup_test_env
}

test_scoped_remove_only_bundler() {
    setup_test_env
    prepare_scoped_remove_fixtures
    install_fake_detection_tools "4.12.0"

    main --remove-tool bundler >/dev/null

    assert_not_exists "$BUNDLER_CONFIG_PATH"
    assert_exists "$POETRY_CONFIG_PATH"
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
run_test "setup_remove_poetry" test_setup_remove_poetry || true
run_test "setup_remove_npm" test_setup_remove_npm || true
run_test "setup_remove_pnpm" test_setup_remove_pnpm || true
run_test "setup_remove_pnpm_legacy_rc" test_setup_remove_pnpm_legacy_rc || true
run_test "setup_remove_vlt" test_setup_remove_vlt || true
run_test "setup_remove_bundler" test_setup_remove_bundler || true
run_test "setup_remove_bun" test_setup_remove_bun || true
run_test "setup_remove_yarn_classic" test_setup_remove_yarn_classic || true
run_test "setup_remove_yarn_berry" test_setup_remove_yarn_berry || true
run_test "setup_remove_deno" test_setup_remove_deno || true
run_test "setup_remove_pixi" test_setup_remove_pixi || true
run_test "setup_pixi_never_creates_manifest_or_overwrites_custom_table" test_setup_pixi_never_creates_manifest_or_overwrites_custom_table || true
run_test "setup_deno_preserves_unrelated_rc_content" test_setup_deno_preserves_unrelated_rc_content || true
run_test "preflight_deno_version_failure" test_preflight_deno_version_failure || true
run_test "preflight_pixi_old_version_skips_global_manifest" test_preflight_pixi_old_version_skips_global_manifest || true
run_test "validate_configs" test_validate_configs || true
run_test "print_tool_overview_yarn_v1" test_print_tool_overview_yarn_v1 || true
run_test "print_tool_overview_yarn_berry" test_print_tool_overview_yarn_berry || true
run_test "tool_detection_times_out_hanging_version_probe" test_tool_detection_times_out_hanging_version_probe || true
run_test "preflight_npm_version_failure" test_preflight_npm_version_failure || true
run_test "preflight_npm_exception_version_failure" test_preflight_npm_exception_version_failure || true
run_test "setup_remove_hex" test_setup_remove_hex || true
run_test "preflight_hex_version_failure" test_preflight_hex_version_failure || true
run_test "preflight_pip_version_failure" test_preflight_pip_version_failure || true
run_test "preflight_uv_version_failure" test_preflight_uv_version_failure || true
run_test "preflight_poetry_version_failure" test_preflight_poetry_version_failure || true
run_test "preflight_pnpm_base_version_failure" test_preflight_pnpm_base_version_failure || true
run_test "preflight_pnpm_pattern_exception_version_failure" test_preflight_pnpm_pattern_exception_version_failure || true
run_test "preflight_pnpm_version_selector_failure" test_preflight_pnpm_version_selector_failure || true
run_test "preflight_bun_version_failure" test_preflight_bun_version_failure || true
run_test "preflight_bundler_version_warning" test_preflight_bundler_version_warning || true
run_test "preflight_yarn_berry_version_failure" test_preflight_yarn_berry_version_failure || true
run_test "main_output_includes_readiness_and_results" test_main_output_includes_readiness_and_results || true
run_test "main_remove_output_includes_tool_overview" test_main_remove_output_includes_tool_overview || true
run_test "main_scoped_remove_output_includes_tool_overview" test_main_scoped_remove_output_includes_tool_overview || true
run_test "scoped_remove_only_pip" test_scoped_remove_only_pip || true
run_test "scoped_remove_only_uv" test_scoped_remove_only_uv || true
run_test "scoped_remove_only_poetry" test_scoped_remove_only_poetry || true
run_test "scoped_remove_only_uv_cron" test_scoped_remove_only_uv_cron || true
run_test "scoped_remove_uv_and_uv_cron" test_scoped_remove_uv_and_uv_cron || true
run_test "scoped_remove_only_yarn_berry" test_scoped_remove_only_yarn_berry || true
run_test "scoped_remove_only_deno" test_scoped_remove_only_deno || true
run_test "scoped_remove_only_pixi" test_scoped_remove_only_pixi || true
run_test "scoped_remove_only_vlt" test_scoped_remove_only_vlt || true
run_test "scoped_remove_only_vlt_cron" test_scoped_remove_only_vlt_cron || true
run_test "scoped_remove_only_bundler" test_scoped_remove_only_bundler || true

run_test "setup_remove_pdm_cargo_mise" test_setup_remove_pdm_cargo_mise || true
run_test "cargo_uses_legacy_config_file_when_only_it_exists" test_cargo_uses_legacy_config_file_when_only_it_exists || true
run_test "preflight_new_tools" test_preflight_new_tools || true
run_test "vlt_cron_replaces_stale_entry" test_vlt_cron_replaces_stale_entry || true
run_test "missing_crontab_does_not_abort_run" test_missing_crontab_does_not_abort_run || true
run_test "vlt_launchd_refresh_job" test_vlt_launchd_refresh_job || true
run_test "update_detail_when_only_exceptions_change" test_update_detail_when_only_exceptions_change || true
run_test "pixi_global_exemptions" test_pixi_global_exemptions || true
run_test "hex_repo_exclusions" test_hex_repo_exclusions || true
run_test "cargo_registry_exemptions" test_cargo_registry_exemptions || true
run_test "new_exception_targets_parse" test_new_exception_targets_parse || true
run_test "blocked_tool_does_not_stop_other_tools" test_blocked_tool_does_not_stop_other_tools || true
run_test "multiple_blocked_tools_are_listed" test_multiple_blocked_tools_are_listed || true
finish_tests
