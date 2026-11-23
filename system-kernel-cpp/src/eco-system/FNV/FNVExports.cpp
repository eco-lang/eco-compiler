//===- FNVExports.cpp - C-linkage export for eco/system's FNV.hash --------===//
//
// `FNV.hash : a -> Int` (and `Hash.hash`, which is the same kernel) is eco's value hash, which SeqDict
// and SeqSet key their trie on. The function itself lives in the runtime
// (runtime/src/allocator/ValueHash.cpp, defined in design_docs/theory/runtime/value-hash.md), so that
// compiled code's `eco.hash` op can share it; this export serves the calls the compiler does not turn
// into that op, such as `FNV.hash` used as a function value.
//
//===----------------------------------------------------------------------===//

#include "KernelExports.h"
#include "allocator/ValueHash.hpp"

extern "C" int64_t Eco_Kernel_FNV_hash(Elm::HPtr value) {
    return eco_hash_value(value);
}
