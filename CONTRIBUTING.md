# Contributing

Thanks for helping land changes to the canonical OCX installer scripts.

## Prerequisites

- [Task](https://taskfile.dev) — task runner.
- [OCX](https://ocx.sh) — bootstraps every linter and test tool used here. After installing OCX, run `task ocx:index-update` once to populate `.ocx/index/`.
- `pwsh` — PowerShell 7+. Needed for Pester tests and PSScriptAnalyzer.
- `python3` — used by the Bats fixture HTTP server.
- `docker` with `buildx` and (for non-native arches) QEMU binfmt handlers — required for `tests/docker/`. Run `task docker:qemu:register` to install handlers on Linux hosts.

## Layout

```
sh/install.sh                Canonical POSIX installer (Linux + macOS)
pwsh/install.ps1             Canonical PowerShell installer (Windows + pwsh)
scripts/publish-installers.sh   rsync to setup.ocx.sh:{sh,pwsh}/{VERSION,latest}/
tests/install/*.bats         Bats env-knob / exit-code / print-path suites
tests/install/ps1/*.ps1      Pester equivalents
tests/install/helpers/       Shared fixture HTTP server helpers
tests/docker/                Distro × arch integration matrix (alpine, fedora, ubuntu)
taskfile.yml + taskfiles/    Task automation (lint, test, release, publish)
.claude/                     AI rules + permissions (Claude Code)
.github/workflows/           CI: verify, test-installers, test-docker-matrix, release
```

## Running tests

```sh
task verify                                                   # lint + Bats + Pester
task test:bats                                                # Bats only
task test:pester                                              # Pester only (needs pwsh)
task docker:integration DISTRO=alpine PLATFORM=linux/amd64    # one distro × arch
task docker:integration:all                                   # full matrix (3 × 2 = 6 jobs)
```

The Bats suite spins a `python3 -m http.server` against fixture release tarballs in `${BATS_FILE_TMPDIR}`. No network access is required.

The docker matrix downloads real OCX releases from `github.com/ocx-sh/ocx`. Set the `VERSION` argument to pin against a specific tag:

```sh
tests/docker/run.sh fedora linux/arm64 0.5.0
```

## Commit conventions

This repo uses Conventional Commits parsed by [git-cliff](https://git-cliff.org/) (see `cliff.toml`). Recognised prefixes:

| Prefix | Purpose | Version bump (post-1.0) |
|---|---|---|
| `feat:` | New feature | minor |
| `fix:` | Bug fix | patch |
| `feat!:` / `fix!:` / `BREAKING CHANGE:` | Breaking change | major |
| `perf:` | Performance improvement | patch |
| `refactor:` | Code restructuring | — |
| `docs:` / `test:` / `ci:` / `build:` / `chore:` | No bump | — |

Scopes are optional: `feat(install): add OCX_INSTALL_FORMAT_URL`.

The PR workflow runs `cocogitto check-latest-tag-only`; commits that aren't conventional will fail the gate.

**Do not** add `Co-Authored-By:` trailers, attribution lines, or any similar metadata to commits or PRs.

## Cross-installer parity

`sh/install.sh` and `pwsh/install.ps1` are independent implementations of the same spec. When you change one, change the other in the same PR — and update the matching Bats + Pester scenarios. See [`.claude/rules/installers.md`](.claude/rules/installers.md) for the full rule.

## Releases

Releases are tag-driven:

```sh
task release:prepare       # git-cliff bump + CHANGELOG + verify
git add -A && git commit -m "release: vX.Y.Z"
git tag vX.Y.Z
git push origin main && git push origin vX.Y.Z
```

The tag push triggers `release.yml`, which creates the GitHub release and rsyncs the installers to `setup.ocx.sh`. See [`.claude/rules/workflow-release.md`](.claude/rules/workflow-release.md) for the full flow.
