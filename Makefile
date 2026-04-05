.PHONY: help syntax-check test check run-linux run-macos

SHELL := /bin/bash

COMMON_LIB := lib/set_package_min_age_common.sh
LINUX_SCRIPT := set_package_min_age_linux.sh
MACOS_SCRIPT := set_package_min_age_macos.sh
TEST_RUNNER := tests/run.sh

help:
	@printf '%s\n' \
		'Available targets:' \
		'  make syntax-check        Run bash -n on scripts and tests' \
		'  make test                Run the full Bash test suite' \
		'  make check               Run syntax-check and test' \
		'  make run-linux ARGS=...  Run the Linux wrapper with optional ARGS' \
		'  make run-macos ARGS=...  Run the macOS wrapper with optional ARGS'

syntax-check:
	bash -n $(COMMON_LIB)
	bash -n $(LINUX_SCRIPT)
	bash -n $(MACOS_SCRIPT)
	bash -n tests/test_helper.sh
	bash -n tests/common_test.sh
	bash -n tests/linux_wrapper_test.sh
	bash -n tests/macos_wrapper_test.sh
	bash -n $(TEST_RUNNER)

test:
	bash $(TEST_RUNNER)

check: syntax-check test

run-linux:
	bash $(LINUX_SCRIPT) $(ARGS)

run-macos:
	bash $(MACOS_SCRIPT) $(ARGS)
