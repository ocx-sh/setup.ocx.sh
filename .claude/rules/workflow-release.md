# Release workflow

## Local steps

1. `git checkout main && git pull`
2. `task release:prepare` — computes next version from conventional commits, regenerates `CHANGELOG.md`, runs `task verify`.
3. Review the diff. Adjust `CHANGELOG.md` if `git-cliff` mis-grouped something.
4. Commit and tag:
   ```bash
   git add -A
   git commit -m "release: vX.Y.Z"
   git tag vX.Y.Z
   ```
5. Push both:
   ```bash
   git push origin main
   git push origin vX.Y.Z
   ```

The tag push triggers `.github/workflows/release.yml`.

## What the release workflow does

| Job | Action |
|---|---|
| `release` | Generates GitHub release notes from git-cliff `--latest`, creates the release |
| `publish-installers` | rsyncs `sh/install.sh` + `pwsh/install.ps1` to `setup.ocx.sh/{sh,pwsh}/{vX.Y.Z,latest}/` using `SETUP_OCX_DEPLOY_KEY` |

Both jobs run on every `v*` tag. There is no mirror-to-GitLab step — the GLF lives in a separate repo now.

## Version policy

The project is **pre-release**: there are zero git tags and nothing has shipped yet. The first release will cut the initial tag. Once versioning starts, the conventional-commit → bump mapping is:

- `feat:` → minor
- `fix:`, `perf:` → patch
- `feat!:` / `fix!:` / `BREAKING CHANGE:` → major
- Everything else → no bump

(Pre-1.0 SemVer convention — breaking changes may be folded into minor bumps — is at the maintainer's discretion until the line is settled at the first release.)

## What never goes in a release commit

- `Co-Authored-By:` trailers
- Attribution lines
- Anything `git-cliff` can't parse as conventional — it'll either be dropped or grouped under "Other"
