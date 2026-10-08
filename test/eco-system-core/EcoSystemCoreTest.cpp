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
#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/Core/Registry.hpp"
#include "eco-system/Core/SignalService.hpp"
#include "eco-system/Core/SocketUtil.hpp"
#include "eco-system/Core/SysWorkPool.hpp"
#include "eco-system/HttpServer/HttpServerService.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <random>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <fcntl.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
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
void recordSignal(int signo, void*) { g_signals.push_back(signo); }

// Waits until the reader thread has queued at least one signal.
void waitSignalReady() {
    auto& svc = SignalService::instance();
    auto deadline = Clock::now() + std::chrono::seconds(5);
    while (!svc.hasReady() && Clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
}

// Raises `signo` and runs the drain until it has been delivered.
void raiseAndDrain(int signo) {
    CHECK(::raise(signo) == 0);
    waitSignalReady();
    signalDrain();
}

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

    // Through the drain and a listener (the listener holds a third
    // subscription).
    auto lid = svc.addListener(SIGUSR1, &recordSignal, nullptr);
    CHECK(lid != 0);
    CHECK(svc.subscribers(SIGUSR1) == 3);
    CHECK(svc.listenerCount(SIGUSR1) == 1);
    raiseAndDrain(SIGUSR1);
    CHECK(g_signals.size() == 1 && g_signals[0] == SIGUSR1);
    svc.removeListener(lid);
    CHECK(svc.subscribers(SIGUSR1) == 2);
    CHECK(svc.listenerCount(SIGUSR1) == 0);
    svc.removeListener(lid);   // unknown id: ignored
    CHECK(svc.subscribers(SIGUSR1) == 2);
    raiseAndDrain(SIGUSR1);    // no listener: popped and dropped
    CHECK(g_signals.size() == 1);

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

struct ListenerLog {
    std::vector<std::string> events;
};
ListenerLog g_llog;
SignalService::ListenerId g_selfRemoving = 0;
SignalService::ListenerId g_victim = 0;

void listenerA(int signo, void* ctx) {
    g_llog.events.push_back(std::string("A") + (ctx ? static_cast<const char*>(ctx) : "") +
                            std::to_string(signo));
}
void listenerB(int signo, void*) { g_llog.events.push_back("B" + std::to_string(signo)); }
// Removes itself and the victim listener registered after it.
void listenerRemover(int signo, void*) {
    g_llog.events.push_back("R" + std::to_string(signo));
    SignalService::instance().removeListener(g_selfRemoving);
    SignalService::instance().removeListener(g_victim);
}

void testSignalServiceListeners() {
    std::printf("SignalService: per-signal, multi-listener dispatch\n");
    auto& svc = SignalService::instance();
    static const char tag[] = "x";
    auto a1 = svc.addListener(SIGUSR1, &listenerA, const_cast<char*>(tag));
    auto b1 = svc.addListener(SIGUSR1, &listenerB, nullptr);
    auto a2 = svc.addListener(SIGUSR2, &listenerA, nullptr);
    CHECK(a1 != 0 && b1 != 0 && a2 != 0 && a1 != b1 && b1 != a2);
    CHECK(svc.listenerCount(SIGUSR1) == 2 && svc.listenerCount(SIGUSR2) == 1);
    CHECK(svc.subscribers(SIGUSR1) == 2 && svc.subscribers(SIGUSR2) == 1);
    CHECK(!svc.addListener(SIGUSR1, nullptr, nullptr));   // no function: rejected
    CHECK(!svc.addListener(SIGKILL, &listenerB, nullptr));

    // SIGUSR1 reaches both of its listeners, in registration order, and not
    // SIGUSR2's; SIGUSR2 reaches only its own.
    g_llog.events.clear();
    raiseAndDrain(SIGUSR1);
    CHECK(g_llog.events.size() == 2);
    if (g_llog.events.size() == 2) {
        CHECK(g_llog.events[0] == "Ax" + std::to_string(SIGUSR1));
        CHECK(g_llog.events[1] == "B" + std::to_string(SIGUSR1));
    }
    g_llog.events.clear();
    raiseAndDrain(SIGUSR2);
    CHECK(g_llog.events.size() == 1 && g_llog.events[0] == "A" + std::to_string(SIGUSR2));

    // Direct dispatch (what the drain does per event) needs no signal.
    g_llog.events.clear();
    svc.dispatch(SIGUSR2);
    CHECK(g_llog.events.size() == 1);

    // A listener that removes itself and a later listener: the later one is
    // not called for this event, and both are gone afterwards.
    g_selfRemoving = svc.addListener(SIGUSR1, &listenerRemover, nullptr);
    g_victim = svc.addListener(SIGUSR1, &listenerB, nullptr);
    CHECK(svc.listenerCount(SIGUSR1) == 4);
    g_llog.events.clear();
    svc.dispatch(SIGUSR1);
    CHECK(g_llog.events.size() == 3);   // A, B, R (the victim B is skipped)
    if (g_llog.events.size() == 3) CHECK(g_llog.events[2] == "R" + std::to_string(SIGUSR1));
    CHECK(svc.listenerCount(SIGUSR1) == 2);
    CHECK(svc.subscribers(SIGUSR1) == 2);

    // Removing the last listener of a signal restores its disposition.
    svc.removeListener(a1);
    svc.removeListener(b1);
    svc.removeListener(a2);
    CHECK(svc.listenerCount(SIGUSR1) == 0 && svc.listenerCount(SIGUSR2) == 0);
    CHECK(svc.subscribers(SIGUSR1) == 0 && svc.subscribers(SIGUSR2) == 0);
    CHECK(currentHandler(SIGUSR1) == SIG_DFL);
    CHECK(currentHandler(SIGUSR2) == SIG_DFL);
}

std::atomic<int> g_prevHandlerHits{0};
extern "C" void prevHandler(int) { g_prevHandlerHits.fetch_add(1); }

void testSignalServiceChainToPrevious() {
    std::printf("SignalService: chainToPrevious\n");
    auto& svc = SignalService::instance();

    // Previous disposition is a handler: chaining runs it once, and ours is
    // reinstalled afterwards (the event is NOT queued again).
    struct sigaction mine {};
    mine.sa_handler = &prevHandler;
    sigemptyset(&mine.sa_mask);
    ::sigaction(SIGUSR2, &mine, nullptr);
    auto lid = svc.addListener(SIGUSR2, &listenerB, nullptr);
    CHECK(lid != 0);
    svc.chainToPrevious(SIGUSR2);
    CHECK(g_prevHandlerHits.load() == 1);
    CHECK(currentHandler(SIGUSR2) != &prevHandler);   // ours again
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    CHECK(!svc.hasReady());
    svc.removeListener(lid);
    CHECK(currentHandler(SIGUSR2) == &prevHandler);   // restored on removal

    // Previous disposition SIG_IGN: the process survives the raise.
    mine.sa_handler = SIG_IGN;
    ::sigaction(SIGUSR2, &mine, nullptr);
    lid = svc.addListener(SIGUSR2, &listenerB, nullptr);
    svc.chainToPrevious(SIGUSR2);
    CHECK(currentHandler(SIGUSR2) != SIG_IGN);
    svc.removeListener(lid);
    CHECK(currentHandler(SIGUSR2) == SIG_IGN);

    // Not subscribed: a no-op (SIG_IGN stays, nothing raised).
    svc.chainToPrevious(SIGUSR2);
    CHECK(currentHandler(SIGUSR2) == SIG_IGN);

    mine.sa_handler = SIG_DFL;
    ::sigaction(SIGUSR2, &mine, nullptr);
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
    CHECK(svc.addListener(SIGUSR1, &listenerB, nullptr) == 0);   // inactive
    CHECK(svc.listenerCount(SIGUSR1) == 0);
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

// ---------------------------------------------------------------------------
// HttpServer service (plans/eco-system-library.md Phase 7): the wire format
// of responses, and the accept/connection threads driven over real sockets
// without Elm. Lives here because the service is POD-only like Core.
// ---------------------------------------------------------------------------

namespace HttpSrvT = Eco::System::HttpSrv;

bool contains(const std::string& s, const std::string& sub) {
    return s.find(sub) != std::string::npos;
}

void testHttpServerWireFormat() {
    std::printf("HttpServer: response wire format\n");
    HttpSrvT::ResponseData r;
    r.status = 201;
    r.headers = {{"X-Multi", "a"}, {"X-Multi", "b"}, {"Content-Length", "999"},
                 {"connection", "keep-alive"}, {"Bad", "x\r\nInjected: 1"}, {"Date", "today"}};
    r.body = "pong";
    std::string out = HttpSrvT::serializeResponse(r, false);
    CHECK(out.rfind("HTTP/1.1 201 Created\r\n", 0) == 0);
    CHECK(contains(out, "\r\nX-Multi: a\r\nX-Multi: b\r\n"));
    CHECK(contains(out, "\r\nContent-Length: 4\r\n"));
    CHECK(!contains(out, "999"));
    CHECK(!contains(out, "keep-alive"));
    CHECK(!contains(out, "Injected"));
    CHECK(contains(out, "\r\nDate: today\r\n"));
    CHECK(contains(out, "\r\nConnection: close\r\n\r\npong"));
    CHECK(out.size() >= 4 && out.compare(out.size() - 4, 4, "pong") == 0);

    std::string head = HttpSrvT::serializeResponse(r, /*isHead=*/true);
    CHECK(contains(head, "\r\nContent-Length: 4\r\n"));
    CHECK(head.size() >= 4 && head.compare(head.size() - 4, 4, "\r\n\r\n") == 0);

    HttpSrvT::ResponseData nc;
    nc.status = 204;
    nc.body = "ignored";
    std::string noContent = HttpSrvT::serializeResponse(nc, false);
    CHECK(noContent.rfind("HTTP/1.1 204 No Content\r\n", 0) == 0);
    CHECK(!contains(noContent, "Content-Length"));
    CHECK(!contains(noContent, "ignored"));
    CHECK(contains(noContent, "\r\nDate: "));

    HttpSrvT::ResponseData odd;
    odd.status = 42;   // out of range → 500
    CHECK(HttpSrvT::serializeResponse(odd, false).rfind("HTTP/1.1 500 Internal Server Error\r\n", 0) == 0);
    odd.status = 299;
    CHECK(HttpSrvT::serializeResponse(odd, false).rfind("HTTP/1.1 299 unknown\r\n", 0) == 0);
    CHECK(std::string(HttpSrvT::statusReason(404)) == "Not Found");
}

int connectTo(int port) {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(static_cast<uint16_t>(port));
    if (::connect(fd, reinterpret_cast<struct sockaddr*>(&a), sizeof(a)) < 0) {
        ::close(fd);
        return -1;
    }
    return fd;
}

void sendAll(int fd, const std::string& s) {
    size_t off = 0;
    while (off < s.size()) {
#if defined(MSG_NOSIGNAL)
        ssize_t n = ::send(fd, s.data() + off, s.size() - off, MSG_NOSIGNAL);
#else
        ssize_t n = ::send(fd, s.data() + off, s.size() - off, 0);
#endif
        if (n <= 0) return;
        off += static_cast<size_t>(n);
    }
}

// Reads until EOF (or 5 s).
std::string readToEof(int fd) {
    std::string out;
    char buf[4096];
    auto deadline = Clock::now() + std::chrono::seconds(5);
    while (Clock::now() < deadline) {
        struct pollfd p{fd, POLLIN, 0};
        if (::poll(&p, 1, 100) <= 0) continue;
        ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) break;
        out.append(buf, static_cast<size_t>(n));
    }
    return out;
}

// Reads until `needle` arrives (or 5 s), without waiting for EOF.
std::string readUntil(int fd, const std::string& needle) {
    std::string out;
    char buf[4096];
    auto deadline = Clock::now() + std::chrono::seconds(5);
    while (!contains(out, needle) && Clock::now() < deadline) {
        struct pollfd p{fd, POLLIN, 0};
        if (::poll(&p, 1, 100) <= 0) continue;
        ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) break;
        out.append(buf, static_cast<size_t>(n));
    }
    return out;
}

std::vector<HttpSrvT::RequestEvent> popRequests(size_t n) {
    std::vector<HttpSrvT::RequestEvent> out;
    auto deadline = Clock::now() + std::chrono::seconds(5);
    while (out.size() < n && Clock::now() < deadline) {
        HttpSrvT::HttpServerService::instance().drainRequests(out);
        if (out.size() < n) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return out;
}

std::vector<uint64_t> popDone(size_t n) {
    std::vector<uint64_t> out;
    auto deadline = Clock::now() + std::chrono::seconds(5);
    while (out.size() < n && Clock::now() < deadline) {
        HttpSrvT::HttpServerService::instance().drainDone(out);
        if (out.size() < n) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return out;
}

void testHttpServerService() {
    std::printf("HttpServer: listen, parse, respond over sockets\n");
    auto& svc = HttpSrvT::HttpServerService::instance();

    HttpSrvT::ListenResult lr = HttpSrvT::listenOn("127.0.0.1", 0);
    CHECK(lr.fd >= 0);
    if (lr.fd < 0) return;
    CHECK((::fcntl(lr.fd, F_GETFD) & FD_CLOEXEC) != 0);
    struct sockaddr_in addr{};
    socklen_t len = sizeof(addr);
    CHECK(::getsockname(lr.fd, reinterpret_cast<struct sockaddr*>(&addr), &len) == 0);
    int port = ntohs(addr.sin_port);

    // The port is taken now: a second listener fails with EADDRINUSE.
    HttpSrvT::ListenResult busy = HttpSrvT::listenOn("127.0.0.1", port);
    CHECK(busy.fd < 0 && busy.code == "EADDRINUSE");
    CHECK(contains(busy.message, "listen EADDRINUSE: "));
    CHECK(contains(busy.message, "127.0.0.1:" + std::to_string(port)));
    HttpSrvT::ListenResult bad = HttpSrvT::listenOn("no-such-host.invalid", 0);
    CHECK(bad.fd < 0 && bad.code == "ENOTFOUND");
    HttpSrvT::ListenResult range = HttpSrvT::listenOn("127.0.0.1", 70000);
    CHECK(range.fd < 0 && range.code == "ERR_SOCKET_BAD_PORT");

    int64_t sid = svc.startServer(lr.fd, "127.0.0.1", port);
    CHECK(sid > 0);

    // 1. A chunked POST, split over two writes, with a repeated header and
    //    no Host header: the URL falls back to host:port (E.5).
    int c1 = connectTo(port);
    CHECK(c1 >= 0);
    sendAll(c1, "POST /echo?x=1 HTTP/1.1\r\nX-Dup: 1\r\nX-D");
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    sendAll(c1, "up: 2\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
    auto evs = popRequests(1);
    CHECK(evs.size() == 1);
    if (evs.size() == 1) {
        const auto& ev = evs[0];
        CHECK(ev.serverId == sid);
        CHECK(ev.method == "POST");
        CHECK(ev.url == "http://127.0.0.1:" + std::to_string(port) + "/echo?x=1");
        CHECK(ev.body == "hello world");
        CHECK(ev.headers.size() == 3);
        if (ev.headers.size() == 3) {
            CHECK(ev.headers[0].first == "X-Dup" && ev.headers[0].second == "1");
            CHECK(ev.headers[1].first == "X-Dup" && ev.headers[1].second == "2");
        }
        HttpSrvT::ResponseData r;
        r.status = 200;
        r.headers = {{"Content-Type", "text/plain"}};
        r.body = "pong";
        CHECK(svc.respond(ev.key, 77, r));
        CHECK(!svc.respond(ev.key, 78, r));   // answered already
        std::string resp = readToEof(c1);
        CHECK(resp.rfind("HTTP/1.1 200 OK\r\n", 0) == 0);
        CHECK(contains(resp, "\r\nContent-Type: text/plain\r\n"));
        CHECK(contains(resp, "\r\nContent-Length: 4\r\n"));
        CHECK(contains(resp, "\r\nConnection: close\r\n\r\npong"));
        auto done = popDone(1);
        CHECK(done.size() == 1 && done[0] == 77);
    }
    if (c1 >= 0) ::close(c1);

    // 2. A Host header wins; OPTIONS is passed through by name; HEAD gets
    //    no body; Expect: 100-continue is answered before the body.
    int c2 = connectTo(port);
    sendAll(c2, "OPTIONS * HTTP/1.1\r\nHost: example.test:8080\r\n\r\n");
    int c3 = connectTo(port);
    sendAll(c3, "HEAD /h HTTP/1.1\r\nHost: h\r\n\r\n");
    int c4 = connectTo(port);
    sendAll(c4, "PUT /up HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n");
    std::string cont = readUntil(c4, "\r\n\r\n");
    CHECK(cont == "HTTP/1.1 100 Continue\r\n\r\n");
    sendAll(c4, "abc");
    auto evs2 = popRequests(3);
    CHECK(evs2.size() == 3);
    for (const auto& ev : evs2) {
        HttpSrvT::ResponseData r;
        r.body = "body";
        if (ev.method == "OPTIONS") {
            CHECK(ev.url == "http://example.test:8080/");
            CHECK(ev.body.empty());
        } else if (ev.method == "HEAD") {
            CHECK(ev.url == "http://h/h");
        } else {
            CHECK(ev.method == "PUT");
            CHECK(ev.body == "abc");
        }
        CHECK(svc.respond(ev.key, 0, r));   // token 0: nothing to complete
    }
    std::string r2 = readToEof(c2), r3 = readToEof(c3), r4 = readToEof(c4);
    CHECK(contains(r2, "\r\n\r\nbody"));
    CHECK(contains(r3, "Content-Length: 4\r\n") && !contains(r3, "\r\n\r\nbody"));
    CHECK(contains(r4, "\r\n\r\nbody"));
    for (int fd : {c2, c3, c4}) if (fd >= 0) ::close(fd);

    // 3. Garbage is answered 400 by the connection thread; nothing reaches Elm.
    int c5 = connectTo(port);
    sendAll(c5, "NOT AN HTTP REQUEST\r\n\r\n");
    std::string r5 = readToEof(c5);
    CHECK(r5.rfind("HTTP/1.1 400 Bad Request\r\n", 0) == 0);
    if (c5 >= 0) ::close(c5);
    std::vector<HttpSrvT::RequestEvent> none;
    svc.drainRequests(none);
    CHECK(none.empty());

    // 4. Unknown keys are refused.
    CHECK(!svc.respond(987654321, 1, HttpSrvT::ResponseData{}));
}


// ===========================================================================
// SocketUtil and IoReactor (plans/eco-system-sockets.md S2)
// ===========================================================================

namespace {

void testSocketUtil() {
    std::printf("SocketUtil: fd flags, sockaddr conversion, sun_path, gai codes\n");

    // --- fd flags, socketCloexec, acceptCloexec over loopback TCP ----------
    int e = 0;
    int lfd = socketCloexec(AF_INET, SOCK_STREAM, 0, /*nonBlocking=*/false, &e);
    CHECK(lfd >= 0);
    CHECK((::fcntl(lfd, F_GETFD) & FD_CLOEXEC) != 0);
    CHECK((::fcntl(lfd, F_GETFL) & O_NONBLOCK) == 0);
    SockAddr la;
    CHECK(inetToSockaddr("127.0.0.1", 0, la) == 0);
    CHECK(la.family() == AF_INET && la.len == sizeof(struct sockaddr_in));
    CHECK(::bind(lfd, la.get(), la.len) == 0);
    CHECK(::listen(lfd, 4) == 0);
    SockAddr bound;
    bound.len = sizeof(bound.ss);
    CHECK(::getsockname(lfd, bound.get(), &bound.len) == 0);
    std::string text;
    int64_t port = -1;
    CHECK(sockaddrToInet(bound, text, port));
    CHECK(text == "127.0.0.1" && port > 0);
    int c = connectTo(static_cast<int>(port));
    CHECK(c >= 0);
    SockAddr peer;
    peer.len = sizeof(peer.ss);
    int afd = acceptCloexec(lfd, /*nonBlocking=*/true, peer.get(), &peer.len, &e);
    CHECK(afd >= 0);
    CHECK((::fcntl(afd, F_GETFD) & FD_CLOEXEC) != 0);
    CHECK((::fcntl(afd, F_GETFL) & O_NONBLOCK) != 0);
    std::string ptext;
    int64_t pport = 0;
    CHECK(sockaddrToInet(peer, ptext, pport) && ptext == "127.0.0.1" && pport > 0);
    CHECK(setNoSigPipe(afd) == 0);
    int nb = socketCloexec(AF_INET6, SOCK_DGRAM, 0, /*nonBlocking=*/true, &e);
    if (nb >= 0) {
        CHECK((::fcntl(nb, F_GETFL) & O_NONBLOCK) != 0);
        ::close(nb);
    }
    int plain = ::socket(AF_INET, SOCK_STREAM, 0);
    CHECK(setNonBlocking(plain) == 0 && (::fcntl(plain, F_GETFL) & O_NONBLOCK) != 0);
    CHECK(setCloexec(plain) == 0 && (::fcntl(plain, F_GETFD) & FD_CLOEXEC) != 0);
    ::close(plain);
    CHECK(setCloexec(-1) == EBADF);
    for (int fd : {c, afd, lfd}) if (fd >= 0) ::close(fd);
    CHECK(kSendFlags == MSG_NOSIGNAL);   // Linux

    // --- inet text <-> sockaddr ---------------------------------------------
    auto roundTrip = [](const std::string& in, int64_t p, std::string& out) {
        SockAddr sa;
        if (inetToSockaddr(in, p, sa) != 0) return false;
        int64_t q = -1;
        if (!sockaddrToInet(sa, out, q)) return false;
        return q == p;
    };
    std::string out;
    CHECK(roundTrip("127.0.0.1", 8080, out) && out == "127.0.0.1");
    CHECK(roundTrip("0.0.0.0", 0, out) && out == "0.0.0.0");
    CHECK(roundTrip("255.255.255.255", 65535, out) && out == "255.255.255.255");
    CHECK(roundTrip("::1", 443, out) && out == "::1");
    CHECK(roundTrip("::", 1, out) && out == "::");
    CHECK(roundTrip("2001:DB8:0:0:0:0:1:2", 9, out) && out == "2001:db8::1:2");
    CHECK(roundTrip("::ffff:127.0.0.1", 7, out) && out == "::ffff:127.0.0.1");
    {
        SockAddr v6;
        CHECK(inetToSockaddr("::1", 1, v6) == 0 && v6.family() == AF_INET6 &&
              v6.len == sizeof(struct sockaddr_in6));
    }
    unsigned lo = ::if_nametoindex("lo");
    CHECK(lo != 0);
    if (lo != 0) {
        CHECK(roundTrip("fe80::1%lo", 80, out) && out == "fe80::1%lo");
        CHECK(roundTrip("fe80::1%" + std::to_string(lo), 80, out) && out == "fe80::1%lo");
        SockAddr sa;
        CHECK(inetToSockaddr("fe80::1%lo", 80, sa) == 0);
        CHECK(reinterpret_cast<struct sockaddr_in6*>(&sa.ss)->sin6_scope_id == lo);
        CHECK(scopeName(lo) == "lo");
        uint32_t id = 0;
        CHECK(parseScope("lo", id) && id == lo);
    }
    CHECK(roundTrip("fe80::1%4000000", 1, out) && out == "fe80::1%4000000");   // no such interface: decimal
    CHECK(scopeName(0).empty());
    uint32_t sid = 0;
    CHECK(parseScope("0", sid) && sid == 0);
    CHECK(!parseScope("", sid));
    CHECK(!parseScope("99999999999", sid));
    CHECK(!parseScope("nosuchif9", sid));
    SockAddr bad;
    CHECK(inetToSockaddr("fe80::1%nosuchif9", 1, bad) == EINVAL);
    CHECK(inetToSockaddr("fe80::1%", 1, bad) == EINVAL);
    CHECK(inetToSockaddr("127.0.0.1%lo", 1, bad) == EINVAL);
    CHECK(inetToSockaddr("1.2.3", 1, bad) == EINVAL);
    CHECK(inetToSockaddr("01.2.3.4", 1, bad) == EINVAL);
    CHECK(inetToSockaddr("", 1, bad) == EINVAL);
    CHECK(inetToSockaddr("::1::2", 1, bad) == EINVAL);
    CHECK(inetToSockaddr("127.0.0.1", 65536, bad) == EINVAL);
    CHECK(inetToSockaddr("127.0.0.1", -1, bad) == EINVAL);
    CHECK(bad.len == 0 && bad.family() == AF_UNSPEC);   // untouched on failure

    // --- IPv4 -> IPv4-mapped IPv6 (§D.4) --------------------------------------
    SockAddr m;
    CHECK(inetToSockaddr("127.0.0.1", 5, m) == 0);
    CHECK(mapIPv4ToIPv6(m));
    CHECK(m.family() == AF_INET6 && m.len == sizeof(struct sockaddr_in6));
    CHECK(sockaddrToInet(m, out, port) && out == "::ffff:127.0.0.1" && port == 5);
    CHECK(!mapIPv4ToIPv6(m));   // already IPv6: unchanged
    CHECK(sockaddrToInet(m, out, port) && out == "::ffff:127.0.0.1");

    // --- Unix paths (§D.3) ----------------------------------------------------
    CHECK(unixPathMax() == sizeof(sockaddr_un::sun_path));
    CHECK(unixPathMax() == 108);   // Linux
    SockAddr u;
    std::string p107(107, 'a');
    CHECK(unixSockaddr(p107, u) == 0);
    CHECK(u.family() == AF_UNIX && u.len == offsetof(struct sockaddr_un, sun_path) + 108);
    std::string back;
    CHECK(sockaddrToUnixPath(u.get(), u.len, back) && back == p107);
    SockAddr u2;
    CHECK(unixSockaddr(std::string(108, 'a'), u2) == ENAMETOOLONG);
    std::string utf8;
    for (int i = 0; i < 54; ++i) utf8 += "\xc3\xa9";   // 54 characters, 108 bytes
    CHECK(unixSockaddr(utf8, u2) == ENAMETOOLONG);
    CHECK(unixSockaddr(std::string("a\0b", 3), u2) == EINVAL);
    CHECK(unixSockaddr("", u2) == ENOENT);
    CHECK(unixSockaddr(std::string(300, '\0'), u2) == ENAMETOOLONG);   // length first
    CHECK(u2.len == 0);
    {
        struct sockaddr_un unnamed{};
        unnamed.sun_family = AF_UNIX;
        std::string p = "x";
        CHECK(sockaddrToUnixPath(reinterpret_cast<struct sockaddr*>(&unnamed), sizeof(sa_family_t), p) &&
              p.empty());
        CHECK(!sockaddrToUnixPath(la.get(), la.len, p));
    }
    std::string sockPath = "/tmp/eco-p11b-sockutil-" + std::to_string(::getpid()) + ".sock";
    ::unlink(sockPath.c_str());
    int us = socketCloexec(AF_UNIX, SOCK_STREAM, 0, false, &e);
    SockAddr ua;
    CHECK(us >= 0 && unixSockaddr(sockPath, ua) == 0);
    CHECK(::bind(us, ua.get(), ua.len) == 0);
    SockAddr ub;
    ub.len = sizeof(ub.ss);
    CHECK(::getsockname(us, ub.get(), &ub.len) == 0);
    CHECK(sockaddrToUnixPath(ub.get(), ub.len, back) && back == sockPath);
    ::close(us);
    ::unlink(sockPath.c_str());

    // --- getaddrinfo codes (§3.3.6) --------------------------------------------
    CHECK(std::string(gaiCode(EAI_NONAME, 0)) == "ENOTFOUND");
#ifdef EAI_NODATA
    CHECK(std::string(gaiCode(EAI_NODATA, 0)) == "ENOTFOUND");
#endif
    CHECK(std::string(gaiCode(EAI_AGAIN, 0)) == "EAI_AGAIN");
    CHECK(std::string(gaiCode(EAI_MEMORY, 0)) == "ENOMEM");
    CHECK(std::string(gaiCode(EAI_SYSTEM, ECONNREFUSED)) == "ECONNREFUSED");
    CHECK(std::string(gaiCode(EAI_FAIL, 0)) == "EAI_FAIL");
    CHECK(std::string(gaiCode(EAI_FAMILY, 0)) == "EAI_FAIL");
    CHECK(std::string(gaiCode(EAI_SERVICE, 0)) == "EAI_FAIL");
}

// --- reactor helpers ---------------------------------------------------------

IoReactor& R() { return IoReactor::instance(); }

// Runs fn on the reactor thread and waits for it (aborts after 10 s: the
// command captures this frame by reference).
void onReactor(const std::function<void()>& fn) {
    std::mutex mu;
    std::condition_variable cv;
    bool done = false;
    R().submit([&] {
        fn();
        {
            std::lock_guard<std::mutex> lk(mu);
            done = true;
        }
        cv.notify_all();
    });
    std::unique_lock<std::mutex> lk(mu);
    if (!cv.wait_for(lk, std::chrono::seconds(10), [&] { return done; })) {
        std::fprintf(stderr, "  FATAL: reactor command did not run within 10 s\n");
        std::abort();
    }
}

template <typename P>
bool waitUntil(P pred, int timeoutMs = 5000) {
    auto deadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
    while (!pred()) {
        if (Clock::now() >= deadline) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return true;
}

bool makePair(int sv[2]) { return ::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) == 0; }

// Reads exactly n bytes from a blocking fd (poll-bounded).
std::string recvExactly(int fd, size_t n, int timeoutMs = 10000) {
    std::string out;
    char buf[65536];
    auto deadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
    while (out.size() < n && Clock::now() < deadline) {
        struct pollfd p{fd, POLLIN, 0};
        if (::poll(&p, 1, 50) <= 0) continue;
        size_t want = std::min(sizeof(buf), n - out.size());
        ssize_t r = ::recv(fd, buf, want, 0);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        out.append(buf, static_cast<size_t>(r));
    }
    return out;
}

// True when the peer sees EOF (recv 0) within timeoutMs.
bool peerSeesEof(int fd, int timeoutMs = 5000) {
    char buf[256];
    auto deadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
    while (Clock::now() < deadline) {
        struct pollfd p{fd, POLLIN, 0};
        if (::poll(&p, 1, 50) <= 0) continue;
        ssize_t r = ::recv(fd, buf, sizeof(buf), 0);
        if (r == 0) return true;
        if (r < 0 && errno != EINTR && errno != EAGAIN) return false;
    }
    return false;
}

// Echoes everything back; closes on EOF/error or closeAll.
struct EchoHandler : IoHandler {
    int fd;
    std::string out;   // reactor thread only
    std::atomic<int> readyCalls{0};
    std::atomic<int> closeAllCalls{0};
    std::atomic<bool> closed{false};
    std::atomic<uint64_t> keySeen{0};
    explicit EchoHandler(int f) : fd(f) {}

    void onReady(bool r, bool, bool e) override {
        ++readyCalls;
        if (r || e) {
            char buf[16384];
            for (;;) {
                ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
                if (n > 0) {
                    out.append(buf, static_cast<size_t>(n));
                    continue;
                }
                if (n == 0) { finish(); return; }
                if (errno == EINTR) continue;
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                finish();
                return;
            }
        }
        flush();
    }
    void flush() {
        while (!out.empty()) {
            ssize_t n = ::send(fd, out.data(), out.size(), kSendFlags);
            if (n > 0) {
                out.erase(0, static_cast<size_t>(n));
                continue;
            }
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
            finish();
            return;
        }
        R().setInterest(key(), true, !out.empty());
    }
    void finish() {
        if (key() == 0) return;
        R().remove(key());   // rule 3: remove, then close
        ::close(fd);
        fd = -1;
        closed = true;
    }
    void onCloseAll() override {
        ++closeAllCalls;
        finish();
    }
};

std::shared_ptr<EchoHandler> startEcho(int fd) {
    CHECK(setNonBlocking(fd) == 0);
    auto h = std::make_shared<EchoHandler>(fd);
    onReactor([&] {
        uint64_t k = R().add(h, fd);
        h->keySeen = k;
        CHECK(k != 0 && h->key() == k);
        CHECK(R().setInterest(k, true, false) == 0);
    });
    return h;
}

// Counts calls; on readiness drops all interest WITHOUT reading (the N1 shape).
struct DropHandler : IoHandler {
    int fd;
    std::atomic<int> calls{0};
    std::atomic<bool> sawHangup{false};
    explicit DropHandler(int f) : fd(f) {}
    void onReady(bool, bool, bool e) override {
        ++calls;
        if (e) sawHangup = true;
        R().setInterest(key(), false, false);
    }
    void onCloseAll() override {
        if (key() == 0) return;
        R().remove(key());
        ::close(fd);
    }
};

// Records readiness calls only.
struct CountHandler : IoHandler {
    int fd;
    std::atomic<int> calls{0};
    std::atomic<int64_t> bytes{0};
    bool readAndDrop = false;   // read everything, then drop interest
    explicit CountHandler(int f, bool rd = false) : fd(f), readAndDrop(rd) {}
    void onReady(bool, bool, bool) override {
        ++calls;
        if (!readAndDrop) return;
        char buf[4096];
        for (;;) {
            ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
            if (n > 0) { bytes += n; continue; }
            if (n < 0 && errno == EINTR) continue;
            break;
        }
        R().setInterest(key(), false, false);
    }
    void onCloseAll() override {
        if (key() == 0) return;
        R().remove(key());
        if (fd >= 0) ::close(fd);
    }
};

// --- tests -------------------------------------------------------------------

void testReactorEcho() {
    std::printf("IoReactor: echo over a socketpair\n");
    int sv[2];
    CHECK(makePair(sv));
    auto h = startEcho(sv[0]);
    sendAll(sv[1], "hello reactor");
    CHECK(recvExactly(sv[1], 13) == "hello reactor");

    // 4 MiB each way: the socket buffers fill, so the echo needs write
    // interest (EPOLLOUT) and the peer must read while it writes.
    std::string big(4u << 20, '\0');
    for (size_t i = 0; i < big.size(); ++i) big[i] = static_cast<char>((i * 131) ^ (i >> 9));
    std::thread writer([&] { sendAll(sv[1], big); });
    std::string got = recvExactly(sv[1], big.size(), 20000);
    writer.join();
    CHECK(got.size() == big.size());
    CHECK(got == big);

    // Half-close: the handler reads EOF, removes itself and closes.
    CHECK(::shutdown(sv[1], SHUT_WR) == 0);
    CHECK(waitUntil([&] { return h->closed.load(); }));
    CHECK(peerSeesEof(sv[1]));
    CHECK(h->closeAllCalls == 0);
    ::close(sv[1]);
}

void testReactorIdleNoBusyLoop() {
    std::printf("IoReactor: idle fd with a closed / reset peer does not spin\n");
    auto& r = R();

    // A: registered with interest; the peer closes; the handler is told once
    // and drops its interest WITHOUT reading. The fd still has EOF pending;
    // since it is no longer in the kernel set, the loop stays idle.
    int sv[2];
    CHECK(makePair(sv));
    CHECK(setNonBlocking(sv[0]) == 0);
    auto a = std::make_shared<DropHandler>(sv[0]);
    onReactor([&] { CHECK(r.setInterest(r.add(a, sv[0]), true, false) == 0); });
    ::close(sv[1]);
    CHECK(waitUntil([&] { return a->calls.load() >= 1; }));
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    uint64_t it0 = r.loopIterations();
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    uint64_t it1 = r.loopIterations();
    std::printf("  close: %llu iterations in 200 ms, %d calls\n",
                static_cast<unsigned long long>(it1 - it0), a->calls.load());
    CHECK(it1 - it0 <= 5);
    CHECK(a->calls == 1);

    // B: TCP, registered then unregistered, then the peer resets it (RST:
    // EPOLLERR|EPOLLHUP, which epoll reports even with no requested events).
    int lfd = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    SockAddr la;
    CHECK(inetToSockaddr("127.0.0.1", 0, la) == 0);
    CHECK(::bind(lfd, la.get(), la.len) == 0 && ::listen(lfd, 4) == 0);
    la.len = sizeof(la.ss);
    CHECK(::getsockname(lfd, la.get(), &la.len) == 0);
    std::string t;
    int64_t port = 0;
    CHECK(sockaddrToInet(la, t, port));
    int client = connectTo(static_cast<int>(port));
    int server = acceptCloexec(lfd, true, nullptr, nullptr, nullptr);
    CHECK(client >= 0 && server >= 0);
    auto b = std::make_shared<DropHandler>(server);
    onReactor([&] {
        uint64_t k = r.add(b, server);
        CHECK(r.setInterest(k, true, false) == 0);
        CHECK(r.setInterest(k, false, false) == 0);   // EPOLL_CTL_DEL
    });
    struct linger lg{1, 0};
    CHECK(::setsockopt(client, SOL_SOCKET, SO_LINGER, &lg, sizeof(lg)) == 0);
    ::close(client);   // RST
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    it0 = r.loopIterations();
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    it1 = r.loopIterations();
    std::printf("  reset: %llu iterations in 200 ms\n", static_cast<unsigned long long>(it1 - it0));
    CHECK(it1 - it0 <= 5);
    CHECK(b->calls == 0);
    // Interest again: the pending error is now reported (level-triggered).
    onReactor([&] { CHECK(r.setInterest(b->key(), true, false) == 0); });
    CHECK(waitUntil([&] { return b->calls.load() == 1; }));
    CHECK(b->sawHangup.load());
    onReactor([&] { a->onCloseAll(); b->onCloseAll(); });
    ::close(lfd);
}

void testReactorManyPairs() {
    constexpr int kWant = 1000;
    struct rlimit rl{};
    ::getrlimit(RLIMIT_NOFILE, &rl);
    rlim_t need = 2 * kWant + 256;
    if (rl.rlim_cur < need && rl.rlim_max >= need) {
        rl.rlim_cur = need;
        ::setrlimit(RLIMIT_NOFILE, &rl);
        ::getrlimit(RLIMIT_NOFILE, &rl);
    }
    int n = kWant;
    if (rl.rlim_cur < need) n = static_cast<int>((rl.rlim_cur - 256) / 2);
    std::printf("IoReactor: %d socketpairs with interleaved traffic\n", n);
    CHECK(n == kWant);

    std::vector<int> peers(static_cast<size_t>(n), -1);
    std::vector<std::shared_ptr<EchoHandler>> hs;
    hs.reserve(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) {
        int sv[2];
        if (!makePair(sv)) {
            CHECK(false);
            return;
        }
        CHECK(setNonBlocking(sv[0]) == 0);
        peers[static_cast<size_t>(i)] = sv[1];
        hs.push_back(std::make_shared<EchoHandler>(sv[0]));
    }
    onReactor([&] {
        for (auto& h : hs) {
            uint64_t k = R().add(h, h->fd);
            if (k == 0 || R().setInterest(k, true, false) != 0) CHECK(false);
        }
    });

    constexpr int kRounds = 4;
    auto msg = [](int i, int round) {
        return "pair " + std::to_string(i) + " round " + std::to_string(round) + std::string(i % 37, '.') + ";";
    };
    std::thread writer([&] {
        std::mt19937 rng(12345);
        std::vector<int> order(static_cast<size_t>(n));
        for (int i = 0; i < n; ++i) order[static_cast<size_t>(i)] = i;
        for (int round = 0; round < kRounds; ++round) {
            std::shuffle(order.begin(), order.end(), rng);
            for (int i : order) sendAll(peers[static_cast<size_t>(i)], msg(i, round));
        }
    });
    int ok = 0;
    for (int round = 0; round < kRounds; ++round) {
        for (int j = 0; j < n; ++j) {
            int i = (j * 7 + round * 13) % n;   // another order than the writer's
            std::string m = msg(i, round);
            if (recvExactly(peers[static_cast<size_t>(i)], m.size()) == m) ++ok;
        }
    }
    writer.join();
    CHECK(ok == n * kRounds);

    for (int fd : peers) ::close(fd);   // every handler sees EOF and closes itself
    CHECK(waitUntil([&] {
        for (auto& h : hs) if (!h->closed.load()) return false;
        return true;
    }, 10000));
}

void testReactorSubmitRacing() {
    std::printf("IoReactor: submit racing readiness\n");
    // A: 4 threads x 20 000 submits while echo traffic runs: every command
    // runs exactly once, in submission order per thread.
    constexpr int kThreads = 4, kPer = 20000;
    std::vector<int> last(kThreads, -1);   // reactor thread only
    std::vector<int> count(kThreads, 0);
    int bad = 0;
    int sv[2];
    CHECK(makePair(sv));
    auto echo = startEcho(sv[0]);
    std::vector<std::thread> ts;
    for (int t = 0; t < kThreads; ++t) {
        ts.emplace_back([&, t] {
            for (int i = 0; i < kPer; ++i) {
                R().submit([&, t, i] {
                    if (i != last[static_cast<size_t>(t)] + 1) ++bad;
                    last[static_cast<size_t>(t)] = i;
                    ++count[static_cast<size_t>(t)];
                });
            }
        });
    }
    int echoed = 0;
    for (int i = 0; i < 200; ++i) {
        std::string m = "ping " + std::to_string(i);
        sendAll(sv[1], m);
        if (recvExactly(sv[1], m.size()) == m) ++echoed;
    }
    for (auto& t : ts) t.join();
    CHECK(echoed == 200);
    int total = 0, badSeen = -1;
    onReactor([&] {
        for (int c : count) total += c;
        badSeen = bad;
    });
    CHECK(total == kThreads * kPer);
    CHECK(badSeen == 0);
    ::close(sv[1]);
    CHECK(waitUntil([&] { return echo->closed.load(); }));

    // B: interest submitted while the data races in: level-triggered
    // registration reports data that arrived before the fd was added.
    int pv[2];
    CHECK(makePair(pv));
    CHECK(setNonBlocking(pv[0]) == 0);
    auto h = std::make_shared<CountHandler>(pv[0], /*readAndDrop=*/true);
    uint64_t key = 0;
    onReactor([&] { key = R().add(h, pv[0]); });
    int delivered = 0;
    for (int i = 0; i < 300; ++i) {
        std::thread w([&] { sendAll(pv[1], "x"); });
        if (i % 2 == 0) std::this_thread::yield();
        R().submit([key] { R().setInterest(key, true, false); });
        w.join();
        if (waitUntil([&] { return h->bytes.load() == i + 1; }, 2000)) ++delivered;
    }
    CHECK(delivered == 300);
    onReactor([&] { h->onCloseAll(); });
    ::close(pv[1]);
}

void testReactorStaleGeneration() {
    std::printf("IoReactor: removed keys and stale generations are dropped\n");
    auto& r = R();

    // A: synthetic events (the normal dispatch path) for a removed key whose
    // slot and fd number were reused.
    int sv[2], sw[2];
    CHECK(makePair(sv));
    CHECK(setNonBlocking(sv[0]) == 0);
    auto a = std::make_shared<CountHandler>(sv[0]);
    auto b = std::make_shared<CountHandler>(-1);
    uint64_t ka = 0, kb = 0;
    int oldFd = sv[0], newFd = -1;
    onReactor([&] {
        ka = r.add(a, sv[0]);
        CHECK(r.setInterest(ka, true, false) == 0);
        r.remove(ka);   // rule 3: remove, then close
        CHECK(a->key() == 0);
        ::close(sv[0]);
        a->fd = -1;
        CHECK(makePair(sw));
        newFd = sw[0];
        CHECK(setNonBlocking(sw[0]) == 0);
        b->fd = sw[0];
        kb = r.add(b, sw[0]);
        r.injectEventForTest(ka, true, true, true);   // stale generation: dropped
        r.injectEventForTest(kb, true, false, false);  // no interest yet: dropped
        CHECK(r.setInterest(kb, true, false) == 0);
        r.injectEventForTest(kb, false, true, false);  // a direction it does not want: dropped
        r.injectEventForTest(kb, true, false, false);  // delivered
        r.injectEventForTest(ka, true, false, false);  // still dropped
    });
    CHECK((ka & 0xFFFFFFFFu) == (kb & 0xFFFFFFFFu));   // the slot was reused...
    CHECK(ka != kb);                                    // ...with a new generation
    CHECK(newFd == oldFd);                              // and the fd number too
    CHECK(a->calls == 0);
    CHECK(b->calls == 1);
    onReactor([&] { r.remove(ka); r.remove(kb); r.remove(0); r.setTimer(ka, r.nowMs()); CHECK(r.setInterest(ka, true, true) == 0); });
    CHECK(b->key() == 0);
    ::close(sw[0]);
    ::close(sw[1]);
    ::close(sv[1]);

    // B: a real batch: two readable handlers, each removes (and closes) the
    // other and itself on its first call. Both events come back from one
    // epoll_wait; the second one must be dropped.
    struct KillOther : IoHandler {
        int fd = -1;
        std::shared_ptr<KillOther> other;
        std::atomic<int>* calls = nullptr;
        void onReady(bool, bool, bool) override {
            ++*calls;
            if (other && other->key() != 0) {
                R().remove(other->key());
                ::close(other->fd);
            }
            other.reset();
            if (key() != 0) {
                R().remove(key());
                ::close(fd);
            }
        }
        void onCloseAll() override {}
    };
    std::atomic<int> calls{0};
    int p1[2], p2[2];
    CHECK(makePair(p1) && makePair(p2));
    auto x = std::make_shared<KillOther>();
    auto y = std::make_shared<KillOther>();
    x->fd = p1[0];
    y->fd = p2[0];
    x->other = y;
    y->other = x;
    x->calls = y->calls = &calls;
    sendAll(p1[1], "a");
    sendAll(p2[1], "b");
    onReactor([&] {
        CHECK(r.setInterest(r.add(x, x->fd), true, false) == 0);
        CHECK(r.setInterest(r.add(y, y->fd), true, false) == 0);
    });
    CHECK(waitUntil([&] { return calls.load() >= 1; }));
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    CHECK(calls == 1);
    ::close(p1[1]);
    ::close(p2[1]);

    // C: real kernel, fd-number reuse: A is put in the kernel set with data
    // pending, then (in the same command, before any wait) removed and its
    // fd closed; B gets the same fd number. Only B may hear about it.
    int q[2], q2[2];
    CHECK(makePair(q));
    CHECK(setNonBlocking(q[0]) == 0);
    sendAll(q[1], "pending for A");
    auto a2 = std::make_shared<CountHandler>(q[0]);
    auto b2 = std::make_shared<CountHandler>(-1, /*readAndDrop=*/true);
    int reusedFd = -1;
    onReactor([&] {
        uint64_t k = r.add(a2, q[0]);
        CHECK(r.setInterest(k, true, false) == 0);
        r.remove(k);
        ::close(q[0]);
        a2->fd = -1;
        CHECK(makePair(q2));
        reusedFd = q2[0];
        CHECK(setNonBlocking(q2[0]) == 0);
        b2->fd = q2[0];
        CHECK(r.setInterest(r.add(b2, q2[0]), true, false) == 0);
        sendAll(q2[1], "for B");
    });
    CHECK(reusedFd == q[0]);
    CHECK(waitUntil([&] { return b2->bytes.load() == 5; }));
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    CHECK(a2->calls == 0);
    CHECK(b2->calls == 1);
    onReactor([&] { b2->onCloseAll(); });
    ::close(q[1]);
    ::close(q2[1]);
}

void testReactorTimers() {
    std::printf("IoReactor: timers (ordering, replace, cancel, remove, re-arm)\n");
    auto& r = R();
    struct Fired {
        int id;
        int64_t at;
        int64_t deadline;
    };
    std::mutex mu;
    std::vector<Fired> fired;
    struct TimerHandler : IoHandler {
        int id = 0;
        int64_t deadline = 0;
        int rearm = 0;      // times to re-arm, period 15 ms
        std::mutex* mu = nullptr;
        std::vector<Fired>* fired = nullptr;
        void onReady(bool, bool, bool) override {}
        void onTimer() override {
            int64_t now = R().nowMs();
            {
                std::lock_guard<std::mutex> lk(*mu);
                fired->push_back(Fired{id, now, deadline});
            }
            if (rearm > 0) {
                --rearm;
                deadline = now + 15;
                R().setTimer(key(), deadline);
            }
        }
        void onCloseAll() override { R().remove(key()); }
    };
    std::vector<std::shared_ptr<TimerHandler>> hs;
    for (int i = 0; i <= 8; ++i) {
        auto h = std::make_shared<TimerHandler>();
        h->id = i;
        h->mu = &mu;
        h->fired = &fired;
        hs.push_back(h);
    }
    hs[7]->rearm = 2;   // fires 3 times
    onReactor([&] {
        for (auto& h : hs) CHECK(r.add(h, -1) != 0);
        int64_t base = r.nowMs();
        auto set = [&](int i, int64_t d) {
            hs[static_cast<size_t>(i)]->deadline = d;
            r.setTimer(hs[static_cast<size_t>(i)]->key(), d);
        };
        set(1, base + 80);
        set(2, base + 20);
        set(3, base + 50);
        set(4, base + 30);
        r.setTimer(hs[4]->key(), 0);   // cancelled
        set(5, base + 10);
        set(5, base + 65);             // replaced (one timer per handler)
        set(6, base + 25);
        r.remove(hs[6]->key());        // removed with its timer
        set(7, base + 5);
        set(8, base - 5);              // already passed: fires on the next iteration
        CHECK(r.setInterest(hs[1]->key(), true, false) == 0);   // timer-only: no-op
    });
    CHECK(waitUntil([&] {
        std::lock_guard<std::mutex> lk(mu);
        return fired.size() >= 8;
    }, 3000));
    std::this_thread::sleep_for(std::chrono::milliseconds(150));   // nothing else may fire
    std::vector<int> order;
    int sevens = 0;
    bool early = false;
    {
        std::lock_guard<std::mutex> lk(mu);
        for (const auto& f : fired) {
            if (f.at < f.deadline) early = true;
            if (f.id == 7) ++sevens;
            else order.push_back(f.id);
        }
    }
    CHECK(!early);
    CHECK(sevens == 3);
    CHECK((order == std::vector<int>{8, 2, 3, 5, 1}));
    onReactor([&] { for (auto& h : hs) r.remove(h->key()); });
}

void testReactorCloseAll() {
    std::printf("IoReactor: closeAll\n");
    auto& r = R();
    std::vector<int> peers;
    std::vector<std::shared_ptr<EchoHandler>> hs;
    for (int i = 0; i < 5; ++i) {
        int sv[2];
        CHECK(makePair(sv));
        peers.push_back(sv[1]);
        hs.push_back(startEcho(sv[0]));
    }
    struct TimerOnly : IoHandler {
        std::atomic<int> closes{0};
        std::atomic<int> timers{0};
        void onReady(bool, bool, bool) override {}
        void onTimer() override { ++timers; }
        void onCloseAll() override {
            ++closes;
            R().remove(key());
        }
    };
    auto t = std::make_shared<TimerOnly>();
    onReactor([&] { r.setTimer(r.add(t, -1), r.nowMs() + 300); });

    r.closeAll();   // main thread: returns once every handler has closed
    for (auto& h : hs) {
        CHECK(h->closeAllCalls == 1);
        CHECK(h->closed.load());
    }
    CHECK(t->closes == 1);
    for (int fd : peers) {
        CHECK(peerSeesEof(fd));
        ::close(fd);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    CHECK(t->timers == 0);   // removed with its timer

    // On the reactor thread it runs inline (no self-deadlock).
    int sv[2];
    CHECK(makePair(sv));
    auto h = startEcho(sv[0]);
    onReactor([&] { R().closeAll(); });
    CHECK(h->closeAllCalls == 1 && h->closed.load());
    CHECK(peerSeesEof(sv[1]));
    ::close(sv[1]);
    r.closeAll();   // nothing registered
}

// Must be the last reactor test: quiesce is irreversible.
void testReactorQuiesce() {
    std::printf("IoReactor: quiesce\n");
    auto& r = R();
    std::atomic<bool> ran{false};
    onReactor([] {});
    auto t0 = Clock::now();
    CHECK(r.quiesce(100));
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count();
    CHECK(ms < 100);
    r.submit([&ran] { ran = true; });
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    CHECK(!ran.load());
    uint64_t it = r.loopIterations();
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    CHECK(r.loopIterations() == it);
    t0 = Clock::now();
    r.closeAll();   // quiesced: returns at once
    CHECK(std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count() < 100);
    CHECK(r.quiesce(10));   // again: still acknowledged
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
    testSignalServiceListeners();
    testSignalServiceChainToPrevious();
    testSignalServiceRestoresCustomHandler();
    testSignalServiceEmbedMode();
    testGuardsAndHelpers();
    testRegistry();
    testHttpServerWireFormat();
    testHttpServerService();
    testSocketUtil();
    testReactorEcho();
    testReactorIdleNoBusyLoop();
    testReactorManyPairs();
    testReactorSubmitRacing();
    testReactorStaleGeneration();
    testReactorTimers();
    testReactorCloseAll();
    testReactorQuiesce();   // last reactor test: irreversible

    std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
    std::printf(g_failures == 0 ? "ALL PASSED\n" : "FAILED\n");
    return g_failures == 0 ? 0 : 1;
}
