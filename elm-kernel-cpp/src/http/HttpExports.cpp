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
#include <curl/curl.h>
#include <map>
#include <mutex>
#include <string>
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
static constexpr int REQ_URL     = 7;

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

// ---- Main-thread async-source drain ----------------------------------------
// Pops completed worker results and, for each, resumes the matching binding on
// the main thread: build Response -> apply expect.toBody/toValue -> apply
// resultToTask -> resume(resultTask).
void httpDrain() {
    HttpService::Result r;
    while (HttpService::instance().tryPopResult(r)) {
        HPointer bundle = Scheduler::instance().takePendingResume(r.token);
        if (alloc::isNil(bundle)) {
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
        Scheduler::instance().registerAsyncSource(
            httpDrain,
            []() { return HttpService::instance().hasReadyResults(); });
    });
}

// Read the stock Request record into a worker POD + extract the expect's
// toBody/toValue closures. Runs on the main thread (binding step).
struct ExtractedRequest {
    HttpService::Request pod;
    HPointer type;     // expect.__type: "" (String body) or "arraybuffer" (Bytes)
    HPointer toBody;
    HPointer toValue;
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

// Binding evaluator (main thread). Captures: args[0]=request, args[1]=resultToTask.
// Scheduler appends the resume closure as args[2].
void* httpBindingEval(void* args[]) {
    HPointer request      = decodeHP(reinterpret_cast<uint64_t>(args[0]));
    HPointer resultToTask = decodeHP(reinterpret_cast<uint64_t>(args[1]));
    HPointer resume       = decodeHP(reinterpret_cast<uint64_t>(args[2]));

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
    Elm::StackRootGuard g({&resume, &resultToTask, &toBody, &toValue, &type});
    std::vector<Unboxable> fields(5);
    fields[0].p = resume;
    fields[1].p = resultToTask;
    fields[2].p = toBody;
    fields[3].p = toValue;
    fields[4].p = type;
    HPointer bundle = custom(BUNDLE_CTOR, fields, 0);

    u64 token = Scheduler::instance().registerPendingResume(bundle);
    Scheduler::instance().incrementPendingAsync();

    ex.pod.token = token;
    HttpService::instance().submit(std::move(ex.pod));

    // Kill handle: Unit (cancellation is Phase-2 via HttpService::cancel).
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
    (void)router;  // Phase-1: progress tracking (router/sendToSelf) is Phase-2.
    httpEnsureRegistered();

    HPointer reqHP = Export::decode(request.toBits());
    HPointer rttHP = Export::decode(resultToTask.toBits());
    Elm::StackRootGuard g(&reqHP, &rttHP);

    // Binding closure captures [request, resultToTask]; arity = 2 captures + 1
    // scheduler-supplied resume arg.
    HPointer bindingCallback = allocClosureK(httpBindingEval, 3, Elm::PK_Boxed);
    void* clPtr = Allocator::instance().resolve(bindingCallback);
    if (clPtr) {
        closureCapture(clPtr, boxed(reqHP), true);
        closureCapture(clPtr, boxed(rttHP), true);
    }
    HPointer task = Scheduler::instance().taskBinding(bindingCallback);
    return HPtr::fromBits(Export::encode(task));
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
