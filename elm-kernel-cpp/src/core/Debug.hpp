#ifndef ELM_KERNEL_DEBUG_HPP
#define ELM_KERNEL_DEBUG_HPP

#include <string>

namespace Elm::Kernel::Debug {

// Forward declaration for generic Elm value
struct Value;

// Log a value with a tag and return the value
Value* log(const std::string& tag, Value* value);

// Convert any Elm value to its string representation
std::string toString(Value* value);

// Crash with a message (for incomplete pattern matches, etc.)
[[noreturn]] void todo(const std::string& message);

} // namespace Elm::Kernel::Debug

#endif // ELM_KERNEL_DEBUG_HPP
