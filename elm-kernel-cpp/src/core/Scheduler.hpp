#ifndef ECO_SCHEDULER_HPP
#define ECO_SCHEDULER_HPP

/**
 * Elm Kernel Scheduler Module - Runtime Heap Integration
 *
 * The Scheduler implements Elm's cooperative task execution system.
 * It's similar to a green thread / coroutine system.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <functional>
#include <memory>
#include <queue>
#include <mutex>
#include <vector>

namespace Elm::Kernel::Scheduler {

// ============================================================================
// Task Types
// ============================================================================

// Task tag values matching Elm's internal representation.
enum class TaskTag : u16 {
    Succeed  = 0,   // Immediately succeeds with value.
    Fail     = 1,   // Immediately fails with error.
    Binding  = 2,   // Async operation with callback and kill function.
    AndThen  = 3,   // Task chaining (monadic bind).
    OnError  = 4,   // Error handler.
    Receive  = 5    // Message receiver.
};

// Forward declarations.
struct Task;
struct Process;

using TaskPtr = std::shared_ptr<Task>;
using ProcessPtr = std::shared_ptr<Process>;

// Callback type for async operations.
using Callback = std::function<void(HPointer)>;

// Binding function: takes callback, returns kill function.
using BindingFn = std::function<std::function<void()>(Callback)>;

// Task callback: transforms value to next task.
using TaskCallback = std::function<TaskPtr(HPointer)>;

// ============================================================================
// Task Structure
// ============================================================================

struct Task {
    TaskTag tag;
    HPointer value;                          // For Succeed/Fail.
    BindingFn binding;                       // For Binding.
    std::function<void()> kill;              // Kill function for Binding.
    TaskCallback callback;                   // For AndThen/OnError/Receive.
    TaskPtr innerTask;                       // For AndThen/OnError.

    Task(TaskTag t) : tag(t), value{0, Const_Nil + 1, 0} {}
};

// ============================================================================
// Process Structure
// ============================================================================

struct Process {
    u64 id;
    TaskPtr root;
    std::vector<TaskPtr> stack;              // Continuation stack.
    std::vector<HPointer> mailbox;           // Pending messages.

    Process(u64 pid) : id(pid) {}
};

// ============================================================================
// Task Constructors
// ============================================================================

// Creates a Task that immediately succeeds with value.
TaskPtr succeed(HPointer value);

// Creates a Task that immediately fails with error.
TaskPtr fail(HPointer error);

// Creates a BINDING task for async operations.
TaskPtr binding(BindingFn fn);

// Chains tasks together (Task monad bind).
TaskPtr andThen(TaskCallback callback, TaskPtr task);

// Handles task errors.
TaskPtr onError(TaskCallback callback, TaskPtr task);

// Creates a RECEIVE task (for messages).
TaskPtr receive(TaskCallback callback);

// ============================================================================
// Process Management
// ============================================================================

// Spawns a new process, returns Task that succeeds with process handle.
TaskPtr spawn(TaskPtr task);

// Kills a running process.
TaskPtr kill(ProcessPtr process);

// Sends message to a process.
TaskPtr send(ProcessPtr process, HPointer msg);

// Raw spawn (internal use), creates process immediately.
ProcessPtr rawSpawn(TaskPtr task);

// Raw send (internal use), sends message immediately.
void rawSend(ProcessPtr process, HPointer msg);

// ============================================================================
// Execution
// ============================================================================

// Enqueues process for execution.
void enqueue(ProcessPtr process);

// Steps execution of a process.
void step(ProcessPtr process);

// Runs the scheduler until queue is empty.
void drain();

// ============================================================================
// Global Scheduler State
// ============================================================================

class SchedulerState {
public:
    static SchedulerState& instance();

    u64 nextId();
    void addToQueue(ProcessPtr proc);
    ProcessPtr popFromQueue();
    bool hasWork() const;
    bool isWorking() const;
    void setWorking(bool w);

private:
    SchedulerState() = default;
    u64 guid_ = 0;
    std::queue<ProcessPtr> queue_;
    bool working_ = false;
    mutable std::mutex mutex_;
};

} // namespace Elm::Kernel::Scheduler

#endif // ECO_SCHEDULER_HPP
