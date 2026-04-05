#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

test_macos_wrapper() {
    setup_test_env
    install_fake_date
    install_fake_crontab
    install_fake_validation_tools "4.10.0"

    local output
    output=$(bash "$PROJECT_ROOT/set_package_min_age_macos.sh" 6 --exception 'yarn-berry:@myorg/*')

    assert_contains "$output" "set-minimum-package-release-age (macOS)"
    assert_file_contains "$HOME/Library/Preferences/pnpm/rc" "minimum-release-age=8640"
    assert_file_contains "$HOME/.yarnrc.yml" "npmPreapprovedPackages: ['@myorg/*']"
    cleanup_test_env
}

run_test "macos_wrapper" test_macos_wrapper || true
finish_tests
