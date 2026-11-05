#!/bin/sh
# Prints a version's section of CHANGELOG.md, for its release's notes, without the
# heading or the link definitions at the end of the file. Fails if there is nothing in it.
#
#   sh tools/release-notes.sh VERSION
notes=$(awk -v version="$1" '
    index($0, "## [" version "]") == 1 { in_section = 1; next }
    in_section && /^## \[/ { exit }
    in_section && /^\[[^]]+\]: / { next }
    in_section && (NF || started) { started = 1; print }
' CHANGELOG.md)
if [ -z "$notes" ]; then
    echo "CHANGELOG.md has nothing for $1" >&2
    exit 1
fi
printf '%s\n' "$notes"
