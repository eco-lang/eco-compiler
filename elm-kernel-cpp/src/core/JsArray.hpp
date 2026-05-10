#ifndef ECO_JSARRAY_HPP
#define ECO_JSARRAY_HPP

/**
 * Elm Kernel JsArray Module — Runtime Heap Integration
 *
 * The full JsArray surface (length / push / unsafeGet / unsafeSet / map /
 * indexedMap / fold / slice / appendN / ...) is implemented directly in
 * `JsArrayExports.cpp` as C-linkage `Elm_Kernel_JsArray_*` entries. The
 * native-function-pointer variants previously declared in this header
 * (which paired `alloc::allocArray` with a per-iteration `func` call) had
 * no callers and would have hit the HEAP_BUILDER_001..003 bug pattern; they
 * were deleted 2026-05-10. Only `initializeFromList` survives — it has no
 * closure call inside the loop and is invoked from `Elm_Kernel_JsArray_
 * initializeFromList{,_Int}`.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::JsArray {

/**
 * Creates an array from up to `max` elements of a list.
 * Returns Tuple2(array, remaining_list). No user-closure calls inside the
 * walk, so no builder-bit treatment is needed.
 */
HPointer initializeFromList(u32 max, HPointer list);

} // namespace Elm::Kernel::JsArray

#endif // ECO_JSARRAY_HPP
