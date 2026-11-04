#ifndef ECO_BITWISE_HPP
#define ECO_BITWISE_HPP

// The bit operations of elm/core's `Bitwise` module, on Eco's 64-bit Int.
//
// elm/core's JavaScript works on 32-bit integers and takes shift counts modulo 32. Here an Int is 64 bits wide, so
// the operations act on all 64 bits and every shift takes its count modulo 64 (`offset & 63`, so a negative count
// wraps too): `shiftLeftBy 64 1` is 1 and `shiftLeftBy 65 1` is 2. Codegen that lowers these operations inline masks
// the count the same way, so both paths agree.
//
// The shift functions take the count first and the value second, the order of Elm's curried arguments.
// The functions are pure and keep no state.

#include <cstdint>

namespace Elm::Kernel::Bitwise {

/// Returns the bitwise AND of `a` and `b`.
int64_t and_(int64_t a, int64_t b);

/// Returns the bitwise OR of `a` and `b`.
int64_t or_(int64_t a, int64_t b);

/// Returns the bitwise XOR of `a` and `b`.
int64_t xor_(int64_t a, int64_t b);

/// Returns the bitwise complement of `a`.
int64_t complement(int64_t a);

/// Returns `a` shifted left by `offset & 63` bits, filling with zeros. Bits shifted past bit 63 are lost.
int64_t shiftLeftBy(int64_t offset, int64_t a);

/// Returns `a` shifted right by `offset & 63` bits, copying the sign bit into the vacated bits.
int64_t shiftRightBy(int64_t offset, int64_t a);

/// Returns the bits of `a` shifted right by `offset & 63` bits, filling with zeros.
///
/// The result is unsigned here but is the same 64 bits an Elm Int holds. Read as a signed Int it is negative only
/// when the masked count is 0 and `a` is negative: `shiftRightZfBy 64 -1` is -1.
uint64_t shiftRightZfBy(int64_t offset, int64_t a);

} // namespace Elm::Kernel::Bitwise

#endif // ECO_BITWISE_HPP
