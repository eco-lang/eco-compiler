//===- Stream.cpp - eco/system stream table, pump and kernel bodies -------===//
//
// plans/eco-system-library.md §3.5 (normative semantics table) and B.2.
//
//   * The StreamTable is a T5 Registry (main thread only, G1/G9).
//   * Bodies follow G2/G3: they read every input out of the heap first, act
//     on the table (and, for channel kinds, queue POD channel requests), and
//     only then allocate results.
//   * read/write/enqueue/closeWritable are T9 operations: they complete at
//     once when they can and otherwise park a resume token on the pair.
//     In-memory parks hold no pendingAsync; channel requests hold one each
//     (keep-alive rule, §3.4), released by whoever completes the token.
//   * Completions issued from a binding body only enqueue the resumed
//     process (resumeEvaluator); the channel drain (ChannelDrain.cpp) calls
//     Scheduler::drain() once after dispatching (T9).
//   * After any allocation a StreamPair* may only be reused if nothing can
//     have erased it; every loop below re-fetches the pair by id (G11).
//   * Pumps run from one work list (the driver): pumpStream() marks a pair
//     dirty and, unless a driver is already running, drains the list. Pipes
//     (StreamPipe.cpp) are items on the same list, so a chain of pipes is
//     driven iteratively, never recursively.
//   * Custom pairs call the Elm action closure inside pump() (G11): fn,
//     state, value and result are rooted across the call; the written value
//     is popped off writeQ first, so the pair is consistent if the call were
//     to re-enter the table; the pair is re-fetched after the call; the
//     result tuple is decoded in a non-allocating scope, and each output is
//     moved into readQ (scanned) right after it is read or boxed.
//   * Codec pairs copy the input out of the heap, run the C++ engine
//     (StreamCodec.cpp), then allocate the outputs one by one, each stored
//     into readQ immediately (G3).
//
// Templates used: T4 (Bytes out), T5 (registry), T9 (park / complete),
// G10 via AsyncRelease (channel results), G11 (Custom action calls).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Stream/Stream.hpp"
#include "eco-system/Stream/StreamTable.hpp"

#include "eco-system/Core/AsyncRelease.hpp"
#include "eco-system/Core/FdChannel.hpp"

#include "allocator/StringOps.hpp"

#include <cerrno>
#include <algorithm>
#include <cstring>
#include <deque>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#ifndef _WIN32
#include <fcntl.h>
#include <unistd.h>
#endif

namespace Eco::System {

namespace {

constexpr const char* kWritableClosed = "WritableStream is closed";
constexpr const char* kTerminated = "TransformStream has been terminated";
constexpr size_t kChannelReadChunk = 64 * 1024;

// Request ids for channel requests that have no resume of their own.
// Disjoint from Scheduler resume tokens, which count up from 1. Main thread.
uint64_t g_nextSyntheticToken = uint64_t{1} << 62;

// ChannelId → pair id for ChannelSource/ChannelSink pairs. Validated on use
// (the pair must still exist and own that channel), so stale entries left
// by an erase or a heap reset are harmless. Main thread only.
std::unordered_map<uint64_t, int64_t>& channelPairs() {
    static auto* m = new std::unordered_map<uint64_t, int64_t>();   // leaky (§3.4)
    return *m;
}

std::string describeErrno(int err) {
    const char* m = std::strerror(err);   // main thread only (G1)
    return std::string(errnoName(err)) + ": " + (m ? m : "");
}

// A Bytes value holding `b` (T4); empty → the empty-Bytes constant (HEAP_071).
HPointer makeBytes(const std::string& b) {
    if (b.empty()) return alloc::emptyBytes();
    alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(b.size());
    std::memcpy(bb.bytes, b.data(), b.size());   // no allocation in between (G8)
    return bb.hp;
}

// --- Payload decoding (no allocation) --------------------------------------

int64_t payloadInt(HPointer captured) {
    return static_cast<ElmInt*>(Allocator::instance().resolve(captured))->value;
}

// tuple2( boxed x, unboxed Int id ), mask 0x4.
void payloadBoxedAndId(HPointer captured, HPointer& x, int64_t& id) {
    Tuple2* t = asTuple2(captured);
    x = t->a.p;
    id = t->b.i;
}

// --- Completion (T9) --------------------------------------------------------

} // namespace

// Completes parked `token` with Task.succeed `value`, then releases its
// pendingAsync count if `counted`. A token whose resume is gone (orphaned)
// only releases its count. `value` is rooted here across the allocations.
void streamCompleteOk(uint64_t token, bool counted, HPointer value) {
    auto& s = Scheduler::instance();
    HPointer resume = s.takePendingResume(token);   // no allocation
    if (!alloc::isNil(resume)) {
        HPointer task = alloc::listNil();
        Elm::StackRootGuard g(&resume, &value, &task);
        task = succeed(value);
        Scheduler::callClosure1(resume, task);
    }
    if (counted) s.decrementPendingAsync();
}

// Completes parked `token` with Task.fail ( kind, reason ).
void streamCompleteErr(uint64_t token, bool counted, int kind, const std::string& reason) {
    auto& s = Scheduler::instance();
    HPointer resume = s.takePendingResume(token);
    if (!alloc::isNil(resume)) {
        HPointer task = alloc::listNil();
        Elm::StackRootGuard g(&resume, &task);
        task = failSErr(kind, reason);
        Scheduler::callClosure1(resume, task);
    }
    if (counted) s.decrementPendingAsync();
}

uint64_t streamSyntheticToken() { return g_nextSyntheticToken++; }

namespace {

void completeOk(uint64_t token, bool counted, HPointer value) {
    streamCompleteOk(token, counted, value);
}

void completeErr(uint64_t token, bool counted, int kind, const std::string& reason) {
    streamCompleteErr(token, counted, kind, reason);
}

// The immediate path of a T9 body: resume the running binding now.
// `resume` is the body's parameter, rooted by ECO_SYSTEM_ASYNC_GUARD.
HPointer resumeNow(HPointer& resume, HPointer task) {
    Elm::StackRootGuard g(&task);
    Scheduler::callClosure1(resume, task);
    return alloc::unit();
}

struct TokenRef {
    uint64_t token;
    bool counted;
};

// Fails every token in `toks` with Cancelled `reason` (POD in, so no heap
// word is held across the allocations).
void failAll(const std::vector<TokenRef>& toks, const std::string& reason) {
    for (const auto& t : toks) completeErr(t.token, t.counted, kSErrCancelled, reason);
}

// Collects the tokens of queued in-memory writes (and the close) of `p`
// and empties the write side. Channel writes are in flight: they complete
// through the channel dispatch instead, so they stay.
void drainWriteSide(StreamPair* p, std::vector<TokenRef>& out) {
    if (p->kind != StreamKind::ChannelSink) {
        for (auto& pw : p->writeQ)
            if (pw.token) out.push_back({pw.token, pw.counted});
        p->writeQ.clear();
    }
    for (auto& pw : p->waitingForRoom)
        if (pw.token) out.push_back({pw.token, pw.counted});
    p->waitingForRoom.clear();
    p->writeLock = false;
    if (p->closeToken && p->kind != StreamKind::ChannelSink) {
        out.push_back({p->closeToken, p->closeCounted});
        p->closeToken = 0;
        p->closeCounted = false;
    }
}

// Sets both sides Errored with `reason` (cancelWritable, a custom Cancel,
// a codec failure): empties both queues and collects every token to fail.
void errorPair(StreamPair* p, const std::string& reason, std::vector<TokenRef>& out) {
    p->w = WState::Errored;
    p->wReason = reason;
    p->r = RState::Errored;
    p->rReason = reason;
    p->readQ.clear();
    drainWriteSide(p, out);
    if (p->parkedReadToken && p->kind != StreamKind::ChannelSource) {
        out.push_back({p->parkedReadToken, p->parkedReadCounted});
        p->parkedReadToken = 0;
        p->parkedReadCounted = false;
        p->readLock = false;
    }
}

// A custom Close (WHATWG TransformStreamDefaultControllerTerminate): the
// readable closes once readQ drains; the writable errors, failing every
// write still queued (and a pending close).
void terminatePair(StreamPair* p, std::vector<TokenRef>& out) {
    if (p->w == WState::Open || p->w == WState::Closing) {
        p->w = WState::Errored;
        p->wReason = kTerminated;
        drainWriteSide(p, out);
    }
    if (p->r == RState::Open) p->r = RState::Closed;
}

void maybeErase(int64_t id) {
    auto& t = streamTable();
    StreamPair* p = t.find(id);
    if (!p || p->pinned || p->pipeRefs > 0) return;
    if (p->w != WState::Closed || p->r != RState::Closed) return;
    if (!p->readQ.empty() || !p->writeQ.empty() || !p->waitingForRoom.empty()) return;
    if (p->parkedReadToken || p->closeToken) return;
    if (p->channel) channelPairs().erase(p->channel->id());
    t.erase(id);
}

void channelDispatch(ChannelResult& r);

int64_t insertChannelPair(StreamKind kind, ByteChannel* channel) {
    auto& t = streamTable();
    StreamPair p;
    p.kind = kind;
    p.channel.reset(channel);
    if (kind == StreamKind::ChannelSource) {
        p.w = WState::Closed;   // no writable side
    } else {
        p.r = RState::Closed;   // no readable side
    }
    uint64_t chan = channel->id();
    int64_t id = t.insert(std::move(p));
    channelPairs()[chan] = id;
    return id;
}

} // namespace

// ---------------------------------------------------------------------------
// The table
// ---------------------------------------------------------------------------

Registry<StreamPair>& streamTable() {
    static auto* t = new Registry<StreamPair>("eco-system-streams");   // leaky (§3.4)
    static bool dispatchSet = false;
    if (!dispatchSet) {
        dispatchSet = true;
        setChannelDispatch(&channelDispatch);
    }
    return *t;
}

void pinStream(int64_t id) {
    if (StreamPair* p = streamTable().find(id)) p->pinned = true;
}

// ---------------------------------------------------------------------------
// pump() — §3.5. One action per iteration; the pair is re-fetched each time
// because a completion allocates and a Custom step calls Elm (G11).
// ---------------------------------------------------------------------------

namespace {

// Completes an accepted write once its value has been transformed: succeed,
// or fail with `reason`. Enqueued values carry no token (already done).
void finishWrite(const PendingWrite& pw, bool ok, const std::string& reason) {
    if (!pw.token || !pw.completeOnTransform) return;
    if (ok) completeOk(pw.token, pw.counted, alloc::unit());
    else completeErr(pw.token, pw.counted, kSErrCancelled, reason);
}

// Allocates each codec output and moves it into readQ straight away (the
// queue is scanned, so nothing fresh is held across the next allocation).
void pushCodecOutputs(int64_t id, const std::vector<std::string>& outs, bool asString) {
    for (const auto& s : outs) {
        HPointer v = asString ? alloc::allocStringFromUTF8(s) : makeBytes(s);
        StreamPair* p = streamTable().find(id);
        if (!p) return;
        p->readQ.push_back(enc(v));
    }
}

// The UTF-16 units of a String, copied out of the heap (no allocation).
std::u16string stringUnits(HPointer s) {
    if (alloc::isEmptyString(s)) return {};
    return StringOps::toStdU16String(Allocator::instance().resolve(s));
}

// Moves the elements of the Elm list `outs` into readQ, boxing unboxed
// Int/Float/Char elements (G7: values handed to Elm through `read` are
// boxed, the polymorphic ABI). The cursor roots the spine.
void pushListOutputs(int64_t id, HPointer outs) {
    alloc::RootedListCursor c(outs);
    Unboxable head;
    u8 kind = 0;
    while (c.read(head, kind)) {
        HPointer v = kind == 0 ? head.p : alloc::boxElement(head, kind);
        StreamPair* p = streamTable().find(id);
        if (!p) return;
        p->readQ.push_back(enc(v));   // no allocation since `v` was read/boxed
        c.advance();
    }
}

// Custom step (§3.5 pump() 3, G11). `pw` has already left writeQ.
void transformCustom(int64_t id, const PendingWrite& pw) {
    HPointer fn = alloc::listNil(), st = alloc::listNil();
    {
        StreamPair* p = streamTable().find(id);
        fn = dec(p->customFnEnc);
        st = dec(p->customStateEnc);
    }
    HPointer v = dec(pw.valueEnc);
    HPointer res = alloc::listNil();
    Elm::StackRootGuard g(&fn, &st, &v, &res);
    res = Scheduler::callClosure2(fn, st, v);   // may GC; G11

    // Decode ( Int ctor, state, ( List out, String reason ) ) without
    // allocating; keep only rooted handles and plain copies.
    int64_t ctor = 0;
    Unboxable stSlot;
    u32 stKind = 0;
    HPointer outs = alloc::listNil();
    std::string reason;
    {
        Tuple3* t3 = asTuple3(res);
        u32 ub = t3->header.unboxed;
        if (Elm::tupleFieldKind(ub, 0) == 1) {
            ctor = t3->a.i;
        } else {
            ctor = static_cast<ElmInt*>(Allocator::instance().resolve(t3->a.p))->value;
        }
        stSlot = t3->b;
        stKind = Elm::tupleFieldKind(ub, 1);
        Tuple2* inner = asTuple2(t3->c.p);
        outs = inner->a.p;
        if (ctor == 3) reason = toStdString(inner->b.p);
    }
    Elm::StackRootGuard g2(&outs);

    // The new state (boxed if the tuple stored it unboxed).
    HPointer newState = stKind == 0 ? stSlot.p : alloc::boxElement(stSlot, stKind);
    StreamPair* p = streamTable().find(id);   // re-resolve after the call
    if (!p) {
        finishWrite(pw, false, kWritableClosed);
        return;
    }
    p->customStateEnc = enc(newState);

    std::vector<TokenRef> toFail;
    std::string failReason;
    switch (ctor) {
    case 0:   // UpdateState
        break;
    case 1:   // Send (may overfill readQ)
        if (p->r == RState::Open) pushListOutputs(id, outs);
        break;
    case 2:   // Close
        if (p->r == RState::Open) pushListOutputs(id, outs);
        p = streamTable().find(id);
        if (p) terminatePair(p, toFail);
        failReason = kTerminated;
        break;
    default:  // 3 Cancel
        errorPair(p, reason, toFail);
        failReason = reason;
        break;
    }
    // WHATWG: the write whose transform ended or errored the stream still
    // succeeds; the writes queued behind it fail.
    finishWrite(pw, true, "");
    failAll(toFail, failReason);
}

// Codec step (§3.5 pump() 4, G3). `pw` has already left writeQ.
void transformCodec(int64_t id, const PendingWrite& pw) {
    StreamPair* p = streamTable().find(id);
    CodecState& codec = *p->codec;            // off-heap; stable address
    std::string bytes;
    std::u16string units;
    if (codecTakesString(codec)) units = stringUnits(dec(pw.valueEnc));
    else bytes = toStdBytes(dec(pw.valueEnc));
    std::vector<std::string> outs;
    std::string err = codecTransform(codec, bytes, units, outs);
    bool asString = codecMakesString(codec);
    if (!err.empty()) {
        std::vector<TokenRef> toFail;
        errorPair(p, err, toFail);
        finishWrite(pw, false, err);
        failAll(toFail, err);
        return;
    }
    if (p->r == RState::Open) pushCodecOutputs(id, outs, asString);
    finishWrite(pw, true, "");
}

// One pump of an in-memory pair (Identity, Custom, Codec). Channel kinds
// are driven by their channel results.
void pumpCore(int64_t id) {
    auto& t = streamTable();
    for (;;) {
        StreamPair* p = t.find(id);
        if (!p) return;
        if (p->kind == StreamKind::ChannelSource || p->kind == StreamKind::ChannelSink) return;

        // 1. A parked reader takes the head of readQ directly.
        if (p->parkedReadToken && !p->readQ.empty()) {
            uint64_t tok = p->parkedReadToken;
            bool counted = p->parkedReadCounted;
            p->parkedReadToken = 0;
            p->parkedReadCounted = false;
            p->readLock = false;
            HPointer v = dec(p->readQ.front());
            p->readQ.pop_front();
            Elm::StackRootGuard g(&v);
            completeOk(tok, counted, v);
            continue;
        }

        // 2. Transform one value. A waiting reader (a parked read, or a
        //    pipe whose destination has room) opens the gate even when
        //    readQ is at capacity 0 (rendezvous).
        bool demand = p->readQ.empty() && (p->parkedReadToken || streamPipeDemand(p));
        if (!p->writeQ.empty() && p->r == RState::Open &&
            (p->readQ.size() < p->readCap || demand)) {
            PendingWrite pw = p->writeQ.front();
            p->writeQ.pop_front();
            switch (p->kind) {
            case StreamKind::Custom:
                transformCustom(id, pw);
                break;
            case StreamKind::Codec:
                transformCodec(id, pw);
                break;
            default:   // Identity
                p->readQ.push_back(pw.valueEnc);   // no allocation: still scanned
                finishWrite(pw, true, "");
                break;
            }
            continue;
        }

        // 3. Room in writeQ: admit a write that was waiting, releasing the
        //    lock once nothing waits. An enqueue completes on admission.
        if (!p->waitingForRoom.empty() && p->writeQ.size() < p->writeCap) {
            PendingWrite pw = p->waitingForRoom.front();
            p->waitingForRoom.pop_front();
            if (p->waitingForRoom.empty()) p->writeLock = false;
            uint64_t completeNow = 0;
            bool counted = false;
            if (!pw.completeOnTransform) {
                completeNow = pw.token;
                counted = pw.counted;
                pw.token = 0;
                pw.counted = false;
            }
            p->writeQ.push_back(pw);
            if (completeNow) completeOk(completeNow, counted, alloc::unit());
            continue;
        }

        // 4. A pending close finishes once every accepted write is through.
        //    A codec flushes first (Z_FINISH / carried UTF-8 state).
        if (p->w == WState::Closing && p->writeQ.empty() && p->waitingForRoom.empty()) {
            if (p->kind == StreamKind::Codec && p->codec) {
                std::vector<std::string> outs;
                std::string err = codecFlush(*p->codec, outs);
                bool asString = codecMakesString(*p->codec);
                if (!err.empty()) {
                    std::vector<TokenRef> toFail;
                    errorPair(p, err, toFail);   // fails the close too
                    failAll(toFail, err);
                    continue;
                }
                if (p->r == RState::Open) pushCodecOutputs(id, outs, asString);
                p = t.find(id);
                if (!p) return;
            }
            p->w = WState::Closed;
            if (p->r == RState::Open) p->r = RState::Closed;
            uint64_t tok = p->closeToken;
            bool counted = p->closeCounted;
            p->closeToken = 0;
            p->closeCounted = false;
            if (tok) completeOk(tok, counted, alloc::unit());
            continue;
        }

        // 5. A parked reader on a drained, terminal readable.
        if (p->parkedReadToken && p->readQ.empty() && p->r != RState::Open) {
            uint64_t tok = p->parkedReadToken;
            bool counted = p->parkedReadCounted;
            p->parkedReadToken = 0;
            p->parkedReadCounted = false;
            p->readLock = false;
            if (p->r == RState::Closed) {
                completeErr(tok, counted, kSErrClosed, "");
            } else {
                std::string reason = p->rReason;
                completeErr(tok, counted, kSErrCancelled, reason);
            }
            continue;
        }
        break;
    }
}

// The driver's work list: pair ids (> 0) and pipe ids (stored negated).
// Main thread only.
std::deque<int64_t> g_work;
bool g_driving = false;

void schedule(int64_t item) {
    if (std::find(g_work.begin(), g_work.end(), item) == g_work.end()) g_work.push_back(item);
}

void drive() {
    if (g_driving) return;
    g_driving = true;
    try {
        while (!g_work.empty()) {
            int64_t item = g_work.front();
            g_work.pop_front();
            if (item < 0) {
                streamRunPipe(-item);
                continue;
            }
            pumpCore(item);
            if (StreamPair* p = streamTable().find(item)) {
                if (p->pipeOutId) schedule(-p->pipeOutId);
                if (p->pipeInId) schedule(-p->pipeInId);
            }
            maybeErase(item);
        }
    } catch (...) {
        g_work.clear();
        g_driving = false;
        throw;
    }
    g_driving = false;
}

} // namespace

void pumpStream(int64_t id) {
    schedule(id);
    drive();
}

void streamSchedulePipe(int64_t pipeId) {
    schedule(-pipeId);
    drive();
}

// ---------------------------------------------------------------------------
// Channel results (main thread, from the Core channel drain; it calls
// Scheduler::drain() once afterwards). Every channel request holds one
// pendingAsync count, released here on every path (G10).
// ---------------------------------------------------------------------------

namespace {

void channelDispatch(ChannelResult& r) {
    auto& t = streamTable();
    int64_t id = 0;
    StreamPair* p = nullptr;
    {
        auto it = channelPairs().find(r.channelId);
        if (it != channelPairs().end()) {
            id = it->second;
            p = t.find(id);
            if (p && (!p->channel || p->channel->id() != r.channelId)) p = nullptr;
        }
    }
    auto& s = Scheduler::instance();

    switch (r.op) {
    case ChannelResult::Op::Read: {
        AsyncRelease release;
        if (!p || r.token == 0 || p->parkedReadToken != r.token) {
            (void)s.takePendingResume(r.token);   // orphaned: drop it
            return;
        }
        p->parkedReadToken = 0;
        p->parkedReadCounted = false;
        p->readLock = false;
        if (p->pipeOutId) {
            // A pipe's read (synthetic token, no resume): the chunk goes to
            // readQ, where the pipe picks it up.
            if (r.err) {
                if (p->r == RState::Open) {
                    p->r = RState::Errored;
                    p->rReason = r.reason.empty() ? describeErrno(r.err) : r.reason;
                }
                p->channel->shutdown();
            } else if (r.eof) {
                if (p->r == RState::Open) p->r = RState::Closed;
                p->channel->close(0);
            } else if (!r.bytes.empty()) {
                HPointer bytes = makeBytes(r.bytes);
                if (StreamPair* q = t.find(id)) q->readQ.push_back(enc(bytes));   // no allocation in between
            }
            pumpStream(id);
            return;
        }
        if (r.err) {
            if (p->r == RState::Open) {
                p->r = RState::Errored;
                p->rReason = r.reason.empty() ? describeErrno(r.err) : r.reason;
            }
            int kind = p->r == RState::Closed ? kSErrClosed : kSErrCancelled;
            std::string reason = p->r == RState::Errored ? p->rReason : std::string();
            p->channel->shutdown();
            completeErr(r.token, false, kind, reason);
        } else if (r.eof) {
            p->r = RState::Closed;
            p->channel->close(0);   // release the fd (never 0–2); uncounted
            completeErr(r.token, false, kSErrClosed, "");
        } else {
            HPointer bytes = makeBytes(r.bytes);
            Elm::StackRootGuard g(&bytes);
            completeOk(r.token, false, bytes);
        }
        pumpStream(id);
        return;
    }

    case ChannelResult::Op::Write: {
        AsyncRelease release;
        bool found = false;
        if (p) {
            for (auto it = p->writeQ.begin(); it != p->writeQ.end(); ++it) {
                if (it->token == r.token) {
                    p->writeQ.erase(it);
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            (void)s.takePendingResume(r.token);
            return;
        }
        if (r.err) {
            if (p->w != WState::Errored) {
                p->w = WState::Errored;
                p->wReason = r.reason.empty() ? describeErrno(r.err) : r.reason;
                p->r = RState::Errored;
                p->rReason = p->wReason;
                p->channel->shutdown();
            }
            std::string reason = p->wReason;
            completeErr(r.token, false, kSErrCancelled, reason);
        } else {
            completeOk(r.token, false, alloc::unit());
        }
        pumpStream(id);
        return;
    }

    case ChannelResult::Op::Close: {
        if (r.token == 0) return;   // a source's own release: not counted
        AsyncRelease release;
        if (!p || p->closeToken != r.token) {
            (void)s.takePendingResume(r.token);
            return;
        }
        p->closeToken = 0;
        p->closeCounted = false;
        if (p->w == WState::Errored) {
            std::string reason = p->wReason;
            completeErr(r.token, false, kSErrCancelled, reason);
        } else if (r.err) {
            p->w = WState::Errored;
            p->wReason = r.reason.empty() ? describeErrno(r.err) : r.reason;
            std::string reason = p->wReason;
            completeErr(r.token, false, kSErrCancelled, reason);
        } else {
            p->w = WState::Closed;
            if (p->r == RState::Open) p->r = RState::Closed;
            completeOk(r.token, false, alloc::unit());
        }
        pumpStream(id);
        return;
    }
    }
}

} // namespace

// ---------------------------------------------------------------------------
// C++ API (B.2)
// ---------------------------------------------------------------------------

int64_t createChannelSource(ByteChannel* channel) {
    return insertChannelPair(StreamKind::ChannelSource, channel);
}

int64_t createChannelSink(ByteChannel* channel) {
    return insertChannelPair(StreamKind::ChannelSink, channel);
}

namespace {

// The fd the channel will own: `fd` itself when the stream owns it (or for
// stdio, which FdChannel never closes), otherwise an O_CLOEXEC duplicate.
int channelFd(int fd, bool owns) {
#ifdef _WIN32
    (void)owns;
    return fd;
#else
    if (owns || fd <= 2) return fd;
    int d = ::fcntl(fd, F_DUPFD_CLOEXEC, 3);
    return d;
#endif
}

} // namespace

int64_t createFdSource(int fd, bool owns) {
    (void)streamTable();   // dispatch installed before the channel exists
    int cfd = channelFd(fd, owns);
    if (cfd < 0) return 0;
    return createChannelSource(new FdChannel(cfd));
}

int64_t createFdSink(int fd, bool owns) {
    (void)streamTable();
    int cfd = channelFd(fd, owns);
    if (cfd < 0) return 0;
    return createChannelSink(new FdChannel(cfd));
}

// ---------------------------------------------------------------------------
// Kernel bodies (B.2)
// ---------------------------------------------------------------------------

// identity : Int -> Int -> Task Never Int — payload tuple2(readCap, writeCap), mask 0x5.
HPointer streamIdentityBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        int64_t readCap, writeCap;
        {
            Tuple2* tp = asTuple2(captured);
            readCap = tp->a.i;
            writeCap = tp->b.i;
        }
        StreamPair p;
        p.kind = StreamKind::Identity;
        p.readCap = static_cast<size_t>(readCap < 1 ? 1 : readCap);
        p.writeCap = static_cast<size_t>(writeCap < 1 ? 1 : writeCap);
        int64_t id = streamTable().insert(std::move(p));
        return succeedInt(id);
    )
}

// custom : (s -> a -> ( Int, s, ( List b, String ) )) -> s -> Int -> Int -> Task Never Int
// payload tuple2( boxed tuple2(fn, state) mask 0, boxed tuple2(readCap, writeCap) mask 0x5 ), mask 0.
// The fn and state words go straight into the (scanned) table entry before
// the result allocates.
HPointer streamCustomBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        StreamPair p;
        p.kind = StreamKind::Custom;
        {
            Tuple2* outer = asTuple2(captured);
            HPointer fnState = outer->a.p;
            HPointer caps = outer->b.p;
            Tuple2* fs = asTuple2(fnState);
            p.customFnEnc = enc(fs->a.p);
            p.customStateEnc = enc(fs->b.p);
            Tuple2* c = asTuple2(caps);
            p.readCap = static_cast<size_t>(c->a.i < 0 ? 0 : c->a.i);
            p.writeCap = static_cast<size_t>(c->b.i < 1 ? 1 : c->b.i);
        }
        int64_t id = streamTable().insert(std::move(p));
        return succeedInt(id);
    )
}

namespace {

// A Codec pair (capacities 1/1: see Stream.elm, the codec constructors).
HPointer insertCodecPair(CodecPtr codec) {
    StreamPair p;
    p.kind = StreamKind::Codec;
    p.readCap = 1;
    p.writeCap = 1;
    p.codec = std::move(codec);
    int64_t id = streamTable().insert(std::move(p));
    return succeedInt(id);
}

} // namespace

// textEncoder : Task Never Int — payload ().
HPointer streamTextEncoderBody(HPointer) {
    ECO_SYSTEM_BODY_GUARD(Never,
        return insertCodecPair(newTextEncoder());
    )
}

// textDecoder : Task Never Int — payload ().
HPointer streamTextDecoderBody(HPointer) {
    ECO_SYSTEM_BODY_GUARD(Never,
        return insertCodecPair(newTextDecoder());
    )
}

// compressor : Int -> Task Never Int — payload: boxed Int algorithm
// (0 gzip, 1 deflate, 2 deflate-raw).
HPointer streamCompressorBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        int algorithm = static_cast<int>(payloadInt(captured));
        return insertCodecPair(newZlibCodec(/*compress=*/true, algorithm));
    )
}

// decompressor : Int -> Task Never Int — payload: boxed Int algorithm.
HPointer streamDecompressorBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        int algorithm = static_cast<int>(payloadInt(captured));
        return insertCodecPair(newZlibCodec(/*compress=*/false, algorithm));
    )
}

// read : Int -> Task SErr a — payload: boxed Int id.
HPointer streamReadBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(SErr, resume, token, counted,
        int64_t id = payloadInt(captured);
        auto& sched = Scheduler::instance();
        StreamPair* p = streamTable().find(id);
        if (!p) return resumeNow(resume, failSErr(kSErrClosed, ""));
        if (streamReadLocked(p)) return resumeNow(resume, failSErr(kSErrLocked, ""));
        if (!p->readQ.empty()) {
            HPointer v = dec(p->readQ.front());
            p->readQ.pop_front();
            Elm::StackRootGuard g(&v);
            pumpStream(id);                     // may complete writers (allocates)
            return resumeNow(resume, succeed(v));
        }
        if (p->r == RState::Closed) return resumeNow(resume, failSErr(kSErrClosed, ""));
        if (p->r == RState::Errored) {
            std::string reason = p->rReason;
            return resumeNow(resume, failSErr(kSErrCancelled, reason));
        }
        // Park (T9).
        token = sched.registerPendingResume(resume);
        p->readLock = true;
        p->parkedReadToken = token;
        if (p->kind == StreamKind::ChannelSource) {
            sched.incrementPendingAsync();      // external IO keeps the program alive
            counted = true;
            p->parkedReadCounted = true;
            p->channel->requestRead(token, kChannelReadChunk);
        }
        pumpStream(id);
        return alloc::unit();
    )
}

namespace {

// write / enqueue : a -> Int -> Task SErr () — payload tuple2(boxed value, Int id), mask 0x4.
HPointer writeOrEnqueue(HPointer captured, HPointer& resume, uint64_t& token,
                        bool& counted, bool isEnqueue) {
    HPointer v = alloc::listNil();
    int64_t id = 0;
    payloadBoxedAndId(captured, v, id);
    auto& sched = Scheduler::instance();
    StreamPair* p = streamTable().find(id);
    if (!p) return resumeNow(resume, failSErr(kSErrCancelled, kWritableClosed));
    if (streamWriteLocked(p)) return resumeNow(resume, failSErr(kSErrLocked, ""));
    if (p->w == WState::Closing || p->w == WState::Closed) {
        return resumeNow(resume, failSErr(kSErrCancelled, kWritableClosed));
    }
    if (p->w == WState::Errored) {
        std::string reason = p->wReason;
        return resumeNow(resume, failSErr(kSErrCancelled, reason));
    }

    if (p->kind == StreamKind::ChannelSink) {
        std::string bytes = toStdBytes(v);       // G3: copy out first
        uint64_t req;
        if (isEnqueue) {
            req = g_nextSyntheticToken++;
        } else {
            token = sched.registerPendingResume(resume);
            req = token;
        }
        sched.incrementPendingAsync();
        if (!isEnqueue) counted = true;
        p->writeQ.push_back(PendingWrite{req, 0, true, true});
        p->channel->requestWrite(req, std::move(bytes));
        if (isEnqueue) return resumeNow(resume, succeedUnit());
        return alloc::unit();
    }

    if (p->kind == StreamKind::ChannelSource) {
        // A source has no writable side (unreachable from Elm).
        return resumeNow(resume, failSErr(kSErrCancelled, kWritableClosed));
    }

    // In-memory pair. No allocation between reading `v` and storing it.
    if (p->writeQ.size() < p->writeCap) {
        if (isEnqueue) {
            p->writeQ.push_back(PendingWrite{0, enc(v), false, false});
            pumpStream(id);
            return resumeNow(resume, succeedUnit());
        }
        token = sched.registerPendingResume(resume);
        p->writeQ.push_back(PendingWrite{token, enc(v), true, false});
        pumpStream(id);
        return alloc::unit();
    }
    // Full: wait for room, holding the write lock.
    token = sched.registerPendingResume(resume);
    p->writeLock = true;
    p->waitingForRoom.push_back(PendingWrite{token, enc(v), !isEnqueue, false});
    pumpStream(id);
    return alloc::unit();
}

} // namespace

HPointer streamWriteBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(SErr, resume, token, counted,
        return writeOrEnqueue(captured, resume, token, counted, /*isEnqueue=*/false);
    )
}

HPointer streamEnqueueBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(SErr, resume, token, counted,
        return writeOrEnqueue(captured, resume, token, counted, /*isEnqueue=*/true);
    )
}

// closeWritable : Int -> Task SErr () — payload: boxed Int id.
HPointer streamCloseWritableBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(SErr, resume, token, counted,
        int64_t id = payloadInt(captured);
        auto& sched = Scheduler::instance();
        StreamPair* p = streamTable().find(id);
        if (!p) return resumeNow(resume, failSErr(kSErrCancelled, kWritableClosed));
        if (streamWriteLocked(p)) return resumeNow(resume, failSErr(kSErrLocked, ""));
        if (p->w == WState::Closing || p->w == WState::Closed ||
            p->kind == StreamKind::ChannelSource) {
            return resumeNow(resume, failSErr(kSErrCancelled, kWritableClosed));
        }
        if (p->w == WState::Errored) {
            std::string reason = p->wReason;
            return resumeNow(resume, failSErr(kSErrCancelled, reason));
        }
        p->w = WState::Closing;
        if (p->kind == StreamKind::ChannelSink) {
            // Succeeds once the channel has written everything and released
            // the fd (never 0–2).
            token = sched.registerPendingResume(resume);
            sched.incrementPendingAsync();
            counted = true;
            p->closeToken = token;
            p->closeCounted = true;
            p->channel->close(token);
            return alloc::unit();
        }
        if (p->writeQ.empty() && p->waitingForRoom.empty() && p->kind != StreamKind::Codec) {
            p->w = WState::Closed;
            if (p->r == RState::Open) p->r = RState::Closed;
            pumpStream(id);                     // wakes a parked reader with Closed
            return resumeNow(resume, succeedUnit());
        }
        // Park until the queued writes are through (a codec also flushes).
        token = sched.registerPendingResume(resume);
        p->closeToken = token;
        pumpStream(id);
        return alloc::unit();
    )
}

void streamCancelReadableNow(int64_t id, const std::string& reason) {
    StreamPair* p = streamTable().find(id);
    if (!p) return;
    std::vector<TokenRef> toFail;
    if (p->r == RState::Open) p->r = RState::Closed;   // later reads give Closed
    p->readQ.clear();
    if (p->w == WState::Open || p->w == WState::Closing) {
        p->w = WState::Errored;
        p->wReason = reason;
        drainWriteSide(p, toFail);
    }
    if (p->kind == StreamKind::ChannelSource && p->channel) p->channel->shutdown();
    failAll(toFail, reason);                    // allocates: `p` is dead from here
    pumpStream(id);
}

void streamCancelWritableNow(int64_t id, const std::string& reason) {
    StreamPair* p = streamTable().find(id);
    if (!p) return;
    if (p->w == WState::Closed || p->w == WState::Errored) return;
    std::vector<TokenRef> toFail;
    errorPair(p, reason, toFail);               // reads give Cancelled reason
    if (p->kind == StreamKind::ChannelSink && p->channel) p->channel->shutdown();
    failAll(toFail, reason);
    pumpStream(id);
}

// cancelReadable : String -> Int -> Task SErr () — payload tuple2(reason, id), mask 0x4.
HPointer streamCancelReadableBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(SErr,
        HPointer reasonHP = alloc::listNil();
        int64_t id = 0;
        payloadBoxedAndId(captured, reasonHP, id);
        std::string reason = toStdString(reasonHP);   // G3
        StreamPair* p = streamTable().find(id);
        if (!p) return succeedUnit();
        if (streamReadLocked(p)) return failSErr(kSErrLocked, "");
        streamCancelReadableNow(id, reason);
        return succeedUnit();
    )
}

// cancelWritable : String -> Int -> Task SErr () — payload tuple2(reason, id), mask 0x4.
HPointer streamCancelWritableBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(SErr,
        HPointer reasonHP = alloc::listNil();
        int64_t id = 0;
        payloadBoxedAndId(captured, reasonHP, id);
        std::string reason = toStdString(reasonHP);
        StreamPair* p = streamTable().find(id);
        if (!p) return succeedUnit();
        if (streamWriteLocked(p)) return failSErr(kSErrLocked, "");
        streamCancelWritableNow(id, reason);
        return succeedUnit();
    )
}

// ---------------------------------------------------------------------------
// Strict UTF-8 (B5)
// ---------------------------------------------------------------------------

bool isValidUtf8(const std::string& s) {
    const auto* b = reinterpret_cast<const unsigned char*>(s.data());
    size_t n = s.size(), i = 0;
    while (i < n) {
        unsigned char c = b[i];
        if (c < 0x80) { ++i; continue; }
        size_t len;
        uint32_t cp;
        if (c >= 0xC2 && c <= 0xDF) { len = 2; cp = c & 0x1F; }
        else if (c >= 0xE0 && c <= 0xEF) { len = 3; cp = c & 0x0F; }
        else if (c >= 0xF0 && c <= 0xF4) { len = 4; cp = c & 0x07; }
        else return false;                      // continuation byte, C0/C1, F5..FF
        if (i + len > n) return false;          // truncated
        for (size_t k = 1; k < len; ++k) {
            unsigned char cc = b[i + k];
            if ((cc & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (cc & 0x3F);
        }
        if (len == 3 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))) return false;
        if (len == 4 && (cp < 0x10000 || cp > 0x10FFFF)) return false;
        i += len;
    }
    return true;
}

} // namespace Eco::System
