#ifndef ECO_CONSOLE_HPP
#define ECO_CONSOLE_HPP

#include <cstdint>

namespace Eco::Kernel::Console {

uint64_t write(uint64_t handle, uint64_t content);
uint64_t readLine();
uint64_t readAll();

} // namespace Eco::Kernel::Console

#endif // ECO_CONSOLE_HPP
