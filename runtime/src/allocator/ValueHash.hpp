//===- ValueHash.hpp - The hash of any Elm value --------------------------===//
//
// eco hashes any Elm value with one function, defined in design_docs/theory/runtime/value-hash.md:
// FNV-1a over the value's content as `==` compares it, finished with MurmurHash3's fmix32, never 0.
// eco/system's `Hash.hash` and `FNV.hash` are this function; the compiler's `eco.hash` op computes it
// inline for Int, Float, Char and Bool and calls these entry points for everything else
// (plans/seq-data-structures-performance.md D1). The JavaScript backend has its own function.
//
// Every entry point gives the number `eco_hash_value` gives for the same value boxed.
//
//===----------------------------------------------------------------------===//

#pragma once

#include "Heap.hpp"

#include <cstdint>

namespace Elm {
// Returns `stringHash` of the non-empty String `s` (any form), computed from its units without reading or
// writing its hash slot (HEAP_088). For validation and tests.
uint32_t stringHashUncached(void* s);
// Returns the raw state (definition v4: CRC32C of its units, Crc32c.hpp) of the non-empty String `s`,
// computed from its units without reading or writing any slot: the number a filled slot must hold.
uint32_t stringRawUncached(void* s);
// Returns the raw state of the non-empty String `s` from its slot when filled, and otherwise computes it
// and stores it in the slot; a rope is composed from its children, whose slots are filled too.
uint32_t stringRaw(void* s);
// Checks the hash slot of the heap object `obj` (HEAP_088): returns null when `obj` is not a String, has
// no slot, or its slot is 0 or holds `stringRawUncached(obj)` (and, for a flat String, the rest of the
// slot word is 0); otherwise what is wrong. Validate builds call it on every young object at each minor.
const char* checkStringHashSlot(void* obj);

// The String build sites the hash census counts (ECO_HASH_CENSUS=1; plans/hash-reuse-explicit-vs-cached.md
// B5c), in the order the census prints them.
enum BuildSite : int { kBuildAppend, kBuildConcat, kBuildJoin, kBuildRope, kBuildCons, kBuildPropagate, kBuildSiteCount };
bool hashCensusEnabled();
// Counts a String with a hash slot built at `site`: whether it was given its raw state at build, and the
// units read to do so.
void hashCensusNoteBuilt(void* obj, int site, bool given, uint64_t unitsHashed);
} // namespace Elm

extern "C" {

/// The hash of any boxed value.
int64_t eco_hash_value(Elm::HPtr value);

/// The hash of a String (any form, or the Empty constant): `eco_hash_value` without its dispatch.
int64_t eco_hash_string(Elm::HPtr value);

/// The walker's step for a String field (`mix(kEmpty)`, or `mix(kString); mix(stringHash)`) applied to
/// the running state `h` (a 32-bit FNV state in an i64): `eco.hash.mix` of kind `string` (D2).
int64_t eco_hash_mix_string(int64_t h, Elm::HPtr value);

/// The walker's `boxed(value, depth)` resumed from the running state `h` with `items` items left: what a
/// typed hash chain does for a field it does not unroll (a list, a custom type, any other boxed value;
/// `eco.hash.walk`, D2). Returns `items << 32 | h`, the new state and the items left, which may be
/// negative (a record uses one up after a field that took the last).
int64_t eco_hash_walk(int64_t h, int64_t items, Elm::HPtr value, int64_t depth);

/// The hash of an Int, a Float and a Char, as `eco_hash_value` gives for them boxed.
int64_t eco_hash_i64(int64_t value);
int64_t eco_hash_f64(double value);
int64_t eco_hash_char(int32_t value);

}
