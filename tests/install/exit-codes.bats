#!/usr/bin/env bats
# Focused coverage for exit codes 5 (archive extract) and 6 (bootstrap).
# Exit codes 2, 3, 4 are covered by env-knobs.bats.
# Exit code 7 (unsupported platform) is exercised indirectly by tests/docker/.

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

@test "exit 5: corrupt archive (bad xz) fails to extract" {
    local _tamper="${BATS_TEST_TMPDIR}/tamper"
    cp -r "$FIXTURE_DIR" "$_tamper"
    # Overwrite the archive with garbage; keep the matching sha256 to bypass exit 4
    # (we want the *extraction* path to fail, not the checksum path).
    printf 'not a real xz archive\n' >"$_tamper/releases/download/v0.0.0/ocx-${FIXTURE_TARGET}.tar.xz"
    local _sum
    _sum=$(sha256sum "$_tamper/releases/download/v0.0.0/ocx-${FIXTURE_TARGET}.tar.xz" | awk '{print $1}')
    printf '%s  ocx-%s.tar.xz\n' "$_sum" "$FIXTURE_TARGET" \
        >"$_tamper/releases/download/v0.0.0/sha256.sum"
    local _info _pid _port
    _info=$(server_start "$_tamper" "${BATS_TEST_TMPDIR}/extract.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_BASE_URL="http://127.0.0.1:${_port}/releases/download" \
        OCX_INSTALL_API_URL="http://127.0.0.1:${_port}/api/repos/ocx-sh/ocx/releases" \
        run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 5 ]
}

@test "exit 5: archive missing ocx binary" {
    local _tamper="${BATS_TEST_TMPDIR}/tamper"
    mkdir -p "$_tamper/releases/download/v0.0.0"
    mkdir -p "$_tamper/api/repos/ocx-sh/ocx/releases"
    local _empty="${BATS_TEST_TMPDIR}/empty-bundle"
    mkdir -p "$_empty/ocx-${FIXTURE_TARGET}"
    # Drop a non-ocx file so the bundle is non-empty but has no binary.
    printf 'README\n' >"$_empty/ocx-${FIXTURE_TARGET}/README.txt"
    (cd "$_empty" && tar cJf "$_tamper/releases/download/v0.0.0/ocx-${FIXTURE_TARGET}.tar.xz" "ocx-${FIXTURE_TARGET}")
    local _sum
    _sum=$(sha256sum "$_tamper/releases/download/v0.0.0/ocx-${FIXTURE_TARGET}.tar.xz" | awk '{print $1}')
    printf '%s  ocx-%s.tar.xz\n' "$_sum" "$FIXTURE_TARGET" \
        >"$_tamper/releases/download/v0.0.0/sha256.sum"
    printf '{"tag_name":"v0.0.0","name":"v0.0.0"}\n' >"$_tamper/api/repos/ocx-sh/ocx/releases/latest"
    local _info _pid _port
    _info=$(server_start "$_tamper" "${BATS_TEST_TMPDIR}/missing.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_BASE_URL="http://127.0.0.1:${_port}/releases/download" \
        OCX_INSTALL_API_URL="http://127.0.0.1:${_port}/api/repos/ocx-sh/ocx/releases" \
        run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 5 ]
}

@test "exit 6: bootstrap failure when stub --remote returns nonzero" {
    # Build a fixture whose ocx stub fails the bootstrap call. SKIP_BOOTSTRAP
    # must be unset so bootstrap_ocx runs.
    local _bs="${BATS_TEST_TMPDIR}/bootstrap-fail"
    mkdir -p "$_bs/releases/download/v0.0.0"
    mkdir -p "$_bs/api/repos/ocx-sh/ocx/releases"
    local _build="${BATS_TEST_TMPDIR}/build/ocx-${FIXTURE_TARGET}"
    mkdir -p "$_build"
    cat >"$_build/ocx" <<'STUB'
#!/bin/sh
case "$1" in
    --remote) echo "stub bootstrap failure" >&2; exit 9 ;;
    *) echo "stub ocx" ;;
esac
STUB
    chmod +x "$_build/ocx"
    (cd "${BATS_TEST_TMPDIR}/build" && tar cJf "$_bs/releases/download/v0.0.0/ocx-${FIXTURE_TARGET}.tar.xz" "ocx-${FIXTURE_TARGET}")
    local _sum
    _sum=$(sha256sum "$_bs/releases/download/v0.0.0/ocx-${FIXTURE_TARGET}.tar.xz" | awk '{print $1}')
    printf '%s  ocx-%s.tar.xz\n' "$_sum" "$FIXTURE_TARGET" \
        >"$_bs/releases/download/v0.0.0/sha256.sum"
    printf '{"tag_name":"v0.0.0","name":"v0.0.0"}\n' >"$_bs/api/repos/ocx-sh/ocx/releases/latest"
    local _info _pid _port
    _info=$(server_start "$_bs" "${BATS_TEST_TMPDIR}/bs.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    unset OCX_INSTALL_SKIP_BOOTSTRAP
    OCX_INSTALL_BASE_URL="http://127.0.0.1:${_port}/releases/download" \
        OCX_INSTALL_API_URL="http://127.0.0.1:${_port}/api/repos/ocx-sh/ocx/releases" \
        run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 6 ]
}
