#!/bin/sh
# plans/large-object-space.md D4 / HEAP_081: a large String/Bytes body is reached
# only through the Heap.hpp accessors (largeStringChars, largeBytesData,
# flatStringChars) or by the allocator/GC code that owns it. Bodies are pinned and
# never forwarded, so a body is NEVER passed to Allocator::resolve/resolveFast: on a
# header-less body that would read the first payload byte as a tag.
#
# Fails when:
#   1. a C++ file that names LargeStringHeader/LargeByteHeader dereferences a
#      `->body` outside the allow-list below;
#   2. any file passes a `->body` to resolve()/resolveFast().
#
# usage: check-large-body-access.sh <repo-root>
set -eu
root=${1:?usage: $0 <repo-root>}
cd "$root"

allow='runtime/src/allocator/Heap.hpp
runtime/src/allocator/ThreadLocalHeap.cpp
runtime/src/allocator/OldGenSpace.cpp
runtime/src/allocator/NurserySpace.cpp
runtime/src/allocator/NurseryRegion.cpp
runtime/src/allocator/NurseryParallel.cpp
runtime/src/allocator/NurseryTenure.cpp
runtime/src/allocator/HeapChildWalk.hpp
runtime/src/allocator/PermanentSpace.cpp'

fail=0
files=$(grep -rlE 'Large(String|Byte)Header' runtime/src elm-kernel-cpp eco-kernel-cpp system-kernel-cpp \
          --include='*.cpp' --include='*.hpp' --include='*.h' 2>/dev/null || true)
for f in $files; do
    # Strip // comments before matching.
    hits=$(sed 's://.*$::' "$f" | grep -nE '(->|\.)body\b' || true)
    [ -z "$hits" ] && continue
    if echo "$allow" | grep -qx "$f"; then
        bad=$(echo "$hits" | grep -E 'resolve(Fast)?\(' || true)
        if [ -n "$bad" ]; then
            echo "check-large-body-access: $f resolves a large body (read it raw: largeBodyAddr / hpToAddr):"
            echo "$bad" | sed 's/^/    /'
            fail=1
        fi
    else
        echo "check-large-body-access: $f reads a large body directly; use the Heap.hpp accessors"
        echo "  (largeStringChars / largeBytesData / flatStringChars, alloc::flatStringView /"
        echo "   alloc::flatBytesView / alloc::byteBufferView):"
        echo "$hits" | sed 's/^/    /'
        fail=1
    fi
done
exit $fail
