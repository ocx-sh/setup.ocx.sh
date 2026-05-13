<div align="center">
  <img src="assets/logo.svg" alt="OCX" width="120" />

# setup.ocx.sh

Canonical hosting for the [OCX](https://ocx.sh) installer scripts.

</div>

`setup.ocx.sh` serves two files:

```
https://setup.ocx.sh/sh/install.sh             # POSIX (Linux + macOS)
https://setup.ocx.sh/pwsh/install.ps1          # PowerShell (Windows + cross-platform pwsh)
```

Every release also publishes pinned, immutable copies at:

```
https://setup.ocx.sh/sh/<VERSION>/install.sh
https://setup.ocx.sh/pwsh/<VERSION>/install.ps1
```

The GitHub Action and GitLab Function listings live in **separate repositories** so they can publish to the native GitHub Marketplace and GitLab CI Catalog. Documentation paths (`/docs/*`) and action paths (`/actions/*`) on `setup.ocx.sh` are forwarded by nginx to those upstream surfaces.

## Quick start

### Linux / macOS

```sh
# Latest:
curl -fsSL https://setup.ocx.sh/sh/install.sh | sh

# Pinned version:
curl -fsSL https://setup.ocx.sh/sh/install.sh | sh -s -- --version 0.5.0

# Pinned install URL (recommended for CI):
curl -fsSL https://setup.ocx.sh/sh/0.5.0/install.sh | sh
```

### Windows / PowerShell

```powershell
# Latest:
irm https://setup.ocx.sh/pwsh/install.ps1 | iex

# Pinned version:
& { iex "$(irm https://setup.ocx.sh/pwsh/install.ps1)" } -Version 0.5.0
```

## Configuration

Both installers read environment variables to override defaults. The `OCX_INSTALL_*` prefix scopes them to install-time; runtime envs (`OCX_HOME`, `OCX_NO_MODIFY_PATH`, `GITHUB_TOKEN`, `NO_COLOR`, `TMPDIR`) keep their existing names.

| Variable | Purpose | Default |
|---|---|---|
| `OCX_INSTALL_REPO` | GitHub repo to install from | `ocx-sh/ocx` |
| `OCX_INSTALL_BASE_URL` | Release download base URL | `https://github.com/<repo>/releases/download` |
| `OCX_INSTALL_API_URL` | GitHub Releases API base | `https://api.github.com/repos/<repo>/releases` |
| `OCX_INSTALL_FORMAT_URL` | URL template for the archive (`{version}`, `{tag}`, `{target}`, `{ext}`) | `{base}/{tag}/ocx-{target}.{ext}` |
| `OCX_INSTALL_CHECKSUM_FORMAT_URL` | URL template for `sha256.sum` | `{base}/{tag}/sha256.sum` |
| `OCX_INSTALL_SKIP_BOOTSTRAP` | Skip `ocx --remote install` after extract (set `1` in air-gapped / offline envs) | `0` |
| `OCX_INSTALL_PRINT_PATH` | Emit the bin dir as the final stdout line | `0` |
| `OCX_INSTALL_FORCE` | Reinstall even if the target version is already present | `0` |
| `OCX_INSTALL_QUIET` | Suppress informational stderr output | `0` |
| `OCX_INSTALL_DOWNLOADER` | Force a downloader (`curl` or `wget`); default auto-detects | _(auto)_ |

The full list lives in `sh/install.sh` (and `pwsh/install.ps1`); see [`.claude/rules/installers.md`](.claude/rules/installers.md) for the naming + parity rules.

## Stdout / stderr contract

- All informational, warning, and error output goes to **stderr**.
- **Stdout is silent on success** unless `OCX_INSTALL_PRINT_PATH=1` (or `-PrintPath`), in which case the final stdout line is the absolute OCX bin dir.

This contract lets downstream callers do:

```sh
BIN_DIR=$(OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 curl -fsSL https://setup.ocx.sh/sh/install.sh | sh | tail -n1)
export PATH="$BIN_DIR:$PATH"
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Generic / legacy fallback |
| 2 | Argument or environment validation |
| 3 | Network / download / API failure |
| 4 | Checksum mismatch |
| 5 | Archive extraction failure |
| 6 | Bootstrap (`ocx --remote install`) failure |
| 7 | Unsupported platform / architecture |

## Development

```sh
task verify                                    # lint + Bats + Pester
task test:bats                                 # only Bats
task test:pester                               # only Pester (needs pwsh + Pester)
task docker:integration DISTRO=alpine PLATFORM=linux/amd64
task docker:integration:all                    # full 3×2 matrix (needs buildx + QEMU)
task publish:dry-run                           # validate rsync paths
```

[`CONTRIBUTING.md`](CONTRIBUTING.md) covers prerequisites and the PR flow. [`CLAUDE.md`](CLAUDE.md) is the AI-collaboration entry point.

## License

[Apache-2.0](LICENSE)
