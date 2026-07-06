#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

test_macos_wrapper() {
    setup_test_env
    install_fake_date
    install_fake_crontab
    install_fake_validation_tools "4.12.0" "11.10.0" "11.0.0"

    local output
    output=$(bash "$PROJECT_ROOT/set_package_min_age_macos.sh" 6 --exception 'yarn-berry:@myorg/*')

    assert_contains "$output" "set-minimum-package-release-age (macOS)"
    assert_file_contains "$HOME/Library/Application Support/pypoetry/config.toml" "min-release-age = 6"
    assert_file_contains "$HOME/Library/Preferences/pnpm/config.yaml" "minimumReleaseAge: 8640"
    assert_file_contains "$HOME/.yarnrc.yml" "npmPreapprovedPackages: ['@myorg/*']"
    assert_file_contains "$HOME/Library/Preferences/vlt/vlt.json" '"before": "2026-03-29T00:00:00Z"'
    assert_file_contains "$HOME/.bundle/config" 'BUNDLE_COOLDOWN: "6"'
    cleanup_test_env
}

run_test "macos_wrapper" test_macos_wrapper || true
finish_tests
