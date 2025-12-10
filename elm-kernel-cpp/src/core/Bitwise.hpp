#ifndef ECO_BITWISE_HPP
#define ECO_BITWISE_HPP

#include <cstdint>

namespace Elm::Kernel::Bitwise {

// Returns bitwise AND of a and b.
int32_t and_(int32_t a, int32_t b);

// Returns bitwise OR of a and b.
int32_t or_(int32_t a, int32_t b);

// Returns bitwise XOR of a and b.
int32_t xor_(int32_t a, int32_t b);

// Returns bitwise complement of a.
int32_t complement(int32_t a);

// Returns a shifted left by offset bits.
int32_t shiftLeftBy(int32_t offset, int32_t a);

// Returns a shifted right by offset bits (arithmetic shift, sign-extends).
int32_t shiftRightBy(int32_t offset, int32_t a);

// Returns a shifted right by offset bits (logical shift, zero-fills).
uint32_t shiftRightZfBy(int32_t offset, int32_t a);

} // namespace Elm::Kernel::Bitwise

#endif // ECO_BITWISE_HPP
