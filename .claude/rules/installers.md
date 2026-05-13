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
| 6 | Bootstrap (`ocx --remote install`) failure |
| 7 | Unsupported platform / architecture |

When `err()` is called from a new code path, choose the most specific code. Adding new codes is fine; reusing them across unrelated failure modes is not — it breaks the diagnostic value for CI scripts.

## Cross-installer parity

`sh/install.sh` and `pwsh/install.ps1` are independent implementations of the same spec. Whenever you change one, change the other in the same PR:

- New env knob → both
- New exit code → both
- New flag → both (`--foo` ↔ `-Foo`)
- Behavioral default change → both

Tests in `tests/install/env-knobs.bats` (POSIX) and `tests/install/ps1/Knobs.Tests.ps1` (Pester) enforce this through symmetric coverage.

## Bootstrap dependency

`bootstrap_ocx()` runs `ocx --remote install --select ocx.sh/ocx:$version`, which contacts the public ocx.sh registry. This is the default for end-user installs. CI use cases (especially air-gapped enterprises) **must** be able to skip this step via `OCX_INSTALL_SKIP_BOOTSTRAP=1` — the installer then drops the binary into the canonical `~/.ocx/symlinks/.../current/bin` location directly.

When changing bootstrap logic, ensure both code paths are covered by the Bats + Pester suites.
