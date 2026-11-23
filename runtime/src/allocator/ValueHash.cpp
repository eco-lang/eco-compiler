//===- ValueHash.cpp - The hash of any Elm value --------------------------===//
//
// The walker behind `eco_hash_value` (ValueHash.hpp). It must give equal hashes for any two values `==`
// (elm/core's `Utils.equal`) finds equal; unequal values may collide, since SeqDict resolves a collision
// with `==`. Its result is in [1, 2^32), because SeqDict reads it 5 bits at a time and 0 is kept free
// for "not computed".
//
// design_docs/theory/runtime/value-hash.md defines it exactly (definition v2). The walk follows
// content, never representation, so that equal values hash alike whatever form they are stored in:
//   - Int, Float and Char hash their value, whether boxed or unboxed in their container;
//   - a String is hashed on its own (`stringHash`: its length and UTF-16 units, whatever its form) and
//     mixed in as one word, and the Empty constant hashes as the String "" does;
//   - a list hashes its elements, whatever mix of cells and chunk views its spine is;
//   - a Dict hashes its key-value pairs in key order, as `==` compares Dicts by content, not tree shape;
//   - a SeqDict hashes its key-value pairs in insertion order, as `==` compares them (SeqDictLayout.hpp).
//
// The walk is bounded so that a hash costs O(1) for a large key: at most `kMaxDepth` levels of nesting,
// `kMaxItems` list elements, Dict entries and fields in all, and `kMaxUnits` units of each String (its
// length is hashed too). The bounds count content only, so they cut equal values at the same place. The
// walk allocates nothing, so no collection can run and no object moves while it runs.
//
//===----------------------------------------------------------------------===//

#include "ValueHash.hpp"

#include "Allocator.hpp"
#include "HeapHelpers.hpp"
#include "SeqDictLayout.hpp"
#include "StringOps.hpp"

#include "PermanentSpace.hpp"
#include "ThreadLocalHeap.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

using namespace Elm;

namespace {


/// The constructor tag of `Dict.RBNode_elm_builtin`, as in elm-kernel-cpp's Utils.cpp.
constexpr u16 kCtorDictNode = 0xFFFF;

constexpr int kMaxDepth = 16;
constexpr int kMaxItems = 256;
constexpr i64 kMaxUnits = 4096;

// Markers mixed in before a value of each kind, so that, for example, a Char and a one-unit String differ.
enum Marker : u32 {
    kInt = 1, kFloat, kChar, kString, kEmpty, kConst, kTuple, kList, kListEnd, kCustom, kRecord,
    kArray, kDict, kSeqDict, kOther, kTag
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

// Hash definition v2 never gives 0, so that 0 can mean "not computed" (design_docs/theory/runtime/
// value-hash.md).
u32 nonZero(u32 h) { return h == 0 ? 1u : h; }

// The String's own finished hash (definition v2): a fresh FNV-1a state over the length and the first
// `kMaxUnits` UTF-16 units, two per step (`u1 | u2 << 16`, a last odd unit alone), read a contiguous
// segment at a time (a UTF-8 form's bytes are its units), then `fmix32`, never 0. `n` is the length.
u32 stringHash(void* s, i64 n) {
    u32 x = 2166136261u;
    auto mixs = [&x](u32 v) { x = (x ^ v) * 16777619u; };
    mixs(static_cast<u32>(n));
    mixs(static_cast<u32>(static_cast<u64>(n) >> 32));
    i64 left = kMaxUnits;
    bool pending = false;
    u32 low = 0;
    auto unit = [&](u32 u) {
        if (pending) {
            mixs(low | (u << 16));
            pending = false;
        } else {
            low = u;
            pending = true;
        }
    };
    StringOps::forEachSegmentEx(
        s,
        [&](const u16* p, u32 len) {
            for (u32 i = 0; i < len && left > 0; ++i, --left) unit(p[i]);
        },
        [&](const u8* p, u32 len) {
            for (u32 i = 0; i < len && left > 0; ++i, --left) unit(p[i]);
        });
    if (pending) mixs(low);
    return nonZero(fmix32(x));
}


// ===== String hash census (ECO_HASH_CENSUS=1, plans/seq-data-structures-performance.md D4) =========
//
// Counts every non-empty String the hash reads, and the units it reads, by the String's form, its
// length, where it lives at hash time (the nursery before or after surviving a collection, the old
// generation, PermanentSpace), and whether it is the hashed value itself or nested in one. It also
// counts the hashes of a String object that was already hashed since the last minor collection (an
// open-addressing table keyed by address, cleared when the nursery's minor sequence moves on, since a
// collection moves objects): a lower bound on what a cached hash would save. Printed to stderr at exit.
// The runtime has one mutator thread, so plain counters suffice.

namespace census {

struct Counts {
    uint64_t calls = 0;
    uint64_t units = 0;
};

const char* const kForms[] = {"flat UTF-16", "UTF-8 leaf", "slice", "rope", "large", "UTF-8 view", "other"};
const char* const kLengths[] = {"< 32", "32-255", "256-4095", ">= 4096"};
const char* const kAges[] = {"nursery, age 0", "nursery, survived", "old generation", "permanent"};

Counts byForm[7], byLength[4], byAge[4], topLevel, nested, repeated;
std::vector<const void*> seen;
size_t seenCount = 0;
uint64_t epoch = ~0ULL;

bool enabled() {
    static const bool on = [] {
        const char* v = std::getenv("ECO_HASH_CENSUS");
        return v != nullptr && std::string(v) == "1";
    }();
    return on;
}

void add(Counts& c, uint64_t units) {
    c.calls++;
    c.units += units;
}

void print() {
    auto row = [](const char* label, const Counts& c) {
        std::fprintf(stderr, "  %-22s %12llu %14llu\n", label, static_cast<unsigned long long>(c.calls),
                     static_cast<unsigned long long>(c.units));
    };
    std::fprintf(stderr, "\n=== String hash census (ECO_HASH_CENSUS) ===\n  %-22s %12s %14s\n", "", "hashes", "units read");
    for (int i = 0; i < 7; ++i) row(kForms[i], byForm[i]);
    for (int i = 0; i < 4; ++i) row(kLengths[i], byLength[i]);
    for (int i = 0; i < 4; ++i) row(kAges[i], byAge[i]);
    row("top-level", topLevel);
    row("nested", nested);
    row("repeat (same object)", repeated);
}

int formOf(void* s) {
    switch (static_cast<Header*>(s)->tag) {
        case Tag_String: return 0;
        case Tag_StringUtf8Leaf: return 1;
        case Tag_StringSlice: return 2;
        case Tag_StringRope: return 3;
        case Tag_LargeStringHeader: return 4;
        case Tag_StringUtf8View: return 5;
        default: return 6;
    }
}

// Whether `s` was already hashed in this minor epoch; records it if not.
bool seenBefore(void* s) {
    uint64_t now = Allocator::instance().getCurrentThreadHeap()->getNursery().minorSeq();
    if (now != epoch || seen.empty()) {
        epoch = now;
        seen.assign(1u << 20, nullptr);
        seenCount = 0;
    }
    if (seenCount * 2 >= seen.size()) return false; // table half full: stop recording this epoch
    size_t mask = seen.size() - 1;
    size_t i = (reinterpret_cast<uintptr_t>(s) >> 3) * 0x9E3779B97F4A7C15ULL >> 40 & mask;
    while (seen[i] != nullptr) {
        if (seen[i] == s) return true;
        i = (i + 1) & mask;
    }
    seen[i] = s;
    seenCount++;
    return false;
}

void note(void* s, int64_t n, bool top) {
    static bool registered = false;
    if (!registered) {
        registered = true;
        std::atexit(print);
    }
    uint64_t units = static_cast<uint64_t>(n < kMaxUnits ? n : kMaxUnits);
    add(byForm[formOf(s)], units);
    add(byLength[n < 32 ? 0 : n < 256 ? 1 : n < 4096 ? 2 : 3], units);
    int age;
    if (Allocator::instance().isInNursery(s)) age = static_cast<Header*>(s)->age == 0 ? 0 : 1;
    else if (PermanentSpace::instance().contains(s)) age = 3;
    else age = 2;
    add(byAge[age], units);
    add(top ? topLevel : nested, units);
    if (seenBefore(s)) add(repeated, units);
}

} // namespace census

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

    // Hashes the String `s`; `top` says it is the hashed value itself rather than nested in one (for
    // the census only).
    void string(void* s, bool top = false) {
        i64 n = StringOps::length(s);
        if (n == 0) { mix(kEmpty); return; }
        if (census::enabled()) census::note(s, n, top);
        mix(kString);
        mix(stringHash(s, n));
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
        // A word's bits 43-52 (a tagged union's constructor, HEAP_086, or a null-cons or spare word's index)
        // are mixed in first, and the rest of the word is hashed without them, as `==` compares tags first
        // and then the untagged words.
        if (const u32 tag = wordTag(hpBits(p)); tag != 0) {
            mix(kTag);
            mix(tag);
            p = hpFromBits(hpBits(p) & ~WORD_TAG_MASK);
        }
        if (alloc::isConstant(p)) {
            if (alloc::isEmptyString(p)) { mix(kEmpty); return; }
            u64 bits;
            memcpy(&bits, &p, 8);
            mix(kConst);
            mix64(bits);
            return;
        }
        void* o = Allocator::instance().resolve(p);
        if (alloc::isString(o)) { string(o, depth == 0); return; }
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


u32 finish(const Hasher& h) { return nonZero(fmix32(h.h)); }

} // namespace

extern "C" int64_t eco_hash_value(HPtr value) {
    Hasher hasher;
    hasher.boxed(value.toHPointer(), 0);
    return static_cast<int64_t>(finish(hasher));
}

extern "C" int64_t eco_hash_string(HPtr value) {
    Hasher hasher;
    HPointer p = value.toHPointer();
    if (alloc::isConstant(p)) {
        hasher.boxed(p, 0); // the Empty constant
    } else {
        hasher.string(Allocator::instance().resolve(p), true);
    }
    return static_cast<int64_t>(finish(hasher));
}

extern "C" int64_t eco_hash_i64(int64_t value) {
    Hasher hasher;
    Unboxable s;
    s.i = value;
    hasher.slot(s, 1, 0);
    return static_cast<int64_t>(finish(hasher));
}

extern "C" int64_t eco_hash_f64(double value) {
    Hasher hasher;
    hasher.floatValue(value);
    return static_cast<int64_t>(finish(hasher));
}

extern "C" int64_t eco_hash_char(int32_t value) {
    Hasher hasher;
    Unboxable s;
    s.c = static_cast<u32>(value);
    hasher.slot(s, 3, 0);
    return static_cast<int64_t>(finish(hasher));
}

extern "C" int64_t eco_hash_mix_string(int64_t h, HPtr value) {
    Hasher hasher;
    hasher.h = static_cast<u32>(h);
    HPointer p = value.toHPointer();
    if (alloc::isConstant(p)) {
        hasher.boxed(p, 0); // the Empty constant: mix(kEmpty)
    } else {
        hasher.string(Allocator::instance().resolve(p));
    }
    return static_cast<int64_t>(hasher.h);
}
