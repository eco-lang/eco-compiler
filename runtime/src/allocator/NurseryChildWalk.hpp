#pragma once

// threaded-gc-07 (plans/threaded-gc-07-concurrent-tenuring.md P§3.11): the
// nursery's per-tag child-slot walk, factored from phase 6's scanEntryP arms
// (the legacy scanObject / scanEntryP are left untouched). The region drain's
// validators, the tenure engine and TV2 share it.
//
// f(HPointer& slot) is called for every BOXED child slot the minor GC traces:
// Unboxable fields only when their kind bit says boxed, Closure slots below
// n_values only, the live range of a boxed ListBacking, the elements of a
// boxed Array. A large header's body is NOT a child (it lives in the old gen
// and is tracked by the body index, HEAP_026).

#include "AllocatorCommon.hpp"
#include "Heap.hpp"

namespace Elm {

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
            Custom* c = static_cast<Custom*>(obj);
            for (u32 i = 0; i < hdr->size && i < 24; i++)
                if (fieldKind(c->unboxed, i) == 0) f(c->values[i].p);
            break;
        }
        case Tag_Record: {
            Record* r = static_cast<Record*>(obj);
            for (u32 i = 0; i < hdr->size && i < 32; i++)
                if (fieldKind(r->unboxed, i) == 0) f(r->values[i].p);
            break;
        }
        case Tag_DynRecord: {
            DynRecord* dr = static_cast<DynRecord*>(obj);
            f(dr->fieldgroup);
            for (u32 i = 0; i < hdr->size; i++) f(dr->values[i]);
            break;
        }
        case Tag_Closure: {
            Closure* cl = static_cast<Closure*>(obj);   // APPLIED slots only
            for (u32 i = 0; i < cl->n_values; i++)
                if (fieldKind(cl->unboxed, i) == 0) f(cl->values[i].p);
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

// Tags with at least one potential child slot (the drain pushes only these).
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
