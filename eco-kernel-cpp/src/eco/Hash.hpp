//===- Hash.hpp - Native string hashing for Elm-side hash tables ---------===//
//
// `Data.HashMap` keys its buckets on an Int the caller supplies, and the
// callers that matter here key on names: `TOpt.globalHash` hashes a value
// name once per probe, roughly 10^6 times per self-compile.
//
// Computing that hash in Elm is what made the hashed tables lose. `String.foldl`
// snapshots the whole string into a std::vector<u16> and then performs one
// GENERIC CLOSURE DISPATCH per character (eco_apply_closure_typed), boxing and
// unboxing the accumulator each time — against a `Dict String` probe whose
// comparisons bottom out in a C++ memcmp. Measured three times, always the same
// way: loop entries 27 (+33.6 s), 24(iii)+(iv) (+7.47 s) and 12s.
//
// This computes the identical hash in one allocation-free C loop. The mix is
// the same one the Elm side used, so a table built by either implementation
// answers the same way and the pure twin in compiler/src-xhr stays exact:
//
//     h_0     = seed
//     h_{i+1} = (h_i * 33 + (c_i mod 2^26) + 7) mod 2^26
//
// Base 2^26 matches `Monomorphized.hashBase`: two of these pack into 2^52,
// inside the exact-integer range of both the native i64 and the JS double, so
// the native, JS-bootstrap and pure-Elm implementations agree bit for bit.
//
// GC: allocation-free on every path, so the lowered call is gc-leaf and needs
// no rooting and no statepoint.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_HASH_HPP
#define ECO_HASH_HPP

#include <cstdint>

namespace Eco {
namespace Kernel {
namespace Hash {

/// Mix `seed` over the UTF-16 code units of `str` (an encoded HPointer's
/// resolved pointer, or nullptr for the empty/constant forms).
///
/// NARROW: the result stays in [0, 2^26). Callers that PACK two hashes into
/// one Int need that — `Monomorphized.packHashes` is `layoutH * hashBase +
/// specH` — so this variant must not be widened.
int64_t stringWithSeed(void* str, int64_t seed);

/// FNV-1a over the same code units, full 64-bit, seeded.
///
/// WIDE: for callers that use the hash only as a `Data.HashMap` bucket key.
/// That map stores its buckets in a `Dict Int` keyed on the RAW hash — no
/// mask, no `modBy`, no `Bitwise` — so any i64 is a legal key, negatives
/// included, and a wider hash simply means shorter buckets. It is also
/// cheaper than the narrow mix: no modulo per character.
int64_t string64(void* str, int64_t seed);

} // namespace Hash
} // namespace Kernel
} // namespace Eco

#endif // ECO_HASH_HPP
