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

    // Hybrid spines: walk via a rooted (node, idx) cursor. arrayPush can
    // allocate (array growth), so re-resolve everything from rooted state
    // each iteration; `remaining` is materialized at the end via
    // listTailOf-equivalent stepping so a mid-chunk stop yields a proper
    // list value.
    u32 count = 0;
    alloc::RootedListCursor cursor(current);
    Unboxable head;
    u8 kind;
    while (count < max && cursor.read(head, kind)) {
        void* arrObj = allocator.resolve(arr);
        if (kind == 0) {
            alloc::arrayPush(arrObj, alloc::boxed(head.p), true);
        } else {
            // Unboxed primitive — use kind-aware push to set the array's uniform kind.
            alloc::arrayPushKind(arrObj, head, static_cast<u8>(kind));
        }
        cursor.advance();
        ++count;
    }

    // Remaining list: the cursor's node with `idx` elements consumed from
    // its run. For a cell (idx == 0) that is just the node; for a mid-run
    // view materialize the successor view by stepping idx times via
    // listTailOf (allocates at most once — listTailOf collapses the offset
    // arithmetic in a single view when idx > 0).
    HPointer remaining = cursor.node;
    if (cursor.idx > 0 && !alloc::isNil(remaining) && remaining.ptr_ind == 0) {
        void* obj = allocator.resolve(remaining);
        if (obj && getHeader(obj)->tag == Tag_ConsChunk) {
            ConsChunk* cv = static_cast<ConsChunk*>(obj);
            ListBacking* lb = static_cast<ListBacking*>(
                allocator.resolve(cv->backing));
            u32 run = lb->header.size - cv->offset;
            if (cv->len < run) run = cv->len;
            if (cursor.idx >= run) {
                remaining = cv->next;
            } else {
                remaining = alloc::consChunkView(
                    cv->backing, cv->offset + cursor.idx,
                    cv->len - cursor.idx, cv->next,
                    static_cast<u8>(getHeader(obj)->unboxed & 0x3));
            }
        }
    }

    // Return Tuple2(array, remaining_list). `remaining` is rooted across
    // tuple2 via the guard on `current`… it is a fresh value; root it.
    Elm::StackRootGuard remGuard(&remaining);
    return alloc::tuple2(alloc::boxed(arr), alloc::boxed(remaining), 0);
}

} // namespace Elm::Kernel::JsArray
