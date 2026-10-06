//===- Process.cpp - Process kernel module implementation -----------------===//
//
// Per KERNEL_TASK_IO_001 / plans/defer-eager-kernel-tasks-via-binding.md
// Phase 4a: `spawn`, `spawnProcess`, `wait` are returned as Task_Bindings so
// `fork`+`execvp`+`waitpid` happen inside the binding evaluator at
// scheduler-step time, not at kernel-call time.
//
// Phase 4a wraps `wait` in a binding with a BLOCKING evaluator — the
// scheduler thread still blocks on `waitpid` until the child exits. Phase 4b
// replaces this with a `WaitService` (SIGCHLD + waitpid(WNOHANG) worker)
// that hands the result back via the standard async-source drain. The
// blocking-evaluator wait is the stepping stone, not the destination.
//
// `exit(code)` is the explicit Q7 / KERNEL_TASK_IO_001 exemption: it never
// returns, so wrapping it in a Task is misleading. It stays eager.
//
//===----------------------------------------------------------------------===//

#include "Process.hpp"
#include "KernelHelpers.hpp"
#include "TaskBinding.hpp"
#include "platform/WaitService.hpp"
#include <cerrno>
#include <cstdlib>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#if !defined(_WIN32)
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace Eco::Kernel::Process {

// Map from child PID to pipe fd (stdin write end) if applicable.
static std::unordered_map<int64_t, int> s_streamHandles;

namespace {

// Body for `spawn`. Captured payload is tuple2(cmd, args).
HPointer spawnBody(HPointer captured) {
#if defined(_WIN32)
    // v1: process-spawning needs CreateProcessW + pipe plumbing per
    // build-on-windows item 9 — TODO. Return a clear error so callers see
    // it instead of silently hanging.
    (void)captured;
    return failErrno(ENOSYS, "", "Eco.Process.spawn not yet implemented on Windows");
#else
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

    std::vector<char*> argv;
    argv.push_back(const_cast<char*>(cmdStr.c_str()));
    for (auto& a : argStrs) {
        argv.push_back(const_cast<char*>(a.c_str()));
    }
    argv.push_back(nullptr);

    pid_t pid = fork();
    if (pid < 0) {
        int err = errno;
        return failErrno(err, cmdStr, "fork failed");
    }
    if (pid == 0) {
        execvp(argv[0], argv.data());
        ::_exit(127);
    }
    return succeedInt(static_cast<int64_t>(pid));
#endif
}

// Body for `spawnProcess`. Captured payload is a Record of 5 boxed fields
// in declaration order: [cmd, args, stdin_, stdout_, stderr_].
HPointer spawnProcessBody(HPointer captured) {
#if defined(_WIN32)
    (void)captured;
    return failErrno(ENOSYS, "", "Eco.Process.spawnProcess not yet implemented on Windows");
#else
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
    (void)stdoutCfg;  // "inherit" is the only currently-supported value
    (void)stderrCfg;

    int stdinPipe[2] = {-1, -1};
    bool pipeStdin = (stdinCfg == "pipe");
    if (pipeStdin) {
        if (pipe(stdinPipe) < 0) {
            int err = errno;
            return failErrno(err, cmdStr, "pipe failed");
        }
    }

    std::vector<char*> argv;
    argv.push_back(const_cast<char*>(cmdStr.c_str()));
    for (auto& a : argStrs) {
        argv.push_back(const_cast<char*>(a.c_str()));
    }
    argv.push_back(nullptr);

    pid_t pid = fork();
    if (pid < 0) {
        int err = errno;
        if (pipeStdin) {
            ::close(stdinPipe[0]);
            ::close(stdinPipe[1]);
        }
        return failErrno(err, cmdStr, "fork failed");
    }

    if (pid == 0) {
        if (pipeStdin) {
            dup2(stdinPipe[0], STDIN_FILENO);
            ::close(stdinPipe[0]);
            ::close(stdinPipe[1]);
        }
        execvp(argv[0], argv.data());
        ::_exit(127);
    }

    if (pipeStdin) {
        ::close(stdinPipe[0]);
    }

    using namespace Elm::alloc;
    std::vector<Unboxable> fields(2);
    fields[0].i = static_cast<int64_t>(pid);

    if (pipeStdin) {
        int64_t handleId = stdinPipe[1];
        s_streamHandles[handleId] = stdinPipe[1];
        fields[1].p = justKind(unboxedInt(handleId), 1);
    } else {
        fields[1].p = nothing();
    }

    HPointer rec = record(fields, 0b01);
    return succeed(rec);
#endif
}

// PHASE-4b WaitService drain. Pops (token, exitCode) pairs queued by the
// WaitService worker thread, allocates Task.succeed(exitCode) on the main
// thread, and resumes the parked closure via callClosure1. Mirrors
// Scheduler::processReadyAsync's TimerService loop. Runs from inside
// processReadyAsync's asyncSources_ iteration.
void waitServiceDrain() {
    auto& sched = Elm::Platform::Scheduler::instance();
    std::uint64_t token;
    int exitCode;
    while (Elm::Platform::WaitService::instance().tryPopResult(token, exitCode)) {
        HPointer resumeClosure = sched.takePendingResume(token);
        if (Elm::alloc::isNil(resumeClosure)) {
            sched.decrementPendingAsync();
            continue;
        }
        // Root resumeClosure + succeedTask across taskSucceedKind (which
        // allocates a Tag_Task with an unboxed Int payload, kind=1) and
        // callClosure1 (which may evaluate the resume closure and GC).
        HPointer succeedTask = Elm::alloc::unit();
        {
            Elm::StackRootGuard guard(&resumeClosure, &succeedTask);
            succeedTask = sched.taskSucceedKind(
                Elm::alloc::unboxedInt(static_cast<int64_t>(exitCode)), /*kind=*/1);
            Elm::Platform::Scheduler::callClosure1(resumeClosure, succeedTask);
        }
        sched.decrementPendingAsync();
    }
}

void waitEnsureRegistered() {
    static std::once_flag flag;
    std::call_once(flag, [] {
        Elm::Platform::Scheduler::instance().registerAsyncSource(
            waitServiceDrain,
            [] { return Elm::Platform::WaitService::instance().hasReady(); });
    });
}

// PHASE-4b async-park body for `wait`. Captured payload is
// tuple2(pid [unboxed Int], unit). Registers the resume token with the
// scheduler, submits the pid to the WaitService worker, and returns the
// kill handle. The actual `taskSucceed(exitCode)` is delivered later by
// `waitServiceDrain` on the main thread.
HPointer waitBody(HPointer captured, HPointer resume) {
    int64_t pid;
    {
        Tuple2* tup = static_cast<Tuple2*>(
            Elm::Allocator::instance().resolve(captured));
        pid = tup->a.i;
    }

    auto& sched = Elm::Platform::Scheduler::instance();
    std::uint64_t token = sched.registerPendingResume(resume);
    sched.incrementPendingAsync();
    Elm::Platform::WaitService::instance().submit(pid, token);

    // Kill handle: Unit placeholder (no cancellation yet).
    return Elm::alloc::unit();
}

} // anonymous namespace

uint64_t exit(int64_t code) {
    // EXEMPT from KERNEL_TASK_IO_001 (Q7): `exit` never returns. Wrapping in
    // a Task / binding would be misleading. The scheduler never sees the
    // post-exit state, so there is no Task to deliver.
    ::exit(static_cast<int>(code));
    // Never returns.
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
    // PHASE-4b: WaitService worker handles waitpid in a separate thread;
    // the binding evaluator only parks the resume + submits the pid.
    waitEnsureRegistered();
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::unboxedInt(static_cast<int64_t>(handle)),
        Elm::alloc::boxed(Elm::alloc::unit()),
        0x1);
    return Export::encode(
        Elm::Platform::makeAsyncBinding<waitBody>(payload));
}

} // namespace Eco::Kernel::Process
