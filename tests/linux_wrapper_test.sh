#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

test_linux_wrapper() {
    setup_test_env
    install_fake_date
    install_fake_crontab
    install_fake_validation_tools "1.22.22" "12.0.1" "11.0.0"

    mkdir -p "$HOME/.pixi/manifests"
    printf 'version = 1\n' > "$HOME/.pixi/manifests/pixi-global.toml"

    local output
    output=$(bash "$PROJECT_ROOT/set_package_min_age_linux.sh" 3 --exception pnpm:webpack)

    assert_contains "$output" "set-minimum-package-release-age | Linux | minimum age"
    assert_file_contains "$HOME/.config/pypoetry/config.toml" "min-release-age = 3"
    assert_file_contains "$HOME/.config/pnpm/config.yaml" "minimumReleaseAge: 4320"
    assert_file_contains "$HOME/.config/pnpm/config.yaml" "minimumReleaseAgeExclude: ['webpack']"
    assert_file_contains "$HOME/.config/set-package-min-age/deno.sh" "--minimum-dependency-age=P3D"
    assert_file_contains "$HOME/.pixi/manifests/pixi-global.toml" 'exclude-newer = "3d"'
    assert_file_contains "$HOME/.zshrc" "set-package-min-age/deno.sh"
    assert_file_contains "$HOME/.bashrc" "set-package-min-age/deno.sh"
    assert_not_exists "$HOME/.config/set-package-min-age/pixi.sh"
    assert_file_contains "$HOME/.config/vlt/vlt.json" '"before": "2026-03-29T00:00:00Z"'
    assert_file_contains "$HOME/.bundle/config" 'BUNDLE_COOLDOWN: "3"'
    cleanup_test_env
}

test_linux_wrapper_honors_config_location_overrides() {
    setup_test_env
    install_fake_date
    install_fake_crontab
    install_fake_validation_tools "1.22.22" "12.0.1" "11.0.0"

    local xdg="$TEST_ROOT/xdg"
    export XDG_CONFIG_HOME="$xdg"
    export ZDOTDIR="$TEST_ROOT/zdot"
    export POETRY_CONFIG_DIR="$TEST_ROOT/poetry"
    export NPM_CONFIG_USERCONFIG="$TEST_ROOT/custom.npmrc"
    export BUNDLE_USER_CONFIG="$TEST_ROOT/bundle-config"
    export CARGO_HOME="$TEST_ROOT/cargo"
    mkdir -p "$ZDOTDIR"

    bash "$PROJECT_ROOT/set_package_min_age_linux.sh" 3 >/dev/null

    assert_file_contains "$xdg/pip/pip.conf" "uploaded-prior-to = P3D"
    assert_file_contains "$xdg/uv/uv.toml" 'exclude-newer = "P3D"'
    assert_file_contains "$xdg/pnpm/config.yaml" "minimumReleaseAge: 4320"
    assert_file_contains "$xdg/.bunfig.toml" "minimumReleaseAge = 259200"
    assert_file_contains "$xdg/vlt/vlt.json" '"before": "2026-03-29T00:00:00Z"'
    assert_file_contains "$POETRY_CONFIG_DIR/config.toml" "min-release-age = 3"
    assert_file_contains "$NPM_CONFIG_USERCONFIG" "min-release-age=3"
    assert_file_contains "$BUNDLE_USER_CONFIG" 'BUNDLE_COOLDOWN: "3"'
    assert_file_contains "$ZDOTDIR/.zshrc" "set-package-min-age/deno.sh"
    assert_file_contains "$xdg/pdm/config.toml" 'exclude-newer = "3d"'
    assert_file_contains "$xdg/mise/config.toml" 'minimum_release_age = "3d"'
    assert_file_contains "$CARGO_HOME/config.toml" 'global-min-publish-age = "3 days"'
    assert_not_exists "$HOME/.zshrc"
    assert_not_exists "$HOME/.bunfig.toml"
    assert_not_exists "$HOME/.npmrc"
    assert_not_exists "$HOME/.config/uv/uv.toml"
    cleanup_test_env
}

run_test "linux_wrapper" test_linux_wrapper || true
run_test "linux_wrapper_honors_config_location_overrides" test_linux_wrapper_honors_config_location_overrides || true
finish_tests
