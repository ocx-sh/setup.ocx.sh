#!/bin/sh
# publish-installers.sh — rsync hardened installers to setup.ocx.sh.
#
# Versioned files (sh/$VERSION/install.sh, pwsh/$VERSION/install.ps1) are
# uploaded with --ignore-existing so a re-run of a release tag never
# silently overwrites a previously published artifact.
#
# Latest pointers (sh/install.sh, pwsh/install.ps1) overwrite freely but
# never use --delete (so sibling versioned dirs are preserved).
#
# Required env: VERSION (no leading v), SSH_KEY (path), SETUP_OCX_HOST.
# Optional env: SSH_PORT (default 22), DRY_RUN=1.

set -eu

: "${VERSION:?VERSION is required (e.g. 1.2.3, no leading v)}"
: "${SSH_KEY:?SSH_KEY (path to private key) is required}"
: "${SETUP_OCX_HOST:=setup.ocx.sh}"

SSH_PORT="${SSH_PORT:-22}"
DRY_RUN="${DRY_RUN:-0}"

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SH="$REPO_ROOT/sh/install.sh"
PS1="$REPO_ROOT/pwsh/install.ps1"

[ -f "$SH"  ] || { echo "publish-installers: $SH missing"  >&2; exit 1; }
[ -f "$PS1" ] || { echo "publish-installers: $PS1 missing" >&2; exit 1; }

RSYNC_OPTS="-avz"
[ "$DRY_RUN" = "1" ] && RSYNC_OPTS="$RSYNC_OPTS --dry-run"
SSH_CMD="ssh -i $SSH_KEY -p $SSH_PORT -o StrictHostKeyChecking=accept-new"

echo "publish-installers: VERSION=$VERSION HOST=$SETUP_OCX_HOST DRY_RUN=$DRY_RUN"

# Pinned (immutable, append-only):
# shellcheck disable=SC2086
rsync $RSYNC_OPTS --ignore-existing -e "$SSH_CMD" \
    "$SH"  "${SETUP_OCX_HOST}:sh/${VERSION}/install.sh"
# shellcheck disable=SC2086
rsync $RSYNC_OPTS --ignore-existing -e "$SSH_CMD" \
    "$PS1" "${SETUP_OCX_HOST}:pwsh/${VERSION}/install.ps1"

# Latest pointers (mutable, no --delete):
# shellcheck disable=SC2086
rsync $RSYNC_OPTS -e "$SSH_CMD" \
    "$SH"  "${SETUP_OCX_HOST}:sh/install.sh"
# shellcheck disable=SC2086
rsync $RSYNC_OPTS -e "$SSH_CMD" \
    "$PS1" "${SETUP_OCX_HOST}:pwsh/install.ps1"

echo "publish-installers: done"
