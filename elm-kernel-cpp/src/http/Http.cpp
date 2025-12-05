/**
 * Elm Kernel Http Module - Runtime Heap Integration
 *
 * Provides HTTP request operations using GC-managed heap values.
 * Note: This is a stub - full implementation requires HTTP client library.
 */

#include "Http.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"
#include "allocator/ListOps.hpp"

namespace Elm::Kernel::Http {

// Response type constructor tags
constexpr u16 TAG_BAD_URL = 0;
constexpr u16 TAG_TIMEOUT = 1;
constexpr u16 TAG_NETWORK_ERROR = 2;
constexpr u16 TAG_BAD_STATUS = 3;
constexpr u16 TAG_GOOD_STATUS = 4;

// Body type constructor tags
constexpr u16 TAG_BODY_EMPTY = 0;
constexpr u16 TAG_BODY_STRING = 1;
constexpr u16 TAG_BODY_JSON = 2;
constexpr u16 TAG_BODY_BYTES = 3;
constexpr u16 TAG_BODY_FILE = 4;

// ============================================================================
// Body constructors
// ============================================================================

HPointer emptyBody() {
    // Return a Custom type representing empty body
    // { $: 0 } in JS
    return alloc::custom(TAG_BODY_EMPTY, {}, 0);
}

HPointer stringBody(void* contentType, void* content) {
    // Return a Custom type with content type and string content
    // { $: 1, a: contentType, b: content }
    HPointer ctPtr = Allocator::instance().wrap(contentType);
    HPointer cPtr = Allocator::instance().wrap(content);
    return alloc::custom(TAG_BODY_STRING, {alloc::boxed(ctPtr), alloc::boxed(cPtr)}, 0);
}

// ============================================================================
// Helper functions
// ============================================================================

HPointer pair(void* key, void* value) {
    // Create a tuple2 for key-value pairs (headers, form data)
    HPointer keyPtr = Allocator::instance().wrap(key);
    HPointer valPtr = Allocator::instance().wrap(value);
    return alloc::tuple2(alloc::boxed(keyPtr), alloc::boxed(valPtr), 0);
}

// ============================================================================
// Response constructors
// ============================================================================

HPointer badUrl(void* url) {
    // BadUrl_ : String -> Response body
    HPointer urlPtr = Allocator::instance().wrap(url);
    return alloc::custom(TAG_BAD_URL, {alloc::boxed(urlPtr)}, 0);
}

HPointer timeout() {
    // Timeout_ : Response body (no fields)
    return alloc::custom(TAG_TIMEOUT, {}, 0);
}

HPointer networkError() {
    // NetworkError_ : Response body (no fields)
    return alloc::custom(TAG_NETWORK_ERROR, {}, 0);
}

HPointer badStatus(void* metadata, void* body) {
    // BadStatus_ : Metadata -> body -> Response body
    HPointer metaPtr = Allocator::instance().wrap(metadata);
    HPointer bodyPtr = Allocator::instance().wrap(body);
    return alloc::custom(TAG_BAD_STATUS, {alloc::boxed(metaPtr), alloc::boxed(bodyPtr)}, 0);
}

HPointer goodStatus(void* metadata, void* body) {
    // GoodStatus_ : Metadata -> body -> Response body
    HPointer metaPtr = Allocator::instance().wrap(metadata);
    HPointer bodyPtr = Allocator::instance().wrap(body);
    return alloc::custom(TAG_GOOD_STATUS, {alloc::boxed(metaPtr), alloc::boxed(bodyPtr)}, 0);
}

// ============================================================================
// HTTP Request Task
// ============================================================================

TaskPtr toTask(HPointer request) {
    /*
     * Create a Task that performs HTTP request.
     *
     * This is a stub implementation. For full functionality:
     * - Use Boost.Beast for HTTP client
     * - Or libcurl for a simpler interface
     * - Handle async execution, timeouts, progress tracking
     */
    (void)request;

    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Return network error to indicate not implemented
        callback(networkError());

        // Return kill function
        return []() {
            // Would abort the HTTP request
        };
    });
}

void cancel(void* tracker) {
    // Cancel an HTTP request by tracker
    // Stub implementation - would cancel actual request
    (void)tracker;
}

} // namespace Elm::Kernel::Http
