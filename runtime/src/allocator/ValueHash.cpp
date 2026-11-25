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
//   - a String is hashed on its own (`stringHash`: CRC32C of its UTF-16 units and its length, whatever
//     its form, definition v4) and mixed in as one word, and the Empty constant hashes as the String ""
//     does;
//   - a list hashes its elements, whatever mix of cells and chunk views its spine is;
//   - a Dict hashes its key-value pairs in key order, as `==` compares Dicts by content, not tree shape;
//   - a SeqDict hashes its key-value pairs in insertion order, as `==` compares them (SeqDictLayout.hpp).
//
// The walk is bounded so that a hash costs O(1) in the size of a large structure: at most `kMaxDepth`
// levels of nesting, and `kMaxItems` list elements, Dict entries and fields in all. Every String is
// hashed whole (definition v4), so a String costs time linear in its length, as `==` on it does. The
// bounds count content only, so they cut equal values at the same place. The
// walk allocates nothing, so no collection can run and no object moves while it runs.
//
//===----------------------------------------------------------------------===//

#include "ValueHash.hpp"

#include "Allocator.hpp"
#include "Crc32c.hpp"
#include "HeapHelpers.hpp"
#include "SeqDictLayout.hpp"
#include "StringOps.hpp"

#include "PermanentSpace.hpp"
#include "ThreadLocalHeap.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#if defined(_MSC_VER) && !defined(__clang__)
#include <intrin.h>
#endif

using namespace Elm;

namespace {


/// The constructor tag of `Dict.RBNode_elm_builtin`, as in elm-kernel-cpp's Utils.cpp.
constexpr u16 kCtorDictNode = 0xFFFF;

constexpr int kMaxDepth = 16;
constexpr int kMaxItems = 256;

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

// The String's own hash, definition v4 (design_docs/theory/runtime/value-hash.md): its raw state is
// CRC32C over its UTF-16 units (a UTF-8 form's bytes are its units; Crc32c.hpp), and its hash is
// `nonZero(fmix32(raw ^ n))`, n its length. A String's hash slot (HEAP_088) holds the raw state, so
// that a String built from parts can be given its raw state from theirs (`crc32c::combine`,
// plans/hash-reuse-explicit-vs-cached.md §4.1.5), and so can a rope from its children.

u32 hashFromRaw(u32 raw, i64 n) { return nonZero(fmix32(raw ^ static_cast<u32>(n))); }

// The raw state of the String `s`, computed from its units: reads and writes no slot.
u32 rawFromUnits(void* s) {
    u32 c = crc32c::kEmpty;
    StringOps::forEachSegmentEx(
        s,
        [&](const u16* p, u32 len) { c = crc32c::update16(c, p, len); },
        [&](const u8* p, u32 len) { c = crc32c::update8(c, p, len); });
    return c;
}

// The raw state of the non-empty String `s`: its slot when filled, otherwise computed and stored in
// its slot, if it has one. A rope below the saturated height is composed from its children, each
// read, or computed and stored, the same way, so ropes that share a child never read it again; the
// height (at most kRopeHeightMax) bounds the recursion. A saturated rope is read from its units.
u32 rawFill(void* s) {
    u32* slot = stringHashSlot(s);
    if (slot) {
        const u32 v = __atomic_load_n(slot, __ATOMIC_RELAXED);
        if (v != 0) return v;
    }
    u32 v;
    if (static_cast<Header*>(s)->tag == Tag_StringRope && StringOps::heightOf(s) < kRopeHeightMax) {
        auto* r = static_cast<ElmStringRope*>(s);
        void* left = Allocator::resolveFast(r->left);
        void* right = Allocator::resolveFast(r->right);
        v = crc32c::combine(rawFill(left), rawFill(right), static_cast<u64>(StringOps::length(right)));
    } else {
        v = rawFromUnits(s);
    }
    if (slot && v != 0) __atomic_store_n(slot, v, __ATOMIC_RELAXED);
    return v;
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

Counts byForm[7], byLength[4], byAge[4], topLevel, nested, repeated, cached;
std::vector<const void*> seen;
size_t seenCount = 0;
uint64_t epoch = ~0ULL;

// Build sites (plans/hash-reuse-explicit-vs-cached.md B5c and B6's census): per site, the Strings with a hash
// slot it built, how many were given their raw state at build, the units read to do so, and how many
// of each were hashed before the next minor collection (a table of the built objects' addresses,
// cleared with the epoch, as `seen`): a lower bound on how many builds a given hash serves.
const char* const kSites[] = {"append", "concat", "join", "rope", "cons", "propagate"};
struct SiteCounts {
    uint64_t built = 0, given = 0, unitsHashed = 0, hashedLater = 0, hashedLaterGiven = 0;
};
SiteCounts sites[Elm::kBuildSiteCount];
struct Built {
    const void* obj;
    uint8_t site;
    bool given;
    bool counted;
};
std::vector<Built> built;
size_t builtCount = 0;
uint64_t builtEpoch = ~0ULL;

size_t builtIndex(const void* s, bool insert) {
    uint64_t now = Allocator::instance().getCurrentThreadHeap()->getNursery().minorSeq();
    if (now != builtEpoch || built.empty()) {
        builtEpoch = now;
        built.assign(1u << 20, Built{nullptr, 0, false, false});
        builtCount = 0;
    }
    size_t mask = built.size() - 1;
    size_t i = (reinterpret_cast<uintptr_t>(s) >> 3) * 0x9E3779B97F4A7C15ULL >> 40 & mask;
    while (built[i].obj != nullptr) {
        if (built[i].obj == s) return i;
        i = (i + 1) & mask;
    }
    if (!insert || builtCount * 2 >= built.size()) return SIZE_MAX;
    built[i].obj = s;
    builtCount++;
    return i;
}

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
    row("served by hash slot", cached);
    std::fprintf(stderr, "  build site     %10s %10s %14s %12s %12s\n", "built", "given", "units read", "hashed",
                 "hashed+given");
    for (int i = 0; i < Elm::kBuildSiteCount; ++i) {
        const SiteCounts& c = sites[i];
        if (!c.built) continue;
        std::fprintf(stderr, "  %-14s %10llu %10llu %14llu %12llu %12llu\n", kSites[i],
                     static_cast<unsigned long long>(c.built), static_cast<unsigned long long>(c.given),
                     static_cast<unsigned long long>(c.unitsHashed), static_cast<unsigned long long>(c.hashedLater),
                     static_cast<unsigned long long>(c.hashedLaterGiven));
    }
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

// Prints the census at exit, from the first String hashed or built.
void registerPrint() {
    static bool registered = false;
    if (!registered) {
        registered = true;
        std::atexit(print);
    }
}

void note(void* s, int64_t n, bool top) {
    registerPrint();
    uint64_t units = static_cast<uint64_t>(n);
    add(byForm[formOf(s)], units);
    add(byLength[n < 32 ? 0 : n < 256 ? 1 : n < 4096 ? 2 : 3], units);
    int age;
    if (Allocator::instance().isInNursery(s)) age = static_cast<Header*>(s)->age == 0 ? 0 : 1;
    else if (PermanentSpace::instance().contains(s)) age = 3;
    else age = 2;
    add(byAge[age], units);
    add(top ? topLevel : nested, units);
    if (seenBefore(s)) add(repeated, units);
    const size_t b = builtIndex(s, false);
    if (b != SIZE_MAX && !built[b].counted) {
        built[b].counted = true;
        sites[built[b].site].hashedLater++;
        if (built[b].given) sites[built[b].site].hashedLaterGiven++;
    }
}

// Counts a hash of the String `s` (`n` units) that its hash slot answered.
void noteCached(int64_t n) { add(cached, static_cast<uint64_t>(n)); }

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
    //
    // The raw state comes from the String's hash slot when it is filled, and is otherwise computed and
    // stored there (`rawFill`, HEAP_088). The store may land in an object that has survived a collection,
    // or in PermanentSpace: the carve-out HEAP_088 makes from HEAP_SNAPSHOT_001 and HEAP_036. The value
    // depends only on the units, so every writer writes the same number, and a store a concurrent tenure
    // copy misses only costs a recomputation.
    void string(void* s, bool top = false) {
        i64 n = StringOps::length(s);
        if (n == 0) { mix(kEmpty); return; }
        if (census::enabled()) census::note(s, n, top);
        u32* slot = stringHashSlot(s);
        u32 raw = slot ? __atomic_load_n(slot, __ATOMIC_RELAXED) : 0;
        if (raw != 0) {
            if (census::enabled()) census::noteCached(n);
        } else {
            raw = rawFill(s);
        }
        mix(kString);
        mix(hashFromRaw(raw, n));
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

uint32_t Elm::stringHashUncached(void* s) {
    return hashFromRaw(rawFromUnits(s), StringOps::length(s));
}

uint32_t Elm::stringRawUncached(void* s) { return rawFromUnits(s); }

uint32_t Elm::stringRaw(void* s) { return rawFill(s); }

bool Elm::hashCensusEnabled() { return census::enabled(); }

void Elm::hashCensusNoteBuilt(void* obj, int site, bool given, uint64_t unitsHashed) {
    census::registerPrint();
    census::SiteCounts& c = census::sites[site];
    c.built++;
    if (given) c.given++;
    c.unitsHashed += unitsHashed;
    const size_t i = census::builtIndex(obj, true);
    if (i != SIZE_MAX) {
        census::built[i].site = static_cast<uint8_t>(site);
        census::built[i].given = given;
        census::built[i].counted = false;
    }
}

const char* Elm::checkStringHashSlot(void* obj) {
    u32* slot = stringHashSlot(obj);
    if (slot == nullptr) return nullptr;
    const u32 tag = static_cast<Header*>(obj)->tag;
    if ((tag == Tag_String || tag == Tag_StringUtf8Leaf) && slot[1] != 0)
        return "the high half of a flat String's hash slot word is not 0 (an allocation left it unwritten)";
    const u32 v = __atomic_load_n(slot, __ATOMIC_RELAXED);
    if (v == 0) return nullptr;
    if (tag == Tag_LargeStringHeader && largeBodyAddr(static_cast<LargeStringHeader*>(obj)) == nullptr)
        return "a large String header without a body has a filled hash slot";
    if (v != rawFromUnits(obj))
        return "a String's hash slot holds a number that is not the raw CRC32C of its units";
    return nullptr;
}

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

extern "C" int64_t eco_hash_walk(int64_t h, int64_t items, HPtr value, int64_t depth) {
    Hasher hasher;
    hasher.h = static_cast<u32>(h);
    hasher.items = static_cast<int>(items);
    hasher.boxed(value.toHPointer(), static_cast<int>(depth));
    return (static_cast<int64_t>(hasher.items) << 32) | static_cast<int64_t>(hasher.h);
}
