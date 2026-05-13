#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
#
# Real-release smoke test for sh/install.sh inside a distro container.
# Runs against the public github.com/ocx-sh/ocx releases. Asserts:
#   1. Installer exits 0.
#   2. PRINT_PATH stdout points at an executable ocx binary.
#   3. `ocx version` runs and returns 0.
#
# Args:
#   $1 (optional) — version to install (default: latest)

set -eu

VERSION="${1:-latest}"

echo ">>> [smoke] distro: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -a)"
echo ">>> [smoke] arch:   $(uname -m)"
echo ">>> [smoke] target version: $VERSION"

if [ "$VERSION" = "latest" ]; then
    BIN_DIR=$(OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 sh /work/install.sh | tail -n1)
else
    BIN_DIR=$(OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 sh /work/install.sh --version "$VERSION" | tail -n1)
fi

echo ">>> [smoke] bin dir: $BIN_DIR"

if [ ! -x "$BIN_DIR/ocx" ]; then
    echo "!!! [smoke] $BIN_DIR/ocx is missing or not executable" >&2
    ls -la "$BIN_DIR" >&2 || :
    exit 1
fi

"$BIN_DIR/ocx" version

echo ">>> [smoke] OK"
