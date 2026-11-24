//===- SeqDictTrieExports.cpp - C-linkage exports for eco/system's SeqDictTrie ===//
//
// `SeqDictTrie.remap flat probe root` copies the hash trie `root` of a SeqDict (KERN_009,
// system-kernel-cpp/src/SeqDict.elm) with every entry replaced by the entry at its order index in `flat`,
// a `JsArray2 (Maybe (Entry k b))`. `SeqDict.map` builds the new entries in insertion order in Elm (so
// `f` runs once per entry, in that order) and calls this to copy the trie, so that the trie and the
// order array share the new entries without a closure call per slot.
//
// The kernel pins no representation (it is `Transparent` in Compiler.IR.Kernel.Visibility):
//   - a slot it reads may be a tagged word (`Slot` tagged, MONO_035: `Data` the entry's word with
//     index 0, `Sub` the node's word with index 1) or a one-field Custom (`Data` ctor 0, `Sub` ctor 1),
//     as core/SeqDict.hpp's validator reads it;
//   - a slot it builds takes the form of `probe`, a `Sub` slot of the result's type built by compiled
//     code, since the representation passes choose per instantiation;
//   - a `flat` element is the entry itself (`Maybe` nullable, MONO_033) or a `Just` Custom holding it.
// Nodes (`Branch` ctor 0, `Collision` ctor 1, two fields each) keep their constructor, slot kinds and
// first field.
//
// It builds bottom up: a node's children first, held in a rooted buffer of untagged words, then its
// slot array and the node, each filled right after its allocation (no write after a collection, P1).
// Tag bits are added only when a word is stored into the new slot array.
//
//===----------------------------------------------------------------------===//

#include "ExportHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RootedSlots.hpp"
#include "allocator/RuntimeExports.h"

#include <cstdint>
#include <cstdlib>
#include <cstdio>

using namespace Elm;
namespace Export = Elm::Kernel::Export;

namespace {

constexpr u16 kSub = 1;       // Slot's Sub, and Node's Collision
constexpr u16 kCollision = 1;

// A node's children, at most 32: a stack buffer held by one root-range record, as RootedSlots holds a
// vector (no heap allocation per node).
class ChildRoots {
public:
    ChildRoots() : saved_(ecoRootRangePoint()) {
        rec_ = eco_tl_root_sp;
        ecoRootRangePush(slots_, 0, ~uint64_t{0});
    }
    ~ChildRoots() { ecoRootRangeRestore(saved_); }
    ChildRoots(const ChildRoots&) = delete;
    ChildRoots& operator=(const ChildRoots&) = delete;

    void push(HPointer hp) {
        slots_[n_++] = hp;
        rec_->count = n_;
    }
    HPointer& operator[](u32 i) { return slots_[i]; }

private:
    HPointer slots_[32];
    u32 n_ = 0;
    StackRootRangeRec* rec_;
    size_t saved_;
};

struct Remap {
    HPointer& flat;    // the caller's rooted handle, current after every collection
    bool tagged;       // the result's Slot is a tagged union
    u32 subTag;        // the tag of a tagged Sub word

    // resolveFast reads the address from the low 43 bits, so a tagged word needs no masking.
    static Custom* res(HPointer hp) { return static_cast<Custom*>(Allocator::resolveFast(hp)); }

    static i64 readInt(const Custom* c, u32 i) {
        if (customSlotKind(c, i) == 1) return c->values[i].i;
        return static_cast<ElmInt*>(Allocator::resolveFast(c->values[i].p))->value;
    }

    // The new entry for the old entry `e`: element `index` of `flat`, unwrapped from a `Just` Custom.
    // Allocates nothing.
    HPointer newEntry(const Custom* e) const {
        i64 idx = readInt(e, 1);
        auto* arr = static_cast<ElmArray*>(Allocator::resolveFast(flat));
        if (idx < 0 || static_cast<u64>(idx) >= arr->length) {
            std::fprintf(stderr, "SeqDictTrie.remap: entry index %lld outside the order array\n", static_cast<long long>(idx));
            std::abort();
        }
        HPointer w = arr->elements[idx].p;
        Custom* obj = alloc::isConstant(w) ? nullptr : res(w);
        if (!obj || obj->header.tag != Tag_Custom) {
            std::fprintf(stderr, "SeqDictTrie.remap: no new entry at index %lld\n", static_cast<long long>(idx));
            std::abort();
        }
        if (obj->header.size == 1) w = obj->values[0].p;
        return w;
    }

    // Reads the slot word `w`: puts its untagged target in `out` and returns whether it is a Sub.
    static bool readSlot(HPointer w, HPointer& out) {
        u64 bits = hpBits(w);
        if (wordTag(bits) != 0) {
            out = hpFromBits(bits & ~WORD_TAG_MASK);
            return true;
        }
        auto* obj = res(w);
        if (obj->header.size == 1) {  // a boxed Slot
            out = obj->values[0].p;
            return obj->ctor == kSub;
        }
        out = w;
        return obj->header.size == 2;  // a bare node word (tag 0 cannot be a Sub); else an entry
    }

    // A copy of the node `node` (untagged, rooted here). A GC point.
    HPointer node(HPointer node) {
        StackRootGuard guardNode(&node);
        Custom* n = res(node);
        return n->ctor == kCollision ? collision(node) : branch(node);
    }

    HPointer collision(HPointer& node) {
        // the new entries, in list order
        alloc::RootedSlots entries(4);
        for (alloc::ListCursor c(res(node)->values[1].p); !c.done(); c.next()) {
            entries.push(newEntry(res(c.current().p)));
        }
        HPointer list = alloc::listNil();
        StackRootGuard guardList(&list);
        for (size_t i = entries.size(); i-- > 0;) {
            list = alloc::cons(alloc::boxed(entries[i]), list, static_cast<u8>(0));
        }
        return finishNode(node, list);
    }

    HPointer branch(HPointer& node) {
        // the children (untagged words) and whether each is a Sub
        ChildRoots kids;
        u32 subs = 0;
        u32 len = static_cast<ElmArray*>(Allocator::resolveFast(res(node)->values[1].p))->length;
        for (u32 i = 0; i < len; ++i) {
            // re-read the old slot each time: building a child may move it
            auto* arr = static_cast<ElmArray*>(Allocator::resolveFast(res(node)->values[1].p));
            HPointer target;
            if (readSlot(arr->elements[i].p, target)) {
                subs |= 1u << i;
                kids.push(this->node(target));
            } else {
                kids.push(newEntry(res(target)));
            }
        }
        if (!tagged) {  // each child into its one-field Slot Custom
            for (u32 i = 0; i < len; ++i) {
                HPtr wrap = eco_alloc_custom((subs >> i) & 1u ? kSub : 0, 1);
                auto* w = static_cast<Custom*>(Allocator::resolveFast(Export::decode(wrap.toBits())));
                w->values[0].p = kids[i];
                kids[i] = Allocator::instance().wrap(w);
            }
        }
        HPointer slots = alloc::allocArray(len);
        auto* arr = static_cast<ElmArray*>(Allocator::resolveFast(slots));
        for (u32 i = 0; i < len; ++i) {
            HPointer w = kids[i];
            if (tagged && ((subs >> i) & 1u)) w = hpFromBits(hpBits(w) | (static_cast<u64>(subTag) << 43));
            arr->elements[i].p = w;
        }
        arr->length = len;
        arr->header.unboxed = 0;
        return finishNode(node, slots);
    }

    // A node of `old`'s constructor, slot kinds and first field, with `second` as its second field.
    static HPointer finishNode(HPointer& old, HPointer second) {
        StackRootGuard guard(&second);
        HPtr made = eco_alloc_custom(res(old)->ctor, 2);
        auto* n = static_cast<Custom*>(Allocator::resolveFast(Export::decode(made.toBits())));
        const Custom* o = res(old);
        n->unboxed = o->unboxed;
        n->values[0] = o->values[0];
        n->values[1].p = second;
        return Allocator::instance().wrap(n);
    }
};

} // namespace

extern "C" HPtr Eco_Kernel_SeqDictTrie_remap(HPtr flat, HPtr probe, HPtr root) {
    HPointer flatHP = Export::decode(flat.toBits());
    HPointer rootHP = Export::decode(root.toBits());
    StackRootGuard guard(&flatHP, &rootHP);
    u64 probeBits = hpBits(Export::decode(probe.toBits()));
    Remap r{flatHP, wordTag(probeBits) != 0, wordTag(probeBits)};
    HPointer result = r.node(rootHP);
    return HPtr::fromBits(Export::encode(result));
}
