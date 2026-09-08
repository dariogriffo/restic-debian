#!/bin/bash
set -euo pipefail

restic_VERSION=${1:-}
BUILD_VERSION=${2:-}
ARCH=${3:-amd64}  # Default to amd64 if no architecture specified

if [ -z "$restic_VERSION" ] || [ -z "$BUILD_VERSION" ]; then
    echo "Usage: $0 <restic_version> <build_version> [architecture]"
    echo "Example: $0 0.19.1 1 all"
    exit 1
fi

./build_debian.sh "$restic_VERSION" "$BUILD_VERSION" "$ARCH"
./build_ubuntu.sh "$restic_VERSION" "$BUILD_VERSION" "$ARCH"
./build_src.sh "$restic_VERSION" "$BUILD_VERSION"
