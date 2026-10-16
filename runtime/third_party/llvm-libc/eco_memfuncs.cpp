// LLVM libc's memcpy, memmove, memset, bcmp and memcmp as one translation unit, so the
// static musl build gets a single object file (eco-memfuncs-obj, installed as
// lib/eco-runtime/memfuncs.o) to link ahead of libc.a in place of musl's versions
// (plans/bundle-runtime-performance.md, D). Compile flags are in the top-level
// CMakeLists.txt; update.sh in this directory refreshes the vendored sources.
//
// All five are replaced together: musl's x86_64 memmove.s jumps to __memcpy_fwd, a label
// inside its memcpy.s, so a program that pulled in musl's memmove would also pull in musl's
// memcpy and the link would fail with a duplicate memcpy.

#include "src/string/memcpy.cpp"
#include "src/string/memmove.cpp"
#include "src/string/memset.cpp"
#include "src/strings/bcmp.cpp"
#include "src/string/memcmp.cpp"
