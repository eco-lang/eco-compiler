#!/bin/bash
# E-M1 statepoint smoke — driver.
#
# Pipeline: gcfun.ll → opt(rewrite-statepoints-for-gc) → llc(host arch) →
# link with harness.cpp via system clang/ld64 → run. Then the two link-time
# variants from the build-on-mac plan: -dead_strip survival of
# __LLVM_STACKMAPS, and codesign presence on the output.
set -euo pipefail
cd "$(dirname "$0")"

LLVM_PREFIX=$(brew --prefix llvm@21 2>/dev/null || brew --prefix llvm)
OPT="$LLVM_PREFIX/bin/opt"
LLC="$LLVM_PREFIX/bin/llc"
echo "=== using LLVM at $LLVM_PREFIX ==="
"$LLC" --version | head -4

ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    TRIPLE=arm64-apple-macosx12.0.0
else
    TRIPLE=x86_64-apple-macosx12.0.0
fi
echo "=== host arch: $ARCH, target triple: $TRIPLE ==="

mkdir -p out

echo "=== 1. RewriteStatepointsForGC ==="
"$OPT" -passes=rewrite-statepoints-for-gc -S gcfun.ll -o out/gcfun.rs4gc.ll
grep -c "gc.statepoint" out/gcfun.rs4gc.ll \
    || { echo "FAIL: no statepoints emitted by RS4GC"; exit 1; }

echo "=== 2. llc → Mach-O object ==="
"$LLC" -O2 -mtriple="$TRIPLE" -filetype=obj out/gcfun.rs4gc.ll -o out/gcfun.o
echo "--- stackmaps section in the object: ---"
"$LLVM_PREFIX/bin/llvm-readobj" --sections out/gcfun.o \
    | grep -B2 -A6 llvm_stackmaps || { echo "FAIL: no __llvm_stackmaps in object"; exit 1; }

echo "=== 3. link (plain) + run: variants (a) plain frame, (b) dynamic alloca ==="
clang++ -std=c++17 -g -O1 harness.cpp out/gcfun.o -o out/smoke
out/smoke 2>&1 | tee out/smoke-plain.log

echo "=== 4. variant (c): -dead_strip ==="
clang++ -std=c++17 -g -O1 harness.cpp out/gcfun.o -o out/smoke-ds -Wl,-dead_strip
set +e
STACKMAP_ALLOW_MISSING=1 out/smoke-ds 2>&1 | tee out/smoke-deadstrip.log
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -eq 0 ]; then
    echo "FINDING: __LLVM_STACKMAPS SURVIVES -dead_strip and still matches"
elif [ "$rc" -eq 42 ]; then
    echo "FINDING: -dead_strip REMOVES __LLVM_STACKMAPS (keep-alive needed in eco's link driver)"
else
    echo "FAIL: dead_strip variant failed with unexpected rc=$rc"
    exit "$rc"
fi

echo "=== 5. variant (d): code signature on the output ==="
codesign -dv out/smoke 2>&1 | tee out/codesign.log \
    || echo "FINDING: output binary carries NO code signature"

echo "=== 6. section layout in the linked binary (for the record) ==="
otool -l out/smoke | grep -B1 -A8 LLVM_STACKMAPS | tee out/sections.log || true

echo "=== E-M1 COMPLETE ==="
