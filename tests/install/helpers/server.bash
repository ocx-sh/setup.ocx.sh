# Shared Bats helpers for the fixture HTTP server.
# Sourced via `load helpers/server.bash` from individual .bats files.

server_start() {
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

server_stop() {
    [ -n "${1:-}" ] && kill "$1" 2>/dev/null || true
}

server_detect_target() {
    local _arch _libc
    case "$(uname -m)" in
        x86_64 | amd64) _arch=x86_64 ;;
        aarch64 | arm64) _arch=aarch64 ;;
        *) echo "unsupported-arch"; return 1 ;;
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
        *) echo "unsupported-os"; return 1 ;;
    esac
}

server_build_fixture() {
    local _srv="$1" _target
    _target=$(server_detect_target)
    mkdir -p "$_srv/releases/download/v0.0.0"
    mkdir -p "$_srv/api/repos/ocx-sh/ocx/releases"

    local _build="${BATS_FILE_TMPDIR}/build/ocx-${_target}"
    mkdir -p "$_build"
    cat >"$_build/ocx" <<'STUB'
#!/bin/sh
case "$1" in
    version) echo "0.0.0" ;;
    --remote) exit 0 ;;
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
