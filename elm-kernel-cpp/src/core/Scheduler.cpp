#include "Scheduler.hpp"
#include <stdexcept>

namespace Elm::Kernel::Scheduler {

Task* succeed(Value* value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Scheduler.succeed not implemented");
}

Task* fail(Value* error) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Scheduler.fail not implemented");
}

Task* andThen(std::function<Task*(Value*)> callback, Task* task) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Scheduler.andThen not implemented");
}

Task* onError(std::function<Task*(Value*)> callback, Task* task) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Scheduler.onError not implemented");
}

Task* spawn(Task* task) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Scheduler.spawn not implemented");
}

Task* kill(Process* process) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Scheduler.kill not implemented");
}

} // namespace Elm::Kernel::Scheduler
