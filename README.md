![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/dariogriffo/restic-debian/total)
![GitHub Downloads (all assets, latest release)](https://img.shields.io/github/downloads/dariogriffo/restic-debian/latest/total)
![GitHub Release](https://img.shields.io/github/v/release/dariogriffo/restic-debian)
![GitHub Release Date](https://img.shields.io/github/release-date/dariogriffo/restic-debian)

<h1>
   <p align="center">
     <a href="https://restic.net/"><img src="https://github.com/dariogriffo/restic-debian/blob/main/restic-logo.png" alt="restic Logo" width="150" style="margin-right: 20px"></a>
     <a href="https://www.debian.org/"><img src="https://github.com/dariogriffo/restic-debian/blob/main/debian-logo.png" alt="Debian Logo" width="104" style="margin-left: 20px"></a>
     <br>restic for Debian
   </p>
</h1>
<p align="center">
 restic is a fast, efficient and secure backup program — deduplicated,
 encrypted and authenticated before anything leaves your machine.
</p>

# restic for Debian

This repository contains build scripts to produce the _unofficial_ Debian packages
(.deb) for [restic](https://github.com/restic/restic/) hosted at [deb.griffo.io](https://deb.griffo.io)

Debian ships restic in its own archive, but stable releases sit still for years:
Debian 12 (Bookworm) carries **0.14.0** and Debian 13 (Trixie) **0.18.0**. These
packages track upstream directly and are built to be a drop-in, newer replacement
for Debian's `restic` package — same package name, same section, same paths.

Currently supported Debian distros are:
- Bookworm (v12)
- Trixie (v13)
- Forky (v14)
- Sid (testing)

Currently supported Ubuntu distros are:
- Jammy (22.04)
- Noble (24.04)
- Questing (25.10)
- Resolute (26.04)

Supported architectures:
- amd64 (x86_64) - All distributions
- arm64 (aarch64) - All distributions
- armhf (ARM hard float, ARMv7) - All distributions
- ppc64el (POWER8+ little endian) - All distributions
- s390x (IBM Z) - All distributions
- riscv64 (RISC-V 64-bit) - All distributions
- i386 (x86 32-bit) - Debian only

`armel` is not offered: upstream builds its `linux/arm` binary with `GOARM=6`,
which needs a hardware FPU, while Debian's armel targets soft-float ARMv5. The
same binary is perfectly happy on armhf. Upstream's `mips*` builds do not map
onto a current Debian release architecture, and there is no upstream `loong64`
build.

The packages include the restic binary, the full set of generated manual pages
(`restic.1` plus one per subcommand) and shell completions for bash, fish and
zsh. Upstream ships only the bare binary in its release assets, so the man pages
and completions are generated at build time with `restic generate`.

## Verifying what gets packaged

restic publishes an aggregate `SHA256SUMS` **and** a detached OpenPGP signature
over it (`SHA256SUMS.asc`), but no Sigstore/SLSA build provenance. Every asset
downloaded during a build — each architecture's binary and the source tarball —
is checked before it is unpacked or executed:

1. its SHA-256 must match the line upstream published in `SHA256SUMS`, and
2. `SHA256SUMS` itself must carry a good signature from the restic release key
   `CF8F 18F2 8445 7597 3F79  D4E1 91A6 868B D3F7 A907`.

The key is vendored in this repository as
[`debian/restic-release-key.asc`](debian/restic-release-key.asc) — inside
`debian/` so that source builds carry it too — and pinned by fingerprint, so it
is never fetched from a keyserver at build time and a compromised GitHub account
cannot swap the key along with the checksums. Both checks are fail-closed: if either the checksum or
the signature is missing or wrong, the build stops.

This is an unofficial community project to provide a package that's easy to
install on Debian. If you're looking for the restic source code, see
[restic](https://github.com/restic/restic/).

## Install/Update

📖 **Step-by-step install guide:** [Debian](https://deb.griffo.io/install-latest-restic-in-debian.html) · [Ubuntu](https://deb.griffo.io/install-latest-restic-in-ubuntu.html)

### The Debian way

> ⚠️ **apt access requires a yearly subscription**
> ([deb.griffo.io](https://deb.griffo.io)). To use this tool for free, download
> the .deb from the [Releases](https://github.com/dariogriffo/restic-debian/releases) page
> and install it manually (see below).

```sh
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://deb.griffo.io/EA0F721D231FDD3A0A17B9AC7808B4DD62C41256.asc | sudo gpg --dearmor --yes -o /etc/apt/keyrings/deb.griffo.io.gpg
echo "deb [signed-by=/etc/apt/keyrings/deb.griffo.io.gpg] https://deb.griffo.io/apt $(lsb_release -sc 2>/dev/null) main" | sudo tee /etc/apt/sources.list.d/deb.griffo.io.list
sudo apt update
sudo apt install -y restic
```

### Manual Installation

1. Download the .deb package for your Debian version available on
   the [Releases](https://github.com/dariogriffo/restic-debian/releases) page.
2. Install the downloaded .deb package.

```sh
sudo dpkg -i <filename>.deb
```
## Updating

To update to a new version, just follow any of the installation methods above. There's no need to uninstall the old version; it will be updated correctly.

## Building

### Build for single architecture
```sh
./build.sh <restic_version> <build_version> <architecture>
# Example: ./build.sh 0.19.1 1 arm64
```

### Build for all architectures
```sh
./build.sh <restic_version> <build_version> all
# Example: ./build.sh 0.19.1 1 all
```

`bzip2` and `gnupg` are required on the build host: upstream ships its Linux
binaries as bare `.bz2` files, and the release checksums are OpenPGP-signed.

## Roadmap

- [x] Produce a .deb package on GitHub Releases
- [x] Set up a debian mirror for easier updates
- [x] Multi-architecture support (amd64, arm64, armhf, i386, ppc64el, s390x, riscv64)
- [x] Verify upstream checksums and their OpenPGP signature before packaging

## Disclaimer

- This repo is not open for issues related to restic. This repo is only for _unofficial_ Debian packaging.
