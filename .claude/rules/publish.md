# Publish rules

The installer-publish pipeline owns one job: keep `setup.ocx.sh` serving the latest set of installer scripts at predictable URLs. This file documents the contract.

## URL layout

```
setup.ocx.sh/sh/install.sh                 # latest pointer (mutable)
setup.ocx.sh/sh/<VERSION>/install.sh       # pinned (immutable, append-only)
setup.ocx.sh/pwsh/install.ps1              # latest pointer (mutable)
setup.ocx.sh/pwsh/<VERSION>/install.ps1    # pinned (immutable, append-only)
```

`<VERSION>` is the semver string without a leading `v` (e.g. `2.0.1`, not `v2.0.1`).

**Forwarded paths** (handled by nginx, *not* this repo):

```
setup.ocx.sh/docs/...      → ocx.sh/docs/...
setup.ocx.sh/actions/...   → GitHub Marketplace / GitLab CI Catalog
```

Never publish a file under a path that nginx will reroute — it just confuses caches.

## rsync flags (see `scripts/publish-installers.sh`)

- Pinned versioned uploads use `--ignore-existing` so a re-run of a release tag never silently overwrites a previously published artifact. If you ever need to overwrite, do it by hand, then audit the cache invalidation downstream.
- Latest pointers overwrite freely. They **never** use `--delete` — adjacent versioned dirs must be preserved.
- All transfers happen over SSH with a deploy key (`SETUP_OCX_DEPLOY_KEY` secret) bound to the `setup.ocx.sh` environment. The key is single-purpose; it has no shell, no sudo, no read access outside the docroot.

## Versioned vs latest

Latest is a **convenience** for `curl ... | sh`; production CI pins. Therefore:

- A bug in `install.sh` published to `<VERSION>/` requires a new version (you can't unpublish — immutable). The latest pointer should be moved off the bad version immediately, and a yanked-marker (`install.sh.yanked`) can be uploaded to the pinned dir as a soft warning. CI tooling can probe for it.
- `latest` always tracks the highest semver tag with a release, never a prerelease.

## Pre-release smoke

Before tagging:

```bash
task publish:dry-run    # rsync --dry-run, no upload
```

After tagging, the release workflow handles upload. Verify post-release:

```bash
curl -fsSL https://setup.ocx.sh/sh/<VERSION>/install.sh | sh -s -- --version
curl -fsSL https://setup.ocx.sh/sh/latest/install.sh   | sh -s -- --version
```
