#!/usr/bin/env bats
# Bats tests for sh/install.sh env-var knobs and exit codes.
# Requires: bats-core >= 1.5, python3, tar, xz, sha256sum.

bats_require_minimum_version 1.5.0

load helpers/server

INSTALL_SH="${BATS_TEST_DIRNAME}/../../sh/install.sh"

# Canonical CLI bin subpath (real on-disk store layout). Mirrors
# OCX_BIN_SUBPATH in sh/install.sh.
BIN_SUBPATH="symlinks/ocx.sh/ocx/cli/current/content/bin"

setup_file() {
    export FIXTURE_DIR="${BATS_FILE_TMPDIR}/srv"
    FIXTURE_TARGET=$(server_build_fixture "$FIXTURE_DIR")
    export FIXTURE_TARGET
    local _info
    _info=$(server_start "$FIXTURE_DIR" "${BATS_FILE_TMPDIR}/server.log")
    export FIXTURE_PID="${_info% *}"
    export FIXTURE_PORT="${_info#* }"
    export FIXTURE_URL="https://127.0.0.1:${FIXTURE_PORT}"
}

teardown_file() {
    server_stop "${FIXTURE_PID:-}"
}

setup() {
    export OCX_HOME="${BATS_TEST_TMPDIR}/.ocx"
    export OCX_NO_MODIFY_PATH=1
    # The fixture server speaks HTTPS (the installer enforces TLS). Trust the
    # vendored localhost test cert via CURL_CA_BUNDLE.
    export CURL_CA_BUNDLE
    CURL_CA_BUNDLE="$(server_ca_bundle)"
    # Record every fixture-stub invocation so tests can assert the exact
    # bootstrap argv (the corrected 'package install --select ...' command).
    export OCX_STUB_ARGV="${BATS_TEST_TMPDIR}/stub-argv.log"
    export OCX_INSTALL_BASE_URL="${FIXTURE_URL}/releases/download"
    export OCX_INSTALL_API_URL="${FIXTURE_URL}/api/repos/ocx-sh/ocx/releases"
    unset GITHUB_PATH
    # Recompute defaults that reference BASE_URL.
    unset OCX_INSTALL_FORMAT_URL OCX_INSTALL_CHECKSUM_FORMAT_URL
    unset OCX_INSTALL_SKIP_SELF_INIT
}

@test "default install bootstraps via the corrected 'package install' command" {
    run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    # The stub records its argv; the bootstrap call MUST be the corrected form,
    # not the old hallucinated 'ocx --remote install --select ocx.sh/ocx:...'.
    grep -qxF -- "--remote package install --select ocx.sh/ocx/cli:0.0.0" "$OCX_STUB_ARGV"
    # And the old broken command must NOT appear.
    ! grep -q -- "--remote install" "$OCX_STUB_ARGV"
    ! grep -q -- "ocx.sh/ocx:0.0.0" "$OCX_STUB_ARGV"
}

@test "default install writes the env.sh shim (not the legacy extensionless env)" {
    run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -f "${OCX_HOME}/env.sh" ]
    [ ! -f "${OCX_HOME}/env" ]
    # The shim delegates to 'ocx self activate --shell=sh'.
    grep -q 'self activate --shell=sh' "${OCX_HOME}/env.sh"
}

@test "skip-self-init writes the binary to the canonical bin dir" {
    OCX_INSTALL_SKIP_SELF_INIT=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "skip-self-init does NOT bootstrap and does NOT write env shims" {
    OCX_INSTALL_SKIP_SELF_INIT=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    # Binary on PATH at the canonical location.
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
    # No bootstrap call was recorded (the stub binary was never invoked with
    # --remote during install).
    [ ! -f "$OCX_STUB_ARGV" ] || ! grep -q -- "--remote" "$OCX_STUB_ARGV"
    # No env shims were generated.
    [ ! -f "${OCX_HOME}/env.sh" ]
    [ ! -f "${OCX_HOME}/env.fish" ]
}

@test "OCX_INSTALL_PRINT_PATH=1 emits bin dir as final stdout line" {
    OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 run --separate-stderr sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    # In --separate-stderr mode $lines is stdout-only.
    [ "${lines[-1]}" = "${OCX_HOME}/${BIN_SUBPATH}" ]
}

@test "OCX_INSTALL_QUIET=1 suppresses stderr informational logs" {
    OCX_INSTALL_QUIET=1 run --separate-stderr sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    # No 'Detected platform' / 'Installing' lines should appear on stderr.
    ! echo "$stderr" | grep -q 'Detected platform' || false
}

@test "stderr discipline: stdout is empty on success without PRINT_PATH" {
    run --separate-stderr sh "$INSTALL_SH" --version 0.0.0
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
    _info=$(server_start "$_tamper" "${BATS_TEST_TMPDIR}/sub.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_BASE_URL="https://127.0.0.1:${_port}/releases/download" \
        OCX_INSTALL_API_URL="https://127.0.0.1:${_port}/api/repos/ocx-sh/ocx/releases" \
        run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
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
    # The idempotent fast-path keys off the binary being present at the
    # canonical bin dir, which only the skip-self-init path populates, so this
    # scenario runs in skip-self-init mode.
    OCX_INSTALL_SKIP_SELF_INIT=1 sh "$INSTALL_SH" --version 0.0.0 >/dev/null 2>&1
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
    # Second run without FORCE should be idempotent (exit 0, fast-path).
    OCX_INSTALL_SKIP_SELF_INIT=1 OCX_INSTALL_PRINT_PATH=1 run --separate-stderr sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    # In --separate-stderr mode $lines is stdout-only.
    [ "${lines[-1]}" = "${OCX_HOME}/${BIN_SUBPATH}" ]
    # FORCE re-runs full install (still exits 0).
    OCX_INSTALL_SKIP_SELF_INIT=1 OCX_INSTALL_FORCE=1 run sh "$INSTALL_SH" --version 0.0.0
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
    _info=$(server_start "$_custom" "${BATS_TEST_TMPDIR}/c.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_FORMAT_URL="https://127.0.0.1:${_port}/{version}/{target}/ocx-{target}.{ext}" \
        OCX_INSTALL_CHECKSUM_FORMAT_URL="https://127.0.0.1:${_port}/{version}/{target}/sums.txt" \
        run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 0 ]
}

@test "flat-layout archive (binary at root) installs successfully" {
    # Production cargo-dist releases ship the binary at the archive root, not
    # nested under ocx-<target>/. Exercise that extraction branch.
    local _flat="${BATS_TEST_TMPDIR}/flat"
    local _flat_target
    _flat_target=$(server_build_fixture "$_flat" flat)
    [ "$_flat_target" = "$FIXTURE_TARGET" ]
    local _info _pid _port
    _info=$(server_start "$_flat" "${BATS_TEST_TMPDIR}/flat.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_SKIP_SELF_INIT=1 \
        OCX_INSTALL_BASE_URL="https://127.0.0.1:${_port}/releases/download" \
        OCX_INSTALL_API_URL="https://127.0.0.1:${_port}/api/repos/ocx-sh/ocx/releases" \
        run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "latest version resolves via OCX_INSTALL_API_URL override" {
    OCX_INSTALL_SKIP_SELF_INIT=1 run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}
