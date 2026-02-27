#ifndef ECO_PROCESS_HPP
#define ECO_PROCESS_HPP

#include <cstdint>

namespace Eco::Kernel::Process {

uint64_t exit(int64_t code);
uint64_t spawn(uint64_t cmd, uint64_t args);
uint64_t spawnProcess(uint64_t cmd, uint64_t args, uint64_t stdin_, uint64_t stdout_, uint64_t stderr_);
uint64_t wait(uint64_t handle);

} // namespace Eco::Kernel::Process

#endif // ECO_PROCESS_HPP
