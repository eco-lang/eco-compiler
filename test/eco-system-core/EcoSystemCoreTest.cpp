//===- EcoSystemCoreTest.cpp - Unit tests for EcoSystem_Core --------------===//
//
// plans/eco-system-library.md Phase 2 step 2.8 (and the WS1 refactors of
// plans/eco-system-websockets.md: Conn protocols, listener callback mode,
// mapped stream pairs). No Elm program: the services
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
#include "eco-system/HttpServer/Http1.hpp"
#include "eco-system/HttpServer/Http2.hpp"
#include "eco-system/HttpServer/HttpServerService.hpp"
#include "eco-system/HttpServer/HttpTables.hpp"
#include "eco-system/Socket/Conn.hpp"
#include "eco-system/Socket/FaceProtocol.hpp"
#include "eco-system/Socket/Listener.hpp"
#include "eco-system/Stream/Stream.hpp"
#include "eco-system/Stream/StreamTable.hpp"
#include "eco-system/WebSocket/WsDeflate.hpp"
#include "eco-system/WebSocket/WsFrame.hpp"
#include "eco-system/WebSocket/WsHandshake.hpp"

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

#include <nghttp2/nghttp2.h>

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
// HttpServer wire format (plans/eco-system-websockets.md §3.4 "Responses",
// phase WS2: serializeH1). The connections themselves are tested on the
// reactor further down (testHttp1*).
// ---------------------------------------------------------------------------

namespace HttpSrvT = Eco::System::HttpSrv;

bool contains(const std::string& s, const std::string& sub) {
    return s.find(sub) != std::string::npos;
}

void testHttpServerWireFormat() {
    std::printf("HttpServer: serializeH1 wire format\n");
    HttpSrvT::ResponseData r;
    r.status = 201;
    r.headers = {{"X-Multi", "a"}, {"X-Multi", "b"}, {"Content-Length", "999"},
                 {"connection", "keep-alive"}, {"Bad", "x\r\nInjected: 1"}, {"Date", "today"},
                 {"Transfer-Encoding", "chunked"}, {"", "empty name"}};
    r.body = "pong";
    HttpSrvT::H1Options close;
    std::string out = HttpSrvT::serializeH1(r, close);
    CHECK(out.rfind("HTTP/1.1 201 Created\r\n", 0) == 0);
    CHECK(contains(out, "\r\nX-Multi: a\r\nX-Multi: b\r\n"));
    CHECK(contains(out, "\r\nContent-Length: 4\r\n"));
    CHECK(!contains(out, "999"));
    CHECK(!contains(out, "keep-alive"));
    CHECK(!contains(out, "Injected"));
    CHECK(!contains(out, "chunked"));
    CHECK(!contains(out, "empty name"));
    CHECK(contains(out, "\r\nDate: today\r\n"));
    CHECK(contains(out, "\r\nConnection: close\r\n\r\npong"));
    CHECK(out.size() >= 4 && out.compare(out.size() - 4, 4, "pong") == 0);

    HttpSrvT::H1Options ka;
    ka.keepAlive = true;
    std::string kept = HttpSrvT::serializeH1(r, ka);
    CHECK(contains(kept, "\r\nConnection: keep-alive\r\n\r\npong"));
    CHECK(!contains(kept, "Connection: close"));

    HttpSrvT::H1Options head;
    head.isHead = true;
    std::string h = HttpSrvT::serializeH1(r, head);
    CHECK(contains(h, "\r\nContent-Length: 4\r\n"));
    CHECK(h.size() >= 4 && h.compare(h.size() - 4, 4, "\r\n\r\n") == 0);

    HttpSrvT::ResponseData nc;
    nc.status = 204;
    nc.body = "ignored";
    std::string noContent = HttpSrvT::serializeH1(nc, ka);
    CHECK(noContent.rfind("HTTP/1.1 204 No Content\r\n", 0) == 0);
    CHECK(!contains(noContent, "Content-Length"));
    CHECK(!contains(noContent, "ignored"));
    CHECK(contains(noContent, "\r\nDate: "));
    nc.status = 304;
    CHECK(!contains(HttpSrvT::serializeH1(nc, ka), "Content-Length"));

    HttpSrvT::ResponseData odd;
    odd.status = 42;   // out of range → 500
    CHECK(HttpSrvT::serializeH1(odd, close).rfind("HTTP/1.1 500 Internal Server Error\r\n", 0) == 0);
    odd.status = 299;
    CHECK(HttpSrvT::serializeH1(odd, close).rfind("HTTP/1.1 299 unknown\r\n", 0) == 0);
    // A user 1xx (and 101 outside an upgrade) is never a final response: 500.
    for (int64_t st : {100, 101, 103, 199}) {
        odd.status = st;
        std::string o = HttpSrvT::serializeH1(odd, close);
        CHECK(o.rfind("HTTP/1.1 500 Internal Server Error\r\n", 0) == 0);
        CHECK(contains(o, "\r\nContent-Length: 0\r\n"));
    }
    CHECK(std::string(HttpSrvT::statusReason(404)) == "Not Found");
    CHECK(std::string(HttpSrvT::statusReason(431)) == "Request Header Fields Too Large");

    CHECK(HttpSrvT::headersAskClose({{"Connection", "close"}}));
    CHECK(HttpSrvT::headersAskClose({{"x", "y"}, {"CONNECTION", " Keep-Alive ,  Close "}}));
    CHECK(!HttpSrvT::headersAskClose({{"Connection", "keep-alive"}, {"X-Close", "close"}}));
    CHECK(!HttpSrvT::headersAskClose({{"Connection", "closed"}}));
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

// --- Stream additions (plans/eco-system-websockets.md §3.3, W16, WS1) ----------
//
// The mapped pairs call real closures: native ones (allocClosureK with a C++
// evaluator), applied by the stream table exactly as an Elm closure would
// be. Bodies are called directly; the resume closure records the task.

std::vector<std::string> g_resumed;   // "ok:<String>" / "err:<kind>:<reason>"
int g_fromWireCalls = 0;
int g_toWireCalls = 0;

void drainResults() {
    ChannelResult tmp;
    while (tryPopChannelResult(tmp)) {}
}

void* recordResumeEval(void* args[]) {
    HPointer task = dec(args[0]);
    auto* t = static_cast<Elm::Task*>(Allocator::instance().resolve(task));
    if (t->ctor == Elm::alloc::Task_Succeed) {
        g_resumed.push_back("ok:" + toStdString(t->value.p));
    } else {
        Tuple2* tup = asTuple2(t->value.p);
        g_resumed.push_back("err:" + std::to_string(tup->a.i) + ":" + toStdString(tup->b.p));
    }
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

// fromWire ( tag, text, bytes ) = "tag|text|bytes" (a String).
void* fromWireEval(void* args[]) {
    std::string out;
    {
        Tuple3* t3 = asTuple3(dec(args[0]));
        out = std::to_string(t3->a.i) + "|" + toStdString(t3->b.p) + "|" + toStdBytes(t3->c.p);
    }
    ++g_fromWireCalls;
    return reinterpret_cast<void*>(enc(alloc::allocStringFromUTF8(out)));
}

// toWire s = ( 1, s, empty ) when s starts with 'T', else ( 2, "", bytes s ).
void* toWireEval(void* args[]) {
    std::string s = toStdString(dec(args[0]));
    ++g_toWireCalls;
    bool text = !s.empty() && s[0] == 'T';
    HPointer str = alloc::listNil(), bytes = alloc::listNil();
    Elm::StackRootGuard g(&str, &bytes);
    str = text ? alloc::allocStringFromUTF8(s) : alloc::emptyString();
    if (text || s.empty()) {
        bytes = alloc::emptyBytes();
    } else {
        alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(s.size());
        std::memcpy(bb.bytes, s.data(), s.size());
        bytes = bb.hp;
    }
    HPointer t = alloc::tuple3(alloc::unboxedInt(text ? 1 : 2), alloc::boxed(str), alloc::boxed(bytes), 0x1);
    return reinterpret_cast<void*>(enc(t));
}

HPointer nativeClosure1(EvalFunction fn) { return alloc::allocClosureK(fn, 1, PK_Boxed); }

// A channel whose requests the test answers by hand.
struct ChanLog {
    std::deque<uint64_t> reads;   // pending read tokens
    std::vector<std::tuple<uint64_t, int64_t, bool, std::string>> writes;
    std::vector<uint64_t> closes;
    int shutdowns = 0;
    bool destroyed = false;
};

class TestChannel final : public ByteChannel {
public:
    explicit TestChannel(std::shared_ptr<ChanLog> log) : log_(std::move(log)) {}
    ~TestChannel() override { log_->destroyed = true; }
    void requestRead(uint64_t token, size_t) override { log_->reads.push_back(token); }
    void requestWrite(uint64_t token, std::string bytes) override {
        log_->writes.emplace_back(token, 0, false, std::move(bytes));
    }
    void requestWriteTagged(uint64_t token, int64_t tag, bool text, std::string bytes) override {
        log_->writes.emplace_back(token, tag, text, std::move(bytes));
    }
    void close(uint64_t token) override { log_->closes.push_back(token); }
    void shutdown() override {
        ++log_->shutdowns;
        while (!log_->reads.empty()) {   // pending requests complete ECANCELED
            ChannelResult r;
            r.channelId = id();
            r.token = log_->reads.front();
            r.op = ChannelResult::Op::Read;
            r.err = ECANCELED;
            log_->reads.pop_front();
            postChannelResult(std::move(r));
        }
    }

private:
    std::shared_ptr<ChanLog> log_;
};

// A plain channel (default requestWriteTagged).
class PlainTestChannel final : public ByteChannel {
public:
    std::vector<std::string> writes;
    void requestRead(uint64_t, size_t) override {}
    void requestWrite(uint64_t, std::string bytes) override { writes.push_back(std::move(bytes)); }
    void close(uint64_t) override {}
    void shutdown() override {}
};

// Answers the oldest pending read of `ch` and runs the channel drain.
void answerRead(const std::shared_ptr<ChanLog>& log, uint64_t chanId, int64_t tag, bool text,
                const std::string& bytes, int err = 0, bool eof = false,
                const std::string& reason = std::string()) {
    CHECK(!log->reads.empty());
    if (log->reads.empty()) return;
    ChannelResult r;
    r.channelId = chanId;
    r.token = log->reads.front();
    log->reads.pop_front();
    r.op = ChannelResult::Op::Read;
    r.tag = tag;
    r.text = text;
    r.bytes = bytes;
    r.err = err;
    r.eof = eof;
    r.reason = reason;
    postChannelResult(std::move(r));
    channelDrain();
}

// Calls a stream body with `captured` and the recording resume.
template <typename Body>
void callBody(Body body, HPointer captured) {
    HPointer resume = alloc::listNil();
    Elm::StackRootGuard g(&captured, &resume);
    resume = nativeClosure1(&recordResumeEval);
    body(captured, resume);
}

void streamRead(int64_t id) { callBody(&streamReadBody, alloc::allocInt(id)); }

void streamWrite(int64_t id, const std::string& s, bool enqueue = false) {
    HPointer v = alloc::allocStringFromUTF8(s);
    Elm::StackRootGuard g(&v);
    HPointer cap = alloc::tuple2(alloc::boxed(v), alloc::unboxedInt(id), 0x4);
    callBody(enqueue ? &streamEnqueueBody : &streamWriteBody, cap);
}

std::string lastResumed() { return g_resumed.empty() ? std::string("<none>") : g_resumed.back(); }

std::vector<std::pair<int64_t, std::string>> g_readerGot;   // (tag, text-or-bytes / "EOF" / "ERR:reason")

void testReader(int64_t, ChannelResult& r, void* ctx) {
    ++*static_cast<int*>(ctx);
    if (r.eof) g_readerGot.emplace_back(-1, "EOF");
    else if (r.err) g_readerGot.emplace_back(-2, "ERR:" + r.reason);
    else g_readerGot.emplace_back(r.tag, std::string(r.text ? "T:" : "B:") + r.bytes);
}

void testMappedSource() {
    std::printf("Stream: mapped source (fromWire, read-ahead, parked, errors, erase)\n");
    drainResults();
    g_resumed.clear();
    g_fromWireCalls = 0;
    auto log = std::make_shared<ChanLog>();
    auto* ch = new TestChannel(log);
    uint64_t chan = ch->id();
    HPointer fn = nativeClosure1(&fromWireEval);
    int64_t id = createMappedSource(ch, enc(fn));   // fn's word is in the scanned pair now
    CHECK(log->reads.size() == 1);                  // read-ahead
    CHECK(streamIsUncountedToken(log->reads.front()));

    // A chunk arrives with no consumer: kept as POD, not mapped, no new read.
    answerRead(log, chan, 1, true, "hi");
    CHECK(g_fromWireCalls == 0 && log->reads.empty());

    // An immediate read maps it; the next read-ahead goes out.
    streamRead(id);
    CHECK(lastResumed() == "ok:1|hi|");
    CHECK(g_fromWireCalls == 1);
    CHECK(log->reads.size() == 1);

    // A parked read gets the next chunk (binary) as soon as it arrives.
    size_t n0 = g_resumed.size();
    streamRead(id);
    CHECK(g_resumed.size() == n0);   // parked
    Allocator::instance().minorGC();  // the parked read and the scanned closure survive a GC
    answerRead(log, chan, 2, false, std::string("\x01\x02", 2));
    CHECK(lastResumed() == std::string("ok:2||\x01\x02", 8));
    CHECK(g_fromWireCalls == 2);

    // Read-ahead is one chunk deep (backpressure): no request while one waits.
    answerRead(log, chan, 1, true, "a");
    CHECK(log->reads.empty());
    streamRead(id);
    CHECK(lastResumed() == "ok:1|a|");

    // A read error fails the parked read with its reason and shuts the channel.
    streamRead(id);
    answerRead(log, chan, 0, false, "", ECONNRESET, false, "read ECONNRESET");
    CHECK(lastResumed() == "err:1:read ECONNRESET");
    CHECK(log->shutdowns == 1);
    streamRead(id);
    CHECK(lastResumed() == "err:1:read ECONNRESET");

    // EOF on a second source: a parked read gets Closed; the pair is erased
    // and its channel destroyed.
    auto log2 = std::make_shared<ChanLog>();
    auto* ch2 = new TestChannel(log2);
    int64_t id2 = createMappedSource(ch2, enc(nativeClosure1(&fromWireEval)));
    streamRead(id2);
    answerRead(log2, ch2->id(), 0, false, "", 0, true);
    CHECK(lastResumed() == "err:0:");
    CHECK(log2->closes.size() == 1 && log2->closes[0] == 0);   // released, uncounted
    CHECK(streamTable().find(id2) == nullptr);
    CHECK(log2->destroyed);
    streamRead(id2);
    CHECK(lastResumed() == "err:0:");

    // cancelReadable: later reads give Closed; the read-ahead in flight is
    // cancelled (its ECANCELED result releases the pair).
    auto log3 = std::make_shared<ChanLog>();
    auto* ch3 = new TestChannel(log3);
    int64_t id3 = createMappedSource(ch3, enc(nativeClosure1(&fromWireEval)));
    {
        HPointer reason = alloc::allocStringFromUTF8("bye");
        Elm::StackRootGuard g(&reason);
        HPointer cap = alloc::tuple2(alloc::boxed(reason), alloc::unboxedInt(id3), 0x4);
        Elm::StackRootGuard g2(&cap);
        (void)streamCancelReadableBody(cap);
    }
    CHECK(log3->shutdowns == 1);
    channelDrain();   // the cancelled read-ahead
    CHECK(streamTable().find(id3) == nullptr);
    streamRead(id3);
    CHECK(lastResumed() == "err:0:");

    // Piped into an identity pair: chunks are mapped for the pipe.
    auto log4 = std::make_shared<ChanLog>();
    auto* ch4 = new TestChannel(log4);
    int64_t src = createMappedSource(ch4, enc(nativeClosure1(&fromWireEval)));
    int64_t dst = 0;
    {
        HPointer cap = alloc::tuple2(alloc::unboxedInt(4), alloc::unboxedInt(4), 0x5);
        Elm::StackRootGuard g(&cap);
        HPointer task = streamIdentityBody(cap);
        auto* t = static_cast<Elm::Task*>(Allocator::instance().resolve(task));
        dst = t->value.i;   // succeedInt: unboxed
    }
    CHECK(pipeStreams(src, dst));
    CHECK(!attachReader(src, &testReader, nullptr));   // piped → refused
    answerRead(log4, ch4->id(), 1, true, "p1");
    answerRead(log4, ch4->id(), 2, false, "p2");
    streamRead(dst);
    CHECK(lastResumed() == "ok:1|p1|");
    streamRead(dst);
    CHECK(lastResumed() == "ok:2||p2");
    answerRead(log4, ch4->id(), 0, false, "", 0, true);   // EOF → the pipe closes dst
    streamRead(dst);
    CHECK(lastResumed() == "err:0:");
}

void testMappedReaderAttach() {
    std::printf("Stream: subscription reader (attach/detach rules)\n");
    drainResults();
    g_resumed.clear();
    g_readerGot.clear();
    g_fromWireCalls = 0;
    int calls = 0;
    auto log = std::make_shared<ChanLog>();
    auto* ch = new TestChannel(log);
    uint64_t chan = ch->id();
    int64_t id = createMappedSource(ch, enc(nativeClosure1(&fromWireEval)));

    // Parked read → attach refused.
    streamRead(id);
    CHECK(!attachReader(id, &testReader, &calls));
    answerRead(log, chan, 1, true, "m1");
    CHECK(lastResumed() == "ok:1|m1|");

    // A chunk read ahead before attaching goes to the reader first, from
    // the channel drain (never inside attachReader).
    answerRead(log, chan, 1, true, "m2");
    CHECK(log->reads.empty());
    CHECK(attachReader(id, &testReader, &calls));
    CHECK(calls == 0);
    CHECK(!attachReader(id, &testReader, &calls));   // already attached
    streamRead(id);
    CHECK(lastResumed() == "err:2:");                // Locked while attached
    channelDrain();                                  // the kick
    CHECK(calls == 1 && g_readerGot.back() == std::make_pair(int64_t{1}, std::string("T:m2")));
    CHECK(log->reads.size() == 1);
    answerRead(log, chan, 2, false, "m3");           // straight to the reader
    CHECK(calls == 2 && g_readerGot.back() == std::make_pair(int64_t{2}, std::string("B:m3")));
    CHECK(log->reads.size() == 1);                   // as fast as the reader takes them
    CHECK(g_fromWireCalls == 1);                     // the reader bypasses fromWire
    {
        HPointer reason = alloc::allocStringFromUTF8("x");
        Elm::StackRootGuard g(&reason);
        HPointer cap = alloc::tuple2(alloc::boxed(reason), alloc::unboxedInt(id), 0x4);
        Elm::StackRootGuard g2(&cap);
        HPointer task = streamCancelReadableBody(cap);   // Locked
        auto* t = static_cast<Elm::Task*>(Allocator::instance().resolve(task));
        CHECK(t->ctor == Elm::alloc::Task_Fail);
    }

    // Detach, then read: later chunks queue and are read as usual.
    detachReader(id);
    detachReader(id);   // no-op
    answerRead(log, chan, 1, true, "m4");
    CHECK(calls == 2);
    streamRead(id);
    CHECK(lastResumed() == "ok:1|m4|");

    // Re-attach; the end reaches the reader once (eof), then the pair goes.
    CHECK(attachReader(id, &testReader, &calls));
    answerRead(log, chan, 0, false, "", 0, true);
    CHECK(calls == 3 && g_readerGot.back().second == "EOF");
    CHECK(log->closes.size() == 1 && log->closes[0] == 0);
    CHECK(streamTable().find(id) == nullptr);   // done: erased (the reader saw the end)
    detachReader(id);                           // no-op on a missing pair
    CHECK(log->destroyed);
}

void testMappedSink() {
    std::printf("Stream: mapped sink (toWire, tagged writes, completion, errors)\n");
    drainResults();
    g_resumed.clear();
    g_toWireCalls = 0;
    auto log = std::make_shared<ChanLog>();
    auto* ch = new TestChannel(log);
    uint64_t chan = ch->id();
    int64_t id = createMappedSink(ch, enc(nativeClosure1(&toWireEval)));

    // write: completes when the channel completes it.
    streamWrite(id, "Thello");
    CHECK(g_toWireCalls == 1);
    CHECK(log->writes.size() == 1);
    CHECK(std::get<1>(log->writes[0]) == 1 && std::get<2>(log->writes[0]) &&
          std::get<3>(log->writes[0]) == "Thello");
    size_t n0 = g_resumed.size();
    CHECK(n0 == 0);
    Allocator::instance().minorGC();
    {
        ChannelResult r;
        r.channelId = chan;
        r.token = std::get<0>(log->writes[0]);
        r.op = ChannelResult::Op::Write;
        r.written = 6;
        postChannelResult(std::move(r));
        channelDrain();
    }
    CHECK(lastResumed() == "ok:");

    // enqueue: completes on acceptance; binary value.
    streamWrite(id, "bin", /*enqueue=*/true);
    CHECK(lastResumed() == "ok:");
    CHECK(log->writes.size() == 2 && std::get<1>(log->writes[1]) == 2 &&
          !std::get<2>(log->writes[1]) && std::get<3>(log->writes[1]) == "bin");

    // A failed write errors the writable: this and later writes fail.
    streamWrite(id, "Tz");
    {
        ChannelResult r;
        r.channelId = chan;
        r.token = std::get<0>(log->writes[2]);
        r.op = ChannelResult::Op::Write;
        r.err = EPIPE;
        r.reason = "write EPIPE";
        postChannelResult(std::move(r));
        channelDrain();
    }
    CHECK(lastResumed() == "err:1:write EPIPE");
    CHECK(log->shutdowns == 1);
    streamWrite(id, "Tq");
    CHECK(lastResumed() == "err:1:write EPIPE");
    CHECK(g_toWireCalls == 3);   // an errored writable does not map

    // ByteChannel's default requestWriteTagged: tag 0 → requestWrite, else ENOTSUP.
    drainResults();
    PlainTestChannel plain;
    plain.requestWriteTagged(1, 0, false, "raw");
    CHECK(plain.writes.size() == 1 && plain.writes[0] == "raw");
    plain.requestWriteTagged(2, 1, true, "txt");
    auto res = popChannel(1, 100);
    CHECK(res.size() == 1 && res[0].err == ENOTSUP && res[0].token == 2 &&
          res[0].op == ChannelResult::Op::Write && res[0].channelId == plain.id());
}

// --- Conn protocols (plans/eco-system-websockets.md §3.2, WS1) ----------------

struct ProtoLog {
    std::mutex mu;
    std::vector<std::string> events;
    std::string leftover;      // ProtoLine: the bytes read past its line
    std::atomic<bool> lineDone{false};
    std::atomic<bool> closed{false};
    void add(std::string e) {
        std::lock_guard<std::mutex> lk(mu);
        events.push_back(std::move(e));
    }
    std::vector<std::string> snapshot() {
        std::lock_guard<std::mutex> lk(mu);
        return events;
    }
    bool has(const std::string& e) {
        std::lock_guard<std::mutex> lk(mu);
        return std::find(events.begin(), events.end(), e) != events.end();
    }
};

// Hands out at most `chunk` bytes per read of what it slurped off the
// socket: the rest is buffered plaintext no fd event announces (as TLS's
// SSL_has_pending).
class ChunkTransport final : public Transport {
public:
    ChunkTransport(int fd, size_t chunk) : fd_(fd), chunk_(chunk) {}
    ssize_t read(char* buf, size_t n) override {
        wantRead = wantWrite = false;
        for (;;) {
            char tmp[4096];
            ssize_t g = ::recv(fd_, tmp, sizeof(tmp), 0);
            if (g > 0) {
                buf_.append(tmp, static_cast<size_t>(g));
                continue;
            }
            if (g == 0) {
                eof_ = true;
                break;
            }
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            errNo = errno;
            errCode = errnoName(errno);
            return -2;
        }
        if (buf_.empty()) {
            if (eof_) return 0;
            wantRead = true;
            return -1;
        }
        size_t k = std::min({n, chunk_, buf_.size()});
        std::memcpy(buf, buf_.data(), k);
        buf_.erase(0, k);
        return static_cast<ssize_t>(k);
    }
    ssize_t write(const char* b, size_t n) override {
        wantRead = wantWrite = false;
        ssize_t put = ::send(fd_, b, n, MSG_NOSIGNAL);
        if (put >= 0) return put;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            wantWrite = true;
            return -1;
        }
        errNo = errno;
        errCode = errnoName(errno);
        return -2;
    }
    int shutdownWrite() override { return ::shutdown(fd_, SHUT_WR) == 0 ? 0 : -1; }
    bool hasBufferedRead() const override { return !buf_.empty(); }

private:
    int fd_;
    size_t chunk_;
    std::string buf_;
    bool eof_ = false;
};

// Reads one line, then stops reading and keeps what came after it.
class ProtoLine final : public ConnProtocol {
public:
    explicit ProtoLine(std::shared_ptr<ProtoLog> log) : log_(std::move(log)) {}
    void onOpen(Conn&) override { log_->add("A:open"); }
    void onData(Conn&, std::string_view bytes) override {
        line_.append(bytes.data(), bytes.size());
        size_t nl = line_.find('\n');
        if (nl == std::string::npos) return;
        log_->add("A:line:" + line_.substr(0, nl));
        log_->leftover = line_.substr(nl + 1);
        done_ = true;
        log_->lineDone = true;
    }
    void onEof(Conn&) override { log_->add("A:eof"); }
    void onError(Conn&, int, const std::string& code) override { log_->add("A:error:" + code); }
    void onCloseAll(Conn&) override { log_->add("A:closeAll"); }
    bool wantsRead() const override { return !done_; }

private:
    std::shared_ptr<ProtoLog> log_;
    std::string line_;
    bool done_ = false;
};

// Echoes; closes gracefully once `expect` bytes arrived.
class ProtoEcho final : public ConnProtocol {
public:
    ProtoEcho(std::shared_ptr<ProtoLog> log, size_t expect) : log_(std::move(log)), expect_(expect) {}
    void onOpen(Conn&) override { log_->add("B:open"); }
    void onData(Conn& c, std::string_view bytes) override {
        log_->add("B:data:" + std::string(bytes));
        got_ += bytes.size();
        auto log = log_;
        c.write(std::string(bytes), [log](int err) { log->add("B:written:" + std::to_string(err)); });
        if (expect_ != 0 && got_ >= expect_) c.closeGraceful(2000);
    }
    void onEof(Conn& c) override {
        log_->add("B:eof");
        c.closeGraceful(2000);
    }
    void onError(Conn& c, int, const std::string& code) override {
        log_->add("B:error:" + code);
        c.abort(false);
    }
    void onCloseAll(Conn&) override { log_->add("B:closeAll"); }
    bool wantsRead() const override { return true; }

private:
    std::shared_ptr<ProtoLog> log_;
    size_t expect_;
    size_t got_ = 0;
};

// An open server Conn over `fd` (plain or the given transport).
std::shared_ptr<Conn> openConn(int fd, std::unique_ptr<Transport> t) {
    CHECK(setNonBlocking(fd) == 0);
    std::shared_ptr<Conn> c;
    onReactor([&] {
        c = Conn::makeAccepted(fd, true, std::move(t));
        CHECK(R().add(c, fd) != 0);
        c->beginServer(0, [](Conn&, bool ok) { CHECK(ok); });
        CHECK(c->phase() == Conn::Phase::Open);
    });
    return c;
}

void testConnProtocolHandoff() {
    std::printf("Conn: protocol hand-off with leftover and transport-buffered bytes\n");
    int sv[2];
    CHECK(makePair(sv));
    // Everything arrives before the Conn reads: one read slurps it all.
    sendAll(sv[1], "UPGRADE\nhelloworld");
    auto log = std::make_shared<ProtoLog>();
    auto c = openConn(sv[0], std::make_unique<ChunkTransport>(sv[0], 5));
    onReactor([&] {
        CHECK(c->face() != nullptr);   // a new Conn runs the stream faces
        c->addCloseHook([log](Conn&) { log->closed = true; });
        c->setProtocol(std::make_unique<ProtoLine>(log), std::string());
    });
    CHECK(waitUntil([&] { return log->lineDone.load(); }));
    // "UPGRA" + "DE\nhe": the line, "he" read past it; "lloworld" is still
    // in the transport (the socket is drained: no fd event will come).
    CHECK(log->leftover == "he");
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    onReactor([&] {
        CHECK(c->face() == nullptr);   // not a FaceProtocol any more
        c->setProtocol(std::make_unique<ProtoEcho>(log, 10), log->leftover);
    });
    CHECK(recvExactly(sv[1], 10) == "helloworld");
    CHECK(peerSeesEof(sv[1]));   // closeGraceful: the echo, then FIN
    ::close(sv[1]);              // the Conn drains to EOF and closes
    CHECK(waitUntil([&] { return log->closed.load(); }));
    auto ev = log->snapshot();
    std::vector<std::string> expectPrefix{"A:open", "A:line:UPGRADE", "B:open", "B:data:he",
                                          "B:data:llowo", "B:data:rld"};
    std::vector<std::string> data;
    for (const auto& e : ev) {
        if (e.rfind("A:", 0) == 0 || e.rfind("B:open", 0) == 0 || e.rfind("B:data:", 0) == 0) {
            data.push_back(e);
        }
    }
    CHECK(data == expectPrefix);
    CHECK(std::count(ev.begin(), ev.end(), std::string("B:written:0")) == 3);
    CHECK(c->phase() == Conn::Phase::Closed);

    // A Socket.Connection hand-off with nothing parked: face requests made
    // afterwards fail at once (ECANCELED with the detached reason).
    int sp[2];
    CHECK(makePair(sp));
    auto c2 = openConn(sp[0], nullptr);
    auto log2 = std::make_shared<ProtoLog>();
    onReactor([&] {
        CHECK(c2->face() && c2->face()->idle());
        c2->setFaceDetachedReason("upgraded");
        c2->setProtocol(std::make_unique<ProtoEcho>(log2, 0), "x");   // leftover only
    });
    CHECK(recvExactly(sp[1], 1) == "x");
    drainResults();
    onReactor([&] { c2->reqRead(77, 5, 1024); });
    auto res = popChannel(1);
    CHECK(res.size() == 1 && res[0].channelId == 77 && res[0].err == ECANCELED &&
          res[0].reason == "upgraded");
    sendAll(sp[1], "abc");
    CHECK(recvExactly(sp[1], 3) == "abc");
    ::close(sp[1]);   // EOF → ProtoEcho closes
    CHECK(waitUntil([&] { return c2->phase() == Conn::Phase::Closed; }));
    CHECK(log2->has("B:eof"));
}

// Records each timer with the time it fired.
class ProtoTimers final : public ConnProtocol {
public:
    struct Fired {
        int id;
        int64_t at;
        int64_t deadline;
    };
    std::mutex mu;
    std::vector<Fired> fired;
    int64_t base = 0;
    int64_t want[Conn::kMaxTimers] = {};
    bool rearmed = false;

    void onOpen(Conn& c) override {
        base = R().nowMs();
        auto set = [&](int id, int64_t off) {
            want[id] = off ? base + off : 0;
            c.setDeadline(id, want[id]);
        };
        set(Conn::kTimerIdle, 60);
        set(Conn::kTimerHeartbeat, 20);
        set(Conn::kTimerHeaders, 40);
        set(Conn::kTimerPong, 40);             // ties with 3: id order
        set(Conn::kTimerCloseHandshake, 30);
        set(Conn::kTimerCloseHandshake, 0);    // cancelled
        set(Conn::kTimerRequest, 10);
        set(Conn::kTimerRequest, 50);          // replaced
        CHECK(c.deadline(Conn::kTimerRequest) == base + 50);
        CHECK(c.deadline(Conn::kTimerCloseHandshake) == 0);
    }
    void onTimer(Conn& c, int id) override {
        int64_t now = R().nowMs();
        {
            std::lock_guard<std::mutex> lk(mu);
            fired.push_back(Fired{id, now, want[id]});
        }
        CHECK(c.deadline(id) == 0);   // cleared before the call
        if (id == Conn::kTimerHeartbeat && !rearmed) {
            rearmed = true;
            want[id] = now + 15;
            c.setDeadline(id, want[id]);
        }
    }
    void onData(Conn&, std::string_view) override {}
    void onEof(Conn&) override {}
    void onError(Conn&, int, const std::string&) override {}
    void onCloseAll(Conn&) override {}
    bool wantsRead() const override { return false; }
};

void testConnMultiTimer() {
    std::printf("Conn: several deadlines on one reactor timer (order, tie, replace, cancel, re-arm)\n");
    int sv[2];
    CHECK(makePair(sv));
    auto c = openConn(sv[0], nullptr);
    auto* pt = new ProtoTimers();
    onReactor([&] { c->setProtocol(std::unique_ptr<ConnProtocol>(pt), std::string()); });
    CHECK(waitUntil([&] {
        std::lock_guard<std::mutex> lk(pt->mu);
        return pt->fired.size() >= 6;
    }, 3000));
    std::this_thread::sleep_for(std::chrono::milliseconds(120));   // nothing else fires
    std::vector<int> order;
    bool early = false;
    {
        std::lock_guard<std::mutex> lk(pt->mu);
        for (const auto& f : pt->fired) {
            order.push_back(f.id);
            if (f.at < f.deadline) early = true;
        }
    }
    CHECK(!early);
    CHECK((order == std::vector<int>{Conn::kTimerHeartbeat, Conn::kTimerHeartbeat,
                                     Conn::kTimerHeaders, Conn::kTimerPong,
                                     Conn::kTimerRequest, Conn::kTimerIdle}));
    // A deadline cancelled after arming never fires; abort clears them.
    onReactor([&] {
        c->setDeadline(Conn::kTimerIdle, R().nowMs() + 30);
        c->setDeadline(Conn::kTimerIdle, 0);
        c->setDeadline(Conn::kTimerPong, R().nowMs() + 40);
        c->abort(false);
        CHECK(c->deadline(Conn::kTimerPong) == 0);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    {
        std::lock_guard<std::mutex> lk(pt->mu);
        CHECK(pt->fired.size() == 6);
    }
    CHECK(peerSeesEof(sv[1]));
    ::close(sv[1]);
}

void testListenerCallbackMode() {
    std::printf("Listener: callback mode (protocol factory, maxConnections credit)\n");
    int lfd = ::socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    CHECK(lfd >= 0);
    struct sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;
    CHECK(::bind(lfd, reinterpret_cast<sockaddr*>(&a), sizeof(a)) == 0);
    CHECK(::listen(lfd, 16) == 0);
    socklen_t al = sizeof(a);
    CHECK(::getsockname(lfd, reinterpret_cast<sockaddr*>(&a), &al) == 0);
    auto log = std::make_shared<ProtoLog>();
    std::atomic<int> made{0};
    auto l = std::make_shared<ListenerHandler>(lfd, 1, 0, false, std::string(), false, nullptr);
    l->setCallbackMode([log, &made](Conn& c) -> std::unique_ptr<ConnProtocol> {
        ++made;
        CHECK(c.phase() == Conn::Phase::Open && c.tlsInfo() == nullptr);
        return std::make_unique<ProtoEcho>(log, 0);
    }, 1);
    onReactor([&] { l->start(); });
    auto dial = [&]() {
        int fd = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        CHECK(::connect(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a)) == 0);
        return fd;
    };
    int c1 = dial();
    sendAll(c1, "one");
    CHECK(recvExactly(c1, 3) == "one");
    int c2 = dial();   // completes in the backlog; not accepted (1 open of max 1)
    sendAll(c2, "two");
    CHECK(recvExactly(c2, 3, 300).empty());
    int64_t open = -1;
    onReactor([&] { open = l->openConnections(); });
    CHECK(open == 1);
    CHECK(made == 1);
    ::shutdown(c1, SHUT_WR);   // EOF → closeGraceful → closed → credit back
    CHECK(peerSeesEof(c1));
    ::close(c1);
    CHECK(recvExactly(c2, 3) == "two");
    CHECK(made == 2);
    ::close(c2);
    CHECK(waitUntil([&] {
        int64_t n = -1;
        onReactor([&] { n = l->openConnections(); });
        return n == 0;
    }));
    onReactor([&] { l->close(); });
}

// ---------------------------------------------------------------------------
// Http.Server on the reactor (plans/eco-system-websockets.md §3.4, WS2):
// Http1Protocol behind a callback-mode listener, driven over real sockets.
// The main-thread tables are bypassed: the Request / ConnGone events are
// popped from the HttpTables queue by hand and answered with http1Respond
// on the reactor, as the respond kernel does.
// ---------------------------------------------------------------------------

struct H1Server {
    int port = 0;
    std::shared_ptr<HttpSrvT::ServerReactorState> rs;
    std::shared_ptr<ListenerHandler> l;
};

H1Server startH1(const std::function<void(HttpSrvT::ServerConfig&)>& tweak) {
    H1Server s;
    HttpSrvT::ListenResult lr = HttpSrvT::listenOn("127.0.0.1", 0);
    CHECK(lr.fd >= 0 && lr.boundPort > 0);
    if (lr.fd < 0) return s;
    CHECK((::fcntl(lr.fd, F_GETFL) & O_NONBLOCK) != 0);
    CHECK((::fcntl(lr.fd, F_GETFD) & FD_CLOEXEC) != 0);
    auto cfg = std::make_shared<HttpSrvT::ServerConfig>();
    cfg->serverId = 99;
    cfg->gen = 7;
    cfg->fallbackAuthority = "127.0.0.1:" + std::to_string(lr.boundPort);
    tweak(*cfg);
    s.rs = std::make_shared<HttpSrvT::ServerReactorState>();
    s.rs->cfg = cfg;
    s.l = std::make_shared<ListenerHandler>(lr.fd, 99, 7, false, std::string(), false, nullptr);
    auto rs = s.rs;
    s.l->setCallbackMode([rs](Conn& c) { return HttpSrvT::makeHttp1Protocol(c, rs); }, -1);
    auto l = s.l;
    onReactor([l] { l->start(); });
    s.port = static_cast<int>(lr.boundPort);
    return s;
}

std::vector<HttpSrvT::HttpEvent> popHttp(size_t n, int timeoutMs = 5000) {
    return popN<HttpSrvT::HttpEvent>(n, timeoutMs, [](HttpSrvT::HttpEvent& e) {
        return HttpSrvT::httpTablesPopEventForTest(e);
    });
}

// One Request event (or a default one, with a failed CHECK).
HttpSrvT::HttpEvent popRequest() {
    auto evs = popHttp(1);
    CHECK(evs.size() == 1 && evs[0].kind == HttpSrvT::HttpEvent::Kind::Request);
    return evs.empty() ? HttpSrvT::HttpEvent{} : std::move(evs[0]);
}

bool h1Respond(const HttpSrvT::HttpEvent& ev, int64_t status, const std::string& body,
               std::vector<std::pair<std::string, std::string>> headers = {},
               std::shared_ptr<std::atomic<int>> doneErr = nullptr) {
    bool ok = false;
    onReactor([&] {
        HttpSrvT::ResponseData r;
        r.status = status;
        r.body = body;
        r.headers = std::move(headers);
        std::function<void(int)> done = [doneErr](int e) {
            if (doneErr) doneErr->store(e);
        };
        ok = HttpSrvT::http1Respond(ev.conn.lock(), ev.key, std::move(r), false, done);
    });
    return ok;
}

size_t countOf(const std::string& s, const std::string& sub) {
    size_t n = 0;
    for (size_t i = s.find(sub); i != std::string::npos; i = s.find(sub, i + 1)) ++n;
    return n;
}

// Sends `req` on a fresh connection and reads to EOF: for requests the
// server answers itself (400, 413, ...). No Request event may follow.
std::string rejected(int port, const std::string& req) {
    int c = connectTo(port);
    sendAll(c, req);
    std::string out = readToEof(c);
    ::close(c);
    return out;
}

void testHttp1KeepAlivePipeline() {
    std::printf("Http1: keep-alive, pipelining (one in flight, in order), HTTP/1.0, chunked, HEAD\n");
    H1Server a = startH1([](HttpSrvT::ServerConfig&) {});
    {
        HttpSrvT::HttpEvent stale;
        while (HttpSrvT::httpTablesPopEventForTest(stale)) {
        }
    }
    int c = connectTo(a.port);
    sendAll(c, "GET /one HTTP/1.1\r\nHost: h\r\n\r\n"
               "GET /two HTTP/1.1\r\nHost: h\r\n\r\n"
               "POST /three?x=1 HTTP/1.1\r\nHost: h:81\r\nContent-Length: 3\r\n\r\nabc");
    HttpSrvT::HttpEvent e1 = popRequest();
    CHECK(e1.req.method == "GET" && e1.req.url == "http://h/one" && e1.req.flags == 1);
    CHECK(e1.req.upgrade.empty() && e1.serverId == 99 && e1.gen == 7 && e1.key > 0);
    CHECK(popHttp(1, 150).empty());   // one in flight: /two waits for the answer
    auto done1 = std::make_shared<std::atomic<int>>(-1);
    CHECK(h1Respond(e1, 200, "r1", {{"Content-Type", "text/plain"}}, done1));
    CHECK(!h1Respond(e1, 200, "again"));   // answered already
    HttpSrvT::HttpEvent e2 = popRequest();
    CHECK(e2.req.url == "http://h/two" && e2.key != e1.key);
    CHECK(h1Respond(e2, 404, "r2"));
    HttpSrvT::HttpEvent e3 = popRequest();
    CHECK(e3.req.method == "POST" && e3.req.url == "http://h:81/three?x=1" && e3.req.body == "abc");
    CHECK(h1Respond(e3, 200, "r3", {{"Connection", "close"}}));   // the user closes it
    std::string all = readToEof(c);
    ::close(c);
    CHECK(waitUntil([&] { return done1->load() == 0; }));
    size_t p1 = all.find("\r\n\r\nr1"), p2 = all.find("\r\n\r\nr2"), p3 = all.find("\r\n\r\nr3");
    CHECK(p1 != std::string::npos && p2 != std::string::npos && p3 != std::string::npos);
    CHECK(p1 < p2 && p2 < p3);
    CHECK(countOf(all, "Connection: keep-alive\r\n") == 2);
    CHECK(countOf(all, "Connection: close\r\n") == 1);
    CHECK(contains(all, "HTTP/1.1 404 Not Found\r\n"));

    // HTTP/1.0: no Host needed (the server's authority), closes unless asked.
    c = connectTo(a.port);
    sendAll(c, "GET /old HTTP/1.0\r\n\r\n");
    HttpSrvT::HttpEvent e4 = popRequest();
    CHECK(e4.req.url == "http://127.0.0.1:" + std::to_string(a.port) + "/old");
    CHECK(e4.req.flags == 0);
    CHECK(h1Respond(e4, 200, "old"));
    std::string r4 = readToEof(c);
    ::close(c);
    CHECK(contains(r4, "Connection: close\r\n\r\nold"));
    c = connectTo(a.port);
    sendAll(c, "GET /ka HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
    HttpSrvT::HttpEvent e5 = popRequest();
    CHECK(h1Respond(e5, 200, "ka"));
    CHECK(contains(readUntil(c, "\r\n\r\nka"), "Connection: keep-alive\r\n"));
    // ... and stays open for the next request: HEAD gets the length, no body.
    sendAll(c, "HEAD /h HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
    HttpSrvT::HttpEvent e6 = popRequest();
    CHECK(e6.req.method == "HEAD" && e6.req.isHead);
    CHECK(h1Respond(e6, 200, "body"));
    std::string r6 = readUntil(c, "\r\n\r\n");
    CHECK(contains(r6, "Content-Length: 4\r\n"));
    ::close(c);

    // A chunked body split over two writes; repeated headers kept in order.
    c = connectTo(a.port);
    sendAll(c, "POST /c HTTP/1.1\r\nHost: h\r\nX-Dup: 1\r\nX-D");
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    sendAll(c, "up: 2\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
    HttpSrvT::HttpEvent e7 = popRequest();
    CHECK(e7.req.body == "hello world");
    CHECK(e7.req.headers.size() == 4);
    if (e7.req.headers.size() == 4) {
        CHECK(e7.req.headers[1].first == "X-Dup" && e7.req.headers[1].second == "1");
        CHECK(e7.req.headers[2].first == "X-Dup" && e7.req.headers[2].second == "2");
    }
    CHECK(h1Respond(e7, 204, "ignored"));
    std::string r7 = readUntil(c, "\r\n\r\n");
    CHECK(r7.rfind("HTTP/1.1 204 No Content\r\n", 0) == 0 && !contains(r7, "Content-Length"));
    // The peer half-closes after a request: it is answered, then closed.
    sendAll(c, "GET /last HTTP/1.1\r\nHost: h\r\n\r\n");
    ::shutdown(c, SHUT_WR);
    HttpSrvT::HttpEvent e8 = popRequest();
    std::this_thread::sleep_for(std::chrono::milliseconds(50));   // the FIN is seen meanwhile
    CHECK(h1Respond(e8, 200, "last"));
    std::string r8 = readToEof(c);
    CHECK(contains(r8, "Connection: close\r\n\r\nlast"));
    ::close(c);
    onReactor([&] { a.l->close(); });
}

void testHttp1Limits() {
    std::printf("Http1: limits, 100-continue, Host rules, strict parsing\n");
    H1Server a = startH1([](HttpSrvT::ServerConfig& c) {
        c.maxHeaderSize = 2048;
        c.maxBodySize = 1000;
    });
    // 100-continue: sent once the head is parsed, then the body.
    int c = connectTo(a.port);
    sendAll(c, "PUT /up HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nExpect: 100-Continue\r\n\r\n");
    CHECK(readUntil(c, "\r\n\r\n") == "HTTP/1.1 100 Continue\r\n\r\n");
    sendAll(c, "abc");
    HttpSrvT::HttpEvent e1 = popRequest();
    CHECK(e1.req.body == "abc");
    CHECK(h1Respond(e1, 200, "ok"));
    CHECK(contains(readUntil(c, "\r\n\r\nok"), "Connection: keep-alive"));
    ::close(c);

    std::string big = rejected(a.port, "PUT /up HTTP/1.1\r\nHost: h\r\nContent-Length: 5000\r\n"
                                       "Expect: 100-continue\r\n\r\n");
    CHECK(big.rfind("HTTP/1.1 413 Payload Too Large\r\n", 0) == 0);
    CHECK(!contains(big, "100 Continue") && contains(big, "Connection: close\r\n"));
    CHECK(rejected(a.port, "PUT /up HTTP/1.1\r\nHost: h\r\nContent-Length: 1001\r\n\r\n")
              .rfind("HTTP/1.1 413 ", 0) == 0);
    std::string chunks = "POST /c HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n";
    for (int i = 0; i < 3; ++i) chunks += "190\r\n" + std::string(400, 'x') + "\r\n";
    chunks += "0\r\n\r\n";
    CHECK(rejected(a.port, chunks).rfind("HTTP/1.1 413 ", 0) == 0);
    CHECK(rejected(a.port, "GET / HTTP/1.1\r\nHost: h\r\nExpect: later\r\n\r\n")
              .rfind("HTTP/1.1 417 Expectation Failed\r\n", 0) == 0);
    CHECK(rejected(a.port, "GET / HTTP/1.1\r\nHost: h\r\nX-Big: " + std::string(3000, 'y') + "\r\n\r\n")
              .rfind("HTTP/1.1 431 Request Header Fields Too Large\r\n", 0) == 0);
    CHECK(rejected(a.port, "GET /" + std::string(3000, 'u') + " HTTP/1.1\r\nHost: h\r\n\r\n")
              .rfind("HTTP/1.1 431 ", 0) == 0);

    // Host (§3.4): missing (1.1), duplicate, invalid → 400.
    const char* badHosts[] = {
        "GET / HTTP/1.1\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nHost: a\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a b\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: \r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a:80x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: [::1\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a/b\r\n\r\n",
        "GET / HTTP/1.0\r\nHost: a\r\nHost: b\r\n\r\n",
    };
    for (const char* req : badHosts) {
        std::string out = rejected(a.port, req);
        CHECK(out.rfind("HTTP/1.1 400 Bad Request\r\n", 0) == 0);
        if (out.rfind("HTTP/1.1 400 ", 0) != 0) std::fprintf(stderr, "    (host case: %s)\n", req);
    }
    // Valid hosts are accepted.
    for (const char* host : {"[::1]:8080", "127.0.0.1", "xn--bcher-kva.example:1", "a%41b"}) {
        c = connectTo(a.port);
        sendAll(c, std::string("GET /h HTTP/1.1\r\nHost: ") + host + "\r\n\r\n");
        HttpSrvT::HttpEvent e = popRequest();
        CHECK(e.req.url == std::string("http://") + host + "/h");
        CHECK(h1Respond(e, 200, "", {{"Connection", "close"}}));
        (void)readToEof(c);
        ::close(c);
    }

    // Request smuggling and malformed requests: strict llhttp → 400 + close.
    const char* smuggles[] = {
        "NOT AN HTTP REQUEST\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabcd",
        "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked, identity\r\n\r\n0\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: h\r\nX-Fold: a\r\n b\r\n\r\n",
        "GET / HTTP/1.1\nHost: h\n\n",
        "GET / HTTP/1.1\r\nHost : h\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: h\r\nX\x01Y: 1\r\n\r\n",
    };
    for (const char* req : smuggles) {
        std::string out = rejected(a.port, req);
        CHECK(out.rfind("HTTP/1.1 400 Bad Request\r\n", 0) == 0 && contains(out, "Connection: close"));
        if (out.rfind("HTTP/1.1 400 ", 0) != 0) std::fprintf(stderr, "    (smuggle case %zu: %s)\n", std::strlen(req), out.substr(0, 40).c_str());
    }
    CHECK(rejected(a.port, "GET / HTTP/2.0\r\nHost: h\r\n\r\n").rfind("HTTP/1.1 ", 0) == 0);
    CHECK(popHttp(1, 100).empty());   // none of them reached "Elm"
    onReactor([&] { a.l->close(); });
}

void testHttp1UpgradeConnectGone() {
    std::printf("Http1: upgrade pending / declined / hand-off head, CONNECT, ConnGone\n");
    H1Server a = startH1([](HttpSrvT::ServerConfig&) {});
    // Declined upgrade: Connection: close, then closed.
    int c = connectTo(a.port);
    sendAll(c, "GET /ws HTTP/1.1\r\nHost: h\r\nUpgrade: WebSocket, foo\r\n"
               "Connection: keep-alive, Upgrade\r\n\r\nEXTRA");
    HttpSrvT::HttpEvent e1 = popRequest();
    CHECK(e1.req.upgrade == "websocket" && e1.req.method == "GET");
    bool pending = false;
    onReactor([&] {
        auto conn = e1.conn.lock();
        auto* p = conn ? dynamic_cast<HttpSrvT::Http1Protocol*>(conn->protocol()) : nullptr;
        pending = p && p->upgradePending(e1.key) && !p->upgradePending(e1.key + 1000);
    });
    CHECK(pending);
    CHECK(h1Respond(e1, 426, "no", {{"Upgrade", "websocket"}}));
    std::string r1 = readToEof(c);
    ::close(c);
    CHECK(r1.rfind("HTTP/1.1 426 Upgrade Required\r\n", 0) == 0);
    CHECK(contains(r1, "Connection: close\r\n\r\nno"));

    // The hand-off hook (WS5): the bytes read past the request.
    c = connectTo(a.port);
    sendAll(c, "GET /ws HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\nFRAME1");
    HttpSrvT::HttpEvent e2 = popRequest();
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    std::string head;
    bool after = true;
    onReactor([&] {
        auto conn = e2.conn.lock();
        auto* p = conn ? dynamic_cast<HttpSrvT::Http1Protocol*>(conn->protocol()) : nullptr;
        if (p) {
            head = p->takeUpgradeHead(*conn, e2.key);
            after = p->upgradePending(e2.key);
            conn->abort(false);
        }
    });
    CHECK(head == "FRAME1" && !after);
    CHECK(popHttp(1, 100).empty());   // taken: no ConnGone for it
    ::close(c);

    // An upgrade request with a body is a normal request (no token), closed after.
    c = connectTo(a.port);
    sendAll(c, "POST /ws HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\nConnection: upgrade\r\n"
               "Content-Length: 2\r\n\r\nhi");
    HttpSrvT::HttpEvent e3 = popRequest();
    CHECK(e3.req.upgrade.empty() && e3.req.body == "hi");
    CHECK(h1Respond(e3, 200, "x"));
    CHECK(contains(readToEof(c), "Connection: close"));
    ::close(c);

    // CONNECT: delivered without a token, closed after the response.
    c = connectTo(a.port);
    sendAll(c, "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n");
    HttpSrvT::HttpEvent e4 = popRequest();
    CHECK(e4.req.method == "CONNECT" && e4.req.upgrade.empty());
    CHECK(e4.req.target == "example.com:443");
    CHECK(h1Respond(e4, 200, "tunnel?"));
    std::string r4 = readToEof(c);
    CHECK(r4.rfind("HTTP/1.1 200 OK\r\n", 0) == 0 && contains(r4, "Connection: close"));
    ::close(c);

    // A reset while the request waits: ConnGone with its key; respond then fails.
    c = connectTo(a.port);
    sendAll(c, "GET /gone HTTP/1.1\r\nHost: h\r\n\r\n");
    HttpSrvT::HttpEvent e5 = popRequest();
    struct linger lg{1, 0};
    ::setsockopt(c, SOL_SOCKET, SO_LINGER, &lg, sizeof(lg));
    ::close(c);
    auto gone = popHttp(1);
    CHECK(gone.size() == 1 && gone[0].kind == HttpSrvT::HttpEvent::Kind::ConnGone &&
          gone[0].key == e5.key && gone[0].serverId == 99);
    CHECK(!h1Respond(e5, 200, "late"));
    onReactor([&] { a.l->close(); });
}

void testHttp1TimeoutsAndClose() {
    std::printf("Http1: headers / request / keep-alive timeouts, server close\n");
    H1Server b = startH1([](HttpSrvT::ServerConfig& c) {
        c.headersMs = 200;
        c.requestMs = 400;
        c.keepAliveMs = 200;
    });
    auto t0 = Clock::now();
    std::string r = rejected(b.port, "GET / HTTP/1.1\r\nHost: h\r\n");   // never ends its head
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count();
    CHECK(r.rfind("HTTP/1.1 408 Request Timeout\r\n", 0) == 0 && contains(r, "Connection: close"));
    CHECK(ms >= 150 && ms < 3000);
    t0 = Clock::now();
    r = rejected(b.port, "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 10\r\n\r\nabc");
    ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count();
    CHECK(r.rfind("HTTP/1.1 408 ", 0) == 0);
    CHECK(ms >= 350 && ms < 3000);
    // Keep-alive timeout: answered, then closed silently when idle.
    int c = connectTo(b.port);
    sendAll(c, "GET / HTTP/1.1\r\nHost: h\r\n\r\n");
    HttpSrvT::HttpEvent e = popRequest();
    std::this_thread::sleep_for(std::chrono::milliseconds(300));   // no timer while Elm answers
    CHECK(h1Respond(e, 200, "one"));
    t0 = Clock::now();
    std::string all = readToEof(c);
    ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count();
    CHECK(countOf(all, "HTTP/1.1 ") == 1 && contains(all, "Connection: keep-alive\r\n\r\none"));
    CHECK(ms >= 150 && ms < 3000);
    ::close(c);
    // A fresh connection that never sends a byte: closed after headersTimeout.
    c = connectTo(b.port);
    CHECK(readToEof(c).empty());
    ::close(c);

    // closeServer: idle connections close at once, in-flight ones finish
    // with Connection: close; the port is free.
    H1Server a = startH1([](HttpSrvT::ServerConfig&) {});
    int idle = connectTo(a.port);
    sendAll(idle, "GET /i HTTP/1.1\r\nHost: h\r\n\r\n");
    HttpSrvT::HttpEvent ei = popRequest();
    CHECK(h1Respond(ei, 200, "i"));
    (void)readUntil(idle, "\r\n\r\ni");
    int busy = connectTo(a.port);
    sendAll(busy, "GET /b HTTP/1.1\r\nHost: h\r\n\r\n");
    HttpSrvT::HttpEvent eb = popRequest();
    int64_t open = -1;
    onReactor([&] {
        a.l->close();
        HttpSrvT::http1ServerClosing(a.rs, R().nowMs() + 2000);
        open = static_cast<int64_t>(a.rs->conns.size());
    });
    CHECK(open == 2);   // both still open: the idle one drains (FIN sent) until our EOF
    CHECK(readToEof(idle).empty());
    ::close(idle);
    CHECK(connectTo(a.port) < 0);   // refused: the listener is closed
    CHECK(h1Respond(eb, 200, "b"));
    std::string rb = readToEof(busy);
    CHECK(contains(rb, "Connection: close\r\n\r\nb"));
    ::close(busy);
    // The deadline aborts what is still in flight.
    H1Server d = startH1([](HttpSrvT::ServerConfig&) {});
    c = connectTo(d.port);
    sendAll(c, "GET /slow HTTP/1.1\r\nHost: h\r\n\r\n");
    HttpSrvT::HttpEvent es = popRequest();
    onReactor([&] {
        d.l->close();
        HttpSrvT::http1ServerClosing(d.rs, R().nowMs() + 100);
    });
    auto gone = popHttp(1);
    CHECK(gone.size() == 1 && gone[0].kind == HttpSrvT::HttpEvent::Kind::ConnGone &&
          gone[0].key == es.key);
    CHECK(readToEof(c).empty());
    ::close(c);
    onReactor([&] { b.l->close(); });
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


// ---------------------------------------------------------------------------
// HTTP/2 (plans/eco-system-websockets.md §3.8, WS8): Http2Protocol behind a
// plain callback-mode listener (the ALPN dispatch is covered end to end by
// the HttpServerHttp2* tests), driven by an nghttp2 client session over a
// blocking socket. Events are popped and answered as for Http1 above.
// ---------------------------------------------------------------------------

struct H2Resp {
    std::string status, body;
    bool closed = false;
    uint32_t code = 0;
};

struct H2Client {
    int fd = -1;
    nghttp2_session* s = nullptr;
    std::map<int32_t, H2Resp> resp;
    int64_t goaway = -1;
    bool eof = false;

    static H2Client* self(void* ud) { return static_cast<H2Client*>(ud); }
    static int onHeader(nghttp2_session*, const nghttp2_frame* f, const uint8_t* n, size_t nl,
                        const uint8_t* v, size_t vl, uint8_t, void* ud) {
        if (std::string(reinterpret_cast<const char*>(n), nl) == ":status")
            self(ud)->resp[f->hd.stream_id].status.assign(reinterpret_cast<const char*>(v), vl);
        return 0;
    }
    static int onData(nghttp2_session*, uint8_t, int32_t sid, const uint8_t* d, size_t l, void* ud) {
        self(ud)->resp[sid].body.append(reinterpret_cast<const char*>(d), l);
        return 0;
    }
    static int onClose(nghttp2_session*, int32_t sid, uint32_t code, void* ud) {
        auto& r = self(ud)->resp[sid];
        r.closed = true;
        r.code = code;
        return 0;
    }
    static int onFrame(nghttp2_session*, const nghttp2_frame* f, void* ud) {
        if (f->hd.type == NGHTTP2_GOAWAY) self(ud)->goaway = f->goaway.error_code;
        return 0;
    }

    explicit H2Client(int port) {
        fd = connectTo(port);
        nghttp2_session_callbacks* cbs = nullptr;
        nghttp2_session_callbacks_new(&cbs);
        nghttp2_session_callbacks_set_on_header_callback(cbs, &onHeader);
        nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, &onData);
        nghttp2_session_callbacks_set_on_stream_close_callback(cbs, &onClose);
        nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, &onFrame);
        nghttp2_session_client_new(&s, cbs, this);
        nghttp2_session_callbacks_del(cbs);
        nghttp2_submit_settings(s, NGHTTP2_FLAG_NONE, nullptr, 0);
    }
    ~H2Client() {
        if (s) nghttp2_session_del(s);
        if (fd >= 0) ::close(fd);
    }
    int32_t request(const std::vector<std::pair<std::string, std::string>>& h, bool end = true) {
        std::vector<nghttp2_nv> nva;
        for (const auto& kv : h) {
            nva.push_back({reinterpret_cast<uint8_t*>(const_cast<char*>(kv.first.data())),
                           reinterpret_cast<uint8_t*>(const_cast<char*>(kv.second.data())),
                           kv.first.size(), kv.second.size(), NGHTTP2_NV_FLAG_NONE});
        }
        int32_t id = nghttp2_submit_headers(s, end ? NGHTTP2_FLAG_END_STREAM : NGHTTP2_FLAG_NONE, -1,
                                            nullptr, nva.data(), nva.size(), nullptr);
        pump(0);
        return id;
    }
    // Sends what is queued, then reads for up to `ms` until `pred` holds.
    template <typename P>
    bool pumpUntil(int ms, P pred) {
        auto deadline = Clock::now() + std::chrono::milliseconds(ms);
        for (;;) {
            const uint8_t* d = nullptr;
            nghttp2_ssize n;
            while ((n = nghttp2_session_mem_send2(s, &d)) > 0)
                sendAll(fd, std::string(reinterpret_cast<const char*>(d), static_cast<size_t>(n)));
            if (pred()) return true;
            if (eof || Clock::now() >= deadline) return pred();
            struct pollfd p{fd, POLLIN, 0};
            if (::poll(&p, 1, 10) <= 0) continue;
            char buf[16384];
            ssize_t r = ::recv(fd, buf, sizeof(buf), 0);
            if (r <= 0) {
                eof = true;
                continue;
            }
            nghttp2_session_mem_recv2(s, reinterpret_cast<const uint8_t*>(buf), static_cast<size_t>(r));
        }
    }
    void pump(int ms) {
        pumpUntil(ms, [] { return false; });
    }
};

std::vector<std::pair<std::string, std::string>> h2Get(const std::string& path) {
    return {{":method", "GET"}, {":scheme", "https"}, {":authority", "h.test"}, {":path", path}};
}

H1Server startH2(const std::function<void(HttpSrvT::ServerConfig&)>& tweak) {
    H1Server s;
    HttpSrvT::ListenResult lr = HttpSrvT::listenOn("127.0.0.1", 0);
    CHECK(lr.fd >= 0);
    if (lr.fd < 0) return s;
    auto cfg = std::make_shared<HttpSrvT::ServerConfig>();
    cfg->serverId = 98;
    cfg->gen = 7;
    cfg->http2 = true;
    cfg->fallbackAuthority = "127.0.0.1:" + std::to_string(lr.boundPort);
    tweak(*cfg);
    s.rs = std::make_shared<HttpSrvT::ServerReactorState>();
    s.rs->cfg = cfg;
    s.l = std::make_shared<ListenerHandler>(lr.fd, 98, 7, false, std::string(), false, nullptr);
    auto rs = s.rs;
    s.l->setCallbackMode([rs](Conn& c) { return HttpSrvT::makeHttp2Protocol(c, rs); }, -1);
    auto l = s.l;
    onReactor([l] { l->start(); });
    s.port = static_cast<int>(lr.boundPort);
    return s;
}

void testHttp2Protocol() {
    std::printf("Http2: settings, mapping, toH2Nv, own answers, reset keys, cap, GOAWAY, ConnGone\n");
    H1Server a = startH2([](HttpSrvT::ServerConfig& c) {
        c.maxHeaderSize = 4096;
        c.maxBodySize = 100;
    });
    {
        H2Client cl(a.port);
        auto h = h2Get("/a?q=1");
        h.push_back({"cookie", "a=1"});
        h.push_back({"x-test", "yes"});
        h.push_back({"cookie", "b=2"});
        h.push_back({"host", "H.test"});
        int32_t id = cl.request(h);
        cl.pump(100);
        CHECK(nghttp2_session_get_remote_settings(cl.s, NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL) == 1);
        CHECK(nghttp2_session_get_remote_settings(cl.s, NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE) == 4096);
        CHECK(nghttp2_session_get_remote_settings(cl.s, NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS) ==
              0xffffffffu);   // not sent (W19): the default, unlimited
        HttpSrvT::HttpEvent ev = popRequest();
        CHECK(ev.req.method == "GET");
        CHECK(ev.req.url == "https://h.test/a?q=1");
        CHECK(ev.req.target == "/a?q=1");
        CHECK(ev.req.flags == 2);
        CHECK(ev.req.upgrade.empty());
        CHECK(ev.req.headers.size() == 3);
        if (ev.req.headers.size() == 3) {
            CHECK(ev.req.headers[0].first == "cookie" && ev.req.headers[0].second == "a=1; b=2");
            CHECK(ev.req.headers[1].first == "x-test");
            CHECK(ev.req.headers[2].first == "host");
        }
        auto doneErr = std::make_shared<std::atomic<int>>(-1);
        CHECK(h1Respond(ev, 200, "hi", {{"X-Reply", "1"}, {"Connection", "close"}, {"TE", "gzip"}},
                        doneErr));
        CHECK(cl.pumpUntil(2000, [&] { return cl.resp[id].closed; }));
        CHECK(cl.resp[id].status == "200" && cl.resp[id].body == "hi" && cl.resp[id].code == 0);
        CHECK(waitUntil([&] { return doneErr->load() == 0; }));
        CHECK(!h1Respond(ev, 200, "again"));   // answered: unknown key

        // A user 1xx → 500; HEAD: no DATA; Host ≠ :authority → 400; unknown
        // :protocol → 501; a body over maxBodySize → 413.
        int32_t one = cl.request(h2Get("/one"));
        HttpSrvT::HttpEvent e1 = popRequest();
        CHECK(h1Respond(e1, 103, ""));
        auto head = h2Get("/head");
        head[0].second = "HEAD";
        int32_t hid = cl.request(head);
        HttpSrvT::HttpEvent eh = popRequest();
        CHECK(eh.req.isHead);
        CHECK(h1Respond(eh, 200, "abc"));
        auto bad = h2Get("/bad");
        bad.push_back({"host", "other.test"});
        int32_t bid = cl.request(bad);
        int32_t pid = cl.request({{":method", "CONNECT"}, {":protocol", "chat"}, {":scheme", "https"},
                                  {":authority", "h.test"}, {":path", "/chat"}}, false);
        auto big = h2Get("/big");
        big.push_back({"content-length", "1000"});
        int32_t gid = cl.request(big, false);
        CHECK(cl.pumpUntil(2000, [&] {
            return cl.resp[one].closed && cl.resp[hid].closed && cl.resp[bid].closed &&
                   cl.resp[pid].closed && cl.resp[gid].closed;
        }));
        CHECK(cl.resp[one].status == "500");
        CHECK(cl.resp[hid].status == "200" && cl.resp[hid].body.empty());
        CHECK(cl.resp[bid].status == "400");
        CHECK(cl.resp[pid].status == "501" && cl.resp[pid].code == NGHTTP2_NO_ERROR);
        CHECK(cl.resp[gid].status == "413");
        CHECK(popHttp(1, 100).empty());

        // Extended CONNECT websocket: delivered on HEADERS with the token; a
        // plain answer then RST_STREAM(NO_ERROR) (the request side is open).
        int32_t wid = cl.request({{":method", "CONNECT"}, {":protocol", "websocket"}, {":scheme", "https"},
                                  {":authority", "h.test"}, {":path", "/ws"},
                                  {"sec-websocket-version", "13"}}, false);
        HttpSrvT::HttpEvent ew = popRequest();
        CHECK(ew.req.method == "CONNECT" && ew.req.upgrade == "websocket" && ew.req.url == "https://h.test/ws");
        CHECK(h1Respond(ew, 404, "no"));
        CHECK(cl.pumpUntil(2000, [&] { return cl.resp[wid].closed; }));
        CHECK(cl.resp[wid].status == "404" && cl.resp[wid].body == "no");

        // A reset stream's key: respond reports it gone.
        int32_t rid = cl.request(h2Get("/r"));
        HttpSrvT::HttpEvent er = popRequest();
        nghttp2_submit_rst_stream(cl.s, NGHTTP2_FLAG_NONE, rid, NGHTTP2_CANCEL);
        cl.pump(100);
        CHECK(!h1Respond(er, 200, "late"));

        // closeServer: GOAWAY(NO_ERROR); the request in flight is still answered.
        int32_t fid = cl.request(h2Get("/f"));
        HttpSrvT::HttpEvent ef = popRequest();
        onReactor([&] { HttpSrvT::http1ServerClosing(a.rs, R().nowMs() + 2000); });
        CHECK(cl.pumpUntil(2000, [&] { return cl.goaway >= 0; }));
        CHECK(cl.goaway == NGHTTP2_NO_ERROR);
        CHECK(h1Respond(ef, 200, "fin"));
        CHECK(cl.pumpUntil(2000, [&] { return cl.resp[fid].closed && cl.eof; }));
        CHECK(cl.resp[fid].body == "fin");
    }
    onReactor([&] { a.l->close(); });

    // maxConcurrentStreams = 2: advertised; a third request waits until one
    // of the first two is answered; a client gone → ConnGone for every key.
    H1Server b = startH2([](HttpSrvT::ServerConfig& c) { c.maxConcurrentStreams = 2; });
    {
        H2Client cl(b.port);
        cl.pump(100);
        CHECK(nghttp2_session_get_remote_settings(cl.s, NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS) == 2);
        cl.request(h2Get("/1"));
        cl.request(h2Get("/2"));
        int32_t third = cl.request(h2Get("/3"));
        cl.pump(100);
        auto evs = popHttp(2);
        CHECK(evs.size() == 2);
        CHECK(popHttp(1, 200).empty());   // held at the cap
        if (evs.size() == 2) CHECK(h1Respond(evs[0], 200, "1"));
        cl.pump(100);
        HttpSrvT::HttpEvent e3 = popRequest();
        CHECK(e3.req.url == "https://h.test/3");
        CHECK(!cl.resp[third].closed);
        struct linger lg{1, 0};   // RST: the connection is gone (a FIN alone is a half-close)
        ::setsockopt(cl.fd, SOL_SOCKET, SO_LINGER, &lg, sizeof(lg));
        ::close(cl.fd);
        cl.fd = -1;
        auto gone = popHttp(2);
        CHECK(gone.size() == 2);
        std::set<int64_t> keys;
        for (auto& g : gone) {
            CHECK(g.kind == HttpSrvT::HttpEvent::Kind::ConnGone);
            keys.insert(g.key);
        }
        CHECK(evs.size() == 2 && keys.count(evs[1].key) == 1 && keys.count(e3.key) == 1);
    }
    onReactor([&] { b.l->close(); });
}

} // namespace



// ---------------------------------------------------------------------------
// WebSocket frame codec and HTTP heads (plans/eco-system-websockets.md §3.6,
// Appendix D.1, D.4, D.5, WS4)
// ---------------------------------------------------------------------------

struct WsSinkLog : ws::WsDecoder::Sink {
    std::vector<std::pair<int, std::string>> events;   // opcode, payload
    void onMessage(uint8_t op, std::string&& p) override { events.emplace_back(op, std::move(p)); }
    void onControl(uint8_t op, std::string&& p) override { events.emplace_back(op, std::move(p)); }
};

std::string bytesOf(std::initializer_list<int> xs) {
    std::string s;
    for (int x : xs) s.push_back(static_cast<char>(x));
    return s;
}

const unsigned char kMask[4] = {0x37, 0xfa, 0x21, 0x3d};

// Feeds `in` to a decoder one byte at a time; returns the decoder's failure code.
int feedBytewise(ws::WsDecoder& d, const std::string& in, WsSinkLog& log) {
    for (char c : in) {
        if (d.failed()) break;
        d.feed(&c, 1, log);
    }
    return d.failCode();
}

int decodeFails(bool server, uint64_t max, const std::string& in) {
    ws::WsDecoder d(server, max);
    WsSinkLog log;
    d.feed(in.data(), in.size(), log);
    return d.failCode();
}

void testWsFrameCodec() {
    std::printf("testWsFrameCodec\n");
    // RFC 6455 §5.7 examples.
    std::string hello = "Hello";
    CHECK(ws::encodeFrame(true, ws::kOpText, hello.data(), hello.size(), nullptr) ==
          bytesOf({0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f}));
    std::string masked = ws::encodeFrame(true, ws::kOpText, hello.data(), hello.size(), kMask);
    CHECK(masked == bytesOf({0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58}));
    CHECK(ws::frameHeader(true, ws::kOpBinary, false, 256, nullptr) == bytesOf({0x82, 0x7E, 0x01, 0x00}));
    CHECK(ws::frameHeader(true, ws::kOpBinary, false, 65536, nullptr) ==
          bytesOf({0x82, 0x7F, 0, 0, 0, 0, 0, 1, 0, 0}));
    CHECK(ws::frameHeader(true, ws::kOpBinary, false, 125, nullptr).size() == 2);
    CHECK(ws::frameHeader(true, ws::kOpBinary, false, 65535, nullptr).size() == 4);

    {   // A masked frame byte by byte (server side), and an unmasked one (client side).
        ws::WsDecoder d(true, 1 << 20);
        WsSinkLog log;
        CHECK(feedBytewise(d, masked, log) == 0);
        CHECK(log.events.size() == 1 && log.events[0].first == ws::kOpText && log.events[0].second == "Hello");
        ws::WsDecoder c(false, 1 << 20);
        WsSinkLog log2;
        std::string plain = bytesOf({0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f});
        c.feed(plain.data(), plain.size(), log2);
        CHECK(log2.events.size() == 1 && log2.events[0].second == "Hello");
    }
    {   // Fragments with a ping between them: the ping first, then one message.
        std::string in = ws::encodeFrame(false, ws::kOpText, "Hel", 3, kMask) +
                         ws::encodeFrame(true, ws::kOpPing, "pp", 2, kMask) +
                         ws::encodeFrame(true, ws::kOpContinuation, "lo", 2, kMask);
        ws::WsDecoder d(true, 1 << 20);
        WsSinkLog log;
        CHECK(feedBytewise(d, in, log) == 0);
        CHECK(log.events.size() == 2);
        if (log.events.size() == 2) {
            CHECK(log.events[0].first == ws::kOpPing && log.events[0].second == "pp");
            CHECK(log.events[1].first == ws::kOpText && log.events[1].second == "Hello");
        }
    }
    {   // A 64 KiB binary message (64-bit length) arrives whole.
        std::string big(70000, '\x07');
        std::string in = ws::encodeFrame(true, ws::kOpBinary, big.data(), big.size(), kMask);
        ws::WsDecoder d(true, 1 << 20);
        WsSinkLog log;
        d.feed(in.data(), in.size(), log);
        CHECK(log.events.size() == 1 && log.events[0].second == big);
    }
    // D.1 errors (1002), D.4 size (1009) and UTF-8 (1007).
    CHECK(decodeFails(true, 100, ws::encodeFrame(true, ws::kOpText, "x", 1, nullptr)) == 1002);   // unmasked
    CHECK(decodeFails(false, 100, ws::encodeFrame(true, ws::kOpText, "x", 1, kMask)) == 1002);    // masked to a client
    CHECK(decodeFails(true, 100, bytesOf({0xC1, 0x80, 1, 2, 3, 4})) == 1002);                     // RSV1
    CHECK(decodeFails(true, 100, bytesOf({0xA1, 0x80, 1, 2, 3, 4})) == 1002);                     // RSV2
    CHECK(decodeFails(true, 100, bytesOf({0x83, 0x80, 1, 2, 3, 4})) == 1002);                     // opcode 3
    CHECK(decodeFails(true, 100, bytesOf({0x8B, 0x80, 1, 2, 3, 4})) == 1002);                     // opcode 11
    CHECK(decodeFails(true, 1000, bytesOf({0x89, 0xFE, 0, 126, 1, 2, 3, 4})) == 1002);            // ping > 125
    CHECK(decodeFails(true, 100, bytesOf({0x09, 0x80, 1, 2, 3, 4})) == 1002);                     // fragmented ping
    CHECK(decodeFails(true, 100, bytesOf({0x82, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 1, 1, 2, 3, 4})) == 1002);   // MSB
    CHECK(decodeFails(true, 100, bytesOf({0x80, 0x80, 1, 2, 3, 4})) == 1002);                     // lone continuation
    CHECK(decodeFails(true, 100, ws::encodeFrame(false, ws::kOpText, "a", 1, kMask) +
                                     ws::encodeFrame(true, ws::kOpText, "b", 1, kMask)) == 1002);
    CHECK(decodeFails(true, 10, ws::encodeFrame(true, ws::kOpBinary, "0123456789x", 11, kMask)) == 1009);
    CHECK(decodeFails(true, 10, ws::encodeFrame(false, ws::kOpBinary, "012345", 6, kMask) +
                                    ws::encodeFrame(true, ws::kOpContinuation, "6789x", 5, kMask)) == 1009);
    CHECK(decodeFails(true, 10, ws::encodeFrame(true, ws::kOpBinary, "0123456789", 10, kMask)) == 0);
    {   // Fail fast: an invalid byte in an unfinished frame of an unfinished message.
        std::string frame = ws::encodeFrame(false, ws::kOpText, "a\xff" "bcdef", 7, kMask);
        frame.resize(frame.size() - 3);   // the frame has not fully arrived
        CHECK(decodeFails(true, 100, frame) == 1007);
    }
    CHECK(decodeFails(true, 100, ws::encodeFrame(true, ws::kOpText, "a\xe2\x82", 3, kMask)) == 1007);   // cut at the end
    {   // A character split across fragments is fine.
        std::string in = ws::encodeFrame(false, ws::kOpText, "\xf0\x9d", 2, kMask) +
                         ws::encodeFrame(true, ws::kOpContinuation, "\x84\x9e", 2, kMask);
        ws::WsDecoder d(true, 100);
        WsSinkLog log;
        d.feed(in.data(), in.size(), log);
        CHECK(!d.failed() && log.events.size() == 1 && log.events[0].second == "\xf0\x9d\x84\x9e");
    }
    {   // Discarding: data skipped (even invalid UTF-8), control frames still delivered.
        ws::WsDecoder d(true, 4);
        d.setDiscardData(true);
        WsSinkLog log;
        std::string in = ws::encodeFrame(true, ws::kOpText, "\xff\xff\xff\xff\xff\xff", 6, kMask) +
                         ws::encodeFrame(true, ws::kOpPong, "z", 1, kMask);
        d.feed(in.data(), in.size(), log);
        CHECK(!d.failed() && log.events.size() == 1 && log.events[0].first == ws::kOpPong);
    }

    // UTF-8 validator (strict).
    CHECK(ws::validUtf8("plain ascii"));
    CHECK(ws::validUtf8("\xc3\xa9\xe2\x9c\x93\xf0\x9d\x84\x9e"));
    CHECK(!ws::validUtf8("\xc0\x80"));           // overlong
    CHECK(!ws::validUtf8("\xe0\x80\x80"));       // overlong
    CHECK(!ws::validUtf8("\xed\xa0\x80"));       // surrogate
    CHECK(!ws::validUtf8("\xf4\x90\x80\x80"));   // above U+10FFFF
    CHECK(!ws::validUtf8("\xf5\x80\x80\x80"));
    CHECK(!ws::validUtf8("\xe2\x82"));           // truncated
    CHECK(ws::truncateUtf8("ab\xc3\xa9", 3) == "ab");
    CHECK(ws::truncateUtf8("ab\xc3\xa9", 4) == "ab\xc3\xa9");

    // Close payloads (D.5).
    int code = 0, failCode = 0;
    std::string reason, failText;
    CHECK(ws::parseClose("", code, reason, failCode, failText) && code == 1005);
    CHECK(!ws::parseClose(bytesOf({3}), code, reason, failCode, failText) && failCode == 1002);
    CHECK(!ws::parseClose(bytesOf({0x03, 0xEC}), code, reason, failCode, failText) && failCode == 1002);   // 1004
    CHECK(!ws::parseClose(bytesOf({0x03, 0xED}), code, reason, failCode, failText));                         // 1005
    CHECK(!ws::parseClose(bytesOf({0x03, 0xEE}), code, reason, failCode, failText));                         // 1006
    CHECK(!ws::parseClose(bytesOf({0x03, 0xF7}), code, reason, failCode, failText));                         // 1015
    CHECK(ws::parseClose(bytesOf({0x0B, 0xB8}), code, reason, failCode, failText) && code == 3000);
    CHECK(!ws::parseClose(bytesOf({0x03, 0xE8, 0xff}), code, reason, failCode, failText) && failCode == 1007);
    CHECK(ws::parseClose(bytesOf({0x03, 0xE8, 'o', 'k'}), code, reason, failCode, failText) && reason == "ok");
    CHECK(ws::closePayload(1000, std::string(200, 'x')).size() == 125);
    CHECK(ws::closeCodeSendable(4999) && !ws::closeCodeSendable(5000) && !ws::closeCodeSendable(999));
}

// --- WS6 / WS7: raw data mode, permessage-deflate engine (RFC 7692 §7.2.3) ---------

struct WsRawLog : ws::WsDecoder::Sink {
    std::vector<std::string> events;   // "start <op> <c>", "data <bytes>", "end", "ctl <op>"
    std::string data;
    void onMessage(uint8_t op, std::string&&) override { events.push_back("whole " + std::to_string(op)); }
    void onControl(uint8_t op, std::string&&) override { events.push_back("ctl " + std::to_string(op)); }
    void onDataStart(uint8_t op, bool c) override {
        events.push_back("start " + std::to_string(op) + (c ? " z" : ""));
    }
    void onDataChunk(const char* p, size_t n) override { data.append(p, n); }
    void onDataEnd() override { events.push_back("end " + data); data.clear(); }
};

int rawDecodeFails(bool allowRsv1, uint64_t max, const std::string& in) {
    ws::WsDecoder d(true, max);
    d.setRawData(true);
    d.setAllowRsv1(allowRsv1);
    WsRawLog log;
    d.feed(in.data(), in.size(), log);
    return d.failCode();
}

// Inflates one message payload (all of it, in steps); "" + failed on an error.
std::string inflateAll(ws::Inflater& inf, const std::string& payload, bool& ok, size_t step = 0) {
    std::string out;
    ok = true;
    inf.push(payload.data(), payload.size());
    inf.finish();
    for (;;) {
        size_t before = out.size();
        ws::Inflater::Step st = inf.step(out, step);
        if (step > 0) CHECK(out.size() - before <= step);
        if (st == ws::Inflater::Step::Output) continue;
        if (st == ws::Inflater::Step::Done) return out;
        ok = false;
        return out;
    }
}

void testWsDeflate() {
    std::printf("testWsDeflate\n");
    const std::string hello = "Hello";
    const std::string helloZ = bytesOf({0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00});
    {   // §7.2.3.1 / §7.2.3.2: "Hello" twice without and with context takeover.
        ws::Deflater noCtx(15, true);
        std::string a, b;
        CHECK(noCtx.message(hello.data(), hello.size(), a) && a == helloZ);
        CHECK(noCtx.message(hello.data(), hello.size(), b) && b == helloZ);
        ws::Deflater ctx(15, false);
        std::string c, d;
        CHECK(ctx.message(hello.data(), hello.size(), c) && c == helloZ);
        CHECK(ctx.message(hello.data(), hello.size(), d) && d == bytesOf({0xf2, 0x00, 0x11, 0x00, 0x00}));
        // The receiving side: a shared window decodes the second one.
        ws::Inflater inf(false);
        bool ok = false;
        CHECK(inflateAll(inf, c, ok) == hello && ok);
        CHECK(inflateAll(inf, d, ok) == hello && ok);
        ws::Inflater fresh(true);
        CHECK(inflateAll(fresh, a, ok) == hello && ok);
        CHECK(inflateAll(fresh, b, ok) == hello && ok);
    }
    {   // An empty message is the single octet 00 (§7.2.3.6), both ways.
        ws::Deflater dz(15, true);
        std::string e;
        CHECK(dz.message("", 0, e) && e == bytesOf({0x00}));
        ws::Inflater inf(true);
        bool ok = false;
        CHECK(inflateAll(inf, e, ok).empty() && ok);
    }
    {   // §7.2.3.3 a stored block, §7.2.3.4 BFINAL, §7.2.3.5 two blocks.
        ws::Inflater inf(false);
        bool ok = false;
        CHECK(inflateAll(inf, bytesOf({0x00, 0x05, 0x00, 0xfa, 0xff, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00}), ok) ==
                  hello && ok);
        CHECK(inflateAll(inf, bytesOf({0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x00}), ok) == hello && ok);
        // After the final block the window is kept: a back-reference into it works.
        CHECK(inflateAll(inf, bytesOf({0xf2, 0x00, 0x11, 0x00, 0x00}), ok) == hello && ok);
        CHECK(inflateAll(inf, bytesOf({0xf2, 0x48, 0x05, 0x00, 0x00, 0x00, 0xff, 0xff, 0xca, 0xc9, 0xc9, 0x07,
                                       0x00}),
                         ok) == hello &&
              ok);
    }
    {   // §7.2.3.1 fragmented compressed message through the decoder (raw mode,
        // RSV1 on the first frame only), then inflated.
        std::string in = bytesOf({0x41, 0x03, 0xf2, 0x48, 0xcd}) + bytesOf({0x80, 0x04, 0xc9, 0xc9, 0x07, 0x00});
        ws::WsDecoder d(false, 1 << 20);
        d.setRawData(true);
        d.setAllowRsv1(true);
        WsRawLog log;
        d.feed(in.data(), in.size(), log);
        CHECK(!d.failed() && log.events.size() == 2);
        if (log.events.size() == 2) {
            CHECK(log.events[0] == "start 1 z");
            CHECK(log.events[1] == "end " + helloZ);
        }
    }
    {   // Window bits 8 deflate with 9; the peer (window 15 inflate) decodes it.
        std::string text;
        for (int i = 0; i < 2000; ++i) text += "message " + std::to_string(i % 37) + " ";
        ws::Deflater d8(8, false);
        std::string z1, z2;
        CHECK(d8.message(text.data(), text.size(), z1) && z1.size() < text.size() / 3);
        CHECK(d8.message(text.data(), text.size(), z2) && z2.size() < z1.size());
        ws::Inflater inf(false);
        bool ok = false;
        CHECK(inflateAll(inf, z1, ok) == text && ok);
        CHECK(inflateAll(inf, z2, ok) == text && ok);
    }
    {   // A streamed message: chunks with sync flushes, an empty FIN fragment.
        std::mt19937 rng(7);
        std::string all;
        ws::Deflater dz(15, true);
        std::string wire;
        for (int i = 0; i < 20; ++i) {
            std::string chunk(1000 + (rng() % 5000), '\0');
            for (char& c : chunk) c = static_cast<char>('a' + rng() % 6);
            all += chunk;
            CHECK(dz.chunk(chunk.data(), chunk.size(), wire));
        }
        dz.endMessage();
        ws::Inflater inf(true);
        bool ok = false;
        CHECK(inflateAll(inf, wire, ok, 4096) == all && ok);
    }
    {   // A streamed message under context takeover: sync-flushed chunks and the
        // final fragment 0x00 (§7.2.3.6), then a whole message that refers back
        // into it: the shared window stays usable.
        ws::Deflater dz(15, false);
        std::string wire;
        std::string a = "streamed chunk one, ", b = "streamed chunk two";
        CHECK(dz.chunk(a.data(), a.size(), wire) && dz.chunk(b.data(), b.size(), wire));
        wire.push_back('\0');
        dz.endMessage();
        std::string next;
        std::string again = "streamed chunk one, streamed chunk two";
        CHECK(dz.message(again.data(), again.size(), next) && next.size() < again.size() / 2);
        ws::Inflater inf(false);
        bool ok = false;
        CHECK(inflateAll(inf, wire, ok) == a + b && ok);
        CHECK(inflateAll(inf, next, ok) == again && ok);
    }
    {   // Bounded inflate: 64 MiB of zeros (a ~64 KiB payload) comes out in
        // steps of at most the step size; the caller can stop early.
        std::string zeros(64 * 1024 * 1024, '\0');
        ws::Deflater dz(15, true);
        std::string bomb;
        CHECK(dz.message(zeros.data(), zeros.size(), bomb) && bomb.size() < 128 * 1024);
        std::string().swap(zeros);
        ws::Inflater inf(true);
        inf.push(bomb.data(), bomb.size());
        inf.finish();
        std::string out;
        size_t total = 0;
        int steps = 0;
        while (total < 16 * 1024 * 1024) {
            out.clear();
            ws::Inflater::Step st = inf.step(out, ws::kInflateStep);
            CHECK(st == ws::Inflater::Step::Output && out.size() <= ws::kInflateStep);
            if (st != ws::Inflater::Step::Output) break;
            total += out.size();
            ++steps;
        }
        CHECK(steps >= 256);
        inf.abandonMessage();
        bool ok = false;
        CHECK(inflateAll(inf, helloZ, ok) == hello && ok);   // usable after abandoning
    }
    {   // Invalid compressed data.
        ws::Inflater inf(true);
        bool ok = true;
        inflateAll(inf, bytesOf({0xff, 0xff, 0xff, 0xff}), ok);
        CHECK(!ok && !inf.error().empty());
    }
    // RSV1 rules in the decoder (D.1).
    CHECK(rawDecodeFails(true, 100, bytesOf({0xC1, 0x80, 1, 2, 3, 4})) == 0);       // first frame
    CHECK(rawDecodeFails(false, 100, bytesOf({0xC1, 0x80, 1, 2, 3, 4})) == 1002);   // not negotiated
    CHECK(rawDecodeFails(true, 100, bytesOf({0xC9, 0x80, 1, 2, 3, 4})) == 1002);    // on a ping
    CHECK(rawDecodeFails(true, 100, bytesOf({0x41, 0x80, 1, 2, 3, 4, 0xC0, 0x80, 1, 2, 3, 4})) == 1002);   // continuation
    // Size: uncompressed messages checked from the header, compressed ones not.
    CHECK(rawDecodeFails(true, 4, ws::encodeFrame(true, ws::kOpBinary, "12345", 5, kMask)) == 1009);
    CHECK(rawDecodeFails(true, 4, ws::encodeFrame(true, ws::kOpBinary, true, "12345", 5, kMask)) == 0);
    {   // Raw mode: fragments with a ping between them, delivered unmasked.
        std::string in = ws::encodeFrame(false, ws::kOpText, "Hel", 3, kMask) +
                         ws::encodeFrame(true, ws::kOpPing, "pp", 2, kMask) +
                         ws::encodeFrame(true, ws::kOpContinuation, "lo", 2, kMask) +
                         ws::encodeFrame(true, ws::kOpBinary, "", 0, kMask);
        ws::WsDecoder d(true, 100);
        d.setRawData(true);
        WsRawLog log;
        for (char c : in) d.feed(&c, 1, log);
        CHECK(!d.failed());
        CHECK(log.events.size() == 5);
        if (log.events.size() == 5) {
            CHECK(log.events[0] == "start 1");
            CHECK(log.events[1] == "ctl 9");
            CHECK(log.events[2] == "end Hello");
            CHECK(log.events[3] == "start 2");
            CHECK(log.events[4] == "end ");
        }
    }
    // Code-point boundaries (streamed text bodies).
    CHECK(ws::utf8CompletePrefix("abc", 3) == 3);
    CHECK(ws::utf8CompletePrefix("ab\xc3", 3) == 2);
    CHECK(ws::utf8CompletePrefix("ab\xc3\xa9", 4) == 4);
    CHECK(ws::utf8CompletePrefix("\xf0\x9d\x84", 3) == 0);
    CHECK(ws::utf8CompletePrefix("x\xf0\x9d\x84\x9e", 5) == 5);
    CHECK(ws::utf8CompletePrefix("x\xe2\x9c", 3) == 1);
    CHECK(ws::utf8CompletePrefix("", 0) == 0);
}

void testWsHttpHeads() {
    std::printf("testWsHttpHeads\n");
    CHECK(wsAcceptFor("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");   // RFC 6455 §1.3
    CHECK(wsNewKey().size() == 24);
    CHECK(httpHeadLength("GET / HTTP/1.1\r\nHost: x\r\n") == 0);
    CHECK(httpHeadLength("GET / HTTP/1.1\r\nHost: x\r\n\r\nrest") == 27);
    CHECK(httpHeadLength("GET / HTTP/1.1\nHost: x\n\nrest") == 24);

    HttpHead h;
    std::string err;
    CHECK(parseRequestHead("GET /chat?x=1 HTTP/1.1\r\nHost: a\r\nX-A:  1 \r\nx-a: 2\r\n\r\n", h, err));
    CHECK(h.method == "GET" && h.target == "/chat?x=1" && h.version == "1.1");
    CHECK(h.headers.size() == 3 && h.headers[1].first == "X-A" && h.headers[1].second == "1" &&
          h.headers[2].second == "2");
    HttpHead bad;
    CHECK(!parseRequestHead("GET / HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n", bad, err));
    CHECK(!parseRequestHead("GET / HTTP/1.1\r\nHost : a\r\n\r\n", bad, err));
    CHECK(!parseRequestHead("GET  / HTTP/1.1\r\n\r\n", bad, err));
    CHECK(!parseRequestHead("GET / HTTP/x\r\n\r\n", bad, err));
    CHECK(!parseRequestHead("hello\r\n\r\n", bad, err));
    HttpHead r;
    CHECK(parseResponseHead("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n", r, err));
    CHECK(r.status == 101 && r.headers.size() == 1);
    HttpHead r2;
    CHECK(parseResponseHead("HTTP/1.1 302\r\n\r\n", r2, err) && r2.status == 302);
    CHECK(!parseResponseHead("HTTP/1.1 3x2 Found\r\n\r\n", r2, err));

    std::string resp = serializeResponse(403, HeaderList{{"X-Why", "no"}, {"Bad\r\nName", "x"},
                                                         {"X-Inj", "a\r\nb"}, {"Content-Length", "9"}},
                                         true, "body");
    CHECK(resp == "HTTP/1.1 403 Forbidden\r\nX-Why: no\r\nContent-Length: 4\r\nConnection: close\r\n\r\nbody");
    CHECK(serializeRequest("/x", HeaderList{{"Host", "h"}}) == "GET /x HTTP/1.1\r\nHost: h\r\n\r\n");
}

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
    testSocketUtil();
    testReactorEcho();
    testReactorIdleNoBusyLoop();
    testReactorManyPairs();
    testReactorSubmitRacing();
    testReactorStaleGeneration();
    testReactorTimers();
    testReactorCloseAll();
    testMappedSource();
    testMappedReaderAttach();
    testMappedSink();
    testConnProtocolHandoff();
    testConnMultiTimer();
    testListenerCallbackMode();
    testHttp1KeepAlivePipeline();
    testHttp1Limits();
    testHttp1UpgradeConnectGone();
    testHttp1TimeoutsAndClose();
    testWsFrameCodec();
    testWsHttpHeads();
    testHttp2Protocol();
    testWsDeflate();
    testReactorQuiesce();   // last reactor test: irreversible

    std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
    std::printf(g_failures == 0 ? "ALL PASSED\n" : "FAILED\n");
    return g_failures == 0 ? 0 : 1;
}
