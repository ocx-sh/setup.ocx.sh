#!/bin/sh
# shellcheck disable=SC3043  # `local` verified at runtime by has_local()
# install.sh — OCX installer for Unix and macOS
# https://ocx.sh
#
# Usage:
#   curl -fsSL https://setup.ocx.sh/sh | sh
#   curl -fsSL https://setup.ocx.sh/sh | sh -s -- --no-modify-path
#   curl -fsSL https://setup.ocx.sh/sh | sh -s -- --version 0.5.0
#
# Stdout/stderr contract (v2):
#   - All informational/warning/error messages go to STDERR.
#   - STDOUT is silent on success unless OCX_INSTALL_PRINT_PATH=1, in which
#     case the FINAL stdout line is the absolute path to the OCX bin dir.
#
# Exit codes:
#   0  success
#   1  generic / legacy
#   2  argument or environment validation
#   3  network / download / API failure
#   4  checksum mismatch
#   5  archive extraction failure
#   6  bootstrap failure
#   7  unsupported platform / architecture

set -eu

has_local() { local _ 2>/dev/null; }
has_local || alias local=typeset

# --- Configuration (env-driven, Bazelisk-style) ---

OCX_INSTALL_REPO="${OCX_INSTALL_REPO:-ocx-sh/ocx}"
OCX_INSTALL_BASE_URL="${OCX_INSTALL_BASE_URL:-https://github.com/${OCX_INSTALL_REPO}/releases/download}"
OCX_INSTALL_API_URL="${OCX_INSTALL_API_URL:-https://api.github.com/repos/${OCX_INSTALL_REPO}/releases}"

# URL templates: placeholders {version}, {tag}, {target}, {ext}.
# Built via intermediate vars because '{tag}' literals inside ${VAR:-default}
# get eaten by the shell's brace-balanced default-value parser.
_default_format_url="${OCX_INSTALL_BASE_URL}/{tag}/ocx-{target}.{ext}"
_default_checksum_format_url="${OCX_INSTALL_BASE_URL}/{tag}/sha256.sum"
OCX_INSTALL_FORMAT_URL="${OCX_INSTALL_FORMAT_URL:-$_default_format_url}"
OCX_INSTALL_CHECKSUM_FORMAT_URL="${OCX_INSTALL_CHECKSUM_FORMAT_URL:-$_default_checksum_format_url}"
unset _default_format_url _default_checksum_format_url

# Behavioral knobs (truthy: 1, true, yes, TRUE, YES)
OCX_INSTALL_SKIP_BOOTSTRAP="${OCX_INSTALL_SKIP_BOOTSTRAP:-0}"
OCX_INSTALL_PRINT_PATH="${OCX_INSTALL_PRINT_PATH:-0}"
OCX_INSTALL_FORCE="${OCX_INSTALL_FORCE:-0}"
OCX_INSTALL_QUIET="${OCX_INSTALL_QUIET:-0}"
OCX_INSTALL_NO_BIN_SMOKETEST="${OCX_INSTALL_NO_BIN_SMOKETEST:-0}"
OCX_INSTALL_DOWNLOADER="${OCX_INSTALL_DOWNLOADER:-}"

# --- Truthy helper ---

is_truthy() {
    case "$1" in
        1 | true | yes | TRUE | YES | True | Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Output helpers (all go to STDERR) ---

say() {
    is_truthy "$OCX_INSTALL_QUIET" && return 0
    printf 'ocx-install: %s\n' "$1" >&2
}

warn() {
    printf 'ocx-install: warning: %s\n' "$1" >&2
}

# err [msg] [exit_code]
err() {
    printf 'ocx-install: error: %s\n' "$1" >&2
    exit "${2:-1}"
}

# Replace $HOME prefix with ~ for user-facing display
tildify() {
    echo "$1" | sed "s|^${HOME}|~|"
}

# --- Core utilities ---

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

need_cmd() {
    if ! check_cmd "$1"; then
        err "required command not found: $1" 2
    fi
}

ensure() {
    if ! "$@"; then err "command failed: $*"; fi
}

ignore() {
    "$@" || true
}

get_home() {
    if [ -n "${HOME:-}" ]; then
        echo "$HOME"
    elif [ -n "${USER:-}" ]; then
        getent passwd "$USER" | cut -d: -f6
    else
        getent passwd "$(id -un)" | cut -d: -f6
    fi
}

HOME="${HOME:-$(get_home)}"

test_windows_posix() {
    case "$(uname)" in
        CYGWIN* | MSYS* | MINGW*) return 0 ;;
        *) return 1 ;;
    esac
}

# TTY/color detection — bold-only, respects NO_COLOR (https://no-color.org/)
# Color goes to stderr alongside the text it decorates.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    _bold=$(tput bold 2>/dev/null || echo "")
    _reset=$(tput sgr0 2>/dev/null || echo "")
else
    _bold=""
    _reset=""
fi

# Substitute {version}, {tag}, {target}, {ext} placeholders in a URL template.
# Args: $1=template, $2=version, $3=tag, $4=target, $5=ext
format_url() {
    printf '%s' "$1" |
        sed -e "s|{version}|$2|g" \
            -e "s|{tag}|$3|g" \
            -e "s|{target}|$4|g" \
            -e "s|{ext}|$5|g"
}

# --- Usage ---

usage() {
    cat >&2 <<'EOF'
OCX installer — https://ocx.sh

USAGE:
    curl -fsSL https://setup.ocx.sh/sh | sh
    curl -fsSL https://setup.ocx.sh/sh | sh -s -- [OPTIONS]

OPTIONS:
    --version <VERSION>   Install a specific version (e.g., 0.5.0)
    --no-modify-path      Don't modify shell profile files
    -h, --help            Print this help message

ENVIRONMENT (user-facing):
    OCX_HOME                  Installation directory (default: ~/.ocx)
    OCX_NO_MODIFY_PATH        Set to 1/true/yes to skip shell profile modification
    GITHUB_TOKEN              GitHub API token (avoids rate limits)
    NO_COLOR                  Disable colored output (https://no-color.org/)

ENVIRONMENT (CI / mirror configuration, Bazelisk-style):
    OCX_INSTALL_REPO              GitHub owner/repo (default: ocx-sh/ocx)
    OCX_INSTALL_BASE_URL          Release-asset base URL
    OCX_INSTALL_API_URL           Release-list API URL (latest version lookup)
    OCX_INSTALL_FORMAT_URL        Template: placeholders {version},{tag},{target},{ext}
    OCX_INSTALL_CHECKSUM_FORMAT_URL  Template for sha256.sum URL
    OCX_INSTALL_SKIP_BOOTSTRAP    1 = skip 'ocx --remote install' bootstrap
    OCX_INSTALL_PRINT_PATH        1 = emit absolute bin dir on final stdout line
    OCX_INSTALL_FORCE             1 = reinstall even if same version is present
    OCX_INSTALL_QUIET             1 = suppress informational logs (warn/err remain)
    OCX_INSTALL_NO_BIN_SMOKETEST  1 = skip post-extract '$bin version' check
    OCX_INSTALL_DOWNLOADER        Force 'curl' or 'wget' (default: auto-detect)
EOF
}

# --- Platform detection ---

detect_target() {
    local _os _arch _libc

    _os=$(uname -s)
    case "$_os" in
        Linux | Darwin) ;;
        *) err "unsupported operating system: $_os (expected Linux or macOS)" 7 ;;
    esac

    _arch=$(uname -m)
    case "$_arch" in
        x86_64 | amd64) _arch="x86_64" ;;
        aarch64 | arm64) _arch="aarch64" ;;
        *) err "unsupported architecture: $_arch (expected x86_64 or aarch64)" 7 ;;
    esac

    if [ "$_os" = "Darwin" ] && [ "$_arch" = "x86_64" ]; then
        if sysctl -n hw.optional.arm64 2>/dev/null | grep -q '1'; then
            say "Detected Apple Silicon running under Rosetta — using native arm64 binary."
            _arch="aarch64"
        fi
    fi

    case "$_os" in
        Linux)
            _libc="gnu"
            if check_cmd ldd; then
                case "$(ldd --version 2>&1 || true)" in
                    *musl*) _libc="musl" ;;
                esac
            elif ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then
                _libc="musl"
            elif [ -f /etc/alpine-release ]; then
                _libc="musl"
            fi
            echo "${_arch}-unknown-linux-${_libc}"
            ;;
        Darwin)
            echo "${_arch}-apple-darwin"
            ;;
        *)
            err "unsupported operating system: $_os" 7
            ;;
    esac
}

# --- Download utilities ---

detect_downloader() {
    if [ -n "$OCX_INSTALL_DOWNLOADER" ]; then
        case "$OCX_INSTALL_DOWNLOADER" in
            curl | wget)
                if ! check_cmd "$OCX_INSTALL_DOWNLOADER"; then
                    err "OCX_INSTALL_DOWNLOADER=$OCX_INSTALL_DOWNLOADER but '$OCX_INSTALL_DOWNLOADER' not on PATH" 2
                fi
                _downloader="$OCX_INSTALL_DOWNLOADER"
                return
                ;;
            *)
                err "OCX_INSTALL_DOWNLOADER must be 'curl' or 'wget' (got: $OCX_INSTALL_DOWNLOADER)" 2
                ;;
        esac
    fi

    if check_cmd curl; then
        if curl --version 2>&1 | head -1 | grep -qF 'snap'; then
            warn "detected snap-packaged curl (may have sandbox restrictions)"
            if check_cmd wget; then
                _downloader="wget"
                return
            fi
            warn "no wget fallback — continuing with snap curl"
        fi
        _downloader="curl"
    elif check_cmd wget; then
        _downloader="wget"
    else
        err "either curl or wget is required to download OCX" 2
    fi
}

download_to_file() {
    local _url="$1" _dest="$2"

    if [ "$_downloader" = "curl" ]; then
        curl --tlsv1.2 -fsSL -o "$_dest" "$_url"
    else
        wget -q -O "$_dest" "$_url"
    fi
}

download() {
    if [ "$_downloader" = "curl" ]; then
        curl --tlsv1.2 -fsSL "$1"
    else
        wget -qO- "$1"
    fi
}

download_api() {
    local _url="$1"

    if [ -n "${GITHUB_TOKEN:-}" ]; then
        if [ "$_downloader" = "curl" ]; then
            curl --tlsv1.2 -fsSL -H "Authorization: token ${GITHUB_TOKEN}" "$_url"
        else
            wget -q --header="Authorization: token ${GITHUB_TOKEN}" -O- "$_url"
        fi
    else
        download "$_url"
    fi
}

# --- Checksum verification ---

verify_checksum() {
    local _dir="$1" _file="$2" _sha_cmd _expected _actual

    if check_cmd sha256sum; then
        _sha_cmd="sha256sum"
    elif check_cmd shasum; then
        _sha_cmd="shasum -a 256"
    else
        warn "neither sha256sum nor shasum found — SKIPPING CHECKSUM VERIFICATION"
        warn "install coreutils or set PATH to include sha256sum for verified downloads"
        return 0
    fi

    _expected=$(grep -F "$_file" "$_dir/sha256.sum" | awk '{print $1}')
    if [ -z "$_expected" ]; then
        err "checksum for $_file not found in sha256.sum" 4
    fi

    # shellcheck disable=SC2086
    _actual=$(cd "$_dir" && $_sha_cmd "$_file" | awk '{print $1}')

    if [ "$_expected" != "$_actual" ]; then
        err "checksum mismatch for $_file
  expected: $_expected
  got:      $_actual" 4
    fi

    say "Checksum verified."
}

# --- Version resolution ---

get_latest_version() {
    local _release_info _tag

    _release_info=$(download_api "${OCX_INSTALL_API_URL}/latest") || {
        if [ -z "${GITHUB_TOKEN:-}" ]; then
            err "failed to fetch latest release from GitHub
  This may be a rate-limit issue. Try setting GITHUB_TOKEN:
    export GITHUB_TOKEN=ghp_...
    curl -fsSL https://setup.ocx.sh/sh | sh" 3
        else
            err "failed to fetch latest release from GitHub — check your internet connection and token" 3
        fi
    }

    _tag=$(printf '%s' "$_release_info" |
        grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' |
        head -1 |
        grep -o '"[^"]*"$' |
        tr -d '"')

    if [ -z "$_tag" ]; then
        err "could not determine latest version from GitHub" 3
    fi

    printf '%s' "$_tag" | sed 's/^v//'
}

# --- Shell environment files ---

create_env_file() {
    local _ocx_home="${OCX_HOME:-$HOME/.ocx}"

    mkdir -p "$_ocx_home"

    cat >"$_ocx_home/env" <<'ENVEOF'
#!/bin/sh
# OCX shell environment — generated by install.sh
# Sourced by your shell profile to add OCX to PATH and enable completions.
# Manual changes will be overwritten on reinstall.
_ocx_home="${OCX_HOME:-$HOME/.ocx}"
export PATH="${_ocx_home}/symlinks/ocx.sh/ocx/current/bin:$PATH"
_ocx_bin="${_ocx_home}/symlinks/ocx.sh/ocx/current/bin/ocx"
if [ -x "$_ocx_bin" ]; then
  eval "$("$_ocx_bin" --offline shell profile load 2>/dev/null)" 2>/dev/null || true
  eval "$("$_ocx_bin" --offline shell completion 2>/dev/null)" 2>/dev/null || true
fi
unset _ocx_home _ocx_bin
ENVEOF
}

create_fish_config() {
    local _fish_conf_dir

    _fish_conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d"
    mkdir -p "$_fish_conf_dir"

    cat >"$_fish_conf_dir/ocx.fish" <<'FISHEOF'
# OCX shell environment — generated by install.sh
# Guarded so that deleting $OCX_HOME does not error on every new fish session.
set -l _ocx_home (set -q OCX_HOME; and echo $OCX_HOME; or echo $HOME/.ocx)
if test -d "$_ocx_home"
  fish_add_path --path "$_ocx_home/symlinks/ocx.sh/ocx/current/bin"
  set -l _ocx_bin "$_ocx_home/symlinks/ocx.sh/ocx/current/bin/ocx"
  if test -x "$_ocx_bin"
    "$_ocx_bin" --offline shell profile load --shell fish 2>/dev/null | source
    "$_ocx_bin" --offline shell completion --shell fish 2>/dev/null | source
  end
end
FISHEOF
}

# --- Shell profile modification ---

detect_profile() {
    local _shell_name

    _shell_name=$(basename "${SHELL:-sh}")

    case "$_shell_name" in
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                echo "$HOME/.bash_profile"
            else
                echo "$HOME/.profile"
            fi
            ;;
        zsh)
            echo "$HOME/.zshenv"
            ;;
        fish)
            echo ""
            ;;
        *)
            echo "$HOME/.profile"
            ;;
    esac
}

modify_shell_profile() {
    local _profile _source_line _ocx_home _env_path _shell_name

    _ocx_home="${OCX_HOME:-$HOME/.ocx}"
    _env_path="$_ocx_home/env"

    if [ "$_ocx_home" = "$HOME/.ocx" ]; then
        # shellcheck disable=SC2016
        _source_line='if [ -f "$HOME/.ocx/env" ]; then . "$HOME/.ocx/env"; fi'
    else
        _source_line="if [ -f \"$_env_path\" ]; then . \"$_env_path\"; fi"
    fi

    _shell_name=$(basename "${SHELL:-sh}")

    if [ "$_shell_name" = "fish" ]; then
        create_fish_config
        say "Created Fish configuration."
        return
    fi

    _profile=$(detect_profile)
    if [ -z "$_profile" ]; then
        return
    fi

    if [ -f "$_profile" ] && grep -qF '.ocx/env' "$_profile" 2>/dev/null; then
        say "Shell profile already configured ($(tildify "$_profile"))."
        return
    fi

    printf '\n# OCX\n%s\n' "$_source_line" >>"$_profile"
    say "Added OCX to $(tildify "$_profile")"
}

# --- Bootstrap: OCX installs itself ---

bootstrap_ocx() {
    local _bin="$1" _version="$2"

    say "Bootstrapping OCX into its own package store..."
    if ! "$_bin" --remote install --select "ocx.sh/ocx:$_version"; then
        err "bootstrap failed: 'ocx --remote install --select ocx.sh/ocx:$_version'
  Ensure ocx v${_version} is published to the ocx.sh registry.
  If this is a first install and the registry is not yet populated,
  please wait for the release pipeline to complete.
  To skip the bootstrap step (offline / air-gapped installs), set
  OCX_INSTALL_SKIP_BOOTSTRAP=1." 6
    fi
}

# Skip-bootstrap path: place the extracted binary at the canonical
# symlinks/.../current/bin location so downstream consumers find it.
# This is the air-gapped / GLF-build path.
install_without_bootstrap() {
    local _bin="$1" _version="$2" _ocx_home="$3"
    local _store="$_ocx_home/symlinks/ocx.sh/ocx"

    say "Installing without bootstrap (OCX_INSTALL_SKIP_BOOTSTRAP=1)..."
    mkdir -p "$_store/$_version/bin"
    cp -f "$_bin" "$_store/$_version/bin/ocx"
    chmod +x "$_store/$_version/bin/ocx"
    ln -sfn "$_version" "$_store/current"
}

# --- Success message ---

print_success() {
    local _version="$1" _ocx_home _env_display _old_version="${2:-}"

    is_truthy "$OCX_INSTALL_QUIET" && return 0

    _ocx_home="${OCX_HOME:-$HOME/.ocx}"
    _env_display=$(tildify "$_ocx_home/env")

    if [ -n "$_old_version" ] && [ "$_old_version" != "$_version" ]; then
        printf '\n  %socx upgraded: %s -> %s%s\n' "$_bold" "$_old_version" "$_version" "$_reset" >&2
    else
        printf '\n  %socx %s installed successfully!%s\n' "$_bold" "$_version" "$_reset" >&2
    fi

    cat >&2 <<EOF

  To get started, restart your shell or run:

    . "$_ocx_home/env"

  Then verify with:

    ocx info

  To uninstall, remove the OCX home directory:

    rm -rf $_ocx_home

EOF
}

# --- Temp directory cleanup ---

cleanup() {
    if [ -n "${_tmpdir:-}" ]; then
        ignore rm -rf "$_tmpdir"
    fi
}

# --- Main ---

main() {
    local _no_modify_path _version _target _tmpdir _archive _tag
    local _archive_url _checksum_url _bin _ocx_home _old_version
    local _bin_dir _ext

    _no_modify_path="${OCX_NO_MODIFY_PATH:-0}"
    _version=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --no-modify-path) _no_modify_path=1 ;;
            --version)
                if [ $# -lt 2 ]; then
                    err "--version requires a value" 2
                fi
                _version="$2"
                shift
                ;;
            --version=*) _version="${1#--version=}" ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) err "unknown option: $1 (use --help for usage)" 2 ;;
        esac
        shift
    done

    if is_truthy "$_no_modify_path"; then
        _no_modify_path=1
    else
        _no_modify_path=0
    fi

    need_cmd uname
    need_cmd mktemp
    need_cmd tar
    detect_downloader

    _ocx_home="${OCX_HOME:-$HOME/.ocx}"

    _target=$(detect_target)
    say "Detected platform: $_target"

    if [ -z "$_version" ]; then
        say "Fetching latest version..."
        _version=$(get_latest_version)
    fi

    if echo "$_version" | grep -q '[^0-9a-zA-Z.+-]'; then
        err "invalid version format: $_version (expected semver like 1.2.3 or 1.0.0-rc.1)" 2
    elif echo "$_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]'; then
        : # valid
    else
        err "invalid version format: $_version (expected semver like 1.2.3)" 2
    fi

    _bin_dir="${_ocx_home}/symlinks/ocx.sh/ocx/current/bin"
    _old_version=""
    if [ -x "$_bin_dir/ocx" ]; then
        _old_version=$("$_bin_dir/ocx" version 2>/dev/null || echo "")
    fi

    # Force / idempotent fast-path
    if [ -n "$_old_version" ] && [ "$_old_version" = "$_version" ] && ! is_truthy "$OCX_INSTALL_FORCE"; then
        say "ocx v${_version} already installed at $(tildify "$_bin_dir/ocx") (set OCX_INSTALL_FORCE=1 to reinstall)"
        if is_truthy "$OCX_INSTALL_PRINT_PATH"; then
            printf '%s\n' "$_bin_dir"
        fi
        export_github_path
        exit 0
    fi

    say "Installing ocx v${_version}..."

    _tmpdir=$(mktemp -d)
    trap cleanup EXIT INT TERM HUP

    _ext="tar.xz"
    _tag="v${_version}"
    _archive="ocx-${_target}.${_ext}"
    _archive_url=$(format_url "$OCX_INSTALL_FORMAT_URL" "$_version" "$_tag" "$_target" "$_ext")
    _checksum_url=$(format_url "$OCX_INSTALL_CHECKSUM_FORMAT_URL" "$_version" "$_tag" "$_target" "$_ext")

    say "Downloading ${_archive}..."
    download_to_file "$_archive_url" "$_tmpdir/$_archive" ||
        err "failed to download ${_archive_url}
  Ensure v${_version} is a valid release with a binary for ${_target}.
  Available releases: https://github.com/${OCX_INSTALL_REPO}/releases" 3

    download_to_file "$_checksum_url" "$_tmpdir/sha256.sum" ||
        err "failed to download checksums from ${_checksum_url}" 3

    verify_checksum "$_tmpdir" "$_archive"

    if ! tar xf "$_tmpdir/$_archive" -C "$_tmpdir" 2>/dev/null; then
        err "failed to extract ${_archive} — ensure tar and xz-utils are installed" 5
    fi

    if [ -f "$_tmpdir/ocx-${_target}/ocx" ]; then
        _bin="$_tmpdir/ocx-${_target}/ocx"
    elif [ -f "$_tmpdir/ocx" ]; then
        _bin="$_tmpdir/ocx"
    else
        err "could not find ocx binary in archive" 5
    fi

    chmod +x "$_bin"

    if ! is_truthy "$OCX_INSTALL_NO_BIN_SMOKETEST"; then
        if ! "$_bin" version >/dev/null 2>&1; then
            warn "binary failed to execute in temp directory ($(dirname "$_bin"))"
            warn "your /tmp may be mounted with noexec — try: TMPDIR=\$HOME/.tmp $0"
        fi
    fi

    if check_cmd ocx; then
        local _existing_ocx
        _existing_ocx=$(command -v ocx)
        case "$_existing_ocx" in
            "${_ocx_home}"/*) ;;
            *)
                warn "an existing ocx was found at $_existing_ocx"
                warn "the new install may be shadowed — check your PATH order"
                ;;
        esac
    fi

    if is_truthy "$OCX_INSTALL_SKIP_BOOTSTRAP"; then
        install_without_bootstrap "$_bin" "$_version" "$_ocx_home"
    else
        bootstrap_ocx "$_bin" "$_version"
    fi
    say "Installed to $(tildify "${_bin_dir}/ocx")"

    create_env_file

    if check_cmd fish; then
        create_fish_config
    fi

    if [ "$_no_modify_path" = "1" ]; then
        say "Skipping shell profile modification (--no-modify-path)."
    else
        modify_shell_profile
    fi

    export_github_path

    print_success "$_version" "$_old_version"

    if is_truthy "$OCX_INSTALL_PRINT_PATH"; then
        printf '%s\n' "$_bin_dir"
    fi
}

# Export the OCX bin directory to GITHUB_PATH for GitHub Actions.
export_github_path() {
    local _install_path="${OCX_HOME:-$HOME/.ocx}/symlinks/ocx.sh/ocx/current/bin"
    if [ -n "${GITHUB_PATH:-}" ]; then
        printf '%s\n' "$_install_path" >>"$GITHUB_PATH" ||
            warn "failed to write to \$GITHUB_PATH"
    fi
}

main "$@"
