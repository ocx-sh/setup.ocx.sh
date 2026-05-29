# PowerShell testing rules (Pester)

## Layout

```
tests/install/ps1/
├── Fixture.psm1          # Shared fixture builder + http.server harness (imported by all suites)
├── Knobs.Tests.ps1       # OCX_INSTALL_* env var behavior (mirrors env-knobs.bats)
├── ExitCodes.Tests.ps1   # Numbered exit-code paths 5/6 + bootstrap-argv (mirrors exit-codes.bats)
└── PrintPath.Tests.ps1   # Stdout/stderr discipline + -PrintPath (mirrors print-path.bats)
```

All three suites exist and run today. `Fixture.psm1` is the PowerShell analogue of
`tests/install/helpers/server.bash`: it builds the fake GitHub-release tree and
spins the fixture HTTP server so the suites stay DRY.

## Conventions

- Use Pester v5 (`New-PesterConfiguration` API; no v3-style globals).
- Run with: `Invoke-Pester -Configuration (New-PesterConfiguration -Hashtable @{ Run = @{ Path = 'tests/install/ps1' } })`, or via `task pwsh:test` / the CI Pester step.
- One `It` per scenario. Top-level `BeforeAll` builds one fixture + server per file; `BeforeEach` resets a fresh `OCX_HOME` and the env knobs.
- Build the fixture and server through `Fixture.psm1` (`New-OcxFixture`, `Start-FixtureServer`), not ad-hoc inside each `It`.
- Test against the **environment-variable form** of every knob first, then the flag form. The env form is the contract; flags are sugar.

## Fixture harness (`Fixture.psm1`)

Three things the harness gets right that a naive `python -m http.server` does not:

1. **FLAT archive layout.** The release `.zip` puts `ocx.exe` at the archive
   root (no `ocx-<target>/` wrapper dir), matching the real cargo-dist release.
   This is also the only layout that resolves on a non-Windows pwsh host:
   `Join-Path` treats `\` as a literal on Linux, so the installer's nested
   candidate `ocx-<target>\ocx.exe` never matches an extracted
   `ocx-<target>/ocx.exe` there — only the flat `ocx.exe` candidate hits.
2. **JSON content-type for `latest`.** A bare `http.server` serves the
   extensionless `latest` file as `application/octet-stream`, which makes
   `Invoke-WebRequest.Content` a `byte[]` and breaks `Get-LatestVersion`'s
   regex. The harness launches a one-file server that forces `application/json`
   on the `latest` endpoint, faithful to GitHub.
3. **Separate stdout/stderr log files.** `Start-Process` on Linux pwsh refuses
   to redirect both streams to the same file; the harness always passes two.

The canonical bin dir asserted everywhere is
`symlinks/ocx.sh/ocx/cli/current/content/bin` (the real on-disk store layout),
via `Get-ExpectedBinDir`. The skip-self-init knob is **`OCX_INSTALL_SKIP_SELF_INIT`**
(not the legacy `OCX_INSTALL_SKIP_BOOTSTRAP`).

## Cross-platform execution (windows-latest vs ubuntu-pwsh)

The installer is Windows-only by intent, but most paths execute meaningfully on
ubuntu-pwsh because `Detect-Architecture` keys off `RuntimeInformation`
(returns the `*-pc-windows-msvc` target on any X64 host) and the suites set
`OCX_HOME` explicitly (so the `$env:USERPROFILE` default is never needed).

Tests that must **execute the extracted `ocx.exe`** are gated `-Skip:(-not $IsWindows)`:

- `ExitCodes.Tests.ps1`: the exit-6 bootstrap-failure test and the
  bootstrap-argv assertion. On Linux the extracted binary has no `+x` bit
  (install.ps1 never chmods — Windows does not need it), so `& $bin ...` fails
  before reaching the bootstrap call. The argv string asserted is the exact
  corrected form: `--remote package install --select ocx.sh/ocx/cli:<version>`
  (regression guard against the hallucinated `--remote install ... ocx.sh/ocx`).

The idempotent fast-path branch likewise probes `& ocx.exe version`, which only
runs on Windows; on Linux the second install does a full reinstall instead, but
the observable contract the Bats test asserts (exit 0 + identical print-path)
still holds, so that scenario stays un-gated.

`OCX_INSTALL_DOWNLOADER` has no Pester mirror by design — it is sh-only
(install.ps1 always uses `Invoke-WebRequest`).

## Parity with Bats

Every Bats test has a matching Pester test (same scenario, mirrored name):

| Bats | Pester suite |
|---|---|
| `env-knobs.bats` | `Knobs.Tests.ps1` |
| `exit-codes.bats` | `ExitCodes.Tests.ps1` |
| `print-path.bats` | `PrintPath.Tests.ps1` |

The cross-installer parity rule (`installers.md`) requires it: when you add a
Bats scenario, add the same-named scenario in the matching Pester suite. Exit
code 7 (unsupported platform) cannot be triggered on an X64 host in either
suite — it is exercised by `tests/docker/`.

CI matrix runs Bats on ubuntu + macos and Pester on windows-latest +
ubuntu-latest with pwsh installed.
