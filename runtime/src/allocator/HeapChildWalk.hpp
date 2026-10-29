#pragma once

#include "AllocatorCommon.hpp"
#include "Heap.hpp"

namespace Elm {

// Code that copies a heap object, or checks a collector's work against an independent trace,
// needs to find the object's children without depending on any one collector's own scan. This
// component is that walk: one function, `visitHeapChildren`, that reads an object's tag and hands
// each of its child slots to a callable.
//
// A child slot is a field that may hold an HPointer. For an `HPointer` field that is always so. For
// an `Unboxable` field it is so only when the field's 2-bit slot kind, read from the header or the
// object's kind words as `allocator/Heap` lays out, is 00 (boxed). A child slot can still hold an
// embedded constant or a word that is not a heap address, so the walk does not say that a slot
// points into the heap; telling those apart is left to the callable.
//
// The walk is modelled on the old generation's mark scan, `OldGenSpace::markChildren`, and like it
// treats the `body` of a large String or Bytes header as a child. It differs in what it refuses.
// Some tags are declined: the function visits nothing and returns false, so that a caller copying
// objects can give up on the value. A `Process` is declined because its fields are changed in place
// while it runs; `Free`, `Forward` and any tag not listed are declined because they are not live
// objects with a known layout.

// Calls `visit` on each child slot of the heap object `obj`, and returns whether its tag is one
// the walk handles.
//
// `obj` must point at a heap object's header, and that object must not move while the call runs.
// `visit` is called as `visit(HPointer&)`, with a reference to the slot inside `obj`, so it may
// rewrite the slot; the reference is valid only for that call. It is called once per child slot,
// in field order, whatever the slot holds, so it must itself
// skip embedded constants and words that are not heap addresses.
//
// Pointer-free objects return true with no call. `Tag_Process`, `Tag_Free`, `Tag_Forward` and
// unknown tags return false with no call. Only the live part of a variable-length object is
// visited: a `Closure`'s first `n_values` slots, a `ListBacking`'s `elems[hd, header.size)` and an
// `ElmArray`'s `elements[0, length)`. Every value of a `DynRecord` is visited, whatever its
// `unboxed` field holds.
template <typename F>
inline bool visitHeapChildren(void *obj, F &&visit) {
    Header *hdr = getHeader(obj);
    switch (hdr->tag) {
        // Pointer-free leaves.
        case Tag_Int:
        case Tag_Float:
        case Tag_Char:
        case Tag_String:
        case Tag_StringUtf8Leaf:
        case Tag_ByteBuffer:
        case Tag_FieldGroup:
            return true;

        case Tag_Tuple2: {
            Tuple2 *t = static_cast<Tuple2 *>(obj);
            if (tupleFieldKind(hdr->unboxed, 0) == 0) visit(t->a.p);
            if (tupleFieldKind(hdr->unboxed, 1) == 0) visit(t->b.p);
            return true;
        }
        case Tag_Tuple3: {
            Tuple3 *t = static_cast<Tuple3 *>(obj);
            if (tupleFieldKind(hdr->unboxed, 0) == 0) visit(t->a.p);
            if (tupleFieldKind(hdr->unboxed, 1) == 0) visit(t->b.p);
            if (tupleFieldKind(hdr->unboxed, 2) == 0) visit(t->c.p);
            return true;
        }
        case Tag_Cons: {
            Cons *c = static_cast<Cons *>(obj);
            if (tupleFieldKind(hdr->unboxed, 0) == 0) visit(c->head.p);
            visit(c->tail);
            return true;
        }
        case Tag_ConsChunk: {
            ConsChunk *cv = static_cast<ConsChunk *>(obj);
            visit(cv->backing);
            visit(cv->next);
            return true;
        }
        case Tag_ListBacking: {
            // Slots below hd are uninitialized.
            if ((hdr->unboxed & 0x3) == 0) {
                ListBacking *lb = static_cast<ListBacking *>(obj);
                for (u32 i = lb->hd; i < hdr->size; i++)
                    visit(lb->elems[i].p);
            }
            return true;
        }
        case Tag_Custom: {
            // The first slots take their kinds from the bitmap after the header, the rest from
            // the extension kind words in the tail.
            Custom *c = static_cast<Custom *>(obj);
            const u32 n = hdr->size, h = n < CUSTOM_HDR_SLOTS ? n : CUSTOM_HDR_SLOTS;
            for (u32 i = 0; i < h; i++)
                if (kindInWord(c->unboxed, i) == 0) visit(c->values[i].p);
            for (u32 i = h; i < n; i++)
                if (customSlotKind(c, i) == 0) visit(c->values[i].p);
            return true;
        }
        case Tag_Record: {
            Record *r = static_cast<Record *>(obj);
            const u32 n = hdr->size, h = n < RECORD_HDR_SLOTS ? n : RECORD_HDR_SLOTS;
            for (u32 i = 0; i < h; i++)
                if (kindInWord(r->unboxed, i) == 0) visit(r->values[i].p);
            for (u32 i = h; i < n; i++)
                if (recordSlotKind(r, i) == 0) visit(r->values[i].p);
            return true;
        }
        case Tag_DynRecord: {
            DynRecord *dr = static_cast<DynRecord *>(obj);
            visit(dr->fieldgroup);
            for (u32 i = 0; i < hdr->size; i++)
                visit(dr->values[i]);
            return true;
        }
        case Tag_Closure: {
            // Slots from n_values on hold no applied argument yet. A closure with no
            // arguments applied therefore has no children.
            Closure *cl = static_cast<Closure *>(obj);
            for (u32 i = 0; i < cl->n_values; i++)
                if (closureSlotKind(cl, i) == 0) visit(cl->values[i].p);
            return true;
        }
        case Tag_Task: {
            // Not declined: the scheduler installs a kill handle on a copy of a Task, not on
            // the Task itself.
            Task *t = static_cast<Task *>(obj);
            if ((t->header.unboxed & 0x3) == 0) visit(t->value.p);
            visit(t->callback);
            visit(t->kill);
            visit(t->task);
            return true;
        }
        case Tag_Array: {
            // Slots from length up to the capacity are uninitialized.
            ElmArray *arr = static_cast<ElmArray *>(obj);
            if ((arr->header.unboxed & 0x3) == 0)
                for (u32 i = 0; i < arr->length; i++)
                    visit(arr->elements[i].p);
            return true;
        }
        case Tag_StringSlice:
            visit(static_cast<ElmStringSlice *>(obj)->base);
            return true;
        case Tag_StringUtf8View:
            visit(static_cast<ElmStringUtf8View *>(obj)->base);
            return true;
        case Tag_ByteBufferSlice:
            visit(static_cast<ElmByteBufferSlice *>(obj)->base);
            return true;
        case Tag_StringRope: {
            ElmStringRope *r = static_cast<ElmStringRope *>(obj);
            visit(r->left);
            visit(r->right);
            return true;
        }
        case Tag_LargeStringHeader:
            visit(static_cast<LargeStringHeader *>(obj)->body);
            return true;
        case Tag_LargeByteHeader:
            visit(static_cast<LargeByteHeader *>(obj)->body);
            return true;

        // Declined: a Process is changed in place; the others are not live objects.
        case Tag_Process:
        case Tag_Free:
        case Tag_Forward:
        default:
            return false;
    }
}

} // namespace Elm
