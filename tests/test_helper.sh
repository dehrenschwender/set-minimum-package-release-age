#!/usr/bin/env bash

set -euo pipefail

TESTS_RUN=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_LIB="$PROJECT_ROOT/lib/set_package_min_age_common.sh"

# Tests are independent (each uses its own temp HOME), so they run in parallel.
# Output is buffered per test and printed in declaration order by finish_tests.
# Set TEST_JOBS=1 to run serially.
TEST_JOBS="${TEST_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
TEST_RESULTS_DIR=""
TEST_NAMES=()
TEST_PIDS=()
TEST_NEXT_TO_WAIT=0

run_test() {
    local name="$1"
    shift
    local idx="${#TEST_NAMES[@]}"

    if [[ -z "$TEST_RESULTS_DIR" ]]; then
        TEST_RESULTS_DIR="$(mktemp -d)"
    fi

    # Keep at most TEST_JOBS tests running; bash 3.2 has no `wait -n`, so wait
    # for the oldest one.
    while (( ${#TEST_PIDS[@]} - TEST_NEXT_TO_WAIT >= TEST_JOBS )); do
        wait "${TEST_PIDS[$TEST_NEXT_TO_WAIT]}" 2>/dev/null || true
        TEST_NEXT_TO_WAIT=$((TEST_NEXT_TO_WAIT + 1))
    done

    TEST_NAMES+=("$name")
    (
        status=0
        ( "$@" ) >"$TEST_RESULTS_DIR/$idx.out" 2>&1 || status=$?
        printf '%s\n' "$status" >"$TEST_RESULTS_DIR/$idx.status"
    ) &
    TEST_PIDS+=("$!")
    return 0
}

finish_tests() {
    local idx status

    wait 2>/dev/null || true
    for idx in "${!TEST_NAMES[@]}"; do
        TESTS_RUN=$((TESTS_RUN + 1))
        cat "$TEST_RESULTS_DIR/$idx.out" 2>/dev/null || true
        status=$(cat "$TEST_RESULTS_DIR/$idx.status" 2>/dev/null || echo 1)
        if [[ "$status" == "0" ]]; then
            printf 'PASS %s\n' "${TEST_NAMES[$idx]}"
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
            printf 'FAIL %s\n' "${TEST_NAMES[$idx]}" >&2
        fi
    done
    if [[ -n "$TEST_RESULTS_DIR" ]]; then
        rm -rf "$TEST_RESULTS_DIR"
    fi

    if [[ $TESTS_FAILED -gt 0 ]]; then
        printf '\n%s of %s tests failed\n' "$TESTS_FAILED" "$TESTS_RUN" >&2
        return 1
    fi
    printf '\n%s tests passed\n' "$TESTS_RUN"
}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    [[ "$expected" == "$actual" ]] || fail "expected [$expected] but got [$actual]"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain [$needle], got: $haystack"
}

assert_before() {
    local haystack="$1"
    local first="$2"
    local second="$3"

    [[ "$haystack" == *"$first"* ]] || fail "expected output to contain [$first]"
    [[ "$haystack" == *"$second"* ]] || fail "expected output to contain [$second]"
    [[ "${haystack#*"$first"}" == *"$second"* ]] || fail "expected [$first] to appear before [$second]"
}

# Expected text of a Tools row ("  * pip         26.1       ") for assertions.
expect_tool_row() {
    printf '  %s %-12s %-10s' "$1" "$2" "$3"
}

# Expected start of a Changes row ("  * pip         added     ").
expect_change_row() {
    printf '  %s %-12s %-9s ' "$1" "$2" "$3"
}

# Output with line breaks and repeated spaces collapsed, so assertions on
# wrapped text do not depend on the terminal width.
flatten_output() {
    printf '%s' "$1" | tr '\n' ' ' | tr -s ' '
}

assert_file_contains() {
    local file="$1"
    local needle="$2"
    grep -Fq -- "$needle" "$file" || fail "expected [$file] to contain [$needle]"
}

assert_file_not_contains() {
    local file="$1"
    local needle="$2"
    if [[ ! -f "$file" ]]; then
        return 0
    fi
    ! grep -Fq -- "$needle" "$file" || fail "expected [$file] to not contain [$needle]"
}

assert_exists() {
    [[ -e "$1" ]] || fail "expected [$1] to exist"
}

assert_not_exists() {
    [[ ! -e "$1" ]] || fail "expected [$1] to not exist"
}

assert_array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    fail "expected array to contain [$needle]"
}

setup_test_env() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT
    export HOME="$TEST_ROOT/home"
    # Keep the developer's own config-location overrides out of the tests.
    # Deterministic output: ASCII symbols, default width, no color.
    export SET_PACKAGE_MIN_AGE_GLYPHS=ascii
    unset COLUMNS NO_COLOR FORCE_COLOR
    unset XDG_CONFIG_HOME ZDOTDIR POETRY_CONFIG_DIR NPM_CONFIG_USERCONFIG npm_config_userconfig \
        BUNDLE_USER_CONFIG BUNDLE_USER_HOME HEX_HOME MIX_XDG \
        XDG_DATA_HOME PDM_CONFIG_FILE MISE_GLOBAL_CONFIG_FILE MISE_CONFIG_DIR CARGO_HOME PIXI_HOME
    export TEST_BIN_DIR="$TEST_ROOT/bin"
    export TEST_CRONTAB_FILE="$TEST_ROOT/crontab"
    export PATH="$TEST_BIN_DIR:/usr/bin:/bin"
    mkdir -p "$HOME/.config" "$TEST_BIN_DIR"
    # Always shadow the schedulers: PATH still includes /usr/bin, so a test that
    # unexpectedly reaches the cron/launchd step must never touch the real ones.
    install_fake_crontab
    install_fake_launchctl
}

cleanup_test_env() {
    rm -rf "$TEST_ROOT"
}

load_common_library() {
    PLATFORM_NAME="${1:-Test}"
    PNPM_RC_PATH="${2:-$HOME/.config/pnpm/rc}"
    PNPM_CONFIG_PATH="${3:-$HOME/.config/pnpm/config.yaml}"
    VLT_CONFIG_PATH="${4:-$HOME/.config/vlt/vlt.json}"
    POETRY_CONFIG_PATH="${5:-$HOME/.config/pypoetry/config.toml}"
    BUNDLER_CONFIG_PATH="${6:-$HOME/.bundle/config}"

    platform_date_days_ago_rfc3339() {
        printf '%s\n' "${TEST_FIXED_RFC3339:-2026-03-29T00:00:00Z}"
    }

    platform_vlt_refresh_script_path() {
        printf '%s\n' "/opt/test & co/set_package_min_age_test.sh"
    }

    platform_build_vlt_cron_command() {
        local min_age="$1"
        local vlt_conf="$2"
        printf '0 0 * * * echo %s >> %s %s\n' "$min_age" "$vlt_conf" "$VLT_CRON_MARKER"
    }

    # shellcheck disable=SC1090
    source "$COMMON_LIB"
}

# Older releases installed a daily uv cron job; current runs only clean it up.
install_legacy_uv_cron_entry() {
    ( crontab -l 2>/dev/null || true; printf '0 0 * * * echo legacy-uv-refresh %s\n' "$CRON_MARKER" ) | crontab -
}

# Older releases installed a pixi wrapper that broke pixi; current runs remove it.
install_legacy_pixi_wrapper() {
    local rc
    mkdir -p "$HOME/.config/set-package-min-age"
    printf '%s\n# minimum-release-age: 7d\npixi() { command pixi "$@"; }\n' "$PIXI_WRAPPER_MARKER" \
        > "$HOME/.config/set-package-min-age/pixi.sh"
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        printf '%s\n%s\n' "$PIXI_WRAPPER_MARKER" "$(pixi_source_line)" >> "$rc"
    done
}

write_pixi_global_manifest() {
    mkdir -p "$(dirname "$PIXI_GLOBAL_MANIFEST_PATH")"
    printf 'version = 1\n\n[envs.ripgrep]\nchannels = ["conda-forge"]\ndependencies = { ripgrep = "*" }\n' \
        > "$PIXI_GLOBAL_MANIFEST_PATH"
}

# Installs a fake binary that prints VERSION_OUTPUT for --version.
install_fake_version_binary() {
    local name="$1"
    local version_output="$2"
    cat > "$TEST_BIN_DIR/$name" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
    printf '%s\n' "$version_output"
    exit 0
fi
printf 'ARGS: %s\n' "\$*"
EOF
    chmod +x "$TEST_BIN_DIR/$name"
}

install_fake_launchctl() {
    cat > "$TEST_BIN_DIR/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${TEST_ROOT:?}/launchd"
mkdir -p "$state"
printf '%s\n' "$*" >> "$TEST_ROOT/launchctl.log"
case "${1:-}" in
    print)
        [[ -f "$state/${2##*/}" ]]
        ;;
    bootstrap)
        if [[ "${TEST_LAUNCHCTL_FAIL_BOOTSTRAP:-0}" == "1" ]]; then
            exit 5
        fi
        touch "$state/$(basename "$3" .plist)"
        ;;
    bootout)
        [[ -f "$state/${2##*/}" ]] || exit 3
        rm -f "$state/${2##*/}"
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$TEST_BIN_DIR/launchctl"
}

install_fake_crontab() {
    cat > "$TEST_BIN_DIR/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state="${TEST_CRONTAB_FILE:?}"
mkdir -p "$(dirname "$state")"

case "${1:-}" in
    -l)
        if [[ -f "$state" ]]; then
            cat "$state"
            exit 0
        fi
        exit 1
        ;;
    -r)
        rm -f "$state"
        ;;
    *)
        if [[ "${TEST_CRONTAB_FAIL_WRITE:-0}" == "1" ]]; then
            exit 1
        fi
        # Buffer stdin like the real crontab so `crontab -l | ... | crontab -`
        # does not truncate the file while it is still being read.
        tmp="$(mktemp "${state}.XXXXXX")"
        cat > "$tmp"
        mv "$tmp" "$state"
        ;;
esac
EOF
    chmod +x "$TEST_BIN_DIR/crontab"
}

install_fake_date() {
    cat > "$TEST_BIN_DIR/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    +*)
        printf '20260405000000\n'
        ;;
    -d|-v-*)
        printf '2026-03-29T00:00:00Z\n'
        ;;
    *)
        if [[ $# -gt 0 && "$*" == *'%Y-%m-%dT00:00:00Z'* ]]; then
            printf '2026-03-29T00:00:00Z\n'
        else
            printf '20260405000000\n'
        fi
        ;;
esac
EOF
    chmod +x "$TEST_BIN_DIR/date"
}

install_fake_detection_tools() {
    local yarn_version="${1:-1.22.22}"
    local include_bun="${2:-0}"
    local npm_version="${3:-12.0.1}"
    local pnpm_version="${4:-10.19.0}"
    local bun_version="${5:-1.3.2}"
    local uv_version="${6:-0.11.24}"
    local pip_version="${7:-26.1}"
    local include_vlt="${8:-1}"
    local vlt_version="${9:-0.0.0}"
    local include_deno="${10:-1}"
    local deno_version="${11:-2.8.0}"
    local include_poetry="${12:-1}"
    local poetry_version="${13:-2.4.0}"
    local include_bundler="${14:-1}"
    local bundler_version="${15:-4.0.15}"
    local pixi_version="${16:-0.83.0}"
    local include_hex="${17:-1}"
    local hex_version="${18:-2.5.1}"

    cat > "$TEST_BIN_DIR/pip3" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "--version" ]]; then
    printf 'pip %s from %s\n' "$pip_version" "\$0"
    exit 0
fi

printf 'pip3 test binary\n'
EOF

    cat > "$TEST_BIN_DIR/uv" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "--version" ]]; then
    printf 'uv %s\n' "$uv_version"
    exit 0
fi

printf 'uv test binary\n'
EOF

    cat > "$TEST_BIN_DIR/npm" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "--version" ]]; then
    printf '%s\n' "$npm_version"
    exit 0
fi

printf 'npm test binary\n'
EOF

    cat > "$TEST_BIN_DIR/pnpm" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "--version" ]]; then
    printf '%s\n' "$pnpm_version"
    exit 0
fi

printf 'pnpm test binary\n'
EOF

    cat > "$TEST_BIN_DIR/yarn" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "--version" ]]; then
    printf '%s\n' "$yarn_version"
    exit 0
fi

printf 'yarn test binary\n'
EOF

    cat > "$TEST_BIN_DIR/pixi" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "--version" ]]; then
    printf 'pixi %s\n' "$pixi_version"
    exit 0
fi

printf 'pixi test binary\n'
EOF

    chmod +x "$TEST_BIN_DIR/pip3" "$TEST_BIN_DIR/uv" "$TEST_BIN_DIR/npm" "$TEST_BIN_DIR/pnpm" "$TEST_BIN_DIR/yarn" "$TEST_BIN_DIR/pixi"

    if [[ "$include_poetry" == "1" ]]; then
        cat > "$TEST_BIN_DIR/poetry" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "--version" ]]; then
    printf 'Poetry (version %s)\n' "$poetry_version"
    exit 0
fi

printf 'poetry test binary\n'
EOF
        chmod +x "$TEST_BIN_DIR/poetry"
    else
        rm -f "$TEST_BIN_DIR/poetry"
    fi

    if [[ "$include_bundler" == "1" ]]; then
        cat > "$TEST_BIN_DIR/bundle" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "--version" ]]; then
    printf 'Bundler version %s\n' "$bundler_version"
    exit 0
fi

printf 'bundle test binary\n'
EOF
        chmod +x "$TEST_BIN_DIR/bundle"
    else
        rm -f "$TEST_BIN_DIR/bundle"
    fi

    if [[ "$include_hex" == "1" ]]; then
        cat > "$TEST_BIN_DIR/mix" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "hex.info" ]]; then
    printf 'Hex: %s\n' "$hex_version"
    exit 0
fi

printf 'mix test binary\n'
EOF
        chmod +x "$TEST_BIN_DIR/mix"
    else
        rm -f "$TEST_BIN_DIR/mix"
    fi

    if [[ "$include_bun" == "1" ]]; then
        cat > "$TEST_BIN_DIR/bun" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "--version" ]]; then
    printf '%s\n' "$bun_version"
    exit 0
fi

printf 'bun test binary\n'
EOF
        chmod +x "$TEST_BIN_DIR/bun"
    else
        rm -f "$TEST_BIN_DIR/bun"
    fi

    if [[ "$include_vlt" == "1" ]]; then
        cat > "$TEST_BIN_DIR/vlt" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "--version" ]]; then
    printf '%s\n' "$vlt_version"
    exit 0
fi

printf 'vlt test binary\n'
EOF
        chmod +x "$TEST_BIN_DIR/vlt"
    else
        rm -f "$TEST_BIN_DIR/vlt"
    fi

    if [[ "$include_deno" == "1" ]]; then
        cat > "$TEST_BIN_DIR/deno" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "--version" ]]; then
    printf 'deno %s\n' "$deno_version"
    exit 0
fi

printf 'deno test binary\n'
EOF
        chmod +x "$TEST_BIN_DIR/deno"
    else
        rm -f "$TEST_BIN_DIR/deno"
    fi
}

install_fake_validation_tools() {
    local yarn_version="${1:-1.22.22}"
    local npm_version="${2:-12.0.1}"
    local pnpm_version="${3:-10.19.0}"
    local deno_version="${4:-2.9.0}"
    local pixi_version="${5:-0.83.0}"

    install_fake_detection_tools "$yarn_version" 1 "$npm_version" "$pnpm_version" "" "" "" 1 "" 1 "$deno_version" 1 "" 1 "" "$pixi_version"

    cat > "$TEST_BIN_DIR/pip3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
    printf 'pip 26.1 from %s\n' "$0"
elif [[ "${1:-}" == "config" && "${2:-}" == "list" ]]; then
    printf 'install.uploaded-prior-to='\''2026-03-29T00:00:00Z'\''\n'
else
    exit 1
fi
EOF

    cat > "$TEST_BIN_DIR/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
    printf 'uv 0.11.24\n'
elif [[ "${1:-}" == "self" && "${2:-}" == "version" ]]; then
    printf 'uv 0.11.24\n'
else
    exit 1
fi
EOF

    cat > "$TEST_BIN_DIR/npm" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "--version" ]]; then
    printf '%s\n' "$npm_version"
elif [[ "\${1:-}" == "config" && "\${2:-}" == "list" ]]; then
    printf '; before = 2026-03-29T00:00:00.000Z\n'
else
    exit 1
fi
EOF

    cat > "$TEST_BIN_DIR/pnpm" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "--version" ]]; then
    printf '%s\n' "$pnpm_version"
elif [[ "\${1:-}" == "config" && "\${2:-}" == "get" && "\${3:-}" == "minimum-release-age" ]]; then
    printf '1440\n'
elif [[ "\${1:-}" == "config" && "\${2:-}" == "get" && "\${3:-}" == "minimum-release-age-exclude" ]]; then
    printf 'webpack,@myorg/*\n'
else
    exit 1
fi
EOF

    cat > "$TEST_BIN_DIR/yarn" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "--version" ]]; then
    printf '%s\n' "$yarn_version"
    exit 0
fi

if [[ "\${1:-}" == "config" && "\${2:-}" == "list" ]]; then
    printf 'cache-min true\n'
    exit 0
fi

if [[ "\${1:-}" == "config" && "\${2:-}" == "get" && "\${3:-}" == "npmMinimalAgeGate" ]]; then
    printf '7d\n'
    exit 0
fi

exit 1
EOF

    chmod +x "$TEST_BIN_DIR/pip3" "$TEST_BIN_DIR/uv" "$TEST_BIN_DIR/npm" "$TEST_BIN_DIR/pnpm" "$TEST_BIN_DIR/yarn"
}
