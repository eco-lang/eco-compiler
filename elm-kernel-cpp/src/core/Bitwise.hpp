#ifndef ELM_KERNEL_BITWISE_HPP
#define ELM_KERNEL_BITWISE_HPP

#include <cstdint>

namespace Elm::Kernel::Bitwise {

int32_t and_(int32_t a, int32_t b);
int32_t or_(int32_t a, int32_t b);
int32_t xor_(int32_t a, int32_t b);
int32_t complement(int32_t a);
int32_t shiftLeftBy(int32_t offset, int32_t a);
int32_t shiftRightBy(int32_t offset, int32_t a);
uint32_t shiftRightZfBy(int32_t offset, int32_t a);

} // namespace Elm::Kernel::Bitwise

#endif // ELM_KERNEL_BITWISE_HPP
