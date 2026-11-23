//===- SeqDictLayout.hpp - Reading an eco/system SeqDict's entries --------===//
//
// `eco/system`'s `SeqDict` (system-kernel-cpp/src/SeqDict.elm, plans/seq-data-structures-performance.md §4)
// is `SeqDict_elm_builtin root order`: a hash trie and the record `{ size : Int, array : Array (Maybe
// (Entry k v)) }`, whose array holds every entry in insertion order (a removed entry leaves `Nothing`).
// An entry is `Entry hash index key value`, one Custom of four fields shared by the trie and the order
// array. `==` (elm-kernel-cpp core/Utils.cpp) and the value hash (ValueHash.cpp) read a SeqDict's
// entries in insertion order through `forEachSeqDictEntry`; elm-kernel-cpp's core/SeqDict.hpp adds the
// structural validator.
//
// The compiler gives `SeqDict_elm_builtin` the reserved constructor tag `CTOR_SEQDICT`, which must equal
// `Compiler.IR.Runtime.CtorTag.seqDict`. An `Array` is elm/core's `Array_elm_builtin length startShift
// tree tail`, whose tree is a `JsArray` (an `ElmArray`) of `SubTree (JsArray node)` and `Leaf (JsArray
// element)` nodes, elements in order from the leftmost leaf, then the tail.
//
// The compiler chooses the representation of `Maybe (Entry k v)`: a `Just` Custom of one field holding
// the entry, or, when it makes the type nullable (MONO_033), the entry itself. Kernel visibility does not
// protect it, since its values sit behind `JsArray`'s type-variable element field, which the declared
// closure does not follow (MONO_032); so the walk reads both forms, told apart by their field counts
// (an `Entry` has four, a `Just` one).
//
// The walk allocates nothing, so no collection can run, and no object moves, while it runs.
//
//===----------------------------------------------------------------------===//

#pragma once

#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"

#include <cassert>

namespace Elm {

/// The constructor tag the compiler gives `SeqDict.SeqDict_elm_builtin` in eco/system.
constexpr u16 CTOR_SEQDICT = 0xFFFB;

namespace SeqDictDetail {

/// The constructor index of elm/core's `Array.SubTree`; `Leaf` is the other one.
constexpr u16 kArraySubTree = 0;

/// The `Entry` held by an order-array element that is not `Nothing`: the element itself (a nullable
/// `Just`) or the one field of a `Just` Custom. Null when it is neither.
inline Custom* entryOf(HPointer elem) {
    auto& allocator = Allocator::instance();
    auto* obj = static_cast<Custom*>(allocator.resolve(elem));
    if (obj->header.tag != Tag_Custom) return nullptr;
    if (obj->header.size == 1) obj = static_cast<Custom*>(allocator.resolve(obj->values[0].p));
    if (obj->header.tag != Tag_Custom || obj->header.size != 4) return nullptr;
    return obj;
}

/// Calls `f` on each `Entry` of the `ElmArray` at `hp`, in order, skipping `Nothing`s. Returns false as
/// soon as `f` does.
template <typename F>
bool eachEntryIn(HPointer hp, F& f) {
    if (alloc::isConstant(hp)) return true;
    auto* arr = static_cast<ElmArray*>(Allocator::instance().resolve(hp));
    for (u32 i = 0; i < arr->length; ++i) {
        HPointer elem = arr->elements[i].p; // `Maybe` elements are boxed.
        if (alloc::isConstant(elem)) continue; // Nothing: a removed entry.
        Custom* e = entryOf(elem);
        assert(e != nullptr && "SeqDict order element is not an Entry");
        if (!f(e->values[2], customSlotKind(e, 2), e->values[3], customSlotKind(e, 3))) return false;
    }
    return true;
}

/// Walks the Array tree nodes in the `ElmArray` at `hp`, in order.
template <typename F>
bool eachEntryInTree(HPointer hp, F& f) {
    if (alloc::isConstant(hp)) return true;
    auto* nodes = static_cast<ElmArray*>(Allocator::instance().resolve(hp));
    for (u32 i = 0; i < nodes->length; ++i) {
        auto* node = static_cast<Custom*>(Allocator::instance().resolve(nodes->elements[i].p));
        bool ok = node->ctor == kArraySubTree ? eachEntryInTree(node->values[0].p, f)
                                              : eachEntryIn(node->values[0].p, f);
        if (!ok) return false;
    }
    return true;
}

/// The order record's `Array` (the field that is a heap Custom; `size` is an Int, unboxed or boxed).
inline Custom* orderArray(Custom* seqDict) {
    auto& allocator = Allocator::instance();
    auto* order = static_cast<Record*>(allocator.resolve(seqDict->values[1].p));
    Custom* array = nullptr;
    for (u32 i = 0; i < order->header.size; ++i) {
        if (recordSlotKind(order, i) != 0 || alloc::isConstant(order->values[i].p)) continue;
        void* o = allocator.resolve(order->values[i].p);
        if (static_cast<Header*>(o)->tag == Tag_Custom) array = static_cast<Custom*>(o);
    }
    return array;
}

} // namespace SeqDictDetail

/// Calls `f(key, keyKind, value, valueKind)` on each entry of the SeqDict `seqDict` (a `Custom` whose ctor is
/// `CTOR_SEQDICT`) in insertion order, where a kind is 0 for a boxed slot and 1, 2 or 3 for an unboxed
/// Int, Float or Char. Stops as soon as `f` returns false, and returns whether it never did.
template <typename F>
bool forEachSeqDictEntry(Custom* seqDict, F f) {
    Custom* array = SeqDictDetail::orderArray(seqDict);
    if (array == nullptr) return true;
    return SeqDictDetail::eachEntryInTree(array->values[2].p, f) &&
           SeqDictDetail::eachEntryIn(array->values[3].p, f);
}

} // namespace Elm
