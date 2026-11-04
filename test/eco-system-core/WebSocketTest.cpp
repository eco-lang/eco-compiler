// WebSocket unit tests of eco-system-core-test (system-kernel-cpp/src/eco-system/WebSocket/): the
// role checks of the open / reject kernels, and WsCore and the open path on a fake port.
//
// DEAD-35 / WS-20: `WsHandshakeEntry::server` is never read. `wsOpenBody` takes the WebSocket's role from the Elm
// payload (`role`, 0 = client, 1 = server) and `wsRejectBody` answers any handshake, so a client handshake (one
// made by `dial`) can be opened as a server, a server handshake opened as a client, and a client handshake
// "rejected" with an HTTP response written to the server it dialled. Well-typed Elm cannot get there (the wrapper
// hard-codes the role), so the checks build the kernel payloads in C++. The fix (decision D13, fix package D3) fails
// such a call with EINVAL at once, before anything is emplaced (the Never-typed reject completes at once); before it
// the call was accepted: the task parked, the handshake consumed, and a WebSocket entry created.
//
// The checks run in a child process (scenario "websocket/role-mismatch"): an accepted open leaves a parked task, a
// WebSocket entry and two stream pairs behind, which must not leak into the other in-process tests.
//
// The WsCore and open-path checks run in one child scenario ("websocket/core-and-open-path"), a fresh process:
// the checks install their own WsEvent dispatch functions (and WS-21 the WebSocket tables' ones), which must not
// leak into the other checks. The parent fails if the child's CHECKs failed. All of these bugs
// are fixed (fix package D3); each former expected-failure guard is now a plain CHECK
// (`expectFixed`), and the comments below say what each one used to see.
//
// The WsCore checks run on a "fake port": `FakeWsPort` implements `WsPort` and records every write
// (bytes plus its `done` callback, which is called only when the test says so), every deadline and
// every close of the transport. The core is driven straight from the test thread; nothing is attached
// to the real reactor, whose clock (`IoReactor::nowMs`) is the only part the core uses. Results are
// popped from the channel-results queue (`tryPopChannelResult`) and the WebSocket event queue
// (recorders installed with `setWsEventDispatch`, then a manual `wsEventsDrain`).
//
// Before the fixes:
//   WS-11    `WsCore::checkPause` re-arms an outstanding heartbeat ping with `heartbeatTimeout`, which
//            is 0 by default, instead of the 30 s default: after a pause the ping deadline is "now".
//   WS-12    `WsCore::closeFrameWritten` ignores its `err`: a failed Close write completes `writeClose`
//            with success and lets the close handshake count as clean.
//   WS-13    `WsCore::ended` sets `closeWritten_` without a write, so a later `writeClose` succeeds.
//   WS-16    `WsCore::failWith` writes a second Close frame when ours was handed to the port but its
//            write has not completed (it tests `closeWritten_`, not "a Close was sent").
//   WS-21    `onOpened` resumes a failed `open` but leaves the `WsEntry` and its two stream pairs,
//            which Elm never received, in the tables.
//   WS-NEW-1 `wsOpenOnConn` (h1 path) posts `Opened` success before installing the codec; when the
//            101 response write fails, the watch-mode HoldProtocol aborts the Conn, `setProtocol`
//            then never calls `WsProtocol::onOpen`, and the core is never attached or ended.

#include "EcoSystemCoreTest.hpp"

#include "eco-system/Core/Core.hpp"
#include "eco-system/WebSocket/WebSocket.hpp"
#include "eco-system/WebSocket/WsTables.hpp"

#include <cstdio>
#include <string>
#include <vector>

#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/Core/IoReactor.hpp"
#include "eco-system/Core/SocketUtil.hpp"
#include "eco-system/Socket/Conn.hpp"
#include "eco-system/Socket/SocketEvents.hpp"
#include "eco-system/Stream/StreamTable.hpp"
#include "eco-system/WebSocket/WsEvents.hpp"
#include "eco-system/WebSocket/WsFrame.hpp"
#include "eco-system/WebSocket/WsHandshake.hpp"
#include "eco-system/WebSocket/WsProtocol.hpp"

#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>

#include <sys/socket.h>
#include <unistd.h>

using namespace Eco::System;

namespace {

// --- DEAD-35 / WS-20: role mismatch between the handshake and the open/reject call --------------------------------

std::vector<std::string> g_resumed03;   // "ok" / "err:<code>:<message>"

// The resume closure: records the task it is called with (a Task of an FErr `( code, message )` or of Never).
void* recordResume03(void* args[]) {
    HPointer task = dec(args[0]);
    auto* t = static_cast<Elm::Task*>(Allocator::instance().resolve(task));
    if (t->ctor == Elm::alloc::Task_Succeed) {
        g_resumed03.push_back("ok");
    } else {
        Tuple2* tup = asTuple2(t->value.p);
        g_resumed03.push_back("err:" + toStdString(tup->a.p) + ":" + toStdString(tup->b.p));
    }
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

// An identity fromWire/toWire closure; never called by these checks.
void* identity03(void* args[]) { return args[0]; }

// The `captured` payload of `wsOpenBody` (WebSocket.cpp):
//   ( ( id, ( status, headers ) ), ( ( role, mode, maxMsg ), ( hbInterval, hbTimeout, closeTimeout ),
//     ( threshold, ( ourNoCtx, ourBits ), ( peerNoCtx, peerBits ) ) ), ( fromWire, toWire ) )
HPointer openPayload(int64_t hsId, int64_t role) {
    HPointer rt = alloc::listNil(), first = alloc::listNil(), t1 = alloc::listNil(), t2 = alloc::listNil();
    HPointer ours = alloc::listNil(), peers = alloc::listNil(), t3 = alloc::listNil(), params = alloc::listNil();
    HPointer fw = alloc::listNil(), tw = alloc::listNil(), fns = alloc::listNil();
    Elm::StackRootGuard g({&rt, &first, &t1, &t2, &ours, &peers, &t3, &params, &fw, &tw, &fns});
    rt = alloc::tuple2(alloc::unboxedInt(101), alloc::boxed(alloc::listNil()), 0x1);
    first = alloc::tuple2(alloc::unboxedInt(hsId), alloc::boxed(rt), 0x1);
    t1 = alloc::tuple3(alloc::unboxedInt(role), alloc::unboxedInt(1), alloc::unboxedInt(0), 0x15);
    t2 = alloc::tuple3(alloc::unboxedInt(0), alloc::unboxedInt(0), alloc::unboxedInt(0), 0x15);
    ours = alloc::tuple2(alloc::boxed(alloc::elmFalse()), alloc::unboxedInt(15), 0x4);
    peers = alloc::tuple2(alloc::boxed(alloc::elmFalse()), alloc::unboxedInt(15), 0x4);
    t3 = alloc::tuple3(alloc::unboxedInt(-1), alloc::boxed(ours), alloc::boxed(peers), 0x1);
    params = alloc::tuple3(alloc::boxed(t1), alloc::boxed(t2), alloc::boxed(t3), 0);
    fw = alloc::allocClosureK(&identity03, 1, PK_Boxed);
    tw = alloc::allocClosureK(&identity03, 1, PK_Boxed);
    fns = alloc::tuple2(alloc::boxed(fw), alloc::boxed(tw), 0);
    return alloc::tuple3(alloc::boxed(first), alloc::boxed(params), alloc::boxed(fns), 0);
}

// The `captured` payload of `wsRejectBody`: ( id, ( status, headers, body ) ).
HPointer rejectPayload(int64_t hsId) {
    HPointer body = alloc::listNil(), r = alloc::listNil();
    Elm::StackRootGuard g({&body, &r});
    body = alloc::allocStringFromUTF8("no");
    r = alloc::tuple3(alloc::unboxedInt(403), alloc::boxed(alloc::listNil()), alloc::boxed(body), 0x1);
    return alloc::tuple2(alloc::unboxedInt(hsId), alloc::boxed(r), 0x1);
}

// Registers a client handshake, as `onDialed` does (WsTables.cpp), with no connection.
int64_t addClientHandshake() {
    ensureWsTables();
    auto& t = wsTables();
    int64_t id = t.nextHsId++;
    t.handshakes.emplace(id, WsHandshakeEntry{nullptr, false});
    return id;
}

// Calls `body` with `captured` and the recording resume; returns how the call ended at once.
template <typename Body>
std::string callNow(Body body, HPointer captured) {
    HPointer resume = alloc::listNil();
    Elm::StackRootGuard g({&captured, &resume});
    resume = alloc::allocClosureK(&recordResume03, 1, PK_Boxed);
    g_resumed03.clear();
    body(captured, resume);
    return g_resumed03.empty() ? std::string("parked") : g_resumed03.back();
}

// Prints one line per case: "DEAD-35 <case>: <how it ended> sockets+<n> hsLeft=<0|1>". The parent decides.
int scenarioRoleMismatch() {
    initCoreRuntime();
    ensureWsTables();
    auto report = [](const char* name, const std::string& got, size_t sockets0, int64_t hsId) {
        auto& t = wsTables();
        std::printf("DEAD-35 %s: %s sockets+%zu hsLeft=%d\n", name, got.c_str(), t.sockets.size() - sockets0,
                    t.handshakes.count(hsId) ? 1 : 0);
    };
    {   // A client handshake opened as a server (role 1).
        int64_t id = addClientHandshake();
        size_t s0 = wsTables().sockets.size();
        report("client-open-as-server", callNow(&wsOpenBody, openPayload(id, 1)), s0, id);
    }
    {   // A server handshake opened as a client (role 0).
        ensureWsTables();
        int64_t id = wsTablesAddServerHandshake(nullptr, kNoHold);
        size_t s0 = wsTables().sockets.size();
        report("server-open-as-client", callNow(&wsOpenBody, openPayload(id, 0)), s0, id);
    }
    {   // A client handshake rejected (only a server handshake can be answered with a rejection).
        int64_t id = addClientHandshake();
        size_t s0 = wsTables().sockets.size();
        report("client-reject", callNow(&wsRejectBody, rejectPayload(id)), s0, id);
    }
    std::fflush(stdout);
    return 0;
}

// The line of case `name` in the child's stdout, or "" if missing.
std::string caseLine(const std::string& out, const std::string& name) {
    std::string key = "DEAD-35 " + name + ": ";
    size_t p = out.find(key);
    if (p == std::string::npos) return std::string();
    size_t e = out.find('\n', p);
    return out.substr(p + key.size(), e == std::string::npos ? std::string::npos : e - p - key.size());
}

void testWsRoleMismatch() {
    std::printf("websocket/open-or-reject-with-a-role-that-does-not-match-the-handshake\n");
    auto r = ChildScenario::runChildScenario("websocket/role-mismatch", {}, 20000);
    CHECK_MSG(r.ok(), r.describe() + "; stderr: " + r.err);
    const char* cases[] = {"client-open-as-server", "server-open-as-client", "client-reject"};
    for (const char* name : cases) {
        std::string line = caseLine(r.out, name);
        CHECK_MSG(!line.empty(), std::string("no result for ") + name + "; stdout: " + r.out);
        if (line.empty()) continue;
        // The call fails (or, for the Never-typed reject, finishes) at once with no WebSocket created, and the
        // handshake stays in place.
        bool rejectedNow = line.rfind("err:EINVAL", 0) == 0 && line.find("sockets+0") != std::string::npos;
        if (std::string(name) == "client-reject") {
            rejectedNow = line.rfind("parked", 0) != 0 && line.find("sockets+0") != std::string::npos;
        }
        rejectedNow = rejectedNow && line.find("hsLeft=1") != std::string::npos;
        CHECK_MSG(rejectedNow, std::string("DEAD-35 ") + name + ": " + line);
    }
}

}  // namespace

using namespace Eco::System;

namespace {

int64_t nowMs() { return IoReactor::instance().nowMs(); }

void sleepMs(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

// In the child: the check of a fixed bug, which was an expected-failure guard until its fix landed.
void expectFixed(const char* id, bool defect, const std::string& how) {
    std::printf("  %s %s: %s\n", id, defect ? "FAILED" : "ok", how.c_str());
    std::fflush(stdout);
    CHECK_MSG(!defect, std::string(id) + " reproduces: " + how);
}

// Runs fn on the reactor thread and waits for it (as EcoSystemCoreTest.cpp's onReactor).
void onReactor(const std::function<void()>& fn) {
    std::mutex mu;
    std::condition_variable cv;
    bool done = false;
    IoReactor::instance().submit([&] {
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

// --- Result capture ------------------------------------------------------------------------

std::vector<WsEvent> g_events;

bool recordWsEvent(WsEvent& ev) {
    g_events.push_back(std::move(ev));
    return false;
}

constexpr WsEvent::Kind kRecordedKinds[] = {WsEvent::Kind::Opened, WsEvent::Kind::OpDone,
                                            WsEvent::Kind::PingDone, WsEvent::Kind::Closed};

// Installs the recorders for the kinds a core (or the open path) posts and clears what was recorded.
void installRecorders() {
    for (WsEvent::Kind k : kRecordedKinds) setWsEventDispatch(k, &recordWsEvent);
    g_events.clear();
}

void removeRecorders() {
    for (WsEvent::Kind k : kRecordedKinds) setWsEventDispatch(k, nullptr);
    g_events.clear();
}

// Moves every queued WsEvent of the current heap generation into g_events.
void drainWsEvents() { wsEventsDrain(); }

std::vector<ChannelResult> g_results;

// Moves every queued ChannelResult into g_results.
void drainChannel() {
    ChannelResult r;
    while (tryPopChannelResult(r)) g_results.push_back(std::move(r));
}

// Drops whatever earlier tests left on both queues.
void resetQueues() {
    drainChannel();
    g_results.clear();
    drainWsEvents();
    g_events.clear();
}

const ChannelResult* resultFor(uint64_t token) {
    drainChannel();
    for (const ChannelResult& r : g_results) {
        if (r.token == token) return &r;
    }
    return nullptr;
}

const WsEvent* eventOf(WsEvent::Kind kind, uint64_t token = 0) {
    drainWsEvents();
    for (const WsEvent& e : g_events) {
        if (e.kind == kind && (token == 0 || e.token == token)) return &e;
    }
    return nullptr;
}

int countEvents(WsEvent::Kind kind) {
    drainWsEvents();
    int n = 0;
    for (const WsEvent& e : g_events) n += e.kind == kind;
    return n;
}

std::string describeResult(const ChannelResult* r) {
    if (!r) return "no result";
    return "err " + std::to_string(r->err) + " (" + (r->err ? errnoName(r->err) : "0") + ") reason \"" +
           r->reason + "\"";
}

// --- The fake port -------------------------------------------------------------------------

struct FakeWsPort final : WsPort {
    struct Write {
        std::string bytes;
        std::function<void(int)> done;
    };
    std::vector<Write> writes;
    std::vector<std::pair<int, int64_t>> deadlines;   // (timerId, monoMs) in call order
    int graceful = 0;
    int aborts = 0;
    size_t outbound = 0;   // what portOutbound reports

    void portWrite(std::string bytes, std::function<void(int)> done) override {
        writes.push_back(Write{std::move(bytes), std::move(done)});
    }
    size_t portOutbound() const override { return outbound; }
    void portSetDeadline(int timerId, int64_t monoMs) override { deadlines.emplace_back(timerId, monoMs); }
    void portUpdateInterest() override {}
    void portCloseGraceful(int64_t) override { ++graceful; }
    void portAbort() override { ++aborts; }

    // The last deadline recorded for `timerId`, or -1 when none was.
    int64_t lastDeadline(int timerId) const {
        for (auto it = deadlines.rbegin(); it != deadlines.rend(); ++it) {
            if (it->first == timerId) return it->second;
        }
        return -1;
    }
    // The number of recorded writes that are Close frames (each portWrite of a control frame is
    // one whole frame; the opcode is the low nibble of its first byte).
    int closeFrames() const {
        int n = 0;
        for (const Write& w : writes) {
            if (!w.bytes.empty() && (static_cast<unsigned char>(w.bytes[0]) & 0x0F) == ws::kOpClose) ++n;
        }
        return n;
    }
    // The index of the first recorded Close write, or -1.
    int firstCloseWrite() const {
        for (size_t i = 0; i < writes.size(); ++i) {
            if (!writes[i].bytes.empty() && (static_cast<unsigned char>(writes[i].bytes[0]) & 0x0F) == ws::kOpClose) {
                return static_cast<int>(i);
            }
        }
        return -1;
    }
    // Completes write `i` with `err` (once).
    void complete(size_t i, int err) {
        auto done = std::move(writes[i].done);
        writes[i].done = nullptr;
        if (done) done(err);
    }
};

// A core with its fake port; detaches the port and drops the recorded callbacks (which hold the core)
// when it goes out of scope.
struct CoreRig {
    FakeWsPort port;
    std::shared_ptr<WsCore> core;
    explicit CoreRig(WsConfig cfg, size_t outbound = 0) {
        cfg.gen = currentHeapGeneration();
        cfg.wsId = 5000;
        port.outbound = outbound;
        core = std::make_shared<WsCore>(cfg);
        core->attach(&port);
    }
    ~CoreRig() {
        core->detachPort(&port);
        port.writes.clear();
        core.reset();
    }
};

// An unmasked frame from the server (what a client core receives).
std::string serverFrame(uint8_t opcode, const std::string& payload) {
    return ws::encodeFrame(true, opcode, payload.data(), payload.size(), nullptr);
}

void feed(WsCore& core, const std::string& bytes) { core.portData(bytes.data(), bytes.size()); }

constexpr uint64_t kChan = 7;

// --- WS-11 ---------------------------------------------------------------------------------

// A heartbeat ping is outstanding when reading pauses; resuming re-arms its deadline with
// `heartbeatTimeout` (0) instead of the 30 s default, so the pong deadline becomes "now".
void testWsCoreHeartbeatResume() {
    std::printf("websocket/heartbeat-ping-deadline-after-a-read-pause\n");
    resetQueues();
    WsConfig cfg;
    cfg.heartbeatInterval = 50;
    cfg.heartbeatTimeout = 0;
    CoreRig rig(cfg);
    sleepMs(60);
    rig.core->portTimer(Conn::kTimerHeartbeat);
    const int64_t afterPing = nowMs();
    const int64_t pingDeadline = rig.port.lastDeadline(Conn::kTimerPong);
    CHECK_MSG(rig.port.writes.size() == 1, "heartbeat ping not written: " + std::to_string(rig.port.writes.size()));
    CHECK_MSG(pingDeadline >= afterPing + 29000, "first ping deadline " + std::to_string(pingDeadline - afterPing));

    // 1,100 small text frames: the readable queue passes kReadHighCount and reading pauses.
    std::string many;
    for (int i = 0; i < 1100; ++i) many += serverFrame(ws::kOpText, "x");
    rig.port.deadlines.clear();
    feed(*rig.core, many);
    const bool paused = rig.port.lastDeadline(Conn::kTimerPong) == 0;
    CHECK_MSG(paused, "reading did not pause (no kTimerPong <- 0)");
    rig.port.deadlines.clear();
    for (uint64_t t = 1; t <= 200; ++t) rig.core->reqRead(kChan, 11000 + t);
    drainChannel();
    const int64_t resumed = nowMs();
    const int64_t after = rig.port.lastDeadline(Conn::kTimerPong);
    CHECK_MSG(after > 0, "no pong deadline re-armed after the reads (" + std::to_string(after) + ")");
    if (!paused || after <= 0) return;
    const bool defect = after < resumed + 29000;
    expectFixed("WS-11", defect,
                      "pong deadline after resume = now + " + std::to_string(after - resumed) + " ms");
}

// --- WS-12 ---------------------------------------------------------------------------------

void testWsCoreCloseWriteFails() {
    std::printf("websocket/failed-close-write-fails-write-close-and-handshake\n");
    // (a) writeClose, its Close write fails EPIPE, then the transport error.
    resetQueues();
    installRecorders();
    bool defectA = false, defectB = false;
    std::string howA, howB;
    {
        CoreRig rig(WsConfig{});
        rig.core->writeClose(kChan, 1);
        const int ci = rig.port.firstCloseWrite();
        CHECK_MSG(ci >= 0, "(a) Close frame not handed to the port");
        CHECK_MSG(resultFor(1) == nullptr, "(a) writeClose completed before its write");
        if (ci >= 0) {
            rig.port.complete(static_cast<size_t>(ci), EPIPE);
            rig.core->portError(EPIPE, "write EPIPE");
            const ChannelResult* r = resultFor(1);
            CHECK_MSG(r != nullptr, "(a) writeClose never completed");
            if (r) {
                defectA = r->err == 0;
                howA = "(a) writeClose after a failed Close write: " + describeResult(r);
            }
        }
    }
    // (b) the peer's Close arrives, then our Close write fails ECANCELED, then the transport goes.
    resetQueues();
    {
        CoreRig rig(WsConfig{});
        rig.core->writeClose(kChan, 2);
        const int ci = rig.port.firstCloseWrite();
        CHECK_MSG(ci >= 0, "(b) Close frame not handed to the port");
        feed(*rig.core, serverFrame(ws::kOpClose, ws::closePayload(ws::kCloseNormal, "")));
        CHECK_MSG(rig.port.closeFrames() == 1, "(b) an echo was written although our Close was queued");
        if (ci >= 0) {
            rig.port.complete(static_cast<size_t>(ci), ECANCELED);
            rig.core->portClosed();
            const WsEvent* ev = eventOf(WsEvent::Kind::Closed);
            CHECK_MSG(ev != nullptr, "(b) no Closed event");
            if (ev) {
                defectB = ev->clean;
                howB = "(b) Closed after a failed Close write: code " + std::to_string(ev->closeCode) +
                       " clean " + (ev->clean ? "true" : "false");
            }
        }
    }
    expectFixed("WS-12", defectA, howA);
    expectFixed("WS-12", defectB, howB);

    // (c) regression pin: startClose's OpDone completes (success) however the Close write ends,
    // because WebSocket.close is `Task.mapError never`.
    resetQueues();
    {
        CoreRig rig(WsConfig{});
        rig.core->startClose(ws::kCloseNormal, "", 3);
        const int ci = rig.port.firstCloseWrite();
        CHECK_MSG(ci >= 0, "(c) Close frame not handed to the port");
        if (ci >= 0) {
            rig.port.complete(static_cast<size_t>(ci), EPIPE);
            rig.core->portError(EPIPE, "write EPIPE");
            const WsEvent* ev = eventOf(WsEvent::Kind::OpDone, 3);
            CHECK_MSG(ev != nullptr && !ev->failed, "(c) startClose did not post OpDone success");
            CHECK_MSG(countEvents(WsEvent::Kind::OpDone) == 1, "(c) OpDone posted more than once");
        }
    }
    removeRecorders();
}

// --- WS-13 ---------------------------------------------------------------------------------

void testWsCoreLateCloseAfterAbnormalEnd() {
    std::printf("websocket/write-close-after-an-abnormal-end\n");
    resetQueues();
    installRecorders();
    const ChannelResult* first = nullptr;
    ChannelResult late, control;
    bool haveLate = false, haveControl = false;
    {
        // (a) the Close stays in outQ_ (the port reports 1 MiB unsent), then the connection resets.
        CoreRig rig(WsConfig{}, 1024 * 1024);
        rig.core->writeClose(kChan, 1);
        CHECK_MSG(rig.port.closeFrames() == 0, "(a) Close frame handed to a full port");
        rig.core->portError(ECONNRESET, "read ECONNRESET");
        first = resultFor(1);
        CHECK_MSG(first != nullptr && first->err == ECANCELED,
                  "(a) the dropped Close's writeClose: " + describeResult(first));
        rig.core->writeClose(kChan, 2);
        if (const ChannelResult* r = resultFor(2)) {
            late = *r;
            haveLate = true;
        }
    }
    {
        // (b) control: a fresh core ends the same way with no earlier close.
        CoreRig rig(WsConfig{}, 1024 * 1024);
        rig.core->portError(ECONNRESET, "read ECONNRESET");
        rig.core->writeClose(kChan, 3);
        if (const ChannelResult* r = resultFor(3)) {
            control = *r;
            haveControl = true;
        }
    }
    CHECK_MSG(haveLate, "(a) the late writeClose never completed");
    CHECK_MSG(haveControl && control.err == ECANCELED,
              "(b) control writeClose after the end: " + describeResult(haveControl ? &control : nullptr));
    removeRecorders();
    if (!haveLate || !haveControl) return;
    const bool defect = late.err != control.err;
    expectFixed("WS-13", defect,
                      "late writeClose: " + describeResult(&late) + "; control: " + describeResult(&control));
}

// --- WS-16 ---------------------------------------------------------------------------------

void testWsCoreSingleCloseFrame() {
    std::printf("websocket/fail-with-writes-no-second-close\n");
    resetQueues();
    installRecorders();
    int closesA = -1, closesB = -1;
    {
        // (a) our Close handed over and pending; then a frame with reserved opcode 0x3.
        CoreRig rig(WsConfig{});
        rig.core->startClose(ws::kCloseNormal, "bye", 1);
        CHECK_MSG(rig.port.closeFrames() == 1, "(a) our Close frame not handed to the port");
        feed(*rig.core, serverFrame(0x3, "zz"));
        const WsEvent* ev = eventOf(WsEvent::Kind::Closed);
        CHECK_MSG(ev != nullptr && ev->closeCode == ws::kCloseProtocolError,
                  "(a) the reserved opcode did not fail the connection with 1002");
        closesA = rig.port.closeFrames();
    }
    resetQueues();
    {
        // (b) the heartbeat path: ping sent, our Close handed over, the ping deadline passes.
        WsConfig cfg;
        cfg.heartbeatInterval = 30;
        cfg.heartbeatTimeout = 30;
        CoreRig rig(cfg);
        sleepMs(40);
        rig.core->portTimer(Conn::kTimerHeartbeat);
        CHECK_MSG(rig.port.writes.size() == 1, "(b) heartbeat ping not written");
        rig.core->startClose(ws::kCloseNormal, "", 2);
        CHECK_MSG(rig.port.closeFrames() == 1, "(b) our Close frame not handed to the port");
        sleepMs(40);
        rig.core->portTimer(Conn::kTimerPong);
        const WsEvent* ev = eventOf(WsEvent::Kind::Closed);
        CHECK_MSG(ev != nullptr && ev->closeCode == ws::kCloseAbnormal,
                  "(b) the heartbeat timeout did not fail the connection");
        closesB = rig.port.closeFrames();
    }
    removeRecorders();
    expectFixed("WS-16", closesA > 1, "(a) protocol error after our Close: " + std::to_string(closesA) +
                                                " Close frames written");
    expectFixed("WS-16", closesB > 1, "(b) heartbeat timeout after our Close: " + std::to_string(closesB) +
                                                " Close frames written");
}

// --- WS-NEW-1 ------------------------------------------------------------------------------

// Reads would block; every write fails EPIPE.
class FailingWriteTransport final : public Transport {
public:
    ssize_t read(char*, size_t) override {
        wantRead = true;
        wantWrite = false;
        return -1;
    }
    ssize_t write(const char*, size_t) override {
        wantRead = wantWrite = false;
        errNo = EPIPE;
        errCode = "EPIPE";
        return -2;
    }
    int shutdownWrite() override { return -1; }
};

void testWsOpenWriteFails() {
    std::printf("websocket/h1-open-whose-101-response-write-fails\n");
    resetQueues();
    installRecorders();
    int sv[2];
    CHECK(::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) == 0);
    CHECK(setNonBlocking(sv[0]) == 0);
    std::shared_ptr<Conn> c;
    bool open = false;
    onReactor([&] {
        c = Conn::makeAccepted(sv[0], true, std::make_unique<FailingWriteTransport>());
        CHECK(IoReactor::instance().add(c, sv[0]) != 0);
        c->beginServer(0, [](Conn&, bool ok) { CHECK(ok); });
        open = c->phase() == Conn::Phase::Open;
        // The handshake is held in watch mode, as a server upgrade request leaves it.
        c->setProtocol(std::make_unique<HoldProtocol>([] {}), std::string());
    });
    CHECK_MSG(open, "the test Conn did not open");
    WsConfig cfg;
    cfg.server = true;
    cfg.gen = currentHeapGeneration();
    cfg.wsId = 5100;
    auto core = std::make_shared<WsCore>(cfg);
    const uint64_t tok = 5101;
    onReactor([&] {
        wsOpenOnConn(c, core, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n", tok, cfg.gen,
                     cfg.wsId);
    });
    const WsEvent* opened = nullptr;
    for (int i = 0; i < 100 && !opened; ++i) {
        opened = eventOf(WsEvent::Kind::Opened, tok);
        if (!opened) sleepMs(5);
    }
    CHECK_MSG(opened != nullptr, "no Opened event posted");
    bool openedOk = opened && !opened->failed;
    onReactor([&] { core->reqRead(kChan, 5102); });
    for (int i = 0; i < 100; ++i) {
        drainChannel();
        if (resultFor(5102)) break;
        sleepMs(5);
    }
    const ChannelResult* rr = resultFor(5102);
    std::string connState;
    onReactor([&] {
        connState = std::string("conn phase ") + (c->phase() == Conn::Phase::Open ? "Open" : "not Open") +
                    (c->aborted() ? ", aborted" : "");
        c->abort(false);
        c.reset();
    });
    ::close(sv[1]);
    removeRecorders();
    if (!opened) return;
    const bool defect = openedOk && rr == nullptr;
    expectFixed("WS-NEW-1", defect,
                      std::string("Opened ") + (openedOk ? "succeeded" : "failed") + ", reqRead: " +
                          (rr ? describeResult(rr) : "no answer within 500 ms") + ", " + connState);
}

// --- WS-21 ---------------------------------------------------------------------------------

std::vector<std::string> g_resumed;   // "ok" / "err"

void* recordResumeEval(void* args[]) {
    HPointer task = dec(args[0]);
    auto* t = static_cast<Elm::Task*>(Allocator::instance().resolve(task));
    g_resumed.push_back(t->ctor == alloc::Task_Succeed ? "ok" : "err");
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

// fromWire / toWire stand-ins: never called here (no data flows), the pairs only store them.
void* identityEval(void* args[]) { return args[0]; }

HPointer nativeClosure1(EvalFunction fn) { return alloc::allocClosureK(fn, 1, PK_Boxed); }

// The `captured` of wsOpenBody for server handshake `hsId`: status 101, no headers, server role, whole
// mode, maxMessage 1 MiB, no heartbeat, close timeout 30 s, no deflate.
HPointer openCaptured(int64_t hsId, HPointer& fromWire, HPointer& toWire) {
    HPointer resp = alloc::listNil(), first = alloc::listNil(), p1 = alloc::listNil(), p2 = alloc::listNil();
    HPointer ours = alloc::listNil(), peers = alloc::listNil(), p3 = alloc::listNil(), params = alloc::listNil();
    HPointer fns = alloc::listNil();
    Elm::StackRootGuard g({&resp, &first, &p1, &p2, &ours, &peers, &p3, &params, &fns, &fromWire, &toWire});
    resp = alloc::tuple2(alloc::unboxedInt(101), alloc::boxed(alloc::listNil()), 0x1);
    first = alloc::tuple2(alloc::unboxedInt(hsId), alloc::boxed(resp), 0x1);
    p1 = alloc::tuple3(alloc::unboxedInt(1), alloc::unboxedInt(1), alloc::unboxedInt(1 << 20), 0x15);
    p2 = alloc::tuple3(alloc::unboxedInt(0), alloc::unboxedInt(0), alloc::unboxedInt(30000), 0x15);
    ours = alloc::tuple2(alloc::boxed(alloc::elmFalse()), alloc::unboxedInt(15), 0x4);
    peers = alloc::tuple2(alloc::boxed(alloc::elmFalse()), alloc::unboxedInt(15), 0x4);
    p3 = alloc::tuple3(alloc::unboxedInt(-1), alloc::boxed(ours), alloc::boxed(peers), 0x1);
    params = alloc::tuple3(alloc::boxed(p1), alloc::boxed(p2), alloc::boxed(p3), 0);
    fns = alloc::tuple2(alloc::boxed(fromWire), alloc::boxed(toWire), 0);
    return alloc::tuple3(alloc::boxed(first), alloc::boxed(params), alloc::boxed(fns), 0);
}

// An `open` on a server handshake whose connection has gone (the watch-mode HoldProtocol of an
// Http.Server upgrade aborted it): the Task fails, and nothing of the WebSocket may stay behind.
void testWsFailedOpenLeavesEntry() {
    std::printf("websocket/failed-open-leaves-no-entry-or-stream-pairs\n");
    resetQueues();
    ensureWsTables();   // the real dispatch functions (onOpened) from here on
    int sv[2];
    CHECK(::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) == 0);
    CHECK(setNonBlocking(sv[0]) == 0);
    std::shared_ptr<Conn> c;
    onReactor([&] {
        c = Conn::makeAccepted(sv[0], true, makePlainTransport(sv[0]));
        CHECK(IoReactor::instance().add(c, sv[0]) != 0);
        c->beginServer(0, [](Conn&, bool ok) { CHECK(ok); });
        c->setProtocol(std::make_unique<HoldProtocol>([] {}), std::string());
    });
    const int64_t hsId = wsTablesAddServerHandshake(c, kNoHold);
    // The peer resets; watch mode aborts the connection before `open` runs.
    onReactor([&] { c->abort(false); });
    const size_t socketsBefore = wsTables().sockets.size();
    const size_t streamsBefore = streamTable().size();
    g_resumed.clear();
    {
        HPointer fromWire = alloc::listNil(), toWire = alloc::listNil(), cap = alloc::listNil(),
                 resume = alloc::listNil();
        Elm::StackRootGuard g({&fromWire, &toWire, &cap, &resume});
        fromWire = nativeClosure1(&identityEval);
        toWire = nativeClosure1(&identityEval);
        cap = openCaptured(hsId, fromWire, toWire);
        resume = nativeClosure1(&recordResumeEval);
        wsOpenBody(cap, resume);
    }
    for (int i = 0; i < 400 && g_resumed.empty(); ++i) {
        wsEventsDrain();
        if (g_resumed.empty()) sleepMs(5);
    }
    CHECK_MSG(g_resumed.size() == 1 && g_resumed[0] == "err",
              "open on a gone connection did not fail: " + (g_resumed.empty() ? std::string("not resumed") : g_resumed[0]));
    // The pairs are erased once their channels' requests in flight (the readable's first read) have been answered,
    // which the channel drain dispatches; give that up to 2 s.
    size_t socketsAfter = 0, streamsAfter = 0;
    for (int i = 0; i < 400; ++i) {
        channelDrain();
        wsEventsDrain();
        socketsAfter = wsTables().sockets.size();
        streamsAfter = streamTable().size();
        if (socketsAfter <= socketsBefore && streamsAfter <= streamsBefore) break;
        sleepMs(5);
    }
    onReactor([&] { c.reset(); });
    ::close(sv[1]);
    if (g_resumed.size() != 1 || g_resumed[0] != "err") return;
    const bool defect = socketsAfter > socketsBefore || streamsAfter > streamsBefore;
    expectFixed("WS-21", defect,
           "after the failed open: " + std::to_string(socketsAfter - socketsBefore) + " WsEntry and " +
               std::to_string(streamsAfter - streamsBefore) + " stream pairs left");
}

int scenarioWsCoreAndOpenPath() {
    initCoreRuntime();
    testWsCoreHeartbeatResume();
    testWsCoreCloseWriteFails();
    testWsCoreLateCloseAfterAbnormalEnd();
    testWsCoreSingleCloseFrame();
    testWsOpenWriteFails();
    testWsFailedOpenLeavesEntry();   // last: it installs the WebSocket tables' dispatch functions
    return CoreTest::g_failures == 0 ? 0 : 1;
}

}  // namespace

void runWebSocketTests() {
    testWsRoleMismatch();
    std::printf("websocket/core-and-open-path checks (child)\n");
    auto r = ChildScenario::runChildScenario("websocket/core-and-open-path", {}, 60000);
    std::fputs(r.out.c_str(), stdout);   // the child's own output, one line per check of a fixed bug
    int checks = 0;
    for (const char* tag : {" ok: ", " FAILED: "}) {
        for (size_t p = r.out.find(tag); p != std::string::npos; p = r.out.find(tag, p + 1)) ++checks;
    }
    CHECK_MSG(r.ok(), r.describe() + "; stderr: " + r.err);
    CHECK_MSG(checks == 8, "expected 8 checks of fixed bugs in the child, got " + std::to_string(checks));
}

void registerWebSocketScenarios() {
    ChildScenario::add("websocket/role-mismatch", scenarioRoleMismatch);
    ChildScenario::add("websocket/core-and-open-path", scenarioWsCoreAndOpenPath);
}
