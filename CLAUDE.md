# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

`setup.ocx.sh` is the canonical website hosting the **shell installers** that bring [OCX](https://ocx.sh) to CI runners, developer machines, and Linux servers. Every published path is one of these installers:

```
setup.ocx.sh/sh/{VERSION,latest}/install.sh
setup.ocx.sh/pwsh/{VERSION,latest}/install.ps1
```

This repo owns those two files (and their release pipeline). The GitHub Action lives in `ocx-sh/setup-ocx` (GitHub Marketplace); the GitLab Function lives in its own repo (GitLab CI Catalog). Documentation paths (`/docs/...`) and action paths (`/actions/...`) on `setup.ocx.sh` are forwarded by nginx to those upstreams.

## Surfaces

| Path | Responsibility |
|---|---|
| `sh/install.sh` | Canonical POSIX installer (Linux + macOS). Env knobs `OCX_INSTALL_*`, exit codes 0–7, stderr-only logging |
| `pwsh/install.ps1` | Canonical PowerShell installer (Windows). Mirrors the sh env knobs |
| `scripts/publish-installers.sh` | rsync to `setup.ocx.sh:{sh,pwsh}/{VERSION,latest}/` |
| `tests/install/*.bats` | Bats env-knob, exit-code, print-path suites |
| `tests/install/ps1/*.Tests.ps1` | Pester equivalents |
| `tests/docker/` | Distro × arch integration matrix harness |
| `.github/workflows/` | verify, test-installers, test-docker-matrix, release |

## Commands

All tasks run through [Task](https://taskfile.dev). Tools come from OCX (no local install needed):

```bash
task verify                                # lint + bats + pester
task shell:verify                          # shellcheck + shfmt
task pwsh:verify                           # PSScriptAnalyzer (needs pwsh on PATH)
task test:bats                             # bats env-knob + exit-code + print-path suites
task test:pester                           # Pester (needs pwsh + Pester module)
task docker:integration DISTRO=alpine PLATFORM=linux/amd64
task docker:integration:all                # full 3×2 matrix
task publish:dry-run                       # validates rsync paths

task release:prepare                       # git-cliff bump + changelog + tag locally
```

## Stdout / stderr contract

`sh/install.sh` and `pwsh/install.ps1`:

- All informational / warning / error messages go to **stderr**.
- **stdout** is silent on success unless `OCX_INSTALL_PRINT_PATH=1` (or `-PrintPath`), in which case the **final stdout line** is the absolute OCX bin dir.

This contract is load-bearing for downstream wrappers that do `BIN_DIR=$(./install.sh | tail -n1)`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Generic / legacy |
| 2 | Argument or environment validation |
| 3 | Network / download / API failure |
| 4 | Checksum mismatch |
| 5 | Archive extraction failure |
| 6 | Bootstrap (`ocx --remote install`) failure |
| 7 | Unsupported platform / architecture |

Pick the most specific code when calling `err()`. Reusing codes across unrelated failures breaks downstream CI diagnostics.

## Testing tiers

1. **Bats** (`tests/install/*.bats`) — fixture HTTP server spun via `python3 -m http.server`, exercises env knobs, exit-code paths, stdout/stderr discipline.
2. **Pester** (`tests/install/ps1/*.Tests.ps1`) — symmetric coverage for the PowerShell installer.
3. **Docker matrix** (`tests/docker/run.sh`) — real distros, real upstream releases:
   - **Alpine** (musl) — `linux/amd64`, `linux/arm64`
   - **Fedora** (glibc, dnf) — `linux/amd64`, `linux/arm64`
   - **Ubuntu** (glibc, apt) — `linux/amd64`, `linux/arm64`

Cross-installer parity is enforced manually: any change to `sh/install.sh` must be mirrored in `pwsh/install.ps1` (and tests) in the same PR. See `.claude/rules/installers.md`.

## Releases

- Conventional Commits drive versioning via [git-cliff](https://git-cliff.org).
- `task release:prepare` produces the version commit + tag locally; pushing the tag triggers `.github/workflows/release.yml`.
- The release workflow does: gh release (git-cliff notes) → `publish-installers` job (rsync via `SETUP_OCX_DEPLOY_KEY`).

| Prefix | Purpose | Version bump (post-1.0) |
|---|---|---|
| `feat:` | New feature | minor |
| `fix:` | Bug fix | patch |
| `feat!:` / `fix!:` / `BREAKING CHANGE` | Breaking change | major |
| `perf:` | Performance improvement | patch |
| `refactor:` | Code restructuring | — |
| `docs:` / `test:` / `ci:` / `build:` / `chore:` | No bump | — |

Scopes are optional: `feat(install): add OCX_INSTALL_FORMAT_URL`.

**Do not** add `Co-Authored-By` trailers or attribution lines to commits or PRs.

## Required release secrets

| Secret | Used by |
|---|---|
| `SETUP_OCX_DEPLOY_KEY` | `publish-installers` rsync to `setup.ocx.sh` |

## Deep context

- [`.claude/rules/installers.md`](.claude/rules/installers.md) — env-knob naming, stdout discipline, exit-code matrix
- [`.claude/rules/publish.md`](.claude/rules/publish.md) — rsync flags, versioned-vs-latest path layout
- [`.claude/rules/testing-bash.md`](.claude/rules/testing-bash.md) — Bats + fixture HTTP server patterns
- [`.claude/rules/testing-pwsh.md`](.claude/rules/testing-pwsh.md) — Pester patterns
- [`.claude/rules/workflow-release.md`](.claude/rules/workflow-release.md) — git-cliff → tag → publish flow
- [`.claude/rules/update-docs.md`](.claude/rules/update-docs.md) — keep README/CLAUDE in sync
