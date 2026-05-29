# Shared Bats helpers for the fixture HTTPS server.
# Sourced via `load helpers/server` from individual .bats files.
#
# NOTE: tests/install/fixtures/ is intentionally EMPTY. There are no static
# tarballs checked in. Every fixture tree (archive + sha256.sum + GitHub-API
# JSON) is built at runtime by server_build_fixture below, then served by
# server_start over HTTPS (python3 + ssl). See .claude/rules/testing-bash.md.
#
# The fixture server speaks HTTPS, not plain HTTP, because the corrected
# installer enforces TLS on every download (curl '--proto =https'; wget
# assert_https_url). A static, long-lived self-signed cert for 127.0.0.1 lives
# next to this file (localhost-cert.pem / localhost-combined.pem). Tests trust
# THAT specific cert via CURL_CA_BUNDLE — this establishes trust for the
# localhost test fixture only; it does NOT disable TLS verification.

# Directory containing this helper (and the vendored test cert).
_server_helper_dir() {
    # BATS sets BATS_TEST_DIRNAME to the .bats file's dir; helpers live under it.
    printf '%s/helpers' "${BATS_TEST_DIRNAME}"
}

# Path to the CA cert tests should trust (export as CURL_CA_BUNDLE).
server_ca_bundle() {
    printf '%s/localhost-cert.pem' "$(_server_helper_dir)"
}

server_start() {
    local _root="$1" _logfile="$2"
    local _combined
    _combined="$(_server_helper_dir)/localhost-combined.pem"
    # Redirect the WHOLE backgrounded subshell's stdio to the logfile (and
    # detach stdin / close bats' fd 3). Otherwise the long-lived server keeps
    # the command-substitution pipe ($(server_start ...)) and bats' fd 3 open,
    # and both the `$()` and the test itself hang waiting for them to close.
    (
        cd "$_root" || exit 1
        OCX_FIXTURE_CERT="$_combined"
        export OCX_FIXTURE_CERT
        exec python3 -u -c '
import http.server, ssl, os, sys
cert = os.environ["OCX_FIXTURE_CERT"]
httpd = http.server.HTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
sys.stderr.write("Serving HTTPS on 127.0.0.1 port %d\n" % httpd.socket.getsockname()[1])
sys.stderr.flush()
httpd.serve_forever()
'
    ) >"$_logfile" 2>&1 <&- 3>&- &
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

server_stop() {
    [ -n "${1:-}" ] && kill "$1" 2>/dev/null || true
}

server_detect_target() {
    local _arch _libc
    case "$(uname -m)" in
        x86_64 | amd64) _arch=x86_64 ;;
        aarch64 | arm64) _arch=aarch64 ;;
        *)
            echo "unsupported-arch"
            return 1
            ;;
    esac
    case "$(uname -s)" in
        Linux)
            _libc=gnu
            if command -v ldd >/dev/null && ldd --version 2>&1 | grep -qi musl; then _libc=musl; fi
            if ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then _libc=musl; fi
            [ -f /etc/alpine-release ] && _libc=musl
            echo "${_arch}-unknown-linux-${_libc}"
            ;;
        Darwin) echo "${_arch}-apple-darwin" ;;
        *)
            echo "unsupported-os"
            return 1
            ;;
    esac
}

# Emit the body of a fixture `ocx` stub binary that:
#   * answers `version` with 0.0.0 and `about` with a plausible banner,
#   * emits a plausible `ocx self activate --shell=sh` PATH-export snippet,
#   * records its full argv to $OCX_STUB_ARGV (one line per invocation) when
#     that env var is set, so the bootstrap call site can be asserted exactly,
#   * exits 0 for the bootstrap `--remote package install` call.
#
# Because the env shim's `self activate` runs at shell startup (not during the
# install), the recording is what proves the installer invoked the corrected
# bootstrap command `--remote package install --select ocx.sh/ocx/cli:VERSION`.
server_stub_body() {
    cat <<'STUB'
#!/bin/sh
# Fixture ocx stub — records argv and emits plausible OCX CLI output.
if [ -n "${OCX_STUB_ARGV:-}" ]; then
    printf '%s\n' "$*" >>"$OCX_STUB_ARGV"
fi
case "$1" in
    version)
        echo "0.0.0"
        ;;
    about)
        echo "ocx 0.0.0"
        echo "registry: ocx.sh"
        ;;
    self)
        # `ocx self activate --shell=<shell>` — emit a plausible activation
        # snippet (PATH export). The installer evals this at shell startup.
        if [ "$2" = "activate" ]; then
            echo 'export PATH="$HOME/.ocx/symlinks/ocx.sh/ocx/cli/current/content/bin:$PATH"'
            echo 'export OCX_ACTIVATED=1'
        fi
        ;;
    --remote)
        # Bootstrap: `ocx --remote package install --select ocx.sh/ocx/cli:VERSION`
        echo "Bootstrapped ocx into the package store." >&2
        exit 0
        ;;
    *)
        echo "stub ocx" ;;
esac
STUB
}

# Build a release fixture tree under $1.
#
# Args:
#   $1  fixture server root
#   $2  archive layout: "nested" (default; binary at ocx-<target>/ocx) or
#       "flat" (binary at archive root — the real cargo-dist release layout)
#   $3  optional alternate stub body (a path to a file, or "-" to read stdin);
#       when omitted the standard server_stub_body is used
#
# Echoes the detected target triple on success.
server_build_fixture() {
    local _srv="$1" _layout="${2:-nested}" _target
    _target=$(server_detect_target)
    mkdir -p "$_srv/releases/download/v0.0.0"
    mkdir -p "$_srv/api/repos/ocx-sh/ocx/releases"

    local _build="${BATS_FILE_TMPDIR}/build-${_layout}"
    rm -rf "$_build"
    mkdir -p "$_build"

    local _binsrc
    if [ "$_layout" = "flat" ]; then
        _binsrc="$_build/ocx"
    else
        mkdir -p "$_build/ocx-${_target}"
        _binsrc="$_build/ocx-${_target}/ocx"
    fi
    server_stub_body >"$_binsrc"
    chmod +x "$_binsrc"

    local _archive="$_srv/releases/download/v0.0.0/ocx-${_target}.tar.xz"
    if [ "$_layout" = "flat" ]; then
        (cd "$_build" && tar cJf "$_archive" "ocx")
    else
        (cd "$_build" && tar cJf "$_archive" "ocx-${_target}")
    fi

    local _sum
    _sum=$(cd "$_srv/releases/download/v0.0.0" && sha256sum "ocx-${_target}.tar.xz" | awk '{print $1}')
    printf '%s  ocx-%s.tar.xz\n' "$_sum" "$_target" >"$_srv/releases/download/v0.0.0/sha256.sum"

    printf '{"tag_name":"v0.0.0","name":"v0.0.0"}\n' >"$_srv/api/repos/ocx-sh/ocx/releases/latest"

    echo "$_target"
}
