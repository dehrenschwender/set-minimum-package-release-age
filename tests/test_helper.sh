#!/usr/bin/env bash

set -euo pipefail

TESTS_RUN=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_LIB="$PROJECT_ROOT/lib/set_package_min_age_common.sh"

run_test() {
    local name="$1"
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if ( "$@" ); then
        printf 'PASS %s\n' "$name"
        return 0
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL %s\n' "$name" >&2
    return 1
}

finish_tests() {
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
    export HOME="$TEST_ROOT/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    export TEST_BIN_DIR="$TEST_ROOT/bin"
    export TEST_CRONTAB_FILE="$TEST_ROOT/crontab"
    export PATH="$TEST_BIN_DIR:/usr/bin:/bin"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$TEST_BIN_DIR"
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

    platform_build_uv_cron_command() {
        local min_age="$1"
        local uv_conf="$2"
        printf '0 0 * * * echo %s >> %s %s\n' "$min_age" "$uv_conf" "$CRON_MARKER"
    }

    platform_build_vlt_cron_command() {
        local min_age="$1"
        local vlt_conf="$2"
        printf '0 0 * * * echo %s >> %s %s\n' "$min_age" "$vlt_conf" "$VLT_CRON_MARKER"
    }

    # shellcheck disable=SC1090
    source "$COMMON_LIB"
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
    -)
        if [[ "${TEST_CRONTAB_FAIL_WRITE:-0}" == "1" ]]; then
            exit 1
        fi
        cat > "$state"
        ;;
    *)
        if [[ "${TEST_CRONTAB_FAIL_WRITE:-0}" == "1" ]]; then
            exit 1
        fi
        cat > "$state"
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
    local npm_version="${3:-11.10.0}"
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
    local pixi_version="${16:-0.58.0}"

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
    local npm_version="${2:-11.10.0}"
    local pnpm_version="${3:-10.19.0}"
    local deno_version="${4:-2.9.0}"
    local pixi_version="${5:-0.58.0}"

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
