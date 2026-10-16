#!/bin/sh
# Refresh the vendored LLVM libc subset under libc/ from an llvm-project release.
#
#   runtime/third_party/llvm-libc/update.sh 21.1.8 <sha256 of llvm-project-21.1.8.src.tar.xz>
#
# Downloads the release tarball (LLVM publishes no per-project libc tarball), checks its
# SHA-256, and copies the five entry points plus every header they include (found with
# `-MM` under the same flags the top-level CMakeLists.txt uses) into libc/. Run it with a
# clang at least as new as the one that builds the bundle (CXX=...); then update the
# version and hash in README.md.
set -eu

ver=${1:?usage: update.sh <llvm version> <tarball sha256>}
sha=${2:?usage: update.sh <llvm version> <tarball sha256>}
cxx=${CXX:-clang++}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d /tmp/llvm-libc-update.XXXXXX)
trap 'rm -rf "$work"' EXIT

tarball=llvm-project-$ver.src.tar.xz
curl -sfL -o "$work/$tarball" \
    "https://github.com/llvm/llvm-project/releases/download/llvmorg-$ver/$tarball"
echo "$sha  $work/$tarball" | sha256sum -c -
tar -C "$work" -xJf "$work/$tarball" "llvm-project-$ver.src/libc"
src=$work/llvm-project-$ver.src/libc

# Keep in step with eco-memfuncs-obj's flags in the top-level CMakeLists.txt.
"$cxx" -std=c++17 -march=x86-64-v3 -ffreestanding -fno-builtin \
    -DLIBC_NAMESPACE=__llvm_libc_eco -DLIBC_COPT_PUBLIC_PACKAGING \
    -I"$src" -MM "$here/eco_memfuncs.cpp" |
    tr ' \\' '\n\n' | grep "^$src/" | (cd "$src" && xargs realpath --relative-to=.) |
    sort -u >"$work/files"

rm -rf "$here/libc"
mkdir -p "$here/libc"
(cd "$src" && xargs cp --parents -t "$here/libc" <"$work/files")
cp "$src/LICENSE.TXT" "$here/LICENSE.TXT"
echo "copied $(wc -l <"$work/files") files from LLVM $ver into $here/libc"
