/**
 * Elm Kernel Http Module - Runtime Heap Integration
 *
 * Provides HTTP request operations using GC-managed heap values.
 * Note: This is a stub - full implementation requires HTTP client library.
 */

#include "Http.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"
#include <cassert>

namespace Elm::Kernel::Http {

// ============================================================================
// Body Construction
// ============================================================================

HPointer emptyBody() {
    return alloc::custom(0, {}, 0);
}

// ============================================================================
// Header/Param helpers
// ============================================================================

HPointer pair(void* key, void* value) {
    HPointer keyPtr = Allocator::instance().wrap(key);
    HPointer valuePtr = Allocator::instance().wrap(value);
    return alloc::tuple2(alloc::boxed(keyPtr), alloc::boxed(valuePtr), 0);
}

// ============================================================================
// Request Conversion
// ============================================================================

HPointer toTask(HPointer request) {
    (void)request;
    assert(false && "not implemented");
    return alloc::unit();
}

// ============================================================================
// Expect/Response handling
// ============================================================================

HPointer expect(HPointer responseToResult) {
    // Wrap the response handler function as Custom
    return alloc::custom(0, {alloc::boxed(responseToResult)}, 0);
}

HPointer mapExpect(std::function<HPointer(HPointer)> func, HPointer expectVal) {
    (void)func;
    // Return expectVal unchanged (stub)
    return expectVal;
}

// ============================================================================
// Data conversion helpers
// ============================================================================

HPointer bytesToBlob(void* bytes, void* mimeType) {
    // Create a blob representation (Custom with bytes and mime type)
    HPointer bytesPtr = Allocator::instance().wrap(bytes);
    HPointer mimePtr = Allocator::instance().wrap(mimeType);
    return alloc::custom(0, {alloc::boxed(bytesPtr), alloc::boxed(mimePtr)}, 0);
}

HPointer toDataView(void* bytes) {
    // Return bytes wrapped as Custom (stub DataView)
    HPointer bytesPtr = Allocator::instance().wrap(bytes);
    return alloc::custom(0, {alloc::boxed(bytesPtr)}, 0);
}

HPointer toFormData(HPointer parts) {
    // Return parts wrapped as Custom (stub FormData)
    return alloc::custom(0, {alloc::boxed(parts)}, 0);
}

} // namespace Elm::Kernel::Http
