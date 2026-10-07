//===- EcoSystemCoreTest.cpp - Unit tests for EcoSystem_Core --------------===//
//
// plans/eco-system-library.md Phase 2 step 2.8. No Elm program: the services
// are driven directly and their result queues are popped by hand (the
// scheduler loop never runs). A heap is initialised only because the
// Scheduler singleton (embed-mode flag, pending-resume registry) needs one;
// the guard/kill-handle tests allocate a few objects.
//
// Build: cmake --build <dir> --target eco-system-core-test
// Run:   <dir>/system-kernel-cpp/eco-system-core-test
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/AsyncSources.hpp"
#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/Core/FdChannel.hpp"
#include "eco-system/Core/Registry.hpp"
#include "eco-system/Core/SignalService.hpp"
#include "eco-system/Core/SysWorkPool.hpp"

#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

using namespace Eco::System;

namespace {

int g_failures = 0;
int g_checks = 0;

#define CHECK(cond)                                                            \
    do {                                                                       \
        ++g_checks;                                                            \
        if (!(cond)) {                                                         \
            ++g_failures;                                                      \
            std::fprintf(stderr, "  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                      \
    } while (0)

using Clock = std::chrono::steady_clock;

// Polls `pop` until it yields `n` items or `timeoutMs` passes.
template <typename T, typename Pop>
std::vector<T> popN(size_t n, int timeoutMs, Pop pop) {
    std::vector<T> out;
    auto deadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
    while (out.size() < n && Clock::now() < deadline) {
        T item;
        if (pop(item)) {
            out.push_back(std::move(item));
        } else {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
    return out;
}

std::vector<ChannelResult> popChannel(size_t n, int timeoutMs = 5000) {
    return popN<ChannelResult>(n, timeoutMs,
                               [](ChannelResult& r) { return tryPopChannelResult(r); });
}

// ---------------------------------------------------------------------------

void testErrnoNames() {
    std::printf("errno names\n");
    CHECK(std::string(errnoName(ENOENT)) == "ENOENT");
    CHECK(std::string(errnoName(EACCES)) == "EACCES");
    CHECK(std::string(errnoName(EEXIST)) == "EEXIST");
    CHECK(std::string(errnoName(EAGAIN)) == "EAGAIN");
    CHECK(std::string(errnoName(ENOTSUP)) == "ENOTSUP");
    CHECK(std::string(errnoName(EPIPE)) == "EPIPE");
    CHECK(std::string(errnoName(123456)) == "UNKNOWN");
    CHECK(std::string(errnoName(-1)) == "UNKNOWN");
}

// ---------------------------------------------------------------------------

struct SquareRes {
    uint64_t token;
    uint64_t square;
};

struct BigRes {
    std::string text;
    char pad[200];
};

HPointer unusedComplete(PoolResult&) { return alloc::unit(); }

void testPoolResult() {
    std::printf("PoolResult\n");
    PoolResult a = PoolResult::of(SquareRes{3, 9});
    CHECK(!a.empty());
    CHECK(a.holds<SquareRes>());
    CHECK(!a.holds<BigRes>());
    PoolResult b = std::move(a);
    CHECK(a.empty());
    CHECK(b.as<SquareRes>().square == 9);

    BigRes big;
    big.text = std::string(1000, 'x');
    PoolResult c = PoolResult::of(std::move(big));    // heap-held
    PoolResult d;
    d = std::move(c);
    CHECK(c.empty());
    CHECK(d.as<BigRes>().text.size() == 1000);

    PoolResult e = PoolResult::of(std::string("inline string"));   // inline-held
    PoolResult f = std::move(e);
    CHECK(f.as<std::string>() == "inline string");
    f.reset();
    CHECK(f.empty());
}

void testPool1000() {
    std::printf("SysWorkPool: 1000 jobs\n");
    auto& pool = SysWorkPool::instance();
    CHECK(pool.threadCount() >= 1 && pool.threadCount() <= 4);
    const uint64_t base = 1'000'000;
    for (uint64_t i = 0; i < 1000; ++i) {
        uint64_t token = base + i;
        pool.submit(token,
                    [token]() -> PoolResult {
                        return PoolResult::of(SquareRes{token, token * token});
                    },
                    &unusedComplete);
    }
    auto items = popN<SysWorkPool::Item>(1000, 10000, [&](SysWorkPool::Item& it) {
        return pool.tryPop(it);
    });
    CHECK(items.size() == 1000);
    std::set<uint64_t> seen;
    bool allOk = true;
    for (auto& it : items) {
        auto& r = it.result.as<SquareRes>();
        if (r.token != it.token || r.square != it.token * it.token) allOk = false;
        if (it.complete != &unusedComplete) allOk = false;
        seen.insert(it.token);
    }
    CHECK(allOk);
    CHECK(seen.size() == 1000);
    CHECK(!pool.hasReady());
}

void testPoolExceptionAndCancel() {
    std::printf("SysWorkPool: exceptions and cancel\n");
    auto& pool = SysWorkPool::instance();

    pool.submit(7, []() -> PoolResult { throw std::runtime_error("boom"); },
                &unusedComplete, ErrShape::SErr);
    auto items = popN<SysWorkPool::Item>(1, 5000, [&](SysWorkPool::Item& it) {
        return pool.tryPop(it);
    });
    CHECK(items.size() == 1);
    if (items.size() == 1) {
        CHECK(items[0].token == 7);
        CHECK(items[0].shape == ErrShape::SErr);
        CHECK(items[0].result.holds<PoolException>());
        CHECK(items[0].result.as<PoolException>().what == "boom");
    }

    // Occupy every worker, then queue one more job and cancel it (T7).
    std::mutex m;
    std::condition_variable cv;
    bool release = false;
    std::atomic<size_t> started{0};
    size_t n = pool.threadCount();
    for (size_t i = 0; i < n; ++i) {
        pool.submit(100 + i, [&]() -> PoolResult {
            started.fetch_add(1);
            std::unique_lock<std::mutex> lk(m);
            cv.wait(lk, [&] { return release; });
            return PoolResult::of(SquareRes{0, 0});
        }, &unusedComplete);
    }
    auto deadline = Clock::now() + std::chrono::seconds(5);
    while (started.load() < n && Clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    CHECK(started.load() == n);

    pool.submit(999, []() -> PoolResult { return PoolResult::of(SquareRes{999, 1}); },
                &unusedComplete);
    CHECK(SysWorkPool::cancel(999) == true);    // queued: removed, never produces a result
    CHECK(SysWorkPool::cancel(999) == false);   // already gone
    CHECK(SysWorkPool::cancel(100) == false);   // running: not cancellable
    {
        std::lock_guard<std::mutex> lk(m);
        release = true;
    }
    cv.notify_all();
    auto blocked = popN<SysWorkPool::Item>(n, 5000, [&](SysWorkPool::Item& it) {
        return pool.tryPop(it);
    });
    CHECK(blocked.size() == n);
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    SysWorkPool::Item extra;
    CHECK(!pool.tryPop(extra));   // the cancelled job produced nothing
}

// ---------------------------------------------------------------------------

void testFdChannelPipe() {
    std::printf("FdChannel: pipe read/write/close\n");
    int p[2];
    CHECK(makeCloexecPipe(p, false) == 0);
    CHECK((::fcntl(p[0], F_GETFD) & FD_CLOEXEC) != 0);
    CHECK((::fcntl(p[1], F_GETFD) & FD_CLOEXEC) != 0);

    auto* r = new FdChannel(p[0]);
    auto* w = new FdChannel(p[1]);
    CHECK(r->id() != w->id());

    w->requestWrite(11, "hello");
    r->requestRead(12, 100);
    auto res = popChannel(2);
    CHECK(res.size() == 2);
    std::map<uint64_t, ChannelResult> byToken;
    for (auto& x : res) byToken[x.token] = x;
    CHECK(byToken[11].op == ChannelResult::Op::Write);
    CHECK(byToken[11].err == 0 && byToken[11].written == 5);
    CHECK(byToken[11].channelId == w->id());
    CHECK(byToken[12].op == ChannelResult::Op::Read);
    CHECK(byToken[12].err == 0 && byToken[12].bytes == "hello" && !byToken[12].eof);
    CHECK(byToken[12].channelId == r->id());

    // 1 MiB through a 64 KiB pipe: chunked writes interleaved with reads.
    std::string big(1 << 20, '\0');
    for (size_t i = 0; i < big.size(); ++i) big[i] = static_cast<char>('a' + i % 26);
    w->requestWrite(20, big);
    std::string got;
    bool writeDone = false;
    uint64_t readTok = 1000;
    r->requestRead(readTok++, 65536);
    auto deadline = Clock::now() + std::chrono::seconds(10);
    while ((got.size() < big.size() || !writeDone) && Clock::now() < deadline) {
        ChannelResult x;
        if (!tryPopChannelResult(x)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
        }
        if (x.op == ChannelResult::Op::Write) {
            CHECK(x.token == 20 && x.err == 0 && x.written == big.size());
            writeDone = true;
        } else if (x.op == ChannelResult::Op::Read) {
            CHECK(x.err == 0 && !x.eof);
            got += x.bytes;
            if (got.size() < big.size()) r->requestRead(readTok++, 65536);
        }
    }
    CHECK(writeDone);
    CHECK(got == big);

    // Graceful close of the writer: Close result, then the reader sees EOF.
    w->close(30);
    auto closed = popChannel(1);
    CHECK(closed.size() == 1 && closed[0].op == ChannelResult::Op::Close &&
          closed[0].token == 30 && closed[0].err == 0);
    r->requestRead(31, 10);
    auto eof = popChannel(1);
    CHECK(eof.size() == 1 && eof[0].token == 31 && eof[0].eof && eof[0].err == 0);

    // Requests after close are cancelled.
    w->requestWrite(32, "late");
    auto late = popChannel(1);
    CHECK(late.size() == 1 && late[0].token == 32 && late[0].err == ECANCELED);

    delete w;
    r->close(33);
    auto rc = popChannel(1);
    CHECK(rc.size() == 1 && rc[0].token == 33 && rc[0].op == ChannelResult::Op::Close);
    delete r;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    // The channel threads closed both ends.
    CHECK(::fcntl(p[0], F_GETFD) == -1 && errno == EBADF);
}

void testFdChannelShutdownWakes() {
    std::printf("FdChannel: shutdown wakes a blocked read\n");
    int p[2];
    CHECK(makeCloexecPipe(p, false) == 0);
    auto* r = new FdChannel(p[0]);
    r->requestRead(40, 10);   // no writer data: the thread blocks in poll
    r->requestRead(41, 10);
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    ChannelResult none;
    CHECK(!tryPopChannelResult(none));
    auto t0 = Clock::now();
    r->shutdown();
    auto res = popChannel(2, 2000);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count();
    CHECK(res.size() == 2);
    for (auto& x : res) CHECK(x.err == ECANCELED && (x.token == 40 || x.token == 41));
    CHECK(ms < 1000);
    r->shutdown();   // idempotent
    delete r;
    ::close(p[1]);
}

void testFdChannelStdioNeverClosed() {
    std::printf("FdChannel: fds 0-2 are never closed\n");
    int before = ::fcntl(2, F_GETFD);
    auto* ch = new FdChannel(2);
    ch->close(50);
    auto res = popChannel(1);
    CHECK(res.size() == 1 && res[0].token == 50 && res[0].err == 0);
    delete ch;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    CHECK(::fcntl(2, F_GETFD) == before);
    CHECK(before != -1);
}

std::vector<ChannelResult> g_dispatched;
void recordDispatch(ChannelResult& r) { g_dispatched.push_back(r); }

void testChannelDrainDispatch() {
    std::printf("ChannelDrain: dispatch callback\n");
    int p[2];
    CHECK(makeCloexecPipe(p, false) == 0);
    auto* w = new FdChannel(p[1]);
    setChannelDispatch(&recordDispatch);
    w->requestWrite(60, "abc");
    auto deadline = Clock::now() + std::chrono::seconds(5);
    while (!channelResultsReady() && Clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    runDrainSources();   // what the scheduler loop would call
    CHECK(g_dispatched.size() == 1 && g_dispatched[0].token == 60 &&
          g_dispatched[0].written == 3);
    setChannelDispatch(nullptr);
    w->shutdown();
    delete w;
    ::close(p[0]);
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    ChannelResult stray;
    while (tryPopChannelResult(stray)) {}
}

// ---------------------------------------------------------------------------

void (*currentHandler(int signo))(int) {
    struct sigaction sa {};
    ::sigaction(signo, nullptr, &sa);
    return sa.sa_handler;
}

std::vector<int> g_signals;
void recordSignal(int signo) { g_signals.push_back(signo); }

void testSignalService() {
    std::printf("SignalService: SIGUSR1\n");
    auto& svc = SignalService::instance();
    CHECK(currentHandler(SIGUSR1) == SIG_DFL);
    CHECK(svc.subscribe(SIGUSR1));
    CHECK(svc.subscribers(SIGUSR1) == 1);
    CHECK(currentHandler(SIGUSR1) != SIG_DFL);
    {
        struct sigaction sa {};
        ::sigaction(SIGUSR1, nullptr, &sa);
        CHECK((sa.sa_flags & SA_RESTART) != 0);
    }
    CHECK(svc.subscribe(SIGUSR1));   // second subscription: same handler
    CHECK(svc.subscribers(SIGUSR1) == 2);

    CHECK(::raise(SIGUSR1) == 0);
    auto got = popN<int>(1, 5000, [&](int& s) { return svc.tryPop(s); });
    CHECK(got.size() == 1 && got[0] == SIGUSR1);

    // Through the drain and the dispatch callback.
    svc.setDispatch(&recordSignal);
    CHECK(::raise(SIGUSR1) == 0);
    auto deadline = Clock::now() + std::chrono::seconds(5);
    while (!svc.hasReady() && Clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    signalDrain();
    CHECK(g_signals.size() == 1 && g_signals[0] == SIGUSR1);
    svc.setDispatch(nullptr);

    svc.unsubscribe(SIGUSR1);
    CHECK(svc.subscribers(SIGUSR1) == 1);
    CHECK(currentHandler(SIGUSR1) != SIG_DFL);   // still subscribed once
    svc.unsubscribe(SIGUSR1);
    CHECK(svc.subscribers(SIGUSR1) == 0);
    CHECK(currentHandler(SIGUSR1) == SIG_DFL);   // previous disposition restored
    svc.unsubscribe(SIGUSR1);                    // unmatched: ignored
    CHECK(svc.subscribers(SIGUSR1) == 0);

    CHECK(!svc.subscribe(SIGKILL));
    CHECK(!svc.subscribe(0));
}

void testSignalServiceRestoresCustomHandler() {
    std::printf("SignalService: restores a previous custom handler\n");
    auto& svc = SignalService::instance();
    struct sigaction mine {};
    mine.sa_handler = SIG_IGN;
    sigemptyset(&mine.sa_mask);
    ::sigaction(SIGUSR2, &mine, nullptr);
    CHECK(svc.subscribe(SIGUSR2));
    CHECK(currentHandler(SIGUSR2) != SIG_IGN);
    svc.unsubscribe(SIGUSR2);
    CHECK(currentHandler(SIGUSR2) == SIG_IGN);
    mine.sa_handler = SIG_DFL;
    ::sigaction(SIGUSR2, &mine, nullptr);
}

void testSignalServiceEmbedMode() {
    std::printf("SignalService: no-op in embed mode\n");
    auto& sched = Scheduler::instance();
    auto& svc = SignalService::instance();
    sched.setEmbedMode(true);
    CHECK(!svc.subscribe(SIGUSR1));
    CHECK(svc.subscribers(SIGUSR1) == 0);
    CHECK(currentHandler(SIGUSR1) == SIG_DFL);
    svc.unsubscribe(SIGUSR1);   // matching no-op
    CHECK(currentHandler(SIGUSR1) == SIG_DFL);
    sched.setEmbedMode(false);
}

// ---------------------------------------------------------------------------
// Heap-touching helpers (a few allocations; no Elm program).

std::vector<uint64_t> g_cancelled;
bool cancelYes(uint64_t token) { g_cancelled.push_back(token); return true; }

HPointer throwingBody(HPointer) {
    ECO_SYSTEM_BODY_GUARD(FErr,
        throw std::runtime_error("disk on fire");
    )
}

HPointer throwingSErrBody(HPointer) {
    ECO_SYSTEM_BODY_GUARD(SErr,
        std::vector<int> v{1, 2, 3};   // commas in the body are fine
        (void)v;
        throw std::runtime_error("bad stream");
    )
}

uint16_t taskCtor(HPointer task) {
    auto* t = static_cast<Elm::Task*>(Allocator::instance().resolve(task));
    return static_cast<uint16_t>(t->ctor);
}

void testGuardsAndHelpers() {
    std::printf("Core helpers: guards, failures, kill handle\n");

    HPointer t = throwingBody(alloc::unit());
    Elm::StackRootGuard g(&t);
    CHECK(taskCtor(t) == Elm::alloc::Task_Fail);
    {
        auto* task = static_cast<Elm::Task*>(Allocator::instance().resolve(t));
        Tuple2* tup = asTuple2(task->value.p);
        std::string code = toStdString(tup->a.p);
        std::string msg = toStdString(tup->b.p);
        CHECK(code == "EIO");
        CHECK(msg == "disk on fire");
    }

    HPointer s = throwingSErrBody(alloc::unit());
    Elm::StackRootGuard gs(&s);
    {
        auto* task = static_cast<Elm::Task*>(Allocator::instance().resolve(s));
        Tuple2* tup = asTuple2(task->value.p);
        CHECK(tup->a.i == 1);
        CHECK(toStdString(tup->b.p) == "bad stream");
    }

    HPointer fe = failErrno(ENOENT);
    Elm::StackRootGuard gf(&fe);
    {
        auto* task = static_cast<Elm::Task*>(Allocator::instance().resolve(fe));
        Tuple2* tup = asTuple2(task->value.p);
        CHECK(toStdString(tup->a.p) == "ENOENT");
        CHECK(!toStdString(tup->b.p).empty());
    }

    HPointer fr = failRun(2, "ENOENT", 3, "out", "");
    Elm::StackRootGuard gr(&fr);
    {
        auto* task = static_cast<Elm::Task*>(Allocator::instance().resolve(fr));
        Tuple3* outer = asTuple3(task->value.p);
        CHECK(outer->a.i == 2);
        CHECK(toStdString(outer->b.p) == "ENOENT");
        Tuple3* inner = asTuple3(outer->c.p);
        CHECK(inner->a.i == 3);
        CHECK(toStdBytes(inner->b.p) == "out");
        CHECK(alloc::isNil(inner->c.p));   // empty Bytes is the constant
        CHECK(toStdBytes(inner->c.p).empty());
    }

    HPointer sb = succeedBytes(std::string("\x00\x01\x02", 3));
    Elm::StackRootGuard gb(&sb);
    {
        auto* task = static_cast<Elm::Task*>(Allocator::instance().resolve(sb));
        CHECK(taskCtor(sb) == Elm::alloc::Task_Succeed);
        CHECK(toStdBytes(task->value.p) == std::string("\x00\x01\x02", 3));
    }

    // T7: the kill handle discards the pending resume and calls cancel.
    auto& sched = Scheduler::instance();
    uint64_t token = sched.registerPendingResume(alloc::unit());
    HPointer kh = makeKillHandle(token, &cancelYes);
    Elm::StackRootGuard gk(&kh);
    sched.incrementPendingAsync();   // what the binding body would have done
    Scheduler::callClosure1(kh, alloc::unit());
    CHECK(g_cancelled.size() == 1 && g_cancelled[0] == token);
    CHECK(alloc::isNil(sched.takePendingResume(token)));
}

struct TestEntry {
    uint64_t a = 0;
    template <typename F> void forEachWord(F&& f) { f(a); }
};

void testRegistry() {
    std::printf("Registry: ids and generation keying\n");
    static auto* reg = new Registry<TestEntry>("eco-system-core-test");
    int64_t id1 = reg->insert(TestEntry{enc(alloc::unit())});
    int64_t id2 = reg->insert(TestEntry{0});
    CHECK(id1 != id2);
    CHECK(reg->find(id1) != nullptr);
    CHECK(reg->size() == 2);
    CHECK(reg->erase(id2));
    CHECK(reg->find(id2) == nullptr);
    CHECK(reg->size() == 1);
}

} // namespace

int main() {
    // The Scheduler singleton needs a heap on this (the main) thread, and must
    // be constructed here, before any service thread can touch it.
    auto& a = Allocator::instance();
    a.initialize();
    a.initThread();
    (void)Scheduler::instance();

    testErrnoNames();
    testPoolResult();
    testPool1000();
    testPoolExceptionAndCancel();
    testFdChannelPipe();
    testFdChannelShutdownWakes();
    testFdChannelStdioNeverClosed();
    testChannelDrainDispatch();
    testSignalService();
    testSignalServiceRestoresCustomHandler();
    testSignalServiceEmbedMode();
    testGuardsAndHelpers();
    testRegistry();

    std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
    std::printf(g_failures == 0 ? "ALL PASSED\n" : "FAILED\n");
    return g_failures == 0 ? 0 : 1;
}
