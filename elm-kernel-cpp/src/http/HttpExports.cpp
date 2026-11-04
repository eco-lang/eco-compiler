//===- HttpExports.cpp - C-linkage exports for the elm/http kernel ---------===//
//
// The stock `elm/http` 2.0.0 package calls a small kernel (`Http.toTask`,
// `Http.expect`, `Http.mapExpect` and the body builders), and this file is
// that kernel for native programs, built on `Elm::Platform::HttpService`. The
// package's `Http.elm` is used unmodified, so every export keeps the stock
// arity and builds the value shapes the stock kernel builds.
//
// Two facts shape the file. First, only the eco thread (the thread that runs
// the Elm scheduler) may touch the heap, while the transfers run on
// `HttpService`'s worker thread. The two sides trade only plain data: a
// `HttpService::Request` going out, and a `HttpService::Result` or
// `HttpService::Progress` coming back, each tagged with a `uint64_t` token.
// Everything that reads or builds an Elm value runs on the eco thread.
//
// Second, a request is a Task, and the Task only starts when the scheduler
// runs its binding (`httpBindingEval`). The binding reads the Elm `Request`
// record into a `HttpService::Request`, parks a continuation bundle with
// `Scheduler::parkResume` (which returns the token and takes a hold under it,
// as `Liveness.hpp` defines a hold), submits the request, and returns a kill
// handle. The async-source drain (`httpDrain`) later pops each result, builds
// the Elm `Response`, runs the expect's closures and resumes the task. The
// hold is released exactly once, by whichever path ends the request.
//
// Most of the remaining state serves `Http.track` and `Http.cancel`, which
// name a request by a tracker String rather than by its token. Stock elm/http
// keeps a process id per tracker from the moment its manager spawns the
// request; here the token exists only once the binding runs, so a cancel that
// arrives earlier is caught by a spawn ticket instead. A tracker reused by a
// newer request is re-pointed at it, and the older request runs on and can
// no longer be cancelled, as in stock elm/http.
//
//===----------------------------------------------------------------------===//

#include "../KernelDebug.hpp"
#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "HttpRequestLayout.hpp"
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
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::alloc;
using namespace Elm::Platform;

namespace {

// Kernel-private value shapes. Elm code never pattern-matches these; only this
// file builds and reads them.

/// The constructor of an empty `Body`, a Custom with no fields.
static constexpr u16 BODY_EMPTY = 0;
/// The constructor of a `pair` value, a Custom with fields [first, second].
/// It is a `Body` as [content type, content] and a multipart `Part` as
/// [name, value].
static constexpr u16 BODY_PAIR  = 1;
/// The constructor of a multipart form, a Custom with fields [list of parts].
static constexpr u16 BODY_FORM  = 2;
/// The constructor of a blob, a Custom holding `bytesToBlob`'s two arguments
/// in order.
static constexpr u16 BODY_BLOB  = 3;
/// The constructor of an `Expect`, a Custom with fields [type String, toBody,
/// toValue].
static constexpr u16 EXPECT_CTOR = 0;
/// The constructor of a request's continuation bundle, parked while the
/// request is in flight: a Custom with fields [resume, resultToTask, toBody,
/// toValue, type].
static constexpr u16 BUNDLE_CTOR = 0;

// Constructor tags of elm/http's
//   type Response body = BadUrl_ String | Timeout_ | NetworkError_
//                      | BadStatus_ Metadata body | GoodStatus_ Metadata body
// which are its declaration indexes and must stay in step with `Http.elm`.

/// The tag of `BadUrl_`.
static constexpr u16 RESP_BAD_URL      = 0;
/// The tag of `Timeout_`.
static constexpr u16 RESP_TIMEOUT      = 1;
/// The tag of `NetworkError_`.
static constexpr u16 RESP_NETWORK      = 2;
/// The tag of `BadStatus_`.
static constexpr u16 RESP_BAD_STATUS   = 3;
/// The tag of `GoodStatus_`.
static constexpr u16 RESP_GOOD_STATUS  = 4;

/// The constructor tag of elm/core's `RBNode_elm_builtin color key value left
/// right`, a reserved tag rather than a declaration index. It must agree with
/// the value of the same name in `core/Utils.cpp` and with the compiler's
/// `Compiler.Data.CtorTag`.
static constexpr u16 CTOR_DICT_RBNODE  = 0xFFFF;
/// The constructor tag of `RBEmpty_elm_builtin`, its declaration index.
static constexpr u16 CTOR_DICT_RBEMPTY = 1;

// The slots of the Request record `Http.toTask` receives (REQ_*).
using namespace Elm::Kernel::HttpRequestLayout;

// Constructor tags of elm/http's
//   type Progress = Sending { sent : Int, size : Int }
//                 | Receiving { received : Int, size : Maybe Int }
// which are its declaration indexes.

/// The tag of `Sending`, an upload tick.
static constexpr u16 PROGRESS_SENDING   = 0;
/// The tag of `Receiving`, a download tick.
static constexpr u16 PROGRESS_RECEIVING = 1;

// Tracking state. Every table below is guarded by `g_trackedMutex` and used on
// the eco thread. The root scanner registered by `httpSyncHeapGeneration`
// takes the same non-recursive mutex, and it runs inside whichever allocation
// starts a collection, so the mutex must never be held across a call that can
// allocate on the heap. Non-allocating reads of heap values under it are fine.

/// A tracked request in flight: where its progress ticks go, and whether
/// `Http.cancel` has withdrawn it.
struct TrackedReq {
    uint64_t routerEnc = 0;   ///< The Http manager's router, an encoded HPointer kept current by the scanner.
    uint64_t trackerEnc = 0;  ///< The tracker String, an encoded HPointer kept current by the scanner.
    bool     cancelled = false;
};
/// The mutex guarding every tracking table in this file.
std::mutex g_trackedMutex;
/// The tracked requests whose binding has run, by token, until their result
/// is drained, they are killed, or a cancel claims them while queued.
std::unordered_map<uint64_t, TrackedReq> g_httpTracked;
/// The token of the request a tracker currently names, the one `Http.cancel`
/// with that tracker withdraws.
std::unordered_map<std::string, uint64_t> g_trackerToken;

/// The abort control of every submitted request, tracked or not, by token.
/// An entry is added by the binding and removed when the result is drained or
/// when `httpAbort` claims the request while it is still queued.
std::unordered_map<uint64_t, std::shared_ptr<HttpService::RequestControl>> g_httpControl;

// Spawn tickets. A tracked request that the Http manager spawns takes a
// ticket (`Eco_Http_toTaskForSpawn`) before its binding runs. A cancel that
// finds the tracker's ticket here marks it cancelled, and the binding, when it
// runs, then returns without submitting the request or taking a hold.

/// The next spawn ticket to hand out. Zero is never a ticket.
uint64_t g_nextTicket = 1;
/// The latest unbound ticket of each tracker, removed when its binding runs
/// or a cancel takes it.
std::unordered_map<std::string, uint64_t> g_unboundTicket;
/// Tickets cancelled before their binding ran.
std::unordered_set<uint64_t> g_cancelledTickets;
/// Tickets whose tracker a later spawn took over before they ran. Their
/// requests still report progress, but never become the tracker's cancel
/// target.
std::unordered_set<uint64_t> g_supersededTickets;

/// Asks for request `token` to be aborted, and returns whether it was claimed
/// while still queued.
///
/// True means no result will be posted for it, its control entry is gone, and
/// the caller must release its hold. False means it is running and told to
/// stop, has finished, or has no control entry; any result still to come is
/// drained by `httpDrain`, which releases the hold. Eco thread.
bool httpAbort(uint64_t token) {
    std::shared_ptr<HttpService::RequestControl> control;
    {
        std::lock_guard<std::mutex> lk(g_trackedMutex);
        auto it = g_httpControl.find(token);
        if (it == g_httpControl.end()) return false;
        control = it->second;
        if (!control->abort()) return false;
        g_httpControl.erase(it);
    }
    ECO_KLOG("elm-http", "abort token=%lu claimed while queued", (unsigned long)token);
    return true;
}

/// Removes the abort control of request `token`, if there is one.
void httpForgetControl(uint64_t token) {
    std::lock_guard<std::mutex> lk(g_trackedMutex);
    g_httpControl.erase(token);
}

/// Returns the Elm String encoded as `strEnc` as UTF-8, or an empty string for
/// the empty String and for a word that resolves to no object. The word must
/// be a String or one of those two; nothing checks its tag. Does not allocate
/// on the heap.
std::string elmStringToUTF8(uint64_t strEnc) {
    HPointer hp = Export::decode(strEnc);
    if (Elm::alloc::isEmptyString(hp)) return "";
    void* ptr = Export::toPtr(strEnc);
    if (!ptr) return "";
    return Elm::StringOps::toStdString(ptr);
}

/// Returns the bytes of the request body or multipart value `content`: the UTF-8 of a String (`stringBody`,
/// `jsonBody`, `stringPart`) or the raw bytes of a Bytes value (`bytesBody`, the bytes of a `bytesPart`). The empty
/// constant is both the empty String and the empty Bytes, and gives `""`. A `File` (`fileBody`, `filePart`) only
/// comes from a browser, so none reaches the native kernel; it gives `""` too. Reads only and allocates nothing.
static std::string bodyBytes(HPointer content) {
    void* obj = resolveOrNull(content);
    if (!obj) return "";
    if (Elm::alloc::isByteBuffer(obj)) {  // any of the three Bytes forms
        return std::string(reinterpret_cast<const char*>(Elm::alloc::byteBufferData(obj)),
                           Elm::alloc::byteBufferLength(obj));
    }
    if (Elm::alloc::isString(obj)) return Elm::StringOps::toStdString(obj);
    return "";
}

/// Returns the standard reason phrase for eleven common HTTP status codes, and
/// an empty string for any other `code`.
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

/// Allocates an empty elm/core Dict.
HPointer rbEmpty() {
    std::vector<Unboxable> v;
    return custom(CTOR_DICT_RBEMPTY, v, 0);
}

namespace {

/// The tag of elm/core's `Red`, the first constructor of `NColor`, a null-cons constant.
constexpr u16 DICT_RED = 0;
/// The tag of elm/core's `Black`.
constexpr u16 DICT_BLACK = 1;

/// Builds the subtree holding `entries[lo, hi)`, rooted at the middle entry, at depth `depth` (the root is 1) of a
/// tree whose deepest level is `height`. Nodes on the deepest level are Red unless that level is the root's, and
/// every other node is Black.
HPointer buildHeadersTree(const std::vector<std::pair<std::string, std::string>>& entries,
                          size_t lo, size_t hi, int depth, int height) {
    if (lo >= hi) return rbEmpty();
    size_t mid = lo + (hi - lo) / 2;
    HPointer left = buildHeadersTree(entries, lo, mid, depth + 1, height);
    Elm::StackRootGuard gl(&left);
    HPointer right = buildHeadersTree(entries, mid + 1, hi, depth + 1, height);
    Elm::StackRootGuard gr(&right);
    HPointer key = allocStringFromUTF8(entries[mid].first);
    Elm::StackRootGuard gk(&key);
    HPointer val = allocStringFromUTF8(entries[mid].second);
    Elm::StackRootGuard gv(&val);
    bool red = depth == height && depth > 1;
    std::vector<Unboxable> colour;
    std::vector<Unboxable> fields(5);
    fields[0].p = custom(red ? DICT_RED : DICT_BLACK, colour, 0);  // null-cons constant
    fields[1].p = key;
    fields[2].p = val;
    fields[3].p = left;
    fields[4].p = right;
    return custom(CTOR_DICT_RBNODE, fields, 0);
}

} // namespace

/// Builds an elm/core `Dict String String` from the header pairs `hdrs`. When a name occurs more than once, the last
/// value wins.
///
/// The result is a valid red-black tree, since `Dict.insert` and `Dict.remove` pattern-match on node colours. It is
/// built balanced from the sorted keys: every level but the deepest is full, the deepest level's nodes are Red and
/// every other node is Black, so each path has the same number of Black nodes and no Red node has a Red child. The
/// root is Black.
HPointer buildHeadersDict(const std::vector<std::pair<std::string, std::string>>& hdrs) {
    std::map<std::string, std::string> sorted;
    for (auto& kv : hdrs) sorted[kv.first] = kv.second;
    std::vector<std::pair<std::string, std::string>> entries(sorted.begin(), sorted.end());
    int height = 0;
    for (size_t n = entries.size(); n > 0; n /= 2) height++;
    return buildHeadersTree(entries, 0, entries.size(), 1, height);
}

/// Builds the `Metadata` record `{ headers, statusCode, statusText, url }` of
/// result `r`. The status text is the reason phrase for `r.status` when
/// `r.statusText` is empty.
HPointer buildMetadata(const HttpService::Result& r) {
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();

    HPointer headers = buildHeadersDict(r.headers);
    rs.pushStackRootRange(&headers, 1, 1);
    HPointer statusText = allocStringFromUTF8(
        r.statusText.empty() ? std::string(reasonPhrase(r.status)) : r.statusText);
    rs.pushStackRootRange(&statusText, 1, 1);
    HPointer url = allocStringFromUTF8(r.finalUrl);

    // The compiler (`Types.computeRecordLayout`) puts unboxed fields first, then
    // boxed ones, each group in name order, so the unboxed Int `statusCode`
    // takes slot 0.
    std::vector<Unboxable> fields(4);
    fields[0].i = static_cast<i64>(r.status);
    fields[1].p = headers;
    fields[2].p = statusText;
    fields[3].p = url;
    HPointer md = record(fields, (u64{1} << 0));  // slot 0 kind 01 (Int)
    rs.restoreStackRangePoint(saved);
    return md;
}

/// Builds the `Response body` for result `r`, with `body` as the body of a
/// `GoodStatus_` (status 200 to 299) or `BadStatus_` response. `BadUrl_`
/// carries `r.finalUrl`.
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
    Elm::StackRootGuard bodyRoot(&body);
    HPointer md = buildMetadata(r);
    Elm::StackRootGuard mdRoot(&md);
    std::vector<Unboxable> v(2);
    v[0].p = md;
    v[1].p = body;
    bool good = (r.status >= 200 && r.status < 300);
    return custom(good ? RESP_GOOD_STATUS : RESP_BAD_STATUS, v, 0);
}

/// Records request `token` as tracked by `tracker`, with progress going to
/// `router`. When `claimTracker` is true the tracker is pointed at this
/// request, and an older request it named is not cancelled but can no longer
/// be cancelled by tracker. Does not allocate.
void httpRegisterTracked(uint64_t token, HPointer router, HPointer tracker,
                         bool claimTracker) {
    std::string trackerStr = elmStringToUTF8(Export::encode(tracker));
    ECO_KLOG("elm-http", "track-register token=%lu tracker=%s",
             (unsigned long)token, trackerStr.c_str());
    std::lock_guard<std::mutex> lk(g_trackedMutex);
    g_httpTracked[token] = TrackedReq{Export::encode(router), Export::encode(tracker), false};
    if (claimTracker) g_trackerToken[trackerStr] = token;
}

/// Ends the tracking of request `token`, and returns whether `Http.cancel` had
/// withdrawn it. Returns false for an untracked token. The tracker stops
/// naming the request if it still does. Does not allocate.
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

/// The heap generation the tracking tables and the root scanner belong to; 0
/// before the first sync. Eco thread only.
uint64_t g_httpHeapGeneration = 0;

/// Makes the tracking state belong to the current heap generation. On the
/// first call in a generation it registers, with the current root set, a root
/// scanner named "http-effects" that keeps the router and tracker words of
/// `g_httpTracked` alive and updates them when objects move; the scanner takes
/// `g_trackedMutex` and does not allocate. If state from an earlier generation
/// is left (a heap reset, which only tests make), it is dropped first: every
/// table is cleared, so no progress tick or cancel reaches a router or tracker
/// of the dead heap, and every request still in flight is told to abort. The
/// scheduler voided their holds and parked resumes at the reset, so a result
/// that still arrives is dropped by `httpDrain`. Later calls in the same
/// generation do nothing. Every entry point that adds to a table calls it
/// first. Eco thread.
void httpSyncHeapGeneration() {
    const uint64_t gen = Allocator::instance().heapGeneration();
    if (g_httpHeapGeneration == gen) return;
    std::vector<std::shared_ptr<HttpService::RequestControl>> stale;
    {
        std::lock_guard<std::mutex> lock(g_trackedMutex);
        for (auto& [token, control] : g_httpControl) {
            (void)token;
            stale.push_back(control);
        }
        g_httpTracked.clear();
        g_trackerToken.clear();
        g_httpControl.clear();
        g_unboundTicket.clear();
        g_cancelledTickets.clear();
        g_supersededTickets.clear();
    }
    for (auto& control : stale) (void)control->abort();
    g_httpHeapGeneration = gen;
    Allocator::instance().getRootSet().addExternalRootScanner(
        [](RootSet::EvacuateFn evac) {
            std::lock_guard<std::mutex> lock(g_trackedMutex);
            for (auto& [token, tr] : g_httpTracked) {
                evac(tr.routerEnc);
                evac(tr.trackerEnc);
            }
        }, "http-effects");
}

/// Builds the `Progress` value of one tick: `Sending { sent = now, size =
/// total }` when `isUpload`, otherwise `Receiving { received = now, size }`,
/// where `size` is `Just total` when `total` is above zero and `Nothing`
/// otherwise.
HPointer buildProgress(bool isUpload, uint64_t now, uint64_t total) {
    if (isUpload) {
        // Both fields are unboxed Ints, in name order: [sent, size], mask 0b0101.
        std::vector<Unboxable> rf(2);
        rf[0] = unboxedInt(static_cast<i64>(now));
        rf[1] = unboxedInt(static_cast<i64>(total));
        HPointer rec = record(rf, 0x5);
        Elm::StackRootGuard g(&rec);
        std::vector<Unboxable> cf(1);
        cf[0] = boxed(rec);
        return custom(PROGRESS_SENDING, cf, 0);
    }
    HPointer size = (total > 0)
        ? justKind(unboxedInt(static_cast<i64>(total)), /*kind=Int*/1)
        : nothing();
    Elm::StackRootGuard sg(&size);
    // The unboxed Int `received` comes before the boxed `size`, mask 0b0001.
    std::vector<Unboxable> rf(2);
    rf[0] = unboxedInt(static_cast<i64>(now));
    rf[1] = boxed(size);
    HPointer rec = record(rf, 0x1);
    Elm::StackRootGuard rg(&rec);
    std::vector<Unboxable> cf(1);
    cf[0] = boxed(rec);
    return custom(PROGRESS_RECEIVING, cf, 0);
}

/// Delivers every queued progress tick of a tracked request that has not been
/// cancelled, as the self-message `(tracker, progress)` to the Http manager.
/// Ticks of untracked, finished or cancelled requests are dropped.
///
/// Each tick is followed by `Scheduler::drain()`, so it is handled before the
/// next is popped.
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
        if (!found || cancelled) continue;

        // The scanner updates the table entries, not these copies, so they need
        // their own roots across the allocations below.
        HPointer router = Export::decode(routerEnc);
        HPointer tracker = Export::decode(trackerEnc);
        HPointer progress = listNil();
        HPointer selfMsg = listNil();
        Elm::StackRootGuard g({&router, &tracker, &progress, &selfMsg});
        progress = buildProgress(ev.isUpload, ev.now, ev.total);
        selfMsg = tuple2(boxed(tracker), boxed(progress), 0);
        PlatformRuntime::instance().sendToSelf(router, selfMsg);

        // `sendToSelf` only enqueues the manager's process. Processes are
        // immutable, so enqueuing several ticks before stepping would leave
        // snapshots with overlapping mailboxes and re-deliver earlier ticks;
        // stepping after each tick delivers each once.
        Scheduler::instance().drain();
    }
}

/// Finishes every completed request: the async source's drain, run on the eco
/// thread.
///
/// Progress is delivered first, so the ticks already queued reach the manager
/// before a result is handled. Then for each result it ends the tracking, and
/// drops a result that was cancelled or whose resume was already taken (a
/// killed task). Otherwise it makes the body (Bytes when the expect type is
/// `"arraybuffer"`, a String otherwise), applies `toBody`, builds the
/// `Response`, applies `toValue` and `resultToTask`, and resumes the task with
/// the result. Each result's hold is released, whether delivered or dropped.
void httpDrain() {
    httpSyncHeapGeneration();
    httpDrainProgress();

    HttpService::Result r;
    while (HttpService::instance().tryPopResult(r)) {
        ECO_KLOG("elm-http",
                 "drain token=%lu err=%d status=%ld body=%zuB",
                 (unsigned long)r.token, (int)r.error, r.status, r.body.size());
        bool cancelled = httpClearTracked(r.token);
        httpForgetControl(r.token);
        HPointer bundle = Scheduler::instance().takePendingResume(r.token);
        if (alloc::isNil(bundle) || cancelled) {
            Scheduler::instance().releaseHold(r.token);
            continue;
        }
        Elm::StackRootGuard bundleRoot(&bundle);

        // The bundle is re-resolved after every allocation, since it may move.
        bool wantBytes;
        {
            void* bp = Allocator::instance().resolve(bundle);
            HPointer typeHP = static_cast<Custom*>(bp)->values[4].p;
            wantBytes = (elmStringToUTF8(Export::encode(typeHP)) == "arraybuffer");
        }
        HPointer rawBody;
        if (wantBytes) {
            rawBody = allocByteBuffer(
                reinterpret_cast<const u8*>(r.body.data()), r.body.size());
        } else {
            rawBody = allocStringFromUTF8(r.body);
        }
        Elm::StackRootGuard rawRoot(&rawBody);

        HPointer body;
        {
            void* bp = Allocator::instance().resolve(bundle);
            HPointer toBody = static_cast<Custom*>(bp)->values[2].p;
            body = Scheduler::instance().callClosure1(toBody, rawBody);
        }
        Elm::StackRootGuard bodyRoot(&body);

        HPointer response = buildResponse(r, body);
        Elm::StackRootGuard respRoot(&response);

        HPointer value;
        {
            void* bp = Allocator::instance().resolve(bundle);
            HPointer toValue = static_cast<Custom*>(bp)->values[3].p;
            value = Scheduler::instance().callClosure1(toValue, response);
        }
        Elm::StackRootGuard valueRoot(&value);

        HPointer resultTask;
        {
            void* bp = Allocator::instance().resolve(bundle);
            HPointer resultToTask = static_cast<Custom*>(bp)->values[1].p;
            resultTask = Scheduler::instance().callClosure1(resultToTask, value);
        }
        Elm::StackRootGuard taskRoot(&resultTask);

        {
            void* bp = Allocator::instance().resolve(bundle);
            HPointer resume = static_cast<Custom*>(bp)->values[0].p;
            Scheduler::instance().callClosure1(resume, resultTask);
        }
        Scheduler::instance().releaseHold(r.token);
    }
}

/// Makes the tracking state belong to the current heap generation
/// (`httpSyncHeapGeneration`, which registers the tracking root scanner), and
/// registers, once per process, the async source whose drain is `httpDrain`,
/// ready while results or progress are queued. The scheduler keeps its async
/// sources across a heap reset.
void httpEnsureRegistered() {
    httpSyncHeapGeneration();
    static std::once_flag flag;
    std::call_once(flag, []() {
        Scheduler::instance().registerAsyncSource(
            httpDrain,
            []() {
                return HttpService::instance().hasReadyResults()
                    || HttpService::instance().hasProgress();
            });
    });
}

/// What the binding reads from one Request record: the plain-data request for
/// the worker, and the heap values it needs to finish the request.
///
/// The HPointers are copies, unrooted, and valid only until the next heap
/// allocation.
struct ExtractedRequest {
    HttpService::Request pod;
    HPointer type;     ///< The expect's type String: `"arraybuffer"` asks for a Bytes body.
    HPointer toBody;
    HPointer toValue;
    HPointer trackerHP = {};  ///< The tracker String; meaningful only when `tracked`.
    bool tracked = false;     ///< Whether `tracker` is `Just`.
    bool ok = false;          ///< False when the record or its expect has no object; then only some fields are set.
};

/// Reads the Request record `requestHP` into an `ExtractedRequest`, without
/// allocating on the heap.
///
/// The method, URL and headers are copied as UTF-8. A `pair` body gives the
/// content type and the content read as a String, except that a multipart
/// form is serialised as `multipart/form-data` with each part's value read as
/// a String. Any other body is sent empty. A `Just` timeout is truncated to
/// whole milliseconds.
ExtractedRequest extractRequest(HPointer requestHP) {
    ExtractedRequest out;
    void* ptr = Allocator::instance().resolve(requestHP);
    Record* req = static_cast<Record*>(ptr);

    out.pod.method = elmStringToUTF8(Export::encode(req->values[REQ_METHOD].p));
    out.pod.url    = elmStringToUTF8(Export::encode(req->values[REQ_URL].p));

    // Each header is a Custom with fields [name, value].
    for (Elm::alloc::ListCursor l(req->values[REQ_HEADERS].p); !l.done();
         l.next()) {
        void* hPtr = resolveOrNull(l.current().p);
        if (hPtr) {
            Custom* hdr = static_cast<Custom*>(hPtr);
            std::string key = elmStringToUTF8(Export::encode(hdr->values[0].p));
            std::string val = elmStringToUTF8(Export::encode(hdr->values[1].p));
            out.pod.headers.push_back({key, val});
        }
    }

    void* bodyPtr = resolveOrNull(req->values[REQ_BODY].p);
    if (bodyPtr) {
        Custom* body = static_cast<Custom*>(bodyPtr);
        if (body->ctor == BODY_PAIR) {
            out.pod.contentType = elmStringToUTF8(Export::encode(body->values[0].p));
            // The content is a String (`stringBody`, `jsonBody`) or Bytes (`bytesBody`), or, from `multipartBody`, a
            // form, which is serialised as multipart/form-data.
            HPointer content = body->values[1].p;
            void* cp = resolveOrNull(content);
            bool isForm = cp && static_cast<Header*>(cp)->tag == Tag_Custom &&
                          static_cast<Custom*>(cp)->ctor == BODY_FORM;
            if (isForm) {
                const std::string boundary = "EcoBoundary7MA4YWxkTrZu0gW";
                std::string mp;
                for (Elm::alloc::ListCursor l(
                         static_cast<Custom*>(cp)->values[0].p);
                     !l.done(); l.next()) {
                    void* partPtr = resolveOrNull(l.current().p);
                    if (partPtr) {
                        Custom* part = static_cast<Custom*>(partPtr);
                        std::string key = elmStringToUTF8(Export::encode(part->values[0].p));
                        HPointer value = part->values[1].p;
                        void* vp = resolveOrNull(value);
                        mp += "--" + boundary + "\r\n";
                        if (vp && static_cast<Header*>(vp)->tag == Tag_Custom &&
                            static_cast<Custom*>(vp)->ctor == BODY_BLOB) {
                            // bytesPart: a Blob of [bytes, mime], sent as a
                            // browser sends a Blob appended to a FormData.
                            Custom* blob = static_cast<Custom*>(vp);
                            std::string mime = elmStringToUTF8(Export::encode(blob->values[1].p));
                            mp += "Content-Disposition: form-data; name=\"" + key +
                                  "\"; filename=\"blob\"\r\n";
                            mp += "Content-Type: " +
                                  (mime.empty() ? std::string("application/octet-stream") : mime) +
                                  "\r\n\r\n";
                            mp += bodyBytes(blob->values[0].p) + "\r\n";
                        } else {
                            mp += "Content-Disposition: form-data; name=\"" + key + "\"\r\n\r\n";
                            mp += bodyBytes(value) + "\r\n";
                        }
                    }
                }
                mp += "--" + boundary + "--\r\n";
                out.pod.body = mp;
                out.pod.contentType = "multipart/form-data; boundary=" + boundary;
            } else {
                out.pod.body = bodyBytes(content);
            }
        }
    }

    // `Nothing` is a constant, so only a `Just` resolves; its field 0 is the
    // unboxed Float.
    void* toPtr = resolveOrNull(req->values[REQ_TIMEOUT].p);
    if (toPtr) {
        Custom* mt = static_cast<Custom*>(toPtr);
        out.pod.timeoutMs = static_cast<long>(mt->values[0].f);
    }

    void* trPtr = resolveOrNull(req->values[REQ_TRACKER].p);
    if (trPtr) {
        out.trackerHP = static_cast<Custom*>(trPtr)->values[0].p;
        out.tracked = true;
    }

    void* expectPtr = resolveOrNull(req->values[REQ_EXPECT].p);
    if (!expectPtr) return out;
    Custom* expect = static_cast<Custom*>(expectPtr);
    out.type    = expect->values[0].p;
    out.toBody  = expect->values[1].p;
    out.toValue = expect->values[2].p;
    out.ok = true;
    return out;
}

/// Kills one request: the evaluator of its kill handle, which `Process.kill`
/// applies to `()`. `args[0]` is the request's token as a raw Int, `args[1]`
/// is `()`.
///
/// The task never resumes and its tracking ends. Its hold is released here if
/// the request was claimed while queued, and otherwise by `httpDrain` when the
/// result arrives and finds no resume. Returns Unit.
void* httpKillEval(void* args[]) {
    uint64_t token = reinterpret_cast<uint64_t>(args[0]);
    auto& s = Scheduler::instance();
    (void)s.takePendingResume(token);
    (void)httpClearTracked(token);
    if (httpAbort(token)) s.releaseHold(token);
    return reinterpret_cast<void*>(Export::encode(unit()));
}

/// Allocates the kill handle of request `token`, a closure that runs
/// `httpKillEval` when applied to `()`.
HPointer makeHttpKillHandle(uint64_t token) {
    HPointer cl = allocClosureK(httpKillEval, /*max_values=*/2, Elm::PK_Boxed);
    void* p = Allocator::instance().resolve(cl);   // nothing allocates before the capture
    closureCapture(p, unboxedInt(static_cast<i64>(token)), Elm::PK_Int);
    return cl;
}

/// Starts one request: the evaluator of its Task binding, run by the scheduler
/// on the eco thread. `args[0]` to `args[3]` are the captured request,
/// `resultToTask`, router and spawn ticket (a raw Int, 0 for none), and
/// `args[4]` is the resume closure the scheduler supplies.
///
/// It parks the continuation bundle with a hold, records tracking for a
/// tracked request, submits the request and returns the kill handle. It
/// returns Unit without submitting, parking or holding when the ticket was
/// cancelled, or when the record or its expect has no object; in both cases
/// the task never resumes.
void* httpBindingEval(void* args[]) {
    httpSyncHeapGeneration();
    HPointer request      = Export::decode(reinterpret_cast<uint64_t>(args[0]));
    HPointer resultToTask = Export::decode(reinterpret_cast<uint64_t>(args[1]));
    HPointer router       = Export::decode(reinterpret_cast<uint64_t>(args[2]));
    uint64_t ticket       = reinterpret_cast<uint64_t>(args[3]);
    HPointer resume       = Export::decode(reinterpret_cast<uint64_t>(args[4]));

    bool claimTracker = true;
    if (ticket != 0) {
        bool cancelled = false;
        {
            std::lock_guard<std::mutex> lk(g_trackedMutex);
            cancelled = g_cancelledTickets.erase(ticket) != 0;
            claimTracker = g_supersededTickets.erase(ticket) == 0;
            for (auto it = g_unboundTicket.begin(); it != g_unboundTicket.end(); ++it) {
                if (it->second == ticket) { g_unboundTicket.erase(it); break; }
            }
        }
        if (cancelled) {
            ECO_KLOG("elm-http", "ticket=%lu cancelled before start", (unsigned long)ticket);
            return reinterpret_cast<void*>(Export::encode(unit()));
        }
    }

    ExtractedRequest ex = extractRequest(request);
    if (!ex.ok) {
        return reinterpret_cast<void*>(Export::encode(unit()));
    }

    // Once parked, the scheduler keeps the bundle rooted.
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

    u64 token = Scheduler::instance().parkResume(bundle, Elm::Platform::HoldKind::Task,
                                                 "Http.request");

    if (ex.tracked) {
        httpRegisterTracked(token, router, trackerHP, claimTracker);
    }

    ex.pod.token = token;
    ex.pod.control = std::make_shared<HttpService::RequestControl>();
    {
        std::lock_guard<std::mutex> lk(g_trackedMutex);
        g_httpControl[token] = ex.pod.control;
    }
    HttpService::instance().submit(std::move(ex.pod));

    // Allocates, but nothing above is used afterwards.
    return reinterpret_cast<void*>(Export::encode(makeHttpKillHandle(token)));
}

/// Returns the Task that, when run, sends request `reqHP` and resumes with
/// `resultToTask` applied to the expect's value. `routerHP` receives the
/// progress of a tracked request, and `ticket` is its spawn ticket or 0.
/// Registers the async source on first use, and the tracking root scanner on
/// the first use in each heap generation.
HPointer httpMakeTask(HPointer routerHP, HPointer rttHP, HPointer reqHP, uint64_t ticket) {
    Elm::StackRootGuard g({&reqHP, &rttHP, &routerHP});
    httpEnsureRegistered();

    // Four captures, plus the resume argument the scheduler supplies.
    HPointer bindingCallback = allocClosureK(httpBindingEval, 5, Elm::PK_Boxed);
    void* clPtr = Allocator::instance().resolve(bindingCallback);
    closureCapture(clPtr, boxed(reqHP), true);
    closureCapture(clPtr, boxed(rttHP), true);
    closureCapture(clPtr, boxed(routerHP), true);
    closureCapture(clPtr, unboxedInt(static_cast<i64>(ticket)), Elm::PK_Int);
    return Scheduler::instance().taskBinding(bindingCallback);
}

/// Returns `func (oldToValue response)`: the evaluator of the `toValue` closure
/// `Http.mapExpect` builds. `args[0]` and `args[1]` are the captured `func`
/// and `oldToValue`, and `args[2]` is the response.
void* mapExpectEvaluator(void* args[]) {
    uint64_t funcEnc     = reinterpret_cast<uint64_t>(args[0]);
    uint64_t oldEnc      = reinterpret_cast<uint64_t>(args[1]);
    uint64_t responseEnc = reinterpret_cast<uint64_t>(args[2]);

    HPointer func = Export::decode(funcEnc);
    Elm::StackRootGuard funcRoot(&func);
    uint64_t midEnc = eco_apply_closure(HPtr::fromBits(oldEnc), &responseEnc, 1).toBits();
    uint64_t funcArg = midEnc;
    HPtr res = eco_apply_closure(HPtr::fromBits(Export::encode(func)), &funcArg, 1);
    return reinterpret_cast<void*>(res.toBits());
}

} // anonymous namespace

// The compiler binds an Elm `Elm.Kernel.Http.<fn>` reference to the C symbol
// `Elm_Kernel_Http_<fn>` (`canonicalToMLIRName`), so these exports keep that
// exact spelling. Each `Elm.Kernel.Http` export is also registered for the JIT in `RuntimeSymbols.cpp`.
extern "C" {

// `emptyBody : Body`.
HPtr Elm_Kernel_Http_emptyBody() {
    std::vector<Unboxable> v;
    return HPtr::fromBits(Export::encode(custom(BODY_EMPTY, v, 0)));
}

// `pair : a -> b -> c`, the constructor elm/http uses for every body and
// multipart part.
HPtr Elm_Kernel_Http_pair(HPtr a, HPtr b) {
    HPointer aHP = Export::decode(a.toBits());
    HPointer bHP = Export::decode(b.toBits());
    Elm::StackRootGuard g(&aHP, &bHP);
    std::vector<Unboxable> v(2);
    v[0].p = aHP;
    v[1].p = bHP;
    return HPtr::fromBits(Export::encode(custom(BODY_PAIR, v, 0)));
}

// `toTask : router -> (a -> Task x b) -> Request -> Task x b`, with no spawn
// ticket.
HPtr Elm_Kernel_Http_toTask(HPtr router, HPtr resultToTask, HPtr request) {
    HPointer task = httpMakeTask(Export::decode(router.toBits()),
                                 Export::decode(resultToTask.toBits()),
                                 Export::decode(request.toBits()), /*ticket=*/0);
    return HPtr::fromBits(Export::encode(task));
}

/// Returns what `Http.toTask` returns, for a request the Http manager is about
/// to spawn. `trackerEnc` is the request's tracker String, or 0 for an
/// untracked request.
///
/// A tracked request takes a spawn ticket, so that a cancel issued before its
/// binding runs still reaches it. A ticket already waiting under the same
/// tracker is superseded: its request is no longer the tracker's cancel
/// target.
uint64_t Eco_Http_toTaskForSpawn(uint64_t routerEnc, uint64_t resultToTaskEnc,
                                 uint64_t requestEnc, uint64_t trackerEnc) {
    httpSyncHeapGeneration();   // before the ticket goes in: a new generation clears the tables
    uint64_t ticket = 0;
    if (trackerEnc != 0) {
        std::string trackerStr = elmStringToUTF8(trackerEnc);
        std::lock_guard<std::mutex> lk(g_trackedMutex);
        ticket = g_nextTicket++;
        auto [it, fresh] = g_unboundTicket.try_emplace(trackerStr, ticket);
        if (!fresh) {
            g_supersededTickets.insert(it->second);
            it->second = ticket;
        }
    }
    HPointer task = httpMakeTask(Export::decode(routerEnc), Export::decode(resultToTaskEnc),
                                 Export::decode(requestEnc), ticket);
    return Export::encode(task);
}

/// Withdraws the request that tracker String `trackerEnc` names, the latest
/// one issued with it, if it is still in flight. Older requests with the same
/// tracker are not affected. Does not allocate on the heap.
///
/// A request whose binding has not run has its ticket cancelled, and the
/// tracker then names nothing. A queued request is claimed and its hold
/// released here. A running one is told to stop, and `httpDrain` drops its
/// result and releases the hold. A withdrawn request never resumes, and its
/// later progress ticks are dropped.
void Eco_Http_cancelTracker(uint64_t trackerEnc) {
    httpSyncHeapGeneration();
    std::string trackerStr = elmStringToUTF8(trackerEnc);
    uint64_t token = 0;
    {
        std::lock_guard<std::mutex> lk(g_trackedMutex);
        auto ui = g_unboundTicket.find(trackerStr);
        if (ui != g_unboundTicket.end()) {
            ECO_KLOG("elm-http", "cancel tracker=%s ticket=%lu (not started)",
                     trackerStr.c_str(), (unsigned long)ui->second);
            g_cancelledTickets.insert(ui->second);
            g_unboundTicket.erase(ui);
            // Any request still under this tracker was superseded by this
            // spawn and is no longer its cancel target.
            g_trackerToken.erase(trackerStr);
            return;
        }
        auto ti = g_trackerToken.find(trackerStr);
        if (ti == g_trackerToken.end()) {
            ECO_KLOG("elm-http", "cancel tracker=%s unknown",
                     trackerStr.c_str());
            return;
        }
        ECO_KLOG("elm-http", "cancel tracker=%s token=%lu",
                 trackerStr.c_str(), (unsigned long)ti->second);
        auto it = g_httpTracked.find(ti->second);
        if (it == g_httpTracked.end()) return;
        it->second.cancelled = true;
        token = ti->second;
    }
    if (httpAbort(token)) {
        // No result will arrive, so the request ends here.
        auto& s = Scheduler::instance();
        (void)s.takePendingResume(token);
        (void)httpClearTracked(token);
        s.releaseHold(token);
    }
}

// `expect : String -> (a -> body) -> (Response body -> b) -> Expect b`.
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

// `mapExpect : (a -> b) -> Expect a -> Expect b`. The new expect keeps the type
// and `toBody`, and its `toValue` applies `closure` after the old one. An
// `expectVal` that resolves to no object is returned unchanged.
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
    closureCapture(clPtr, boxed(func), true);
    closureCapture(clPtr, boxed(oldTV), true);
    Elm::StackRootGuard cg(&composed);
    std::vector<Unboxable> v(3);
    v[0].p = type;
    v[1].p = toBody;
    v[2].p = composed;
    return HPtr::fromBits(Export::encode(custom(EXPECT_CTOR, v, 0)));
}

// `bytesToBlob`, which elm/http calls as `bytesToBlob mime bytes`. The blob holds
// the bytes then the MIME type.
HPtr Elm_Kernel_Http_bytesToBlob(HPtr mimeType, HPtr bytes) {
    HPointer bytesHP = Export::decode(bytes.toBits());
    HPointer mimeHP  = Export::decode(mimeType.toBits());
    Elm::StackRootGuard g(&bytesHP, &mimeHP);
    std::vector<Unboxable> v(2);
    v[0].p = bytesHP;
    v[1].p = mimeHP;
    return HPtr::fromBits(Export::encode(custom(BODY_BLOB, v, 0)));
}

// `toDataView`, the `toBody` of a Bytes expect. The body is already Bytes, so
// it is returned unchanged.
HPtr Elm_Kernel_Http_toDataView(HPtr bytes) {
    return bytes;
}

// `toFormData : List Part -> body`, the multipart form `extractRequest`
// serialises.
HPtr Elm_Kernel_Http_toFormData(HPtr parts) {
    HPointer partsHP = Export::decode(parts.toBits());
    Elm::StackRootGuard g(&partsHP);
    std::vector<Unboxable> v(1);
    v[0].p = partsHP;
    return HPtr::fromBits(Export::encode(custom(BODY_FORM, v, 0)));
}

// libcurl's process-wide setup, run before `main`, and its teardown at exit.
__attribute__((constructor))
static void initCurl() { curl_global_init(CURL_GLOBAL_DEFAULT); }
__attribute__((destructor))
static void cleanupCurl() { curl_global_cleanup(); }

} // extern "C"
