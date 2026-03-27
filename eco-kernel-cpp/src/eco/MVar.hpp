#ifndef ECO_MVAR_HPP
#define ECO_MVAR_HPP

#include <cstdint>

namespace Eco::Kernel::MVar {

int64_t newEmpty();
uint64_t read(uint64_t typeTag, uint64_t id);
uint64_t take(uint64_t typeTag, uint64_t id);
uint64_t put(uint64_t typeTag, uint64_t id, uint64_t value);
uint64_t drop(uint64_t id);

} // namespace Eco::Kernel::MVar

#endif // ECO_MVAR_HPP
