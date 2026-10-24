#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run every file even if an earlier one fails, then report overall status.
status=0
bash "$SCRIPT_DIR/common_test.sh" || status=1
bash "$SCRIPT_DIR/linux_wrapper_test.sh" || status=1
bash "$SCRIPT_DIR/macos_wrapper_test.sh" || status=1
bash "$SCRIPT_DIR/shell_test.sh" || status=1
bash "$SCRIPT_DIR/ui_test.sh" || status=1
exit "$status"
