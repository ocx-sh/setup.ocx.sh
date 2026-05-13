#!/usr/bin/env bats
# Stdout/stderr discipline. Documents the load-bearing contract that lets
# downstream wrappers do `BIN_DIR=$(./install.sh | tail -n1)`.

load helpers/server.bash

INSTALL_SH="${BATS_TEST_DIRNAME}/../../sh/install.sh"

setup_file() {
    export FIXTURE_DIR="${BATS_FILE_TMPDIR}/srv"
    FIXTURE_TARGET=$(server_build_fixture "$FIXTURE_DIR")
    export FIXTURE_TARGET
    local _info
    _info=$(server_start "$FIXTURE_DIR" "${BATS_FILE_TMPDIR}/server.log")
    export FIXTURE_PID="${_info% *}"
    export FIXTURE_PORT="${_info#* }"
    export FIXTURE_URL="http://127.0.0.1:${FIXTURE_PORT}"
}

teardown_file() {
    server_stop "${FIXTURE_PID:-}"
}

setup() {
    export OCX_HOME="${BATS_TEST_TMPDIR}/.ocx"
    export OCX_NO_MODIFY_PATH=1
    export OCX_INSTALL_SKIP_BOOTSTRAP=1
    export OCX_INSTALL_BASE_URL="${FIXTURE_URL}/releases/download"
    export OCX_INSTALL_API_URL="${FIXTURE_URL}/api/repos/ocx-sh/ocx/releases"
    unset OCX_INSTALL_FORMAT_URL OCX_INSTALL_CHECKSUM_FORMAT_URL GITHUB_PATH
}

@test "stdout is empty on default success" {
    run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -z "$stdout" ]
}

@test "OCX_INSTALL_PRINT_PATH=1 prints the bin dir as the final stdout line" {
    OCX_INSTALL_PRINT_PATH=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "${OCX_HOME}/symlinks/ocx.sh/ocx/current/bin" ]
}

@test "stderr carries the informational banner even with PRINT_PATH set" {
    OCX_INSTALL_PRINT_PATH=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    echo "$stderr" | grep -q 'Installing\|Detected\|Downloaded\|Verified\|Bootstrapped\|symlinks'
}

@test "OCX_INSTALL_QUIET=1 silences stderr informational lines" {
    OCX_INSTALL_QUIET=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    ! echo "$stderr" | grep -q 'Installing\|Downloaded\|Detected platform' || false
}

@test "error messages always go to stderr (exit 2 path)" {
    run sh "$INSTALL_SH" --bogus
    [ "$status" -eq 2 ]
    [ -z "$stdout" ]
    echo "$stderr" | grep -qi 'unknown\|invalid\|usage'
}
