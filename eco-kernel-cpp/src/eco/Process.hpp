#ifndef ECO_PROCESS_HPP
#define ECO_PROCESS_HPP

#include <cstdint>

namespace Eco::Kernel::Process {

uint64_t exit(uint64_t code);
uint64_t spawn(uint64_t config);
uint64_t wait(uint64_t handle);

} // namespace Eco::Kernel::Process

#endif // ECO_PROCESS_HPP
