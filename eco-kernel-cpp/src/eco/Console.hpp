#ifndef ECO_CONSOLE_HPP
#define ECO_CONSOLE_HPP

#include <cstdint>

namespace Eco::Kernel::Console {

uint64_t write(uint64_t handle, uint64_t content);
uint64_t readLine();
uint64_t readAll();

// log(tag, value): writes `tag` (with newline) to stderr and returns `value`
// unchanged. Pure-looking from Elm's perspective; side-effect only via stderr.
uint64_t log(uint64_t tag, uint64_t value);

} // namespace Eco::Kernel::Console

#endif // ECO_CONSOLE_HPP
