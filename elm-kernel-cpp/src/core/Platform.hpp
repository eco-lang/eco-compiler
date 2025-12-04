#ifndef ELM_KERNEL_PLATFORM_HPP
#define ELM_KERNEL_PLATFORM_HPP

#include <functional>

namespace Elm::Kernel::Platform {

// Forward declarations
struct Value;
struct Cmd;
struct Sub;
struct Task;
struct Process;

// Batch multiple commands into one
Cmd* batch(Value* commands);

// Map over a command
Cmd* map(std::function<Value*(Value*)> func, Cmd* cmd);

// Send a message to the application
void sendToApp(Value* router, Value* msg);

// Send a message to self (for effects managers)
Task* sendToSelf(Value* router, Value* msg);

// Create a worker program (no view)
Value* worker(Value* impl);

} // namespace Elm::Kernel::Platform

#endif // ELM_KERNEL_PLATFORM_HPP
