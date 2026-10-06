/**
 * Wide Custom/Record objects, layout C (plans/wide-object-tail-kind-words-phase-3.md,
 * step 3A.9, T1-T14).
 *
 * A Custom (Record) of n fields carries its kinds for slots 0..23 (0..31) in the
 * header bitmap and K = extWords(n, CAP) extension kind words after values[n];
 * K is stored in header.unboxed (HEAP_019, HEAP_077). These tests build wide
 * objects through the runtime builders and drive them through every GC path:
 * serial and parallel minors, promotion, majors, compaction, YLOS, nursery-large
 * placement, region mode with concurrent tenuring, a concurrent mark cycle, the
 * CAF permanent copy, equality and the printer.
 *
 * Validate builds check K and the ext-word padding of every scanned
 * Custom/Record (validateExtKinds). T8 (the Phase 3A-3C inertness census) was
 * deleted with the test switch in Phase 3D. Death tests run in a fork()ed child
 * (ParallelMinorTest.cpp pattern).
 */

#include "WideObjectTest.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/AllocatorCommon.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/OldGenSpace.hpp"
#include "../../runtime/src/allocator/PermanentSpace.hpp"
#include "../../runtime/src/allocator/RootSet.hpp"
#include "../../runtime/src/allocator/ThreadLocalHeap.hpp"
#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../../elm-kernel-cpp/src/ExportHelpers.hpp"
#include "TestHelpers.hpp"
#include "../TestSuite.hpp"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#if !defined(_WIN32)
#include <sys/wait.h>
#include <unistd.h>
#endif

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

using OA = OldGenSpaceTestAccess;
using BE = OldGenSpace::BgEpisode;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

u32 capOf(bool isC) { return isC ? CUSTOM_HDR_SLOTS : RECORD_HDR_SLOTS; }

// k[i] = (i*7+3) % 4, forced boxed at cap-1, cap, cap+31, cap+32 and n-1, with
// typed neighbours, so every kind sits on both sides of each word boundary.
std::vector<u8> kindsPattern(u32 n, u32 cap) {
    std::vector<u8> k(n);
    for (u32 i = 0; i < n; ++i) k[i] = static_cast<u8>((i * 7 + 3) % 4);
    const u32 forced[] = {cap - 1, cap, cap + 31, cap + 32, n - 1};
    u8 nb = 1;
    for (u32 f : forced) {
        if (f >= n) continue;
        if (f > 0) { k[f - 1] = nb; nb = static_cast<u8>(nb % 3 + 1); }
        if (f + 1 < n) { k[f + 1] = nb; nb = static_cast<u8>(nb % 3 + 1); }
    }
    for (u32 f : forced)
        if (f < n) k[f] = 0;
    return k;
}

Unboxable rawSlot(u32 i, u8 kind) {
    Unboxable u;
    u.i = 0;
    switch (kind) {
        case 1: u.i = static_cast<i64>(i) * 3; break;
        case 2: u.f = static_cast<f64>(i) + 0.5; break;
        case 3: u.i = 'a' + static_cast<i64>(i % 26); break;
        default: break;
    }
    return u;
}

HPtr toHPtr(HPointer p) {
    HPtr h;
    std::memcpy(&h.bits, &p, sizeof(h.bits));
    return h;
}

uint64_t bitsOf(HPointer p) {
    uint64_t b;
    std::memcpy(&b, &p, sizeof(b));
    return b;
}

// Builds a wide Custom (ctor 7) or Record of n fields through alloc::custom /
// alloc::record with kindsPattern(n, CAP): boxed slots hold fresh young Ints
// 1000+i, Int slots i*3, Float slots i+0.5, Char slots 'a'+(i%26).
HPointer buildWide(bool isC, u32 n) {
    Allocator& a = Allocator::instance();
    const std::vector<u8> kinds = kindsPattern(n, capOf(isC));
    std::vector<HPointer> held(n);
    std::vector<u32> rooted;
    for (u32 i = 0; i < n; ++i) {
        if (kinds[i] != 0) continue;
        held[i] = alloc::allocInt(1000 + static_cast<i64>(i));
        a.getRootSet().addRoot(&held[i]);
        rooted.push_back(i);
    }
    std::vector<Unboxable> values(n);
    for (u32 i = 0; i < n; ++i) {
        if (kinds[i] == 0) values[i].p = held[i];
        else values[i] = rawSlot(i, kinds[i]);
    }
    HPointer h = isC ? alloc::custom(7, values, kinds) : alloc::record(values, kinds);
    for (u32 i : rooted) a.getRootSet().removeRoot(&held[i]);
    return h;
}

[[noreturn]] void failAt(const std::string& where, const std::string& what) {
    throw std::runtime_error("wide check (" + where + "): " + what);
}

// Checks one object word by word against what buildWide stored. `obj` may be a
// permanent-space copy (resolve = identity on its word).
void checkWideObj(const void* obj, bool isC, u32 n, const std::string& where) {
    Allocator& a = Allocator::instance();
    const Header* h = static_cast<const Header*>(obj);
    const u32 cap = capOf(isC);
    const u32 K = extWords(n, cap);
    if (h->tag != (isC ? Tag_Custom : Tag_Record)) failAt(where, "tag");
    if (h->size != n) failAt(where, "header.size " + std::to_string(h->size) + " != " + std::to_string(n));
    if (h->unboxed != K) failAt(where, "header.unboxed " + std::to_string(h->unboxed) + " != K " + std::to_string(K));
    if (getObjectSize(const_cast<void*>(obj)) != 16 + 8 * size_t(n + K)) failAt(where, "getObjectSize");
    if (isC && static_cast<const Custom*>(obj)->ctor != 7) failAt(where, "ctor");
    const std::vector<u8> kinds = kindsPattern(n, cap);
    const Unboxable* vals = isC ? static_cast<const Custom*>(obj)->values : static_cast<const Record*>(obj)->values;
    for (u32 i = 0; i < n; ++i) {
        const u32 k = isC ? customSlotKind(static_cast<const Custom*>(obj), i)
                          : recordSlotKind(static_cast<const Record*>(obj), i);
        if (k != kinds[i]) failAt(where, "kind of slot " + std::to_string(i));
        if (k == 0) {
            void* child = a.resolve(vals[i].p);
            if (child == nullptr || getHeader(child)->tag != Tag_Int)
                failAt(where, "boxed slot " + std::to_string(i) + " is not an Int");
            if (static_cast<ElmInt*>(child)->value != 1000 + static_cast<i64>(i))
                failAt(where, "boxed slot " + std::to_string(i) + " value");
        } else {
            const Unboxable want = rawSlot(i, kinds[i]);
            if (std::memcmp(&vals[i], &want, 8) != 0) failAt(where, "raw slot " + std::to_string(i));
        }
    }
    if (K) {   // padding past the last slot is zero (HEAP_077)
        const u64* ext = isC ? customExtWords(static_cast<const Custom*>(obj))
                             : recordExtWords(static_cast<const Record*>(obj));
        const u32 used = (n - cap) - (K - 1) * SLOTS_PER_EXT_WORD;
        if (used < SLOTS_PER_EXT_WORD && (ext[K - 1] >> (2 * used)) != 0) failAt(where, "ext padding");
    }
}

void checkWide(HPointer hp, bool isC, u32 n, const std::string& where) {
    void* obj = Allocator::instance().resolve(hp);
    if (obj == nullptr) failAt(where, "null");
    checkWideObj(obj, isC, n, where);
}

struct Spec { bool isC; u32 n; };
const std::vector<Spec> kAllSpecs = {
    {true, 25}, {true, 56}, {true, 1100}, {true, 2040},
    {false, 33}, {false, 64}, {false, 1100}, {false, 2047},
};
std::string nameOf(const Spec& s) { return std::string(s.isC ? "Custom " : "Record ") + std::to_string(s.n); }

// Builds every spec, rooted in `roots` (pre-sized; caller removes the roots).
void buildRooted(const std::vector<Spec>& specs, std::vector<HPointer>& roots) {
    Allocator& a = Allocator::instance();
    roots.assign(specs.size(), HPointer{});
    for (size_t s = 0; s < specs.size(); ++s) {
        roots[s] = buildWide(specs[s].isC, specs[s].n);
        a.getRootSet().addRoot(&roots[s]);
    }
}
void checkAll(const std::vector<Spec>& specs, const std::vector<HPointer>& roots, const std::string& where) {
    for (size_t s = 0; s < specs.size(); ++s) checkWide(roots[s], specs[s].isC, specs[s].n, where + ", " + nameOf(specs[s]));
}
void unroot(std::vector<HPointer>& roots) {
    for (auto& r : roots) Allocator::instance().getRootSet().removeRoot(&r);
}

void churn(int n = 20000) {
    for (int i = 0; i < n; ++i) (void)alloc::allocInt(0x5A5A0000 + i);
}

uint64_t minorCount() { return Allocator::instance().getCombinedStats().minor_gc_count; }
uint64_t majorCount() { return Allocator::instance().getCombinedStats().major_gc_count; }

ThreadLocalHeap* tlh(Allocator& a) { return AllocatorTestAccess::getThreadHeap(a); }
OldGenSpace& og(Allocator& a) { return tlh(a)->getOldGen(); }

// ---- heap configs (unit tests ignore ECO_HEAP_CONFIG) ----
// = LargePtrPlacementTest.cpp smallConfig: 64 KiB per side; divisor 0 = every
// pointer-bearing large object is a YLOS. Serial minors (threads 0, lab pinned).
HeapConfig wideSmall(u32 divisor) {
    HeapConfig c;
    c.alloc_buffer_size = 32 * 1024;
    c.nursery_block_count = 4;
    c.nursery_max_block_count = 4;
    c.initial_old_gen_size = 256 * 1024;
    c.max_heap_size = 256ULL << 20;
    c.large_object_threshold = 8 * 1024;
    c.large_ptr_nursery_divisor = divisor;
    c.decommit_on_oldgen_release = false;
    c.gc_thread_mode = 0;
    c.gc_minor_threads = 0;
    c.minor_lab_bytes = 4096;
    c.validate();
    return c;
}
HeapConfig wideNurseryLarge() {
    HeapConfig c = wideSmall(2);
    c.large_ptr_nursery_max_size = 64 * 1024;
    c.validate();
    return c;
}
HeapConfig wideParallel() {
    HeapConfig c = wideSmall(2);
    c.old_gen_bitmap_alloc = true;
    c.gc_minor_threads = 4;
    c.minor_parallel_min_bytes = 0;
    c.validate();
    return c;
}
// = ConcurrentTenureTest.cpp tenureConfig(2) with the tenure age k = 2.
HeapConfig wideRegion() {
    HeapConfig cfg;
    cfg.alloc_buffer_size          = 32 * 1024;
    cfg.nursery_block_count        = 64;
    cfg.nursery_max_block_count    = 64;
    cfg.initial_old_gen_size       = 256 * 1024;
    cfg.max_heap_size              = 512ULL * 1024 * 1024;
    cfg.large_object_threshold     = 8 * 1024;
    cfg.large_ptr_nursery_max_size = 8 * 1024;
    cfg.decommit_on_oldgen_release = false;
    cfg.old_gen_bitmap_alloc       = true;
    cfg.gc_thread_mode             = 0;
    cfg.gc_minor_threads           = 1;
    cfg.minor_lab_bytes            = 4096;
    cfg.minor_parallel_min_bytes   = 0;
    cfg.nursery_regions            = 1;
    cfg.tenure_mode                = 2;
    cfg.tenure_help                = 1;
    cfg.tenure_help_threads        = 1;
    cfg.promotion_age              = 2;
    cfg.validate();
    return cfg;
}
// Concurrent mark t0 (ConcurrencyRegisterTest.cpp cr017ConcConfig settings) over
// the wideSmall(0) placement.
HeapConfig wideConc() {
    HeapConfig c = wideSmall(0);
    c.incremental_mark = true;
    c.incremental_mark_slices = 8;
    c.incremental_mark_min_slice_units = 64;
    c.conc_mark = 2;
    c.gc_mark_threads = 1;
    c.conc_mark_threads = 1;
    c.conc_mark_priority = 0;
    c.validate();
    return c;
}

// Pins the concurrent-mark mode: the ECO_GC_CONC_MARK* variables would otherwise win.
struct EnvGuard {
    std::string m, t;
    bool hm = false, ht = false;
    EnvGuard() {
        if (const char* v = std::getenv("ECO_GC_CONC_MARK")) { m = v; hm = true; }
        if (const char* v = std::getenv("ECO_GC_CONC_MARK_THREADS")) { t = v; ht = true; }
        unsetenv("ECO_GC_CONC_MARK");
        unsetenv("ECO_GC_CONC_MARK_THREADS");
    }
    ~EnvGuard() {
        if (hm) setenv("ECO_GC_CONC_MARK", m.c_str(), 1);
        if (ht) setenv("ECO_GC_CONC_MARK_THREADS", t.c_str(), 1);
    }
};

// = ConcurrentMarkTest.cpp runToHandoff / holdNextCycle / startCycle / waitBackground.
void runToHandoff(Allocator& a) {
    for (int g = 0; OA::cycleActive(og(a)); ++g) {
        if (g > 100000) throw std::runtime_error("cycle never handed off");
        a.minorGC();
    }
}
void holdNextCycle(Allocator& a) {
    runToHandoff(a);
    og(a).test_bg_hold_.store(true);
}
void startCycle(Allocator& a) {
    runToHandoff(a);
    tlh(a)->test_force_major_trigger_ = true;
    a.minorGC();
}
bool waitBackground(Allocator& a, int ms = 20000) {
    for (int i = 0; i < ms; ++i) {
        if (OA::bgEpisode(og(a)) != BE::Running || OA::bgFinishedApprox(og(a))) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return false;
}

#if ENABLE_GC_STATS
// Placement counters (noteLargeAlloc) live in the thread heap's stats; the
// YLOS promote/free counters in the old gen's (LargePtrPlacementTest.cpp).
const LargePtrStats& ogLp(Allocator& a) { return og(a).getStats().lp; }
const LargePtrStats& tlhLp(Allocator& a) { return tlh(a)->getStats().lp; }
#endif

#if !defined(_WIN32)   // fork()ed children: POSIX only; the death tests are no-ops on Windows
// Runs `f` in a forked child with stderr captured. Returns the wait status.
template <class F> int runInChildCapture(F f, std::string& err) {
    int fds[2];
    if (pipe(fds) != 0) throw std::runtime_error("pipe failed");
    pid_t pid = fork();
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], 2);
        close(fds[1]);
        f();
        _exit(0);
    }
    close(fds[1]);
    char buf[4096];
    ssize_t r;
    while ((r = read(fds[0], buf, sizeof buf)) > 0) err.append(buf, static_cast<size_t>(r));
    close(fds[0]);
    int st = 0;
    waitpid(pid, &st, 0);
    return st;
}

bool abnormal(int st) { return WIFSIGNALED(st) || (WIFEXITED(st) && WEXITSTATUS(st) != 0); }
#endif

// ---------------------------------------------------------------------------
// T1
// ---------------------------------------------------------------------------
void test_split_inverts() {
    for (u32 cap : {CUSTOM_HDR_SLOTS, RECORD_HDR_SLOTS}) {
        std::set<u32> image;
        for (u32 n = 0; n <= 2200; ++n) {
            const u32 W = n + extWords(n, cap);
            image.insert(W);
            if (n <= 2047) {
                u32 sn = 0, sk = 0;
                TEST_ASSERT(splitPhysicalSlots(W, cap, sn, sk));
                TEST_ASSERT(sn == n && sk == extWords(n, cap));
            }
        }
        for (u32 W = 0; W <= 2200; ++W) {
            u32 sn = 0, sk = 0;
            const bool ok = splitPhysicalSlots(W, cap, sn, sk);
            TEST_ASSERT(ok == (image.count(W) != 0));
            if (ok) TEST_ASSERT(sn + sk == W && sk == extWords(sn, cap));
        }
    }
    static_assert(extWords(CUSTOM_MAX_FIELDS, CUSTOM_HDR_SLOTS) == 63);
    static_assert(extWords(RECORD_MAX_FIELDS, RECORD_HDR_SLOTS) == 63);
}

// ---------------------------------------------------------------------------
// T2
// ---------------------------------------------------------------------------
void test_builders_round_trip() {
    initAllocator();
    for (const Spec& s : kAllSpecs) {
        HPointer h = buildWide(s.isC, s.n);
        checkWide(h, s.isC, s.n, "built " + nameOf(s));
    }
}

// ---------------------------------------------------------------------------
// T3 / T4
// ---------------------------------------------------------------------------
void gcScenario(Allocator& a, const std::string& tag) {
    std::vector<HPointer> roots;
    buildRooted(kAllSpecs, roots);
    checkAll(kAllSpecs, roots, tag + " built");
    const uint64_t m0 = minorCount(), M0 = majorCount();
    for (int k = 0; k < 3; ++k) {
        churn();
        a.minorGC();
        checkAll(kAllSpecs, roots, tag + " minor " + std::to_string(k));
    }
    a.majorGC();
    checkAll(kAllSpecs, roots, tag + " major");
    OA::scheduleCompaction(og(a));
    a.majorGC();
    checkAll(kAllSpecs, roots, tag + " compaction");
    churn();
    a.minorGC();
    checkAll(kAllSpecs, roots, tag + " final minor");
#if ENABLE_GC_STATS
    TEST_ASSERT(minorCount() >= m0 + 3);
    TEST_ASSERT(majorCount() >= M0 + 2);
#else
    (void)m0; (void)M0;
#endif
    unroot(roots);
}

void test_serial_gc() { gcScenario(initAllocator(wideSmall(2)), "serial"); }

void test_parallel_minor() {
    auto& a = initAllocator(wideParallel());
    gcScenario(a, "parallel");
#if ENABLE_GC_STATS
    TEST_ASSERT(tlh(a)->getNursery().getStats().pmin.minors_parallel > 0);
#endif
}

// ---------------------------------------------------------------------------
// T5
// ---------------------------------------------------------------------------
void test_ylos_forced() {
    auto& a = initAllocator(wideSmall(0));
#if ENABLE_GC_STATS
    const uint64_t ylos0 = tlhLp(a).ylos_allocs, inplace0 = ogLp(a).ylos_promoted_in_place;
#endif
    const std::vector<Spec> specs = {{true, 1100}, {true, 2040}, {false, 2047}};
    std::vector<HPointer> roots(specs.size());
    for (size_t s = 0; s < specs.size(); ++s) {
        roots[s] = buildWide(specs[s].isC, specs[s].n);
        a.getRootSet().addRoot(&roots[s]);
        TEST_ASSERT(og(a).isYoungLarge(a.resolve(roots[s])));   // >= 8 KiB with divisor 0
    }
    for (int k = 0; k < 3; ++k) {
        churn();
        a.minorGC();
        checkAll(specs, roots, "YLOS minor " + std::to_string(k));
    }
    for (auto& r : roots) TEST_ASSERT(!og(a).isYoungLarge(a.resolve(r)));   // promoted in place
    a.majorGC();
    checkAll(specs, roots, "YLOS major");
#if ENABLE_GC_STATS
    TEST_ASSERT(tlhLp(a).ylos_allocs >= ylos0 + 3);
    TEST_ASSERT(ogLp(a).ylos_promoted_in_place >= inplace0 + 1);
#endif
    unroot(roots);
}

// ---------------------------------------------------------------------------
// T6
// ---------------------------------------------------------------------------
void test_nursery_large() {
    auto& a = initAllocator(wideNurseryLarge());
#if ENABLE_GC_STATS
    const uint64_t n0 = tlhLp(a).nursery_allocs;
#endif
    const std::vector<Spec> specs = {{true, 1100}, {false, 1100}};
    std::vector<HPointer> roots(specs.size());
    for (size_t s = 0; s < specs.size(); ++s) {
        roots[s] = buildWide(specs[s].isC, specs[s].n);
        a.getRootSet().addRoot(&roots[s]);
        TEST_ASSERT(a.isInNursery(a.resolve(roots[s])));
    }
#if ENABLE_GC_STATS
    TEST_ASSERT(tlhLp(a).nursery_allocs >= n0 + 1);
#endif
    for (int k = 0; k < 3; ++k) {
        churn();
        a.minorGC();
        checkAll(specs, roots, "nursery-large minor " + std::to_string(k));
    }
    a.majorGC();
    checkAll(specs, roots, "nursery-large major");
    unroot(roots);
}

// ---------------------------------------------------------------------------
// T7
// ---------------------------------------------------------------------------
void test_region_k2() {
    auto& a = initRegionAllocator(wideRegion());
#if ENABLE_GC_STATS
    const auto& rg = tlh(a)->getNursery().getStats().rg;
    const uint64_t minors0 = rg.minors, tenured0 = rg.tenured;
#endif
    const std::vector<Spec> base = {{true, 56}, {false, 64}, {false, 1100}, {true, 1100}};
    std::vector<Spec> specs;
    for (int j = 0; j < 3; ++j) specs.insert(specs.end(), base.begin(), base.end());
    std::vector<HPointer> roots;
    buildRooted(specs, roots);
    churn();
    a.minorGC();   // first age
    checkAll(specs, roots, "region age 1");
    // Drop every other object: dead ageing survivors are zapped at the merge (CR-038 path).
    std::vector<Spec> keepSpecs;
    std::vector<HPointer> keep;
    keep.reserve(specs.size());
    for (size_t s = 0; s < specs.size(); ++s) {
        if (s % 2 == 0) { keepSpecs.push_back(specs[s]); keep.push_back(roots[s]); }
    }
    unroot(roots);
    for (auto& r : keep) a.getRootSet().addRoot(&r);
    for (int k = 0; k < 5; ++k) {
        churn();
        a.minorGC();
        checkAll(keepSpecs, keep, "region minor " + std::to_string(k));
    }
    a.majorGC();
    checkAll(keepSpecs, keep, "region major");
#if ENABLE_GC_STATS
    TEST_ASSERT(rg.minors >= minors0 + 4);
    TEST_ASSERT(rg.tenured > tenured0);
#endif
    unroot(keep);
}

// ---------------------------------------------------------------------------
// T9
// ---------------------------------------------------------------------------
void test_conc_mark_wide_ylos() {
    EnvGuard env;
    auto& a = initAllocator(wideConc());
    const uint64_t M0 = majorCount();
    HPointer w = buildWide(true, 2040);
    TEST_ASSERT(og(a).isYoungLarge(a.resolve(w)));
    HPointer t;
    {
        StackRootRangeGuard sg(&w, 1, 1);
        t = alloc::tuple2(alloc::boxed(w), alloc::unboxedInt(42), 0x4);   // b: Int
    }
    a.getRootSet().addRoot(&t);   // the YLOS is reachable only through the young tuple
    auto wOf = [&]() { return static_cast<Tuple2*>(a.resolve(t))->a.p; };
    holdNextCycle(a);
    startCycle(a);   // t0 walks the young tuple
    TEST_ASSERT(OA::cycleActive(og(a)));
    churn();
    a.minorGC();
    checkWide(wOf(), true, 2040, "conc held");
    og(a).test_bg_hold_.store(false);
    TEST_ASSERT(waitBackground(a));
    runToHandoff(a);
    checkWide(wOf(), true, 2040, "conc after handoff");
    a.majorGC();
    checkWide(wOf(), true, 2040, "conc after STW major");
#if ENABLE_GC_STATS
    TEST_ASSERT(majorCount() > M0);
#else
    (void)M0;
#endif
    a.getRootSet().removeRoot(&t);
}

// ---------------------------------------------------------------------------
// T10
// ---------------------------------------------------------------------------
void test_caf_permanent_copy() {
    initAllocator();
    static uint64_t slots[2] = {0, 0};
    const std::vector<Spec> specs = {{false, 64}, {true, 56}};
    for (size_t s = 0; s < specs.size(); ++s) {
        HPointer h = buildWide(specs[s].isC, specs[s].n);
        Allocator::instance().getRootSet().addRoot(&h);
        const uint64_t bits = bitsOf(h);
        const uint64_t out = eco_caf_promote(bits, &slots[s]);
        TEST_ASSERT(out != bits);   // promoted: a permanent copy (ECO_CAF_PERMANENT unset = on)
        const void* copy = reinterpret_cast<const void*>(out);   // permanent word = address
        checkWideObj(copy, specs[s].isC, specs[s].n, "permanent copy " + nameOf(specs[s]));
        const u32 K = extWords(specs[s].n, capOf(specs[s].isC));
        const void* orig = Allocator::instance().resolve(h);
        TEST_ASSERT(std::memcmp(static_cast<const char*>(copy) + 8, static_cast<const char*>(orig) + 8, 8) == 0);
        const u64* ce = specs[s].isC ? customExtWords(static_cast<const Custom*>(copy))
                                     : recordExtWords(static_cast<const Record*>(copy));
        const u64* oe = specs[s].isC ? customExtWords(static_cast<const Custom*>(orig))
                                     : recordExtWords(static_cast<const Record*>(orig));
        TEST_ASSERT(std::memcmp(ce, oe, size_t(K) * 8) == 0);
        checkWide(h, specs[s].isC, specs[s].n, "original after promote " + nameOf(specs[s]));
        Allocator::instance().getRootSet().removeRoot(&h);
    }
}

// ---------------------------------------------------------------------------
// T11
// ---------------------------------------------------------------------------
bool elmEqual(HPointer x, HPointer y) {
    return Elm_Kernel_Utils_equal(toHPtr(x), toHPtr(y)).toBits() ==
           Elm::Kernel::Export::encodeBoxedBool(true);
}

void test_equality() {
    auto& a = initAllocator();
    const u32 n = CUSTOM_MAX_FIELDS;
    HPointer x = buildWide(true, n);
    a.getRootSet().addRoot(&x);
    HPointer y = buildWide(true, n);
    a.getRootSet().addRoot(&y);
    TEST_ASSERT(elmEqual(x, y));
    const std::vector<u8> kinds = kindsPattern(n, CUSTOM_HDR_SLOTS);
    Custom* cy = static_cast<Custom*>(a.resolve(y));
    // Flip the value of the last Int slot (an ext-word slot).
    u32 lastInt = 0;
    for (u32 i = 0; i < n; ++i) if (kinds[i] == 1) lastInt = i;
    TEST_ASSERT(lastInt >= CUSTOM_HDR_SLOTS);
    cy->values[lastInt].i += 1;
    TEST_ASSERT(!elmEqual(x, y));
    cy->values[lastInt].i -= 1;
    TEST_ASSERT(elmEqual(x, y));
    // Kind only: a boxed Int slot past the header becomes a raw Int of the same
    // value (eqUnboxableSlot compares mixed kinds by value).
    u32 lastBoxed = 0;
    for (u32 i = CUSTOM_HDR_SLOTS; i < n; ++i) if (kinds[i] == 0) lastBoxed = i;
    TEST_ASSERT(lastBoxed >= CUSTOM_HDR_SLOTS);
    const u32 r = lastBoxed - CUSTOM_HDR_SLOTS;
    customExtWordsMut(cy)[r / SLOTS_PER_EXT_WORD] |= u64{1} << (2 * (r % SLOTS_PER_EXT_WORD));
    TEST_ASSERT(customSlotKind(cy, lastBoxed) == 1);
    cy->values[lastBoxed].i = 1000 + static_cast<i64>(lastBoxed);
    TEST_ASSERT(elmEqual(x, y));
    a.getRootSet().removeRoot(&y);
    a.getRootSet().removeRoot(&x);
}

// ---------------------------------------------------------------------------
// T12
// ---------------------------------------------------------------------------
std::string printed(HPointer v) {
    std::ostringstream out;
    void* prev = eco_set_output_stream(&out);
    eco_print_value(toHPtr(v));
    eco_set_output_stream(prev);
    return out.str();
}

std::string expectedSlot(u32 i, u8 kind) {
    char buf[64];
    switch (kind) {
        case 0: std::snprintf(buf, sizeof buf, "%lld", 1000LL + i); break;
        case 1: std::snprintf(buf, sizeof buf, "%lld", 3LL * i); break;
        case 2: std::snprintf(buf, sizeof buf, "%g", static_cast<double>(i) + 0.5); break;
        default: std::snprintf(buf, sizeof buf, "'%c'", static_cast<int>('a' + i % 26)); break;
    }
    return buf;
}

void test_debug_to_string() {
    initAllocator();
    {
        const u32 n = 30;
        const std::vector<u8> k = kindsPattern(n, CUSTOM_HDR_SLOTS);
        std::string want = "Ctor7 ";
        for (u32 i = 0; i < n; ++i) want += (i ? " " : "") + expectedSlot(i, k[i]);
        HPointer h = buildWide(true, n);
        TEST_ASSERT(printed(h) == want);
    }
    {
        const u32 n = 40;
        const std::vector<u8> k = kindsPattern(n, RECORD_HDR_SLOTS);
        std::string want = "{ ";
        for (u32 i = 0; i < n; ++i)
            want += (i ? ", " : "") + std::string("f") + std::to_string(i) + " = " + expectedSlot(i, k[i]);
        want += " }";
        HPointer h = buildWide(false, n);
        TEST_ASSERT(printed(h) == want);
    }
}

// ---------------------------------------------------------------------------
// T13
// ---------------------------------------------------------------------------
void expectLimitAbort(void (*body)()) {
#if defined(_WIN32)
    (void)body;
#else
    std::string err;
    const int st = runInChildCapture(body, err);
    TEST_ASSERT(abnormal(st));
    TEST_ASSERT(err.find("exceeds the wide-object limit") != std::string::npos);
#endif
}

void test_release_abort_past_limits() {
    expectLimitAbort([] {
        initAllocator();
        std::vector<Unboxable> v(CUSTOM_MAX_FIELDS + 1);
        for (auto& u : v) u.i = 1;
        (void)alloc::custom(0, v, std::vector<u8>(v.size(), 1));
    });
    expectLimitAbort([] {
        initAllocator();
        std::vector<Unboxable> v(RECORD_MAX_FIELDS + 1);
        for (auto& u : v) u.i = 1;
        (void)alloc::record(v, std::vector<u8>(v.size(), 1));
    });
    expectLimitAbort([] {
        initAllocator();
        (void)eco_alloc_record(RECORD_MAX_FIELDS + 1, 0);
    });
}

// ---------------------------------------------------------------------------
// T14
// ---------------------------------------------------------------------------
void test_small_unchanged() {
    initAllocator();
    for (u32 n = 1; n <= RECORD_HDR_SLOTS; ++n) {
        for (bool isC : {true, false}) {
            if (isC && n > CUSTOM_HDR_SLOTS) continue;
            std::vector<Unboxable> v(n);
            for (auto& u : v) u.i = 5;
            HPointer h = isC ? alloc::custom(1, v, std::vector<u8>(n, 1)) : alloc::record(v, std::vector<u8>(n, 1));
            void* obj = Allocator::instance().resolve(h);
            TEST_ASSERT(getHeader(obj)->size == n);
            TEST_ASSERT(getHeader(obj)->unboxed == 0);
            TEST_ASSERT(getObjectSize(obj) == 16 + 8 * size_t(n));
            TEST_ASSERT(wideByteSize(isC ? Tag_Custom : Tag_Record, n) == 16 + 8 * size_t(n));
        }
    }
}

} // namespace

void registerWideObjectTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase("wide: splitPhysicalSlots inverts n + extWords", test_split_inverts));
    suite.add(Testing::TestCase(
        "wide: builders and accessors round-trip (Custom 25/56/1100/2040, Record 33/64/1100/2047)",
        test_builders_round_trip));
    suite.add(Testing::TestCase("wide: survive serial minors, promotion, major and compaction", test_serial_gc));
    suite.add(Testing::TestCase("wide: parallel minor", test_parallel_minor));
    suite.add(Testing::TestCase("wide: YLOS forced (1100/2040/2047 fields)", test_ylos_forced));
    suite.add(Testing::TestCase("wide: nursery-large placement", test_nursery_large));
    suite.add(Testing::TestCase(
        "wide: region mode with concurrent tenuring and promotion_age 2 (CR-038 zap path)", test_region_k2));
    suite.add(Testing::TestCase("wide: concurrent mark t0 snapshot over a wide YLOS", test_conc_mark_wide_ylos));
    suite.add(Testing::TestCase("wide: CAF permanent copy", test_caf_permanent_copy));
    suite.add(Testing::TestCase("wide: equality", test_equality));
    suite.add(Testing::TestCase("wide: Debug.toString", test_debug_to_string));
    suite.add(Testing::TestCase("wide: release abort past limits", test_release_abort_past_limits));
    suite.add(Testing::TestCase("wide: small objects unchanged", test_small_unchanged));
}
