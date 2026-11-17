//===- FNVExports.cpp - C-linkage export for eco/containers' FNV.hash -----===//
//
// `FNV.hash : a -> Int` is the hash SeqDict and SeqSet key their trie on. It must give equal hashes for
// any two values `==` (elm/core's `Utils.equal`) finds equal; unequal values may collide, since SeqDict
// resolves a collision with `==`. Its result is in [0, 2^32), because SeqDict reads it 5 bits at a time
// from bit 0 to bit 34.
//
// It is FNV-1a over 32-bit words of the value's content, finished with MurmurHash3's fmix32 so that the low
// bits, which pick the first trie level, depend on every word. The walk follows content, never
// representation, so that equal values hash alike whatever form they are stored in:
//   - Int, Float and Char hash their value, whether boxed or unboxed in their container;
//   - a String hashes its UTF-16 units, whatever its form (leaf, slice, rope, UTF-8 view, large), and the
//     Empty constant hashes as the String "" does, since `==` finds them equal;
//   - a list hashes its elements, whatever mix of cells and chunk views its spine is;
//   - a Dict hashes its key-value pairs in key order, as `==` compares Dicts by content, not tree shape;
//   - a SeqDict hashes its key-value pairs in insertion order, as `==` compares them (core/SeqDict.hpp).
//
// The walk is bounded so that a hash costs O(1) for a large key: at most `kMaxDepth` levels of nesting,
// `kMaxItems` list elements, Dict entries and fields in all, and `kMaxUnits` units of each String (its
// length is hashed too). The bounds count content only, so they cut equal values at the same place. The
// walk allocates nothing, so no collection can run and no object moves while it runs.
//
//===----------------------------------------------------------------------===//

#include "KernelExports.h"
#include "ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/StringOps.hpp"
#include "core/SeqDict.hpp"

using namespace Elm;
using namespace Elm::Kernel;

namespace {

/// The constructor tag of `Dict.RBNode_elm_builtin`, as in elm-kernel-cpp's Utils.cpp.
constexpr u16 kCtorDictNode = 0xFFFF;

constexpr int kMaxDepth = 16;
constexpr int kMaxItems = 256;
constexpr i64 kMaxUnits = 4096;

// Markers mixed in before a value of each kind, so that, for example, a Char and a one-unit String differ.
enum Marker : u32 {
    kInt = 1, kFloat, kChar, kString, kEmpty, kConst, kTuple, kList, kListEnd, kCustom, kRecord,
    kArray, kDict, kSeqDict, kOther
};

struct Hasher {
    u32 h = 2166136261u;
    int items = kMaxItems;

    void mix(u32 x) { h = (h ^ x) * 16777619u; }
    void mix64(u64 x) { mix(static_cast<u32>(x)); mix(static_cast<u32>(x >> 32)); }

    // Hashes `slot`, a field of kind `kind` (0 boxed, 1 Int, 2 Float, 3 Char), at nesting `depth`.
    void slot(Unboxable s, u32 kind, int depth) {
        switch (kind) {
            case 1: mix(kInt); mix64(static_cast<u64>(s.i)); return;
            case 2: floatValue(s.f); return;
            case 3: mix(kChar); mix(s.c); return;
            default: boxed(s.p, depth); return;
        }
    }

    void floatValue(f64 f) {
        mix(kFloat);
        if (f == 0.0) f = 0.0; // -0.0 == 0.0
        u64 bits;
        memcpy(&bits, &f, 8);
        mix64(bits);
    }

    void string(void* s) {
        i64 n = StringOps::length(s);
        if (n == 0) { mix(kEmpty); return; }
        mix(kString);
        mix64(static_cast<u64>(n));
        if (StringOps::isUtf8(s)) {
            // A UTF-8 form holds only ASCII, so each byte is one UTF-16 unit.
            auto pr = StringOps::utf8Bytes(s);
            for (u32 i = 0; i < pr.second && i < kMaxUnits; ++i) mix(pr.first[i]);
            return;
        }
        for (i64 i = 0; i < n && i < kMaxUnits; ++i) mix(StringOps::charAt(s, i));
    }

    // Hashes the entries of the Dict tree at `p` in key order: left subtree, key, value, right subtree.
    void dict(HPointer p, int depth) {
        while (items > 0 && !alloc::isConstant(p)) {
            auto* n = static_cast<Custom*>(Allocator::instance().resolve(p));
            dict(n->values[3].p, depth);
            if (items <= 0) return;
            items--;
            slot(n->values[1], customSlotKind(n, 1), depth + 1);
            slot(n->values[2], customSlotKind(n, 2), depth + 1);
            p = n->values[4].p;
        }
    }

    void boxed(HPointer p, int depth) {
        if (alloc::isConstant(p)) {
            if (alloc::isEmptyString(p)) { mix(kEmpty); return; }
            u64 bits;
            memcpy(&bits, &p, 8);
            mix(kConst);
            mix64(bits);
            return;
        }
        void* o = Allocator::instance().resolve(p);
        if (alloc::isString(o)) { string(o); return; }
        Header* hdr = static_cast<Header*>(o);
        switch (hdr->tag) {
            case Tag_Int: mix(kInt); mix64(static_cast<u64>(static_cast<ElmInt*>(o)->value)); return;
            case Tag_Float: floatValue(static_cast<ElmFloat*>(o)->value); return;
            case Tag_Char: mix(kChar); mix(static_cast<ElmChar*>(o)->value); return;
            default: break;
        }
        if (depth >= kMaxDepth || items <= 0) return;
        switch (hdr->tag) {
            case Tag_Tuple2: {
                auto* t = static_cast<Tuple2*>(o);
                mix(kTuple);
                slot(t->a, tupleFieldKind(hdr->unboxed, 0), depth + 1);
                slot(t->b, tupleFieldKind(hdr->unboxed, 1), depth + 1);
                return;
            }
            case Tag_Tuple3: {
                auto* t = static_cast<Tuple3*>(o);
                mix(kTuple);
                slot(t->a, tupleFieldKind(hdr->unboxed, 0), depth + 1);
                slot(t->b, tupleFieldKind(hdr->unboxed, 1), depth + 1);
                slot(t->c, tupleFieldKind(hdr->unboxed, 2), depth + 1);
                return;
            }
            case Tag_Cons:
            case Tag_ConsChunk: {
                mix(kList);
                for (alloc::ListCursor c(p); !c.done() && items > 0; c.next()) {
                    items--;
                    slot(c.current(), c.currentKind(), depth + 1);
                }
                mix(kListEnd);
                return;
            }
            case Tag_Custom: {
                auto* c = static_cast<Custom*>(o);
                if (c->ctor == kCtorDictNode) {
                    mix(kDict);
                    dict(p, depth);
                    return;
                }
                if (c->ctor == CTOR_SEQDICT) {
                    mix(kSeqDict);
                    forEachSeqDictEntry(c, [this, depth](Unboxable k, u32 kk, Unboxable v, u32 vk) {
                        if (items <= 0) return false;
                        items--;
                        slot(k, kk, depth + 1);
                        slot(v, vk, depth + 1);
                        return true;
                    });
                    return;
                }
                mix(kCustom);
                mix(static_cast<u32>(c->ctor));
                for (u32 i = 0; i < hdr->size && items > 0; ++i, --items) {
                    slot(c->values[i], customSlotKind(c, i), depth + 1);
                }
                return;
            }
            case Tag_Record: {
                auto* r = static_cast<Record*>(o);
                mix(kRecord);
                for (u32 i = 0; i < hdr->size && items > 0; ++i, --items) {
                    slot(r->values[i], recordSlotKind(r, i), depth + 1);
                }
                return;
            }
            case Tag_Array: {
                auto* a = static_cast<ElmArray*>(o);
                u32 kind = hdr->unboxed & 0x3;
                mix(kArray);
                for (u32 i = 0; i < a->length && items > 0; ++i, --items) {
                    slot(a->elements[i], kind, depth + 1);
                }
                return;
            }
            default:
                // Bytes, closures and the like: `==` does not compare them by content, or not at all.
                mix(kOther);
                mix(hdr->tag);
                return;
        }
    }
};

// MurmurHash3's finalizer: spreads every input bit over every output bit.
u32 fmix32(u32 h) {
    h ^= h >> 16;
    h *= 0x85ebca6bu;
    h ^= h >> 13;
    h *= 0xc2b2ae35u;
    h ^= h >> 16;
    return h;
}

} // namespace

extern "C" int64_t Elm_Kernel_FNV_hash(HPtr value) {
    Hasher hasher;
    hasher.boxed(Export::decode(value.toBits()), 0);
    return static_cast<int64_t>(fmix32(hasher.h));
}
