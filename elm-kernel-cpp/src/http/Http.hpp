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

// Body types
enum class BodyType { Empty, String, Json, Bytes, FormData };

/**
 * Create empty body.
 */
HPointer emptyBody();

/**
 * Create body with string content.
 */
HPointer stringBody(void* contentType, void* content);

/**
 * Create a key-value pair for headers/params.
 */
HPointer pair(void* key, void* value);

/**
 * Convert HTTP request to Task.
 * Returns Task that fails with NetworkError (not implemented).
 */
TaskPtr toTask(HPointer request);

/**
 * Cancel an HTTP request.
 */
void cancel(void* tracker);

/**
 * Create BadUrl response.
 */
HPointer badUrl(void* url);

/**
 * Create Timeout response.
 */
HPointer timeout();

/**
 * Create NetworkError response.
 */
HPointer networkError();

} // namespace Elm::Kernel::Http

#endif // ELM_KERNEL_HTTP_HPP
