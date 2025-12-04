#include "Debug.hpp"
#include <stdexcept>

namespace Elm::Kernel::Debug {

Value* log(const std::string& tag, Value* value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Debug.log not implemented");
}

std::string toString(Value* value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Debug.toString not implemented");
}

[[noreturn]] void todo(const std::string& message) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Debug.todo not implemented");
}

} // namespace Elm::Kernel::Debug
