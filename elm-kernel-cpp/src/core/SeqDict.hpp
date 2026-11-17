//===- SeqDict.hpp - Walking the entries of an eco/containers SeqDict -------===//
//
// `eco/containers`' `SeqDict` keeps its entries twice: in a hash trie, for lookups, and in insertion order
// in an Elm `Array (Maybe ( Int, k, v ))`, where removing an entry leaves a `Nothing`. Two SeqDicts that
// hold the same entries in the same order can differ in both (a removed entry leaves a hole in one but not
// the other), so `==` and `FNV.hash` compare and hash the entries in insertion order instead, which
// `forEachSeqDictEntry` walks.
//
// The compiler gives `SeqDict_elm_builtin` the reserved constructor tag `CTOR_SEQDICT`, which must equal
// `Compiler.IR.Runtime.CtorTag.seqDict`. Its fields are the trie's bitmap, the trie, and the record
// `{ array : Array (Maybe ( Int, k, v )), size : Int }`. An `Array` is elm/core's `Array_elm_builtin length
// startShift tree tail`, whose tree is a `JsArray` (an `ElmArray`) of `SubTree (JsArray node)` and
// `Leaf (JsArray element)` nodes, elements in order from the leftmost leaf, then the tail.
//
// The walk allocates nothing, so no collection can run, and no object moves, while it runs.
//
//===----------------------------------------------------------------------===//

#pragma once

#include "allocator/Allocator.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel {

/// The constructor tag the compiler gives `SeqDict.SeqDict_elm_builtin` in eco/containers.
constexpr u16 CTOR_SEQDICT = 0xFFFB;

namespace SeqDictDetail {

/// The constructor index of elm/core's `Array.SubTree`; `Leaf` is the other one.
constexpr u16 kArraySubTree = 0;

/// Calls `f` on each `Just ( hash, key, value )` element of the `ElmArray` at `hp`, in order. Returns false
/// as soon as `f` does.
template <typename F>
bool eachEntryIn(HPointer hp, F& f) {
    if (alloc::isConstant(hp)) return true;
    auto* arr = static_cast<ElmArray*>(Allocator::instance().resolve(hp));
    for (u32 i = 0; i < arr->length; ++i) {
        HPointer elem = arr->elements[i].p; // `Maybe` elements are boxed.
        if (alloc::isConstant(elem)) continue; // Nothing: a removed entry.
        auto* just = static_cast<Custom*>(Allocator::instance().resolve(elem));
        auto* t = static_cast<Tuple3*>(Allocator::instance().resolve(just->values[0].p));
        u32 kinds = t->header.unboxed;
        if (!f(t->b, tupleFieldKind(kinds, 1), t->c, tupleFieldKind(kinds, 2))) return false;
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

} // namespace SeqDictDetail

/// Calls `f(key, keyKind, value, valueKind)` on each entry of the SeqDict `seqDict` (a `Custom` whose ctor is
/// `CTOR_SEQDICT`) in insertion order, where a kind is 0 for a boxed slot and 1, 2 or 3 for an unboxed
/// Int, Float or Char. Stops as soon as `f` returns false, and returns whether it never did.
template <typename F>
bool forEachSeqDictEntry(Custom* seqDict, F f) {
    auto& allocator = Allocator::instance();
    auto* intDict = static_cast<Record*>(allocator.resolve(seqDict->values[2].p));
    // The record's two fields are `array` and `size`; the Array is the one that is a heap Custom (the size
    // is an Int, unboxed or boxed).
    Custom* array = nullptr;
    for (u32 i = 0; i < intDict->header.size; ++i) {
        if (recordSlotKind(intDict, i) != 0 || alloc::isConstant(intDict->values[i].p)) continue;
        void* o = allocator.resolve(intDict->values[i].p);
        if (static_cast<Header*>(o)->tag == Tag_Custom) array = static_cast<Custom*>(o);
    }
    if (array == nullptr) return true;
    return SeqDictDetail::eachEntryInTree(array->values[2].p, f) &&
           SeqDictDetail::eachEntryIn(array->values[3].p, f);
}

} // namespace Elm::Kernel
