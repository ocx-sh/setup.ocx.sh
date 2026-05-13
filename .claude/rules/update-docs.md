# Update docs

Keep `README.md` and `CONTRIBUTING.md` in sync when the project shape changes.

## README.md

The README is the front door for `curl | sh` users. Update when:

- **Curl one-liners** — installer URL, env-var overrides change
- **Env-var matrix** — `OCX_INSTALL_*` knob added, removed, or renamed in `sh/install.sh` or `pwsh/install.ps1`
- **Exit-code table** — code added, removed, or its meaning changes
- **Stdout/stderr contract** — discipline changes (which would be a major version bump)

## CONTRIBUTING.md

The CONTRIBUTING guide is for developers landing a PR. Update when:

- **Prerequisites** — a new tool dependency is introduced (Task, OCX, pwsh, docker buildx, etc.)
- **Layout table** — top-level dir is added/removed
- **Running tests** — `task` names change in `taskfile.yml`
- **Commit conventions** — git-cliff parser rules change in `cliff.toml`

## CLAUDE.md

The CLAUDE.md surfaces table must reflect reality. Update when a top-level dir is added/removed.
