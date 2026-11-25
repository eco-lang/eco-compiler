//===- FNVExports.cpp - C-linkage exports for eco/system's FNV kernel -----===//
//
// `FNV.hash : a -> Int` (and `Hash.hash`, which is the same kernel) is eco's value hash, which SeqDict
// and SeqSet key their trie on. The function itself lives in the runtime
// (runtime/src/allocator/ValueHash.cpp, defined in design_docs/theory/runtime/value-hash.md), so that
// compiled code's `eco.hash` op can share it; this export serves the calls the compiler does not turn
// into that op, such as `FNV.hash` used as a function value.
//
// `hashed` and `value` are eco/system's `Hash.Hashed` (HEAP_089): a `Tag_Hashed` object
// (`ElmHashed`) holding a value and its hash. The value hash reads a `Hashed`'s stored hash instead of
// walking its value, so a structure built from `Hashed` parts hashes in O(1) per part, and `Hash.hash`
// of a `Hashed` is its stored hash.
//
//===----------------------------------------------------------------------===//

#include "KernelExports.h"
#include "allocator/Allocator.hpp"
#include "allocator/Heap.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/ValueHash.hpp"

#include <cstring>

using namespace Elm;

extern "C" int64_t Eco_Kernel_FNV_hash(Elm::HPtr value) {
    return eco_hash_value(value);
}

// Returns a new `Hashed` of `value`: its hash, computed first (the walk allocates nothing), then the object.
// The allocation is a GC point, so `value` is rooted across it and read back from the root.
extern "C" Elm::HPtr Eco_Kernel_FNV_hashed(Elm::HPtr value) {
    const u32 h = static_cast<u32>(eco_hash_value(value));
    HPointer v = value.toHPointer();
    uint64_t roots[1];
    std::memcpy(&roots[0], &v, sizeof(v));
    void* obj = eco_alloc_with_roots(Tag_Hashed, sizeof(ElmHashed), roots, 1, 0x1);
    ElmHashed* hd = static_cast<ElmHashed*>(obj);
    hd->hash = h;
    hd->reserved = 0;
    std::memcpy(&hd->value, &roots[0], sizeof(hd->value));
    return Elm::HPtr::fromBits(hpBits(Allocator::instance().wrap(hd)));
}

// Returns the value of the `Hashed` `hashedValue`.
extern "C" Elm::HPtr Eco_Kernel_FNV_value(Elm::HPtr hashedValue) {
    auto* hd = static_cast<ElmHashed*>(Allocator::instance().resolve(hashedValue.toHPointer()));
    return Elm::HPtr::fromBits(hpBits(hd->value));
}
