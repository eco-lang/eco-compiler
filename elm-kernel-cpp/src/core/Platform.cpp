#include "Platform.hpp"
#include <stdexcept>

namespace Elm::Kernel::Platform {

Cmd* batch(Value* commands) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Platform.batch not implemented");
}

Cmd* map(std::function<Value*(Value*)> func, Cmd* cmd) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Platform.map not implemented");
}

void sendToApp(Value* router, Value* msg) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Platform.sendToApp not implemented");
}

Task* sendToSelf(Value* router, Value* msg) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Platform.sendToSelf not implemented");
}

Value* worker(Value* impl) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Platform.worker not implemented");
}

} // namespace Elm::Kernel::Platform
