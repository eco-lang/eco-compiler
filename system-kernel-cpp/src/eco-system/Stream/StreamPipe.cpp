//===- StreamPipe.cpp - pipeThrough / pipeTo for the eco/system streams ---===//
//
// plans/eco-system-library.md §3.5 (pipeThrough, pipeTo, propagation) and
// Phase 6 step 6.2 ("a registry of src → dst pumps, triggered from every
// state change of either pair").
//
// A pipe moves values from the readable side of `src` into the writable
// side of `dst`. While it runs it owns both sides (StreamPair::pipedOut /
// pipedIn: every other read, write, close or cancel on them fails with
// `Locked`) and keeps both pairs alive (pipeRefs). It runs as an item on the
// pump driver's work list (Stream.cpp), scheduled whenever either pair is
// pumped, so chains of pipes are driven iteratively.
//
// Each run, in order (WHATWG pipeTo defaults):
//   1. dst errored, or closed by someone else → cancel src with the reason;
//      the pipe fails with Cancelled reason.
//   2. src errored → abort dst (cancelWritable semantics) with the reason;
//      the pipe fails.
//   3. src has a value and dst has room → move it (an accepted write that
//      needs no completion; a ChannelSink gets a channel write).
//   4. src closed and drained → close dst; the pipe succeeds once dst is
//      Closed (a codec dst flushes first), or fails if the close errors.
//   5. src has nothing buffered and dst has room: an in-memory src with a
//      value waiting in its writeQ is pumped (the pipe is now a waiting
//      reader, which opens a readCap-0 gate); a ChannelSource gets one
//      channel read (Stream.cpp's channel dispatch puts the chunk into
//      src's readQ).
// A pipe is also a waiting reader for src's pump: streamPipeDemand() opens
// the readCap gate (so readCap 0 sources still flow).
//
// pipeStreams() (Stream.hpp) creates the same pipe with no Elm task, for C++
// callers: Http.Stream's upload pump pipes the request-body Readable into a
// ChannelSink over the transfer's upload channel (Phase 8).
//
// The registry holds POD only (ids, a resume token, flags): the pipeTo
// resume closure lives in the Scheduler's pendingResumes_, so no scanner is
// needed. It is cleared when the heap generation changes (F24), like the
// stream table.
//
// Channel requests issued here use synthetic tokens and hold one
// pendingAsync count each, released by the channel dispatch (G10).
// In-memory pipes hold none (an in-memory park, §3.5).
//
// Templates used: T9 (pipeTo parks and completes), G10 (channel requests).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Stream/Stream.hpp"
#include "eco-system/Stream/StreamTable.hpp"

#include <string>
#include <unordered_map>
#include <utility>

namespace Eco::System {

namespace {

constexpr const char* kWritableClosed = "WritableStream is closed";
constexpr size_t kPipeReadChunk = 64 * 1024;

struct Pipe {
    int64_t src = 0;
    int64_t dst = 0;
    uint64_t token = 0;        // pipeTo resume token (0: pipeThrough)
    bool closingDst = false;   // the pipe has closed dst and waits for it
};

struct PipeTable {
    std::unordered_map<int64_t, Pipe> m;
    int64_t nextId = 1;
    uint64_t gen = 0;
    bool init = false;
};

PipeTable& pipes() {
    static auto* t = new PipeTable();   // leaky (§3.4); main thread only
    uint64_t g = Allocator::instance().heapGeneration();
    if (!t->init || t->gen != g) {
        t->init = true;
        t->gen = g;
        t->m.clear();   // pipes of a dead heap are meaningless
    }
    return *t;
}

bool dstCanAccept(const StreamPair* d) {
    return d && d->w == WState::Open && d->waitingForRoom.empty() &&
           d->writeQ.size() < d->writeCap;
}

// Hands encoded value `v` to dst's writable side. No heap allocation.
void pushIntoDst(StreamPair* d, uint64_t v) {
    if (d->kind == StreamKind::ChannelSink) {
        std::string bytes = toStdBytes(dec(v));   // G3: copy out before the request
        uint64_t req = streamSyntheticToken();
        Scheduler::instance().incrementPendingAsync();   // released by the dispatch
        d->writeQ.push_back(PendingWrite{req, 0, true, true});
        d->channel->requestWrite(req, std::move(bytes));
        return;
    }
    d->writeQ.push_back(PendingWrite{0, v, true, false});
}

void closeDst(StreamPair* d) {
    d->w = WState::Closing;
    if (d->kind == StreamKind::ChannelSink) {
        uint64_t req = streamSyntheticToken();
        Scheduler::instance().incrementPendingAsync();   // released by the dispatch
        d->closeToken = req;
        d->closeCounted = true;
        d->channel->close(req);
    }
    // In-memory: the dst pump finishes the close (a codec flushes first).
}

// Removes pipe `pid`, releases its locks and references, and completes a
// pipeTo task. Allocates (the completion).
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

// The immediate path of a T9 body (`resume` is rooted by the guard).
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

        // 4 (second half). Waiting for the close of dst.
        if (pp.closingDst) {
            if (!d || d->w == WState::Closed) {
                finishPipe(pid, true, "");
            } else if (d->w == WState::Errored) {
                std::string reason = d->wReason;
                finishPipe(pid, false, reason);
            }
            return;
        }

        // 1. dst errored or closed → cancel src.
        if (!d || d->w != WState::Open) {
            std::string reason = (d && d->w == WState::Errored) ? d->wReason
                                                                 : std::string(kWritableClosed);
            finishPipe(pid, false, reason);
            streamCancelReadableNow(pp.src, reason);
            return;
        }

        // 2. src errored → abort dst.
        if (s && s->r == RState::Errored) {
            std::string reason = s->rReason;
            finishPipe(pid, false, reason);
            streamCancelWritableNow(pp.dst, reason);
            return;
        }

        // 3. Move one value.
        if (s && !s->readQ.empty() && dstCanAccept(d)) {
            uint64_t v = s->readQ.front();
            s->readQ.pop_front();
            pushIntoDst(d, v);      // no heap allocation: `v` is in writeQ now
            pumpStream(pp.src);     // room in readQ: transform more
            pumpStream(pp.dst);
            continue;
        }

        // 4. src closed and drained → close dst.
        bool srcDone = !s || (s->r == RState::Closed && s->readQ.empty() &&
                              s->parkedReadToken == 0);
        if (srcDone) {
            it->second.closingDst = true;
            closeDst(d);
            pumpStream(pp.dst);
            continue;
        }

        // 5a. An in-memory source with nothing transformed yet but a value
        //     waiting: the pipe is a waiting reader now, so pump the source
        //     (its gate opens through streamPipeDemand; readCap 0 sources
        //     transform only here). Progress is guaranteed: the source
        //     transforms one value, so this cannot loop.
        if (s->kind != StreamKind::ChannelSource && s->kind != StreamKind::ChannelSink &&
            s->r == RState::Open && s->readQ.empty() && !s->writeQ.empty() && dstCanAccept(d)) {
            pumpStream(pp.src);
            return;
        }

        // 5b. A channel source: the pipe reads.
        if (s->kind == StreamKind::ChannelSource && s->r == RState::Open &&
            s->parkedReadToken == 0 && s->readQ.empty() && dstCanAccept(d) && s->channel) {
            uint64_t req = streamSyntheticToken();
            Scheduler::instance().incrementPendingAsync();   // released by the dispatch
            s->parkedReadToken = req;
            s->parkedReadCounted = true;
            s->channel->requestRead(req, kPipeReadChunk);
        }
        return;
    }
}

bool pipeStreams(int64_t src, int64_t dst) {
    auto& t = streamTable();
    StreamPair* s = t.find(src);
    StreamPair* d = t.find(dst);
    if ((s && streamReadLocked(s)) || (d && streamWriteLocked(d))) return false;
    int64_t pid = createPipe(src, dst, 0);   // no task: like pipeThrough
    streamSchedulePipe(pid);
    return true;
}

// ---------------------------------------------------------------------------
// Kernel bodies (B.2)
// ---------------------------------------------------------------------------

// pipeThrough : Int -> Int -> Task SErr () — payload tuple2(Int transformation,
// Int readable), mask 0x5. Elm returns `Readable transformation`.
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
        streamSchedulePipe(pid);   // completions inside only enqueue resumes
        return succeedUnit();
    )
}

// pipeTo : Int -> Int -> Task SErr () — payload tuple2(Int writable,
// Int readable), mask 0x5. Parks until dst has been closed (Q mode).
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
