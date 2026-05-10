/**
 * Elm Kernel JsArray Module — Runtime Heap Integration
 *
 * See header for the scoping story. Only `initializeFromList` lives here;
 * the rest of the JsArray surface is implemented as C-linkage entries in
 * `JsArrayExports.cpp`.
 */

#include "JsArray.hpp"
#include "allocator/Allocator.hpp"

namespace Elm::Kernel::JsArray {

HPointer initializeFromList(u32 max, HPointer list) {
    auto& allocator = Allocator::instance();

    // `list` and the freshly-allocated `arr` must both be rooted across
    // every alloc-capable call (allocArray, the final tuple2). A by-value
    // HPointer parameter is unrooted; a minor GC during allocArray would
    // leave `list` pointing at post-swap to-space (caught by the
    // validator's STALE hptr trip in the resolve hot path).
    HPointer current = list;
    HPointer arr = alloc::listNil();  // placeholder; assigned below
    Elm::StackRootGuard roots(&current, &arr);

    arr = alloc::allocArray(max);

    u32 count = 0;
    while (count < max && !alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = static_cast<Header*>(cell);

        uint32_t kind = Elm::tupleFieldKind(hdr->unboxed, 0);
        void* arrObj = allocator.resolve(arr);

        if (kind == 0) {
            alloc::arrayPush(arrObj, alloc::boxed(c->head.p), true);
        } else {
            // Unboxed primitive — use kind-aware push to set the array's uniform kind.
            alloc::arrayPushKind(arrObj, c->head, static_cast<u8>(kind));
        }

        current = c->tail;
        ++count;
    }

    // Return Tuple2(array, remaining_list)
    return alloc::tuple2(alloc::boxed(arr), alloc::boxed(current), 0);
}

} // namespace Elm::Kernel::JsArray
