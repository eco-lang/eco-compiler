/**
 * Elm Kernel Scheduler Module - Runtime Heap Integration
 *
 * The Scheduler implements Elm's cooperative task execution system.
 */

#include "Scheduler.hpp"
#include "allocator/Allocator.hpp"

namespace Elm::Kernel::Scheduler {

// ============================================================================
// Scheduler State (singleton)
// ============================================================================

SchedulerState& SchedulerState::instance() {
    static SchedulerState state;
    return state;
}

u64 SchedulerState::nextId() {
    std::lock_guard<std::mutex> lock(mutex_);
    return guid_++;
}

void SchedulerState::addToQueue(ProcessPtr proc) {
    std::lock_guard<std::mutex> lock(mutex_);
    queue_.push(std::move(proc));
}

ProcessPtr SchedulerState::popFromQueue() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (queue_.empty()) return nullptr;
    auto proc = queue_.front();
    queue_.pop();
    return proc;
}

bool SchedulerState::hasWork() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return !queue_.empty();
}

bool SchedulerState::isWorking() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return working_;
}

void SchedulerState::setWorking(bool w) {
    std::lock_guard<std::mutex> lock(mutex_);
    working_ = w;
}

// ============================================================================
// Task Constructors
// ============================================================================

TaskPtr succeed(HPointer value) {
    auto task = std::make_shared<Task>(TaskTag::Succeed);
    task->value = value;
    return task;
}

TaskPtr fail(HPointer error) {
    auto task = std::make_shared<Task>(TaskTag::Fail);
    task->value = error;
    return task;
}

TaskPtr binding(BindingFn fn) {
    auto task = std::make_shared<Task>(TaskTag::Binding);
    task->binding = std::move(fn);
    return task;
}

TaskPtr andThen(TaskCallback callback, TaskPtr task) {
    auto result = std::make_shared<Task>(TaskTag::AndThen);
    result->callback = std::move(callback);
    result->innerTask = std::move(task);
    return result;
}

TaskPtr onError(TaskCallback callback, TaskPtr task) {
    auto result = std::make_shared<Task>(TaskTag::OnError);
    result->callback = std::move(callback);
    result->innerTask = std::move(task);
    return result;
}

TaskPtr receive(TaskCallback callback) {
    auto result = std::make_shared<Task>(TaskTag::Receive);
    result->callback = std::move(callback);
    return result;
}

// ============================================================================
// Process Management
// ============================================================================

ProcessPtr rawSpawn(TaskPtr task) {
    auto& state = SchedulerState::instance();
    auto proc = std::make_shared<Process>(state.nextId());
    proc->root = task;
    enqueue(proc);
    return proc;
}

TaskPtr spawn(TaskPtr task) {
    return binding([task](Callback callback) -> std::function<void()> {
        auto proc = rawSpawn(task);

        // Create a Custom type wrapping the process ID
        // The process handle is represented as an int (process ID)
        HPointer procValue = alloc::allocInt(static_cast<i64>(proc->id));
        callback(procValue);

        return []() {}; // No kill function
    });
}

TaskPtr kill(ProcessPtr process) {
    return binding([process](Callback callback) -> std::function<void()> {
        if (process->root && process->root->tag == TaskTag::Binding) {
            if (process->root->kill) {
                process->root->kill();
            }
        }
        process->root = nullptr;
        callback(alloc::unit());
        return []() {};
    });
}

void rawSend(ProcessPtr process, HPointer msg) {
    process->mailbox.push_back(msg);
    enqueue(process);
}

TaskPtr send(ProcessPtr process, HPointer msg) {
    return binding([process, msg](Callback callback) -> std::function<void()> {
        rawSend(process, msg);
        callback(alloc::unit());
        return []() {};
    });
}

// ============================================================================
// Execution
// ============================================================================

void enqueue(ProcessPtr process) {
    auto& state = SchedulerState::instance();
    state.addToQueue(process);

    if (state.isWorking()) {
        return;
    }

    drain();
}

void drain() {
    auto& state = SchedulerState::instance();
    state.setWorking(true);

    while (auto proc = state.popFromQueue()) {
        step(proc);
    }

    state.setWorking(false);
}

void step(ProcessPtr process) {
    while (process->root) {
        auto rootTag = process->root->tag;

        if (rootTag == TaskTag::Succeed || rootTag == TaskTag::Fail) {
            // Pop stack until we find matching handler
            while (!process->stack.empty()) {
                auto& top = process->stack.back();
                bool isMatchingHandler =
                    (rootTag == TaskTag::Succeed && top->tag == TaskTag::AndThen) ||
                    (rootTag == TaskTag::Fail && top->tag == TaskTag::OnError);

                if (isMatchingHandler) {
                    break;
                }
                process->stack.pop_back();
            }

            if (process->stack.empty()) {
                // No handler, process terminates
                return;
            }

            // Call continuation
            auto handler = process->stack.back();
            process->stack.pop_back();

            if (handler->callback) {
                process->root = handler->callback(process->root->value);
            } else {
                return;
            }
        }
        else if (rootTag == TaskTag::Binding) {
            // Yield to async operation
            if (process->root->binding) {
                auto procWeak = process;  // Capture for callback
                process->root->kill = process->root->binding([procWeak](HPointer newValue) {
                    if (procWeak->root) {
                        procWeak->root = succeed(newValue);
                        enqueue(procWeak);
                    }
                });
            }
            return;
        }
        else if (rootTag == TaskTag::Receive) {
            // Check mailbox
            if (process->mailbox.empty()) {
                return;
            }

            // Get first message
            HPointer msg = process->mailbox.front();
            process->mailbox.erase(process->mailbox.begin());

            if (process->root->callback) {
                process->root = process->root->callback(msg);
            } else {
                return;
            }
        }
        else {
            // AND_THEN or ON_ERROR: push to stack, recurse into inner task
            process->stack.push_back(process->root);

            if (process->root->innerTask) {
                process->root = process->root->innerTask;
            } else {
                return;
            }
        }
    }
}

} // namespace Elm::Kernel::Scheduler
