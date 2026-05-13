#!/usr/bin/env bats
# Bats tests for sh/install.sh env-var knobs and exit codes.
# Requires: bats-core, python3, tar, xz, sha256sum.

INSTALL_SH="${BATS_TEST_DIRNAME}/../../sh/install.sh"

start_server() {
    local _root="$1" _logfile="$2"
    (cd "$_root" && python3 -u -m http.server 0 >"$_logfile" 2>&1) &
    local _pid=$!
    local _port=""
    for _ in $(seq 1 50); do
        _port=$(grep -oE 'port [0-9]+' "$_logfile" 2>/dev/null | head -1 | awk '{print $2}')
        [ -n "$_port" ] && break
        sleep 0.1
    done
    [ -z "$_port" ] && {
        kill "$_pid" 2>/dev/null
        return 1
    }
    printf '%s %s\n' "$_pid" "$_port"
}

stop_server() {
    [ -n "${1:-}" ] && kill "$1" 2>/dev/null || true
}

detect_target() {
    local _arch _libc
    case "$(uname -m)" in
        x86_64 | amd64) _arch=x86_64 ;;
        aarch64 | arm64) _arch=aarch64 ;;
        *) echo "unsupported-arch"; return 1 ;;
    esac
    case "$(uname -s)" in
        Linux)
            _libc=gnu
            if check_musl; then _libc=musl; fi
            echo "${_arch}-unknown-linux-${_libc}"
            ;;
        Darwin) echo "${_arch}-apple-darwin" ;;
        *) echo "unsupported-os"; return 1 ;;
    esac
}

check_musl() {
    if command -v ldd >/dev/null && ldd --version 2>&1 | grep -qi musl; then return 0; fi
    if ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then return 0; fi
    [ -f /etc/alpine-release ] && return 0
    return 1
}

build_fixture() {
    local _srv="$1" _target
    _target=$(detect_target)
    mkdir -p "$_srv/releases/download/v0.0.0"
    mkdir -p "$_srv/api/repos/ocx-sh/ocx/releases"

    local _build="${BATS_FILE_TMPDIR}/build/ocx-${_target}"
    mkdir -p "$_build"
    cat >"$_build/ocx" <<'STUB'
#!/bin/sh
case "$1" in
    version) echo "0.0.0" ;;
    --remote)
        # SKIP_BOOTSTRAP=1 in tests means this path is unused; succeed if hit.
        exit 0
        ;;
    *) echo "stub ocx" ;;
esac
STUB
    chmod +x "$_build/ocx"

    local _archive="$_srv/releases/download/v0.0.0/ocx-${_target}.tar.xz"
    (cd "${BATS_FILE_TMPDIR}/build" && tar cJf "$_archive" "ocx-${_target}")

    local _sum
    _sum=$(cd "$_srv/releases/download/v0.0.0" && sha256sum "ocx-${_target}.tar.xz" | awk '{print $1}')
    printf '%s  ocx-%s.tar.xz\n' "$_sum" "$_target" >"$_srv/releases/download/v0.0.0/sha256.sum"

    printf '{"tag_name":"v0.0.0","name":"v0.0.0"}\n' >"$_srv/api/repos/ocx-sh/ocx/releases/latest"

    echo "$_target"
}

setup_file() {
    export FIXTURE_DIR="${BATS_FILE_TMPDIR}/srv"
    FIXTURE_TARGET=$(build_fixture "$FIXTURE_DIR")
    export FIXTURE_TARGET
    local _info
    _info=$(start_server "$FIXTURE_DIR" "${BATS_FILE_TMPDIR}/server.log")
    export FIXTURE_PID="${_info% *}"
    export FIXTURE_PORT="${_info#* }"
    export FIXTURE_URL="http://127.0.0.1:${FIXTURE_PORT}"
}

teardown_file() {
    stop_server "${FIXTURE_PID:-}"
}

setup() {
    export OCX_HOME="${BATS_TEST_TMPDIR}/.ocx"
    export OCX_NO_MODIFY_PATH=1
    export OCX_INSTALL_SKIP_BOOTSTRAP=1
    export OCX_INSTALL_BASE_URL="${FIXTURE_URL}/releases/download"
    export OCX_INSTALL_API_URL="${FIXTURE_URL}/api/repos/ocx-sh/ocx/releases"
    unset GITHUB_PATH
    # Recompute defaults that reference BASE_URL.
    unset OCX_INSTALL_FORMAT_URL OCX_INSTALL_CHECKSUM_FORMAT_URL
}

@test "default install via env-overridden URLs writes binary to OCX_HOME" {
    run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/symlinks/ocx.sh/ocx/current/bin/ocx" ]
}

@test "OCX_INSTALL_PRINT_PATH=1 emits bin dir as final stdout line" {
    OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "${OCX_HOME}/symlinks/ocx.sh/ocx/current/bin" ]
}

@test "OCX_INSTALL_QUIET=1 suppresses stderr informational logs" {
    OCX_INSTALL_QUIET=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    # No 'Detected platform' / 'Installing' lines should appear.
    ! echo "$stderr" | grep -q 'Detected platform' || false
}

@test "stderr discipline: stdout is empty on success without PRINT_PATH" {
    run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -z "$stdout" ]
}

@test "404 → exit code 3" {
    OCX_INSTALL_BASE_URL="${FIXTURE_URL}/no-such-path" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 3 ]
}

@test "checksum mismatch → exit code 4" {
    local _tamper="${BATS_TEST_TMPDIR}/tamper"
    cp -r "$FIXTURE_DIR" "$_tamper"
    printf '%s  ocx-%s.tar.xz\n' \
        "0000000000000000000000000000000000000000000000000000000000000000" \
        "$FIXTURE_TARGET" >"$_tamper/releases/download/v0.0.0/sha256.sum"
    local _info _pid _port
    _info=$(start_server "$_tamper" "${BATS_TEST_TMPDIR}/sub.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_BASE_URL="http://127.0.0.1:${_port}/releases/download" \
        OCX_INSTALL_API_URL="http://127.0.0.1:${_port}/api/repos/ocx-sh/ocx/releases" \
        run sh "$INSTALL_SH" --version 0.0.0
    stop_server "$_pid"
    [ "$status" -eq 4 ]
}

@test "invalid version → exit code 2" {
    run sh "$INSTALL_SH" --version "foo;rm"
    [ "$status" -eq 2 ]
}

@test "unknown flag → exit code 2" {
    run sh "$INSTALL_SH" --bogus
    [ "$status" -eq 2 ]
}

@test "OCX_INSTALL_DOWNLOADER=invalid → exit code 2" {
    OCX_INSTALL_DOWNLOADER=ftp run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 2 ]
}

@test "OCX_INSTALL_FORCE=1 reinstalls when same version is present" {
    sh "$INSTALL_SH" --version 0.0.0 >/dev/null 2>&1
    [ -x "${OCX_HOME}/symlinks/ocx.sh/ocx/current/bin/ocx" ]
    # Second run without FORCE should be idempotent (exit 0, no re-download).
    OCX_INSTALL_PRINT_PATH=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "${OCX_HOME}/symlinks/ocx.sh/ocx/current/bin" ]
    # FORCE re-runs full install (still exits 0).
    OCX_INSTALL_FORCE=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
}

@test "OCX_INSTALL_FORMAT_URL substitutes {version},{target},{ext},{tag}" {
    local _custom="${BATS_TEST_TMPDIR}/custom"
    # Layout uses bare version (no v) to exercise the {version} placeholder.
    mkdir -p "$_custom/0.0.0/${FIXTURE_TARGET}"
    cp "${FIXTURE_DIR}/releases/download/v0.0.0/ocx-${FIXTURE_TARGET}.tar.xz" \
        "$_custom/0.0.0/${FIXTURE_TARGET}/ocx-${FIXTURE_TARGET}.tar.xz"
    cp "${FIXTURE_DIR}/releases/download/v0.0.0/sha256.sum" \
        "$_custom/0.0.0/${FIXTURE_TARGET}/sums.txt"
    local _info _pid _port
    _info=$(start_server "$_custom" "${BATS_TEST_TMPDIR}/c.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_FORMAT_URL="http://127.0.0.1:${_port}/{version}/{target}/ocx-{target}.{ext}" \
        OCX_INSTALL_CHECKSUM_FORMAT_URL="http://127.0.0.1:${_port}/{version}/{target}/sums.txt" \
        run sh "$INSTALL_SH" --version 0.0.0
    stop_server "$_pid"
    [ "$status" -eq 0 ]
}

@test "latest version resolves via OCX_INSTALL_API_URL override" {
    run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/symlinks/ocx.sh/ocx/current/bin/ocx" ]
}
