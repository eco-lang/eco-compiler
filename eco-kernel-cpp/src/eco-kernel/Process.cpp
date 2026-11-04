//===- Process.cpp - Process kernel module implementation -----------------===//
//
// `spawn` and `spawnProcess` are Binding Tasks whose bodies start the child
// with the runtime's `Elm::platform::spawnChild` (posix_spawnp, or
// CreateProcessW on Windows, never a fork).
//
// `wait` is an async-park binding. Its body parks the resume closure under a
// scheduler hold and submits the pid to the `WaitService` on the EcoKernel
// lane. `waitServiceDrain`, registered once as a scheduler async source,
// later turns each finished wait into a succeeding Task, resumes the parked
// closure with it, and releases the hold.
//
//===----------------------------------------------------------------------===//

#include "Process.hpp"
#include "KernelHelpers.hpp"
#include "TaskBinding.hpp"
#include "platform/Spawn.hpp"
#include "platform/WaitService.hpp"
#include <cerrno>
#include <cstdlib>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace Eco::Kernel::Process {

// Stdin pipe descriptors handed out by `spawnProcess`, keyed by the
// descriptor itself. Entries are added and never read or removed.
static std::unordered_map<int64_t, int> s_streamHandles;

namespace {

// Starts `cmd` with `args` directly (no shell), in this process's session,
// with stdout and stderr shared and stdin a pipe when `pipeStdin`, else
// shared. Returns the child; a nonzero `err` means it was not started.
Elm::platform::SpawnedChild startChild(const std::string& cmd, const std::vector<std::string>& args,
                                       bool pipeStdin) {
    Elm::platform::SpawnSpec spec;
    spec.program = cmd;
    spec.args = args;
    spec.shellKind = Elm::platform::kShellNone;
    Elm::platform::SpawnedChild child = Elm::platform::spawnChild(
        spec, pipeStdin ? Elm::platform::StdioMode::StdinPipe : Elm::platform::StdioMode::Inherit,
        /*newSession=*/false);
#if defined(_WIN32)
    // WaitService waits on the process handle (Spawn.hpp takeProcessHandle).
    if (child.err == 0) Elm::platform::registerProcessHandle(child.pid, child.process);
#endif
    return child;
}

// Binding body for `spawn`: starts the child named by `captured`, the tuple
// ( cmd, args ), and returns the Task that succeeds with its pid or fails
// with the IO error tuple. Unpacks `captured` before its first allocation.
HPointer spawnBody(HPointer captured) {
    HPointer cmdHP;
    HPointer argsHP;
    {
        Tuple2* tup = static_cast<Tuple2*>(
            Elm::Allocator::instance().resolve(captured));
        cmdHP = tup->a.p;
        argsHP = tup->b.p;
    }
    std::string cmdStr = toString(Export::encode(cmdHP));
    std::vector<std::string> argStrs = listToStringVector(Export::encode(argsHP));

    Elm::platform::SpawnedChild child = startChild(cmdStr, argStrs, /*pipeStdin=*/false);
    if (child.err != 0) return failErrno(child.err, cmdStr, "spawn failed");
    return succeedInt(child.pid);
}

// Binding body for `spawnProcess`: `captured` is a Record of five boxed
// fields, cmd, args, stdin_, stdout_, stderr_ in that order. Returns the
// Task that succeeds with ( stdinHandle, pid ) or fails with the IO error
// tuple.
HPointer spawnProcessBody(HPointer captured) {
    HPointer cmdHP, argsHP, stdinHP, stdoutHP, stderrHP;
    {
        Record* rec = static_cast<Record*>(
            Elm::Allocator::instance().resolve(captured));
        cmdHP    = rec->values[0].p;
        argsHP   = rec->values[1].p;
        stdinHP  = rec->values[2].p;
        stdoutHP = rec->values[3].p;
        stderrHP = rec->values[4].p;
    }
    std::string cmdStr = toString(Export::encode(cmdHP));
    std::vector<std::string> argStrs = listToStringVector(Export::encode(argsHP));
    std::string stdinCfg = toString(Export::encode(stdinHP));
    std::string stdoutCfg = toString(Export::encode(stdoutHP));
    std::string stderrCfg = toString(Export::encode(stderrHP));
    (void)stdoutCfg;  // ignored: stdout and stderr are always shared
    (void)stderrCfg;

    const bool pipeStdin = (stdinCfg == "pipe");
    Elm::platform::SpawnedChild child = startChild(cmdStr, argStrs, pipeStdin);
    if (child.err != 0) return failErrno(child.err, cmdStr, "spawn failed");

    using namespace Elm::alloc;
    HPointer stdinMaybe = nothing();
    if (pipeStdin) {
        int64_t handleId = child.stdinFd;
        s_streamHandles[handleId] = child.stdinFd;
        stdinMaybe = justKind(unboxedInt(handleId), 1);
    }

    // A Tuple2 of (Maybe Int, boxed; pid, unboxed Int): mask 0x4 marks
    // slot 1 as an unboxed Int.
    HPointer tup = tuple2(boxed(stdinMaybe), unboxedInt(child.pid), 0x4);
    return succeed(tup);
}

// Delivers every finished wait on the EcoKernel lane: resumes the closure
// parked under each token with a Task that succeeds with the exit code, and
// releases the token's hold. A token with no parked closure only has its hold
// released. Called by the scheduler as an async source, on its thread; GC
// points.
void waitServiceDrain() {
    auto& sched = Elm::Platform::Scheduler::instance();
    Elm::Platform::WaitService::Ready ready;
    while (Elm::Platform::WaitService::instance().tryPopReady(
               Elm::Platform::WaitLane::EcoKernel, ready)) {
        std::uint64_t token = ready.token;
        // A failed wait arrives as WaitService::kWaitFailedExitCode (-1), since
        // the Task cannot fail.
        std::int64_t exitCode = ready.exitCode;
        HPointer resumeClosure = sched.takePendingResume(token);
        if (Elm::alloc::isNil(resumeClosure)) {
            sched.releaseHold(token);
            continue;
        }
        // Both values are rooted across taskSucceedKind (which allocates a
        // Task with an unboxed Int payload, kind 1) and callClosure1 (which
        // may run the resume closure and collect).
        HPointer succeedTask = Elm::alloc::unit();
        {
            Elm::StackRootGuard guard(&resumeClosure, &succeedTask);
            succeedTask = sched.taskSucceedKind(
                Elm::alloc::unboxedInt(exitCode), /*kind=*/1);
            Elm::Platform::Scheduler::callClosure1(resumeClosure, succeedTask);
        }
        sched.releaseHold(token);
    }
}

// Registers `waitServiceDrain` as a scheduler async source, once per process.
void waitEnsureRegistered() {
    static std::once_flag flag;
    std::call_once(flag, [] {
        Elm::Platform::Scheduler::instance().registerAsyncSource(
            waitServiceDrain,
            [] {
                return Elm::Platform::WaitService::instance().hasReady(
                    Elm::Platform::WaitLane::EcoKernel);
            });
    });
}

// Async-park body for `wait`: `captured` is the tuple ( pid as an unboxed
// Int, unit ). Parks `resume` under a Task hold, submits the pid to the
// WaitService, and returns `unit()` as the kill handle. The result is
// delivered later by `waitServiceDrain`.
HPointer waitBody(HPointer captured, HPointer resume) {
    int64_t pid;
    {
        Tuple2* tup = static_cast<Tuple2*>(
            Elm::Allocator::instance().resolve(captured));
        pid = tup->a.i;
    }

    auto& sched = Elm::Platform::Scheduler::instance();
    std::uint64_t token = sched.parkResume(resume, Elm::Platform::HoldKind::Task, "Eco.Process.wait");
    Elm::Platform::WaitService::instance().submit(
        pid, token, Elm::Platform::WaitLane::EcoKernel);

    // No cancellation: the kill handle is unit.
    return Elm::alloc::unit();
}

} // anonymous namespace

uint64_t exit(int64_t code) {
    // Eager rather than a Task: there is no state after exit to deliver to.
    ::exit(static_cast<int>(code));
    // Unreachable.
    return 0;
}

uint64_t spawn(uint64_t cmd, uint64_t args) {
    HPointer cmdHP = Export::decode(cmd);
    HPointer argsHP = Export::decode(args);
    Elm::StackRootGuard g(&cmdHP, &argsHP);
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::boxed(cmdHP), Elm::alloc::boxed(argsHP), 0);
    return Export::encode(Eco::Kernel::makeBinding<spawnBody>(payload));
}

uint64_t spawnProcess(uint64_t cmd, uint64_t args,
                      uint64_t stdin_, uint64_t stdout_, uint64_t stderr_) {
    HPointer cmdHP    = Export::decode(cmd);
    HPointer argsHP   = Export::decode(args);
    HPointer stdinHP  = Export::decode(stdin_);
    HPointer stdoutHP = Export::decode(stdout_);
    HPointer stderrHP = Export::decode(stderr_);
    Elm::StackRootGuard g({&cmdHP, &argsHP, &stdinHP, &stdoutHP, &stderrHP});
    std::vector<Elm::Unboxable> fields(5);
    fields[0] = Elm::alloc::boxed(cmdHP);
    fields[1] = Elm::alloc::boxed(argsHP);
    fields[2] = Elm::alloc::boxed(stdinHP);
    fields[3] = Elm::alloc::boxed(stdoutHP);
    fields[4] = Elm::alloc::boxed(stderrHP);
    HPointer payload = Elm::alloc::record(fields, /*unboxed_mask=*/0);
    return Export::encode(Eco::Kernel::makeBinding<spawnProcessBody>(payload));
}

uint64_t wait(uint64_t handle) {
    // Registration happens when the Task is made, not when it runs.
    waitEnsureRegistered();
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::unboxedInt(static_cast<int64_t>(handle)),
        Elm::alloc::boxed(Elm::alloc::unit()),
        0x1);
    return Export::encode(
        Elm::Platform::makeAsyncBinding<waitBody>(payload));
}

} // namespace Eco::Kernel::Process
