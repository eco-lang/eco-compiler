#ifndef ECO_ENV_HPP
#define ECO_ENV_HPP

#include <cstdint>

namespace Eco::Kernel::Env {

uint64_t lookup(uint64_t name);
uint64_t rawArgs();

} // namespace Eco::Kernel::Env

#endif // ECO_ENV_HPP
