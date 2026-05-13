# PowerShell testing rules (Pester)

## Layout

```
tests/install/ps1/
├── Knobs.Tests.ps1       # OCX_INSTALL_* env var behavior (mirrors env-knobs.bats)
├── ExitCodes.Tests.ps1   # Each numbered exit code path 2..7
└── PrintPath.Tests.ps1   # Stdout/stderr discipline + -PrintPath
```

## Conventions

- Use Pester v5 (`New-PesterConfiguration` API; no v3-style globals).
- One `It` per scenario. `BeforeEach` spins the fixture HTTP server (the Bats fixtures double as the source of truth — Pester reuses `tests/install/fixtures/`).
- Spin the fixture server with `Start-Job` running `python -m http.server`. Kill it in `AfterEach`.
- Test against the **environment-variable form** of every knob first, then the flag form. The env form is the contract; flags are sugar.

## Parity with Bats

Every Bats test must have a matching Pester test (same name, same scenario). The cross-installer parity rule (`installers.md`) requires it. If you add `env-knobs.bats:OCX_INSTALL_FORMAT_URL works against private S3 mirror`, also add the same scenario name in `Knobs.Tests.ps1`.

CI matrix runs Bats on ubuntu + macos and Pester on windows-latest + ubuntu-latest with pwsh installed.
