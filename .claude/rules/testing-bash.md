# Bash testing rules (Bats)

## Layout

```
tests/install/
├── env-knobs.bats        # OCX_INSTALL_* env var behavior
├── exit-codes.bats       # Each numbered exit code path 2..7
├── print-path.bats       # Stdout/stderr discipline + OCX_INSTALL_PRINT_PATH
└── fixtures/             # Tarballs + sha256.sum for the fixture HTTP server
```

## Fixture HTTP server

Tests spin up a `python3 -m http.server` against `tests/install/fixtures/`. The fixtures mimic the GitHub release layout: `ocx-<target>.<ext>` + a `sha256.sum` per "release". Setting `OCX_INSTALL_BASE_URL=http://127.0.0.1:<port>` redirects the installer at that fixture tree.

Standard `setup()` shape:

```bash
setup() {
  TMPDIR_TEST="$(mktemp -d)"
  cp -r "${BATS_TEST_DIRNAME}/fixtures/." "${TMPDIR_TEST}/"
  PORT="$((20000 + RANDOM % 10000))"
  ( cd "${TMPDIR_TEST}" && python3 -m http.server "${PORT}" >/dev/null 2>&1 & )
  echo $! > "${TMPDIR_TEST}/.pid"
  export OCX_INSTALL_BASE_URL="http://127.0.0.1:${PORT}"
  export OCX_HOME="${TMPDIR_TEST}/home"
  export OCX_INSTALL_SKIP_BOOTSTRAP=1
}

teardown() { kill "$(cat "${TMPDIR_TEST}/.pid")" 2>/dev/null || :; rm -rf "${TMPDIR_TEST}"; }
```

## Conventions

- One assertion per test where possible. Bats does not stop on the first failure within a test, but failing fast keeps signals readable.
- Use `run` for commands that may fail — never bare `sh/install.sh`. `run` captures stderr+stdout+exit.
- Assert exit code AND output when both are meaningful. Exit-only assertions miss regressions in messaging.
- Tests must not require network. The fixture server is the only HTTP allowed.

## When to update tests

| Change | Tests to add/update |
|---|---|
| New env knob | `env-knobs.bats` — happy path + invalid value |
| New exit code | `exit-codes.bats` — at least one triggering scenario |
| Stdout/stderr change | `print-path.bats` — verify the discipline still holds |
| New flag | `env-knobs.bats` — long form parses, short form (if any) parses |
