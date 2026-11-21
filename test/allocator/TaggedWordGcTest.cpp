/**
 * Tagged heap words survive every collection (plans/constructor-representation-followups.md F1.1,
 * HEAP_086).
 *
 * F1 represents a value of a tagged union as a heap word with its constructor's declaration index in
 * bits 43-52 (`addr | (idx << 43)`). The address part is what `hpToAddr` already reads, so finding the
 * object is unchanged; what must hold is that every place a collector writes a word back after moving
 * its object keeps those bits, and that every root path recognizes a tagged word as a heap word.
 *
 * Each scenario holds tagged words to Strings in a root slot, a Custom field, a record field, a list
 * head, a kind-0 array element and a JIT root, with tags 1, 5, 6, 7, 9 and 1023 (the largest), runs a
 * collection, and checks that each word still names a String with the original text and still
 * carries its tag. The collections: the serial and the parallel legacy minor, the region minor
 * repeated until the objects are tenured, a major collection, and promotion of a CAF value into
 * permanent space.
 */

#include "TaggedWordGcTest.hpp"

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "NurserySpace.hpp"
#include "StringOps.hpp"
#include "TestHelpers.hpp"
#include "../../elm-kernel-cpp/src/KernelExports.h"

extern "C" std::uint64_t eco_caf_promote(std::uint64_t bits, std::uint64_t* slot);
extern "C" int64_t Eco_Kernel_FNV_hash(HPtr value);

using namespace Elm;

namespace {

constexpr unsigned kTagShift = 43;

HPointer withTag(HPointer p, u32 idx) {
    return hpFromBits(hpBits(p) | (static_cast<u64>(idx) << kTagShift));
}

u32 tagOf(u64 bits) {
    return static_cast<u32>((bits >> kTagShift) & 0x3FF);
}

HPointer str(const std::string& s) {
    return alloc::allocString(std::u16string(s.begin(), s.end()));
}

// Returns whether `bits` is a heap word tagged `idx` naming a String whose text is `text`, at the address
// the untagged root `same` now names (so a word the collector skipped, still naming the stale copy, fails).
bool namesString(Allocator& a, u64 bits, u32 idx, const std::string& text, HPointer same, const char* where) {
    if (tagOf(bits) != idx) {
        std::fprintf(stderr, "  %s: tag %u, expected %u (word 0x%016llx)\n", where, tagOf(bits), idx,
                     static_cast<unsigned long long>(bits));
        return false;
    }
    if (isConstantBits(bits)) {
        std::fprintf(stderr, "  %s: a constant word\n", where);
        return false;
    }
    void* obj = a.resolve(hpFromBits(bits));
    if (obj != a.resolve(same)) {
        std::fprintf(stderr, "  %s: names %p, but the object is now at %p\n", where, obj, a.resolve(same));
        return false;
    }
    if (getHeader(obj)->tag != Tag_String) {
        std::fprintf(stderr, "  %s: object tag %u, expected a String\n", where, getHeader(obj)->tag);
        return false;
    }
    const std::u16string got = StringOps::toStdU16String(obj);
    if (got != std::u16string(text.begin(), text.end())) {
        std::fprintf(stderr, "  %s: wrong text\n", where);
        return false;
    }
    return true;
}

// Builds the six holders of tagged words, runs `collect` (possibly several times), and checks every word.
void scenario(Allocator& a, const std::function<void(Allocator&)>& collect) {
    RootSet& roots = a.getRootSet();

    // The payloads, each also held by an untagged root.
    std::vector<std::string> texts = {"in a root slot", "in a Custom field", "in a record field",
                                      "in a list head", "in an array element", "in a JIT root"};
    std::vector<HPointer> plain(texts.size());
    for (size_t i = 0; i < texts.size(); ++i) {
        plain[i] = str(texts[i]);
        roots.addRoot(&plain[i]);
    }

    HPointer rootSlot = withTag(plain[0], 1);
    roots.addRoot(&rootSlot);

    HPointer custom = alloc::custom(0, {alloc::boxed(withTag(plain[1], 5)), alloc::boxed(str("plain"))},
                                    std::vector<u8>{0, 0});
    roots.addRoot(&custom);

    HPointer record = alloc::record({alloc::boxed(withTag(plain[2], 6))}, std::vector<u8>{0});
    roots.addRoot(&record);

    HPointer list = alloc::cons(alloc::boxed(withTag(plain[3], 7)), alloc::listNil(), u8{0});
    roots.addRoot(&list);

    HPointer array = alloc::allocArray(4);
    roots.addRoot(&array);
    TEST_ASSERT(alloc::arrayPushKind(a.resolve(array), alloc::boxed(withTag(plain[4], 1023)), 0));

    uint64_t jitSlot = hpBits(withTag(plain[5], 9));
    roots.addJitRoot(&jitSlot);

    collect(a);

    bool ok = true;
    ok &= namesString(a, hpBits(rootSlot), 1, texts[0], plain[0], "root slot");
    ok &= namesString(a, hpBits(static_cast<Custom*>(a.resolve(custom))->values[0].p), 5, texts[1], plain[1],
                      "Custom field");
    ok &= namesString(a, hpBits(static_cast<Record*>(a.resolve(record))->values[0].p), 6, texts[2], plain[2],
                      "record field");
    ok &= namesString(a, hpBits(static_cast<Cons*>(a.resolve(list))->head.p), 7, texts[3], plain[3], "list head");
    ok &= namesString(a, hpBits(static_cast<ElmArray*>(a.resolve(array))->elements[0].p), 1023, texts[4], plain[4],
                      "array element");
    ok &= namesString(a, jitSlot, 9, texts[5], plain[5], "JIT root");

    roots.removeJitRoot(&jitSlot);
    roots.removeRoot(&array);
    roots.removeRoot(&list);
    roots.removeRoot(&record);
    roots.removeRoot(&custom);
    roots.removeRoot(&rootSlot);
    for (auto& p : plain) roots.removeRoot(&p);
    TEST_ASSERT(ok);
}

void minorOnce(Allocator& a) { a.minorGC(); }

void minorUntilTenured(Allocator& a) {
    for (int i = 0; i < 4; ++i) a.minorGC();
}

void minorThenMajor(Allocator& a) {
    a.minorGC();
    a.majorGC();
    a.minorGC();
}

// A CAF value whose graph holds a tagged word is copied into permanent space with the tag kept, on its
// fields and on the returned root word itself.
void cafPromotion() {
    Allocator& a = initAllocator();
    HPointer field = str("in a CAF field");
    HPointer custom = alloc::custom(0, {alloc::boxed(withTag(field, 3))}, std::vector<u8>{0});
    std::uint64_t slot = 0;
    const std::uint64_t in = hpBits(withTag(custom, 4));
    const std::uint64_t out = eco_caf_promote(in, &slot);
    bool ok = tagOf(out) == 4;
    if (!ok) std::fprintf(stderr, "  CAF root: tag %u, expected 4\n", tagOf(out));
    // The copy's field names the copied String, not `field`: check the tag and the text.
    const u64 f = hpBits(static_cast<Custom*>(a.resolve(hpFromBits(out)))->values[0].p);
    ok &= namesString(a, f, 3, "in a CAF field", hpFromBits(f & ((1ULL << kTagShift) - 1)), "CAF field");
    TEST_ASSERT(ok);
}

HPtr toHPtr(HPointer p) { return HPtr::fromBits(hpBits(p)); }

bool equal(HPointer a, HPointer b) {
    return Elm_Kernel_Utils_equal(toHPtr(a), toHPtr(b)).toBits() == hpBits(alloc::elmTrue());
}

// `==` and FNV.hash compare a tagged word's tag before its object (HEAP_086): two words over one String with
// different tags are different constructors, at the top level and as fields; equal words hash equally.
void equalityAndHash() {
    Allocator& a = initAllocator();
    HPointer s = str("payload");
    a.getRootSet().addRoot(&s);
    const HPointer a1 = withTag(s, 1), a1b = withTag(s, 1), b2 = withTag(s, 2);

    bool ok = true;
    ok &= equal(a1, a1b);
    ok &= !equal(a1, b2);
    ok &= !equal(a1, s);

    HPointer ca = alloc::custom(0, {alloc::boxed(a1)}, std::vector<u8>{0});
    a.getRootSet().addRoot(&ca);
    HPointer cb = alloc::custom(0, {alloc::boxed(withTag(s, 2))}, std::vector<u8>{0});
    a.getRootSet().addRoot(&cb);
    HPointer cc = alloc::custom(0, {alloc::boxed(withTag(s, 1))}, std::vector<u8>{0});
    a.getRootSet().addRoot(&cc);
    ok &= !equal(ca, cb);   // fields of different constructors over one String
    ok &= equal(ca, cc);

    // A tagged Empty (a bare `A ""`) is not the plain Empty word, nor another constructor's Empty.
    const HPointer emptyA = hpFromBits(0x6ULL | (1ULL << kTagShift));
    const HPointer emptyB = hpFromBits(0x6ULL | (2ULL << kTagShift));
    ok &= equal(emptyA, hpFromBits(0x6ULL | (1ULL << kTagShift)));
    ok &= !equal(emptyA, emptyB);
    ok &= !equal(emptyA, alloc::emptyString());

    ok &= Eco_Kernel_FNV_hash(toHPtr(a1)) == Eco_Kernel_FNV_hash(toHPtr(a1b));
    ok &= Eco_Kernel_FNV_hash(toHPtr(ca)) == Eco_Kernel_FNV_hash(toHPtr(cc));
    ok &= Eco_Kernel_FNV_hash(toHPtr(a1)) != Eco_Kernel_FNV_hash(toHPtr(b2));

    a.getRootSet().removeRoot(&cc);
    a.getRootSet().removeRoot(&cb);
    a.getRootSet().removeRoot(&ca);
    a.getRootSet().removeRoot(&s);
    TEST_ASSERT(ok);
}

}  // namespace

void registerTaggedWordGcTests(Testing::TestSuite& suite) {
    suite.add(Testing::UnitTest("TaggedWordGc: serial legacy minor keeps tags", [] {
        HeapConfig cfg;
        cfg.gc_minor_threads = 1;
        scenario(initLegacyAllocator(cfg), minorOnce);
    }));
    suite.add(Testing::UnitTest("TaggedWordGc: parallel legacy minor keeps tags", [] {
        HeapConfig cfg;
        cfg.gc_minor_threads = 4;
        cfg.minor_parallel_min_bytes = 0;
        scenario(initLegacyAllocator(cfg), minorOnce);
    }));
    suite.add(Testing::UnitTest("TaggedWordGc: region minor keeps tags", [] {
        scenario(initAllocator(), minorOnce);
    }));
    suite.add(Testing::UnitTest("TaggedWordGc: region minors through tenuring keep tags", [] {
        scenario(initAllocator(), minorUntilTenured);
    }));
    suite.add(Testing::UnitTest("TaggedWordGc: a major collection keeps tags", [] {
        scenario(initAllocator(), minorThenMajor);
    }));
    suite.add(Testing::UnitTest("TaggedWordGc: CAF promotion keeps tags", cafPromotion));
    suite.add(Testing::UnitTest("TaggedWordGc: == and FNV.hash compare tags", equalityAndHash));
}
