//===- ChildProcess.cpp - eco/system kernel module ChildProcess -----------===//
//
// plans/eco-system-library.md Appendix B.4 (`run`), E.4 (node execFile
// semantics) and Phase 5 step 5.2: the job table shared with the
// `System.Process` manager (ChildProcessManager.cpp), the `run` binding
// body, the run output collector, the runDuration timer and the drains.
//
// `run`:
//   * the child gets /dev/null as stdin and two O_CLOEXEC pipes as stdout and
//     stderr; one detached COLLECTOR thread per run polls both pipes (and a
//     wake pipe) and reads them into std::strings, at most `maxBytes` each
//     (POD only, G1). It posts one RunOutput when both pipes reached EOF, when
//     a stream exceeded `maxBytes` (output truncated at the limit), or when
//     the main thread asked it to stop.
//   * the WaitService (lane EcoSystem, token = job id) reports the exit.
//   * `runDuration` arms a TimerService timer whose pending resume is a C++
//     closure capturing the job id (it holds one pendingAsync until it fires
//     or is cancelled). On expiry, and on overflow, the child gets SIGTERM
//     and the run fails with ProgramError exitCode -1 (E.4).
//   * The run completes once the exit has been seen AND the collector has
//     posted (node waits for 'close'). After a kill the collector is told to
//     stop at the exit, so a grandchild keeping the pipes open cannot delay a
//     killed run. When the child exits first, the timer is cancelled with
//     TimerService::cancel; if that removed it we drop its pending resume
//     and decrement (T7 rule), otherwise it fires into a closure that finds
//     no job.
//   * Result: exit 0 → ( stdout, stderr ); a non-zero exit → ProgramError
//     exitCode; a signal death or a kill → ProgramError -1 (node reports
//     `code === null` as -1); a spawn failure → InitError errnoName.
//   * The kill handle (T7) SIGTERMs the child; its CancelFn returns false, so
//     the completion path still decrements and finds the resume gone.
//
// The deviation from the plan's "two FdChannels" wording: FdChannel results
// go through the one channel dispatch that the StreamTable owns, so `run`
// uses its own collector thread with the same fd discipline (§3.4: O_CLOEXEC,
// EINTR retried, only the reading thread closes the fds).
//
// Templates used: T2-style drains (G10, AsyncRelease semantics written out),
// T4 (Bytes out), T5 (job table), T7 (kill handles), T8 (onExit delivery).
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
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

#ifndef _WIN32
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace Eco::System {

using ::Elm::Platform::TimerService;
using ::Elm::Platform::WaitLane;
using ::Elm::Platform::WaitService;

// ---------------------------------------------------------------------------
// Copy-out helpers (G3). No allocation.
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
    static auto* r = new Registry<ChildJob>("eco-system-child-jobs");   // leaky (§3.4)
    return *r;
}

// ---------------------------------------------------------------------------
// Run output collector (one detached thread per run; POD only, G1)
// ---------------------------------------------------------------------------

struct RunCollector {
    int outFd = -1;
    int errFd = -1;
    int wake[2] = {-1, -1};   // closed by the destructor (both users are done)
    size_t maxBytes = 0;      // 0 = no limit
    int64_t jobId = 0;

    ~RunCollector() {
#ifndef _WIN32
        if (wake[0] >= 0) ::close(wake[0]);
        if (wake[1] >= 0) ::close(wake[1]);
#endif
    }
};

namespace {

struct RunOutput {
    int64_t jobId = 0;
    std::string out, err;
    bool overflow = false;
};

struct RunOutputQueue {
    std::mutex m;
    std::deque<RunOutput> q;
    std::atomic<size_t> count{0};
    Scheduler* sched;
    RunOutputQueue() : sched(&Scheduler::instance()) {}   // bound on the main thread
};

RunOutputQueue& runOutputs() {
    static auto* q = new RunOutputQueue();   // leaky (§3.4)
    return *q;
}

void postRunOutput(RunOutput r) {
    auto& q = runOutputs();
    {
        std::lock_guard<std::mutex> lk(q.m);
        q.q.push_back(std::move(r));
        q.count.fetch_add(1, std::memory_order_acq_rel);
    }
    q.sched->notifyWorkAvailableFromAsync();   // outside q.m
}

bool tryPopRunOutput(RunOutput& out) {
    auto& q = runOutputs();
    std::lock_guard<std::mutex> lk(q.m);
    if (q.q.empty()) return false;
    out = std::move(q.q.front());
    q.q.pop_front();
    q.count.fetch_sub(1, std::memory_order_acq_rel);
    return true;
}

bool runOutputReady() { return runOutputs().count.load(std::memory_order_acquire) > 0; }

#ifndef _WIN32
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
            open = false;   // EOF, or an error: no more output from this pipe
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
        if (p[iWake].revents) break;   // stop requested
        const short ready = POLLIN | POLLHUP | POLLERR | POLLNVAL;
        if (iOut >= 0 && (p[iOut].revents & ready)) readInto(c->outFd, r.out, outOpen);
        if (iErr >= 0 && (p[iErr].revents & ready)) readInto(c->errFd, r.err, errOpen);
        if (c->maxBytes > 0 && (r.out.size() > c->maxBytes || r.err.size() > c->maxBytes)) {
            r.overflow = true;   // E.4: truncated at the limit, the child is killed
        }
    }
    if (c->maxBytes > 0) {
        if (r.out.size() > c->maxBytes) r.out.resize(c->maxBytes);
        if (r.err.size() > c->maxBytes) r.err.resize(c->maxBytes);
    }
    // Only this thread ever closes the pipes (§3.4).
    if (c->outFd >= 0) ::close(c->outFd);
    if (c->errFd >= 0) ::close(c->errFd);
    postRunOutput(std::move(r));
}
#endif

// ---------------------------------------------------------------------------
// Timer (runDuration)
// ---------------------------------------------------------------------------

// Cancels an armed runDuration timer (T7 rule): when TimerService removed it
// the token will never fire, so we drop its pending resume and release its
// pendingAsync count; otherwise it fires into runDurationEval, which finds no
// job (or an exited one) and the Scheduler releases the count.
void cancelTimer(uint64_t timerToken) {
    if (timerToken == 0) return;
    if (TimerService::instance().cancel(timerToken)) {
        auto& s = Scheduler::instance();
        (void)s.takePendingResume(timerToken);
        s.decrementPendingAsync();
    }
}

void advanceJob(int64_t jobId);

// The timer's "resume" closure: args[0] = job id (PK_Int, raw bits),
// args[1] = the Task.succeed () the Scheduler passes. Main thread.
void* runDurationEval(void* args[]) {
    int64_t jobId = static_cast<int64_t>(reinterpret_cast<uint64_t>(args[0]));
    if (ChildJob* j = childJobs().find(jobId)) {
        j->timerToken = 0;   // fired: the Scheduler releases its count
        if (!j->exited) {
            killJob(jobId);
        } else if (j->kind == JobKind::Run && !j->outputDone) {
            j->killed = true;   // exited, a grandchild holds the pipes: stop waiting
            advanceJob(jobId);
        }
    }
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

HPointer makeTimerClosure(int64_t jobId) {
    HPointer cl = alloc::allocClosureK(&runDurationEval, /*max_values=*/2, PK_Boxed);
    void* p = Allocator::instance().resolve(cl);   // no allocation until captured (G8)
    alloc::closureCapture(p, alloc::unboxedInt(jobId), PK_Int);
    return cl;
}

// ---------------------------------------------------------------------------
// Completion
// ---------------------------------------------------------------------------

HPointer makeBytes(const std::string& b) {
    if (b.empty()) return alloc::emptyBytes();
    alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(b.size());
    std::memcpy(bb.bytes, b.data(), b.size());   // no allocation in between (G8)
    return bb.hp;
}

// Completes a run whose exit and output are both in. Erases the job.
void completeRun(int64_t jobId) {
    ChildJob* j = childJobs().find(jobId);
    if (!j) return;
    uint64_t token = j->resumeToken;
    uint64_t timerToken = j->timerToken;
    bool counted = j->counted;
    bool killed = j->killed || j->overflow;
    int raw = j->rawStatus;
    std::string out = std::move(j->out), err = std::move(j->err);
    childJobs().erase(jobId);   // `j` is dead from here
    cancelTimer(timerToken);

    int64_t code = -1;
    bool success = false;
#ifndef _WIN32
    if (!killed && WIFEXITED(raw)) {
        code = WEXITSTATUS(raw);
        success = code == 0;
    }
#endif

    auto& s = Scheduler::instance();
    HPointer resume = s.takePendingResume(token);
    if (!alloc::isNil(resume)) {   // nil: the task was killed (G10)
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
    if (counted) s.decrementPendingAsync();   // exactly once per child (G10)
}

// Completes a spawned child whose exit is in: resumes its Elm process, then
// delivers onExit ( exitCode, signal ) (T8, G12). Erases the job.
void completeSpawn(int64_t jobId) {
    ChildJob* j = childJobs().find(jobId);
    if (!j) return;
    uint64_t token = j->resumeToken;
    uint64_t timerToken = j->timerToken;
    bool counted = j->counted;
    int raw = j->rawStatus;
    HPointer router = dec(j->routerEnc);
    HPointer tagger = dec(j->onExitEnc);
    // No allocation since the decode: root, then the job may go.
    HPointer resume = alloc::listNil();
    HPointer task = alloc::listNil();
    HPointer arg = alloc::listNil();
    HPointer msg = alloc::listNil();
    Elm::StackRootGuard g({&router, &tagger, &resume, &task, &arg, &msg});
    childJobs().erase(jobId);
    cancelTimer(timerToken);

    int64_t code = WaitService::exitCodeFromStatus(raw);   // 128 + signal for a signal death
    int64_t sig = 0;
#ifndef _WIN32
    if (WIFSIGNALED(raw)) sig = WTERMSIG(raw);
#endif

    auto& s = Scheduler::instance();
    resume = s.takePendingResume(token);
    if (!alloc::isNil(resume)) {   // nil: Process.kill took it (T7)
        task = succeedUnit();
        Scheduler::callClosure1(resume, task);
    }
    if (!alloc::isNil(tagger) && !alloc::isConstant(tagger) && !alloc::isNil(router)) {
        arg = alloc::tuple2(alloc::unboxedInt(code), alloc::unboxedInt(sig), 0x5);
        msg = Scheduler::callClosure1(tagger, arg);   // Elm call (G11)
        PlatformRuntime::instance().sendToApp(router, msg);
        s.drain();
    }
    if (counted) s.decrementPendingAsync();
}

// Moves job `jobId` forward after one of its events. Main thread.
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

// --- Drains (main thread, from the eco/system async source) ---------------

bool waitReady() { return WaitService::instance().hasReady(WaitLane::EcoSystem); }

void waitDrain() {
    bool any = false;
    WaitService::Ready r;
    while (WaitService::instance().tryPopReady(WaitLane::EcoSystem, r)) {
        int64_t jobId = static_cast<int64_t>(r.token);
        ChildJob* j = childJobs().find(jobId);
        if (!j) continue;   // a job of a dead heap (F24)
        j->exited = true;
        j->rawStatus = r.rawStatus;
        advanceJob(jobId);
        any = true;
    }
    if (any) Scheduler::instance().drain();
}

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

// Starts the collector thread of a run. On failure the pipes are closed and
// false is returned. Main thread.
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
#endif
    col->outFd = col->errFd = -1;
    return false;
}

// The CancelFn of `run` kill handles (T7): SIGTERM, then let the job finish.
bool cancelRunByToken(uint64_t token) {
    for (auto& [id, job] : childJobs().map()) {
        if (job.kind == JobKind::Run && job.resumeToken == token) {
            killJob(id);
            return false;   // the completion path decrements
        }
    }
    return false;
}

} // namespace

void ensureChildDrains() {
    static bool done = false;   // main thread only
    if (done) return;
    done = true;
    (void)runOutputs();          // bind the Scheduler on the main thread
    (void)WaitService::instance();
    addDrainSource(&waitDrain, &waitReady);
    addDrainSource(&runOutputDrain, &runOutputReady);
}

void startJobWatch(int64_t jobId, int64_t runDurationMs) {
    ensureChildDrains();
    HPointer timer = alloc::listNil();
    Elm::StackRootGuard g(&timer);
    if (runDurationMs > 0) timer = makeTimerClosure(jobId);   // allocate first
    ChildJob* j = childJobs().find(jobId);
    if (!j) return;
    int64_t pid = j->pid;
    if (runDurationMs > 0) {
        auto& s = Scheduler::instance();
        uint64_t tt = s.registerPendingResume(timer);
        s.incrementPendingAsync();   // the timer holds one count (§3.4)
        j->timerToken = tt;
        TimerService::instance().schedule(static_cast<double>(runDurationMs), tt);
    }
    WaitService::instance().submit(pid, static_cast<uint64_t>(jobId), WaitLane::EcoSystem);
}

void killJob(int64_t jobId) {
    ChildJob* j = childJobs().find(jobId);
    if (!j || j->exited) return;   // never signal a pid we already saw exit
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
    return false;   // the exit drain decrements and finds the resume gone
}

// ---------------------------------------------------------------------------
// run (B.4)
// ---------------------------------------------------------------------------

HPointer childProcessRunBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(RunErr, resume, token, counted,
        // G3: copy every input out of the heap first.
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

        // G10: register, count, then publish (collector, WaitService). The
        // JOB owns the count (`counted` stays false for the guard: on an
        // exception the guard takes the resume, and the job still releases
        // its count exactly once when the child exits).
        token = s.registerPendingResume(resume);
        s.incrementPendingAsync();
        {
            ChildJob* j = childJobs().find(jobId);
            j->resumeToken = token;
            j->counted = true;
        }
        if (!startCollector(col)) {
            // No collector thread: the output is dropped, the exit still counts.
            if (ChildJob* j = childJobs().find(jobId)) j->outputDone = true;
        }
        startJobWatch(jobId, runMs);
        return makeKillHandle(token, &cancelRunByToken);
    )
}

} // namespace Eco::System
