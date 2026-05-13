#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
#
# Build a single (distro, platform) image and run sh/install.sh inside it.
#
# Usage:
#   tests/docker/run.sh <distro> <platform> [version]
#
# Examples:
#   tests/docker/run.sh alpine linux/amd64
#   tests/docker/run.sh fedora linux/arm64
#   tests/docker/run.sh ubuntu linux/amd64 0.5.0

set -euo pipefail

DISTRO="${1:?distro required (alpine|fedora|ubuntu)}"
PLATFORM="${2:?platform required (linux/amd64|linux/arm64)}"
VERSION="${3:-latest}"

case "$DISTRO" in
    alpine | fedora | ubuntu) ;;
    *)
        echo "run.sh: unknown distro '$DISTRO' (want: alpine, fedora, ubuntu)" >&2
        exit 2
        ;;
esac

case "$PLATFORM" in
    linux/amd64 | linux/arm64) ;;
    *)
        echo "run.sh: unknown platform '$PLATFORM' (want: linux/amd64, linux/arm64)" >&2
        exit 2
        ;;
esac

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DOCKERFILE="$REPO_ROOT/tests/docker/Dockerfile.$DISTRO"
ARCH_SLUG=${PLATFORM##*/}
TAG="setup-ocx-sh-test/${DISTRO}-${ARCH_SLUG}:latest"

echo "==> Building $TAG ($PLATFORM, $DOCKERFILE)"
docker buildx build \
    --platform "$PLATFORM" \
    --file "$DOCKERFILE" \
    --tag "$TAG" \
    --load \
    "$REPO_ROOT"

echo "==> Running smoke ($DISTRO, $PLATFORM, version=$VERSION)"
docker run --rm \
    --platform "$PLATFORM" \
    "$TAG" "$VERSION"
