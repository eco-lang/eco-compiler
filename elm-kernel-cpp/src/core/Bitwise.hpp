#ifndef ECO_BITWISE_HPP
#define ECO_BITWISE_HPP

#include <cstdint>

namespace Elm::Kernel::Bitwise {

// Returns bitwise AND of a and b.
int64_t and_(int64_t a, int64_t b);

// Returns bitwise OR of a and b.
int64_t or_(int64_t a, int64_t b);

// Returns bitwise XOR of a and b.
int64_t xor_(int64_t a, int64_t b);

// Returns bitwise complement of a.
int64_t complement(int64_t a);

// Returns a shifted left by offset bits.
int64_t shiftLeftBy(int64_t offset, int64_t a);

// Returns a shifted right by offset bits (arithmetic shift, sign-extends).
int64_t shiftRightBy(int64_t offset, int64_t a);

// Returns a shifted right by offset bits (logical shift, zero-fills).
uint64_t shiftRightZfBy(int64_t offset, int64_t a);

} // namespace Elm::Kernel::Bitwise

#endif // ECO_BITWISE_HPP
