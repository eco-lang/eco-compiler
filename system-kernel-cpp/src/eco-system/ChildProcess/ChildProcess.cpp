//===- ChildProcess.cpp - eco/system kernel module ChildProcess -----------===//
//
// How a run job reaches completion. A run completes only when two things are in: the child's exit, which the
// WaitService reports, and its output, which a collector posts. They arrive in either order, through two drains,
// and each drain records its event in the job and calls `advanceJob`, which decides what the job does next.
//
// The *collector* is a detached thread, one per run, that reads the child's stdout and stderr pipes into
// `std::string`s and posts them as one `RunOutput`. It touches no Elm value. It stops when both pipes have reached
// end of file, when either stream passes `maxBytes`, or when the eco thread writes to its wake pipe, which it does
// for a killed job whose child has exited, so that a process holding the pipes open cannot delay the result. Once
// it has started, only the collector closes the two output pipes, and the wake pipe is closed when both the job
// and the collector have dropped their `RunCollector`. `run` does not read through an `FdChannel`, because channel
// results are delivered through the one channel dispatch the stream table owns. On Windows, where pipes cannot be
// polled, the collector reads the two pipes with blocking reads, stderr on a second thread, and has no wake pipe.
//
// The runDuration timer is a closure parked with `Scheduler::parkResume`, whose token is scheduled on the
// `TimerService`; when the timer fires the Scheduler calls the closure with the job id it captured. Both
// completions erase the job before withdrawing the timer, so a timer that fires afterwards finds no job.
//
//===----------------------------------------------------------------------===//

#include "eco-system/ChildProcess/ChildProcess.hpp"

#include "eco-system/Core/AsyncSources.hpp"
#include "eco-system/Core/FdChannel.hpp"   // makeCloexecPipe

#include "platform/TimerService.hpp"
#include "platform/WaitService.hpp"

#include <atomic>
#include <cerrno>
#include <cstring>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

#ifndef _WIN32
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#else
#include <io.h>
#endif

namespace Eco::System {

using ::Elm::Platform::TimerService;
using ::Elm::Platform::WaitLane;
using ::Elm::Platform::WaitService;

// ---------------------------------------------------------------------------
// Decoders
// ---------------------------------------------------------------------------

bool isElmTrue(HPointer b) {
    return ::Elm::hpBits(b) == ::Elm::hpBits(alloc::elmTrue());
}

void decodeProgram(HPointer progTuple, SpawnSpec& spec) {
    HPointer programHP, argsHP;
    {
        Tuple2* t = asTuple2(progTuple);
        programHP = t->a.p;
        argsHP = t->b.p;
    }
    spec.program = toStdString(programHP);
    spec.args = ::Eco::Kernel::listToStringVector(enc(argsHP));
}

void decodeShell(HPointer shellTuple, SpawnSpec& spec) {
    Tuple2* t = asTuple2(shellTuple);
    spec.shellKind = static_cast<int>(t->a.i);
    spec.customShell = toStdString(t->b.p);
}

void decodeCwd(HPointer cwdTuple, SpawnSpec& spec) {
    Tuple2* t = asTuple2(cwdTuple);
    spec.inheritCwd = isElmTrue(t->a.p);
    spec.cwd = toStdString(t->b.p);
}

void decodeEnv(HPointer envTuple, SpawnSpec& spec) {
    HPointer pairs;
    {
        Tuple2* t = asTuple2(envTuple);
        spec.envMode = static_cast<int>(t->a.i);
        pairs = t->b.p;
    }
    spec.env.clear();
    for (alloc::ListCursor c(pairs); !c.done(); c.next()) {
        Tuple2* kv = asTuple2(c.current().p);
        spec.env.emplace_back(toStdString(kv->a.p), toStdString(kv->b.p));
    }
}

// ---------------------------------------------------------------------------
// Job table
// ---------------------------------------------------------------------------

Registry<ChildJob>& childJobs() {
    static auto* r = new Registry<ChildJob>("eco-system-child-jobs");   // never deleted, as Registry requires
    return *r;
}

// ---------------------------------------------------------------------------
// Run output collector
// ---------------------------------------------------------------------------

/// The state a run job shares with its collector thread: the pipes to read, the output limit and the wake pipe.
///
/// It is held by `shared_ptr` from the job and from the collector, and its destructor closes the wake pipe's two
/// ends, so the pipe lasts until both are done with it. It does not close `outFd` and `errFd`; the collector closes
/// them, or `startCollector` when no collector starts. Windows has no wake pipe.
struct RunCollector {
    int outFd = -1;
    int errFd = -1;
    int wake[2] = {-1, -1};   // A byte written to wake[1] tells the collector to stop.
    size_t maxBytes = 0;      // The output limit of each stream, in bytes; 0 means none.
    int64_t jobId = 0;

    ~RunCollector() {
#ifndef _WIN32
        if (wake[0] >= 0) ::close(wake[0]);
        if (wake[1] >= 0) ::close(wake[1]);
#endif
    }
};

namespace {

/// What a collector posts for one run: the output it read, and whether a stream passed the limit.
struct RunOutput {
    int64_t jobId = 0;
    std::string out, err;
    bool overflow = false;
};

/// The queue through which collector threads hand `RunOutput`s to the eco thread.
struct RunOutputQueue {
    std::mutex m;                    // Guards `q`.
    std::deque<RunOutput> q;
    std::atomic<size_t> count{0};    // The size of `q`, changed under `m` and read without it.
    Scheduler* sched;                // The Scheduler to wake; never null.
    /// Creates the queue and binds the Scheduler, which must happen on the eco thread.
    RunOutputQueue() : sched(&Scheduler::instance()) {}
};

/// Returns the run output queue, created on the first call, which must be on the eco thread, and never destroyed,
/// so a collector thread still running at exit never uses a destroyed queue.
RunOutputQueue& runOutputs() {
    static auto* q = new RunOutputQueue();
    return *q;
}

/// Queues `r` for the run output drain and wakes the Scheduler. May be called from any thread once the queue
/// exists.
void postRunOutput(RunOutput r) {
    auto& q = runOutputs();
    {
        std::lock_guard<std::mutex> lk(q.m);
        q.q.push_back(std::move(r));
        q.count.fetch_add(1, std::memory_order_acq_rel);
    }
    q.sched->notifyWorkAvailableFromAsync();   // Outside q.m, as AsyncSources requires.
}

/// Moves the oldest queued output into `out` and returns true, or returns false, leaving `out` unchanged, if there
/// is none.
bool tryPopRunOutput(RunOutput& out) {
    auto& q = runOutputs();
    std::lock_guard<std::mutex> lk(q.m);
    if (q.q.empty()) return false;
    out = std::move(q.q.front());
    q.q.pop_front();
    q.count.fetch_sub(1, std::memory_order_acq_rel);
    return true;
}

/// Returns whether any run output is queued. It takes no lock.
bool runOutputReady() { return runOutputs().count.load(std::memory_order_acquire) > 0; }

#ifndef _WIN32
/// Runs one collector: reads `c`'s two pipes until both reach end of file, a stream passes `c->maxBytes`, a stop is
/// requested on the wake pipe, or `poll` fails; then cuts each stream to `c->maxBytes`, closes both pipes and posts
/// what it read. A read error on a pipe other than `EINTR` or `EAGAIN` counts as its end. Runs on its own thread.
void collectRunOutput(std::shared_ptr<RunCollector> c) {
    RunOutput r;
    r.jobId = c->jobId;
    bool outOpen = c->outFd >= 0, errOpen = c->errFd >= 0;
    std::vector<char> buf(64 * 1024);
    auto readInto = [&](int fd, std::string& dst, bool& open) {
        ssize_t k = ::read(fd, buf.data(), buf.size());
        if (k > 0) {
            dst.append(buf.data(), static_cast<size_t>(k));
        } else if (k == 0 || (errno != EINTR && errno != EAGAIN)) {
            open = false;
        }
    };
    while ((outOpen || errOpen) && !r.overflow) {
        struct pollfd p[3];
        int n = 0, iOut = -1, iErr = -1;
        if (outOpen) { iOut = n; p[n++] = {c->outFd, POLLIN, 0}; }
        if (errOpen) { iErr = n; p[n++] = {c->errFd, POLLIN, 0}; }
        int iWake = n;
        p[n++] = {c->wake[0], POLLIN, 0};
        int rc = ::poll(p, static_cast<nfds_t>(n), -1);
        if (rc < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (p[iWake].revents) break;
        const short ready = POLLIN | POLLHUP | POLLERR | POLLNVAL;
        if (iOut >= 0 && (p[iOut].revents & ready)) readInto(c->outFd, r.out, outOpen);
        if (iErr >= 0 && (p[iErr].revents & ready)) readInto(c->errFd, r.err, errOpen);
        if (c->maxBytes > 0 && (r.out.size() > c->maxBytes || r.err.size() > c->maxBytes)) {
            r.overflow = true;
        }
    }
    if (c->maxBytes > 0) {
        if (r.out.size() > c->maxBytes) r.out.resize(c->maxBytes);
        if (r.err.size() > c->maxBytes) r.err.resize(c->maxBytes);
    }
    if (c->outFd >= 0) ::close(c->outFd);
    if (c->errFd >= 0) ::close(c->errFd);
    postRunOutput(std::move(r));
}
#else
/// Reads the CRT descriptor `fd` into `dst` until end of file, a read error, or `over` is set, then closes `fd`.
/// Sets `over` once `dst` passes `maxBytes`, when that is not 0, so the other stream's reader stops after its next
/// read too. Closing a stream as soon as it is done gives a child still writing to it a broken pipe rather than a
/// full one.
void drainRunPipe(int fd, std::string& dst, size_t maxBytes, std::atomic<bool>& over) {
    std::vector<char> buf(64 * 1024);
    while (!over.load(std::memory_order_relaxed)) {
        int k = ::_read(fd, buf.data(), static_cast<unsigned>(buf.size()));
        if (k > 0) {
            dst.append(buf.data(), static_cast<size_t>(k));
            if (maxBytes > 0 && dst.size() > maxBytes) over.store(true, std::memory_order_relaxed);
        } else if (k == 0 || errno != EINTR) {
            break;
        }
    }
    ::_close(fd);
}

/// Runs one collector on Windows, where the pipes cannot be polled: reads stderr on a second thread and stdout on
/// this one with blocking reads, each to end of file or until a stream passes `c->maxBytes`; then cuts each stream
/// to `c->maxBytes` and posts what it read. If the second thread cannot be started, stderr is read after stdout.
/// It cannot be told to stop: a killed run waits for its pipes to close. Runs on its own thread.
void collectRunOutput(std::shared_ptr<RunCollector> c) {
    RunOutput r;
    r.jobId = c->jobId;
    std::atomic<bool> over{false};
    std::thread errReader;
    bool errOnThread = false;
    if (c->errFd >= 0) {
        try {
            errReader = std::thread(drainRunPipe, c->errFd, std::ref(r.err), c->maxBytes, std::ref(over));
            errOnThread = true;
        } catch (...) {
        }
    }
    if (c->outFd >= 0) drainRunPipe(c->outFd, r.out, c->maxBytes, over);
    if (errOnThread) errReader.join();
    else if (c->errFd >= 0) drainRunPipe(c->errFd, r.err, c->maxBytes, over);
    r.overflow = over.load();
    if (c->maxBytes > 0) {
        if (r.out.size() > c->maxBytes) r.out.resize(c->maxBytes);
        if (r.err.size() > c->maxBytes) r.err.resize(c->maxBytes);
    }
    postRunOutput(std::move(r));
}
#endif

// ---------------------------------------------------------------------------
// Timer (runDuration)
// ---------------------------------------------------------------------------

/// Withdraws the runDuration timer `timerToken`, if it is not 0, as `Elm::Platform::withdrawParkedTimer` does:
/// its closure is discarded and its hold is released once, whether or not it has already fired.
void cancelTimer(uint64_t timerToken) {
    if (timerToken == 0) return;
    ::Elm::Platform::withdrawParkedTimer(timerToken);
}

void advanceJob(int64_t jobId);

/// Kills job `jobId` for a runDuration expiry or a killed run Task. If its child has not exited it kills the job,
/// as `killJob` does. If the child has exited but a run's output is still open, as when a process the child started
/// keeps the pipes open, it marks the run killed and advances it, so the collector is told to stop and the output
/// stops being waited for; `advanceJob` may then complete and erase the job. Does nothing if there is no job
/// `jobId`, or for a job whose exit and output are both in.
void killRun(int64_t jobId) {
    ChildJob* j = childJobs().find(jobId);
    if (!j) return;
    if (!j->exited) {
        killJob(jobId);
    } else if (j->kind == JobKind::Run && !j->outputDone) {
        j->killed = true;
        advanceJob(jobId);
    }
}

/// Handles the expiry of a runDuration timer: the evaluator of the closure `makeTimerClosure` builds. `args[0]` is
/// the job id, captured unboxed; `args[1]` is the Task the Scheduler passes, which is ignored. Returns the word for
/// `()`. It kills the job with `killRun`; a job that is gone is ignored.
void* runDurationEval(void* args[]) {
    int64_t jobId = static_cast<int64_t>(reinterpret_cast<uint64_t>(args[0]));
    if (ChildJob* j = childJobs().find(jobId)) {
        j->timerToken = 0;   // Fired: the Scheduler releases its hold, so cancelTimer must not.
        killRun(jobId);
    }
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

/// Allocates the runDuration timer's closure for job `jobId`, with `runDurationEval` as its evaluator and the job
/// id captured, waiting for the one argument the Scheduler supplies.
HPointer makeTimerClosure(int64_t jobId) {
    HPointer cl = alloc::allocClosureK(&runDurationEval, /*max_values=*/2, PK_Boxed);
    void* p = Allocator::instance().resolve(cl);   // Valid: nothing allocates before the capture.
    alloc::closureCapture(p, alloc::unboxedInt(jobId), PK_Int);
    return cl;
}

// ---------------------------------------------------------------------------
// Completion
// ---------------------------------------------------------------------------

/// Allocates an Elm Bytes value holding a copy of `b`.
HPointer makeBytes(const std::string& b) {
    if (b.empty()) return alloc::emptyBytes();
    alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(b.size());
    std::memcpy(bb.bytes, b.data(), b.size());   // `bb.bytes` is valid: nothing allocates in between.
    return bb.hp;
}

/// Completes run job `jobId`, whose exit and output must both be in, with the result `childProcessRunBody`
/// describes, and erases the job. The resume is called only if it is still parked, since killing the Task takes
/// it; the job's hold is released afterwards either way. Does nothing if there is no job `jobId`.
void completeRun(int64_t jobId) {
    ChildJob* j = childJobs().find(jobId);
    if (!j) return;
    uint64_t token = j->resumeToken;
    uint64_t timerToken = j->timerToken;
    HoldToken hold = j->hold;
    bool killed = j->killed || j->overflow;
    bool waitFailed = j->waitFailed;
    int raw = j->rawStatus;
    std::string out = std::move(j->out), err = std::move(j->err);
    childJobs().erase(jobId);   // `j` dangles from here.
    cancelTimer(timerToken);

    int64_t code = -1;
    bool success = false;
#ifndef _WIN32
    if (!killed && !waitFailed && WIFEXITED(raw)) {
        code = WEXITSTATUS(raw);
        success = code == 0;
    }
#else
    // Windows has no exit/signal split: the exit code, never negative, is the outcome.
    if (!killed && !waitFailed) {
        code = WaitService::exitCodeFromStatus(raw);
        success = code == 0;
    }
#endif

    auto& s = Scheduler::instance();
    HPointer resume = s.takePendingResume(token);
    if (!alloc::isNil(resume)) {   // Nil: the Task was killed.
        HPointer outHP = alloc::listNil();
        HPointer errHP = alloc::listNil();
        HPointer task = alloc::listNil();
        Elm::StackRootGuard g({&resume, &outHP, &errHP, &task});
        if (success) {
            outHP = makeBytes(out);
            errHP = makeBytes(err);
            task = succeed(alloc::tuple2(alloc::boxed(outHP), alloc::boxed(errHP), 0));
        } else {
            task = failRun(/*ProgramError*/ 1, "", static_cast<int>(code), out, err);
        }
        Scheduler::callClosure1(resume, task);
    }
    if (hold != kNoHold) s.releaseHold(hold);
}

/// Completes spawn job `jobId`, whose exit must be in, and erases the job. Does nothing if there is no such job.
///
/// It ends the Elm process standing for the child by resuming it with `Task.succeed ()`, if that process has parked
/// and `Process.kill` has not taken its resume. It then sends the program `onExit ( exitCode, signal )` through the
/// router and drains the Scheduler, provided both are set and the tagger is not a constant. `exitCode` is the
/// WaitService's exit code: the exit status, 128 plus the signal for a signal death, or
/// `WaitService::kWaitFailedExitCode` for a failed wait. `signal` is the signal number for a signal death,
/// otherwise 0, and always 0 on Windows. The hold, if any, is released last, so it covers the delivery.
void completeSpawn(int64_t jobId) {
    ChildJob* j = childJobs().find(jobId);
    if (!j) return;
    uint64_t token = j->resumeToken;
    uint64_t timerToken = j->timerToken;
    HoldToken hold = j->hold;
    int raw = j->rawStatus;
    bool waitFailed = j->waitFailed;
    HPointer router = dec(j->routerEnc);
    HPointer tagger = dec(j->onExitEnc);
    // Nothing has allocated since the decode, so the words are current; root them before the job goes.
    HPointer resume = alloc::listNil();
    HPointer task = alloc::listNil();
    HPointer arg = alloc::listNil();
    HPointer msg = alloc::listNil();
    Elm::StackRootGuard g({&router, &tagger, &resume, &task, &arg, &msg});
    childJobs().erase(jobId);
    cancelTimer(timerToken);

    int64_t code = waitFailed ? WaitService::kWaitFailedExitCode : WaitService::exitCodeFromStatus(raw);
    int64_t sig = 0;
#ifndef _WIN32
    if (!waitFailed && WIFSIGNALED(raw)) sig = WTERMSIG(raw);
#endif

    auto& s = Scheduler::instance();
    resume = s.takePendingResume(token);
    if (!alloc::isNil(resume)) {   // Nil: not parked yet, or Process.kill took it.
        task = succeedUnit();
        Scheduler::callClosure1(resume, task);
    }
    if (!alloc::isNil(tagger) && !alloc::isConstant(tagger) && !alloc::isNil(router)) {
        arg = alloc::tuple2(alloc::unboxedInt(code), alloc::unboxedInt(sig), 0x5);
        msg = Scheduler::callClosure1(tagger, arg);
        PlatformRuntime::instance().sendToApp(router, msg);
        s.drain();
    }
    if (hold != kNoHold) s.releaseHold(hold);
}

/// Moves job `jobId` forward after an event has been recorded in it, and completes it when it can. A spawn job
/// completes once its exit is in. For a run job, an overflow kills the job if its child has not exited; a killed
/// job whose child has exited tells its collector to stop, once; and the job completes once its exit and output
/// are both in. Does nothing if there is no such job.
void advanceJob(int64_t jobId) {
    ChildJob* j = childJobs().find(jobId);
    if (!j) return;
    if (j->kind == JobKind::Spawn) {
        if (j->exited) completeSpawn(jobId);
        return;
    }
    if (j->outputDone && j->overflow && !j->exited && !j->killed) killJob(jobId);
    j = childJobs().find(jobId);
    if (!j) return;
    if (j->exited && !j->outputDone && j->killed && !j->stopRequested && j->collector) {
#ifndef _WIN32
        j->stopRequested = true;
        unsigned char b = 1;
        ssize_t r;
        do { r = ::write(j->collector->wake[1], &b, 1); } while (r < 0 && errno == EINTR);
#endif
    }
    if (j->exited && j->outputDone) completeRun(jobId);
}

// --- Drains, called by the eco/system async source ---------------------------

/// Returns whether the WaitService has an exit queued on the EcoSystem lane.
bool waitReady() { return WaitService::instance().hasReady(WaitLane::EcoSystem); }

/// Records every queued exit in its job and advances the job, then drains the Scheduler if any job was found.
void waitDrain() {
    bool any = false;
    WaitService::Ready r;
    while (WaitService::instance().tryPopReady(WaitLane::EcoSystem, r)) {
        int64_t jobId = static_cast<int64_t>(r.token);
        ChildJob* j = childJobs().find(jobId);
        if (!j) continue;   // Its job is gone, as after a heap reset.
        j->exited = true;
        j->rawStatus = r.rawStatus;
        j->waitFailed = r.error != 0;
        advanceJob(jobId);
        any = true;
    }
    if (any) Scheduler::instance().drain();
}

/// Records every queued run output in its job and advances the job, then drains the Scheduler if any job was found.
void runOutputDrain() {
    bool any = false;
    RunOutput r;
    while (tryPopRunOutput(r)) {
        ChildJob* j = childJobs().find(r.jobId);
        if (!j) continue;
        j->outputDone = true;
        j->overflow = r.overflow;
        j->out = std::move(r.out);
        j->err = std::move(r.err);
        advanceJob(r.jobId);
        any = true;
    }
    if (any) Scheduler::instance().drain();
}

/// Starts a collector thread for `col` and returns true, or returns false, closing the output pipes and setting
/// `col`'s output fds to -1, if the thread (or, on POSIX, the wake pipe) cannot be made.
bool startCollector(const std::shared_ptr<RunCollector>& col) {
#ifndef _WIN32
    if (makeCloexecPipe(col->wake, /*nonBlocking=*/true) == 0) {
        try {
            std::thread(collectRunOutput, col).detach();
            return true;
        } catch (...) {
        }
    }
    if (col->outFd >= 0) ::close(col->outFd);
    if (col->errFd >= 0) ::close(col->errFd);
#else
    try {
        std::thread(collectRunOutput, col).detach();
        return true;
    } catch (...) {
    }
    if (col->outFd >= 0) ::_close(col->outFd);
    if (col->errFd >= 0) ::_close(col->errFd);
#endif
    col->outFd = col->errFd = -1;
    return false;
}

/// Kills, as `killRun` does, the run job whose resume token is `token`, if there is one, and returns false. It is
/// the `CancelFn` of a run's kill handle; returning false leaves the hold to the job, which releases it when it
/// completes (at once, if the child has exited and only its output was still awaited).
bool cancelRunByToken(uint64_t token) {
    for (auto& [id, job] : childJobs().map()) {
        if (job.kind == JobKind::Run && job.resumeToken == token) {
            killRun(id);   // may erase the job: the iterator is not used again
            return false;
        }
    }
    return false;
}

} // namespace

void abandonJob(int64_t jobId) {
    ChildJob* j = childJobs().find(jobId);
    if (!j) return;
    uint64_t timerToken = j->timerToken;
    j->timerToken = 0;
#ifndef _WIN32
    if (j->pid > 0) {
        ::kill(static_cast<pid_t>(j->pid), SIGKILL);
        int st;
        while (::waitpid(static_cast<pid_t>(j->pid), &st, 0) < 0 && errno == EINTR) {}
    }
    if (j->collector && j->collector->wake[1] >= 0) {
        unsigned char b = 1;
        ssize_t r;
        do { r = ::write(j->collector->wake[1], &b, 1); } while (r < 0 && errno == EINTR);
    }
#endif
    childJobs().erase(jobId);   // `j` dangles from here.
    cancelTimer(timerToken);
}

void ensureChildDrains() {
    static bool done = false;   // Unguarded: eco thread only.
    if (done) return;
    done = true;
    (void)runOutputs();          // Creates the queue, binding the Scheduler, on the eco thread.
    (void)WaitService::instance();
    addDrainSource(&waitDrain, &waitReady);
    addDrainSource(&runOutputDrain, &runOutputReady);
}

#if ECO_TEST_HOOKS
namespace {
// The run fault hook; null unless a test installed one. Eco thread only.
RunFaultHook gRunFaultHook = nullptr;
// Calls the run fault hook, if any, for `site`.
inline void runFaultPoint(RunFaultSite site) {
    if (gRunFaultHook) gRunFaultHook(site);
}
} // namespace

RunFaultHook setRunFaultHookForTest(RunFaultHook hook) {
    RunFaultHook prev = gRunFaultHook;
    gRunFaultHook = hook;
    return prev;
}
#endif

void startJobWatch(int64_t jobId, int64_t runDurationMs) {
    ensureChildDrains();
    if (runDurationMs > kMaxRunDurationMs) runDurationMs = 0;   // beyond any timer: no limit
    HPointer timer = alloc::listNil();
    Elm::StackRootGuard g(&timer);
    if (runDurationMs > 0) timer = makeTimerClosure(jobId);   // Allocates, so before the job is looked up.
    ChildJob* j = childJobs().find(jobId);
    if (!j) return;
    int64_t pid = j->pid;
    uint64_t tt = 0;
    bool scheduled = false;
    try {
        if (runDurationMs > 0) {
            auto& s = Scheduler::instance();
            tt = s.parkResume(timer, HoldKind::Task, "ChildProcess.runDuration");
            j->timerToken = tt;
            TimerService::instance().schedule(static_cast<double>(runDurationMs), tt);
            scheduled = true;
        }
#if ECO_TEST_HOOKS
        runFaultPoint(RunFaultSite::BeforeWaitSubmit);
#endif
        WaitService::instance().submit(pid, static_cast<uint64_t>(jobId), WaitLane::EcoSystem);
    } catch (...) {
        // Nothing is watched: withdraw the timer, releasing its hold once, before the exception goes on.
        if (tt != 0) {
            if (ChildJob* jj = childJobs().find(jobId)) jj->timerToken = 0;
            if (scheduled) {
                cancelTimer(tt);
            } else {
                auto& s = Scheduler::instance();
                (void)s.takePendingResume(tt);
                s.releaseHold(tt);
            }
        }
        throw;
    }
}

void killJob(int64_t jobId) {
    ChildJob* j = childJobs().find(jobId);
    if (!j || j->exited) return;
    j->killed = true;
#ifndef _WIN32
    if (j->pid > 0) ::kill(static_cast<pid_t>(j->pid), SIGTERM);
#endif
}

bool cancelSpawnByToken(uint64_t token) {
    for (auto& [id, job] : childJobs().map()) {
        if (job.kind == JobKind::Spawn && job.resumeToken == token) {
            killJob(id);
            break;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------

HPointer childProcessRunBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(RunErr, resume, token, counted,
        // Copy every input out of the heap before anything allocates.
        SpawnSpec spec;
        int64_t maxBytes = 0, runMs = 0;
        {
            HPointer progHP, optsHP, envLimHP;
            {
                Tuple3* t = asTuple3(captured);
                progHP = t->a.p;
                optsHP = t->b.p;
                envLimHP = t->c.p;
            }
            decodeProgram(progHP, spec);
            HPointer shellHP, cwdHP;
            {
                Tuple2* t = asTuple2(optsHP);
                shellHP = t->a.p;
                cwdHP = t->b.p;
            }
            decodeShell(shellHP, spec);
            decodeCwd(cwdHP, spec);
            HPointer envHP, limHP;
            {
                Tuple2* t = asTuple2(envLimHP);
                envHP = t->a.p;
                limHP = t->b.p;
            }
            decodeEnv(envHP, spec);
            Tuple2* lim = asTuple2(limHP);
            maxBytes = lim->a.i;
            runMs = lim->b.i;
        }

        auto& s = Scheduler::instance();
        ensureChildDrains();
        SpawnedChild ch = spawnChild(spec, StdioMode::RunPipes, /*newSession=*/false);
        if (ch.err != 0) {
            HPointer task = failRun(/*InitError*/ 0, errnoName(ch.err), 0, "", "");
            Elm::StackRootGuard g(&task);
            Scheduler::callClosure1(resume, task);
            return alloc::unit();
        }
#if defined(_WIN32)
        // The WaitService takes this handle by pid (runtime platform/Spawn.hpp `takeProcessHandle`), waits on it
        // and closes it, so it is registered here and the record gives it up.
        Elm::platform::registerProcessHandle(ch.pid, ch.process);
        ch.process = nullptr;
#endif

        auto col = std::make_shared<RunCollector>();
        col->outFd = ch.stdoutFd;
        col->errFd = ch.stderrFd;
        col->maxBytes = maxBytes > 0 ? static_cast<size_t>(maxBytes) : 0;

        ChildJob job;
        job.kind = JobKind::Run;
        job.pid = ch.pid;
        job.collector = col;
        int64_t jobId = childJobs().insert(std::move(job));
        col->jobId = jobId;

        // Park and hold before starting the collector and the wait. The job owns the hold, so `counted` stays
        // false once the wait is submitted: on a later exception the guard only takes the resume, and the job,
        // which still completes, releases the hold. Until then nothing would complete the job, so an exception
        // abandons it and hands its hold to the guard, which releases it once, after failing the Task (LIVE_003).
        token = s.parkResume(resume, HoldKind::Task, "ChildProcess.run");
        {
            ChildJob* j = childJobs().find(jobId);
            j->resumeToken = token;
            j->hold = token;
        }
        try {
            if (!startCollector(col)) {
                // No collector: the output is empty, and the run completes on the exit alone.
                if (ChildJob* j = childJobs().find(jobId)) j->outputDone = true;
            }
#if ECO_TEST_HOOKS
            runFaultPoint(RunFaultSite::BeforeJobWatch);
#endif
            startJobWatch(jobId, runMs);
        } catch (...) {
            abandonJob(jobId);
            counted = true;
            throw;
        }
        return makeKillHandle(token, &cancelRunByToken);
    )
}

} // namespace Eco::System
