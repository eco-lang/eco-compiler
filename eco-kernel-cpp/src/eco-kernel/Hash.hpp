//===- Hash.hpp - Native string hashing for Elm-side hash tables ---------===//
//
// Hashing a String in Elm costs one closure call per character, so this
// component computes the two String hashes the Elm side uses in a native loop
// that does not allocate.
//
// `Data.HashMap` keys its buckets on an Int the caller supplies, and callers
// that key on names hash a String on every probe. The narrow hash returns
// exactly what its JS twin returns. Its pure-Elm twin agrees only for a
// non-negative seed and a string with no surrogate code units. The twins live
// outside this file and are kept in step by hand. The wide hash's JS twin
// computes a different value.
//
// There are two hashes, and the difference between them is width.
//
// The *narrow* hash stays below 2^26 (for a non-negative seed), so that two of
// them can be packed into one Int as `a * 2^26 + b` without leaving the range
// both a native i64 and a JS double represent exactly. It is
//
//     h_0     = seed mod 2^26
//     h_{i+1} = (h_i * 33 + (c_i mod 2^26) + 7) mod 2^26
//
// over the UTF-16 code units c_i, with C++ `%` as `mod`.
//
// The *wide* hash is 64-bit FNV-1a over the same code units. It is for callers
// that use the hash only as a bucket key, where any i64 is acceptable and more
// bits mean fewer collisions.
//
// Both read the string through `Elm::StringOps` and never allocate, so the
// pointer they are given stays valid for the whole call.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_HASH_HPP
#define ECO_HASH_HPP

#include <cstdint>

namespace Eco {
namespace Kernel {
namespace Hash {

/// Returns the narrow hash of `str` from `seed`: the formula in the file
/// comment, applied to each UTF-16 code unit of `str` in order.
///
/// `str` is the resolved address of an Elm String, or null for the empty
/// string, which hashes to `seed mod 2^26`. It is only read, and only during
/// the call. The result is in [0, 2^26) when `seed` is non-negative. A negative
/// `seed` keeps its sign through C++ `%`, and the result may then be negative.
///
/// Callers that pack two hashes into one Int rely on the narrow range, so this
/// function must not be widened.
int64_t stringWithSeed(void* str, int64_t seed);

/// Returns the wide hash of `str` from `seed`: 64-bit FNV-1a over the UTF-16
/// code units of `str`, starting from the FNV offset basis XOR `seed`.
///
/// `str` is as for `stringWithSeed`; null hashes to the starting value. The
/// result is the 64-bit hash reinterpreted as a signed Int, so it may be
/// negative.
int64_t string64(void* str, int64_t seed);

} // namespace Hash
} // namespace Kernel
} // namespace Eco

#endif // ECO_HASH_HPP
