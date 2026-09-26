#pragma once

#include "AllocatorCommon.hpp"
#include "Heap.hpp"

namespace Elm {

//===--------------------------------------------------------------------===//
// Per-tag child walk — mirror of OldGenSpace::markChildren. Shared by
// PermanentSpace (copy-to-permanent) and the threaded-gc-04b V2 validator.
//
// `visit` is called for every POTENTIALLY-BOXED child slot (HPointer fields
// always; Unboxable fields only when the mask says boxed). The lambda owns
// the constant / non-heap gating. Returns false when the tag is not safe to
// copy (mutable innards or unknown layout) — the decline ladder.
//===--------------------------------------------------------------------===//

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
            // Chunked-list backing: visit live boxed slots [hd, capacity).
            // A permanent copy freezes the chunk (immutable in v1 anyway);
            // slack below hd (v1: none) is never visited.
            if ((hdr->unboxed & 0x3) == 0) {
                ListBacking *lb = static_cast<ListBacking *>(obj);
                for (u32 i = lb->hd; i < hdr->size; i++)
                    visit(lb->elems[i].p);
            }
            return true;
        }
        case Tag_Custom: {
            Custom *c = static_cast<Custom *>(obj);
            for (u32 i = 0; i < hdr->size && i < 24; i++)
                if (fieldKind(c->unboxed, i) == 0) visit(c->values[i].p);
            return true;
        }
        case Tag_Record: {
            Record *r = static_cast<Record *>(obj);
            for (u32 i = 0; i < hdr->size && i < 32; i++)
                if (fieldKind(r->unboxed, i) == 0) visit(r->values[i].p);
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
            // Bounds on n_values, matching the nursery and major scans.
            // An interned closure singleton has n_values == 0 and never
            // writes a value slot, so this visits nothing — which is right.
            Closure *cl = static_cast<Closure *>(obj);
            for (u32 i = 0; i < cl->n_values; i++)
                if (fieldKind(cl->unboxed, i) == 0) visit(cl->values[i].p);
            return true;
        }
        case Tag_Task: {
            // Immutable post task-purity (kill is copy-on-install).
            Task *t = static_cast<Task *>(obj);
            if ((t->header.unboxed & 0x3) == 0) visit(t->value.p);
            visit(t->callback);
            visit(t->kill);
            visit(t->task);
            return true;
        }
        case Tag_Array: {
            // Mutated during construction only; immutable at rest (Array.set
            // path-copies). Iterate length like mark; the capacity tail is
            // uninitialized and copied as raw bytes only.
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

        // Declines: mutable innards (Process) or must-not-appear tags.
        case Tag_Process:
        case Tag_Free:
        case Tag_Forward:
        default:
            return false;
    }
}

} // namespace Elm
