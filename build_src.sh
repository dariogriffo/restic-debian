#!/bin/bash
set -euo pipefail

restic_VERSION=${1:-}
BUILD_VERSION=${2:-}

if [ -z "$restic_VERSION" ] || [ -z "$BUILD_VERSION" ]; then
    echo "Usage: $0 <restic_version> <build_version>"
    echo "Example: $0 0.19.1 1"
    exit 1
fi

PACKAGE_NAME="restic"
UPSTREAM_TARBALL="restic-${restic_VERSION}.tar.gz"
ORIG_TARBALL="${PACKAGE_NAME}_${restic_VERSION}.orig.tar.gz"
BUILD_DIR="${PACKAGE_NAME}-${restic_VERSION}"

echo "Creating Debian/Ubuntu source packages for restic ${restic_VERSION}-${BUILD_VERSION}..."

# Download the upstream source tarball (shared .orig.tar.gz across all
# distributions). Upstream publishes its own tarball -- covered by SHA256SUMS
# and its OpenPGP signature, unlike GitHub's generated tag archive -- and it
# extracts as restic-0.19.1/, matching BUILD_DIR, so it is used verbatim and
# never repacked: the same bytes on every rebuild.
if [ ! -f "$ORIG_TARBALL" ]; then
    echo "Downloading upstream source from GitHub..."
    wget -q "https://github.com/restic/restic/releases/download/v${restic_VERSION}/${UPSTREAM_TARBALL}" \
         -O "$ORIG_TARBALL"

    # The local file was renamed by -O, so map it back to the upstream asset
    # name for the checksum lookup.
    if ! ./verify_download.sh \
        --tag "v${restic_VERSION}" \
        --asset-name "$UPSTREAM_TARBALL" \
        --checksum-asset SHA256SUMS --require-checksum \
        --gpg-key debian/restic-release-key.asc \
        --gpg-fingerprint "CF8F18F2844575973F79D4E191A6868BD3F7A907" \
        --signature-asset SHA256SUMS.asc --require-signature \
        "$ORIG_TARBALL"; then
        echo "❌ Verification failed for ${UPSTREAM_TARBALL}; refusing to package it"
        rm -f "$ORIG_TARBALL"
        exit 1
    fi
    echo "  Downloaded $ORIG_TARBALL"
else
    echo "  Using existing $ORIG_TARBALL"
fi

build_source_package() {
    local dist=$1
    local FULL_VERSION="${restic_VERSION}-${BUILD_VERSION}~${dist}"

    echo "  Building source package for ${dist} (${FULL_VERSION})..."

    # Clean and recreate build directory from orig tarball
    rm -rf "$BUILD_DIR"
    tar -xf "$ORIG_TARBALL"

    # Copy Debian packaging directory
    cp -r debian "$BUILD_DIR/"

    # Generate distribution-specific changelog (overwrites placeholder)
    cat > "$BUILD_DIR/debian/changelog" << EOF
restic (${FULL_VERSION}) ${dist}; urgency=medium

  * New upstream release ${restic_VERSION}.

 -- Dario Griffo <dariogriffo@gmail.com>  $(date -R)
EOF

    # Build source package (.dsc + .debian.tar.xz); reuses existing .orig.tar.gz
    dpkg-source -b "$BUILD_DIR"

    rm -rf "$BUILD_DIR"
    echo "    ${FULL_VERSION}"
}

echo ""
echo "Building Debian source packages..."
DEBIAN_DISTS=("bookworm" "trixie" "forky" "sid")
for dist in "${DEBIAN_DISTS[@]}"; do
    build_source_package "$dist"
done

echo ""
echo "Building Ubuntu source packages..."
UBUNTU_DISTS=("jammy" "noble" "questing" "resolute")
for dist in "${UBUNTU_DISTS[@]}"; do
    build_source_package "$dist"
done

echo ""
echo "Source packages created successfully!"
echo ""
echo "Generated files:"
ls -la "${PACKAGE_NAME}_"*.dsc "${PACKAGE_NAME}_"*.orig.tar.gz "${PACKAGE_NAME}_"*.debian.tar.xz 2>/dev/null || true
