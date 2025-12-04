#ifndef ELM_KERNEL_SCHEDULER_HPP
#define ELM_KERNEL_SCHEDULER_HPP

#include <functional>

namespace Elm::Kernel::Scheduler {

// Forward declarations
struct Value;
struct Task;
struct Process;

// Create a successful task
Task* succeed(Value* value);

// Create a failed task
Task* fail(Value* error);

// Chain tasks together
Task* andThen(std::function<Task*(Value*)> callback, Task* task);

// Handle task errors
Task* onError(std::function<Task*(Value*)> callback, Task* task);

// Spawn a new process
Task* spawn(Task* task);

// Kill a running process
Task* kill(Process* process);

} // namespace Elm::Kernel::Scheduler

#endif // ELM_KERNEL_SCHEDULER_HPP
