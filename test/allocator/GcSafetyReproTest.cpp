/**
 * Regression tests for GC-safety defects found in the runtime review (cpp-review-bugs.md, "High
 * severity"). Each test forces a minor collection at the one point the defect needs, with
 * `NurserySpace::requestMinor`, so it fails on every run rather than under rare timing.
 *
 * - String slice: a short non-ASCII slice of a nursery UTF-16 String copied its units from the
 *   source after allocating the result, so from a stale address when that allocation collected.
 * - JIT roots: the serial semi-space minor promoted a large String header reached only from a JIT
 *   root without transferring its body to the old generation (HEAP_026), so a later minor freed
 *   the body under the live header.
 */

#include "GcSafetyReproTest.hpp"

#include <cstring>
#include <string>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "NurserySpace.hpp"
#include "StringOps.hpp"
#include "TestHelpers.hpp"

using namespace Elm;

namespace {

// A non-ASCII run, so a slice of it is copied as UTF-16 rather than through the stack buffer of the
// UTF-8 path.
const std::u16string kAccented = u"éèêëàâäôöûüç"
                                 u"ÉÈÊËÀÂÄÔÖÛÜÇ";

// A short non-ASCII slice of a nursery UTF-16 String, taken when its result's allocation collects,
// holds the source's units.
//
// The collection copies the rooted source out of from-space (or eden). A scanner registered for
// the test, which runs after the ordinary roots, then overwrites the units of the old copy, as a
// later allocation into that space would; the slice must not read them.
void sliceAcrossCollection(Allocator& a) {
    HPointer src = alloc::allocString(kAccented);
    void* orig = a.resolve(src);
    TEST_ASSERT(getHeader(orig)->tag == Tag_String);
    a.getRootSet().addRoot(&src);

    NurserySpace* nursery = AllocatorTestAccess::getNursery(a);
    TEST_ASSERT(NurserySpaceTestAccess::contains(*nursery, orig));

    const size_t units = kAccented.size();
    bool armed = true;
    a.getRootSet().addExternalRootScanner(
        [&armed, orig, units](RootSet::EvacuateFn) {
            if (!armed) return;
            armed = false;
            std::memset(static_cast<ElmString*>(orig)->chars, 0xDD, units * sizeof(u16));
        },
        "GcSafetyRepro.slice");

    const uint64_t seq0 = nursery->minorSeq();
    TEST_ASSERT(nursery->requestMinor());
    HPointer out = StringOps::slice(a.resolve(src), 2, 10);
    TEST_ASSERT(nursery->minorSeq() == seq0 + 1);
    TEST_ASSERT(a.resolve(src) != orig);

    const std::u16string got = StringOps::toStdU16String(a.resolve(out));
    a.getRootSet().removeRoot(&src);
    TEST_ASSERT(got == kAccented.substr(2, 8));
}

// A large String header reached only through a JIT root keeps its body across the minor that
// promotes it and the minors after.
//
// The header is the only reference: its body leaves the nursery's ownership only if the promotion
// calls `OldGenSpace::promoteLargeHeader`. Otherwise the first minor after the promotion, which no
// longer reaches the header, frees the body, and the large Strings allocated next reuse its cell.
void jitRootLargeStringPromotion() {
    HeapConfig cfg;
    cfg.gc_minor_threads = 1;   // the serial core, whose JIT-root path is under test
    Allocator& a = initLegacyAllocator(cfg);
    NurserySpace* nursery = AllocatorTestAccess::getNursery(a);

    const size_t units = 20000;   // above the large-object threshold: a split header + LOS body
    uint64_t jitSlot;
    {
        HPointer s = alloc::allocString(std::u16string(units, u'q'));
        void* hdr = a.resolve(s);
        TEST_ASSERT(getHeader(hdr)->tag == Tag_LargeStringHeader);
        TEST_ASSERT(NurserySpaceTestAccess::contains(*nursery, hdr));
        jitSlot = reinterpret_cast<uint64_t>(hdr);
    }
    a.getRootSet().addJitRoot(&jitSlot);

    // Minor collections until the header is promoted, then two more.
    int minors = 0;
    while (NurserySpaceTestAccess::contains(*nursery, reinterpret_cast<void*>(jitSlot))) {
        TEST_ASSERT(++minors <= 8);
        a.minorGC();
    }
    a.minorGC();
    a.minorGC();

    // Large Strings of another unit, unrooted, to take any freed body cell.
    for (int i = 0; i < 8; ++i) (void)alloc::allocString(std::u16string(units, u'z'));

    auto* h = reinterpret_cast<LargeStringHeader*>(jitSlot);
    TEST_ASSERT(h->header.tag == Tag_LargeStringHeader);
    const u16* chars = largeStringChars(h);
    size_t bad = 0;
    for (size_t i = 0; i < units; ++i) bad += chars[i] != u'q';
    a.getRootSet().removeJitRoot(&jitSlot);
    TEST_ASSERT(bad == 0);
}

}  // namespace

void registerGcSafetyReproTests(Testing::TestSuite& suite) {
    suite.add(Testing::UnitTest("GcSafetyRepro: String slice reads its source after a collection (legacy nursery)", [] {
        HeapConfig cfg;
        cfg.gc_minor_threads = 1;
        sliceAcrossCollection(initLegacyAllocator(cfg));
    }));
    suite.add(Testing::UnitTest("GcSafetyRepro: String slice reads its source after a collection (region nursery)", [] {
        sliceAcrossCollection(initAllocator());
    }));
    suite.add(Testing::UnitTest("GcSafetyRepro: JIT-rooted large String keeps its body after promotion (serial minor)",
                                jitRootLargeStringPromotion));
}
