#include "JsArray.hpp"
#include "allocator/Allocator.hpp"

namespace Elm::Kernel::JsArray {

HPointer initializeFromList(u32 max, HPointer list) {
    auto& allocator = Allocator::instance();

    // `list` arrives unrooted, so it is copied into a rooted local before `allocArray` can move it. `arr`
    // is rooted too, for the allocations after the walk.
    HPointer current = list;
    HPointer arr = alloc::listNil();
    Elm::StackRootGuard roots(&current, &arr);

    arr = alloc::allocArray(max);

    // A list may mix cons cells and chunk views, so it is walked with a cursor. Nothing in the loop
    // allocates: `arr` was sized to `max` up front, and the pushes and the cursor never allocate.
    u32 count = 0;
    alloc::RootedListCursor cursor(current);
    Unboxable head;
    u8 kind;
    while (count < max && cursor.read(head, kind)) {
        void* arrObj = allocator.resolve(arr);
        if (kind == 0) {
            alloc::arrayPush(arrObj, alloc::boxed(head.p), true);
        } else {
            alloc::arrayPushKind(arrObj, head, static_cast<u8>(kind));
        }
        cursor.advance();
        ++count;
    }

    // The rest of the list is the cursor's node with its first `idx` elements dropped. At a cons cell
    // `idx` is 0 and the node is the rest. Part way through a chunk view, the rest is a new view starting
    // `idx` elements later, or the view's `next` if its run is used up.
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

    // `remaining` is rooted for the `tuple2` allocation.
    Elm::StackRootGuard remGuard(&remaining);
    return alloc::tuple2(alloc::boxed(arr), alloc::boxed(remaining), 0);
}

} // namespace Elm::Kernel::JsArray
