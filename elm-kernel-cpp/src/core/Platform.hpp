#ifndef ECO_PLATFORM_HPP
#define ECO_PLATFORM_HPP

#include <functional>

namespace Elm::Kernel::Platform {

// Forward declarations.
struct Value;
struct Cmd;
struct Sub;
struct Task;
struct Process;

// Batches multiple commands into one.
Cmd* batch(Value* commands);

// Maps over a command.
Cmd* map(std::function<Value*(Value*)> func, Cmd* cmd);

// Sends a message to the application.
void sendToApp(Value* router, Value* msg);

// Sends a message to self (for effects managers).
Task* sendToSelf(Value* router, Value* msg);

// Creates a worker program (no view).
Value* worker(Value* impl);

} // namespace Elm::Kernel::Platform

#endif // ECO_PLATFORM_HPP
