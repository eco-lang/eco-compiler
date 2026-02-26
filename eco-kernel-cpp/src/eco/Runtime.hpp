#ifndef ECO_RUNTIME_HPP
#define ECO_RUNTIME_HPP

#include <cstdint>

namespace Eco::Kernel::Runtime {

uint64_t dirname();
double random();
uint64_t saveState(uint64_t state);

} // namespace Eco::Kernel::Runtime

#endif // ECO_RUNTIME_HPP
