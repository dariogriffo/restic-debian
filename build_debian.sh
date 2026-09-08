#!/bin/bash
set -uo pipefail

# Upstream Linux architectures for restic (https://github.com/restic/restic):
#   amd64    -> restic_<ver>_linux_amd64.bz2
#   arm64    -> restic_<ver>_linux_arm64.bz2
#   armhf    -> restic_<ver>_linux_arm.bz2
#   i386     -> restic_<ver>_linux_386.bz2
#   ppc64el  -> restic_<ver>_linux_ppc64le.bz2
#   s390x    -> restic_<ver>_linux_s390x.bz2
#   riscv64  -> restic_<ver>_linux_riscv64.bz2
#
# armel is deliberately NOT claimed: upstream builds linux/arm with GOARM=6
# (helpers/build-release-binaries), which requires a hardware FPU, while Debian
# armel targets soft-float ARMv5. The same GOARM=6 binary runs fine on armhf.
# Upstream's mips/mips64/mipsle/mips64le builds do not map onto a current
# Debian release architecture and loong64 has no upstream build, so neither is
# offered.

# restic publishes an aggregate SHA256SUMS plus a detached OpenPGP signature
# over it (SHA256SUMS.asc), but no Sigstore/SLSA build provenance. The
# signature is the layer that actually survives a compromised GitHub account,
# so the release key is vendored here and pinned by fingerprint rather than
# fetched from a keyserver at build time.
UPSTREAM_CHECKSUM_ASSET="SHA256SUMS"
UPSTREAM_SIGNATURE_ASSET="SHA256SUMS.asc"
UPSTREAM_GPG_KEY="debian/restic-release-key.asc"
UPSTREAM_GPG_FINGERPRINT="CF8F18F2844575973F79D4E191A6868BD3F7A907"

restic_VERSION=$1
BUILD_VERSION=$2
ARCH=${3:-amd64}  # Default to amd64 if no architecture specified

if [ -z "$restic_VERSION" ] || [ -z "$BUILD_VERSION" ]; then
    echo "Usage: $0 <restic_version> <build_version> [architecture]"
    echo "Example: $0 0.19.1 1 arm64"
    echo "Example: $0 0.19.1 1 all    # Build for all architectures"
    echo "Supported architectures: amd64, arm64, armhf, i386, ppc64el, s390x, riscv64, all"
    exit 1
fi

# Function to map Debian architecture to the upstream GOARCH suffix
get_restic_goarch() {
    local arch=$1
    case "$arch" in
        "amd64")   echo "amd64"   ;;
        "arm64")   echo "arm64"   ;;
        "armhf")   echo "arm"     ;;
        "i386")    echo "386"     ;;
        "ppc64el") echo "ppc64le" ;;
        "s390x")   echo "s390x"   ;;
        "riscv64") echo "riscv64" ;;
        *)         echo ""        ;;
    esac
}

# Verify one upstream asset through all three layers before it is unpacked.
verify_asset() {
    local file=$1
    local asset_name=${2:-}
    local args=(--tag "v${restic_VERSION}"
                --checksum-asset "$UPSTREAM_CHECKSUM_ASSET" --require-checksum
                --gpg-key "$UPSTREAM_GPG_KEY"
                --gpg-fingerprint "$UPSTREAM_GPG_FINGERPRINT"
                --signature-asset "$UPSTREAM_SIGNATURE_ASSET" --require-signature)
    [ -n "$asset_name" ] && args+=(--asset-name "$asset_name")
    ./verify_download.sh "${args[@]}" "$file"
}

# restic ships only the bare binary in its release assets -- no man pages and no
# completion scripts. The binary emits both (`restic generate`), and the output
# is pure text, identical on every architecture, so it is produced once per
# build run and reused for every arch/suite. When the target architecture's
# binary cannot be executed on this host we fall back to the amd64 build purely
# to generate them.
ensure_generated() {
    local binary=$1

    if [ -d generated/man ] && [ -f generated/restic.bash ] && \
       [ -f generated/_restic ] && [ -f generated/restic.fish ]; then
        return 0
    fi

    rm -rf generated
    mkdir -p generated/man

    local generator="$binary"
    local scratch=""
    if ! "$generator" version >/dev/null 2>&1; then
        echo "  Target binary is not executable on this host; fetching amd64 build to generate docs"
        scratch=".generate"
        rm -rf "$scratch"
        mkdir -p "$scratch"
        local amd64_asset="restic_${restic_VERSION}_linux_amd64.bz2"
        if ! wget -q "https://github.com/restic/restic/releases/download/v${restic_VERSION}/${amd64_asset}" \
                -O "$scratch/${amd64_asset}"; then
            echo "❌ Failed to download the amd64 build needed to generate man pages and completions"
            rm -rf "$scratch"
            return 1
        fi

        # Verify before unpacking -- an unchecked binary must never be executed,
        # even when it is only used to generate documentation.
        if ! verify_asset "$scratch/${amd64_asset}"; then
            echo "❌ Verification failed for the amd64 build needed to generate man pages and completions"
            rm -rf "$scratch"
            return 1
        fi

        if ! bunzip2 -c "$scratch/${amd64_asset}" > "$scratch/restic"; then
            echo "❌ Failed to decompress the amd64 build"
            rm -rf "$scratch"
            return 1
        fi
        chmod 755 "$scratch/restic"
        generator="$scratch/restic"
    fi

    "$generator" generate \
        --man generated/man \
        --bash-completion generated/restic.bash \
        --zsh-completion generated/_restic \
        --fish-completion generated/restic.fish
    local rc=$?

    [ -n "$scratch" ] && rm -rf "$scratch"
    if [ $rc -ne 0 ]; then
        rm -rf generated
        return 1
    fi

    echo "  Generated $(find generated/man -name '*.1' | wc -l) man pages and bash/zsh/fish completions"
    return 0
}

# Function to build for a specific architecture
build_architecture() {
    local build_arch=$1
    local goarch

    goarch=$(get_restic_goarch "$build_arch")
    if [ -z "$goarch" ]; then
        echo "❌ Unsupported architecture: $build_arch"
        echo "Supported architectures: amd64, arm64, armhf, i386, ppc64el, s390x, riscv64"
        return 1
    fi

    local asset="restic_${restic_VERSION}_linux_${goarch}.bz2"
    local restic_dir="restic-${restic_VERSION}-linux-${build_arch}"

    echo "Building for architecture: $build_arch using $asset"

    # Clean up any previous builds for this architecture
    rm -rf "$restic_dir" || true
    rm -f "$asset" || true

    # Download the restic binary for this architecture
    if ! wget "https://github.com/restic/restic/releases/download/v${restic_VERSION}/${asset}"; then
        echo "❌ Failed to download restic binary for $build_arch"
        return 1
    fi

    # Verify before unpacking -- an unchecked binary must never reach the
    # packaging step.
    if ! verify_asset "$asset"; then
        echo "❌ Verification failed for ${asset}; refusing to package it"
        rm -f "$asset"
        return 1
    fi

    # restic ships each binary bzip2-compressed, with no enclosing archive
    mkdir -p "$restic_dir"
    if ! bunzip2 -c "$asset" > "$restic_dir/restic"; then
        echo "❌ Failed to decompress restic binary for $build_arch"
        return 1
    fi

    rm -f "$asset"
    chmod 755 "$restic_dir/restic"

    if ! ensure_generated "$restic_dir/restic"; then
        echo "❌ Failed to generate man pages and shell completions"
        return 1
    fi

    # Build packages for appropriate Debian distributions
    declare -a arr=("bookworm" "trixie" "forky" "sid")

    for dist in "${arr[@]}"; do
        FULL_VERSION="$restic_VERSION-${BUILD_VERSION}~${dist}_${build_arch}"
        echo "  Building $FULL_VERSION"

        if ! docker build . -t "restic-$dist-$build_arch" \
            --build-arg DEBIAN_DIST="$dist" \
            --build-arg restic_VERSION="$restic_VERSION" \
            --build-arg BUILD_VERSION="$BUILD_VERSION" \
            --build-arg FULL_VERSION="$FULL_VERSION" \
            --build-arg ARCH="$build_arch" \
            --build-arg RESTIC_DIR="$restic_dir"; then
            echo "❌ Failed to build Docker image for $dist on $build_arch"
            return 1
        fi

        id="$(docker create "restic-$dist-$build_arch")"
        if ! docker cp "$id:/restic_$FULL_VERSION.deb" - > "./restic_$FULL_VERSION.deb"; then
            echo "❌ Failed to extract .deb package for $dist on $build_arch"
            return 1
        fi

        if ! tar -xf "./restic_$FULL_VERSION.deb"; then
            echo "❌ Failed to extract .deb contents for $dist on $build_arch"
            return 1
        fi
    done

    # Clean up extracted directory
    rm -rf "$restic_dir" || true

    echo "✅ Successfully built for $build_arch"
    return 0
}

# Main build logic
if [ "$ARCH" = "all" ]; then
    echo "🚀 Building restic $restic_VERSION-$BUILD_VERSION for all supported architectures..."
    echo ""

    # All supported architectures
    ARCHITECTURES=("amd64" "arm64" "armhf" "i386" "ppc64el" "s390x" "riscv64")

    for build_arch in "${ARCHITECTURES[@]}"; do
        echo "==========================================="
        echo "Building for architecture: $build_arch"
        echo "==========================================="

        if ! build_architecture "$build_arch"; then
            echo "❌ Failed to build for $build_arch"
            exit 1
        fi

        echo ""
    done

    echo "🎉 All architectures built successfully!"
    echo "Generated packages:"
    ls -la restic_*.deb
else
    # Build for single architecture
    if ! build_architecture "$ARCH"; then
        exit 1
    fi
fi
