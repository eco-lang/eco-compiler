#ifndef ECO_PLATFORM_SCHEDULER_HPP
#define ECO_PLATFORM_SCHEDULER_HPP

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include <deque>
#include <mutex>
#include <atomic>
#include <condition_variable>
#include <cstdint>

namespace Elm::Platform {

class Scheduler {
public:
    static Scheduler& instance();

    // Task constructors - allocate heap Task objects
    HPointer taskSucceed(HPointer value);
    HPointer taskFail(HPointer error);
    HPointer taskBinding(HPointer callback);
    HPointer taskAndThen(HPointer callback, HPointer task);
    HPointer taskOnError(HPointer callback, HPointer task);
    HPointer taskReceive(HPointer callback);

    // Process API
    HPointer rawSpawn(HPointer rootTask);
    HPointer spawnTask(HPointer rootTask);
    void rawSend(HPointer proc, HPointer msg);
    HPointer killTask(HPointer proc);

    // Run queue management
    void enqueue(HPointer proc);
    void drain();

    // Event loop for single-threaded Elm execution
    void runEventLoop();
    void incrementPendingAsync();
    void decrementPendingAsync();

    // Closure calling helper: calls a 1-arg Elm closure, returns result
    static HPointer callClosure1(HPointer closurePtr, HPointer arg);
    // Calls a 2-arg Elm closure
    static HPointer callClosure2(HPointer closurePtr, HPointer arg1, HPointer arg2);
    // Calls a 4-arg Elm closure (for onEffects: router, cmds, subs, state)
    static HPointer callClosure4(HPointer closurePtr, HPointer arg1, HPointer arg2,
                                 HPointer arg3, HPointer arg4);

    u32 nextProcessId() { return nextProcId_.fetch_add(1); }

private:
    Scheduler();

    void stepProcess(uint64_t procEncoded);

    // Mailbox helpers (Elm List as queue)
    static void mailboxPushBack(Process* proc, HPointer msg);
    static bool mailboxPopFront(Process* proc, HPointer& outMsg);

    // Stack helpers (Elm List of StackFrame Custom objects)
    static void pushStack(Process* proc, u64 expectedTag, HPointer callback);
    static bool popStackMatching(Process* proc, u64 tag, HPointer& outCallback);

    struct RootedProc {
        uint64_t encoded;  // HPointer encoded as uint64_t for GC root registration
    };

    std::deque<RootedProc> runQueue_;
    bool working_ = false;
    std::mutex mutex_;
    std::condition_variable eventCV_;
    std::atomic<int> pendingAsync_{0};
    std::atomic<u32> nextProcId_{0};
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_SCHEDULER_HPP
