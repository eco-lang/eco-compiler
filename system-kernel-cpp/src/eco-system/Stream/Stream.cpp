//===- Stream.cpp - eco/system stream table, pump and kernel bodies -------===//
//
// How the stream table works. StreamTable.hpp describes pairs and pumping; this file rests on four further
// rules.
//
// Heap values and pair pointers. Calling Elm or allocating may run the collector, and calling Elm may
// re-enter a kernel that pumps and erases pairs. So a body reads every input out of the heap first, then
// acts on the table (and, for a channel pair, queues POD channel requests), and allocates its result last.
// A value taken out of a queue is rooted before the next allocation, a fresh value is stored into a scanned
// queue before the next allocation, and a `StreamPair*` is looked up again by id after any allocation or
// Elm call that could have erased the pair.
//
// Parking. A read, write, enqueue or close completes at once when it can, and otherwise parks the task's
// resume under a token kept on the pair. A park on an in-memory pair holds nothing, since only Elm code can
// complete it. A channel request is outside work, so it normally holds one liveness hold, named by its
// token, and the channel dispatch releases it on every path (with `HoldRelease`). An uncounted token
// (`streamUncountedToken`), for a mapped source's read-ahead and a subscription reader's kick, is not itself
// a hold; but a read-ahead requested while a pipe reads from the pair takes a separate hold, kept on the
// pair and released when the result arrives. A source's untokened close (token 0) holds nothing.
//
// Completion. Completing a token calls the parked resume closure, which only queues the resumed process.
// The channel drain that calls `channelDispatch` runs the scheduler once afterwards.
//
// Elm calls inside a pump. A Custom pair's action closure and a mapped pair's closures run in the middle of
// a pump. The value being written has left `writeQ` before the call, so the pair is consistent if the call
// re-enters the table; the closure, its arguments and its result are rooted across the call; and the
// result is decoded without allocating, each output moving into `readQ` as soon as it is read or boxed.
// A Codec pair copies its input off the heap, runs the C++ engine, and allocates its outputs one by one,
// storing each into `readQ` at once.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Stream/Stream.hpp"
#include "eco-system/Stream/StreamTable.hpp"

#include "eco-system/Core/FdChannel.hpp"

#include "allocator/StringOps.hpp"

#include <cerrno>
#include <algorithm>
#include <cstring>
#include <deque>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#ifndef _WIN32
#include <fcntl.h>
#include <unistd.h>
#endif

namespace Eco::System {

namespace {

/// The failure reason of writes behind a Custom transform that closed its stream, marked as ended.
/// (`kWritableClosed`, the other ended reason used here, is shared from Core.hpp.)
constexpr char kTerminated[] = ECO_SYSTEM_ENDED_MARKER "TransformStream has been terminated";
static_assert(kTerminated[0] == kEndedMarker[0] && kTerminated[1] == 'T',
              "kTerminated starts with the ended marker, then its text");
/// The most bytes one channel read asks for.
constexpr size_t kChannelReadChunk = 64 * 1024;

/// The next uncounted request id. The ids start at 2^61, a value resume tokens are assumed never to reach,
/// and `streamIsUncountedToken` accepts them up to 2^62, below every free-standing hold token (which has bit
/// 63 set). Nothing checks that the counter stays below 2^62.
uint64_t g_nextUncountedToken = uint64_t{1} << 61;

/// Returns the map from channel id to the id of the pair that owns the channel, for every channel pair,
/// created on first use and never destroyed. An entry is checked on use (the pair must still exist and own
/// that channel), so an entry left behind by a heap reset is harmless. Eco thread only.
std::unordered_map<uint64_t, int64_t>& channelPairs() {
    static auto* m = new std::unordered_map<uint64_t, int64_t>();
    return *m;
}

/// Returns the marked failure reason for the failed channel result `r`: the channel's own `encodeFailure`
/// when `p` has a channel, otherwise `r.reason` if it is already marked, else a "stream" reason built from
/// `r.err` (`EIO` when 0) or from `r.reason`. `p` may be null.
std::string channelFailure(const StreamPair* p, const ChannelResult& r) {
    if (p && p->channel) return p->channel->encodeFailure(r.err, r.reason);
    if (isMarkedReason(r.reason)) return r.reason;
    return r.reason.empty() ? errnoFailureReason("stream", r.err != 0 ? r.err : EIO)
                            : failureReason("stream", "", r.reason);
}

/// Returns a new Bytes value holding a copy of `b`, or the empty-Bytes constant when `b` is empty.
/// Allocates.
HPointer makeBytes(const std::string& b) {
    if (b.empty()) return alloc::emptyBytes();
    alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(b.size());
    std::memcpy(bb.bytes, b.data(), b.size());   // no allocation in between
    return bb.hp;
}

// --- Payload decoding (no allocation) --------------------------------------

/// Returns the value of the boxed Int `captured`.
int64_t payloadInt(HPointer captured) {
    return static_cast<ElmInt*>(Allocator::instance().resolve(captured))->value;
}

/// Reads the payload `tuple2( boxed x, Int id )` (kind mask 0x4: slot 1 is an unboxed Int) into `x` and `id`.
/// `x` is unrooted and stale after the next allocation.
void payloadBoxedAndId(HPointer captured, HPointer& x, int64_t& id) {
    Tuple2* t = asTuple2(captured);
    x = t->a.p;
    id = t->b.i;
}

// --- Completion --------------------------------------------------------------

} // namespace

// The hold is released after the resumed process is queued, so the program cannot be seen idle in between.
void streamCompleteOk(uint64_t token, bool counted, HPointer value) {
    auto& s = Scheduler::instance();
    HPointer resume = s.takePendingResume(token);   // no allocation
    if (!alloc::isNil(resume)) {
        HPointer task = alloc::listNil();
        Elm::StackRootGuard g(&resume, &value, &task);
        task = succeed(value);
        Scheduler::callClosure1(resume, task);
    }
    if (counted) s.releaseHold(token);
}

void streamCompleteErr(uint64_t token, bool counted, int kind, const std::string& reason) {
    auto& s = Scheduler::instance();
    HPointer resume = s.takePendingResume(token);
    if (!alloc::isNil(resume)) {
        HPointer task = alloc::listNil();
        Elm::StackRootGuard g(&resume, &task);
        task = failSErr(kind, reason);
        Scheduler::callClosure1(resume, task);
    }
    if (counted) s.releaseHold(token);
}

uint64_t streamHeldToken(const char* site) {
    return Scheduler::instance().acquireHold(HoldKind::Task, site);
}

uint64_t streamUncountedToken() { return g_nextUncountedToken++; }

bool streamIsUncountedToken(uint64_t token) {
    return token >= (uint64_t{1} << 61) && token < (uint64_t{1} << 62);
}

namespace {

/// Completes `token` as `streamCompleteOk` does.
void completeOk(uint64_t token, bool counted, HPointer value) {
    streamCompleteOk(token, counted, value);
}

/// Fails `token` as `streamCompleteErr` does.
void completeErr(uint64_t token, bool counted, int kind, const std::string& reason) {
    streamCompleteErr(token, counted, kind, reason);
}

/// Resumes the running task at once with `task`, for a body that can answer without parking, and returns
/// Unit for the body to return. `resume` is the body's parameter, which `ECO_SYSTEM_ASYNC_GUARD` roots.
HPointer resumeNow(HPointer& resume, HPointer task) {
    Elm::StackRootGuard g(&task);
    Scheduler::callClosure1(resume, task);
    return alloc::unit();
}

/// A parked token to complete later, and whether it is also a liveness hold.
struct TokenRef {
    uint64_t token;
    bool counted;
};

/// Fails every token in `toks` with a Cancelled SErr carrying `reason`. Allocates and calls Elm.
void failAll(const std::vector<TokenRef>& toks, const std::string& reason) {
    for (const auto& t : toks) completeErr(t.token, t.counted, kSErrCancelled, reason);
}

/// Empties the write side of `p`, appending to `out` the tokens of the writes waiting for room, of the writes
/// queued in memory, and of a parked close, and releases the write lock. A ChannelSink's queued writes and
/// close are in flight, so they stay and complete through the channel dispatch.
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

/// Makes both sides of `p` Errored with `reason`, empties `readQ` and the write side as `drainWriteSide`
/// does, and appends to `out` every token that must now fail: those `drainWriteSide` collects and, except on
/// a ChannelSource, a parked read. A
/// ChannelSource's parked read completes when its channel answers.
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

/// Ends `p` for a Custom transform that closed it, as WHATWG's transform-stream terminate does: an Open
/// readable side becomes Closed, so it ends once `readQ` drains, and an Open or Closing writable side becomes
/// Errored with `kTerminated`, with the tokens of its queued writes and close appended to `out`.
void terminatePair(StreamPair* p, std::vector<TokenRef>& out) {
    if (p->w == WState::Open || p->w == WState::Closing) {
        p->w = WState::Errored;
        p->wReason = kTerminated;
        drainWriteSide(p, out);
    }
    if (p->r == RState::Open) p->r = RState::Closed;
}

/// The reasons of an erased pair one of whose sides was Errored, which its missing id still answers with.
struct ErasedReasons {
    bool wErrored = false;
    bool rErrored = false;
    std::string wReason, rReason;
};

/// The most erased pairs whose reasons are kept; the oldest is forgotten first.
constexpr size_t kErasedReasonsCap = 4096;

/// The reasons of the most recently erased pairs that had an Errored side, by pair id, and their ids in the
/// order they were erased. Plain strings, off the heap. Pair ids are never reused (the table's id counter only
/// grows, even across a heap reset), so an entry can never answer for a newer pair. Eco thread only.
struct ErasedStore {
    std::unordered_map<int64_t, ErasedReasons> byId;
    std::deque<int64_t> order;
};

ErasedStore& erasedStore() {
    static auto* s = new ErasedStore();
    return *s;
}

/// Keeps the reasons of `p`, about to be erased as pair `id`, if one of its sides is Errored.
void rememberErased(int64_t id, const StreamPair& p) {
    const bool wErr = p.w == WState::Errored;
    const bool rErr = p.r == RState::Errored;
    if (!wErr && !rErr) return;
    auto& st = erasedStore();
    while (st.order.size() >= kErasedReasonsCap) {
        st.byId.erase(st.order.front());
        st.order.pop_front();
    }
    ErasedReasons e;
    e.wErrored = wErr;
    e.rErrored = rErr;
    if (wErr) e.wReason = p.wReason;
    if (rErr) e.rReason = p.rReason;
    st.byId[id] = std::move(e);
    st.order.push_back(id);
}

/// Returns the Task a read of the missing pair `id` answers with: a Cancelled SErr with the stored reason if
/// the pair was erased with its readable side Errored, otherwise Closed.
HPointer missingReadFailure(int64_t id) {
    std::string reason;
    if (streamErasedReadReason(id, reason)) return failSErr(kSErrCancelled, reason);
    return failSErr(kSErrClosed, "");
}

/// Returns the reason a write or close of the missing pair `id` fails Cancelled with: the stored reason if the
/// pair was erased with its writable side Errored, otherwise `kWritableClosed`.
std::string missingWriteReason(int64_t id) {
    std::string reason;
    if (streamErasedWriteReason(id, reason)) return reason;
    return kWritableClosed;
}

/// Erases pair `id` if the erasure rule in StreamTable.hpp allows it, keeps the reasons of an Errored side,
/// and forgets its channel.
void maybeErase(int64_t id) {
    auto& t = streamTable();
    StreamPair* p = t.find(id);
    if (!p || p->pinned || p->pipeRefs > 0) return;
    if (p->w != WState::Closed && p->w != WState::Errored) return;
    if (p->r != RState::Closed && p->r != RState::Errored) return;
    if (!p->readQ.empty() || !p->writeQ.empty() || !p->waitingForRoom.empty()) return;
    if (p->parkedReadToken || p->closeToken || p->chanReadTok) return;
    if (!p->rawQ.empty() || p->readInFlight || p->readerKick) return;   // MappedSource
    if (p->reader && !p->readerEndSent) return;   // the subscription reader is still owed the end
    if (p->carryPos < p->carry.size()) return;    // `Stream.readLine` bytes not handed out yet
    rememberErased(id, *p);
    if (p->channel) channelPairs().erase(p->channel->id());
    t.erase(id);
}

void channelDispatch(ChannelResult& r);
void mapHead(int64_t id);
void mappedReadResult(int64_t id, ChannelResult& r);

/// Adds a ChannelSource or ChannelSink pair that owns `channel`, with the side it lacks Closed, and returns
/// its id. `channel` must not be null.
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
    static auto* t = new Registry<StreamPair>("eco-system-streams");
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

bool streamErasedReadReason(int64_t id, std::string& reason) {
    auto& st = erasedStore();
    auto it = st.byId.find(id);
    if (it == st.byId.end() || !it->second.rErrored) return false;
    reason = it->second.rReason;
    return true;
}

bool streamErasedWriteReason(int64_t id, std::string& reason) {
    auto& st = erasedStore();
    auto it = st.byId.find(id);
    if (it == st.byId.end() || !it->second.wErrored) return false;
    reason = it->second.wReason;
    return true;
}

// ---------------------------------------------------------------------------
// The pump. One action per iteration; the pair is looked up again each time,
// because a completion allocates and a Custom step calls Elm.
// ---------------------------------------------------------------------------

namespace {

/// Completes the write `pw` once its value has been transformed: with success if `ok`, otherwise with a
/// Cancelled SErr carrying `reason`. Does nothing for an enqueued value, which was completed on acceptance.
void finishWrite(const PendingWrite& pw, bool ok, const std::string& reason) {
    if (!pw.token || !pw.completeOnTransform) return;
    if (ok) completeOk(pw.token, pw.counted, alloc::unit());
    else completeErr(pw.token, pw.counted, kSErrCancelled, reason);
}

/// Appends the codec outputs `outs` to the `readQ` of pair `id`, as Strings if `asString`, otherwise as Bytes.
/// Each is stored as soon as it is allocated, so no fresh value is held across the next allocation. Stops if
/// the pair is gone.
void pushCodecOutputs(int64_t id, const std::vector<std::string>& outs, bool asString) {
    for (const auto& s : outs) {
        HPointer v = asString ? alloc::allocStringFromUTF8(s) : makeBytes(s);
        StreamPair* p = streamTable().find(id);
        if (!p) return;
        p->readQ.push_back(enc(v));
    }
}

/// Returns a copy of the UTF-16 code units of the String `s`. No heap allocation.
std::u16string stringUnits(HPointer s) {
    if (alloc::isEmptyString(s)) return {};
    return StringOps::toStdU16String(Allocator::instance().resolve(s));
}

/// Appends the elements of the Elm list `outs` to the `readQ` of pair `id`, boxing unboxed Int, Float and
/// Char elements, since `read` hands values to Elm boxed. Stops if the pair is gone.
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

/// Runs one Custom step on pair `id` for the write `pw`, which has already left `writeQ`: calls the action
/// closure with the state and the value, stores the new state, and acts on the result's constructor.
/// UpdateState only updates the state; Send appends the outputs to an Open readable side, even past its
/// capacity; Close appends them and then terminates the pair (`terminatePair`); Cancel makes both sides
/// Errored with the result's reason. `pw` itself succeeds in every case but a vanished pair, and the writes
/// queued behind a Close or Cancel fail.
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
    res = Scheduler::callClosure2(fn, st, v);   // may collect and re-enter the table

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
        finishWrite(pw, false, missingWriteReason(id));
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

/// Runs one Codec step on pair `id` for the write `pw`, which has already left `writeQ`: feeds its value to
/// the codec, appends the outputs to an Open readable side, and completes `pw`. A codec error makes both
/// sides Errored with a "codec" failure reason and fails `pw` and every other parked task.
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
        err = failureReason("codec", "", err);   // Stream.Failed
        std::vector<TokenRef> toFail;
        errorPair(p, err, toFail);
        finishWrite(pw, false, err);
        failAll(toFail, err);
        return;
    }
    if (p->r == RState::Open) pushCodecOutputs(id, outs, asString);
    finishWrite(pw, true, "");
}

/// Moves pair `id` forward until no step applies. Applies to an in-memory pair (Identity, Custom, Codec) and
/// to the `readQ` side of a MappedSource; a ChannelSource or ChannelSink is moved by its channel results
/// instead, and is left alone here.
void pumpCore(int64_t id) {
    auto& t = streamTable();
    for (;;) {
        StreamPair* p = t.find(id);
        if (!p) return;
        if (p->kind == StreamKind::ChannelSource || p->kind == StreamKind::ChannelSink) return;

        // 0. MappedSource: a waiting consumer (a parked read, or a pipe
        //    whose destination has room) takes the next raw chunk: map it.
        if (p->kind == StreamKind::MappedSource && p->readQ.empty() && !p->rawQ.empty() &&
            (p->parkedReadToken || streamPipeDemand(p))) {
            mapHead(id);   // calls Elm
            continue;
        }

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
                    err = failureReason("codec", "", err);   // Stream.Failed
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
        if (p->parkedReadToken && p->readQ.empty() && p->rawQ.empty() && p->r != RState::Open) {
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

/// The pump driver's work list: pair ids, which are positive, and pipe ids, stored negated. Eco thread only.
std::deque<int64_t> g_work;
/// Whether `drive` is running, so that a re-entrant call only adds to `g_work`.
bool g_driving = false;

/// Adds `item` to the work list unless it is already there.
void schedule(int64_t item) {
    if (std::find(g_work.begin(), g_work.end(), item) == g_work.end()) g_work.push_back(item);
}

/// Runs the work list until it is empty, unless a run is already in progress. Each pair item is pumped, has
/// its read-ahead issued if it is a MappedSource and one is due, has its pipes scheduled, and is erased if it
/// may be. Each pipe item is run. If an item throws, the list is cleared and the exception propagates.
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
                if (p->kind == StreamKind::MappedSource) streamMappedMaybeRead(item);
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
// Channel results, on the eco thread from the Core channel drain, which runs
// the scheduler once afterwards. A counted channel request is its own
// liveness hold, released here by its token on every path. An uncounted
// token is not a hold (a piped read-ahead's separate hold is released with
// its result), and an untokened close holds nothing.
// ---------------------------------------------------------------------------

namespace {

/// Returns the request ids of withdrawn reads: ChannelSource reads still in flight whose parked task was
/// killed. The kill released their holds, so their results release nothing. Created on first use and never
/// destroyed or cleared, not even by a heap reset, so a late result still finds its id here.
std::unordered_set<uint64_t>& withdrawnReads() {
    static auto* s = new std::unordered_set<uint64_t>();
    return *s;
}

/// Withdraws the read parked under `token`, for the kill handle of a `read` or `readChunk`, and returns
/// whether that read held a liveness hold, which the kill handle then releases. The pair is no longer
/// read-locked. A ChannelSource's channel request stays in flight as a withdrawn read; a MappedSource's
/// read-ahead goes on and is not the read's hold; an in-memory read held nothing. A pipe's read is never withdrawn.
/// Returns false if no read is parked under `token`, because it has completed already.
bool cancelParkedRead(uint64_t token) {
    for (auto& kv : streamTable().map()) {
        StreamPair& p = kv.second;
        if (p.parkedReadToken != token || p.pipeOutId) continue;
        bool counted = p.parkedReadCounted;
        p.parkedReadToken = 0;
        p.parkedReadCounted = false;
        p.readLock = false;
        if (p.kind == StreamKind::ChannelSource && p.chanReadTok == token)
            withdrawnReads().insert(token);
        return counted;
    }
    return false;   // completed already: its completion released (or will)
}

/// Applies the channel result `r` to the pair that owns its channel: completes the read, write or close it
/// answers, updates the pair's state, releases the request's hold, and pumps the pair. A result for a pair
/// that is gone, or for a token no longer parked, drops the token's resume and releases its hold if it has
/// one.
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

    if (r.op == ChannelResult::Op::Read && p && p->kind == StreamKind::MappedSource) {
        mappedReadResult(id, r);
        return;
    }

    switch (r.op) {
    case ChannelResult::Op::Read: {
        // A withdrawn read (its reader was killed, and the kill handle released its
        // hold): its result belongs to the read parked behind it, if any, else to readQ.
        bool withdrawn = r.token != 0 && withdrawnReads().erase(r.token) > 0;
        if (p && p->chanReadTok == r.token) p->chanReadTok = 0;
        if (withdrawn) {
            if (!p) return;
            if (!p->parkedReadToken) {
                if (r.err) {
                    if (p->r == RState::Open) {
                        p->r = RState::Errored;
                        p->rReason = channelFailure(p, r);
                    }
                    p->channel->shutdown();
                } else if (r.eof) {
                    if (p->r == RState::Open) p->r = RState::Closed;
                    p->channel->close(0);
                } else if (!r.bytes.empty() && p->r == RState::Open) {
                    HPointer v = r.text ? alloc::allocStringFromUTF8(r.bytes) : makeBytes(r.bytes);
                    if (StreamPair* q = t.find(id)) q->readQ.push_back(enc(v));   // no allocation in between
                }
                pumpStream(id);
                return;
            }
            r.token = p->parkedReadToken;   // adopted: completed (and released) below as its own
        }
        HoldRelease release(streamIsUncountedToken(r.token) ? kNoHold : r.token);   // mapped read-ahead: uncounted
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
                    p->rReason = channelFailure(p, r);
                }
                p->channel->shutdown();
            } else if (r.eof) {
                if (p->r == RState::Open) p->r = RState::Closed;
                p->channel->close(0);
            } else if (!r.bytes.empty()) {
                HPointer v = r.text ? alloc::allocStringFromUTF8(r.bytes) : makeBytes(r.bytes);
                if (StreamPair* q = t.find(id)) q->readQ.push_back(enc(v));   // no allocation in between
            }
            pumpStream(id);
            return;
        }
        if (r.err) {
            if (p->r == RState::Open) {
                p->r = RState::Errored;
                p->rReason = channelFailure(p, r);
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
            HPointer v = r.text ? alloc::allocStringFromUTF8(r.bytes) : makeBytes(r.bytes);
            Elm::StackRootGuard g(&v);
            completeOk(r.token, false, v);
        }
        pumpStream(id);
        return;
    }

    case ChannelResult::Op::Write: {
        HoldRelease release(r.token);
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
                p->wReason = channelFailure(p, r);
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
        HoldRelease release(r.token);
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
            p->wReason = channelFailure(p, r);
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
// Value-mapped pairs
// ---------------------------------------------------------------------------

namespace {

/// Returns a new `( Int tag, String, Bytes )` for the chunk `c` (kind mask 0x1: slot 0 is an unboxed Int).
/// A text chunk gives its String and empty Bytes, any other chunk "" and its Bytes. The result is unrooted.
HPointer wireTuple(const ChannelResult& c) {
    HPointer str = alloc::listNil(), bytes = alloc::listNil();
    Elm::StackRootGuard g(&str, &bytes);
    str = c.text ? alloc::allocStringFromUTF8(c.bytes) : alloc::emptyString();
    bytes = c.text ? alloc::emptyBytes() : makeBytes(c.bytes);
    return alloc::tuple3(alloc::unboxedInt(c.tag), alloc::boxed(str), alloc::boxed(bytes), 0x1);
}

/// Maps the oldest raw chunk of MappedSource `id` through its `fromWire` closure and appends the result to
/// `readQ`. Does nothing if the pair is gone or has no raw chunk. Calls Elm.
void mapHead(int64_t id) {
    ChannelResult c;
    HPointer fn = alloc::listNil();
    {
        StreamPair* p = streamTable().find(id);
        if (!p || p->rawQ.empty()) return;
        c = std::move(p->rawQ.front());
        p->rawQ.pop_front();
        fn = dec(p->mapFnEnc);
    }
    HPointer arg = alloc::listNil(), res = alloc::listNil();
    Elm::StackRootGuard g(&fn, &arg, &res);
    arg = wireTuple(c);
    res = Scheduler::callClosure1(fn, arg);   // may collect and re-enter the table
    StreamPair* p = streamTable().find(id);  // re-fetch after the call
    if (!p) return;
    p->readQ.push_back(enc(res));            // no allocation since the call
}

/// Hands the subscription reader of pair `id` every raw chunk it has not seen, then the end once if the
/// readable side has ended, and otherwise requests the next read-ahead. If the reader was detached
/// meanwhile, pumps the pair instead. Runs from the channel drain.
void feedReader(int64_t id) {
    for (;;) {
        StreamPair* p = streamTable().find(id);
        if (!p) return;
        if (!p->reader) {   // detached meanwhile: back to normal reading
            pumpStream(id);
            return;
        }
        ReaderFn fn = p->reader;
        void* ctx = p->readerCtx;
        if (!p->rawQ.empty()) {
            ChannelResult c = std::move(p->rawQ.front());
            p->rawQ.pop_front();
            fn(id, c, ctx);   // may call Elm: `p` is dead from here
            continue;
        }
        if (p->r != RState::Open) {
            if (!p->readerEndSent) {
                p->readerEndSent = true;
                ChannelResult c;
                c.channelId = p->channel ? p->channel->id() : 0;
                c.op = ChannelResult::Op::Read;
                if (p->r == RState::Closed) {
                    c.eof = true;
                } else {
                    c.err = p->rErrno != 0 ? p->rErrno : EIO;
                    c.reason = p->rReason;
                }
                fn(id, c, ctx);
                continue;
            }
            pumpStream(id);   // erasure checks
            return;
        }
        streamMappedMaybeRead(id);
        return;
    }
}

/// Applies the read result `r` of MappedSource `id`'s channel. A subscription reader's kick feeds the
/// reader. The read-ahead's result releases the hold a pipe gave it, records an end or failure, or keeps the
/// chunk in `rawQ`, and then feeds the reader or pumps the pair. Any other result is stale and only drops
/// its token's resume. Pair `id` must exist.
void mappedReadResult(int64_t id, ChannelResult& r) {
    auto& s = Scheduler::instance();
    StreamPair* p = streamTable().find(id);
    if (r.token != 0 && r.token == p->readerKick) {   // attachReader's kick (uncounted)
        p->readerKick = 0;
        feedReader(id);
        return;
    }
    if (r.token == 0 || r.token != p->readInFlight) {   // stale
        (void)s.takePendingResume(r.token);
        return;
    }
    HoldRelease release(p->readInFlightHold);
    p->readInFlight = 0;
    p->readInFlightHold = kNoHold;
    if (r.err) {
        if (p->r == RState::Open) {
            p->r = RState::Errored;
            p->rReason = channelFailure(p, r);
            p->rErrno = r.err;
        }
        if (p->channel) p->channel->shutdown();
    } else if (r.eof) {
        if (p->r == RState::Open) p->r = RState::Closed;
        if (p->channel) p->channel->close(0);   // uncounted release
    } else if (p->r == RState::Open) {
        p->rawQ.push_back(std::move(r));   // POD until a consumer takes it
    }
    if (p->reader && !p->readerKick) {
        feedReader(id);
    } else {
        pumpStream(id);
    }
}

} // namespace

void streamMappedMaybeRead(int64_t id) {
    StreamPair* p = streamTable().find(id);
    if (!p || p->kind != StreamKind::MappedSource || !p->channel) return;
    if (p->r != RState::Open || p->readInFlight || p->readerKick) return;
    if (!p->rawQ.empty() || !p->readQ.empty()) return;   // read-ahead: one chunk
    uint64_t tok = streamUncountedToken();
    p->readInFlight = tok;
    if (p->pipeOutId != 0)   // a pipe waits for it: keep the program alive
        p->readInFlightHold = Scheduler::instance().acquireHold(HoldKind::Task, "Stream.mappedReadAhead");
    p->channel->requestRead(tok, kChannelReadChunk);
}

void streamMapForSink(uint64_t toWireEnc, HPointer value, int64_t& tag, bool& text,
                      std::string& bytes) {
    HPointer fn = dec(toWireEnc), res = alloc::listNil();
    Elm::StackRootGuard g(&fn, &value, &res);
    res = Scheduler::callClosure1(fn, value);   // may collect and re-enter the table
    // Decode ( Int, String, Bytes ) without allocating.
    Tuple3* t3 = asTuple3(res);
    u32 ub = t3->header.unboxed;
    if (Elm::tupleFieldKind(ub, 0) == 1) {
        tag = t3->a.i;
    } else {
        tag = static_cast<ElmInt*>(Allocator::instance().resolve(t3->a.p))->value;
    }
    std::string str = toStdString(t3->b.p);
    if (!str.empty()) {
        text = true;
        bytes = std::move(str);
    } else {
        text = false;
        bytes = toStdBytes(asTuple3(res)->c.p);
    }
}

int64_t createMappedSource(ByteChannel* channel, uint64_t fromWireEnc) {
    auto& t = streamTable();
    StreamPair p;
    p.kind = StreamKind::MappedSource;
    p.channel.reset(channel);
    p.w = WState::Closed;   // no writable side
    p.readCap = 1;
    p.mapFnEnc = fromWireEnc;
    uint64_t chan = channel->id();
    int64_t id = t.insert(std::move(p));
    channelPairs()[chan] = id;
    streamMappedMaybeRead(id);   // read ahead (no heap allocation)
    return id;
}

int64_t createMappedSink(ByteChannel* channel, uint64_t toWireEnc) {
    int64_t id = insertChannelPair(StreamKind::ChannelSink, channel);
    if (StreamPair* p = streamTable().find(id)) p->mapFnEnc = toWireEnc;
    return id;
}

bool attachReader(int64_t pairId, ReaderFn fn, void* ctx) {
    StreamPair* p = streamTable().find(pairId);
    if (!p || p->kind != StreamKind::MappedSource || !fn) return false;
    if (p->reader || p->readLock || p->pipedOut) return false;
    if (!p->readQ.empty()) return false;   // mapped values wait for a reader
    p->reader = fn;
    p->readerCtx = ctx;
    if (!p->rawQ.empty() || p->r != RState::Open) {
        // Chunks already read (or the end): handed over from the channel
        // drain, in order (no read is in flight while rawQ holds a chunk).
        if (!p->readerKick && p->channel) {
            p->readerKick = streamUncountedToken();
            ChannelResult kick;
            kick.channelId = p->channel->id();
            kick.token = p->readerKick;
            kick.op = ChannelResult::Op::Read;
            postChannelResult(std::move(kick));
        }
    } else {
        streamMappedMaybeRead(pairId);
    }
    return true;
}

void detachReader(int64_t pairId) {
    StreamPair* p = streamTable().find(pairId);
    if (!p || !p->reader) return;
    p->reader = nullptr;
    p->readerCtx = nullptr;
    streamMappedMaybeRead(pairId);
}

// ---------------------------------------------------------------------------
// C++ API
// ---------------------------------------------------------------------------

int64_t createChannelSource(ByteChannel* channel) {
    return insertChannelPair(StreamKind::ChannelSource, channel);
}

int64_t createTextChannelSink(ByteChannel* channel) {
    int64_t id = insertChannelPair(StreamKind::ChannelSink, channel);
    if (StreamPair* p = streamTable().find(id)) p->textSink = true;
    return id;
}

void discardReadable(int64_t id) { streamCancelReadableNow(id, std::string()); }

void discardWritable(int64_t id) {
    StreamPair* p = streamTable().find(id);
    if (!p || p->w == WState::Closed || p->w == WState::Errored) return;
    std::vector<TokenRef> toFail;
    p->w = WState::Closed;   // Closed, not Errored, so that the pair can be erased
    drainWriteSide(p, toFail);
    if (p->kind == StreamKind::ChannelSink && p->channel) p->channel->shutdown();
    failAll(toFail, std::string());   // allocates: `p` is dead from here
    pumpStream(id);
}

int64_t createChannelSink(ByteChannel* channel) {
    return insertChannelPair(StreamKind::ChannelSink, channel);
}

namespace {

/// Returns the fd the channel will own: `fd` itself when the stream owns it, for fds 0 to 2 (which
/// `FdChannel` never closes), and always on Windows; otherwise a close-on-exec duplicate numbered 3 or
/// above, or -1 if duplicating fails.
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

int64_t createFdSource(int fd, bool owns, const char* origin) {
    (void)streamTable();   // dispatch installed before the channel exists
    int cfd = channelFd(fd, owns);
    if (cfd < 0) return 0;
    FdChannelOptions o;
    o.origin = origin;
    o.nonBlocking = owns && cfd > 2;   // an fd the stream owns has a description of its own
    return createChannelSource(new FdChannel(cfd, o));
}

int64_t createFdSink(int fd, bool owns, const char* origin) {
    (void)streamTable();
    int cfd = channelFd(fd, owns);
    if (cfd < 0) return 0;
    FdChannelOptions o;
    o.origin = origin;
    o.nonBlocking = owns && cfd > 2;
    return createChannelSink(new FdChannel(cfd, o));
}

// ---------------------------------------------------------------------------
// Kernel bodies
// ---------------------------------------------------------------------------

// Payload tuple2( Int readCap, Int writeCap ), mask 0x5. Capacities below 1 are raised to 1.
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

// Payload tuple2( boxed tuple2( fn, state ) mask 0, boxed tuple2( Int readCap, Int writeCap ) mask 0x5 ),
// mask 0. A negative read capacity becomes 0, which makes the pair a rendezvous; a write capacity below 1
// becomes 1. The fn and state words go straight into the scanned table entry before the result allocates.
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

/// Adds a Codec pair running `codec`, with read and write capacities of 1, and returns `Task.succeed` of its
/// id.
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

HPointer streamTextEncoderBody(HPointer) {
    ECO_SYSTEM_BODY_GUARD(Never,
        return insertCodecPair(newTextEncoder());
    )
}

HPointer streamTextDecoderBody(HPointer) {
    ECO_SYSTEM_BODY_GUARD(Never,
        return insertCodecPair(newTextDecoder());
    )
}

// Payload: boxed Int algorithm, a `newZlibCodec` value (0 gzip, 1 deflate, 2 raw deflate).
HPointer streamCompressorBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        int algorithm = static_cast<int>(payloadInt(captured));
        return insertCodecPair(newZlibCodec(/*compress=*/true, algorithm));
    )
}

// Payload: boxed Int algorithm, as for the compressor.
HPointer streamDecompressorBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        int algorithm = static_cast<int>(payloadInt(captured));
        return insertCodecPair(newZlibCodec(/*compress=*/false, algorithm));
    )
}

namespace {

/// Reads the next value of pair `id` (the boxed Int `captured`) for `read` and `readChunk`. With
/// `carryFirst`, the unread part of the `Stream.readLine` carry is handed out first, as one Bytes value.
///
/// Answers at once with the next buffered value, with Closed for a missing pair or an ended side, with the
/// reason for an Errored one (also one erased since, as StreamTable.hpp says), and with Locked when the side
/// is in use. Otherwise parks the task and returns
/// its kill handle. A park on a channel or mapped source holds the program alive; one on an in-memory pair
/// does not. A ChannelSource issues a channel read for the park unless a withdrawn read is still in flight,
/// whose result then answers this read.
HPointer readImpl(HPointer captured, HPointer resume, bool carryFirst) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(SErr, resume, token, counted,
        int64_t id = payloadInt(captured);
        auto& sched = Scheduler::instance();
        StreamPair* p = streamTable().find(id);
        if (!p) return resumeNow(resume, missingReadFailure(id));
        if (streamReadLocked(p)) return resumeNow(resume, failSErr(kSErrLocked, ""));
        if (carryFirst && p->carryPos < p->carry.size()) {
            std::string rest = p->carry.substr(p->carryPos);   // copy out first
            p->carry.clear();
            p->carryPos = 0;
            return resumeNow(resume, succeed(makeBytes(rest)));
        }
        if (p->kind == StreamKind::MappedSource && p->readQ.empty() && !p->rawQ.empty()) {
            mapHead(id);                        // the chunk read ahead (calls Elm)
            p = streamTable().find(id);
            if (!p) return resumeNow(resume, missingReadFailure(id));
        }
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
        if (p->kind == StreamKind::ChannelSource) {
            // External IO keeps the program alive.
            token = sched.parkResume(resume, HoldKind::Task, "Stream.read");
            counted = true;
            p->parkedReadCounted = true;
        } else if (p->kind == StreamKind::MappedSource) {
            // The read-ahead request is uncounted: the parked read holds.
            token = sched.parkResume(resume, HoldKind::Task, "Stream.readMapped");
            counted = true;
            p->parkedReadCounted = true;
        } else {
            token = sched.registerPendingResume(resume);   // in-memory: only Elm code can complete it
        }
        // The kill handle first: it allocates, and a throw must not leave the
        // token parked (asyncFailure releases it).
        HPointer kill = makeKillHandle(token, &cancelParkedRead);
        Elm::StackRootGuard kg(&kill);
        p = streamTable().find(id);             // looked up again after the allocation
        p->readLock = true;
        p->parkedReadToken = token;
        if (p->kind == StreamKind::ChannelSource && p->chanReadTok == 0) {
            p->chanReadTok = token;
            p->channel->requestRead(token, kChannelReadChunk);
        }   // else a withdrawn read is in flight: its result is this read's
        pumpStream(id);                         // MappedSource: issues the read-ahead if due
        return kill;
    )
}

} // namespace

HPointer streamReadBody(HPointer captured, HPointer resume) {
    return readImpl(captured, resume, /*carryFirst=*/true);
}

HPointer streamReadChunkBody(HPointer captured, HPointer resume) {
    return readImpl(captured, resume, /*carryFirst=*/false);
}

// Payload tuple2( Int atEnd, Int id ), mask 0x5, with `atEnd` 0 or 1. Succeeds with the next line of the
// carry without its "\n" and any "\r" before it; when no newline is left, with the rest of the carry if
// `atEnd` is set, else Nothing. A missing pair or an empty carry gives Nothing.
HPointer streamCarryLineBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        int64_t atEnd = 0, id = 0;
        {
            Tuple2* t = asTuple2(captured);   // no allocation in scope
            atEnd = t->a.i;
            id = t->b.i;
        }
        StreamPair* p = streamTable().find(id);
        if (!p || p->carryPos >= p->carry.size()) return succeed(alloc::nothing());
        std::string line;   // copy out, update the carry, then allocate
        const char* base = p->carry.data() + p->carryPos;
        size_t avail = p->carry.size() - p->carryPos;
        const void* nl = std::memchr(base, '\n', avail);
        if (nl) {
            size_t len = static_cast<const char*>(nl) - base;
            line.assign(base, len);
            p->carryPos += len + 1;
            if (!line.empty() && line.back() == '\r') line.pop_back();
        } else if (atEnd != 0) {
            line.assign(base, avail);
            p->carryPos = p->carry.size();
        } else {
            return succeed(alloc::nothing());
        }
        bool drained = false;
        if (p->carryPos >= p->carry.size()) {
            p->carry.clear();
            p->carryPos = 0;
            drained = true;
        } else if (p->carryPos > p->carry.size() / 2) {
            p->carry.erase(0, p->carryPos);
            p->carryPos = 0;
        }
        if (drained) maybeErase(id);   // the carry kept an ended pair; `p` is dead from here
        HPointer bytes = makeBytes(line);
        return succeed(alloc::just(alloc::boxed(bytes), true));   // fresh: `just` roots it
    )
}

// Payload tuple2( boxed Bytes, Int id ), mask 0x4. A missing pair drops the bytes.
HPointer streamCarryAppendBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(Never,
        HPointer b = alloc::listNil();
        int64_t id = 0;
        payloadBoxedAndId(captured, b, id);
        std::string data = toStdBytes(b);
        if (StreamPair* p = streamTable().find(id)) p->carry.append(data);
        return succeedUnit();
    )
}

namespace {

/// Writes the value in `captured` (payload tuple2( boxed value, Int id ), mask 0x4) to pair `id`, for
/// `write` and, with `isEnqueue`, `enqueue`. Sets `token` and `counted` when it parks, for the async guard.
///
/// A missing pair, a source, or a writable side that is Closing or Closed fails with the closed reason; an
/// Errored side fails with its reason, also once its pair has been erased; a side in use fails Locked. On a channel sink the value becomes one
/// channel write, holding the program alive until the channel answers it: a write parks until then, an
/// enqueue succeeds at once. On an in-memory pair, a write parks until its value is transformed and an
/// enqueue succeeds once its value is accepted; when `writeQ` is full, either waits for room and holds the
/// write lock meanwhile.
HPointer writeOrEnqueue(HPointer captured, HPointer& resume, uint64_t& token,
                        bool& counted, bool isEnqueue) {
    HPointer v = alloc::listNil();
    int64_t id = 0;
    payloadBoxedAndId(captured, v, id);
    auto& sched = Scheduler::instance();
    StreamPair* p = streamTable().find(id);
    if (!p) return resumeNow(resume, failSErr(kSErrCancelled, missingWriteReason(id)));
    if (streamWriteLocked(p)) return resumeNow(resume, failSErr(kSErrLocked, ""));
    if (p->w == WState::Closing || p->w == WState::Closed) {
        return resumeNow(resume, failSErr(kSErrCancelled, kWritableClosed));
    }
    if (p->w == WState::Errored) {
        std::string reason = p->wReason;
        return resumeNow(resume, failSErr(kSErrCancelled, reason));
    }

    if (p->kind == StreamKind::ChannelSink && p->mapFnEnc) {
        // Mapped sink: toWire first (an Elm call), then the tagged channel write.
        int64_t tag = 0;
        bool text = false;
        std::string bytes;
        streamMapForSink(p->mapFnEnc, v, tag, text, bytes);
        p = streamTable().find(id);              // re-fetch after the call
        if (!p) return resumeNow(resume, failSErr(kSErrCancelled, missingWriteReason(id)));
        if (p->w != WState::Open) {
            std::string reason = p->w == WState::Errored ? p->wReason : std::string(kWritableClosed);
            return resumeNow(resume, failSErr(kSErrCancelled, reason));
        }
        uint64_t req;   // its hold is released by the channel dispatch
        if (isEnqueue) {
            req = streamHeldToken("Stream.enqueue");
        } else {
            token = sched.parkResume(resume, HoldKind::Task, "Stream.write");
            req = token;
            counted = true;
        }
        p->writeQ.push_back(PendingWrite{req, 0, true, true});
        p->channel->requestWriteTagged(req, tag, text, std::move(bytes));
        if (isEnqueue) return resumeNow(resume, succeedUnit());
        return alloc::unit();
    }

    if (p->kind == StreamKind::ChannelSink) {
        std::string bytes = p->textSink ? toStdString(v) : toStdBytes(v);   // copy out first
        uint64_t req;   // its hold is released by the channel dispatch
        if (isEnqueue) {
            req = streamHeldToken("Stream.enqueue");
        } else {
            token = sched.parkResume(resume, HoldKind::Task, "Stream.write");
            req = token;
            counted = true;
        }
        p->writeQ.push_back(PendingWrite{req, 0, true, true});
        p->channel->requestWrite(req, std::move(bytes));
        if (isEnqueue) return resumeNow(resume, succeedUnit());
        return alloc::unit();
    }

    if (p->kind == StreamKind::ChannelSource || p->kind == StreamKind::MappedSource) {
        // A source has no writable side.
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

// Payload: boxed Int id. A ChannelSink's close holds the program alive until the channel answers it; an
// in-memory pair closes at once when nothing is queued (except a codec, which must flush), and otherwise
// parks until the queued writes are through.
HPointer streamCloseWritableBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(SErr, resume, token, counted,
        int64_t id = payloadInt(captured);
        auto& sched = Scheduler::instance();
        StreamPair* p = streamTable().find(id);
        if (!p) return resumeNow(resume, failSErr(kSErrCancelled, missingWriteReason(id)));
        if (streamWriteLocked(p)) return resumeNow(resume, failSErr(kSErrLocked, ""));
        if (p->w == WState::Closing || p->w == WState::Closed ||
            p->kind == StreamKind::ChannelSource || p->kind == StreamKind::MappedSource) {
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
            token = sched.parkResume(resume, HoldKind::Task, "Stream.closeWritable");
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
    p->rawQ.clear();
    if (p->w == WState::Open || p->w == WState::Closing) {
        p->w = WState::Errored;
        p->wReason = reason;
        drainWriteSide(p, toFail);
    }
    if ((p->kind == StreamKind::ChannelSource || p->kind == StreamKind::MappedSource) && p->channel) {
        p->channel->shutdown();
    }
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

// Payload tuple2( boxed String reason, Int id ), mask 0x4. A missing pair succeeds.
HPointer streamCancelReadableBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(SErr,
        HPointer reasonHP = alloc::listNil();
        int64_t id = 0;
        payloadBoxedAndId(captured, reasonHP, id);
        std::string reason = toStdString(reasonHP);
        StreamPair* p = streamTable().find(id);
        if (!p) return succeedUnit();
        if (streamReadLocked(p)) return failSErr(kSErrLocked, "");
        streamCancelReadableNow(id, reason);
        return succeedUnit();
    )
}

// Payload tuple2( boxed String reason, Int id ), mask 0x4. A missing pair succeeds.
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
// Strict UTF-8
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
