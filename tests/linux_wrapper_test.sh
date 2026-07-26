#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helper.sh"

test_linux_wrapper() {
    setup_test_env
    install_fake_date
    install_fake_crontab
    install_fake_validation_tools "1.22.22" "11.10.0" "11.0.0"

    local output
    output=$(bash "$PROJECT_ROOT/set_package_min_age_linux.sh" 3 --exception pnpm:webpack)

    assert_contains "$output" "set-minimum-package-release-age (Linux)"
    assert_file_contains "$HOME/.config/pypoetry/config.toml" "min-release-age = 3"
    assert_file_contains "$HOME/.config/pnpm/config.yaml" "minimumReleaseAge: 4320"
    assert_file_contains "$HOME/.config/pnpm/config.yaml" "minimumReleaseAgeExclude: ['webpack']"
    assert_file_contains "$HOME/.config/set-package-min-age/deno.sh" "--minimum-dependency-age=P3D"
    assert_file_contains "$HOME/.config/set-package-min-age/pixi.sh" '--exclude-newer "3d"'
    assert_file_contains "$HOME/.zshrc" "set-package-min-age/deno.sh"
    assert_file_contains "$HOME/.bashrc" "set-package-min-age/pixi.sh"
    assert_file_contains "$HOME/.config/vlt/vlt.json" '"before": "2026-03-29T00:00:00Z"'
    assert_file_contains "$HOME/.bundle/config" 'BUNDLE_COOLDOWN: "3"'
    cleanup_test_env
}

run_test "linux_wrapper" test_linux_wrapper || true
finish_tests
