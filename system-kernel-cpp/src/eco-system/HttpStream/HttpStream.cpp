//===- HttpStream.cpp - eco/system kernel module HttpStream ---------------===//
//
// plans/eco-system-library.md Appendix B.7, E.6 and Phase 8 step 8.2: the
// `send` binding body and the main-thread drain of HttpStreamService events.
//
// `send` (async, T2 shape on HttpStreamService):
//   1. G3: the request is copied out of the heap into an HttpRequestSpec.
//      Headers are elm/http `Header` values read in place (B1a:
//      `type Header = Header String String`, constructor 0, two boxed
//      Strings — elm/http 2.0.0 Http.elm:198, read the same way by
//      elm-kernel-cpp/src/http/HttpExports.cpp extractRequest).
//   2. A stream body (bodyKind 2) must not be read-locked (it is consumed by
//      the transfer); a locked one resolves at once with NetworkError_.
//   3. The resume is registered and pendingAsync incremented (G10).
//   4. A stream body gets the upload pump: a ChannelSink over the
//      transfer's upload HttpTransferChannel, and an internal pipe
//      (Stream.hpp pipeStreams) from the Readable into it. The pipe reads
//      the stream on the main thread with the stream table's own machinery
//      (any stream kind, no Elm task), closes the sink when the Readable
//      closes (the end of the chunked body), and when the Readable errors it
//      aborts the sink, whose shutdown aborts the transfer (NetworkError_).
//      If the transfer ends first, the sink errors and the pipe cancels the
//      Readable.
//   5. The transfer thread starts; the kill handle (T7) aborts it.
//
// Drain (one event per transfer, each holding the task's pendingAsync count):
//   * Bad/GoodStatus (the headers): the body becomes a ChannelSource over the
//     download HttpTransferChannel (its reads answer EOF at once when the
//     body is discarded), the B.7 result tuple is built and the task resumes.
//     From here only parked reads of the body stream keep the program alive
//     (keep-alive rule, §3.4).
//   * BadUrl/Timeout/NetworkError (the transfer ended before the headers):
//     the result carries kind 0/1/2.
//   * A killed task (resume gone): the count is released and the transfer
//     aborted.
// A curl error after the headers reaches the body stream as an Errored
// readable with reason "network error: <curl message>" (ChannelResult
// reason), so readers get Cancelled.
//
// Result masks (B.7, G7): ( Int, String, String ) 0x1;
// ( (…), List, Int ) 0x10; ( Int, String, (…) ) 0x1.
//
// Templates used: T2 (async binding + drain), T3 (header list, one
// RootedSlots record), T7 (kill handle), G10 via AsyncRelease.
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpStream/HttpStream.hpp"
#include "eco-system/HttpStream/HttpTransfer.hpp"

#include "eco-system/Core/AsyncRelease.hpp"
#include "eco-system/Core/AsyncSources.hpp"
#include "eco-system/Stream/Stream.hpp"
#include "eco-system/Stream/StreamTable.hpp"

#include "allocator/RootedSlots.hpp"

#include <exception>
#include <string>
#include <utility>

namespace Eco::System {

namespace {

// --- Copy-out (G3; no allocation) -------------------------------------------

bool isElmTrue(HPointer b) {
    return ::Elm::hpBits(b) == ::Elm::hpBits(alloc::elmTrue());
}

// An Int tuple slot: unboxed (kind 1, the normal case) or boxed.
int64_t slotInt(const Unboxable& u, u32 kind) {
    if (kind == 1) return u.i;
    return static_cast<ElmInt*>(Allocator::instance().resolve(u.p))->value;
}

// Decodes the payload into `spec`; `streamId` is the Readable of a stream
// body (-1 otherwise).
void decodeSend(HPointer captured, HttpRequestSpec& spec, int64_t& streamId) {
    HPointer reqAndHeaders, bodyAndDiscard;
    {
        Tuple2* t = asTuple2(captured);
        reqAndHeaders = t->a.p;
        bodyAndDiscard = t->b.p;
    }
    HPointer req, headers;
    {
        Tuple2* t = asTuple2(reqAndHeaders);
        req = t->a.p;
        headers = t->b.p;
    }
    HPointer body, discard;
    {
        Tuple2* t = asTuple2(bodyAndDiscard);
        body = t->a.p;
        discard = t->b.p;
    }

    // ( method, url, timeoutMs )
    HPointer methodHP, urlHP;
    {
        Tuple3* t = asTuple3(req);
        methodHP = t->a.p;
        urlHP = t->b.p;
        spec.timeoutMs = slotInt(t->c, Elm::tupleFieldKind(t->header.unboxed, 2));
    }
    spec.method = toStdString(methodHP);
    spec.url = toStdString(urlHP);
    if (spec.timeoutMs < 0) spec.timeoutMs = 0;

    // List Http.Header (B1a): Custom ctor 0 with two boxed Strings.
    for (alloc::ListCursor c(headers); !c.done(); c.next()) {
        void* hp = Allocator::instance().resolve(c.current().p);
        if (!hp) continue;
        Custom* h = static_cast<Custom*>(hp);
        HPointer nameHP = h->values[0].p;
        HPointer valueHP = h->values[1].p;
        spec.headers.emplace_back(toStdString(nameHP), toStdString(valueHP));
    }

    // ( bodyKind, contentType, ( bytes, streamId ) )
    HPointer contentTypeHP, inner;
    {
        Tuple3* t = asTuple3(body);
        spec.bodyKind = static_cast<int>(slotInt(t->a, Elm::tupleFieldKind(t->header.unboxed, 0)));
        contentTypeHP = t->b.p;
        inner = t->c.p;
    }
    spec.contentType = toStdString(contentTypeHP);
    HPointer bytesHP;
    {
        Tuple2* t = asTuple2(inner);
        bytesHP = t->a.p;
        streamId = slotInt(t->b, Elm::tupleFieldKind(t->header.unboxed, 1));
    }
    if (spec.bodyKind == 1) spec.bytes = toStdBytes(bytesHP);
    if (spec.bodyKind != 2) streamId = -1;

    spec.discardNon2xx = isElmTrue(discard);
}

// --- Result (B.7) ------------------------------------------------------------

// List ( String, String ) in arrival order (T3: one RootedSlots record).
HPointer buildHeaderList(const HttpHeaderList& hs) {
    alloc::RootedSlots slots(hs.size());
    HPointer name = alloc::listNil();
    HPointer value = alloc::listNil();
    Elm::StackRootGuard g(&name, &value);
    for (const auto& h : hs) {
        name = alloc::allocStringFromUTF8(h.first);
        value = alloc::allocStringFromUTF8(h.second);
        slots.push(alloc::tuple2(alloc::boxed(name), alloc::boxed(value), 0));
    }
    return alloc::listFromPointers(slots);
}

// ( kind, badUrl, ( ( status, statusText, url ), headers, streamId ) ).
HPointer buildResult(const HttpEvent& ev, int64_t streamId) {
    HPointer statusText = alloc::listNil();
    HPointer url = alloc::listNil();
    HPointer meta = alloc::listNil();
    HPointer headers = alloc::listNil();
    HPointer mid = alloc::listNil();
    HPointer badUrl = alloc::listNil();
    Elm::StackRootGuard g({&statusText, &url, &meta, &headers, &mid, &badUrl});
    statusText = alloc::allocStringFromUTF8(ev.statusText);
    url = alloc::allocStringFromUTF8(ev.url);
    meta = alloc::tuple3(alloc::unboxedInt(ev.status), alloc::boxed(statusText),
                         alloc::boxed(url), 0x1);
    headers = buildHeaderList(ev.headers);
    mid = alloc::tuple3(alloc::boxed(meta), alloc::boxed(headers), alloc::unboxedInt(streamId),
                        0x10);
    badUrl = alloc::allocStringFromUTF8(ev.badUrl);
    return alloc::tuple3(alloc::unboxedInt(static_cast<int64_t>(ev.kind)), alloc::boxed(badUrl),
                         alloc::boxed(mid), 0x1);
}

// Resumes `resume` (rooted by the caller) with Task.succeed of the result.
void resumeWith(HPointer& resume, const HttpEvent& ev, int64_t streamId) {
    HPointer task = alloc::listNil();
    Elm::StackRootGuard g(&task);
    task = buildResult(ev, streamId);
    task = succeed(task);
    Scheduler::callClosure1(resume, task);
}

// --- Drain (main thread) -----------------------------------------------------

void httpStreamDrain() {
    auto& svc = HttpStreamService::instance();
    auto& sched = Scheduler::instance();
    bool resumed = false;
    HttpEvent ev;
    while (svc.tryPop(ev)) {
        AsyncRelease release;   // every event carries the task's count (G10)
        try {
            HPointer resume = sched.takePendingResume(ev.token);
            if (alloc::isNil(resume)) {
                // Killed after the event was posted: nobody gets the body.
                if (ev.transfer) HttpStreamService::abort(*ev.transfer);
                continue;
            }
            Elm::StackRootGuard g(&resume);
            int64_t streamId = -1;
            bool hasBody = ev.kind == HttpOutcome::GoodStatus || ev.kind == HttpOutcome::BadStatus;
            if (hasBody && !ev.transfer) {
                ev.kind = HttpOutcome::NetworkError;   // defensive: no body source
                hasBody = false;
            }
            if (hasBody) {
                (void)streamTable();   // the channel dispatch exists before the channel
                streamId = createChannelSource(
                    new HttpTransferChannel(ev.transfer, HttpTransferChannel::Dir::Download));
            }
            resumeWith(resume, ev, streamId);
            resumed = true;
        } catch (const std::exception& e) {
            ::Eco::Kernel::reportFatal(e.what());   // never unwind into the loop (F21)
        } catch (...) {
            ::Eco::Kernel::reportFatal("unknown native exception in the Http.Stream drain");
        }
    }
    if (resumed) sched.drain();
}

bool httpStreamReady() {
    return HttpStreamService::instance().ready();
}

bool cancelTransfer(uint64_t token) {
    return HttpStreamService::cancel(token);
}

} // namespace

HPointer httpStreamSendBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(Never, resume, token, counted,
        HttpRequestSpec spec;
        int64_t streamId = -1;
        decodeSend(captured, spec, streamId);   // G3: nothing allocates before this

        auto& sched = Scheduler::instance();
        auto& svc = HttpStreamService::instance();
        addDrainSource(&httpStreamDrain, &httpStreamReady);

        if (spec.bodyKind == 2) {
            StreamPair* src = streamTable().find(streamId);
            if (src && streamReadLocked(src)) {
                // The Readable is in use elsewhere: it cannot be consumed.
                HttpEvent ev;
                ev.kind = HttpOutcome::NetworkError;
                resumeWith(resume, ev, -1);
                return alloc::unit();
            }
        }

        token = sched.registerPendingResume(resume);
        sched.incrementPendingAsync();
        counted = true;
        bool stream = spec.bodyKind == 2;
        auto transfer = svc.create(token, std::move(spec));
        if (stream) {
            int64_t sink = createChannelSink(
                new HttpTransferChannel(transfer, HttpTransferChannel::Dir::Upload));
            (void)pipeStreams(streamId, sink);   // checked above; may pump (allocates)
        }
        svc.start(transfer);                    // on failure it posts NetworkError itself
        return makeKillHandle(token, &cancelTransfer);
    )
}

} // namespace Eco::System
