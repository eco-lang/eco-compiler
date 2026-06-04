//===- HttpExports.cpp - C-linkage exports for the elm/http kernel ---------===//
//
// Implements the stock `elm/http` 2.0.0 kernel contract (Elm.Kernel.Http.*) on
// libcurl + OpenSSL. The SAME unmodified `Http.elm` runs on both the JS and
// C++ kernels, so these exports must match the stock arities and value shapes:
//
//   toTask : router -> (a -> Task) -> Request -> Task        (arity 3)
//   expect : type -> toBody -> toValue -> Expect             (arity 3)
//   pair   : a -> b -> Body                                  (arity 2)
//   emptyBody, bytesToBlob, toDataView, toFormData, mapExpect
//
// SINGLE-THREADED HEAP (HEAP_007/HEAP_011): only the main scheduler thread may
// touch the Eco heap. The actual network IO runs on Elm::Platform::HttpService
// worker threads, which exchange ONLY plain-data PODs + a uint64 token with the
// main thread. All Response/Metadata/Task construction and closure application
// happens on the main thread in the async-source drain registered with the
// Scheduler. Per-request heap continuations are rooted via the Scheduler's
// pendingResumes_ (already GC-scanned), so no worker thread ever holds an
// HPointer.
//
//===----------------------------------------------------------------------===//

#include "../KernelDebug.hpp"
#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/RootSet.hpp"
#include "platform/Scheduler.hpp"
#include "platform/HttpService.hpp"
#include "platform/PlatformRuntime.hpp"
#include <curl/curl.h>
#include <map>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::alloc;
using namespace Elm::Platform;

namespace {

// ---- Internal value shapes (kernel-private; never matched by Elm) ----------
// Body : Custom. ctor 0 = empty; ctor 1 = pair [contentType(String), content];
// ctor 2 = form-data [parts list]; ctor 3 = blob [bytes, mime].
static constexpr u16 BODY_EMPTY = 0;
static constexpr u16 BODY_PAIR  = 1;
static constexpr u16 BODY_FORM  = 2;
static constexpr u16 BODY_BLOB  = 3;
// Expect/Resolver : Custom ctor 0, fields [type(String), toBody, toValue].
static constexpr u16 EXPECT_CTOR = 0;
// Per-request continuation bundle stashed in pendingResumes_ while the request
// is in flight: Custom ctor 0, fields [resume, resultToTask, toBody, toValue, type].
static constexpr u16 BUNDLE_CTOR = 0;

// ---- Response constructor tags (Elm-observed; declaration order) -----------
//   type Response body = BadUrl_ String | Timeout_ | NetworkError_
//                      | BadStatus_ Metadata body | GoodStatus_ Metadata body
static constexpr u16 RESP_BAD_URL      = 0;
static constexpr u16 RESP_TIMEOUT      = 1;
static constexpr u16 RESP_NETWORK      = 2;
static constexpr u16 RESP_BAD_STATUS   = 3;
static constexpr u16 RESP_GOOD_STATUS  = 4;

// Dict ctor tags — reserved values the compiler assigns to elm/core Dict
// (must match CTOR_DICT_* in elm-kernel-cpp/src/core/Utils.cpp).
//   RBNode_elm_builtin NColor k v left right   (fields 0..4)
//   RBEmpty_elm_builtin                         (no fields)
static constexpr u16 CTOR_DICT_RBNODE  = 0xFFFF;
static constexpr u16 CTOR_DICT_RBEMPTY = 0xFFFE;

// ---- Stock Request record field indices (alphabetical canonical order) -----
//   { allowCookiesFromOtherDomains, body, expect, headers, method, timeout,
//     tracker, url }
static constexpr int REQ_BODY    = 1;
static constexpr int REQ_EXPECT  = 2;
static constexpr int REQ_HEADERS = 3;
static constexpr int REQ_METHOD  = 4;
static constexpr int REQ_TIMEOUT = 5;
static constexpr int REQ_TRACKER = 6;
static constexpr int REQ_URL     = 7;

// ---- Progress ctor tags (Elm-observed; declaration order) ------------------
//   type Progress = Sending { sent : Int, size : Int }
//                 | Receiving { received : Int, size : Maybe Int }
static constexpr u16 PROGRESS_SENDING   = 0;
static constexpr u16 PROGRESS_RECEIVING = 1;

// ---- Per-request progress-tracking registry (main-thread only, P3b) --------
// Maps an in-flight request token to the Http manager's router + the user's
// tracker String, so a progress tick (which carries only a token) can be
// routed via sendToSelf. Also indexes tracker -> token so Http.cancel (keyed
// by tracker) can mark a request cancelled (drop-delivery, Q-L simpler option).
//
// All access is on the main scheduler thread (toTask binding step, the
// async-source drain, and the GC scanner which runs stop-the-world on this
// thread). g_trackedMutex is defensive and is NEVER held across an Allocator
// call (which could trigger GC -> the scanner -> self-deadlock).
struct TrackedReq {
    uint64_t routerEnc = 0;   // boxed HPointer (Router Custom)
    uint64_t trackerEnc = 0;  // boxed HPointer (tracker String)
    bool     cancelled = false;
};
std::mutex g_trackedMutex;
std::unordered_map<uint64_t, TrackedReq> g_httpTracked;     // token -> req
std::unordered_map<std::string, uint64_t> g_trackerToken;   // tracker -> token

std::string elmStringToUTF8(uint64_t strEnc) {
    HPointer hp = Export::decode(strEnc);
    if (hp.constant == Const_EmptyString + 1) return "";
    void* ptr = Export::toPtr(strEnc);
    if (!ptr) return "";
    return Elm::StringOps::toStdString(ptr);
}

static inline uint64_t encodeHP(HPointer h) {
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}
static inline HPointer decodeHP(uint64_t val) {
    union { HPointer hp; uint64_t val; } u;
    u.val = val;
    return u.hp;
}

// Constant-safe resolve: embedded constants (Nil, Nothing, True/False, Unit,
// EmptyString) have a non-zero constant field and must not be passed to
// Allocator::resolve (which asserts). Returns nullptr for those.
static inline void* resolveOrNull(HPointer hp) {
    if (hp.constant != 0) return nullptr;
    return Allocator::instance().resolve(hp);
}

// HTTP status code -> a short reason phrase (curl does not surface it).
const char* reasonPhrase(long code) {
    switch (code) {
        case 200: return "OK";
        case 201: return "Created";
        case 204: return "No Content";
        case 301: return "Moved Permanently";
        case 302: return "Found";
        case 400: return "Bad Request";
        case 401: return "Unauthorized";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 500: return "Internal Server Error";
        case 503: return "Service Unavailable";
        default:  return "";
    }
}

// Build an elm/core `Dict String String` from the response headers. The Dict
// is only ever READ by user code (Dict.get/toList), which ignores node colour,
// so we build a valid BST (left-empty, right-chain over keys sorted ascending)
// without red-black balancing. std::map gives sorted, dedup (last-wins) keys.
HPointer rbEmpty() {
    std::vector<Unboxable> v;
    return custom(CTOR_DICT_RBEMPTY, v, 0);
}

HPointer buildHeadersDict(const std::vector<std::pair<std::string, std::string>>& hdrs) {
    std::map<std::string, std::string> sorted;
    for (auto& kv : hdrs) sorted[kv.first] = kv.second;

    HPointer tree = rbEmpty();
    Elm::StackRootGuard treeRoot(&tree);
    for (auto it = sorted.rbegin(); it != sorted.rend(); ++it) {
        HPointer key = allocStringFromUTF8(it->first);
        HPointer val = listNil();
        {
            Elm::StackRootGuard g(&key);
            val = allocStringFromUTF8(it->second);
        }
        HPointer left = listNil();
        {
            Elm::StackRootGuard g({&key, &val});
            left = rbEmpty();
        }
        // RBNode color k v left right; colour is read-only-irrelevant here so a
        // Unit placeholder is fine (never pattern-matched without rebalancing).
        Elm::StackRootGuard g({&key, &val, &left});
        std::vector<Unboxable> fields(5);
        fields[0].p = unit();
        fields[1].p = key;
        fields[2].p = val;
        fields[3].p = left;
        fields[4].p = tree;
        tree = custom(CTOR_DICT_RBNODE, fields, 0);
    }
    return tree;
}

// Build the Metadata record { headers, statusCode, statusText, url }.
HPointer buildMetadata(const HttpService::Result& r) {
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();

    HPointer headers = buildHeadersDict(r.headers);
    rs.pushStackRootRange(&headers, 1, 1);
    HPointer statusText = allocStringFromUTF8(
        r.statusText.empty() ? std::string(reasonPhrase(r.status)) : r.statusText);
    rs.pushStackRootRange(&statusText, 1, 1);
    HPointer url = allocStringFromUTF8(r.finalUrl);

    // computeRecordLayout (Types.elm) orders fields as unboxed-first (sorted),
    // then boxed (sorted). Metadata { headers, statusCode:Int, statusText, url }
    // => physical [ statusCode(0,Int), headers(1), statusText(2), url(3) ].
    std::vector<Unboxable> fields(4);
    fields[0].i = static_cast<i64>(r.status);  // statusCode (unboxed Int, slot 0)
    fields[1].p = headers;
    fields[2].p = statusText;
    fields[3].p = url;
    HPointer md = record(fields, (u64{1} << 0));  // slot0 kind=01 (Int)
    rs.restoreStackRangePoint(saved);
    return md;
}

// Build a `Response body` Custom from the worker result and the materialised
// `body` value. Runs on the main thread.
HPointer buildResponse(const HttpService::Result& r, HPointer body) {
    using EK = HttpService::ErrorKind;
    if (r.error == EK::Timeout) {
        std::vector<Unboxable> v;
        return custom(RESP_TIMEOUT, v, 0);
    }
    if (r.error == EK::NetworkError) {
        std::vector<Unboxable> v;
        return custom(RESP_NETWORK, v, 0);
    }
    if (r.error == EK::BadUrl) {
        HPointer url = allocStringFromUTF8(r.finalUrl);
        std::vector<Unboxable> v(1);
        v[0].p = url;
        return custom(RESP_BAD_URL, v, 0);
    }
    // Ok: GoodStatus_ for 2xx else BadStatus_; both carry [metadata, body].
    Elm::StackRootGuard bodyRoot(&body);
    HPointer md = buildMetadata(r);
    Elm::StackRootGuard mdRoot(&md);
    std::vector<Unboxable> v(2);
    v[0].p = md;
    v[1].p = body;
    bool good = (r.status >= 200 && r.status < 300);
    return custom(good ? RESP_GOOD_STATUS : RESP_BAD_STATUS, v, 0);
}

// ---- Tracking registry helpers (main thread) -------------------------------

// Register a tracked request. trackerStr is computed here (no Allocator call)
// and held only as a std::string key.
void httpRegisterTracked(uint64_t token, HPointer router, HPointer tracker) {
    std::string trackerStr = elmStringToUTF8(encodeHP(tracker));
    ECO_KLOG("elm-http", "track-register token=%lu tracker=%s",
             (unsigned long)token, trackerStr.c_str());
    std::lock_guard<std::mutex> lk(g_trackedMutex);
    g_httpTracked[token] = TrackedReq{encodeHP(router), encodeHP(tracker), false};
    g_trackerToken[trackerStr] = token;
}

// Clear a token's tracking on final result. Returns whether it was cancelled
// (so the caller can drop delivery). Reads the stored tracker String (no alloc)
// to remove the tracker -> token index entry if it still points at this token.
bool httpClearTracked(uint64_t token) {
    std::lock_guard<std::mutex> lk(g_trackedMutex);
    auto it = g_httpTracked.find(token);
    if (it == g_httpTracked.end()) return false;
    bool cancelled = it->second.cancelled;
    std::string trackerStr = elmStringToUTF8(it->second.trackerEnc);
    ECO_KLOG("elm-http", "track-clear token=%lu cancelled=%d",
             (unsigned long)token, (int)cancelled);
    auto ti = g_trackerToken.find(trackerStr);
    if (ti != g_trackerToken.end() && ti->second == token) g_trackerToken.erase(ti);
    g_httpTracked.erase(it);
    return cancelled;
}

// GC scanner over the tracking registry (P3c). Runs stop-the-world on the main
// thread; evacuates the router + tracker HPointers in place. Never allocates.
void httpRegisterScannerOnce() {
    static std::once_flag flag;
    std::call_once(flag, []() {
        Allocator::instance().getRootSet().addExternalRootScanner(
            [](RootSet::EvacuateFn evac) {
                std::lock_guard<std::mutex> lock(g_trackedMutex);
                for (auto& [token, tr] : g_httpTracked) {
                    evac(tr.routerEnc);
                    evac(tr.trackerEnc);
                }
            });
    });
}

// ---- Progress value construction (P5, main thread) -------------------------
// upload   -> Sending  { sent : Int, size : Int }       ctor 0
// download -> Receiving{ received : Int, size : Maybe Int } ctor 1
HPointer buildProgress(bool isUpload, uint64_t now, uint64_t total) {
    if (isUpload) {
        // record { sent, size } — both unboxed Int; computeRecordLayout orders
        // unboxed-first (alphabetical): [sent(slot0,Int), size(slot1,Int)].
        // 2-bit mask: slot0=01, slot1=01 -> 0b0101.
        std::vector<Unboxable> rf(2);
        rf[0] = unboxedInt(static_cast<i64>(now));    // sent
        rf[1] = unboxedInt(static_cast<i64>(total));  // size
        HPointer rec = record(rf, 0x5);
        Elm::StackRootGuard g(&rec);
        std::vector<Unboxable> cf(1);
        cf[0] = boxed(rec);
        return custom(PROGRESS_SENDING, cf, 0);
    }
    // size : Maybe Int — Just total when known, else Nothing (chunked).
    HPointer size = (total > 0)
        ? justKind(unboxedInt(static_cast<i64>(total)), /*kind=Int*/1)
        : nothing();
    Elm::StackRootGuard sg(&size);
    // record { received, size } — received unboxed Int, size boxed Maybe;
    // unboxed-first order: [received(slot0,Int), size(slot1,boxed)].
    // 2-bit mask: slot0=01, slot1=00 -> 0b0001.
    std::vector<Unboxable> rf(2);
    rf[0] = unboxedInt(static_cast<i64>(now));  // received
    rf[1] = boxed(size);                         // size : Maybe Int
    HPointer rec = record(rf, 0x1);
    Elm::StackRootGuard rg(&rec);
    std::vector<Unboxable> cf(1);
    cf[0] = boxed(rec);
    return custom(PROGRESS_RECEIVING, cf, 0);
}

// Drain progress ticks (P4a). For each, look up the token's (router, tracker),
// build a Progress value, wrap it in the SelfMsg tuple (tracker, progress), and
// route it to the Http manager self-process via sendToSelf -> onSelfMsg.
void httpDrainProgress() {
    HttpService::Progress ev;
    while (HttpService::instance().tryPopProgress(ev)) {
        ECO_KLOG("elm-http",
                 "progress token=%lu upload=%d now=%lu total=%lu",
                 (unsigned long)ev.token, (int)ev.isUpload,
                 (unsigned long)ev.now, (unsigned long)ev.total);
        uint64_t routerEnc = 0, trackerEnc = 0;
        bool found = false, cancelled = false;
        {
            std::lock_guard<std::mutex> lk(g_trackedMutex);
            auto it = g_httpTracked.find(ev.token);
            if (it != g_httpTracked.end()) {
                routerEnc = it->second.routerEnc;
                trackerEnc = it->second.trackerEnc;
                cancelled = it->second.cancelled;
                found = true;
            }
        }
        if (!found || cancelled) continue;  // untracked or cancelled: drop

        // Root the decoded locals before any allocation: the scanner keeps the
        // registry entries alive, but these stack copies need their own roots
        // so GC updates them in place across buildProgress / tuple2.
        HPointer router = decodeHP(routerEnc);
        HPointer tracker = decodeHP(trackerEnc);
        HPointer progress = listNil();
        HPointer selfMsg = listNil();
        Elm::StackRootGuard g({&router, &tracker, &progress, &selfMsg});
        progress = buildProgress(ev.isUpload, ev.now, ev.total);
        selfMsg = tuple2(boxed(tracker), boxed(progress), 0);  // (tracker, progress)
        PlatformRuntime::instance().sendToSelf(router, selfMsg);

        // Deliver this tick (step the manager self-process -> onSelfMsg ->
        // sendToApp) before popping the next. sendToSelf only *enqueues* the
        // self-process; because Process is immutable, enqueuing multiple ticks
        // before stepping would leave several snapshots whose mailboxes overlap,
        // and stepping each would re-deliver earlier ticks. Draining per tick
        // keeps the mailbox at one message and delivers each exactly once
        // (per-tick scheduler step, Q-G).
        Scheduler::instance().drain();
    }
}

// ---- Main-thread async-source drain ----------------------------------------
// Pops completed worker results and, for each, resumes the matching binding on
// the main thread: build Response -> apply expect.toBody/toValue -> apply
// resultToTask -> resume(resultTask).
void httpDrain() {
    // Drain progress first (delivering each tick fully, see httpDrainProgress)
    // so all progress reaches the app before the final result is delivered:
    // result delivery (httpSuccessHandler) calls sendToApp synchronously, so
    // progress must be flushed first to preserve the track API's "progress
    // before final result" ordering (P2c).
    httpDrainProgress();

    HttpService::Result r;
    while (HttpService::instance().tryPopResult(r)) {
        ECO_KLOG("elm-http",
                 "drain token=%lu err=%d status=%ld body=%zuB",
                 (unsigned long)r.token, (int)r.error, r.status, r.body.size());
        // Clear tracking for this token (no-op for untracked). If it was
        // cancelled via Http.cancel, drop the result without resuming.
        bool cancelled = httpClearTracked(r.token);
        HPointer bundle = Scheduler::instance().takePendingResume(r.token);
        if (alloc::isNil(bundle) || cancelled) {
            // Cancelled or unknown token: drop the pending-async count.
            Scheduler::instance().decrementPendingAsync();
            continue;
        }
        Elm::StackRootGuard bundleRoot(&bundle);

        // Materialise the raw body per the expect type (bundle.values[4]):
        // "" => an Elm String (UTF-8); "arraybuffer" => Elm Bytes (ByteBuffer).
        // The expect.toBody closure (identity / toDataView) is applied below.
        bool wantBytes;
        {
            void* bp = Allocator::instance().resolve(bundle);
            HPointer typeHP = static_cast<Custom*>(bp)->values[4].p;
            wantBytes = (elmStringToUTF8(encodeHP(typeHP)) == "arraybuffer");
        }
        HPointer rawBody;
        if (wantBytes) {
            rawBody = allocByteBuffer(
                reinterpret_cast<const u8*>(r.body.data()), r.body.size());
        } else {
            rawBody = allocStringFromUTF8(r.body);
        }
        Elm::StackRootGuard rawRoot(&rawBody);

        // toBody = bundle.values[2]
        HPointer body;
        {
            void* bp = Allocator::instance().resolve(bundle);
            HPointer toBody = static_cast<Custom*>(bp)->values[2].p;
            body = Scheduler::instance().callClosure1(toBody, rawBody);
        }
        Elm::StackRootGuard bodyRoot(&body);

        HPointer response = buildResponse(r, body);
        Elm::StackRootGuard respRoot(&response);

        // value = toValue(response); toValue = bundle.values[3]
        HPointer value;
        {
            void* bp = Allocator::instance().resolve(bundle);
            HPointer toValue = static_cast<Custom*>(bp)->values[3].p;
            value = Scheduler::instance().callClosure1(toValue, response);
        }
        Elm::StackRootGuard valueRoot(&value);

        // resultTask = resultToTask(value); resultToTask = bundle.values[1]
        HPointer resultTask;
        {
            void* bp = Allocator::instance().resolve(bundle);
            HPointer resultToTask = static_cast<Custom*>(bp)->values[1].p;
            resultTask = Scheduler::instance().callClosure1(resultToTask, value);
        }
        Elm::StackRootGuard taskRoot(&resultTask);

        // resume(resultTask); resume = bundle.values[0]
        {
            void* bp = Allocator::instance().resolve(bundle);
            HPointer resume = static_cast<Custom*>(bp)->values[0].p;
            Scheduler::instance().callClosure1(resume, resultTask);
        }
        Scheduler::instance().decrementPendingAsync();
    }
}

void httpEnsureRegistered() {
    static std::once_flag flag;
    std::call_once(flag, []() {
        httpRegisterScannerOnce();
        Scheduler::instance().registerAsyncSource(
            httpDrain,
            []() {
                return HttpService::instance().hasReadyResults()
                    || HttpService::instance().hasProgress();
            });
    });
}

// Read the stock Request record into a worker POD + extract the expect's
// toBody/toValue closures. Runs on the main thread (binding step).
struct ExtractedRequest {
    HttpService::Request pod;
    HPointer type;     // expect.__type: "" (String body) or "arraybuffer" (Bytes)
    HPointer toBody;
    HPointer toValue;
    HPointer trackerHP = {};  // tracker String (valid only when tracked)
    bool tracked = false;     // request.tracker == Just _
    bool ok = false;
};

ExtractedRequest extractRequest(HPointer requestHP) {
    ExtractedRequest out;
    void* ptr = Allocator::instance().resolve(requestHP);
    if (!ptr) return out;
    Record* req = static_cast<Record*>(ptr);

    out.pod.method = elmStringToUTF8(encodeHP(req->values[REQ_METHOD].p));
    out.pod.url    = elmStringToUTF8(encodeHP(req->values[REQ_URL].p));

    // headers : List Header, Header = Header String String (Custom ctor 0).
    HPointer headersList = req->values[REQ_HEADERS].p;
    while (!isNil(headersList)) {
        void* cellPtr = resolveOrNull(headersList);
        if (!cellPtr) break;
        Cons* cell = static_cast<Cons*>(cellPtr);
        void* hPtr = resolveOrNull(cell->head.p);
        if (hPtr) {
            Custom* hdr = static_cast<Custom*>(hPtr);
            std::string key = elmStringToUTF8(encodeHP(hdr->values[0].p));
            std::string val = elmStringToUTF8(encodeHP(hdr->values[1].p));
            out.pod.headers.push_back({key, val});
        }
        headersList = cell->tail;
    }

    // body : Body (Custom). empty => no body; pair => [contentType, content].
    void* bodyPtr = resolveOrNull(req->values[REQ_BODY].p);
    if (bodyPtr) {
        Custom* body = static_cast<Custom*>(bodyPtr);
        if (body->ctor == BODY_PAIR) {
            out.pod.contentType = elmStringToUTF8(encodeHP(body->values[0].p));
            // content is usually a String (stringBody/jsonBody). multipartBody
            // wraps a BODY_FORM here; serialise it to multipart/form-data.
            HPointer content = body->values[1].p;
            void* cp = resolveOrNull(content);
            bool isForm = cp && static_cast<Header*>(cp)->tag == Tag_Custom &&
                          static_cast<Custom*>(cp)->ctor == BODY_FORM;
            if (isForm) {
                const std::string boundary = "EcoBoundary7MA4YWxkTrZu0gW";
                HPointer partsList = static_cast<Custom*>(cp)->values[0].p;
                std::string mp;
                while (!isNil(partsList)) {
                    void* cellPtr = resolveOrNull(partsList);
                    if (!cellPtr) break;
                    Cons* cell = static_cast<Cons*>(cellPtr);
                    void* partPtr = resolveOrNull(cell->head.p);
                    if (partPtr) {
                        Custom* part = static_cast<Custom*>(partPtr);  // pair [key, value]
                        std::string key = elmStringToUTF8(encodeHP(part->values[0].p));
                        std::string val = elmStringToUTF8(encodeHP(part->values[1].p));
                        mp += "--" + boundary + "\r\n";
                        mp += "Content-Disposition: form-data; name=\"" + key + "\"\r\n\r\n";
                        mp += val + "\r\n";
                    }
                    partsList = cell->tail;
                }
                mp += "--" + boundary + "--\r\n";
                out.pod.body = mp;
                out.pod.contentType = "multipart/form-data; boundary=" + boundary;
            } else {
                out.pod.body = elmStringToUTF8(encodeHP(content));
            }
        }
    }

    // timeout : Maybe Float (Just => ctor 1, field 0 is the Float ms). Nothing
    // is an embedded constant (resolveOrNull => nullptr => no timeout).
    void* toPtr = resolveOrNull(req->values[REQ_TIMEOUT].p);
    if (toPtr) {
        // Nothing is an embedded constant (filtered above), so a resolved value
        // is `Just <Float ms>` — the Float is at field 0 (unboxed).
        Custom* mt = static_cast<Custom*>(toPtr);
        out.pod.timeoutMs = static_cast<long>(mt->values[0].f);
    }

    // tracker : Maybe String (Just => Custom, field 0 is the tracker String;
    // Nothing => embedded constant => resolveOrNull yields nullptr => untracked).
    void* trPtr = resolveOrNull(req->values[REQ_TRACKER].p);
    if (trPtr) {
        out.trackerHP = static_cast<Custom*>(trPtr)->values[0].p;
        out.tracked = true;
    }

    // expect : Expect (Custom ctor 0) [type, toBody, toValue].
    void* expectPtr = resolveOrNull(req->values[REQ_EXPECT].p);
    if (!expectPtr) return out;
    Custom* expect = static_cast<Custom*>(expectPtr);
    out.type    = expect->values[0].p;
    out.toBody  = expect->values[1].p;
    out.toValue = expect->values[2].p;
    out.ok = true;
    return out;
}

// Binding evaluator (main thread). Captures: args[0]=request,
// args[1]=resultToTask, args[2]=router. Scheduler appends the resume closure
// as args[3].
void* httpBindingEval(void* args[]) {
    HPointer request      = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer resultToTask = decodeHP(reinterpret_cast<uint64_t>(args[1]));
    HPointer router       = decodeHP(reinterpret_cast<uint64_t>(args[2]));
    HPointer resume       = decodeHP(reinterpret_cast<uint64_t>(args[3]));

    ExtractedRequest ex = extractRequest(request);
    if (!ex.ok) {
        // Malformed expect: resume immediately with NetworkError -> resultToTask.
        return reinterpret_cast<void*>(encodeHP(unit()));
    }

    // Build the continuation bundle [resume, resultToTask, toBody, toValue, type]
    // and register it; the Scheduler's pendingResumes_ scanner keeps it rooted.
    HPointer toBody = ex.toBody;
    HPointer toValue = ex.toValue;
    HPointer type = ex.type;
    HPointer trackerHP = ex.trackerHP;
    Elm::StackRootGuard g({&resume, &resultToTask, &toBody, &toValue, &type,
                           &router, &trackerHP});
    std::vector<Unboxable> fields(5);
    fields[0].p = resume;
    fields[1].p = resultToTask;
    fields[2].p = toBody;
    fields[3].p = toValue;
    fields[4].p = type;
    HPointer bundle = custom(BUNDLE_CTOR, fields, 0);

    u64 token = Scheduler::instance().registerPendingResume(bundle);
    Scheduler::instance().incrementPendingAsync();

    // Tracked request (tracker == Just _): register (router, tracker) so the
    // worker's progress ticks route to the Http manager self-process (P3b).
    if (ex.tracked) {
        httpRegisterTracked(token, router, trackerHP);
    }

    ex.pod.token = token;
    HttpService::instance().submit(std::move(ex.pod));

    // Kill handle: Unit. Http.cancel is implemented as drop-delivery in the
    // tracking registry (Q-L simpler option), not via this kill handle.
    return reinterpret_cast<void*>(encodeHP(unit()));
}

// mapExpect composition: newToValue(response) = func(oldToValue(response)).
// Captures: args[0]=func, args[1]=oldToValue, args[2]=response.
void* mapExpectEvaluator(void* args[]) {
    uint64_t funcEnc     = reinterpret_cast<uint64_t>(args[0]);
    uint64_t oldEnc      = reinterpret_cast<uint64_t>(args[1]);
    uint64_t responseEnc = reinterpret_cast<uint64_t>(args[2]);

    HPointer func = decodeHP(funcEnc);
    Elm::StackRootGuard funcRoot(&func);
    uint64_t midEnc = eco_apply_closure(HPtr::fromBits(oldEnc), &responseEnc, 1).toBits();
    uint64_t funcArg = midEnc;
    HPtr res = eco_apply_closure(HPtr::fromBits(encodeHP(func)), &funcArg, 1);
    return reinterpret_cast<void*>(res.toBits());
}

} // anonymous namespace

// Kernel symbol names are NOT arbitrary: the compiler binds an Elm
// `Elm.Kernel.Http.<fn>` reference to the external C symbol `Elm_Kernel_Http_<fn>`
// by the dot->underscore convention in canonicalToMLIRName
// (compiler/src/Compiler/Generate/MLIR/Names.elm:18). These exports must keep
// that exact spelling, and each is registered for the JIT in
// runtime/src/codegen/RuntimeSymbols.cpp.
extern "C" {

// emptyBody : Body
HPtr Elm_Kernel_Http_emptyBody() {
    std::vector<Unboxable> v;
    return HPtr::fromBits(Export::encode(custom(BODY_EMPTY, v, 0)));
}

// pair : a -> b -> Body  (also stringBody/jsonBody/stringPart/filePart/bytesBody)
HPtr Elm_Kernel_Http_pair(HPtr a, HPtr b) {
    HPointer aHP = Export::decode(a.toBits());
    HPointer bHP = Export::decode(b.toBits());
    Elm::StackRootGuard g(&aHP, &bHP);
    std::vector<Unboxable> v(2);
    v[0].p = aHP;
    v[1].p = bHP;
    return HPtr::fromBits(Export::encode(custom(BODY_PAIR, v, 0)));
}

// toTask : router -> (a -> Task x b) -> Request -> Task x b
HPtr Elm_Kernel_Http_toTask(HPtr router, HPtr resultToTask, HPtr request) {
    httpEnsureRegistered();

    HPointer reqHP    = Export::decode(request.toBits());
    HPointer rttHP    = Export::decode(resultToTask.toBits());
    HPointer routerHP = Export::decode(router.toBits());
    Elm::StackRootGuard g({&reqHP, &rttHP, &routerHP});

    // Binding closure captures [request, resultToTask, router]; arity = 3
    // captures + 1 scheduler-supplied resume arg. The router is needed so the
    // binding step can register progress tracking for a tracked request.
    HPointer bindingCallback = allocClosureK(httpBindingEval, 4, Elm::PK_Boxed);
    void* clPtr = Allocator::instance().resolve(bindingCallback);
    if (clPtr) {
        closureCapture(clPtr, boxed(reqHP), true);
        closureCapture(clPtr, boxed(rttHP), true);
        closureCapture(clPtr, boxed(routerHP), true);
    }
    HPointer task = Scheduler::instance().taskBinding(bindingCallback);
    return HPtr::fromBits(Export::encode(task));
}

// Mark a tracked request cancelled by its tracker string (drop-delivery). The
// pending result, when it arrives, is dropped without resuming, and any further
// progress ticks are ignored. Called by the Http effect manager's Cancel branch.
void Eco_Http_cancelTracker(uint64_t trackerEnc) {
    std::string trackerStr = elmStringToUTF8(trackerEnc);
    std::lock_guard<std::mutex> lk(g_trackedMutex);
    auto ti = g_trackerToken.find(trackerStr);
    if (ti == g_trackerToken.end()) {
        ECO_KLOG("elm-http", "cancel tracker=%s unknown",
                 trackerStr.c_str());
        return;
    }
    ECO_KLOG("elm-http", "cancel tracker=%s token=%lu",
             trackerStr.c_str(), (unsigned long)ti->second);
    auto it = g_httpTracked.find(ti->second);
    if (it != g_httpTracked.end()) it->second.cancelled = true;
}

// expect : type -> toBody -> toValue -> Expect
HPtr Elm_Kernel_Http_expect(HPtr type, HPtr toBody, HPtr toValue) {
    HPointer typeHP    = Export::decode(type.toBits());
    HPointer toBodyHP  = Export::decode(toBody.toBits());
    HPointer toValueHP = Export::decode(toValue.toBits());
    Elm::StackRootGuard g(&typeHP, &toBodyHP, &toValueHP);
    std::vector<Unboxable> v(3);
    v[0].p = typeHP;
    v[1].p = toBodyHP;
    v[2].p = toValueHP;
    return HPtr::fromBits(Export::encode(custom(EXPECT_CTOR, v, 0)));
}

// mapExpect : (a -> b) -> Expect a -> Expect b
HPtr Elm_Kernel_Http_mapExpect(HPtr closure, HPtr expectVal) {
    void* expectPtr = Export::toPtr(expectVal.toBits());
    if (!expectPtr) return expectVal;
    Custom* expect = static_cast<Custom*>(expectPtr);
    HPointer type    = expect->values[0].p;
    HPointer toBody  = expect->values[1].p;
    HPointer oldTV   = expect->values[2].p;
    HPointer func    = Export::decode(closure.toBits());

    Elm::StackRootGuard g(&type, &toBody, &oldTV, &func);
    HPointer composed = allocClosureK(mapExpectEvaluator, 3, Elm::PK_Boxed);
    void* clPtr = Allocator::instance().resolve(composed);
    if (clPtr) {
        closureCapture(clPtr, boxed(func), true);
        closureCapture(clPtr, boxed(oldTV), true);
    }
    Elm::StackRootGuard cg(&composed);
    std::vector<Unboxable> v(3);
    v[0].p = type;
    v[1].p = toBody;
    v[2].p = composed;
    return HPtr::fromBits(Export::encode(custom(EXPECT_CTOR, v, 0)));
}

// bytesToBlob : String -> Bytes -> Body content  (Phase-2 multipart helper)
HPtr Elm_Kernel_Http_bytesToBlob(HPtr bytes, HPtr mimeType) {
    HPointer bytesHP = Export::decode(bytes.toBits());
    HPointer mimeHP  = Export::decode(mimeType.toBits());
    Elm::StackRootGuard g(&bytesHP, &mimeHP);
    std::vector<Unboxable> v(2);
    v[0].p = bytesHP;
    v[1].p = mimeHP;
    return HPtr::fromBits(Export::encode(custom(BODY_BLOB, v, 0)));
}

// toDataView : Bytes -> body  (used as expect.toBody for the bytes path).
// Eco `Bytes` is already a ByteBuffer, so this is identity.
HPtr Elm_Kernel_Http_toDataView(HPtr bytes) {
    return bytes;
}

// toFormData : List Part -> body  (Phase-2 multipart).
HPtr Elm_Kernel_Http_toFormData(HPtr parts) {
    HPointer partsHP = Export::decode(parts.toBits());
    Elm::StackRootGuard g(&partsHP);
    std::vector<Unboxable> v(1);
    v[0].p = partsHP;
    return HPtr::fromBits(Export::encode(custom(BODY_FORM, v, 0)));
}

// Global curl init/teardown.
__attribute__((constructor))
static void initCurl() { curl_global_init(CURL_GLOBAL_DEFAULT); }
__attribute__((destructor))
static void cleanupCurl() { curl_global_cleanup(); }

} // extern "C"
