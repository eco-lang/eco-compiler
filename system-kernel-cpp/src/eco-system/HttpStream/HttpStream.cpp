//===- HttpStream.cpp - eco/system kernel module HttpStream ---------------===//
//
// Two pieces of machinery, both on the eco thread: the send body, which
// starts a transfer, and the drain, which takes the transfer's event off the
// service's queue and resumes the task.
//
// Nothing allocates on the GC heap until the request has been copied out of
// the payload into an `HttpRequestSpec`, so the payload's fields can be read
// in place without rooting. Headers are elm/http `Header` values
// (`type Header = Header String String`): a Custom whose two fields are
// Strings, read the same way as elm/http's own kernel reads them.
//
// For a stream body, a `ChannelSink` is made over the transfer's upload side
// and the Readable is piped into it with `pipeStreams`, which reads the
// stream with the stream table's own machinery and no Elm task. When the
// Readable ends the sink is closed, which ends the chunked body. When the
// Readable fails the sink is cancelled, which aborts the transfer. When the
// transfer ends first, the sink fails and the pipe cancels the Readable.
//
// The task's hold is taken when its resume is parked, and the event that
// answers the transfer carries the token; the drain releases the hold after
// handling the event. After a Bad/GoodStatus result, any further hold comes
// from work on the body stream, which Stream owns.
//
//===----------------------------------------------------------------------===//

#include "eco-system/HttpStream/HttpStream.hpp"
#include "eco-system/HttpStream/HttpTransfer.hpp"

#include "eco-system/Core/AsyncSources.hpp"
#include "eco-system/Stream/Stream.hpp"
#include "eco-system/Stream/StreamTable.hpp"

#include "allocator/RootedSlots.hpp"
#include "platform/HttpService.hpp"

#include <exception>
#include <string>
#include <utility>

namespace Eco::System {

namespace {

// --- Copy-out (no allocation) ------------------------------------------------

// Returns whether `b` is the True constant.
bool isElmTrue(HPointer b) {
    return ::Elm::hpBits(b) == ::Elm::hpBits(alloc::elmTrue());
}

// Returns the Int in a tuple slot whose kind is `kind`: the raw value when
// the kind is 1 (unboxed Int), otherwise the boxed `ElmInt` it points to.
int64_t slotInt(const Unboxable& u, u32 kind) {
    if (kind == 1) return u.i;
    return static_cast<ElmInt*>(Allocator::instance().resolve(u.p))->value;
}

// Copies the payload `captured` (laid out as `httpStreamSendBody` describes)
// into `spec`, and sets `streamId` to the Readable of a stream body, or -1
// for any other body kind. Allocates nothing on the GC heap. A header list
// element that resolves to null is skipped.
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

    for (alloc::ListCursor c(headers); !c.done(); c.next()) {
        void* hp = Allocator::instance().resolve(c.current().p);
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

// --- Result ------------------------------------------------------------------

// Builds a `List ( String, String )` of `hs`, in the same order.
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

// Builds the task's result for `ev`, with `streamId` as the body's Readable:
// `( kind, badUrl, ( ( status, statusText, url ), headers, streamId ) )`.
// Int slots are unboxed, so the masks are 0x1, 0x10 and 0x1.
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

// Resumes `resume` with a Task that succeeds with the result for `ev` and
// `streamId`. `resume` must be rooted by the caller, since building the
// result allocates.
void resumeWith(HPointer& resume, const HttpEvent& ev, int64_t streamId) {
    HPointer task = alloc::listNil();
    Elm::StackRootGuard g(&task);
    task = buildResult(ev, streamId);
    task = succeed(task);
    Scheduler::callClosure1(resume, task);
}

// --- Drain (eco thread) ------------------------------------------------------

// Delivers every queued `HttpEvent`: releases its task's hold, and resumes
// the task, first making a Readable over the download side for a Bad/
// GoodStatus event. An event whose task was killed aborts its transfer
// instead. A Bad/GoodStatus event with no transfer is delivered as
// NetworkError. An exception while handling an event is fatal. Calls
// `Scheduler::drain` afterwards if any task was resumed.
void httpStreamDrain() {
    auto& svc = HttpStreamService::instance();
    auto& sched = Scheduler::instance();
    bool resumed = false;
    HttpEvent ev;
    while (svc.tryPop(ev)) {
        HoldRelease release(ev.token);
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
                ev.kind = HttpOutcome::NetworkError;
                hasBody = false;
            }
            if (hasBody) {
                (void)streamTable();   // makes sure the channel dispatch exists before the channel
                streamId = createChannelSource(
                    new HttpTransferChannel(ev.transfer, HttpTransferChannel::Dir::Download));
            }
            resumeWith(resume, ev, streamId);
            resumed = true;
        } catch (const std::exception& e) {
            ::Eco::Kernel::reportFatal(e.what());   // never unwind into the scheduler loop
        } catch (...) {
            ::Eco::Kernel::reportFatal("unknown native exception in the Http.Stream drain");
        }
    }
    if (resumed) sched.drain();
}

// Returns whether the service has an event waiting for the drain.
bool httpStreamReady() {
    return HttpStreamService::instance().ready();
}

// The kill handle's cancel function: aborts the transfer created with `token`
// and returns whether that resolved it, so no event will arrive.
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
        decodeSend(captured, spec, streamId);   // nothing allocates before this

        auto& sched = Scheduler::instance();
        auto& svc = HttpStreamService::instance();
        addDrainSource(&httpStreamDrain, &httpStreamReady);

        if (!::Elm::Platform::HttpService::isHttpToken(spec.method)) {
            // An empty method, or one with a space, CR/LF or other separator, is not
            // HTTP (and could inject a request line): nothing is sent, as elm/http's
            // kernel (HttpService) refuses it too.
            HttpEvent ev;
            ev.kind = HttpOutcome::BadUrl;
            ev.badUrl = spec.url;
            resumeWith(resume, ev, -1);
            return alloc::unit();
        }
        if (spec.bodyKind == 2) {
            StreamPair* src = streamTable().find(streamId);
            if (src && streamReadLocked(src)) {
                // The Readable is already being read, so it cannot be the body.
                HttpEvent ev;
                ev.kind = HttpOutcome::NetworkError;
                resumeWith(resume, ev, -1);
                return alloc::unit();
            }
        }

        token = sched.parkResume(resume, HoldKind::Task, "Http.Stream.send");
        counted = true;
        bool stream = spec.bodyKind == 2;
        auto transfer = svc.create(token, std::move(spec));
        if (stream) {
            int64_t sink = createChannelSink(
                new HttpTransferChannel(transfer, HttpTransferChannel::Dir::Upload));
            (void)pipeStreams(streamId, sink);   // read lock checked above (not existence); may allocate
        }
        svc.start(transfer);                    // on failure it posts NetworkError itself
        return makeKillHandle(token, &cancelTransfer);
    )
}

} // namespace Eco::System
