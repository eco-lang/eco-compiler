//===- StreamPipe.cpp - pipeThrough / pipeTo for the eco/system streams ---===//
//
// A pipe moves values from the readable side of one pair, `src`, into the writable side of another, `dst`, until
// one of them ends. This file implements the pipes behind `Stream.pipeThrough`, `Stream.pipeTo` and the C++
// `pipeStreams`; their contracts are on the declarations in `StreamTable.hpp` and `Stream.hpp`.
//
// While a pipe runs it owns both sides: it sets `StreamPair::pipedOut` on `src` and `pipedIn` on `dst`, so any
// other read, write, close or cancel on them fails with `Locked`, and it counts in both pairs' `pipeRefs`, so
// neither is erased. A pipe has no thread or callback of its own. It is an item on the pump driver's work list
// (`streamSchedulePipe`), and `streamRunPipe` is run whenever either pair is pumped. Chains of pipes are
// therefore driven by one loop instead of by recursion.
//
// Each run of a pipe takes the first of these steps that applies, and repeats while it makes progress:
//   - while the pipe waits for its own close of `dst`: it succeeds once `dst` is Closed or missing, and fails
//     with `dst`'s reason if the close errors;
//   - `dst` is not Open, or missing: `src` is cancelled with `dst`'s reason if `dst` has Errored, or
//     with a Closed reason otherwise, and the pipe fails;
//   - `src` has Errored: `dst` is cancelled with `src`'s reason, and the pipe fails;
//   - `src` has a value ready and `dst` has room: the value is moved. A ChannelSink gets a channel write, through
//     its Elm mapping closure first if it is a mapped sink;
//   - `src` is Closed and drained, or missing: `dst` is closed, and the pipe waits for that close;
//   - otherwise, if `dst` has room, `src` is asked for more: an in-memory source with a value in its `writeQ`
//     is pumped, a MappedSource is pumped or has its read-ahead issued, and a ChannelSource gets one channel
//     read whose result its channel dispatch puts into `readQ`.
// A pipe whose `dst` has room, and that is not closing `dst`, also counts as a waiting reader of `src`
// (`streamPipeDemand`), so `src`'s pump moves a value to its readable side even when `readQ` is at capacity.
//
// The pipe table holds only ids, a resume token and a flag, no heap values: a `pipeTo` task's resume closure
// is kept by the Scheduler under that token, so no root scanner is needed. The table is cleared when the heap
// generation changes, as the stream table is.
//
// Liveness: each channel read, write or close a pipe issues is a held token (`streamHeldToken`), released when
// the channel's result is dispatched. A pipe over in-memory pairs holds nothing, and neither does a parked
// `pipeTo` task. A pipe waiting on a MappedSource's read-ahead gives that request a hold of its own.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Stream/Stream.hpp"
#include "eco-system/Stream/StreamTable.hpp"

#include <string>
#include <unordered_map>
#include <utility>

namespace Eco::System {

namespace {

/// The reason `src` is cancelled with when `dst` was closed, marked (`\x02`) as a Closed reason.
constexpr const char* kWritableClosed = "\x02WritableStream is closed";   // Stream.Closed
/// The most bytes one channel read issued by a pipe asks for.
constexpr size_t kPipeReadChunk = 64 * 1024;

/// One running pipe: the pair ids it connects and how it reports.
struct Pipe {
    int64_t src = 0;
    int64_t dst = 0;
    uint64_t token = 0;        ///< The `pipeTo` resume token; 0 when no task waits (pipeThrough, pipeStreams).
    bool closingDst = false;   ///< The pipe has closed `dst` and waits for the close to finish.
};

/// The running pipes by pipe id, for the heap generation `gen`. Eco thread only.
struct PipeTable {
    std::unordered_map<int64_t, Pipe> m;
    int64_t nextId = 1;
    uint64_t gen = 0;
    bool init = false;
};

/// Returns the pipe table, first emptying it if the heap generation has changed since it was last used.
PipeTable& pipes() {
    static auto* t = new PipeTable();   // leaked, never destroyed at exit
    uint64_t g = Allocator::instance().heapGeneration();
    if (!t->init || t->gen != g) {
        t->init = true;
        t->gen = g;
        t->m.clear();   // pipes of a dead heap are meaningless
    }
    return *t;
}

/// Returns whether `d` exists, its writable side is Open, and it can take one more value without waiting.
bool dstCanAccept(const StreamPair* d) {
    return d && d->w == WState::Open && d->waitingForRoom.empty() &&
           d->writeQ.size() < d->writeCap;
}

/// Queues encoded value `v` on `d`'s writable side as an accepted write that needs no completion. A ChannelSink
/// is sent the value's bytes (text or raw, by `textSink`) as a held channel write. No heap allocation.
void pushIntoDst(StreamPair* d, uint64_t v) {
    if (d->kind == StreamKind::ChannelSink) {
        std::string bytes = d->textSink ? toStdString(dec(v)) : toStdBytes(dec(v));   // copied before any allocation
        uint64_t req = streamHeldToken("StreamPipe.write");   // released by the dispatch
        d->writeQ.push_back(PendingWrite{req, 0, true, true});
        d->channel->requestWrite(req, std::move(bytes));
        return;
    }
    d->writeQ.push_back(PendingWrite{0, v, true, false});
}

/// Starts closing `d`'s writable side: it becomes Closing, and a ChannelSink is sent a held channel close.
/// An in-memory pair's own pump finishes the close, flushing a codec first.
void closeDst(StreamPair* d) {
    d->w = WState::Closing;
    if (d->kind == StreamKind::ChannelSink) {
        uint64_t req = streamHeldToken("StreamPipe.close");   // released by the dispatch
        d->closeToken = req;
        d->closeCounted = true;
        d->channel->close(req);
    }
}

/// Removes pipe `pid`, releases its locks and references on both pairs, and completes its `pipeTo` task, if any:
/// with Unit if `ok`, otherwise failing with `Cancelled` and `reason`. Then pumps both pairs. Does nothing for an
/// unknown `pid`. Allocates and calls Elm.
void finishPipe(int64_t pid, bool ok, const std::string& reason) {
    auto& pt = pipes();
    auto it = pt.m.find(pid);
    if (it == pt.m.end()) return;
    Pipe pp = it->second;
    pt.m.erase(it);
    auto& t = streamTable();
    if (StreamPair* s = t.find(pp.src); s && s->pipeOutId == pid) {
        s->pipeOutId = 0;
        s->pipedOut = false;
        --s->pipeRefs;
    }
    if (StreamPair* d = t.find(pp.dst); d && d->pipeInId == pid) {
        d->pipeInId = 0;
        d->pipedIn = false;
        --d->pipeRefs;
    }
    if (pp.token) {
        if (ok) streamCompleteOk(pp.token, false, alloc::unit());
        else streamCompleteErr(pp.token, false, kSErrCancelled, reason);
    }
    pumpStream(pp.src);   // erasure checks, now that the pipe is gone
    pumpStream(pp.dst);
}

/// Adds a pipe from `src` to `dst`, reporting to `token` (0 for none), takes both sides and a pipe reference on
/// each pair that exists, and returns the pipe's id. Does not schedule it.
int64_t createPipe(int64_t src, int64_t dst, uint64_t token) {
    auto& pt = pipes();
    int64_t pid = pt.nextId++;
    pt.m.emplace(pid, Pipe{src, dst, token, false});
    auto& t = streamTable();
    if (StreamPair* s = t.find(src)) {
        s->pipedOut = true;
        s->pipeOutId = pid;
        ++s->pipeRefs;
    }
    if (StreamPair* d = t.find(dst)) {
        d->pipedIn = true;
        d->pipeInId = pid;
        ++d->pipeRefs;
    }
    return pid;
}

/// Completes a `pipeTo` task at once by applying `resume` to `task`, and returns Unit. `resume` must be rooted
/// by the caller.
HPointer resumeNow(HPointer& resume, HPointer task) {
    Elm::StackRootGuard g(&task);
    Scheduler::callClosure1(resume, task);
    return alloc::unit();
}

} // namespace

bool streamPipeDemand(const StreamPair* src) {
    if (!src->pipeOutId) return false;
    auto& pt = pipes();
    auto it = pt.m.find(src->pipeOutId);
    if (it == pt.m.end() || it->second.closingDst) return false;
    return dstCanAccept(streamTable().find(it->second.dst));
}

void streamRunPipe(int64_t pid) {
    auto& t = streamTable();
    for (;;) {
        auto& pt = pipes();
        auto it = pt.m.find(pid);
        if (it == pt.m.end()) return;
        Pipe pp = it->second;   // POD copy: survives the calls below
        StreamPair* s = t.find(pp.src);
        StreamPair* d = t.find(pp.dst);

        // Waiting for the close of dst that the drained-src step started.
        if (pp.closingDst) {
            if (!d || d->w == WState::Closed) {
                finishPipe(pid, true, "");
            } else if (d->w == WState::Errored) {
                std::string reason = d->wReason;
                finishPipe(pid, false, reason);
            }
            return;
        }

        // dst errored or closed: cancel src.
        if (!d || d->w != WState::Open) {
            std::string reason = (d && d->w == WState::Errored) ? d->wReason
                                                                 : std::string(kWritableClosed);
            finishPipe(pid, false, reason);
            streamCancelReadableNow(pp.src, reason);
            return;
        }

        // src errored: cancel dst.
        if (s && s->r == RState::Errored) {
            std::string reason = s->rReason;
            finishPipe(pid, false, reason);
            streamCancelWritableNow(pp.dst, reason);
            return;
        }

        // Move one value. A mapped sink maps it first; that calls Elm, and the value has left src's scanned
        // readQ, so it is rooted across the call.
        if (s && !s->readQ.empty() && dstCanAccept(d) && d->kind == StreamKind::ChannelSink &&
            d->mapFnEnc) {
            HPointer v = dec(s->readQ.front());
            s->readQ.pop_front();
            Elm::StackRootGuard g(&v);
            int64_t tag = 0;
            bool text = false;
            std::string bytes;
            streamMapForSink(d->mapFnEnc, v, tag, text, bytes);   // calls Elm: s and d may be dangling
            if (StreamPair* dd = t.find(pp.dst); dd && dd->w == WState::Open && dd->channel) {
                uint64_t req = streamHeldToken("StreamPipe.write");   // released by the dispatch
                dd->writeQ.push_back(PendingWrite{req, 0, true, true});
                dd->channel->requestWriteTagged(req, tag, text, std::move(bytes));
            }
            pumpStream(pp.src);
            pumpStream(pp.dst);
            continue;
        }
        if (s && !s->readQ.empty() && dstCanAccept(d)) {
            uint64_t v = s->readQ.front();
            s->readQ.pop_front();
            pushIntoDst(d, v);      // no heap allocation: `v` is in writeQ now
            pumpStream(pp.src);     // room in readQ: transform more
            pumpStream(pp.dst);
            continue;
        }

        // src closed and drained (or missing): close dst. s is non-null below this step.
        bool srcDone = !s || (s->r == RState::Closed && s->readQ.empty() && s->rawQ.empty() &&
                              s->parkedReadToken == 0);
        if (srcDone) {
            it->second.closingDst = true;
            closeDst(d);
            pumpStream(pp.dst);
            continue;
        }

        // A source with nothing in readQ but a value in its writeQ: pump it. The pipe counts as a waiting
        // reader (streamPipeDemand), so the pump moves a value even with readQ at capacity. Returns rather than
        // loops: the pump schedules this pipe again.
        if (s->kind != StreamKind::ChannelSource && s->kind != StreamKind::ChannelSink &&
            s->r == RState::Open && s->readQ.empty() && !s->writeQ.empty() && dstCanAccept(d)) {
            pumpStream(pp.src);
            return;
        }

        // A MappedSource: a raw chunk already read is mapped by its pump; a read-ahead in flight gets a hold
        // while the pipe waits on it; otherwise the read-ahead is issued.
        if (s->kind == StreamKind::MappedSource && s->r == RState::Open && s->readQ.empty() &&
            dstCanAccept(d)) {
            if (!s->rawQ.empty()) {
                pumpStream(pp.src);
            } else if (s->readInFlight && s->readInFlightHold == kNoHold) {
                // Released by the read's result (mappedReadResult).
                s->readInFlightHold = Scheduler::instance().acquireHold(
                    HoldKind::Task, "StreamPipe.mappedReadAhead");
            } else if (!s->readInFlight) {
                streamMappedMaybeRead(pp.src);
            }
            return;
        }

        // A ChannelSource: the pipe reads.
        if (s->kind == StreamKind::ChannelSource && s->r == RState::Open &&
            s->parkedReadToken == 0 && s->readQ.empty() && dstCanAccept(d) && s->channel) {
            uint64_t req = streamHeldToken("StreamPipe.read");   // released by the dispatch
            s->parkedReadToken = req;
            s->parkedReadCounted = true;
            if (s->chanReadTok == 0) {
                s->chanReadTok = req;
                s->channel->requestRead(req, kPipeReadChunk);
            }   // else a withdrawn read is in flight, and its result goes to the pipe
        }
        return;
    }
}

bool pipeStreams(int64_t src, int64_t dst) {
    auto& t = streamTable();
    StreamPair* s = t.find(src);
    StreamPair* d = t.find(dst);
    if ((s && streamReadLocked(s)) || (d && streamWriteLocked(d))) return false;
    int64_t pid = createPipe(src, dst, 0);
    streamSchedulePipe(pid);
    return true;
}

// ---------------------------------------------------------------------------
// Kernel bodies
// ---------------------------------------------------------------------------

// Payload tuple2( Int transformation, Int readable ), mask 0x5. Succeeds once the pipe is started; the pipe's
// outcome is not reported.
HPointer streamPipeThroughBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(SErr,
        int64_t dst, src;
        {
            Tuple2* tp = asTuple2(captured);
            dst = tp->a.i;
            src = tp->b.i;
        }
        auto& t = streamTable();
        StreamPair* s = t.find(src);
        StreamPair* d = t.find(dst);
        if ((s && streamReadLocked(s)) || (d && streamWriteLocked(d))) {
            return failSErr(kSErrLocked, "");
        }
        int64_t pid = createPipe(src, dst, 0);
        streamSchedulePipe(pid);
        return succeedUnit();
    )
}

// Payload tuple2( Int writable, Int readable ), mask 0x5. Parks until the pipe finishes: it succeeds once dst
// has closed or is gone, and otherwise fails with Cancelled and the reason. The parked resume holds nothing.
HPointer streamPipeToBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(SErr, resume, token, counted,
        int64_t dst, src;
        {
            Tuple2* tp = asTuple2(captured);
            dst = tp->a.i;
            src = tp->b.i;
        }
        auto& t = streamTable();
        StreamPair* s = t.find(src);
        StreamPair* d = t.find(dst);
        if ((s && streamReadLocked(s)) || (d && streamWriteLocked(d))) {
            return resumeNow(resume, failSErr(kSErrLocked, ""));
        }
        token = Scheduler::instance().registerPendingResume(resume);
        int64_t pid = createPipe(src, dst, token);
        streamSchedulePipe(pid);
        return alloc::unit();
    )
}

} // namespace Eco::System
