#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

test_linux_wrapper() {
    setup_test_env
    install_fake_date
    install_fake_crontab
    install_fake_validation_tools "1.22.22"

    local output
    output=$(bash "$PROJECT_ROOT/set_package_min_age_linux.sh" 3 --exception pnpm:webpack)

    assert_contains "$output" "set-minimum-package-release-age (Linux)"
    assert_file_contains "$HOME/.config/pnpm/rc" "minimum-release-age=4320"
    assert_file_contains "$HOME/.config/pnpm/rc" "minimum-release-age-exclude[]=webpack"
    assert_file_contains "$HOME/.config/set-package-min-age/deno.sh" "--minimum-dependency-age=P3D"
    assert_file_contains "$HOME/.config/set-package-min-age/pixi.sh" '--exclude-newer "3d"'
    assert_file_contains "$HOME/.zshrc" "set-package-min-age/deno.sh"
    assert_file_contains "$HOME/.bashrc" "set-package-min-age/pixi.sh"
    cleanup_test_env
}

run_test "linux_wrapper" test_linux_wrapper || true
finish_tests
