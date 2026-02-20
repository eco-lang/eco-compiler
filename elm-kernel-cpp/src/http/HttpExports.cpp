//===- HttpExports.cpp - C-linkage exports for Http module -----------------===//
//
// Full implementation using libcurl with OpenSSL for HTTPS support.
// Falls back to stubs if libcurl is not available.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include "platform/Scheduler.hpp"
#ifdef HTTP_CURL_AVAILABLE
#include <curl/curl.h>
#endif
#include <string>
#include <vector>
#include <thread>
#include <cstring>
#include <mutex>

// Declare closure call
extern "C" uint64_t eco_apply_closure(uint64_t closure, uint64_t* args, uint32_t num_args);

using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::alloc;
using namespace Elm::Platform;

namespace {

// Body type constructors
static constexpr u16 BODY_EMPTY = 0;
static constexpr u16 BODY_STRING = 1;
static constexpr u16 BODY_BYTES = 2;
static constexpr u16 BODY_BLOB = 3;
static constexpr u16 BODY_FORM = 4;

// Expect type ctor
static constexpr u16 EXPECT_CTOR = 0;

// Response type (from Http module)
// Response body = { url : String, statusCode : Int, statusText : String, headers : Dict String String, body : body }
// We'll represent Response as a record

// Error type constructors
static constexpr u16 ERR_BAD_URL = 0;
static constexpr u16 ERR_TIMEOUT = 1;
static constexpr u16 ERR_NETWORK_ERROR = 2;
static constexpr u16 ERR_BAD_STATUS = 3;
static constexpr u16 ERR_BAD_BODY = 4;

// Helper: Convert Elm UTF-16 string to std::string (UTF-8) for libcurl
std::string elmStringToUTF8(uint64_t strEnc) {
    HPointer hp = Export::decode(strEnc);

    // Check for empty string constant
    if (hp.constant == Const_EmptyString + 1) {
        return "";
    }

    void* ptr = Export::toPtr(strEnc);
    if (!ptr) return "";

    ElmString* str = static_cast<ElmString*>(ptr);
    size_t len = str->header.size;
    if (len == 0) return "";

    std::string result;
    result.reserve(len * 3);

    for (size_t i = 0; i < len; ++i) {
        u16 c = str->chars[i];

        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len) {
            u16 c2 = str->chars[i + 1];
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                uint32_t cp = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                result.push_back(static_cast<char>(0xF0 | (cp >> 18)));
                result.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
                result.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                result.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                ++i;
                continue;
            }
        }

        if (c < 0x80) {
            result.push_back(static_cast<char>(c));
        } else if (c < 0x800) {
            result.push_back(static_cast<char>(0xC0 | (c >> 6)));
            result.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        } else {
            result.push_back(static_cast<char>(0xE0 | (c >> 12)));
            result.push_back(static_cast<char>(0x80 | ((c >> 6) & 0x3F)));
            result.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        }
    }

    return result;
}

// Helper: Create an Elm string from UTF-8
HPointer utf8ToElmString(const std::string& utf8) {
    return allocStringFromUTF8(utf8);
}

// Encode HPointer as uint64_t
static inline uint64_t encodeHP(HPointer h) {
    union { HPointer hp; uint64_t val; } u;
    u.hp = h;
    return u.val;
}

// Decode uint64_t to HPointer
static inline HPointer decodeHP(uint64_t val) {
    union { HPointer hp; uint64_t val; } u;
    u.val = val;
    return u.hp;
}

#ifdef HTTP_CURL_AVAILABLE
// libcurl write callback
static size_t writeCallback(void* contents, size_t size, size_t nmemb, void* userp) {
    size_t realsize = size * nmemb;
    std::string* mem = static_cast<std::string*>(userp);
    mem->append(static_cast<char*>(contents), realsize);
    return realsize;
}

// libcurl header callback
struct HeaderData {
    std::vector<std::pair<std::string, std::string>> headers;
};

static size_t headerCallback(char* buffer, size_t size, size_t nitems, void* userdata) {
    size_t numbytes = size * nitems;
    HeaderData* data = static_cast<HeaderData*>(userdata);

    std::string line(buffer, numbytes);

    // Skip status line and empty lines
    if (line.find("HTTP/") == 0 || line == "\r\n" || line == "\n") {
        return numbytes;
    }

    // Parse "Header-Name: value\r\n"
    size_t colonPos = line.find(':');
    if (colonPos != std::string::npos) {
        std::string name = line.substr(0, colonPos);
        std::string value = line.substr(colonPos + 1);

        // Trim whitespace
        while (!value.empty() && (value[0] == ' ' || value[0] == '\t')) {
            value.erase(0, 1);
        }
        while (!value.empty() && (value.back() == '\r' || value.back() == '\n')) {
            value.pop_back();
        }

        // Convert header name to lowercase for consistent lookup
        for (auto& c : name) {
            c = static_cast<char>(std::tolower(c));
        }

        data->headers.push_back({name, value});
    }

    return numbytes;
}
#endif // HTTP_CURL_AVAILABLE

// Create a Response record
// Response body = { url : String, statusCode : Int, statusText : String, headers : Dict String String, body : body }
// Fields in canonical order: body, headers, statusCode, statusText, url
HPointer createResponse(const std::string& url, long statusCode, const std::string& statusText,
                        const std::vector<std::pair<std::string, std::string>>& headers,
                        HPointer body) {
    // Build headers Dict (we'll use a simple list of tuples for now)
    // TODO: proper Dict implementation
    HPointer headersList = listNil();
    for (auto it = headers.rbegin(); it != headers.rend(); ++it) {
        HPointer key = utf8ToElmString(it->first);
        HPointer val = utf8ToElmString(it->second);
        HPointer pair = tuple2(boxed(key), boxed(val), 0);  // both boxed
        headersList = cons(boxed(pair), headersList, true);
    }

    HPointer urlStr = utf8ToElmString(url);
    HPointer statusTextStr = utf8ToElmString(statusText);

    // Record fields in canonical order: body, headers, statusCode, statusText, url
    std::vector<Unboxable> fields(5);
    fields[0].p = body;                                    // body (boxed)
    fields[1].p = headersList;                             // headers (boxed, using list instead of Dict)
    fields[2].i = static_cast<i64>(statusCode);            // statusCode (unboxed)
    fields[3].p = statusTextStr;                           // statusText (boxed)
    fields[4].p = urlStr;                                  // url (boxed)

    // Unboxed mask: bit 2 = statusCode is unboxed
    return record(fields, 0b00100);
}

// Create an Error value
HPointer createError(u16 errorCtor, HPointer payload = HPointer{}) {
    if (payload.ptr == 0 && payload.constant == 0) {
        // No payload error
        std::vector<Unboxable> values;
        return custom(errorCtor, values, 0);
    } else {
        std::vector<Unboxable> values(1);
        values[0].p = payload;
        return custom(errorCtor, values, 0);  // payload is boxed
    }
}

#ifdef HTTP_CURL_AVAILABLE
// HTTP worker thread context
struct HttpContext {
    std::string url;
    std::string method;
    std::vector<std::pair<std::string, std::string>> requestHeaders;
    std::string requestBody;
    uint64_t resumeClosureEnc;  // Encoded closure to call on completion
    uint64_t expectHandlerEnc;  // Encoded expect handler closure
};

// Perform HTTP request in thread and call resume closure
void httpWorkerThread(HttpContext ctx) {
    CURL* curl = curl_easy_init();
    if (!curl) {
        // Create NetworkError and call resume with Task.fail
        HPointer error = createError(ERR_NETWORK_ERROR);
        HPointer failTask = Scheduler::instance().taskFail(error);

        uint64_t resultEnc = encodeHP(failTask);
        eco_apply_closure(ctx.resumeClosureEnc, &resultEnc, 1);
        return;
    }

    std::string responseBody;
    HeaderData headerData;

    curl_easy_setopt(curl, CURLOPT_URL, ctx.url.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &responseBody);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, headerCallback);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, &headerData);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);

    // Set method
    if (ctx.method == "POST") {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, ctx.requestBody.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, ctx.requestBody.size());
    } else if (ctx.method == "PUT") {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "PUT");
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, ctx.requestBody.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, ctx.requestBody.size());
    } else if (ctx.method == "DELETE") {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "DELETE");
    } else if (ctx.method == "PATCH") {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "PATCH");
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, ctx.requestBody.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, ctx.requestBody.size());
    }
    // GET is the default

    // Set request headers
    struct curl_slist* headerList = nullptr;
    for (const auto& h : ctx.requestHeaders) {
        std::string header = h.first + ": " + h.second;
        headerList = curl_slist_append(headerList, header.c_str());
    }
    if (headerList) {
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headerList);
    }

    // Perform the request
    CURLcode res = curl_easy_perform(curl);

    long httpCode = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &httpCode);

    char* effectiveUrl = nullptr;
    curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &effectiveUrl);
    std::string finalUrl = effectiveUrl ? effectiveUrl : ctx.url;

    if (headerList) {
        curl_slist_free_all(headerList);
    }
    curl_easy_cleanup(curl);

    HPointer resultTask;

    if (res != CURLE_OK) {
        // Create appropriate error based on curl error
        HPointer error;
        if (res == CURLE_OPERATION_TIMEDOUT) {
            error = createError(ERR_TIMEOUT);
        } else if (res == CURLE_URL_MALFORMAT) {
            HPointer urlStr = utf8ToElmString(ctx.url);
            error = createError(ERR_BAD_URL, urlStr);
        } else {
            error = createError(ERR_NETWORK_ERROR);
        }
        resultTask = Scheduler::instance().taskFail(error);
    } else {
        // Create response with body as String
        HPointer bodyStr = utf8ToElmString(responseBody);

        // Get status text (simplified - curl doesn't give us this easily)
        std::string statusText = "OK";
        if (httpCode >= 400) {
            statusText = "Error";
        }

        HPointer response = createResponse(finalUrl, httpCode, statusText,
                                           headerData.headers, bodyStr);

        // Call the expect handler with the response to get Result Error a
        uint64_t responseEnc = encodeHP(response);
        uint64_t resultEnc = eco_apply_closure(ctx.expectHandlerEnc, &responseEnc, 1);

        // The result is already a Result, so we need to convert it to Task
        HPointer result = decodeHP(resultEnc);

        // Check if result is Ok or Err
        void* resultPtr = Allocator::instance().resolve(result);
        if (resultPtr) {
            Custom* custom = static_cast<Custom*>(resultPtr);
            if (custom->ctor == 0) {
                // Ok value -> Task.succeed
                HPointer okValue = custom->values[0].p;
                resultTask = Scheduler::instance().taskSucceed(okValue);
            } else {
                // Err value -> Task.fail
                HPointer errValue = custom->values[0].p;
                resultTask = Scheduler::instance().taskFail(errValue);
            }
        } else {
            // Something went wrong, return NetworkError
            HPointer error = createError(ERR_NETWORK_ERROR);
            resultTask = Scheduler::instance().taskFail(error);
        }
    }

    // Call the resume closure with the result task
    uint64_t taskEnc = encodeHP(resultTask);
    eco_apply_closure(ctx.resumeClosureEnc, &taskEnc, 1);
}
#endif // HTTP_CURL_AVAILABLE

#ifdef HTTP_CURL_AVAILABLE
// Extract request fields from Elm Request record
// Request = { method : String, headers : List Header, url : String, body : Body,
//             expect : Expect a, timeout : Maybe Float, tracker : Maybe String }
// Fields in canonical order: body, expect, headers, method, timeout, tracker, url
bool extractRequest(uint64_t requestEnc, HttpContext& ctx, uint64_t& expectHandler) {
    void* ptr = Export::toPtr(requestEnc);
    if (!ptr) return false;

    Record* req = static_cast<Record*>(ptr);

    // Field indices in canonical order
    // 0: body, 1: expect, 2: headers, 3: method, 4: timeout, 5: tracker, 6: url

    // Get method
    HPointer methodHP = req->values[3].p;
    ctx.method = elmStringToUTF8(encodeHP(methodHP));

    // Get URL
    HPointer urlHP = req->values[6].p;
    ctx.url = elmStringToUTF8(encodeHP(urlHP));

    // Get headers (List (String, String))
    HPointer headersList = req->values[2].p;
    while (!isNil(headersList)) {
        void* cellPtr = Allocator::instance().resolve(headersList);
        if (!cellPtr) break;

        Cons* cell = static_cast<Cons*>(cellPtr);
        HPointer tupleHP = cell->head.p;

        void* tuplePtr = Allocator::instance().resolve(tupleHP);
        if (tuplePtr) {
            Tuple2* tuple = static_cast<Tuple2*>(tuplePtr);
            std::string key = elmStringToUTF8(encodeHP(tuple->a.p));
            std::string val = elmStringToUTF8(encodeHP(tuple->b.p));
            ctx.requestHeaders.push_back({key, val});
        }

        headersList = cell->tail;
    }

    // Get body
    HPointer bodyHP = req->values[0].p;
    void* bodyPtr = Allocator::instance().resolve(bodyHP);
    if (bodyPtr) {
        Custom* body = static_cast<Custom*>(bodyPtr);
        if (body->ctor == BODY_STRING) {
            ctx.requestBody = elmStringToUTF8(encodeHP(body->values[0].p));
        } else if (body->ctor == BODY_BYTES) {
            // Get bytes data
            HPointer bytesHP = body->values[0].p;
            void* bytesPtr = Allocator::instance().resolve(bytesHP);
            if (bytesPtr) {
                ByteBuffer* buf = static_cast<ByteBuffer*>(bytesPtr);
                ctx.requestBody = std::string(reinterpret_cast<char*>(buf->bytes), buf->header.size);
            }
        }
        // BODY_EMPTY and others leave requestBody empty
    }

    // Get expect handler
    HPointer expectHP = req->values[1].p;
    void* expectPtr = Allocator::instance().resolve(expectHP);
    if (expectPtr) {
        Custom* expect = static_cast<Custom*>(expectPtr);
        expectHandler = encodeHP(expect->values[0].p);  // The handler closure
    } else {
        return false;
    }

    return true;
}
#endif // HTTP_CURL_AVAILABLE

// Static evaluator for composed expect handler (used by mapExpect)
// args[0] = mapper closure
// args[1] = original handler
// args[2] = response argument
static void* composeExpectEvaluator(void* args[]) {
    uint64_t mapperEnc = reinterpret_cast<uint64_t>(args[0]);
    uint64_t handlerEnc = reinterpret_cast<uint64_t>(args[1]);
    uint64_t responseEnc = reinterpret_cast<uint64_t>(args[2]);

    // First call handler with response
    uint64_t resultEnc = eco_apply_closure(handlerEnc, &responseEnc, 1);

    // result is Result Error a
    // If Ok, map the value; if Err, return unchanged
    HPointer result = decodeHP(resultEnc);
    void* resultPtr = Allocator::instance().resolve(result);

    if (resultPtr) {
        Custom* resultCustom = static_cast<Custom*>(resultPtr);
        if (resultCustom->ctor == 0) {
            // Ok value - apply mapper
            uint64_t okValueEnc = encodeHP(resultCustom->values[0].p);
            uint64_t mappedEnc = eco_apply_closure(mapperEnc, &okValueEnc, 1);

            // Wrap in Ok
            HPointer mappedValue = decodeHP(mappedEnc);
            HPointer okResult = ok(boxed(mappedValue), true);
            return reinterpret_cast<void*>(encodeHP(okResult));
        }
    }

    // Return original result for Err
    return reinterpret_cast<void*>(resultEnc);
}

} // anonymous namespace

extern "C" {

uint64_t Elm_Kernel_Http_emptyBody() {
    // Return a Body Custom type representing empty body
    std::vector<Unboxable> values;  // No values for empty body
    HPointer body = custom(BODY_EMPTY, values, 0);
    return Export::encode(body);
}

uint64_t Elm_Kernel_Http_pair(uint64_t keyEnc, uint64_t valueEnc) {
    // Return a Header tuple (String, String)
    HPointer key = Export::decode(keyEnc);
    HPointer value = Export::decode(valueEnc);

    HPointer header = tuple2(boxed(key), boxed(value), 0);  // Both boxed strings
    return Export::encode(header);
}

uint64_t Elm_Kernel_Http_toTask(uint64_t requestEnc) {
#ifdef HTTP_CURL_AVAILABLE
    // Create a Task that performs the HTTP request
    // This creates a Binding task that spawns a thread

    HttpContext ctx;
    uint64_t expectHandler;

    if (!extractRequest(requestEnc, ctx, expectHandler)) {
        HPointer error = createError(ERR_BAD_URL, utf8ToElmString("Invalid request"));
        HPointer failTask = Scheduler::instance().taskFail(error);
        return Export::encode(failTask);
    }

    // Store request info in closure
    struct BindingCaptureData {
        HttpContext ctx;
        uint64_t expectHandler;
    };

    // Allocate capture data (will leak - proper impl would use GC or cleanup)
    auto* capture = new BindingCaptureData{std::move(ctx), expectHandler};

    // Create binding callback closure
    auto bindingEval = [](void* args[]) -> void* {
        // args[0] = captured BindingCaptureData*
        // args[1] = resume closure (passed by scheduler)
        uint64_t captureEnc = reinterpret_cast<uint64_t>(args[0]);
        uint64_t resumeEnc = reinterpret_cast<uint64_t>(args[1]);

        auto* cap = reinterpret_cast<BindingCaptureData*>(captureEnc);

        // Set resume closure in context and spawn thread
        cap->ctx.resumeClosureEnc = resumeEnc;
        cap->ctx.expectHandlerEnc = cap->expectHandler;

        // Spawn worker thread
        std::thread worker(httpWorkerThread, cap->ctx);
        worker.detach();

        // Delete capture data after copying to ctx
        delete cap;

        // Return Unit as kill handle (no cleanup needed)
        return reinterpret_cast<void*>(encodeHP(unit()));
    };

    // Allocate the closure (+ converts captureless lambda to function pointer)
    EvalFunction bindingFn = +bindingEval;
    HPointer bindingCallback = allocClosure(bindingFn, 2);
    void* clPtr = Allocator::instance().resolve(bindingCallback);
    if (clPtr) {
        // Capture the data pointer
        closureCapture(clPtr, Unboxable{.i = reinterpret_cast<int64_t>(capture)}, false);
    }

    // Create the binding task
    HPointer task = Scheduler::instance().taskBinding(bindingCallback);
    return Export::encode(task);
#else
    // HTTP not available - return NetworkError
    (void)requestEnc;
    HPointer error = createError(ERR_NETWORK_ERROR);
    HPointer failTask = Scheduler::instance().taskFail(error);
    return Export::encode(failTask);
#endif
}

uint64_t Elm_Kernel_Http_expect(uint64_t responseToResultEnc) {
    // Create an Expect value that wraps the response-to-result function
    // Expect = Custom { ctor: EXPECT_CTOR, values: [handler] }

    HPointer handler = Export::decode(responseToResultEnc);

    std::vector<Unboxable> values(1);
    values[0].p = handler;

    HPointer expect = custom(EXPECT_CTOR, values, 0);  // handler is boxed
    return Export::encode(expect);
}

uint64_t Elm_Kernel_Http_mapExpect(uint64_t closureEnc, uint64_t expectEnc) {
    // Map a function over an Expect
    // Returns a new Expect that applies the mapper to the result

    // Get the original handler
    void* expectPtr = Export::toPtr(expectEnc);
    if (!expectPtr) {
        return expectEnc;  // Return unchanged if invalid
    }

    Custom* expect = static_cast<Custom*>(expectPtr);
    HPointer originalHandler = expect->values[0].p;

    // Create a new handler that composes: closure ∘ originalHandler
    // This is: \response -> mapper (originalHandler response)

    // Allocate composed closure with static evaluator
    HPointer composed = allocClosure(composeExpectEvaluator, 3);
    void* clPtr = Allocator::instance().resolve(composed);
    if (clPtr) {
        HPointer mapper = Export::decode(closureEnc);
        closureCapture(clPtr, boxed(mapper), true);
        closureCapture(clPtr, boxed(originalHandler), true);
    }

    // Create new Expect with composed handler
    std::vector<Unboxable> values(1);
    values[0].p = composed;

    HPointer newExpect = custom(EXPECT_CTOR, values, 0);
    return Export::encode(newExpect);
}

uint64_t Elm_Kernel_Http_bytesToBlob(uint64_t bytesEnc, uint64_t mimeTypeEnc) {
    // Create a Body from Bytes with a mime type
    // Body = Custom { ctor: BODY_BLOB, values: [bytes, mimeType] }

    HPointer bytes = Export::decode(bytesEnc);
    HPointer mimeType = Export::decode(mimeTypeEnc);

    std::vector<Unboxable> values(2);
    values[0].p = bytes;
    values[1].p = mimeType;

    HPointer body = custom(BODY_BLOB, values, 0);  // both boxed
    return Export::encode(body);
}

uint64_t Elm_Kernel_Http_toDataView(uint64_t bytesEnc) {
    // Create a Body from Bytes (raw bytes body)
    // Body = Custom { ctor: BODY_BYTES, values: [bytes] }

    HPointer bytes = Export::decode(bytesEnc);

    std::vector<Unboxable> values(1);
    values[0].p = bytes;

    HPointer body = custom(BODY_BYTES, values, 0);
    return Export::encode(body);
}

uint64_t Elm_Kernel_Http_toFormData(uint64_t partsEnc) {
    // Create a multipart form Body from a list of parts
    // Body = Custom { ctor: BODY_FORM, values: [parts] }

    HPointer parts = Export::decode(partsEnc);

    std::vector<Unboxable> values(1);
    values[0].p = parts;

    HPointer body = custom(BODY_FORM, values, 0);
    return Export::encode(body);
}

#ifdef HTTP_CURL_AVAILABLE
// Global curl initialization (should be called once)
__attribute__((constructor))
static void initCurl() {
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

__attribute__((destructor))
static void cleanupCurl() {
    curl_global_cleanup();
}
#endif // HTTP_CURL_AVAILABLE

} // extern "C"
