// Socket unit tests of eco-system-core-test (system-kernel-cpp/src/eco-system/Socket/): FaceProtocol, Conn
// and Socket.connect.
//
// DEAD-43  FaceProtocol::writeFaceShutdown's `if (closePending_)` branch is unreachable: a pending close-write is
//          always completed by `cancelWrites` (failOutbound -> finishShutdown -> closeDone) or synchronously by
//          `shutdownWrite`. No behaviour bug: this pins both reachable paths (the close completes exactly once,
//          ECANCELED / 0), so the fix's `assert(!closePending_)` can be checked against them. Passes today.
// SOCK-03  Conn::applyInterest reported a second "write <CODE>" onError when the reactor refused the fd after a write
//          error had already ended writing. Fixed: exactly one write error is reported.
// SOCK-12  socketStartConnect inserted the pending connect and submitted it before makeKillHandle; when makeKillHandle
//          threw, asyncFailure released the hold and resumed the task, and the connect's later completion released
//          the hold a second time (holdFatal in census builds). Fixed: the kill handle is made first. Runs in a child
//          scenario.

#include "EcoSystemCoreTest.hpp"

#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/Core/SocketUtil.hpp"
#include "eco-system/Socket/Conn.hpp"
#include "eco-system/Socket/FaceProtocol.hpp"
#include "eco-system/Socket/Socket.hpp"
#include "eco-system/Socket/SocketEvents.hpp"
#include "eco-system/Socket/SocketTables.hpp"

#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifndef _WIN32
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#endif

using namespace Eco::System;

namespace {

#ifdef __linux__

using Clock = std::chrono::steady_clock;

// --- helpers (copies of the EcoSystemCoreTest.cpp reactor helpers, which are file-local there) ---------------

IoReactor& R() { return IoReactor::instance(); }

// Runs fn on the reactor thread and waits for it (aborts after 10 s: fn captures this frame by reference).
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

void drainResults() {
    ChannelResult tmp;
    while (tryPopChannelResult(tmp)) {}
}

// Pops every channel result that arrives within `ms`.
std::vector<ChannelResult> collectResults(int ms) {
    std::vector<ChannelResult> out;
    auto deadline = Clock::now() + std::chrono::milliseconds(ms);
    while (Clock::now() < deadline) {
        ChannelResult r;
        if (tryPopChannelResult(r)) out.push_back(std::move(r));
        else std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return out;
}

// An open server Conn over `fd` (the plain transport when `t` is null).
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

// --- DEAD-43 --------------------------------------------------------------------------------------------------

// The close-write results for `channelId` among `res`.
std::vector<ChannelResult> closesOf(const std::vector<ChannelResult>& res, uint64_t channelId) {
    std::vector<ChannelResult> out;
    for (const auto& r : res) {
        if (r.channelId == channelId && r.op == ChannelResult::Op::Close) out.push_back(r);
    }
    return out;
}

void testFaceCloseWriteThenShutdown() {
    std::printf("socket/face-close-write-then-shutdown-completes-the-close-once\n");
    constexpr uint64_t kChanA = 0x1743a, kChanB = 0x1743b;

    // (a) Queued writes the peer does not read: the close-write is parked in the Conn (shutDone_), and
    // writeFaceShutdown's cancelWrites(ECANCELED) completes it through failOutbound -> finishShutdown.
    {
        int sv[2];
        CHECK(makePair(sv));
        auto c = openConn(sv[0], nullptr);
        drainResults();
        bool parked = false;
        onReactor([&] {
            CHECK(c->face() != nullptr);
            c->reqWrite(kChanA, 1, std::string(8u << 20, 'x'));   // far more than the socket buffer holds
            parked = c->outbound() > 0;
            c->reqCloseWrite(kChanA, 2);
        });
        CHECK_MSG(parked, "DEAD-43 (a): the write was not left queued; the close would not be parked");
        auto before = collectResults(50);
        CHECK_MSG(closesOf(before, kChanA).empty(), "DEAD-43 (a): the close completed before the shutdown");
        onReactor([&] { c->writeFaceShutdown(); });
        auto res = collectResults(200);
        res.insert(res.begin(), before.begin(), before.end());
        auto closes = closesOf(res, kChanA);
        CHECK_MSG(closes.size() == 1, "DEAD-43 (a): " + std::to_string(closes.size()) + " close results, want 1");
        if (closes.size() == 1) {
            CHECK_MSG(closes[0].err == ECANCELED && closes[0].token == 2,
                      "DEAD-43 (a): close err " + std::to_string(closes[0].err) + ", want ECANCELED");
        }
        onReactor([&] { c->abort(false); });
        ::close(sv[1]);
        CHECK(waitUntil([&] { return c->phase() == Conn::Phase::Closed; }));
        drainResults();
    }

    // (b) Empty queue: shutdownWrite runs the close callback synchronously (closeDone(0)); the later
    // writeFaceShutdown has nothing pending.
    {
        int sv[2];
        CHECK(makePair(sv));
        auto c = openConn(sv[0], nullptr);
        drainResults();
        onReactor([&] {
            c->reqCloseWrite(kChanB, 3);
            c->writeFaceShutdown();
        });
        auto res = collectResults(200);
        auto closes = closesOf(res, kChanB);
        CHECK_MSG(closes.size() == 1, "DEAD-43 (b): " + std::to_string(closes.size()) + " close results, want 1");
        if (closes.size() == 1) {
            CHECK_MSG(closes[0].err == 0 && closes[0].token == 3,
                      "DEAD-43 (b): close err " + std::to_string(closes[0].err) + ", want 0");
        }
        char b;
        CHECK_MSG(::recv(sv[1], &b, 1, 0) == 0, "DEAD-43 (b): the peer did not see the FIN");
        onReactor([&] { c->abort(false); });
        ::close(sv[1]);
        CHECK(waitUntil([&] { return c->phase() == Conn::Phase::Closed; }));
        drainResults();
    }
}

// --- SOCK-03 --------------------------------------------------------------------------------------------------

// A plain socket transport whose hasPendingWrite the test switches on: that gives the Conn write interest without
// any read or queued write, so applyInterest calls setInterest with nothing else happening first.
class PendingFlagTransport final : public Transport {
public:
    explicit PendingFlagTransport(int fd) : fd_(fd) {}
    ssize_t read(char* buf, size_t n) override {
        wantRead = wantWrite = false;
        ssize_t g = ::recv(fd_, buf, n, 0);
        if (g >= 0) return g;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            wantRead = true;
            return -1;
        }
        errNo = errno;
        errCode = errnoName(errno);
        return -2;
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
    bool hasPendingWrite() const override { return pending.load(); }
    int flush() override { return 1; }   // never drains: the flag stays on

    std::atomic<bool> pending{false};

private:
    int fd_;
};

// Logs every onError code; never wants to read.
class ErrorLogProtocol final : public ConnProtocol {
public:
    explicit ErrorLogProtocol(std::shared_ptr<std::vector<std::string>> log) : log_(std::move(log)) {}
    void onData(Conn&, std::string_view) override {}
    void onEof(Conn&) override { log_->push_back("eof"); }
    void onError(Conn&, int, const std::string& code) override { log_->push_back("error:" + code); }
    void onCloseAll(Conn&) override { log_->push_back("closeAll"); }
    bool wantsRead() const override { return false; }

private:
    std::shared_ptr<std::vector<std::string>> log_;
};

void testConnSetInterestFailureAfterWriteError() {
    std::printf("socket/refused-set-interest-after-a-write-error-reports-no-second-error\n");
    int sv[2];
    CHECK(makePair(sv));
    auto* tp = new PendingFlagTransport(sv[0]);
    auto c = openConn(sv[0], std::unique_ptr<Transport>(tp));
    auto log = std::make_shared<std::vector<std::string>>();   // touched on the reactor thread only
    std::atomic<bool> closed{false};
    onReactor([&] {
        c->addCloseHook([&closed](Conn&) { closed = true; });
        c->setProtocol(std::make_unique<ErrorLogProtocol>(log), std::string());
    });
    ::close(sv[1]);   // the peer is gone: the next send fails with EPIPE
    int writeErr = -1;
    onReactor([&] { c->write("x", [&writeErr](int e) { writeErr = e; }); });
    std::vector<std::string> afterWrite;
    onReactor([&] { afterWrite = *log; });
    CHECK_MSG(writeErr == EPIPE, "SOCK-03: the queued write got " + std::to_string(writeErr) + ", want EPIPE");
    CHECK_MSG(afterWrite.size() == 1 && afterWrite[0] == "error:write EPIPE",
              "SOCK-03 precondition: want exactly one 'write EPIPE' before the interest failure");

    // Replace the socket's description with a regular file: epoll drops the old one from its set and refuses the
    // new one (EPERM), so the next interest change fails inside applyInterest.
    char tmpl[] = "/tmp/eco-sock03-XXXXXX";
    int reg = ::mkstemp(tmpl);
    CHECK(reg >= 0);
    ::unlink(tmpl);
    onReactor([&] {
        CHECK(::dup2(reg, sv[0]) == sv[0]);
        tp->pending = true;   // write interest from the transport alone
        c->updateInterest();
    });
    ::close(reg);
    CHECK_MSG(waitUntil([&] { return closed.load(); }), "SOCK-03 precondition: the Conn did not close");
    std::vector<std::string> ev;
    onReactor([&] { ev = *log; });
    int writeErrors = 0;
    bool sawCtlError = false;
    std::string all;
    for (const auto& e : ev) {
        all += e + "; ";
        if (e.rfind("error:write", 0) == 0) ++writeErrors;
        if (e.rfind("error:read", 0) == 0) sawCtlError = true;
    }
    CHECK_MSG(sawCtlError, "SOCK-03 precondition: setInterest did not fail (no read error): " + all);
    CHECK_MSG(writeErrors == 1, "SOCK-03: " + std::to_string(writeErrors) + " write errors reported, want 1: " + all);
}

// --- SOCK-12 --------------------------------------------------------------------------------------------------

std::vector<std::string> g_sock12Resumed;

// The connect Task's resume closure: records whether it succeeded or failed.
void* sock12ResumeEval(void* args[]) {
    HPointer task = dec(args[0]);
    auto* t = static_cast<Elm::Task*>(Allocator::instance().resolve(task));
    g_sock12Resumed.push_back(t->ctor == Elm::alloc::Task_Succeed ? "ok" : "fail");
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

// Child: connect to a listening Unix socket with the next makeKillHandle armed to throw; the connect itself
// succeeds on the reactor. Correct: the task fails once, the connect is not left pending, the hold count is back at
// its baseline and the later completion does nothing. Before the fix the completion released the hold a second time.
int scenarioConnectKillHandleThrow() {
#if ECO_TEST_HOOKS
    initCoreRuntime();
    std::string path = "/tmp/eco-sock12-" + std::to_string(::getpid()) + ".sock";
    ::unlink(path.c_str());
    int lfd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un sa;
    std::memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    std::strncpy(sa.sun_path, path.c_str(), sizeof(sa.sun_path) - 1);
    CHECK(lfd >= 0 && ::bind(lfd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) == 0 && ::listen(lfd, 4) == 0);

    auto& sched = Scheduler::instance();
    size_t holdsBefore = sched.liveHoldCount();
    int asyncBefore = sched.pendingAsync();
    std::printf("SOCK-12 census=%d holds=%zu pendingAsync=%d\n", sched.holdCensusEnabled() ? 1 : 0, holdsBefore,
                asyncBefore);

    HPointer resume = alloc::allocClosureK(&sock12ResumeEval, 1, PK_Boxed);
    HPointer pathStr = alloc::allocStringFromUTF8(path);
    Elm::StackRootGuard g(&resume, &pathStr);
    killHandleFailNextForTest();
    (void)socketUnixConnectBody(pathStr, resume);
    std::printf("SOCK-12 after body: resumed=%zu (%s) pendingConnects=%zu holds=%zu pendingAsync=%d\n",
                g_sock12Resumed.size(), g_sock12Resumed.empty() ? "-" : g_sock12Resumed[0].c_str(),
                socketTables().pendingConnects.size(), sched.liveHoldCount(), sched.pendingAsync());
    std::fflush(stdout);
    CHECK_MSG(g_sock12Resumed.size() == 1 && g_sock12Resumed[0] == "fail",
              "SOCK-12 precondition: the hook did not make the connect Task fail at once");

    // Let the connect finish on the reactor and dispatch its Connected event on this (the eco) thread.
    int conns = -1;
    auto deadline = Clock::now() + std::chrono::milliseconds(3000);
    while (Clock::now() < deadline) {
        socketEventsDrain();
        if (socketTables().pendingConnects.empty()) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    for (int i = 0; i < 50; ++i) {   // a little longer: any late event is dispatched too
        socketEventsDrain();
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    conns = static_cast<int>(socketTables().pendingConnects.size());
    size_t holdsAfter = sched.liveHoldCount();
    int asyncAfter = sched.pendingAsync();
    std::printf("SOCK-12 end: resumed=%zu pendingConnects=%d holds=%zu pendingAsync=%d\n", g_sock12Resumed.size(),
                conns, holdsAfter, asyncAfter);
    std::fflush(stdout);
    CHECK_MSG(g_sock12Resumed.size() == 1, "SOCK-12: the task was resumed more than once");
    CHECK_MSG(conns == 0, "SOCK-12: a connect is still pending");
    CHECK_MSG(holdsAfter == holdsBefore, "SOCK-12: live holds " + std::to_string(holdsAfter) + ", want " +
                                             std::to_string(holdsBefore));
    CHECK_MSG(asyncAfter == asyncBefore, "SOCK-12: pendingAsync " + std::to_string(asyncAfter) + ", want " +
                                             std::to_string(asyncBefore));
    ::close(lfd);
    ::unlink(path.c_str());
    return CoreTest::g_failures == 0 ? 0 : 1;
#else
    std::printf("SOCK-12: no test hooks in this build\n");
    return 77;
#endif
}

void testConnectKillHandleThrow() {
    std::printf("socket/connect-kill-handle-throw-leaves-no-pending-connect-or-double-release\n");
#if ECO_TEST_HOOKS
    auto r = ChildScenario::runChildScenario("socket/connect-kill-handle-throw", {}, 30000);
    CHECK_MSG(r.started, "SOCK-12: the child did not start");
    CHECK_MSG(r.out.find("after body: resumed=1 (fail)") != std::string::npos,
              "SOCK-12 precondition: the hook did not fire in the child: " + r.out);
    CHECK_MSG(r.ok(), "SOCK-12: " + r.describe() + "; stdout: " + r.out + "; stderr: " + r.err);
#else
    std::printf("  skipped: no test hooks in this build\n");
#endif
}

#endif  // __linux__

}  // namespace

void runSocketTests() {
#ifdef __linux__
    testFaceCloseWriteThenShutdown();
    testConnSetInterestFailureAfterWriteError();
    testConnectKillHandleThrow();
#endif
}

void registerSocketScenarios() {
#ifdef __linux__
    ChildScenario::add("socket/connect-kill-handle-throw", scenarioConnectKillHandleThrow);
#endif
}
