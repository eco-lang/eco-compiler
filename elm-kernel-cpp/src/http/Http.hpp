#ifndef ELM_KERNEL_HTTP_HPP
#define ELM_KERNEL_HTTP_HPP

/**
 * Elm Kernel Http Module - Runtime Heap Integration
 *
 * Provides HTTP request operations using GC-managed heap values.
 * Note: This is a stub - full implementation requires HTTP client library.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "../core/Scheduler.hpp"

namespace Elm::Kernel::Http {

using TaskPtr = Scheduler::TaskPtr;

// ============================================================================
// Body Construction
// ============================================================================

/**
 * Create empty body.
 */
HPointer emptyBody();

// ============================================================================
// Header/Param helpers
// ============================================================================

/**
 * Create a key-value pair for headers/params.
 */
HPointer pair(void* key, void* value);

// ============================================================================
// Request Conversion
// ============================================================================

/**
 * Convert HTTP request to Task.
 * Returns Task that fails with NetworkError (not implemented).
 */
TaskPtr toTask(HPointer request);

// ============================================================================
// Expect/Response handling
// ============================================================================

/**
 * Create an Expect value for response handling.
 */
HPointer expect(HPointer responseToResult);

/**
 * Map over an Expect value.
 */
HPointer mapExpect(std::function<HPointer(HPointer)> func, HPointer expectVal);

// ============================================================================
// Data conversion helpers
// ============================================================================

/**
 * Convert bytes to a Blob representation.
 */
HPointer bytesToBlob(void* bytes, void* mimeType);

/**
 * Convert bytes to a DataView.
 */
HPointer toDataView(void* bytes);

/**
 * Create FormData from a list of parts.
 */
HPointer toFormData(HPointer parts);

} // namespace Elm::Kernel::Http

#endif // ELM_KERNEL_HTTP_HPP
