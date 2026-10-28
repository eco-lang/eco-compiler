#pragma once

// The minor collector's definition of which slots of an object are its children. The region
// drain's validators, the tenure engine and the hand-over closure check on a Tenuring extent
// call it; `NurserySpace::scanObject` and `scanEntryP` keep their own per-tag walks.
//
// A child slot is a slot that may hold an HPointer: a field whose slot kind (00 boxed, 01 Int,
// 10 Float, 11 Char) is boxed, or a pointer field that has no kind. `forEachChildSlot` visits
// exactly these, per tag, and `nurseryTagHasChildren` names the tags for which it can visit any.
//
// A large String or Bytes header's `body` is not a child. The body is a header-less payload in
// the old generation, tracked by the large-body index rather than traced (HEAP_026, HEAP_081).
// A Process's three pointers are children.

#include "AllocatorCommon.hpp"
#include "Heap.hpp"

namespace Elm {

/// Calls `f(HPointer&)` once for each child slot of the object at `obj`, in slot order.
///
/// Per tag: a tuple's fields, a Cons head, a Custom's or Record's values, and a Task's `value`
/// are visited only when their kind is boxed. A Closure's slots are visited below `n_values` only,
/// and then only the boxed ones. A ListBacking's elements `[hd, header.size)` and an Array's
/// `[0, length)` are visited only when the uniform kind in `header.unboxed` bits 1:0 is boxed.
/// Every DynRecord value and its `fieldgroup` are visited; its kind bitmap is not read.
/// The other pointer fields (Cons tail, ConsChunk, Task, Process, slice, view and rope links)
/// are always visited. Any other tag, including large String and Bytes headers, visits nothing.
///
/// A visited slot may hold null, an embedded constant or a pointer outside the nursery, so `f`
/// must filter those itself. `f` gets a reference into the object and may rewrite the slot.
template <typename F>
inline void forEachChildSlot(void* obj, F&& f) {
    Header* hdr = getHeader(obj);
    switch (hdr->tag) {
        case Tag_Tuple2: {
            Tuple2* t = static_cast<Tuple2*>(obj);
            if (tupleFieldKind(hdr->unboxed, 0) == 0) f(t->a.p);
            if (tupleFieldKind(hdr->unboxed, 1) == 0) f(t->b.p);
            break;
        }
        case Tag_Tuple3: {
            Tuple3* t = static_cast<Tuple3*>(obj);
            if (tupleFieldKind(hdr->unboxed, 0) == 0) f(t->a.p);
            if (tupleFieldKind(hdr->unboxed, 1) == 0) f(t->b.p);
            if (tupleFieldKind(hdr->unboxed, 2) == 0) f(t->c.p);
            break;
        }
        case Tag_Custom: {
            // Kinds of the first slots are in the header word, the rest in ext words (HEAP_019).
            Custom* c = static_cast<Custom*>(obj);
            const u32 n = hdr->size, h = n < CUSTOM_HDR_SLOTS ? n : CUSTOM_HDR_SLOTS;
            for (u32 i = 0; i < h; i++)
                if (kindInWord(c->unboxed, i) == 0) f(c->values[i].p);
            for (u32 i = h; i < n; i++)
                if (customSlotKind(c, i) == 0) f(c->values[i].p);
            break;
        }
        case Tag_Record: {
            Record* r = static_cast<Record*>(obj);
            const u32 n = hdr->size, h = n < RECORD_HDR_SLOTS ? n : RECORD_HDR_SLOTS;
            for (u32 i = 0; i < h; i++)
                if (kindInWord(r->unboxed, i) == 0) f(r->values[i].p);
            for (u32 i = h; i < n; i++)
                if (recordSlotKind(r, i) == 0) f(r->values[i].p);
            break;
        }
        case Tag_DynRecord: {
            DynRecord* dr = static_cast<DynRecord*>(obj);
            f(dr->fieldgroup);
            for (u32 i = 0; i < hdr->size; i++) f(dr->values[i]);
            break;
        }
        case Tag_Closure: {
            Closure* cl = static_cast<Closure*>(obj);   // Only the applied arguments.
            for (u32 i = 0; i < cl->n_values; i++)
                if (closureSlotKind(cl, i) == 0) f(cl->values[i].p);
            break;
        }
        case Tag_Cons: {
            Cons* c = static_cast<Cons*>(obj);
            if (tupleFieldKind(hdr->unboxed, 0) == 0) f(c->head.p);
            f(c->tail);
            break;
        }
        case Tag_ConsChunk: {
            ConsChunk* cv = static_cast<ConsChunk*>(obj);
            f(cv->backing);
            f(cv->next);
            break;
        }
        case Tag_ListBacking: {
            if ((hdr->unboxed & 0x3) != 0) break;
            ListBacking* lb = static_cast<ListBacking*>(obj);
            for (u32 i = lb->hd; i < hdr->size; i++) f(lb->elems[i].p);
            break;
        }
        case Tag_Task: {
            Task* t = static_cast<Task*>(obj);
            if ((t->header.unboxed & 0x3) == 0) f(t->value.p);
            f(t->callback);
            f(t->kill);
            f(t->task);
            break;
        }
        case Tag_Process: {
            Process* p = static_cast<Process*>(obj);
            f(p->root);
            f(p->stack);
            f(p->mailbox);
            break;
        }
        case Tag_Array: {
            ElmArray* arr = static_cast<ElmArray*>(obj);
            if ((arr->header.unboxed & 0x3) != 0) break;
            for (u32 i = 0; i < arr->length; i++) f(arr->elements[i].p);
            break;
        }
        case Tag_StringSlice: f(static_cast<ElmStringSlice*>(obj)->base); break;
        case Tag_StringUtf8View: f(static_cast<ElmStringUtf8View*>(obj)->base); break;
        case Tag_ByteBufferSlice: f(static_cast<ElmByteBufferSlice*>(obj)->base); break;
        case Tag_StringRope: {
            ElmStringRope* r = static_cast<ElmStringRope*>(obj);
            f(r->left);
            f(r->right);
            break;
        }
        default:
            break;
    }
}

/// Returns whether an object with tag `tag` can have a child slot, that is, whether
/// `forEachChildSlot` has a case for it. An object of such a tag may still visit nothing, for
/// example an Array of unboxed Ints.
inline bool nurseryTagHasChildren(uint32_t tag) {
    switch (tag) {
        case Tag_Tuple2: case Tag_Tuple3: case Tag_Custom: case Tag_Record:
        case Tag_DynRecord: case Tag_Closure: case Tag_Cons: case Tag_ConsChunk:
        case Tag_ListBacking: case Tag_Task: case Tag_Process: case Tag_Array:
        case Tag_StringSlice: case Tag_StringUtf8View: case Tag_ByteBufferSlice:
        case Tag_StringRope:
            return true;
        default:
            return false;
    }
}

}  // namespace Elm
