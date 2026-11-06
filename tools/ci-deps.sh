#!/bin/sh
# What building from a checkout, and CI, need from outside the repository, checked against these
# hashes. Usage:
#
#   sh tools/ci-deps.sh kernel DIR            the kernel's release, with klambda/ and tests/, in DIR
#   sh tools/ci-deps.sh shen-jit DIR          the release of Shen/JIT that builds this one, for this
#                                             platform, in DIR
#   sh tools/ci-deps.sh shen-scheme DIR       Shen/Scheme's release for this platform, in DIR: it can
#                                             build Shen/JIT too, and make bench compares against it
#   sh tools/ci-deps.sh shen-scheme-src DIR   its sources, whose benchmarks make bench runs
#
# Each prints what to use: DIR, or the executable. make deps runs the first two.
set -e
KERNEL=43.4
KERNEL_SHA256=15e7972e6bf0cd65d37c2eba85750b8839d2dbadda41027eae0c88e5017a2756
BOOTSTRAP=0.1
BOOTSTRAP_URL=https://github.com/tizoc/shen-jit/releases/download/v$BOOTSTRAP/shen-jit-$BOOTSTRAP
SCHEME=0.53
SCHEME_URL=https://github.com/tizoc/shen-scheme/releases/download/v$SCHEME/shen-scheme-v$SCHEME

fetch() { # url, hash, directory
    mkdir -p "$3"
    name=${1##*/}
    curl -fsSL --retry 3 -o "$3/$name" "$1"
    echo "$2  $3/$name" | { command -v sha256sum > /dev/null && sha256sum -c - || shasum -a 256 -c -; } > /dev/null
    case "$name" in
    *.zip)
        unzip -q -o -d "$3" "$3/$name"
        for top in "$3"/shen-*/; do
            cp -R "$top". "$3"/
            rm -rf "$top"
        done
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
shen-jit)
    # On Linux the static builds, which run on any system, as a host needs no libraries.
    case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        fetch "$BOOTSTRAP_URL-linux-x86_64-static.tar.gz" 4e569fe92e24a722afe406807e7ad3271fd2d6cc4b7744c981536f732e2953bd "$2" ;;
    Linux-aarch64)
        fetch "$BOOTSTRAP_URL-linux-arm64-static.tar.gz" 2aad3cce35a39be0d9f8859122a4ad1582564ba6afad597054b2cfb2011f0f9d "$2" ;;
    Darwin-arm64)
        fetch "$BOOTSTRAP_URL-macos-arm64.tar.gz" 4c21b9e3b100dec8411ca5a1685fd7acb6afc79d8c304b930af6bde4c5a7fb91 "$2" ;;
    MINGW*-x86_64 | MSYS*-x86_64)
        fetch "$BOOTSTRAP_URL-windows-x86_64.zip" 8bd2ddc99791253b134d92d4a03e7c366264aafb5917743590e8382e505ec7aa "$2"
        echo "$2/shen-jit.exe"
        exit 0 ;;
    *)
        echo "Shen/JIT $BOOTSTRAP has no release for $(uname -s) $(uname -m): build from a source tarball, or set BOOTSTRAP" >&2
        exit 1 ;;
    esac
    echo "$2/shen-jit"
    ;;
shen-scheme)
    case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        fetch "$SCHEME_URL-linux-x64-bin.tar.gz" 235e03fac3143f5b2a1a3529c27f626d20d9fbc8548dd1729a9afe3f8d45ac4b "$2" ;;
    Linux-aarch64)
        fetch "$SCHEME_URL-linux-arm64-bin.tar.gz" 1ddc812eb6be81a12857c7399f3964e0e9e9d17a2a2a0b2107773805e40f8fd4 "$2" ;;
    Darwin-arm64)
        fetch "$SCHEME_URL-macOS-arm64-bin.tar.gz" e3ce2175c1786a285628dc95558c7ebc9decf1063a55f38d104061f491e53a77 "$2" ;;
    MINGW*-x86_64 | MSYS*-x86_64)
        fetch "$SCHEME_URL-windows-x64-bin.zip" a56cd765d9c960f1cdcfc4c5192c14c48e0658fbf113670f7ffe819007a36e68 "$2" ;;
    *)
        echo "Shen/Scheme $SCHEME has no release for $(uname -s) $(uname -m)" >&2
        exit 1 ;;
    esac
    echo "$2/bin/shen-scheme"
    ;;
shen-scheme-src)
    fetch "$SCHEME_URL-src.tar.gz" 3032e3ee0780c58a64780ed842eee9f24e3145e9928b39977261c3aad5c02052 "$2"
    echo "$2"
    ;;
*)
    echo "usage: ci-deps.sh kernel|shen-jit|shen-scheme|shen-scheme-src DIR" >&2
    exit 2
    ;;
esac
