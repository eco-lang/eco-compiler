#ifndef ECO_DEBUG_HPP
#define ECO_DEBUG_HPP

// A C++ namespace API for elm/core's `Debug` module that nothing calls.
//
// Elm code reaches `Debug.log`, `Debug.todo` and `Debug.toString` through the C-linkage exports declared in
// `KernelExports.h` and defined in `DebugExports.cpp`, not through these functions. They take a `Value`
// that is declared here and defined nowhere, so no caller can obtain a `Value` to pass, and they behave
// differently from the exports: `log` writes to `std::cout` rather than the runtime's output destination,
// `toString` returns a fixed string, and `todo` throws rather than exiting.

#include <string>

namespace Elm::Kernel::Debug {

/// An Elm value, declared but never defined.
struct Value;

/// Writes `tag`, `": "` and `toString(value)` and a newline to `std::cout`, and returns `value`.
Value* log(const std::string& tag, Value* value);

/// Returns `"<internals>"`, whatever `value` is.
std::string toString(Value* value);

/// Throws `std::runtime_error` with the text `"TODO: "` followed by `message`.
[[noreturn]] void todo(const std::string& message);

} // namespace Elm::Kernel::Debug

#endif // ECO_DEBUG_HPP
