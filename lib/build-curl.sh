#!/bin/sh
# Build the optional adapter; only libcurl and the public Shen C header are dependencies.
set -eu
out=${1:?usage: sh lib/build-curl.sh OUTPUT}
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -z "${CURL_CFLAGS:-}${CURL_LIBS:-}" ]; then
    if command -v pkg-config > /dev/null && pkg-config --exists libcurl; then
        CURL_CFLAGS=$(pkg-config --cflags libcurl)
        CURL_LIBS=$(pkg-config --libs libcurl)
    elif command -v curl-config > /dev/null; then
        CURL_CFLAGS=$(curl-config --cflags)
        CURL_LIBS=$(curl-config --libs)
    else
        CURL_CFLAGS=
        CURL_LIBS=-lcurl
    fi
fi
mkdir -p "$(dirname -- "$out")"
# Intentional word splitting for compiler and flag lists, with no eval.
${CC:-cc} -std=c11 ${CFLAGS:--O2 -g} -Wall -Wextra -Wno-deprecated-declarations -shared -fPIC \
    -I"$source_dir/../include" ${CURL_CFLAGS:-} "$source_dir/curl.c" ${CURL_LIBS:--lcurl} -o "$out"
