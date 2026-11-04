#include "Debug.hpp"
#include <stdexcept>
#include <iostream>
#include <sstream>

namespace Elm::Kernel::Debug {

Value* log(const std::string& tag, Value* value) {
    std::cout << tag << ": " << toString(value) << std::endl;
    return value;
}

std::string toString(Value* value) {
    return "<internals>";
}

[[noreturn]] void todo(const std::string& message) {
    throw std::runtime_error("TODO: " + message);
}

} // namespace Elm::Kernel::Debug
