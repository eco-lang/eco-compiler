#ifndef ECO_DEBUG_HPP
#define ECO_DEBUG_HPP

#include <string>

namespace Elm::Kernel::Debug {

// Forward declaration for generic Elm value.
struct Value;

// Logs a value with a tag and returns the value unchanged.
Value* log(const std::string& tag, Value* value);

// Converts any Elm value to its string representation.
std::string toString(Value* value);

// Crashes with a message (for incomplete pattern matches, etc.).
[[noreturn]] void todo(const std::string& message);

} // namespace Elm::Kernel::Debug

#endif // ECO_DEBUG_HPP
