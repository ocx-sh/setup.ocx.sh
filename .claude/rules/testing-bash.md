# Bash testing rules (Bats)

## Layout

```
tests/install/
├── env-knobs.bats             # OCX_INSTALL_* env var behavior + happy paths
├── exit-codes.bats            # Each numbered exit code path 2..7
├── print-path.bats            # Stdout/stderr discipline + OCX_INSTALL_PRINT_PATH
├── helpers/
│   ├── server.bash            # Runtime fixture builder + HTTPS server helpers
│   ├── localhost-cert.pem     # CA cert tests trust (CURL_CA_BUNDLE)
│   └── localhost-combined.pem # key + cert the python HTTPS server loads
└── fixtures/                  # EMPTY — fixtures are built at runtime (see below)
```

> `fixtures/` is intentionally empty. There are **no** static tarballs checked
> in. The whole release tree (archive + `sha256.sum` + GitHub-API JSON) is
> generated per-test by `helpers/server.bash`.

## Runtime fixture builder (`helpers/server.bash`)

`load helpers/server` exposes:

| Function | Purpose |
|---|---|
| `server_detect_target` | Echo the current `<arch>-<os>-<libc>` triple (e.g. `x86_64-unknown-linux-gnu`) so the fixture archive name matches what `detect_target()` in `install.sh` will request. |
| `server_build_fixture ROOT [LAYOUT]` | Build a v0.0.0 release tree under `ROOT`: `releases/download/v0.0.0/ocx-<target>.tar.xz` + `sha256.sum`, and `api/repos/ocx-sh/ocx/releases/latest`. Echoes the target triple. |
| `server_stub_body` | Emit the body of the fixture `ocx` stub binary that gets packed into the archive. |
| `server_start ROOT LOGFILE` | Spin a python3 `ssl`-wrapped HTTP server on an ephemeral port against `ROOT`, scrape the chosen port from the log, echo `PID PORT`. Serves **HTTPS** (see below). |
| `server_stop PID` | Kill the server. |
| `server_ca_bundle` | Echo the path to the vendored localhost CA cert; export it as `CURL_CA_BUNDLE` in `setup()`. |

### HTTPS, not HTTP

The corrected installer enforces TLS on every download — curl runs with
`--proto '=https'` and the wget path calls `assert_https_url`, both of which
reject any non-`https://` URL. So the fixture server **must** speak HTTPS, and
every fixture URL the tests pass to the installer uses `https://127.0.0.1:PORT`.

A static, long-lived self-signed cert for `127.0.0.1` is vendored next to the
helper:

- `helpers/localhost-cert.pem` — the cert (also the CA); tests export it as
  `CURL_CA_BUNDLE` so curl trusts the fixture server.
- `helpers/localhost-combined.pem` — key + cert; python's `ssl` loads this to
  serve.

Trusting one specific localhost test cert via `CURL_CA_BUNDLE` is establishing
trust for the test fixture; it does **not** disable TLS verification and the
installer keeps its full `--proto '=https'` hardening. Because curl is detected
ahead of wget, the curl+`CURL_CA_BUNDLE` path is the one exercised by default.
If the cert ever expires (it is dated ~100 years out), regenerate a 127.0.0.1
self-signed cert and replace both PEMs.

### Archive layout variants

`server_build_fixture` takes a second arg:

- `nested` (default) — binary at `ocx-<target>/ocx`. Exercises the installer's
  legacy nested-extraction branch.
- `flat` — binary at the **archive root** (`ocx`). This is the real cargo-dist
  release layout that production hits, so at least one test must use it.

```bash
server_build_fixture "$root"          # nested
server_build_fixture "$root" flat     # flat (production layout)
```

### The `ocx` stub binary

The stub packed into the fixture archive (`server_stub_body`):

- answers `version` (`0.0.0`) and `about` (a plausible banner),
- emits a plausible `ocx self activate --shell=sh` PATH-export snippet,
- exits 0 for the bootstrap `--remote package install ...` call,
- **records its full argv** (one line per invocation) to the file named in
  `OCX_STUB_ARGV` when that env var is set.

The argv recording is load-bearing: it is what lets a test assert the
**exact** bootstrap call

```
--remote package install --select ocx.sh/ocx/cli:0.0.0
```

A stub that merely `exit 0`s on any `--remote` is unacceptable — it would let
the installer silently regress to the old broken `ocx --remote install --select
ocx.sh/ocx:VERSION` and the suite would still pass green.

## Install modes under test

The installer has two terminal paths; tests must pick deliberately:

| Mode | How | What happens | What to assert |
|---|---|---|---|
| **bootstrap** (default) | leave `OCX_INSTALL_SKIP_SELF_INIT` unset | runs `ocx --remote package install --select ocx.sh/ocx/cli:VERSION`, writes `$OCX_HOME/env.sh` shims. The binary is NOT copied to the canonical bin dir (the package store owns it). | the recorded bootstrap argv; `env.sh` exists and delegates to `self activate`; no legacy extensionless `env`. |
| **skip-self-init** | `OCX_INSTALL_SKIP_SELF_INIT=1` | copies the binary to `$OCX_HOME/symlinks/ocx.sh/ocx/cli/current/content/bin/ocx`, **no** bootstrap, **no** env shims. The CI/air-gapped path. | the binary is present + executable at the canonical bin dir; no bootstrap argv recorded; no `env.sh`. |

The idempotent fast-path keys off the binary being present at the canonical bin
dir, so tests for `OCX_INSTALL_FORCE` / idempotency must run in skip-self-init
mode.

## Standard `setup_file` / `setup` shape

```bash
setup_file() {
  export FIXTURE_DIR="${BATS_FILE_TMPDIR}/srv"
  FIXTURE_TARGET=$(server_build_fixture "$FIXTURE_DIR")   # nested by default
  export FIXTURE_TARGET
  local _info
  _info=$(server_start "$FIXTURE_DIR" "${BATS_FILE_TMPDIR}/server.log")
  export FIXTURE_PID="${_info% *}" FIXTURE_PORT="${_info#* }"
  export FIXTURE_URL="http://127.0.0.1:${FIXTURE_PORT}"
}
teardown_file() { server_stop "${FIXTURE_PID:-}"; }

setup() {
  export OCX_HOME="${BATS_TEST_TMPDIR}/.ocx"
  export OCX_NO_MODIFY_PATH=1
  export CURL_CA_BUNDLE; CURL_CA_BUNDLE="$(server_ca_bundle)"   # trust fixture cert
  export OCX_STUB_ARGV="${BATS_TEST_TMPDIR}/stub-argv.log"
  export OCX_INSTALL_BASE_URL="${FIXTURE_URL}/releases/download"  # https://127.0.0.1:...
  export OCX_INSTALL_API_URL="${FIXTURE_URL}/api/repos/ocx-sh/ocx/releases"
  unset OCX_INSTALL_FORMAT_URL OCX_INSTALL_CHECKSUM_FORMAT_URL GITHUB_PATH
  unset OCX_INSTALL_SKIP_SELF_INIT
}
```

`FIXTURE_URL` is `https://127.0.0.1:${FIXTURE_PORT}` (set in `setup_file`).

The canonical bin subpath asserted in tests is
`symlinks/ocx.sh/ocx/cli/current/content/bin` (mirrors `OCX_BIN_SUBPATH` in
`sh/install.sh`). Never assert the old `ocx/current/bin`.

## Conventions

- One assertion per test where possible. Bats does not stop on the first failure within a test, but failing fast keeps signals readable.
- Use `run` for commands that may fail — never bare `sh/install.sh`. `run` captures stderr+stdout+exit.
- Assert exit code AND output when both are meaningful. Exit-only assertions miss regressions in messaging. For the bootstrap path, assert the recorded argv, not just the exit code.
- Tests must not require network. The runtime fixture server (HTTPS, localhost) is the only network endpoint allowed.

## When to update tests

| Change | Tests to add/update |
|---|---|
| New env knob | `env-knobs.bats` — happy path + invalid value |
| New exit code | `exit-codes.bats` — at least one triggering scenario |
| Stdout/stderr change | `print-path.bats` — verify the discipline still holds |
| New flag | `env-knobs.bats` — long form parses, short form (if any) parses |
| Bin-path / bootstrap-command / env-file change | flip the path string in all three `.bats`, update the `server_stub_body` argv assertion, update this file |
| New archive layout | add a `server_build_fixture ... <layout>` variant + a test |
