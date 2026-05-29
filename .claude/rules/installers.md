# Installer rules (sh/install.sh + pwsh/install.ps1)

These rules govern the canonical shell installers. They are the load-bearing artifacts published to `setup.ocx.sh` and consumed by the GitHub Action and GitLab Function repos (which live in separate marketplaces). Be conservative.

## Env-knob naming

All knobs that influence the *install process* (URLs, mirror config, behavioral toggles) use the `OCX_INSTALL_*` prefix. They are scoped to install-time and must not collide with the `OCX_*` runtime envs the OCX binary itself consumes.

User-facing settings that survive after install (`OCX_HOME`, `OCX_NO_MODIFY_PATH`, `GITHUB_TOKEN`, `NO_COLOR`, `TMPDIR`) keep their existing names — they are not install-only.

When introducing a new knob:

- Pick the most boring possible name (Bazelisk-shaped: `OCX_INSTALL_<NOUN>` or `OCX_INSTALL_<VERB>`).
- Default to the empty string or `0` so existing pipelines don't change behavior.
- Document it in `README.md` (env-var matrix) and `tests/install/env-knobs.bats` (if testable).
- Mirror in `pwsh/install.ps1` (same env name, optionally a `[switch]` parameter that the env overrides).

Current install-time knobs include the Bazelisk-style mirror set (`OCX_INSTALL_REPO`, `OCX_INSTALL_BASE_URL`, `OCX_INSTALL_API_URL`, `OCX_INSTALL_FORMAT_URL`, `OCX_INSTALL_CHECKSUM_FORMAT_URL`) plus the behavioral toggles `OCX_INSTALL_SKIP_SELF_INIT`, `OCX_INSTALL_PRINT_PATH`, `OCX_INSTALL_FORCE`, `OCX_INSTALL_QUIET`, `OCX_INSTALL_NO_BIN_SMOKETEST`, and (sh-only) `OCX_INSTALL_DOWNLOADER`. The mirror knobs are a deliberate repo value-add that the canonical ocx.sh installer does not carry — preserve them.

Truthy values: `1`, `true`, `yes`, `TRUE`, `YES`, `True`, `Yes`. Anything else is falsy.

## Stdout / stderr discipline (load-bearing)

`sh/install.sh` and `pwsh/install.ps1` must follow this contract:

- All informational, warning, and error output goes to **stderr**.
- **stdout** is silent on success unless `OCX_INSTALL_PRINT_PATH=1` (or `-PrintPath`), in which case the **final stdout line** is the absolute path to the OCX bin dir.
- The success banner / "installed to ..." text is informational and goes to **stderr**, not stdout.

This contract is what lets downstream callers do `BIN_DIR=$(./install.sh | tail -n1)`. Breaking it breaks GLF + every wrapper that depends on a clean stdout.

## Exit codes (stable contract)

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Generic / legacy fallback |
| 2 | Argument or environment validation failure |
| 3 | Network / download / API failure |
| 4 | Checksum mismatch |
| 5 | Archive extraction failure |
| 6 | Bootstrap (`ocx --remote package install`) failure |
| 7 | Unsupported platform / architecture |

When `err()` is called from a new code path, choose the most specific code. Adding new codes is fine; reusing them across unrelated failure modes is not — it breaks the diagnostic value for CI scripts.

### Accepted divergence: unknown-argument exit code

The exit-code contract above (codes 2–7 for in-script `err()` paths) holds identically on both installers. There is one **accepted, justified divergence** in the unknown-argument path:

- **sh** — an unknown option is caught by the `case "$1" in … *)` arm in `main()` and routed through `err "unknown option: …" 2`, so it exits **2** (argument validation), consistent with the rest of the contract.
- **pwsh** — an unknown flag (e.g. `-BogusFlag`) is rejected by the `[CmdletBinding()]` param binder *before* `Main` ever runs. The binder owns unknown-argument rejection and exits **1**; it has no hook to emit code 2. When the script is consumed through the `irm … | iex` (or `[scriptblock]::Create`) idiom, the parser/binder error surfaces but the pipeline yields **no deterministic exit code** — callers must not rely on a specific number there.

This divergence is accepted because PowerShell parameter binding owns unknown-argument rejection and structurally cannot emit code 2 — the rejection happens before any in-script `Err` (the pwsh analogue of `err`) can run. Every exit code that *is* produced by an in-script error path (2–7) remains symmetric across both installers; only the binder-level "unknown flag" case differs (sh `2` vs pwsh `1`/indeterminate).

## Cross-installer parity

`sh/install.sh` and `pwsh/install.ps1` are independent implementations of the same spec. Whenever you change one, change the other in the same PR:

- New env knob → both
- New exit code → both
- New flag → both (`--foo` ↔ `-Foo`)
- Behavioral default change → both

Tests in `tests/install/env-knobs.bats` (POSIX) and `tests/install/ps1/Knobs.Tests.ps1` (Pester) enforce this through symmetric coverage.

## Bootstrap dependency

`bootstrap_ocx()` runs `ocx --remote package install --select ocx.sh/ocx/cli:$version`, which contacts the public ocx.sh registry. (`ocx` 0.3.1 has **no** `ocx install` subcommand; the self-init verb is `ocx --remote package install`, where `--select`/`-s` is a boolean "set as current" flag and the package id `ocx.sh/ocx/cli:$version` is positional.) This is the default for end-user installs.

CI use cases (especially air-gapped enterprises) **must** be able to skip the networked step via `OCX_INSTALL_SKIP_SELF_INIT=1`. With it set, the installer drops the binary into the canonical OCX bin dir directly — `${OCX_HOME}/symlinks/ocx.sh/ocx/cli/current/content/bin` — so `ocx` is on PATH, but it does **not** run the networked `ocx --remote package install` that would populate the package store. This is the binary-on-PATH semantics: enough for wrappers that just invoke the binary, not a full self-resolvable package-store install.

The bin dir (`${OCX_HOME}/symlinks/ocx.sh/ocx/cli/current/content/bin`) is also what `OCX_INSTALL_PRINT_PATH` emits and what PATH activation, the generated env file, and the idempotent fast-path all reference.

When changing bootstrap logic, ensure both code paths are covered by the Bats + Pester suites.
