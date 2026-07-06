set shell := ["bash", "-cu"]

common_lib := "lib/set_package_min_age_common.sh"
linux_script := "set_package_min_age_linux.sh"
macos_script := "set_package_min_age_macos.sh"
test_runner := "tests/run.sh"

default:
  @just --list

syntax-check:
  bash -n {{common_lib}}
  bash -n {{linux_script}}
  bash -n {{macos_script}}
  bash -n tests/test_helper.sh
  bash -n tests/common_test.sh
  bash -n tests/linux_wrapper_test.sh
  bash -n tests/macos_wrapper_test.sh
  bash -n {{test_runner}}

test:
  bash {{test_runner}}

check: syntax-check test

run-linux ARGS="":
  bash {{linux_script}} {{ARGS}}

run-macos ARGS="":
  bash {{macos_script}} {{ARGS}}
