#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/common_test.sh"
bash "$SCRIPT_DIR/linux_wrapper_test.sh"
bash "$SCRIPT_DIR/macos_wrapper_test.sh"
