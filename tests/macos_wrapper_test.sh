#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

test_macos_wrapper() {
    setup_test_env
    install_fake_date
    install_fake_crontab
    install_fake_validation_tools "4.12.0" "12.0.1" "11.0.0"

    mkdir -p "$HOME/.pixi/manifests"
    printf 'version = 1\n' > "$HOME/.pixi/manifests/pixi-global.toml"

    local output
    output=$(bash "$PROJECT_ROOT/set_package_min_age_macos.sh" 6 --exception 'yarn-berry:@myorg/*')

    assert_contains "$output" "set-minimum-package-release-age | macOS | minimum age"
    assert_file_contains "$HOME/Library/Application Support/pypoetry/config.toml" "min-release-age = 6"
    assert_file_contains "$HOME/Library/Preferences/pnpm/config.yaml" "minimumReleaseAge: 8640"
    assert_file_contains "$HOME/.yarnrc.yml" "npmPreapprovedPackages: ['@myorg/*']"
    assert_file_contains "$HOME/.config/set-package-min-age/deno.sh" "--minimum-dependency-age=P6D"
    assert_file_contains "$HOME/.pixi/manifests/pixi-global.toml" 'exclude-newer = "6d"'
    assert_file_contains "$HOME/.zshrc" "set-package-min-age/deno.sh"
    assert_file_contains "$HOME/.bashrc" "set-package-min-age/deno.sh"
    assert_not_exists "$HOME/.config/set-package-min-age/pixi.sh"
    assert_file_contains "$HOME/Library/Preferences/vlt/vlt.json" '"before": "2026-03-29T00:00:00Z"'
    assert_file_contains "$HOME/Library/LaunchAgents/com.set-minimum-package-release-age.vlt-refresh.plist" "$PROJECT_ROOT/set_package_min_age_macos.sh"
    assert_file_not_contains "$TEST_CRONTAB_FILE" "set-minimum-package-release-age: vlt before"
    assert_contains "$output" "vlt launchd"
    assert_file_contains "$HOME/.bundle/config" 'BUNDLE_COOLDOWN: "6"'
    cleanup_test_env
}

test_macos_wrapper_honors_xdg_config_home() {
    setup_test_env
    install_fake_date
    install_fake_crontab
    install_fake_validation_tools "4.12.0" "12.0.1" "11.0.0"

    local xdg="$TEST_ROOT/xdg"
    export XDG_CONFIG_HOME="$xdg"

    bash "$PROJECT_ROOT/set_package_min_age_macos.sh" 6 >/dev/null

    assert_file_contains "$xdg/pnpm/config.yaml" "minimumReleaseAge: 8640"
    assert_file_contains "$xdg/vlt/vlt.json" '"before": "2026-03-29T00:00:00Z"'
    assert_file_contains "$xdg/uv/uv.toml" 'exclude-newer = "P6D"'
    assert_file_contains "$xdg/.bunfig.toml" "minimumReleaseAge = 518400"
    # pip and Poetry ignore XDG_CONFIG_HOME on macOS.
    assert_file_contains "$HOME/.config/pip/pip.conf" "uploaded-prior-to = P6D"
    assert_file_contains "$HOME/Library/Application Support/pypoetry/config.toml" "min-release-age = 6"
    assert_file_contains "$HOME/Library/Application Support/pdm/config.toml" 'exclude-newer = "6d"'
    assert_file_contains "$xdg/mise/config.toml" 'minimum_release_age = "6d"'
    assert_not_exists "$HOME/Library/Preferences/pnpm/config.yaml"
    assert_not_exists "$HOME/.bunfig.toml"
    cleanup_test_env
}

test_macos_wrapper_uses_application_support_pip_dir_when_present() {
    setup_test_env
    install_fake_date
    install_fake_crontab
    install_fake_validation_tools "4.12.0" "12.0.1" "11.0.0"
    mkdir -p "$HOME/Library/Application Support/pip"

    bash "$PROJECT_ROOT/set_package_min_age_macos.sh" 6 >/dev/null

    assert_file_contains "$HOME/Library/Application Support/pip/pip.conf" "uploaded-prior-to = P6D"
    assert_not_exists "$HOME/.config/pip/pip.conf"

    bash "$PROJECT_ROOT/set_package_min_age_macos.sh" --remove-tool pip >/dev/null
    assert_not_exists "$HOME/Library/Application Support/pip/pip.conf"
    cleanup_test_env
}

run_test "macos_wrapper" test_macos_wrapper || true
run_test "macos_wrapper_honors_xdg_config_home" test_macos_wrapper_honors_xdg_config_home || true
run_test "macos_wrapper_uses_application_support_pip_dir_when_present" test_macos_wrapper_uses_application_support_pip_dir_when_present || true
finish_tests
