#!/bin/sh
# What building from a checkout, and CI, need from outside the repository, checked against these
# hashes. Usage:
#
#   sh tools/ci-deps.sh kernel DIR            the kernel's release, with klambda/ and tests/, in DIR
#   sh tools/ci-deps.sh shen-scheme DIR       Shen/Scheme's release for this platform, in DIR
#   sh tools/ci-deps.sh shen-scheme-src DIR   its sources, whose benchmarks make bench runs
#
# Each prints what to use: DIR, or Shen/Scheme's executable. make deps runs the first two.
set -e
KERNEL=43.2
KERNEL_SHA256=23c71508f0de24785e1f127ea4fab440081904d81c463090bc642ee840417f32
SCHEME=0.52
SCHEME_URL=https://github.com/tizoc/shen-scheme/releases/download/v$SCHEME/shen-scheme-v$SCHEME

fetch() { # url, hash, directory
    mkdir -p "$3"
    name=${1##*/}
    curl -fsSL --retry 3 -o "$3/$name" "$1"
    echo "$2  $3/$name" | { command -v sha256sum > /dev/null && sha256sum -c - || shasum -a 256 -c -; } > /dev/null
    case "$name" in
    *.zip)
        unzip -q -d "$3" "$3/$name"
        mv "$3"/shen-scheme-*-bin/* "$3"
        rmdir "$3"/shen-scheme-*-bin
        ;;
    *)
        tar -C "$3" --strip-components=1 -xzf "$3/$name"
        ;;
    esac
    rm "$3/$name"
}

case "$1" in
kernel)
    fetch "https://github.com/Shen-Language/shen-sources/releases/download/shen-$KERNEL/ShenOSKernel-$KERNEL.tar.gz" \
        "$KERNEL_SHA256" "$2"
    echo "$2"
    ;;
shen-scheme)
    case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        fetch "$SCHEME_URL-linux-x64-bin.tar.gz" aa711f576ea0ec96d86b0120eeba875153317a9af9e6a69f9c6ef4c00a4ad8c9 "$2" ;;
    Darwin-arm64)
        fetch "$SCHEME_URL-macOS-arm64-bin.tar.gz" 44e980d192d156859d06374e554813e1dc1e81210b95e9b1e23eb5e85276106b "$2" ;;
    MINGW*-x86_64 | MSYS*-x86_64)
        fetch "$SCHEME_URL-windows-x64-bin.zip" 3857afbb189c0bb95f1ce3ebb07de274dc26f36f285070adbe7317f42702b3da "$2" ;;
    *)
        echo "Shen/Scheme $SCHEME has no release for $(uname -s) $(uname -m): build from a release tarball, or set SHEN_SCHEME" >&2
        exit 1 ;;
    esac
    echo "$2/bin/shen-scheme"
    ;;
shen-scheme-src)
    fetch "$SCHEME_URL-src.tar.gz" 6f3d4bdfa86a15e7916288f320e6a2f8d1739bdc5a93bf70d383b9ee83c86974 "$2"
    echo "$2"
    ;;
*)
    echo "usage: ci-deps.sh kernel|shen-scheme|shen-scheme-src DIR" >&2
    exit 2
    ;;
esac
