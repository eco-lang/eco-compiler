//===- SeqDict.hpp - Walking and checking an eco/system SeqDict -----------===//
//
// The layout and the entry walk `forEachSeqDictEntry` live in the runtime
// (runtime/src/allocator/SeqDictLayout.hpp), which the value hash shares. This header adds the
// structural validator, which Utils.cpp runs when ECO_SEQDICT_VALIDATE=1.
//
//===----------------------------------------------------------------------===//

#pragma once

#include "allocator/Allocator.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/SeqDictLayout.hpp"

#include <bit>
#include <string>
#include <vector>

namespace Elm::Kernel {

// ===== Structural validator =====================================================================
//
// `validateSeqDict` checks the invariants of plans/seq-data-structures-performance.md §4.2: O1 (every
// order slot is `Nothing` or an entry whose index is the slot's), O2 (the trie reaches exactly the live
// entries, each the very object in its order slot), T1 (bitmaps agree with their slot arrays, every
// entry sits under its hash's chunks), T2 (no branch below the root holds no slot, one `Data`, or one
// collision) and T3 (a collision holds 2+ entries of its hash in ascending index order). It reads every
// word by its heap tag, its word tag bits and its slot kinds, so it pins no representation of `Node`,
// `Slot`, `Entry` or `Maybe`. Utils.cpp runs it on both operands of `==` when ECO_SEQDICT_VALIDATE=1.

namespace SeqDictValidate {

inline void* res(HPointer p) { return Allocator::instance().resolve(p); }

/// Reads an Int held in a slot of kind `kind`: unboxed, or a boxed `ElmInt`.
inline bool readInt(Unboxable s, u32 kind, i64& out) {
    if (kind == 1) { out = s.i; return true; }
    if (kind != 0 || alloc::isConstant(s.p)) return false;
    auto* o = static_cast<Header*>(res(s.p));
    if (o->tag != Tag_Int) return false;
    out = reinterpret_cast<ElmInt*>(o)->value;
    return true;
}

inline bool entryFields(Custom* e, i64& hash, i64& index) {
    return readInt(e->values[0], customSlotKind(e, 0), hash) && readInt(e->values[1], customSlotKind(e, 1), index);
}

struct State {
    std::vector<Custom*> entryAt; // the entry in each order slot, or null for Nothing
    std::vector<bool> seen;       // whether the trie reached the slot
    size_t reached = 0;
    std::string* why = nullptr;
    bool fail(const std::string& m) { if (why) *why = m; return false; }
};

template <typename F> void eachSlotIn(HPointer hp, F& f) {
    if (alloc::isConstant(hp)) return;
    auto* arr = static_cast<ElmArray*>(res(hp));
    for (u32 i = 0; i < arr->length; ++i) f(arr->elements[i].p);
}

template <typename F> void eachSlotInTree(HPointer hp, F& f) {
    if (alloc::isConstant(hp)) return;
    auto* nodes = static_cast<ElmArray*>(res(hp));
    for (u32 i = 0; i < nodes->length; ++i) {
        auto* node = static_cast<Custom*>(res(nodes->elements[i].p));
        if (node->ctor == SeqDictDetail::kArraySubTree) eachSlotInTree(node->values[0].p, f);
        else eachSlotIn(node->values[0].p, f);
    }
}

/// Checks that `e` is the live entry of its order slot, with hash `hash`, under the path bits `prefix`
/// of the `bits` hash bits consumed so far.
inline bool checkEntry(State& st, Custom* e, u32 bits, u32 prefix) {
    i64 hash, idx;
    if (!entryFields(e, hash, idx)) return st.fail("unreadable trie entry");
    if (idx < 0 || static_cast<size_t>(idx) >= st.entryAt.size()) return st.fail("trie entry index out of range (O2)");
    if (st.entryAt[idx] != e) return st.fail("trie entry is not the object in its order slot (O2)");
    if (st.seen[idx]) return st.fail("order slot reached twice from the trie (O2)");
    u32 low = bits >= 32 ? 0xFFFFFFFFu : ((1u << bits) - 1u);
    if ((static_cast<u32>(hash) & low) != prefix) return st.fail("trie entry under the wrong path (T1)");
    st.seen[idx] = true;
    st.reached++;
    return true;
}

/// A `Slot` word: tagged (index 1 in bits 43-52 is `Sub`, 0 is `Data`) or a boxed one-field Custom
/// (ctor 0 `Data`, 1 `Sub`). Sets `isSub` and returns the entry or node object.
inline Custom* readSlot(HPointer word, bool& isSub) {
    u64 bits = hpBits(word);
    u32 tag = wordTag(bits);
    auto* obj = static_cast<Custom*>(res(hpFromBits(bits & ~WORD_TAG_MASK)));
    if (tag != 0) { isSub = true; return obj; }
    if (obj->header.tag == Tag_Custom && obj->header.size == 1) {
        isSub = obj->ctor == 1;
        return static_cast<Custom*>(res(obj->values[0].p));
    }
    isSub = obj->header.tag == Tag_Custom && obj->header.size == 2; // an untagged node pointer
    return obj;
}

inline bool checkNode(State& st, Custom* node, u32 shift, u32 prefix, bool isRoot);

inline bool checkCollision(State& st, Custom* node, u32 bits, u32 prefix) {
    i64 h, prevIdx = -1;
    if (!readInt(node->values[0], customSlotKind(node, 0), h)) return st.fail("unreadable Collision");
    u32 n = 0;
    for (alloc::ListCursor c(node->values[1].p); !c.done(); c.next(), ++n) {
        auto* e = static_cast<Custom*>(res(c.current().p));
        i64 eh, ei;
        if (!entryFields(e, eh, ei)) return st.fail("unreadable Collision entry");
        if (eh != h) return st.fail("Collision entry with another hash (T3)");
        if (ei <= prevIdx) return st.fail("Collision entries out of index order (T3)");
        prevIdx = ei;
        if (!checkEntry(st, e, bits, prefix)) return false;
    }
    if (n < 2) return st.fail("Collision with fewer than 2 entries (T3)");
    return true;
}

inline bool checkNode(State& st, Custom* node, u32 shift, u32 prefix, bool isRoot) {
    if (node->header.tag != Tag_Custom || node->header.size != 2) return st.fail("trie node is not a two-field Custom");
    if (node->ctor == 1) return checkCollision(st, node, shift, prefix);
    if (shift > 30) return st.fail("branch deeper than the hash (T1)");
    i64 bitmap;
    if (!readInt(node->values[0], customSlotKind(node, 0), bitmap)) return st.fail("unreadable Branch bitmap");
    auto* arr = static_cast<ElmArray*>(res(node->values[1].p));
    u32 bm = static_cast<u32>(bitmap);
    if (static_cast<i64>(bm) != bitmap) return st.fail("Branch bitmap above 32 bits (T1)");
    if (static_cast<u32>(std::popcount(bm)) != arr->length) return st.fail("bitmap and slot array disagree (T1)");
    if (!isRoot) {
        if (arr->length == 0) return st.fail("empty branch below the root (T2)");
        if (arr->length == 1) {
            bool isSub;
            Custom* only = readSlot(arr->elements[0].p, isSub);
            if (!isSub || only->ctor == 1) return st.fail("branch below the root holds one entry or collision (T2)");
        }
    }
    u32 j = 0;
    for (u32 b = 0; b < 32; ++b) {
        if (!(bm & (1u << b))) continue;
        u32 path = prefix | (b << shift);
        bool isSub;
        Custom* obj = readSlot(arr->elements[j++].p, isSub);
        if (isSub) {
            if (!checkNode(st, obj, shift + 5, path, false)) return false;
        } else if (!checkEntry(st, obj, shift + 5, path)) {
            return false;
        }
    }
    return true;
}

} // namespace SeqDictValidate

/// Checks the structure of the SeqDict `seqDict`; on failure returns false and, when `why` is given,
/// says what is wrong.
inline bool validateSeqDict(Custom* seqDict, std::string* why) {
    using namespace SeqDictValidate;
    State st;
    st.why = why;
    if (seqDict->header.size != 2) return st.fail("SeqDict is not a two-field Custom");
    Custom* array = SeqDictDetail::orderArray(seqDict);
    if (array == nullptr) return st.fail("order record has no Array (O1)");
    auto* order = static_cast<Record*>(res(seqDict->values[1].p));
    i64 size = -1;
    for (u32 i = 0; i < order->header.size; ++i) {
        i64 n;
        if (readInt(order->values[i], recordSlotKind(order, i), n)) size = n;
    }
    bool ok = true;
    i64 live = 0;
    auto onSlot = [&](HPointer elem) {
        if (alloc::isConstant(elem)) { st.entryAt.push_back(nullptr); return; }
        Custom* e = SeqDictDetail::entryOf(elem);
        i64 h, idx;
        if (e == nullptr || !entryFields(e, h, idx) || idx != static_cast<i64>(st.entryAt.size())) ok = false;
        st.entryAt.push_back(e);
        live++;
    };
    eachSlotInTree(array->values[2].p, onSlot);
    eachSlotIn(array->values[3].p, onSlot);
    if (!ok) return st.fail("order slot holds an unreadable entry or one with another index (O1)");
    if (size != live) return st.fail("order size differs from its live slots (O1)");
    st.seen.assign(st.entryAt.size(), false);
    auto* root = static_cast<Custom*>(res(seqDict->values[0].p));
    if (root->ctor != 0) return st.fail("root is not a Branch (T2)");
    if (!checkNode(st, root, 0, 0, true)) return false;
    if (static_cast<i64>(st.reached) != live) return st.fail("trie and order array hold different entry counts (O2)");
    return true;
}

} // namespace Elm::Kernel
