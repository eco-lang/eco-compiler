#include "Time.hpp"
#include <stdexcept>

namespace Elm::Kernel::Time {

Task* now() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Time.now not implemented");
}

Task* here() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Time.here not implemented");
}

Value* getZoneName() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Time.getZoneName not implemented");
}

Process* setInterval(double interval, std::function<void(double)> callback) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Time.setInterval not implemented");
}

} // namespace Elm::Kernel::Time
