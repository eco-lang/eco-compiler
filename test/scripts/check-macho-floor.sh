#!/usr/bin/env bash
# Fail if any Mach-O file, or any member of a static archive, needs a newer
# macOS than <min> (plans/mac-self-contained-bundle.md, step 1 floor gate).
# Reads LC_BUILD_VERSION's minos, or LC_VERSION_MIN_MACOSX's version for
# older objects. A runner-image or Homebrew-bottle change that raises the
# floor of anything eco ships or links shows up here, not on a user's Mac.
#
# Usage: check-macho-floor.sh <min> <file-or-archive>...
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 <min-macos-version> <file-or-archive>..." >&2
    exit 2
fi
min="$1"
shift

# version_gt A B: exit 0 iff A > B, comparing up to three numeric parts.
version_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, x, "."); m = split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            p = (i <= n ? x[i] : 0) + 0; q = (i <= m ? y[i] : 0) + 0
            if (p > q) exit 0
            if (p < q) exit 1
        }
        exit 1
    }'
}

checked=0
bad=0
for f in "$@"; do
    if [ ! -f "$f" ]; then
        echo "FATAL: $f does not exist" >&2
        exit 1
    fi
    # otool -l names each file (or archive member) on a line ending in ':'.
    while read -r obj ver; do
        checked=$((checked + 1))
        if version_gt "$ver" "$min"; then
            echo "TOO NEW: $obj needs macOS $ver (floor $min)" >&2
            bad=$((bad + 1))
        fi
    done < <(otool -l "$f" | awk '
        /^[^ \t].*:$/            { obj = substr($0, 1, length($0) - 1); next }
        /cmd LC_BUILD_VERSION$/  { want = "minos"; next }
        /cmd LC_VERSION_MIN_MACOSX$/ { want = "version"; next }
        want != "" && $1 == want { print obj, $2; want = "" }')
done

if [ "$checked" -eq 0 ]; then
    echo "FATAL: no Mach-O version load commands found in: $*" >&2
    exit 1
fi
if [ "$bad" -ne 0 ]; then
    echo "FATAL: $bad of $checked Mach-O objects need a macOS newer than $min" >&2
    exit 1
fi
echo "OK: $checked Mach-O objects all run on macOS $min or later"
