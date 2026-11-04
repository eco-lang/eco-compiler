// eco/system tables across a heap reset, in eco-system-core-test. The kernel state of the `test`
// binary's kernels (Runtime saved state, Time / Http scanners, MVars) is covered by
// test/platform/HeapResetKernelStateTest.cpp.
//
// A heap reset (`Allocator::reset`, reachable only from tests through `AllocatorTestAccess::reset`) bumps
// `heapGeneration`. Every eco/system table that outlives the heap resets itself on the first use in a new
// generation. The holds the old tables owned are voided by the Scheduler's own reset (D21), and the OS resources
// their entries own must be released. Each scenario checks one table (the bugs these were, now fixed):
//
//   RESET-04  FileSystem: the open-handle table was never cleared, so an fd opened in the old heap stayed open
//             (leaked) and a `close` of it in the new heap was accepted instead of failing with EBADF.
//   RESET-05  FileSystemManager: `Registry::ensure` dropped the WatchEntry without `stopWatch`, so the inotify watch
//             and its Subscription hold survived.
//   RESET-06  SocketTables: the close tokens of a closing listener and the hold of a cancelled pending connect were
//             not released.
//   RESET-07  HttpTables: the hold of a respond task whose RespondDone is in flight, and the close tokens of a
//             closing server, were not released.
//   RESET-08  SocketEvents: an old-generation OpDone (and Connected) orphan was dropped without releasing its
//             token's hold.
//   RESET-09  WsTables: a socket's close-handshake hold, its parked `closed` waiters and cancelled dials kept their
//             holds; an old-generation WsEvent orphan dropped its token's hold too.
//   RESET-10  WsManager: `aux()` cleared its entries without releasing their subscription holds.
//   RESET-11  SystemManager: the process-wide SIGINT listener survived with an empty state, so Ctrl-C was swallowed.
//
// Each scenario resets the heap, so each runs in a child process (ChildScenario). A child exits 0 when it saw the
// correct (fixed) behaviour, 1 when the defect reproduced, and 3 when a precondition failed; it prints what it saw
// on stdout, which the parent puts in its failure message. RESET-11's child is instead expected to die of SIGINT.
//
// No scenario resumes a closure parked before its reset.

#include "EcoSystemCoreTest.hpp"

#include "eco-system/Core/AsyncSources.hpp"
#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/SignalService.hpp"
#include "eco-system/FileSystem/FileSystem.hpp"
#include "eco-system/FileSystem/FileSystemManager.hpp"
#include "eco-system/HttpServer/Http1.hpp"
#include "eco-system/HttpServer/HttpTables.hpp"
#include "eco-system/Socket/Conn.hpp"
#include "eco-system/Socket/SocketEvents.hpp"
#include "eco-system/Socket/SocketTables.hpp"
#include "eco-system/System/SystemManager.hpp"
#include "eco-system/WebSocket/WsEvents.hpp"
#include "eco-system/WebSocket/WsHandshake.hpp"
#include "eco-system/WebSocket/WsManager.hpp"
#include "eco-system/WebSocket/WsTables.hpp"

#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <dirent.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

namespace {

using namespace Eco::System;
using Elm::Allocator;
using Elm::AllocatorTestAccess;

constexpr int kCorrect = 0;
constexpr int kDefect = 1;
constexpr int kPrecondition = 3;

// ---- Shared helpers ---------------------------------------------------------------------------------------

// Resets the heap of this (the eco) thread: a new heap generation and a new RootSet.
void resetHeap() {
    auto& a = Allocator::instance();
    AllocatorTestAccess::reset(a);
    a.initThread();
}

// A closure of arity 1 that ignores its argument; parked as the "resume" of injected tokens. It is never called.
void* ignoreEval(void*[]) { return reinterpret_cast<void*>(enc(alloc::unit())); }
HPointer anyClosure() { return alloc::allocClosure(&ignoreEval, 1); }

// Parks a fresh closure with a Task hold and returns its token.
uint64_t parkTask(const char* site) {
    HPointer r = anyClosure();
    return Scheduler::instance().parkResume(r, HoldKind::Task, site);
}

// "live"/"released"/"(no census)" for token `t`.
std::string liveness(HoldToken t) {
    auto& s = Scheduler::instance();
    if (!s.holdCensusEnabled()) return "(no census)";
    return s.holdIsLive(t) ? "live" : "released";
}

// Calls the onEffects closure registered for `home` with `subs` (no commands, unit state, unit router).
bool callOnEffects(const char* home, HPointer subs) {
#if ECO_TEST_HOOKS
    const auto* info = PlatformRuntime::instance().findManagerForTest(home);
    if (!info) return false;
    Elm::StackRootGuard g(&subs);
    (void)Scheduler::callClosure4(dec(info->onEffects), alloc::unit(), alloc::listNil(), subs, alloc::unit());
    return true;
#else
    (void)home;
    (void)subs;
    return false;
#endif
}

// Runs scenario `name` and checks guard `id` from its exit status (see the file comment).
void reportScenario(const char* id, const char* name) {
    std::printf("%s\n", name);
    auto r = ChildScenario::runChildScenario(name, {{"ECO_SYSTEM_WATCH_POLL", "0"}}, 30000);
    std::string out = r.out;
    while (!out.empty() && (out.back() == '\n' || out.back() == ' ')) out.pop_back();
    for (auto& c : out) {
        if (c == '\n') c = ';';
    }
    if (r.exited && (r.exitCode == kCorrect || r.exitCode == kDefect)) {
        CHECK_MSG(r.exitCode == kCorrect, std::string(id) + ": " + out);
    } else {
        CHECK_MSG(false, std::string(name) + ": " + r.describe() + "; out: " + out + "; err: " + r.err);
    }
}

// ---- RESET-04: FileSystem handle table ---------------------------------------------------------------------

// The Task the last FileSystem resume was called with, as an encoded word.
uint64_t g_fsTask = 0;
void* recordFsEval(void* args[]) {
    g_fsTask = reinterpret_cast<uint64_t>(args[0]);
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

// Runs `op` of kind `kind` on payload `payload` to completion (event loop until quiescent); returns whether the
// Task succeeded, and its unboxed Int value in `n` when it did, or the FErr code in `code` when it failed.
bool runFs(Fs::FsOp op, Fs::FsKind kind, HPointer payload, int64_t& n, std::string& code) {
    g_fsTask = 0;
    HPointer resume = alloc::listNil();
    Elm::StackRootGuard g(&payload, &resume);
    resume = alloc::allocClosure(&recordFsEval, 1);
    (void)Fs::fsPoolSubmit(op, kind, payload, resume);
    Scheduler::instance().runEventLoop();
    if (g_fsTask == 0) {
        code = "(no result)";
        return false;
    }
    auto* t = static_cast<Elm::Task*>(Allocator::instance().resolve(dec(g_fsTask)));
    if (t->ctor == alloc::Task_Succeed) {
        n = t->value.i;
        return true;
    }
    Tuple2* err = asTuple2(t->value.p);
    code = toStdString(err->a.p);
    return false;
}

int scenarioReset04() {
    initCoreRuntime();
    char path[] = "/tmp/eco-reset04-XXXXXX";
    int tmp = ::mkstemp(path);
    if (tmp < 0) {
        std::printf("mkstemp failed\n");
        return kPrecondition;
    }
    ::close(tmp);
    // `open` succeeds with a handle id (FS-01); the test hook gives the fd behind it.
    int64_t handle = -1;
    std::string code;
    bool opened = runFs(&Fs::opOpen, Fs::FsKind::Open,
                        Fs::packFsArgs(enc(alloc::allocStringFromUTF8(path)), enc(alloc::allocStringFromUTF8("r"))),
                        handle, code);
#if ECO_TEST_HOOKS
    const int64_t fd = opened ? Fs::fdOfHandleForTest(handle) : -1;
#else
    const int64_t fd = -1;   // no way to see the fd: a precondition failure
#endif
    if (!opened || fd < 0 || ::fcntl(static_cast<int>(fd), F_GETFD) == -1) {
        std::printf("open failed: %s\n", code.c_str());
        ::unlink(path);
        return kPrecondition;
    }

    resetHeap();

    // The first FileSystem call of the new generation: fstat of an fd that was never opened (EBADF at once).
    int64_t ignored = 0;
    std::string fstatCode;
    (void)runFs(&Fs::opFstat, Fs::FsKind::Handle, Fs::packFsArgs(0, 0, 1 << 20), ignored, fstatCode);
    const bool stillOpen = ::fcntl(static_cast<int>(fd), F_GETFD) != -1;
    std::string closeCode;
    int64_t unused = 0;
    const bool closeAccepted = runFs(&Fs::opClose, Fs::FsKind::Close, Fs::packFsArgs(0, 0, handle), unused, closeCode);
    ::unlink(path);
    std::printf("fd %lld opened before the reset is %s after it; close of it in the new heap %s\n",
                static_cast<long long>(fd), stillOpen ? "still open (leaked)" : "closed",
                closeAccepted ? "succeeded (stale table entry)" : ("failed with " + closeCode).c_str());
    if (fstatCode != "EBADF") {
        std::printf("precondition: fstat of an unknown fd gave '%s', not EBADF\n", fstatCode.c_str());
        return kPrecondition;
    }
    const bool correct = !stillOpen && !closeAccepted && closeCode == "EBADF";
    return correct ? kCorrect : kDefect;
}

// ---- RESET-05: FileSystemManager watch after a reset -------------------------------------------------------

// Returns the number of inotify watches this process has ("inotify wd:" lines of every inotify fd), or -1 if it
// has no inotify fd.
int inotifyWatchCount() {
    DIR* d = ::opendir("/proc/self/fd");
    if (!d) return -1;
    int total = -1;
    while (dirent* e = ::readdir(d)) {
        if (e->d_name[0] == '.') continue;
        std::string link = std::string("/proc/self/fd/") + e->d_name;
        char buf[256];
        ssize_t n = ::readlink(link.c_str(), buf, sizeof buf - 1);
        if (n <= 0) continue;
        buf[n] = '\0';
        if (std::strstr(buf, "inotify") == nullptr) continue;
        if (total < 0) total = 0;
        std::ifstream info(std::string("/proc/self/fdinfo/") + e->d_name);
        std::string line;
        while (std::getline(info, line)) {
            if (line.rfind("inotify wd:", 0) == 0) ++total;
        }
    }
    ::closedir(d);
    return total;
}

HPointer watchSubs(const std::string& dir) {
    HPointer path = alloc::listNil(), tagger = alloc::listNil(), sub = alloc::listNil();
    Elm::StackRootGuard g({&path, &tagger, &sub});
    path = alloc::allocStringFromUTF8(dir);
    tagger = anyClosure();
    std::vector<Unboxable> fields{alloc::boxed(path), alloc::boxed(alloc::elmFalse()), alloc::boxed(tagger)};
    sub = alloc::custom(FileSystemManager::CTOR_WATCH, fields, 0);
    return alloc::cons(alloc::boxed(sub), alloc::listNil(), true);
}

int scenarioReset05() {
    initCoreRuntime();
    auto& s = Scheduler::instance();
    char dir[] = "/tmp/eco-reset05-XXXXXX";
    if (!::mkdtemp(dir)) {
        std::printf("mkdtemp failed\n");
        return kPrecondition;
    }
    (void)Eco_System_registerManager_FileSystem();
    const int base = s.pendingAsync();
    if (!callOnEffects("FileSystem", watchSubs(dir))) {
        std::printf("no FileSystem manager (ECO_TEST_HOOKS?)\n");
        return kPrecondition;
    }
    const int withWatch = s.pendingAsync();
    const int wdBefore = inotifyWatchCount();
    if (withWatch != base + 1) {
        std::printf("precondition: the watch took %d holds, not 1\n", withWatch - base);
        ::rmdir(dir);
        return kPrecondition;
    }

    resetHeap();
    (void)Eco_System_registerManager_FileSystem();   // the manager closures of the new heap
    (void)callOnEffects("FileSystem", alloc::listNil());   // reaches state(): the registry is cleared here

    const int after = s.pendingAsync();
    const int wdAfter = inotifyWatchCount();
    ::rmdir(dir);
    std::printf("pendingAsync %d before the watch, %d with it, %d after the reset and an empty onEffects; "
                "inotify watches %d with the watch, %d after\n",
                base, withWatch, after, wdBefore, wdAfter);
    bool correct = after == base;
    if (wdBefore > 0) correct = correct && wdAfter < wdBefore;
    return correct ? kCorrect : kDefect;
}

// ---- RESET-06: SocketTables close tokens and pending connects ----------------------------------------------

int scenarioReset06() {
    initCoreRuntime();
    auto& s = Scheduler::instance();
    ensureSocketTables();
    const int base = s.pendingAsync();
    const uint64_t t1 = parkTask("reset06.close");
    socketTables().listeners[1].closeTokens.push_back(t1);
    socketTables().listeners[1].closing = true;
    const uint64_t t2 = parkTask("reset06.connect");
    socketTables().pendingConnects[t2] = Conn::makeClient(ConnectSpec{}, nullptr, t2, currentHeapGeneration());
    const int injected = s.pendingAsync();

    resetHeap();
    (void)socketTables();   // runs resetTables
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    socketEventsDrain();    // a Connected for t2 would be an orphan here (the connect was never started)

    const int after = s.pendingAsync();
    std::printf("pendingAsync %d before injection, %d with a close token and a pending connect, %d after the "
                "reset; close token %s, pending connect %s\n",
                base, injected, after, liveness(t1).c_str(), liveness(t2).c_str());
    return after == base ? kCorrect : kDefect;
}

// ---- RESET-07: HttpTables respond and close tokens ---------------------------------------------------------

// A non-blocking TCP listener on 127.0.0.1, or -1.
int loopbackListener() {
    int fd = ::socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;
    if (::bind(fd, reinterpret_cast<sockaddr*>(&a), sizeof a) != 0 || ::listen(fd, 8) != 0) {
        ::close(fd);
        return -1;
    }
    return fd;
}

int scenarioReset07() {
    initCoreRuntime();
    auto& s = Scheduler::instance();
    HttpSrv::ensureHttpTables();
    const int base = s.pendingAsync();

    // (b) a closing server whose ServerClosed is still to come.
    int lfd = loopbackListener();
    if (lfd < 0) {
        std::printf("no loopback listener\n");
        return kPrecondition;
    }
    auto cfg = std::make_shared<HttpSrv::ServerConfig>();
    const int64_t serverId = HttpSrv::httpTablesStartServer(lfd, cfg, -1);
    const uint64_t tClose = parkTask("reset07.close");
    if (!HttpSrv::httpTablesCloseServer(serverId, 0, tClose)) {
        std::printf("httpTablesCloseServer refused\n");
        return kPrecondition;
    }
    // (a) a respond task whose RespondDone is in flight.
    const uint64_t tRespond = parkTask("reset07.respond");
    HttpSrv::HttpEvent ev;
    ev.kind = HttpSrv::HttpEvent::Kind::RespondDone;
    ev.gen = currentHeapGeneration();
    ev.token = tRespond;
    HttpSrv::postHttpEvent(std::move(ev));
    const int injected = s.pendingAsync();

    resetHeap();
    HttpSrv::httpTablesSubscriptionsChanged();   // reaches tables(): runs resetTables
    std::this_thread::sleep_for(std::chrono::milliseconds(100));   // the reactor posts the old ServerClosed
    runDrainSources();

    const int after = s.pendingAsync();
    std::printf("pendingAsync %d before, %d with a closing server and an in-flight respond, %d after the reset "
                "and a drain; respond token %s, close token %s\n",
                base, injected, after, liveness(tRespond).c_str(), liveness(tClose).c_str());
    return after == base ? kCorrect : kDefect;
}

// ---- RESET-08: SocketEvents orphans of an old generation ---------------------------------------------------

int scenarioReset08() {
    initCoreRuntime();
    auto& s = Scheduler::instance();
    ensureSocketTables();   // the socket event queue and its dispatchers
    const int base = s.pendingAsync();
    const uint64_t tOp = parkTask("reset08.opdone");
    {
        SocketEvent ev;   // what UdpHandler::postOpDone posts
        ev.kind = SocketEvent::Kind::OpDone;
        ev.gen = currentHeapGeneration();
        ev.token = tOp;
        postSocketEvent(std::move(ev));
    }
    const uint64_t tConn = parkTask("reset08.connected");
    {
        SocketEvent ev;   // a connect whose cancel lost the race (RESET-06): its failed Connected is in flight
        ev.kind = SocketEvent::Kind::Connected;
        ev.gen = currentHeapGeneration();
        ev.token = tConn;
        ev.failed = true;
        ev.code = "ECONNREFUSED";
        ev.message = "connect ECONNREFUSED";
        postSocketEvent(std::move(ev));
    }
    const int injected = s.pendingAsync();

    resetHeap();
    socketEventsDrain();

    const int after = s.pendingAsync();
    std::printf("pendingAsync %d before, %d with an OpDone and a Connected in flight, %d after the reset and a "
                "drain; OpDone token %s, Connected token %s\n",
                base, injected, after, liveness(tOp).c_str(), liveness(tConn).c_str());
    return after == base ? kCorrect : kDefect;
}

// ---- RESET-09: WsTables holds -----------------------------------------------------------------------------

int scenarioReset09() {
    initCoreRuntime();
    auto& s = Scheduler::instance();
    ensureWsTables();
    const int base = s.pendingAsync();
    const HoldToken closeHold = s.acquireHold(HoldKind::Item, "reset09.close");
    const uint64_t waiter = parkTask("reset09.waiter");
    {
        WsEntry& e = wsTables().sockets[1];
        e.closed = false;
        e.core = nullptr;   // abortCore(null) does nothing
        e.closeHold = closeHold;
        e.closedWaiters.push_back(waiter);
    }
    const uint64_t dialToken = parkTask("reset09.dial");
    wsTables().pendingDials[dialToken] = std::make_shared<DialJob>(DialSpec{});   // never started: cancel wins
    const uint64_t opToken = parkTask("reset09.opdone");
    {
        WsEvent ev;   // a close or reject operation whose OpDone is in flight
        ev.kind = WsEvent::Kind::OpDone;
        ev.gen = currentHeapGeneration();
        ev.token = opToken;
        ev.wsId = 1;
        postWsEvent(std::move(ev));
    }
    const int injected = s.pendingAsync();

    resetHeap();
    (void)wsTables();   // runs resetTables
    wsEventsDrain();    // the OpDone is an old-generation orphan

    const int after = s.pendingAsync();
    std::printf("pendingAsync %d before, %d with a close hold, a closed waiter, a pending dial and an in-flight "
                "OpDone, %d after the reset; close hold %s, waiter %s, dial %s, OpDone %s\n",
                base, injected, after, liveness(closeHold).c_str(), liveness(waiter).c_str(),
                liveness(dialToken).c_str(), liveness(opToken).c_str());
    return after == base ? kCorrect : kDefect;
}

// ---- RESET-10: WsManager aux() holds ----------------------------------------------------------------------

HPointer onCloseSubs(int64_t wsId) {
    HPointer tagger = alloc::listNil(), sub = alloc::listNil();
    Elm::StackRootGuard g(&tagger, &sub);
    tagger = anyClosure();
    std::vector<Unboxable> fields{alloc::unboxedInt(wsId), alloc::boxed(tagger)};
    sub = alloc::custom(WsManager::CTOR_ON_CLOSE, fields, WsManager::SUB_MASK);
    return alloc::cons(alloc::boxed(sub), alloc::listNil(), true);
}

int scenarioReset10() {
    initCoreRuntime();
    auto& s = Scheduler::instance();
    ensureWsTables();
    (void)Eco_System_registerManager_WebSocket();
    {
        WsEntry& e = wsTables().sockets[1];   // an open WebSocket with no readable: no reader is attached
        e.closed = false;
        e.readableId = 0;
    }
    const int base = s.pendingAsync();
    if (!callOnEffects("WebSocket", onCloseSubs(1))) {
        std::printf("no WebSocket manager (ECO_TEST_HOOKS?)\n");
        return kPrecondition;
    }
    const int subscribed = s.pendingAsync();
    if (subscribed != base + 1) {
        std::printf("precondition: the OnClose subscription took %d holds, not 1\n", subscribed - base);
        return kPrecondition;
    }

    resetHeap();
    (void)Eco_System_registerManager_WebSocket();         // the manager closures of the new heap
    (void)callOnEffects("WebSocket", alloc::listNil());   // reaches aux(): its entries are discarded

    const int after = s.pendingAsync();
    std::printf("pendingAsync %d before, %d with an OnClose subscription, %d after the reset and an empty "
                "onEffects\n",
                base, subscribed, after);
    return after == base ? kCorrect : kDefect;
}

// ---- RESET-11: the System manager's SIGINT listener after a reset ------------------------------------------

// Raises `signo` and runs the signal drain once the reader thread has queued it (or after 5 s).
void raiseAndDrainSignal(int signo) {
    (void)::raise(signo);
    auto& svc = SignalService::instance();
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!svc.hasReady() && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    signalDrain();
}

int scenarioReset11() {
    initCoreRuntime();
    ::signal(SIGINT, SIG_DFL);   // the disposition a fresh CLI process starts with
    (void)Eco_System_registerManager_System();
    HPointer subs = alloc::listNil(), msg = alloc::listNil(), sub = alloc::listNil();
    {
        Elm::StackRootGuard g({&subs, &msg, &sub});
        msg = alloc::allocInt(7);
        std::vector<Unboxable> fields{alloc::boxed(msg)};
        sub = alloc::custom(SystemManager::CTOR_ON_SIGNAL_INTERRUPT, fields, 0);
        subs = alloc::cons(alloc::boxed(sub), alloc::listNil(), true);
        if (!callOnEffects("System", subs)) {
            std::printf("no System manager (ECO_TEST_HOOKS?)\n");
            return kPrecondition;
        }
    }
    if (SignalService::instance().listenerCount(SIGINT) != 1) {
        std::printf("precondition: onSignalInterrupt added %d SIGINT listeners, not 1\n",
                    static_cast<int>(SignalService::instance().listenerCount(SIGINT)));
        return kPrecondition;
    }
    std::fflush(stdout);

    resetHeap();   // the program and its subscriptions are gone with the heap
    raiseAndDrainSignal(SIGINT);
    raiseAndDrainSignal(SIGINT);

    std::printf("survived two SIGINTs after the reset (SIGINT listeners: %d): the default action was not "
                "restored\n",
                static_cast<int>(SignalService::instance().listenerCount(SIGINT)));
    return kDefect;
}

void testReset11() {
    const char* name = "heap-reset/sigint-listener";
    std::printf("%s\n", name);
    auto r = ChildScenario::runChildScenario(name, {}, 30000);
    std::string out = r.out;
    while (!out.empty() && out.back() == '\n') out.pop_back();
    if (r.signaled && r.signal == SIGINT) {
        // Correct: the child died of SIGINT after the reset (default action restored).
    } else if (r.exited && r.exitCode == kDefect) {
        CHECK_MSG(false, "RESET-11: " + out);
    } else {
        CHECK_MSG(false, std::string(name) + ": " + r.describe() + "; out: " + out + "; err: " + r.err);
    }
}

}  // namespace

void runHeapResetTests() {
    reportScenario("RESET-04", "heap-reset/filesystem-handles");
    reportScenario("RESET-05", "heap-reset/watch");
    reportScenario("RESET-06", "heap-reset/socket-tables");
    reportScenario("RESET-07", "heap-reset/http-tables");
    reportScenario("RESET-08", "heap-reset/socket-orphans");
    reportScenario("RESET-09", "heap-reset/websocket-tables");
    reportScenario("RESET-10", "heap-reset/websocket-manager");
    testReset11();
}

void registerHeapResetScenarios() {
    ChildScenario::add("heap-reset/filesystem-handles", scenarioReset04);
    ChildScenario::add("heap-reset/watch", scenarioReset05);
    ChildScenario::add("heap-reset/socket-tables", scenarioReset06);
    ChildScenario::add("heap-reset/http-tables", scenarioReset07);
    ChildScenario::add("heap-reset/socket-orphans", scenarioReset08);
    ChildScenario::add("heap-reset/websocket-tables", scenarioReset09);
    ChildScenario::add("heap-reset/websocket-manager", scenarioReset10);
    ChildScenario::add("heap-reset/sigint-listener", scenarioReset11);
}
