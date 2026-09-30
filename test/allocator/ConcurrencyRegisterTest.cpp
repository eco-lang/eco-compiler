/**
 * Regression guards for entries of plans/threaded-gc-concurrency-register.md
 * that need code-level tests (see ConcurrencyRegisterTest.hpp for the
 * expected-fail convention and ECO_TEST_XFAIL=strict).
 *
 *   CR-011  forward/BUSY word layout (MinorWork.hpp) vs Heap.hpp's bitfields.
 *   CR-017  region mode: the t0 young walk greys an old cell a STW major freed,
 *           through a dead survivor (k = 1: the hand-over extent; k = 2: an
 *           ageing extent). Expected-fail.
 *   CR-018  after the sweep, mixed-block allocations are not counted in
 *           live_bytes, so the empty-regular-block flip takes a live block.
 *           Serial. Expected-fail.
 *   CR-025  helper-job waits on GCMarkGang members are attributed to the pause.
 *   CR-029  a size-classed request that reaches the bag rung
 *           (allocateFromBagPage) gets an exact-size, black, counted object in
 *           a mixed block. Serial; the bitmap ladder (rung 7) and the legacy
 *           one (step 6). Aborted on the pre-fix assert.
 */

#include "ConcurrencyRegisterTest.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#if !defined(_WIN32)
#include <pthread.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#endif

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "GCHelperPool.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "MinorWork.hpp"
#include "NurserySpace.hpp"
#include "NurseryRegions.hpp"
#include "OldGenSpace.hpp"
#include "PageWork.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

using OA = OldGenSpaceTestAccess;
namespace mw = minorwork;

// ---------------------------------------------------------------------------
// Expected-fail harness. The scenario runs in a forked child (it may corrupt
// the heap, and a validate build may abort) and reports with its exit code.
// ---------------------------------------------------------------------------
constexpr int kCorrect = 0;       // the heap behaved correctly
constexpr int kDefect = 10;       // the scenario's own check saw the defect
constexpr int kNotReached = 11;   // a precondition of the scenario did not hold

bool xfailStrict() {
    const char* e = std::getenv("ECO_TEST_XFAIL");
    return e != nullptr && std::strcmp(e, "strict") == 0;
}

int notReached(const char* id, const char* why) {
    std::fprintf(stderr, "  %s child: scenario NOT reached: %s\n", id, why);
    return kNotReached;
}

#if !defined(_WIN32)
// Runs `scenario` in a forked child; returns the child's wait status.
int runScenarioInChild(const char* id, const std::function<int()>& scenario) {
    std::cout.flush();
    std::fflush(stdout);
    std::fflush(stderr);
    const pid_t pid = fork();
    if (pid == 0) {
        int rc = kNotReached;
        try {
            rc = scenario();
        } catch (const std::exception& e) {
            std::fprintf(stderr, "  %s child: exception: %s\n", id, e.what());
        } catch (...) {
            std::fprintf(stderr, "  %s child: unknown exception\n", id);
        }
        std::fflush(stdout);
        std::fflush(stderr);
        _exit(rc);
    }
    int st = 0;
    if (waitpid(pid, &st, 0) != pid) TEST_FAIL(std::string(id) + ": waitpid failed");
    return st;
}
#endif

void runXfailGuard(const char* id, const std::function<int()>& scenario) {
#if defined(_WIN32)
    (void)id;
    (void)scenario;   // fork-based; POSIX only
#else
    const int st = runScenarioInChild(id, scenario);
    bool defect = false;
    std::string how;
    if (WIFEXITED(st) && WEXITSTATUS(st) == kCorrect) {
        how = "the heap behaved correctly";
    } else if (WIFEXITED(st) && WEXITSTATUS(st) == kDefect) {
        defect = true;
        how = "the guard's check saw the defect";
    } else if (WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT) {
        defect = true;
        how = "the child aborted (a validator or assert saw the defect)";
    } else if (WIFEXITED(st) && WEXITSTATUS(st) == kNotReached) {
        TEST_FAIL(std::string(id) + ": the scenario did not reach the defect's precondition "
                  "(the child's message says which)");
    } else {
        TEST_FAIL(std::string(id) + ": the child died unexpectedly (wait status " +
                  std::to_string(st) + ")");
    }
    if (xfailStrict()) {
        if (defect) TEST_FAIL(std::string(id) + " reproduces: " + how);
        std::cout << "  " << id << " (strict): " << how << "\n";
        return;
    }
    if (!defect) {
        TEST_FAIL(std::string(id) + " XPASS: " + how +
                  " -- the defect looks fixed; turn this guard into a plain test");
    }
    std::cout << "  XFAIL " << id << ": " << how << " (ECO_TEST_XFAIL=strict makes it fail)\n";
#endif
}

// A guard for a FIXED entry: the scenario runs in a forked child (the pre-fix
// code may abort there) and the test passes only when the heap behaved
// correctly.
void runFixedGuard(const char* id, const std::function<int()>& scenario) {
#if defined(_WIN32)
    (void)id;
    (void)scenario;   // fork-based; POSIX only
#else
    const int st = runScenarioInChild(id, scenario);
    if (WIFEXITED(st) && WEXITSTATUS(st) == kCorrect) return;
    if (WIFEXITED(st) && WEXITSTATUS(st) == kDefect) {
        TEST_FAIL(std::string(id) + ": the guard's check failed (the child's message says which)");
    }
    if (WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT) {
        TEST_FAIL(std::string(id) + ": the child aborted (an assert or a validator fired)");
    }
    if (WIFEXITED(st) && WEXITSTATUS(st) == kNotReached) {
        TEST_FAIL(std::string(id) + ": the scenario did not reach its route "
                  "(the child's message says which precondition failed)");
    }
    TEST_FAIL(std::string(id) + ": the child died unexpectedly (wait status " +
              std::to_string(st) + ")");
#endif
}

void* allocByteBuf(Allocator& a, size_t total, uint8_t fill) {
    void* obj = a.allocate(total, Tag_ByteBuffer);
    if (obj == nullptr) throw std::runtime_error("allocByteBuf: allocation failed");
    ByteBuffer* buf = static_cast<ByteBuffer*>(obj);
    buf->header.size = static_cast<u32>(total - sizeof(ByteBuffer));
    std::memset(buf->bytes, fill, total - sizeof(ByteBuffer));
    return obj;
}

}  // namespace

// ============================================================================
// CR-011: the parallel minor's forward and BUSY words (MinorWork.hpp builds
// them from its own bit constants) decode through Heap.hpp's Forward and
// Header bitfields, and bitfield-composed words equal them. Edge addresses
// (8 and HPOINTER_ADDRESS_LIMIT - 8), every address bit set and clear, every
// colour; a published forward word is never BUSY.
// ============================================================================

Testing::TestCase testForwardWordMatchesBitfields(
    "CR-011: minorwork forward/BUSY words agree with Heap.hpp's Forward and Header bitfields",
    []() {
        static_assert(sizeof(Forward) == sizeof(uint64_t), "Forward is one word");
        static_assert(sizeof(Header) == sizeof(uint64_t), "Header is one word");
        TEST_ASSERT(mw::kTagForward == static_cast<uint64_t>(Tag_Forward));
        // The forward field spans exactly the heap's address space, so no heap
        // address (< HPOINTER_ADDRESS_LIMIT) can mask to BUSY.
        TEST_ASSERT(((mw::kFwdMask + 1) << 3) == HPOINTER_ADDRESS_LIMIT);

        const uintptr_t top = HPOINTER_ADDRESS_LIMIT - 8;
        std::vector<uintptr_t> addrs = {8, 16, 24, 0x1000, 0x123456788ULL,
                                        HPOINTER_ADDRESS_LIMIT / 2 - 8,
                                        HPOINTER_ADDRESS_LIMIT / 2, top};
        for (unsigned b = 3; b < POINTER_BITS + 3; ++b) {
            addrs.push_back(uintptr_t{1} << b);             // one address bit set
            addrs.push_back(top & ~(uintptr_t{1} << b));    // one address bit clear
        }
        const uint64_t colours[] = {static_cast<uint64_t>(Color::White),
                                    static_cast<uint64_t>(Color::Grey),
                                    static_cast<uint64_t>(Color::Black), 3};
        for (uintptr_t a : addrs) {
            for (uint64_t c : colours) {
                auto expect = [&](bool ok, const char* what) {
                    if (ok) return;
                    char msg[256];
                    std::snprintf(msg, sizeof msg, "CR-011: %s (addr 0x%llx, colour %llu)", what,
                                  static_cast<unsigned long long>(a),
                                  static_cast<unsigned long long>(c));
                    TEST_FAIL(msg);
                };
                const void* dst = reinterpret_cast<const void*>(a);
                const uint64_t w = mw::fwdWord(dst, c);
                // Decode through Heap.hpp's Forward (what every non-minorwork
                // reader of a forwarded header uses).
                Forward f;
                std::memcpy(&f, &w, sizeof w);
                expect(f.header.tag == Tag_Forward, "Forward.tag != Tag_Forward");
                expect(f.header.color == c, "Forward.color != colour");
                expect(decodeForwardPtr(f.header.forward_ptr, nullptr) == reinterpret_cast<const char*>(a),
                       "decodeForwardPtr(Forward.forward_ptr) != address");
                expect(f.header.unused == 0, "Forward.unused != 0");
                // Decode through Header (tag and colour, as the walkers read them).
                Header h;
                std::memcpy(&h, &w, sizeof w);
                expect(h.tag == Tag_Forward, "Header.tag != Tag_Forward");
                expect(h.color == c, "Header.color != colour");
                // Compose through the bitfields: the same word.
                Forward g;
                std::memset(&g, 0, sizeof g);
                g.header.tag = Tag_Forward;
                g.header.color = c;
                g.header.forward_ptr = encodeForwardPtr(const_cast<void*>(dst), nullptr);
                uint64_t gw = 0;
                std::memcpy(&gw, &g, sizeof gw);
                expect(gw == w, "bitfield-composed Forward word != mw::fwdWord");
                // minorwork's own decoders agree.
                expect(mw::isForwardWord(w), "!mw::isForwardWord");
                expect(mw::colorOf(w) == c, "mw::colorOf != colour");
                expect(mw::fwdAddr(w) == reinterpret_cast<const char*>(a), "mw::fwdAddr != address");
                // A published forward word is never BUSY (a waiter would spin forever).
                expect(w != mw::kBusy, "fwdWord == kBusy");
            }
        }
        // BUSY: Tag_Forward, colour 0, forward_ptr 0 (address 0 is never an object).
        Forward b;
        std::memcpy(&b, &mw::kBusy, sizeof b);
        TEST_ASSERT(b.header.tag == Tag_Forward);
        TEST_ASSERT(b.header.color == 0);
        TEST_ASSERT(b.header.forward_ptr == 0);
        TEST_ASSERT(b.header.unused == 0);
        TEST_ASSERT(mw::isForwardWord(mw::kBusy));
    });

// ============================================================================
// CR-018 (serial): a mixed block that was all-dead at a major and kept by the
// min_heap floor still reads fully_swept && live_bytes == 0 after small
// objects are allocated into its free runs (initObjectHeaderWithSize adds
// live_bytes only while marking or gc_phase_ != Idle), so an allocation of
// exactly alloc_buffer_size bytes flips it to a large block over them
// (allocateFromEmptyRegularBlocks).
// ============================================================================

namespace {

HeapConfig cr018Config() {
    HeapConfig cfg;
    cfg.alloc_buffer_size = 64 * 1024;
    cfg.nursery_block_count = 4;
    cfg.initial_old_gen_size = 256 * 1024;   // 4 pages: the min_heap floor keeps the block
    cfg.max_heap_size = 64ULL * 1024 * 1024;
    cfg.large_object_threshold = 8 * 1024;   // 16/32/64 KiB are mixed-only classes
    cfg.decommit_on_oldgen_release = false;
    cfg.gc_thread_mode = 0;
    cfg.incremental_mark = false;
    cfg.conc_mark = 0;
    cfg.validate();
    return cfg;
}

int cr018Scenario() {
    const char* id = "CR-018";
    const HeapConfig cfg = cr018Config();
    auto& a = initAllocator(cfg);
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    const size_t page = cfg.alloc_buffer_size;
    const size_t mid = 16 * 1024;   // > large_object_threshold: allocateFromBagPage

    // (1) A mixed block P from a fresh bag page, holding one object that dies.
    void* first = allocByteBuf(a, mid, 0x11);
    const BlockId P = OA::blockOf(og, first);
    if (!P.valid() || OA::inUniformBlock(og, first)) return notReached(id, "the first object is not in a mixed block");

    // (2) A STW major finds P all-dead; the min_heap floor keeps it. Finish the sweep.
    a.majorGC();
    OA::driveSweepToCompletion(og);
    if (!OA::blockLive(og, P)) return notReached(id, "P was released (the min_heap floor did not keep it)");
    if (OA::gcPhase(og) != GCPhase::Idle) return notReached(id, "the sweep did not complete");
    if (!OA::metaOf(og, P).fully_swept || OA::metaOf(og, P).live_bytes != 0) {
        return notReached(id, "P is not fully_swept with live_bytes == 0 after the sweep");
    }

    // (3) Small objects into P's free runs, allocated after the sweep (Idle).
    std::vector<HPointer> small(3);
    for (size_t i = 0; i < small.size(); ++i) {
        void* o = allocByteBuf(a, mid, static_cast<uint8_t>(0xA0 + i));
        small[i] = AllocatorTestAccess::toPointer(o);
        a.getRootSet().addRoot(&small[i]);
        if (OA::blockOf(og, o) != P) return notReached(id, "a small object did not land in P");
    }
    std::fprintf(stderr, "  %s child: P holds %zu live bytes; its live_bytes reads %zu\n", id,
                 small.size() * mid, static_cast<size_t>(OA::metaOf(og, P).live_bytes));

    // (4) Exactly alloc_buffer_size bytes: allocateLargeBlock -> allocateFromEmptyRegularBlocks.
    void* big = allocByteBuf(a, page, 0xEE);
    HPointer bigp = AllocatorTestAccess::toPointer(big);
    a.getRootSet().addRoot(&bigp);

    // (5) Every small object must be intact and disjoint from the big one.
    int rc = kCorrect;
    const char* blo = static_cast<const char*>(big);
    for (size_t i = 0; i < small.size(); ++i) {
        const ByteBuffer* b = static_cast<const ByteBuffer*>(AllocatorTestAccess::fromPointer(small[i]));
        const char* lo = reinterpret_cast<const char*>(b);
        bool ok = b->header.tag == Tag_ByteBuffer && b->header.size == mid - sizeof(ByteBuffer);
        for (size_t k = 0; ok && k < mid - sizeof(ByteBuffer); ++k) {
            ok = b->bytes[k] == static_cast<uint8_t>(0xA0 + i);
        }
        const bool overlap = lo < blo + page && blo < lo + mid;
        if (!ok || overlap) {
            std::fprintf(stderr, "  %s child: small object %zu at %p %s by the %zu-byte allocation at %p "
                         "(P flipped to large: %s)\n", id, i, static_cast<const void*>(lo),
                         ok ? "overlapped" : "overwritten", page, static_cast<const void*>(blo),
                         OA::blockLive(og, P) && OA::getBlockTable(og).info(P).is_large ? "yes" : "no");
            rc = kDefect;
        }
    }
    for (auto& s : small) a.getRootSet().removeRoot(&s);
    a.getRootSet().removeRoot(&bigp);
    return rc;
}

}  // namespace

Testing::TestCase testCR018EmptyBlockFlipKeepsLiveCells(
    "CR-018 [xfail CR-018]: the empty-block flip never takes a mixed block refilled after its sweep",
    []() { runXfailGuard("CR-018", cr018Scenario); });

// ============================================================================
// CR-017 (region mode, the default nursery): x -> c with c old; x dies; an
// explicit STW major frees c (it traces the nursery from roots only); the next
// minor starts a mark cycle, and its t0 young walk reads the dead x in the
// extent it lives in (k = 1: the hand-over extent; k = 2: an ageing extent) and
// greys c's freed cell. Validate builds may also abort (IM4/IM6).
// ============================================================================

namespace {

HeapConfig cr017Config(uint32_t k) {
    HeapConfig cfg;
    cfg.alloc_buffer_size = 32 * 1024;
    cfg.nursery_block_count = 64;
    cfg.nursery_max_block_count = 64;
    cfg.initial_old_gen_size = 256 * 1024;
    cfg.max_heap_size = 512ULL * 1024 * 1024;
    cfg.large_object_threshold = 8 * 1024;
    cfg.large_ptr_nursery_max_size = 8 * 1024;
    cfg.decommit_on_oldgen_release = false;
    cfg.old_gen_bitmap_alloc = true;
    cfg.gc_thread_mode = 0;
    cfg.gc_minor_threads = 1;
    cfg.minor_lab_bytes = 4096;
    cfg.minor_parallel_min_bytes = 0;
    cfg.nursery_regions = 1;
    cfg.tenure_mode = 1;
    cfg.tenure_help_threads = 1;
    cfg.promotion_age = k;
    cfg.incremental_mark = true;
    cfg.incremental_mark_slices = 4;
    cfg.incremental_mark_min_slice_units = 64;
    cfg.conc_mark = 1;
    cfg.validate();
    return cfg;
}

int cr017Scenario(uint32_t k) {
    const char* id = k == 1 ? "CR-017 (k=1)" : "CR-017 (k=2)";
    auto& a = initRegionAllocator(cr017Config(k));
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    NurserySpace& ns = h->getNursery();
    OldGenSpace& og = h->getOldGen();
    if (!ns.regionMode()) return notReached(id, "the region nursery is not active");
    auto young = [&](HPointer p) {
        return NurserySpaceTestAccess::contains(ns, AllocatorTestAccess::fromPointer(p));
    };

    // (1) c: an old object.
    HPointer c = alloc::allocInt(0x5EED17);
    a.getRootSet().addRoot(&c);
    for (int g = 0; g < 8 && young(c); ++g) a.minorGC();
    if (young(c)) return notReached(id, "c was never tenured");
    void* c_addr = AllocatorTestAccess::fromPointer(c);

    // (2) x -> c, x young: the next minor copies x into a survivor extent.
    HPointer x = alloc::tuple2(alloc::boxed(c), alloc::boxed(alloc::allocInt(1)), 0);
    a.getRootSet().addRoot(&x);
    a.getRootSet().removeRoot(&c);
    c = alloc::listNil();
    a.minorGC();
    if (!young(x)) return notReached(id, "x is not in a survivor extent");
    void* x_addr = AllocatorTestAccess::fromPointer(x);

    // (3) x dies; an explicit STW major frees c.
    a.getRootSet().removeRoot(&x);
    x = alloc::listNil();
    a.majorGC();
    OA::driveSweepToCompletion(og);
    if (og.cycleActive()) return notReached(id, "a mark cycle is active after the major");
    if (OA::isMarked(og, c_addr)) return notReached(id, "c's cell is still allocated after the major");

    // (4) Force the trigger at the next minor: its t0 walks x's extent.
    h->test_force_major_trigger_ = true;
    a.minorGC();
    if (!og.cycleActive()) return notReached(id, "the forced trigger did not start a mark cycle");
    const bool greyed = OA::isMarked(og, c_addr);
    std::fprintf(stderr, "  %s child: the t0 walk %s the freed cell of c (%p) through the dead x (%p)\n",
                 id, greyed ? "GREYED" : "left unmarked", c_addr, x_addr);
    // Run the cycle to its handoff (a validate build checks IM4/IM6 on the way).
    for (int g = 0; g < 32 && og.cycleActive(); ++g) {
        for (int i = 0; i < 2000; ++i) (void)alloc::allocInt(i);
        a.minorGC();
    }
    return greyed ? kDefect : kCorrect;
}

}  // namespace

Testing::TestCase testCR017RegionT0WalkSkipsFreedCellK1(
    "CR-017 [xfail CR-017]: region k=1, the t0 walk does not grey a cell a STW major freed (hand-over extent)",
    []() { runXfailGuard("CR-017 (k=1)", [] { return cr017Scenario(1); }); });

Testing::TestCase testCR017RegionT0WalkSkipsFreedCellK2(
    "CR-017 [xfail CR-017]: region k=2, the t0 walk does not grey a cell a STW major freed (ageing extent)",
    []() { runXfailGuard("CR-017 (k=2)", [] { return cr017Scenario(2); }); });

// ============================================================================
// CR-025: a GCMarkGang member has no ThreadLocalHeap, but every gang run is
// inside a GC pause (HEAP_058), so a helper-job wait it makes (the parallel
// minor's or the pause tenure engine's, under promo_mu_: CR-007's routes) is
// a pause stall. Allocator::callerInPause() is the in_pause value those waits
// pass to GCHelperPool::wait / noteStall (stall_outside_pause) and to the
// PageWork stall hook (the MMU stall list).
// ============================================================================

Testing::TestCase testCR025GangMemberStallInPause(
    "CR-025: a GCMarkGang member counts as inside the pause for helper-job stall accounting",
    []() {
        auto& a = initAllocator();
        gc::GCMarkGang& gang = gc::GCMarkGang::instance();
        if (!gang.configured()) gang.configure(2, 0);
        if (gang.members() < 2) {
            std::cout << "  (skipped: the mark gang has a single member)\n";
            return;
        }
        struct Ctx {
            Allocator* a;
            int member = -1, member_flag = -1, caller = -1, caller_flag = -1;
        } ctx{&a};
        gang.run(
            [](void* p, unsigned m) {
                Ctx& c = *static_cast<Ctx*>(p);
                if (m == 1) {
                    c.member = AllocatorTestAccess::callerInPause(*c.a) ? 1 : 0;
                    c.member_flag = gc::GCMarkGang::onMemberRun() ? 1 : 0;
                } else {
                    c.caller = AllocatorTestAccess::callerInPause(*c.a) ? 1 : 0;
                    c.caller_flag = gc::GCMarkGang::onMemberRun() ? 1 : 0;
                }
            },
            &ctx, 2);
        TEST_ASSERT(ctx.member_flag == 1);
        TEST_ASSERT(ctx.member == 1);        // the fix: in the pause although tl_heap_ is null
        TEST_ASSERT(ctx.caller_flag == 0);   // worker 0 is the caller: its heap decides
        TEST_ASSERT(ctx.caller == 0);        // (this test's heap is not in a pause)
        int other = -1;
        std::thread t([&] { other = AllocatorTestAccess::callerInPause(a) ? 1 : 0; });
        t.join();
        TEST_ASSERT(other == 0);             // neither a heap nor a gang member
    });

// ============================================================================
// CR-029 (serial): a size-classed request that reaches the bag rung
// (allocateFromBagPage) gets a correct object. The rung's assert used to forbid
// such a request; it now states the real precondition (8-byte aligned, below
// alloc_buffer_size), and on the pre-fix code this scenario aborts in the child.
//
// Route (bitmap: allocateFromSizeClassBitmap rung 7; legacy:
// allocateFromSizeClass step 6): the old-gen reservation is exhausted and the
// bag is empty, so the virgin-block / populateFromBlock rung fails, while a
// lazy sweep is pending and a dead 16 KiB object D is the third sweep slice
// ahead, at the end of mixed block M. With sweep budgets of 8 bytes a slice
// sweeps one object: allocate()'s up-front slice and the sweep-on-demand rung
// each sweep a live object, and the bag rung's step 2 sweeps D and carves the
// request (6000 bytes, in the 8 KiB class) out of D's cell. The carve is
// mid-sweep, so the object must be black and counted in M's live_bytes with
// its own size (not the class's 8 KiB); M must parse by object size, and the
// next major must attribute exactly the object's size.
// ============================================================================

namespace {

HeapConfig cr029Config(bool bitmap) {
    HeapConfig cfg;
    cfg.alloc_buffer_size = 64 * 1024;
    cfg.nursery_block_count = 4;
    cfg.initial_old_gen_size = 256 * 1024;
    cfg.max_heap_size = 64ULL * 1024 * 1024;
    cfg.large_object_threshold = 8 * 1024;   // size classes up to 8 KiB; 16/32/64 KiB are mixed-only
    cfg.decommit_on_oldgen_release = false;
    cfg.old_gen_bitmap_alloc = bitmap;
    cfg.gc_thread_mode = 0;
    cfg.gc_mark_threads = 1;
    cfg.incremental_mark = false;
    cfg.conc_mark = 0;
    // A sweep slice stops once it has covered 8 bytes: one object per slice.
    cfg.sweep_work_budget = 8;
    cfg.initial_sweep_budget = 8;
    cfg.max_sweep_bytes_per_alloc = 8;
    cfg.max_sweep_bytes_hard = 8;
    cfg.validate();
    return cfg;
}

// A ByteBuffer of `total` bytes allocated straight in the old gen (the
// mutator's OldGenSpace::allocate), filled with `fill`.
void* oldByteBuf(OldGenSpace& og, size_t total, uint8_t fill) {
    void* obj = og.allocate(total);
    if (obj == nullptr) throw std::runtime_error("oldByteBuf: allocation failed");
    ByteBuffer* buf = static_cast<ByteBuffer*>(obj);
    buf->header.tag = Tag_ByteBuffer;
    buf->header.size = static_cast<u32>(total - sizeof(ByteBuffer));
    std::memset(buf->bytes, fill, total - sizeof(ByteBuffer));
    return obj;
}

bool byteBufIntact(const void* obj, size_t total, uint8_t fill) {
    const ByteBuffer* b = static_cast<const ByteBuffer*>(obj);
    if (b->header.tag != Tag_ByteBuffer || b->header.size != total - sizeof(ByteBuffer)) return false;
    for (size_t k = 0; k < total - sizeof(ByteBuffer); ++k) {
        if (b->bytes[k] != fill) return false;
    }
    return true;
}

// Walks a mixed block by object size, as the sweep does: every step positive,
// `obj` an object boundary, and the walk ends exactly at end_of_objects.
bool mixedBlockParses(OldGenSpace& og, BlockId id, const void* obj) {
    const BlockInfo& b = OA::getBlockTable(og).info(id);
    bool hit = false;
    char* q = b.start;
    while (q < b.end_of_objects) {
        const size_t step = getObjectSize(q);
        if (step == 0 || q + step > b.end_of_objects) return false;
        if (q == obj) hit = true;
        q += step;
    }
    return hit && q == b.end_of_objects;
}

int cr029Scenario(bool bitmap) {
    const char* id = bitmap ? "CR-029 (bitmap rung 7)" : "CR-029 (legacy step 6)";
    auto& a = initAllocator(cr029Config(bitmap));
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    constexpr size_t kObj = 16 * 1024;   // a mixed-only class's cell: four fill a page
    constexpr size_t kReq = 6000;        // size-classed, well below its 8 KiB cell
    const size_t cls = OA::sizeClass(kReq);
    if (cls >= OA::numSizeClasses(og) || OA::classToSize(cls) <= kReq) {
        return notReached(id, "the request is not a size-classed one below its cell size");
    }

    // (1) Eight 16 KiB objects (the (LOT, page) band: the bag path) fill two
    //     mixed blocks. M is the first of them in sweep order.
    struct Obj { void* p; uint8_t fill; };
    std::vector<Obj> objs;
    std::vector<BlockId> blocks;
    for (int i = 0; i < 8; ++i) {
        const uint8_t fill = static_cast<uint8_t>(0x40 + i);
        void* p = oldByteBuf(og, kObj, fill);
        const BlockId b = OA::blockOf(og, p);
        if (!b.valid() || OA::inUniformBlock(og, p)) return notReached(id, "an object is not in a mixed block");
        if (std::find(blocks.begin(), blocks.end(), b) == blocks.end()) blocks.push_back(b);
        objs.push_back({p, fill});
    }
    if (blocks.size() != 2) return notReached(id, "the eight objects are not in two blocks");
    BlockId M = NO_BLOCK_ID;
    for (size_t pos = 0; pos < OA::blockCount(og) && !M.valid(); ++pos) {
        const BlockId b = OA::blockIdAt(og, pos);
        if (b == blocks[0] || b == blocks[1]) M = b;
    }
    std::vector<char*> m;   // M's objects by address
    for (const Obj& o : objs) {
        if (OA::blockOf(og, o.p) == M) m.push_back(static_cast<char*>(o.p));
    }
    std::sort(m.begin(), m.end());
    const BlockInfo& mi = OA::getBlockTable(og).info(M);
    if (m.size() != 4 || m[0] != mi.start || m[1] != m[0] + kObj || m[2] != m[1] + kObj ||
        m[3] != m[2] + kObj || mi.end_of_objects != m[3] + kObj) {
        return notReached(id, "M is not four contiguous 16 KiB objects from its start");
    }
    char* const D = m[3];

    // (2) D dies; everything else stays rooted (the other block keeps the
    //     sweep pending after M, so the carve is mid-sweep). A STW major.
    std::vector<HPointer> roots;
    std::vector<Obj> live;
    roots.reserve(objs.size());
    for (const Obj& o : objs) {
        if (o.p == D) continue;
        live.push_back(o);
        roots.push_back(AllocatorTestAccess::toPointer(o.p));
    }
    for (auto& r : roots) a.getRootSet().addRoot(&r);
    a.majorGC();
    if (OA::gcPhase(og) != GCPhase::Sweeping || OA::metaOf(og, M).fully_swept) {
        return notReached(id, "the major left no pending sweep of M");
    }

    // (3) Stop the sweep at M's second object: the next three slices sweep
    //     m[1], m[2] and D.
    for (int g = 0; OA::getSweepCursor(og) != m[1]; ++g) {
        if (g > 100000 || OA::metaOf(og, M).fully_swept || !OA::hasPendingSweepWork(og)) {
            return notReached(id, "the sweep could not be stopped at M's second object");
        }
        OA::lazySweep(og, NUM_SIZE_CLASSES, 8);
    }

    // (4) Growth impossible: take every page the reservation has left, and
    //     empty the bag (the pages stay committed and unused).
    AllocatorTestAccess::ensureOldGenCapacityFor(a, og, SIZE_MAX);
    OA::drainUnassignedBlocksForTest(og);
    AllocatorTestAccess::ensureOldGenCapacityFor(a, og, SIZE_MAX);
    if (!OA::getUnassignedBlocks(og).empty()) return notReached(id, "acquireOldGenBlock still grants pages");
    for (size_t c = cls; c < NUM_SIZE_CLASSES; ++c) {
        if (OA::getFreeList(og, c) != nullptr) return notReached(id, "a free cell of the class or larger exists");
    }
    if (bitmap && (OA::cursorBlock(og, cls).valid() || OA::partialQueueLength(og, cls) != 0)) {
        return notReached(id, "a uniform block of the class has free cells");
    }

    // (5) The request. Pre-fix code: allocateFromBagPage's assert aborts here.
#if ENABLE_GC_STATS
    const BitmapAllocStats bm0 = OA::bitmapStats(og);
#endif
    const uint64_t live0 = OA::metaOf(og, M).live_bytes;
    const size_t alloc0 = OA::allocatedBytes(og);
    void* r = og.allocate(kReq);
    if (r == nullptr) {
        std::fprintf(stderr, "  %s child: the request failed (nullptr)\n", id);
        return kDefect;
    }
    if (OA::gcPhase(og) != GCPhase::Sweeping) return notReached(id, "the sweep completed inside the request");
    int rc = kCorrect;
    auto check = [&](bool ok, const char* what) {
        if (ok) return;
        std::fprintf(stderr, "  %s child: %s\n", id, what);
        rc = kDefect;
    };
    check(r == D, "the object is not carved from D's cell (the bag rung's step 2)");
    check(OA::blockOf(og, r) == M && !OA::inUniformBlock(og, r), "the object is not in mixed block M");
    check(getHeader(r)->color == static_cast<u32>(Color::Black), "the mid-sweep object is not black");
    check(OA::isMarked(og, r), "the mid-sweep object's mark bit is clear");
    check(OA::metaOf(og, M).live_bytes - live0 == kReq,
          "M's live_bytes did not grow by exactly the request (an exact-size carve)");
    check(OA::allocatedBytes(og) - alloc0 == kReq, "allocated_bytes did not grow by exactly the request");
#if ENABLE_GC_STATS
    if (bitmap) {
        const BitmapAllocStats& bm = OA::bitmapStats(og);
        check(bm.split_allocs == bm0.split_allocs && bm.sweep_on_demand_hits == bm0.sweep_on_demand_hits &&
              bm.virgin_blocks == bm0.virgin_blocks && bm.list_pops == bm0.list_pops,
              "a rung above the bag rung served the request");
    }
#endif

    // (6) Usable: a ByteBuffer of exactly kReq bytes, and M parses around it.
    ByteBuffer* rb = static_cast<ByteBuffer*>(r);
    rb->header.tag = Tag_ByteBuffer;
    rb->header.size = static_cast<u32>(kReq - sizeof(ByteBuffer));
    std::memset(rb->bytes, 0xC9, kReq - sizeof(ByteBuffer));
    check(getObjectSize(r) == kReq, "the object does not report the requested size");
    check(mixedBlockParses(og, M, r), "M does not parse by object size around the object");
    roots.push_back(AllocatorTestAccess::toPointer(r));   // reserved: no reallocation
    a.getRootSet().addRoot(&roots.back());
    live.push_back({r, 0xC9});

    // (7) Finish the sweep, then a major: the mark attributes the object's own
    //     size to M, and every object survives intact.
    OA::driveSweepToCompletion(og);
    a.majorGC();
    OA::driveSweepToCompletion(og);
    check(OA::metaOf(og, M).live_bytes == 3 * kObj + kReq,
          "the next major did not attribute exactly M's objects' own sizes");
    for (size_t i = 0; i < live.size(); ++i) {
        void* p = AllocatorTestAccess::fromPointer(roots[i]);
        const size_t total = (live[i].p == r) ? kReq : kObj;
        check(byteBufIntact(p, total, live[i].fill), "an object did not survive intact");
    }
    for (auto& h : roots) a.getRootSet().removeRoot(&h);
    return rc;
}

}  // namespace

Testing::TestCase testCR029BagRungSizeClassedBitmap(
    "CR-029: a size-classed request at the bag rung gets an exact-size black object (bitmap ladder, rung 7)",
    []() { runFixedGuard("CR-029 (bitmap rung 7)", [] { return cr029Scenario(true); }); });

Testing::TestCase testCR029BagRungSizeClassedLegacy(
    "CR-029: a size-classed request at the bag rung gets an exact-size black object (legacy ladder, step 6)",
    []() { runFixedGuard("CR-029 (legacy step 6)", [] { return cr029Scenario(false); }); });

// ============================================================================
// plans/threaded-gc-register-repros-impl.md, Phases A and B: expected-fail
// guards for the TLA+ findings (CR-014, CR-001, CR-016, CR-028, CR-037,
// CR-017 R1/R2, CR-007, CR-023, CR-012). Phase A drives the promotion workers
// from ONE thread (og.promoCtx(), allocatePromotion(ctx.w[i], ...)), so every
// interleaving is exact; Phase B latches real threads.
// ============================================================================

namespace {

constexpr size_t kEq = 12816;   // 16 + 8*1600 == 8 + 2*6404 (ElmArray n=1600, ElmString L=6404)

// A promotion cell handed out outside a minor must parse: a ByteBuffer.
void formatAsBytes(void* p, size_t sz) {
    std::memset(p, 0, sz);
    Header* h = getHeader(p);
    h->tag = Tag_ByteBuffer;
    h->size = static_cast<u32>(sz - sizeof(ByteBuffer));
}

void* promo(OldGenSpace& og, OldGenSpace::PromoWorker& w, size_t sz, uint8_t fill = 0) {
    void* p = og.allocatePromotion(w, sz, false);
    if (p == nullptr) throw std::runtime_error("promo: nullptr");
    formatAsBytes(p, sz);
    std::memset(static_cast<ByteBuffer*>(p)->bytes, fill, sz - sizeof(ByteBuffer));
    return p;
}

// CR-014 / CR-001 / CR-028: one-thread sweep-and-promotion geometry.
HeapConfig tailConfig(size_t lot, size_t sweep, double demote) {
    HeapConfig cfg;
    cfg.alloc_buffer_size = 64 * 1024;
    cfg.nursery_block_count = 4;
    cfg.initial_old_gen_size = 256 * 1024;   // the floor keeps all-dead blocks at the major
    cfg.max_heap_size = 64ULL << 20;
    cfg.large_object_threshold = lot;
    cfg.decommit_on_oldgen_release = false;
    cfg.old_gen_bitmap_alloc = true;
    cfg.gc_thread_mode = 0;
    cfg.commit_ahead_bytes = 0;
    cfg.gc_mark_threads = 1;
    cfg.incremental_mark = false;
    cfg.conc_mark = 0;
    cfg.small_class_heap_budget_bytes = 0;   // no bag-first rung
    cfg.demote_live_fraction = demote;
    cfg.minor_sweep_divisor = 0;
    cfg.sweep_work_budget = cfg.initial_sweep_budget = sweep;
    cfg.max_sweep_bytes_per_alloc = cfg.max_sweep_bytes_hard = sweep;
    cfg.validate();
    return cfg;
}

bool noMixedOnlyCells(const OldGenSpace& og) {   // W2's split rung must fail
    for (size_t c = OA::numSizeClasses(og); c < NUM_SIZE_CLASSES; ++c)
        if (OA::getFreeList(og, c) != nullptr) return false;
    return true;
}

bool sweepTo(OldGenSpace& og, const char* at) {
    for (int g = 0; OA::getSweepCursor(og) != at; ++g) {
        if (g > 1000 || !OA::hasPendingSweepWork(og)) return false;
        OA::lazySweep(og, NUM_SIZE_CLASSES, 8);
    }
    return true;
}

// Grows the bag (opens the light-shrink gate); call AFTER the major.
bool grewBag(Allocator& a, OldGenSpace& og) {
    const size_t n0 = OA::getUnassignedBlocks(og).size();
    AllocatorTestAccess::ensureOldGenCapacityFor(a, og, 512 * 1024);
    return OA::getUnassignedBlocks(og).size() >= n0 + 4;
}

// For a guard whose defect is a VALUE (not an abort): an abort in the child
// is an unrelated failure, so it reports "not reached" instead of letting
// runXfailGuard count the SIGABRT as the defect.
void valueGuardOnAbort(int) {
    static const char msg[] = "  child: unexpected abort (not this guard's defect): scenario NOT reached\n";
    (void)!write(2, msg, sizeof msg - 1);
    _exit(kNotReached);
}
void abortMeansNotReached() {
    struct sigaction sa{};
    sa.sa_handler = valueGuardOnAbort;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGABRT, &sa, nullptr);
}

void dumpBlocks(const char* id, OldGenSpace& og) {
    std::fprintf(stderr, "  %s child: phase %d cursor %p idx %zu/%zu bag %zu\n", id,
                 static_cast<int>(OA::gcPhase(og)), static_cast<const void*>(OA::getSweepCursor(og)),
                 OA::getSweepBufferIndex(og), OA::blockCount(og), OA::getUnassignedBlocks(og).size());
    for (size_t pos = 0; pos < OA::blockCount(og); ++pos) {
        const BlockId b = OA::blockIdAt(og, pos);
        const BlockInfo& i = OA::getBlockTable(og).info(b);
        const BufferMetadata& m = OA::metaOf(og, b);
        std::fprintf(stderr, "    pos %zu id %u start %p len %zu eoo %zu cls %zu large %d st %u live %zu swept %d demoted %d\n",
                     pos, b.v, static_cast<void*>(i.start), i.totalBytes(),
                     static_cast<size_t>(i.end_of_objects - i.start), i.size_class, (int)i.is_large,
                     (unsigned)i.alloc_state, m.live_bytes, (int)m.fully_swept, (int)OA::demoted(og, b));
    }
}

}  // namespace

// ----------------------------------------------------------------------------
// Step 5: CR-014 A. The tail completion (lazySweep's path 3) runs
// onSweepComplete inside a parallel minor; the light shrink's pass 1 releases
// a worker's Current block with live_bytes 0 -> detachFromAllocation FATAL.
// ----------------------------------------------------------------------------

namespace {

int cr014A(unsigned n) {
    const char* id = n == 1 ? "CR-014 A (N=1)" : "CR-014 A (N=2)";
    auto& a = initAllocator(tailConfig(8 * 1024, 8, 0.0));
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    void* v = og.allocate(32);   // V: a class-32 virgin block, unrooted
    formatAsBytes(v, 32);
    const BlockId V = OA::blockOf(og, v);
    std::vector<char*> m;
    for (int i = 0; i < 4; ++i) m.push_back(static_cast<char*>(oldByteBuf(og, 16 * 1024, static_cast<uint8_t>(0x40 + i))));
    std::sort(m.begin(), m.end());
    std::vector<HPointer> roots;
    for (char* p : m) roots.push_back(AllocatorTestAccess::toPointer(p));
    for (auto& r : roots) a.getRootSet().addRoot(&r);
    const BlockId M = OA::blockOf(og, m[0]);
    const BlockInfo& mi = OA::getBlockTable(og).info(M);
    if (!OA::inUniformBlock(og, v) || OA::blockCount(og) != 2 || OA::blockIdAt(og, 1) != M ||
        m[0] != mi.start || m[3] != m[0] + 3 * 16384 || mi.end_of_objects != m[3] + 16384) {
        dumpBlocks(id, og);
        return notReached(id, "layout is not [V][M = four packed 16 KiB objects]");
    }
    a.majorGC();
    if (!OA::blockLive(og, V) || OA::allocState(og, V) != 1 ||
        OA::partialFront(og, OA::sizeClass(32)) != V || OA::blockIdAt(og, OA::blockCount(og) - 1) != M) {
        dumpBlocks(id, og);
        return notReached(id, "V is not live and Queued, or M is not last");
    }
    if (!sweepTo(og, m[3])) { dumpBlocks(id, og); return notReached(id, "could not stop the sweep at m[3]"); }
    if (!grewBag(a, og)) return notReached(id, "the bag did not grow (the light gate stays shut)");
    if (OA::getFreeList(og, OA::sizeClass(64)) != nullptr || !noMixedOnlyCells(og))
        return notReached(id, "W2 would be served before sweep-on-demand");
    auto& ctx = og.promoCtx();
    og.beginParallelPromotion(ctx, n);
    void* p1 = promo(og, ctx.w[0], 32);   // W1: publishes V, takes a cell
    if (OA::blockOf(og, p1) != V || OA::allocState(og, V) != 2 || OA::metaOf(og, V).live_bytes != 0 ||
        OA::blockCount(og) != 2) {
        dumpBlocks(id, og);
        return notReached(id, "V is not Current with live_bytes 0, or a block was created");
    }
    std::fprintf(stderr, "  %s child: V (block %u) is w[0]'s Current block; w[%u] promotes 64 B "
                 "(the sweep's last slice: the tail completion)\n", id, V.v, n - 1);
    promo(og, ctx.w[n - 1], 64);   // today: tail path -> light shrink pass 1 -> detach(V) -> FATAL
    if (OA::gcPhase(og) != GCPhase::Idle) { dumpBlocks(id, og); return notReached(id, "W2 did not complete the sweep"); }
    int rc = OA::blockLive(og, V) && OA::blockOf(og, p1) == V ? kCorrect : kDefect;
    og.endParallelPromotion(ctx);
    if (!OA::blockLive(og, V) || !OA::allocStateConsistent(og)) rc = kDefect;
    for (auto& r : roots) a.getRootSet().removeRoot(&r);
    return rc;
}

}  // namespace

Testing::TestCase testCR014TailShrinkN2(
    "CR-014 [xfail CR-014]: the tail completion never shrinks under a worker's Current block (A, N=2)",
    []() { runXfailGuard("CR-014 A (N=2)", [] { return cr014A(2); }); });

Testing::TestCase testCR014TailShrinkN1(
    "CR-014 [xfail CR-014]: the tail completion never shrinks under a worker's Current block (A, N=1)",
    []() { runXfailGuard("CR-014 A (N=1)", [] { return cr014A(1); }); });

// ----------------------------------------------------------------------------
// Steps 6-7: CR-014 B and CR-001. Layout [D][D'][M]: D and D' are demoted,
// all-dead uniform blocks of 24 B and 40 B cells (each 65,520-byte gap packs
// into 32K + 16K + 8K + ... cells, one 8 KiB cell each), M a bag page with one
// live 40 KiB object and a 24 KiB tail gap. W1's batch pop finalizes the
// D'-cell and stashes the D-cell; W2's slice completes the sweep.
// ----------------------------------------------------------------------------

namespace {

struct DPair {
    BlockId D, Dp, M, Lg;
    char *Dstart, *Dcell, *Dpcell;
    std::vector<HPointer> roots;
};

// leadLarge (CR-014 C): an exact-size large block Lg is materialised FIRST (the
// lowest position, dies at the major), and the bag is emptied before the
// major, so the floor (256 K == Lg + D + D' + M) still keeps D and D'.
int buildDPair(Allocator& a, OldGenSpace& og, const char* id, DPair& L, bool leadLarge = false) {
    const size_t base = leadLarge ? 1 : 0;
    if (leadLarge) {
        char* lg = static_cast<char*>(oldByteBuf(og, 64 * 1024, 0x16));   // allocateLargeBlock
        L.Lg = OA::blockOf(og, lg);
        if (!L.Lg.valid() || !OA::getBlockTable(og).info(L.Lg).is_large || OA::blockCount(og) != 1 ||
            OA::getBlockTable(og).info(L.Lg).totalBytes() != 64 * 1024) {
            dumpBlocks(id, og);
            return notReached(id, "the leading 64 KiB object is not alone in an is_large block");
        }
    }
    void* d = og.allocate(24);    // D : class-24 virgin block, dies
    formatAsBytes(d, 24);
    void* dp = og.allocate(40);   // D': class-40 virgin block, dies
    formatAsBytes(dp, 40);
    char* mo = static_cast<char*>(oldByteBuf(og, 40 * 1024, 0x4D));   // M: bag page [40K obj][24K gap]
    L.D = OA::blockOf(og, d);
    L.Dp = OA::blockOf(og, dp);
    L.M = OA::blockOf(og, mo);
    if (OA::blockCount(og) != 3 + base || OA::blockIdAt(og, base) != L.D || OA::blockIdAt(og, base + 1) != L.Dp ||
        OA::blockIdAt(og, base + 2) != L.M || mo != OA::getBlockTable(og).info(L.M).start) {
        dumpBlocks(id, og);
        return notReached(id, leadLarge ? "layout is not [Lg][D][D'][M]" : "layout is not [D][D'][M]");
    }
    if (leadLarge) OA::drainUnassignedBlocksForTest(og);   // the floor must see exactly Lg + D + D' + M
    L.roots.reserve(4);
    L.roots.push_back(AllocatorTestAccess::toPointer(mo));
    a.getRootSet().addRoot(&L.roots[0]);
    a.majorGC();   // the initial slice sweeps all of D
    if (!OA::blockLive(og, L.D) || !OA::blockLive(og, L.Dp) || !OA::demoted(og, L.D) ||
        !OA::demoted(og, L.Dp) || OA::metaOf(og, L.D).live_bytes != 0 || !OA::metaOf(og, L.D).fully_swept) {
        dumpBlocks(id, og);
        return notReached(id, "D/D' not kept by the floor, demoted, D swept and all-dead");
    }
    OA::lazySweep(og, NUM_SIZE_CLASSES, 8);   // D' (one whole gap)
    OA::lazySweep(og, NUM_SIZE_CLASSES, 8);   // M's object
    if (OA::getSweepCursor(og) != mo + 40 * 1024) {
        dumpBlocks(id, og);
        return notReached(id, "the sweep cursor is not at M's tail gap");
    }
    L.Dstart = OA::getBlockTable(og).info(L.D).start;
    L.Dcell = L.Dstart + 48 * 1024;
    L.Dpcell = OA::getBlockTable(og).info(L.Dp).start + 48 * 1024;
    FreeCell* h = OA::getFreeList(og, OA::sizeClass(8192));
    if (reinterpret_cast<char*>(h) != L.Dpcell || h->next_in_class == nullptr ||
        reinterpret_cast<char*>(h->next_in_class) != L.Dcell || h->next_in_class->next_in_class != nullptr) {
        std::fprintf(stderr, "  %s child: 8K list head %p next %p (D' cell %p, D cell %p)\n", id,
                     static_cast<void*>(h), h ? static_cast<void*>(h->next_in_class) : nullptr,
                     static_cast<void*>(L.Dpcell), static_cast<void*>(L.Dcell));
        return notReached(id, "free_lists_[8K] is not [D'-cell, D-cell]");
    }
    if (OA::getFreeList(og, OA::sizeClass(64)) != nullptr || !noMixedOnlyCells(og))
        return notReached(id, "W2 would not reach sweep-on-demand");
    if (leadLarge) {   // region = [4 initial pages][Lg]: grow it by four pages
        const size_t n0 = OA::getUnassignedBlocks(og).size();
        AllocatorTestAccess::ensureOldGenCapacityFor(a, og, 9 * 64 * 1024);
        if (OA::getUnassignedBlocks(og).size() < n0 + 4) return notReached(id, "the bag did not grow");
    } else if (!grewBag(a, og)) {
        return notReached(id, "the bag did not grow");
    }
    return kCorrect;
}

int cr014B() {
    const char* id = "CR-014 B";
    auto& a = initAllocator(tailConfig(32 * 1024, 8, 0.5));
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    DPair L;
    if (int rc = buildDPair(a, og, id, L)) return rc;
    const size_t c8 = OA::sizeClass(8192);
    auto& ctx = og.promoCtx();
    og.beginParallelPromotion(ctx, 2);
    auto &w1 = ctx.w[1], &w2 = ctx.w[0];
    void* p1 = promo(og, w1, 8192, 0xD1);   // batch pop: finalizes the D'-cell (Sweeping), stashes the D-cell
    if (p1 != L.Dpcell || w1.stash_n[c8] != 1 || reinterpret_cast<char*>(w1.stash[c8][0]) != L.Dcell ||
        OA::metaOf(og, L.D).live_bytes != 0 || OA::gcPhase(og) != GCPhase::Sweeping)
        return notReached(id, "W1's batch pop did not stash D's cell");
    void* p2 = promo(og, w2, 64);   // one 8-byte slice: M's 24K gap -> the tail path
    if (OA::gcPhase(og) != GCPhase::Idle) { dumpBlocks(id, og); return notReached(id, "W2 did not complete the sweep"); }
    if (OA::sweepCompleteDeferred(og)) return notReached(id, "the completion was in-loop (deferred), not the tail");
    const bool dOk = OA::blockLive(og, L.D) && OA::getBlockTable(og).info(L.D).start == L.Dstart;
    if (!dOk) {
        std::fprintf(stderr, "  %s child: D released inside the minor; W1's stash still holds %p; "
                     "D's id now names %s (p2 %p)\n", id, static_cast<void*>(L.Dcell),
                     OA::blockLive(og, L.D) ? "another block" : "nothing", p2);
        return kDefect;   // do NOT pop the stash: it would write released memory
    }
    return kCorrect;
}

int cr001(bool releaseArm) {
    const char* id = releaseArm ? "CR-001 (b)" : "CR-001 (a)";
    auto& a = initAllocator(tailConfig(32 * 1024, 32 * 1024, 0.5));
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    DPair L;
    if (int rc = buildDPair(a, og, id, L)) return rc;
    const size_t c8 = OA::sizeClass(8192);
    auto& ctx = og.promoCtx();
    og.beginParallelPromotion(ctx, 2);
    auto &w1 = ctx.w[1], &w2 = ctx.w[0];
    void* p1 = promo(og, w1, 8192, 0xD1);
    if (p1 != L.Dpcell || w1.stash_n[c8] != 1 || OA::metaOf(og, L.D).live_bytes != 0)
        return notReached(id, "W1 did not stash D's cell");
    promo(og, w2, 64);   // the in-loop completion -> deferred
    if (OA::gcPhase(og) != GCPhase::Idle || !OA::sweepCompleteDeferred(og))
        return notReached(id, "the completion was not in-loop and deferred (tail path? budgets)");
    if (!OA::blockLive(og, L.D) || OA::getBlockTable(og).info(L.D).start != L.Dstart)
        return notReached(id, "D was released before W1's finalize");
    void* p3 = promo(og, w1, 8192, 0xC1);   // stash pop: the finalize reads Idle
    if (p3 != L.Dcell) return notReached(id, "W1 did not take its stashed D cell");
    if (!releaseArm) {
        const uint64_t lb = OA::metaOf(og, L.D).live_bytes;
        std::fprintf(stderr, "  %s child: D holds an 8 KiB promotion; live_bytes reads %llu\n", id,
                     static_cast<unsigned long long>(lb));
        return lb == 0 ? kDefect : kCorrect;
    }
    og.endParallelPromotion(ctx);   // the deferred onSweepComplete: light pass 1
    if (!OA::blockLive(og, L.D) || OA::getBlockTable(og).info(L.D).start != L.Dstart) {
        std::fprintf(stderr, "  %s child: D released with the promoted object %p in it\n", id, p3);
        return kDefect;
    }
    return byteBufIntact(p3, 8192, 0xC1) ? kCorrect : kDefect;
}

// CR-014 C (M4 MC_quick_sweep_tail_reuse, NoDoubleAlloc): B's release, then
// the virgin rung re-issues D's id AND start, and W1's stashed cell of the old
// D is handed out a second time. Why a leading large block Lg: with only the
// floor keeping D alive at the major, the light shrink's pass 3 always leaves
// bag pages (the heap may not drop below the floor), so the first virgin after
// the release takes a bag page and D's id (B's partial ABA). Lg is released in
// the same shrink (pass 2) AFTER D (descending position), so Lg's id is on top
// of the LIFO id stack and D's extent is first on old_gen_free_blocks_: the
// completing worker's own virgin takes Lg's id at a bag page; once the bag is
// empty (the test drains it: allocations would consume ids), the next virgin
// acquires D's extent first-fit AND gets D's id.
int cr014C() {
    const char* id = "CR-014 C";
    abortMeansNotReached();   // a value oracle up to the stash pop
    auto& a = initAllocator(tailConfig(32 * 1024, 8, 0.5));
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    DPair L;
    if (int rc = buildDPair(a, og, id, L, /*leadLarge=*/true)) return rc;
    const BlockTable& bt = OA::getBlockTable(og);
    if (!OA::blockLive(og, L.Lg) || !bt.info(L.Lg).is_large || OA::metaOf(og, L.Lg).live_bytes != 0 ||
        !OA::metaOf(og, L.Lg).fully_swept) {
        dumpBlocks(id, og);
        return notReached(id, "Lg is not a live, fully swept, all-dead is_large block after the major");
    }
    char* const heapBase = AllocatorTestAccess::getHeapBase(a);
    if (L.Dstart == heapBase) return notReached(id, "D sits at heap_base (never reused for a page)");
    if (!AllocatorTestAccess::freeBlocks(a).empty()) return notReached(id, "the released-extent list is not empty");
    const size_t c8 = OA::sizeClass(8192);
    auto& ctx = og.promoCtx();
    og.beginParallelPromotion(ctx, 2);
    auto &w1 = ctx.w[1], &w2 = ctx.w[0];
    void* p1 = promo(og, w1, 8192, 0xD1);   // batch pop: finalizes the D'-cell, stashes the D-cell
    if (p1 != L.Dpcell || w1.stash_n[c8] != 1 || reinterpret_cast<char*>(w1.stash[c8][0]) != L.Dcell ||
        OA::metaOf(og, L.D).live_bytes != 0 || OA::gcPhase(og) != GCPhase::Sweeping)
        return notReached(id, "W1's batch pop did not stash D's cell");
    void* p2 = promo(og, w2, 64, 0xB2);   // one 8-byte slice: M's 24K gap -> the tail path
    if (OA::gcPhase(og) != GCPhase::Idle) { dumpBlocks(id, og); return notReached(id, "W2 did not complete the sweep"); }
    if (OA::sweepCompleteDeferred(og)) return notReached(id, "the completion was in-loop (deferred), not the tail");
    // The release (CR-014 B's state) and the order the re-issue depends on.
    if (OA::blockLive(og, L.D) && bt.info(L.D).start == L.Dstart)
        return notReached(id, "D was not released inside the minor");
    const auto& fb = AllocatorTestAccess::freeBlocks(a);
    const char* firstFit = nullptr;
    for (const auto& e : fb) {
        if (e.first != heapBase && e.second >= 64 * 1024 && e.second % OS_PAGE_SIZE == 0) { firstFit = e.first; break; }
    }
    const bool lgTookId = OA::blockLive(og, L.Lg) && OA::blockOf(og, p2) == L.Lg;
    std::fprintf(stderr, "  %s child: D (id %u, %p) released inside the minor; W1's stash holds %p; "
                 "W2's own virgin block took id %u at %p; first-fit extent now %p\n", id, L.D.v,
                 static_cast<void*>(L.Dstart), static_cast<void*>(L.Dcell), OA::blockOf(og, p2).v,
                 static_cast<void*>(bt.info(OA::blockOf(og, p2)).start), static_cast<const void*>(firstFit));
    if (!lgTookId || firstFit != L.Dstart || OA::blockLive(og, L.D))
        return notReached(id, "W2's virgin did not take Lg's id, D's id is live, or D's extent is not first-fit");
    // The bag the light shrink kept goes away, so the next virgin must acquire.
    OA::drainUnassignedBlocksForTest(og);
    // W2 promotes 8 KiB objects: the first pops M's 8K gap cell; the next finds
    // no cell and no pending sweep, and the virgin rung re-issues D.
    std::vector<void*> w2objs;
    BlockId N = NO_BLOCK_ID;
    void* dup = nullptr;
    for (int i = 0; i < 16 && dup == nullptr; ++i) {
        void* q = promo(og, w2, 8192, static_cast<uint8_t>(0x80 + i));
        w2objs.push_back(q);
        const BlockId b = OA::blockOf(og, q);
        if (!N.valid() && b.valid() && bt.info(b).start == L.Dstart) {
            N = b;
            std::fprintf(stderr, "  %s child: the virgin rung re-issued block id %u at %p (D was id %u at %p), "
                         "class %zu\n", id, N.v, static_cast<void*>(bt.info(N).start), L.D.v,
                         static_cast<void*>(L.Dstart), bt.info(N).size_class);
        }
        if (q == L.Dcell) dup = q;
    }
    if (!N.valid()) return notReached(id, "no block was re-issued at D's start");
    if (N != L.D) return notReached(id, "the block at D's start did not get D's id (not the same-id re-issue)");
    if (dup == nullptr) return notReached(id, "W2 never reached the cell at W1's stashed address");
    const uint8_t w2fill = static_cast<uint8_t>(0x80 + (w2objs.size() - 1));
    if (!byteBufIntact(dup, 8192, w2fill)) return notReached(id, "W2's object at the stashed address is not intact");
    if (w1.stash_n[c8] != 1 || w1.cur[c8].block.valid())
        return notReached(id, "W1 no longer holds its stashed cell, or has a cursor");
    // The re-issue is done (the memory is committed and owned by block N): now
    // W1's next 8 KiB promotion pops its stash. From here on an abort is a
    // check catching the double allocation (the child's message says which).
    std::signal(SIGABRT, SIG_DFL);
    std::fprintf(stderr, "  %s child: W2 holds a promoted object at %p in re-issued block %u; W1 pops its stash\n",
                 id, dup, N.v);
    void* p3 = promo(og, w1, 8192, 0xC1);
    const bool same = p3 == dup;
    const bool w2Intact = byteBufIntact(dup, 8192, w2fill);
    std::fprintf(stderr, "  %s child: W1 got %p%s; W2's object %s\n", id, p3,
                 same ? " -- the SAME address: two promoted objects share one cell" : "",
                 w2Intact ? "intact" : "OVERWRITTEN");
    return (same || !w2Intact) ? kDefect : kCorrect;
}

}  // namespace

Testing::TestCase testCR014TailReleasesStashedBlock(
    "CR-014 [xfail CR-014]: the tail completion never releases a block whose cell is in a worker's stash (B)",
    []() { runXfailGuard("CR-014 B", cr014B); });

Testing::TestCase testCR014TailReissueDoubleAlloc(
    "CR-014 [xfail CR-014]: a stashed cell is never handed out twice after the tail shrink's block is re-issued at the same id and start (C)",
    []() { runXfailGuard("CR-014 C", cr014C); });

Testing::TestCase testCR001Recount(
    "CR-001 [xfail CR-001]: a cell popped while Sweeping is counted although the sweep completed before its finalize (a: recount)",
    []() { runXfailGuard("CR-001 (a)", [] { return cr001(false); }); });

Testing::TestCase testCR001Release(
    "CR-001 [xfail CR-001]: the deferred shrink never releases a block holding a promoted object (b)",
    []() { runXfailGuard("CR-001 (b)", [] { return cr001(true); }); });

// ----------------------------------------------------------------------------
// Steps 8-9: CR-016. allocateFromEmptyRegularBlocks skips only Current blocks
// inside a parallel minor; a block a worker still holds through a CHUNK (the
// shared block moved on: kAllocNone) or through its STASH (a mixed block,
// never Current) reads fully_swept && live_bytes == 0 and flips to large.
// ----------------------------------------------------------------------------

namespace {

HeapConfig cr016Config(double demote) {
    HeapConfig cfg;
    cfg.alloc_buffer_size = 32 * 1024;
    cfg.nursery_block_count = 8;
    cfg.nursery_max_block_count = 8;
    cfg.initial_old_gen_size = 256 * 1024;
    cfg.max_heap_size = 512ULL * 1024 * 1024;
    cfg.large_object_threshold = 8 * 1024;
    cfg.decommit_on_oldgen_release = false;
    cfg.old_gen_bitmap_alloc = true;
    cfg.gc_minor_threads = 1;
    cfg.minor_lab_bytes = 4096;
    cfg.gc_thread_mode = 0;
    cfg.commit_ahead_bytes = 0;
    cfg.incremental_mark = false;
    cfg.conc_mark = 0;
    cfg.demote_live_fraction = demote;
    cfg.validate();
    return cfg;
}

int cr016Chunk() {
    const char* id = "CR-016 (chunk)";
    auto& a = initAllocator(cr016Config(0.0));
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    if (OA::blockCount(og) != 0) return notReached(id, "the heap is not fresh");
    auto& ctx = og.promoCtx();
    og.beginParallelPromotion(ctx, 2);
    auto &w0 = ctx.w[0], &w1 = ctx.w[1];
    void* p0 = promo(og, w0, 512);   // virgin V published; w0 claims unit 0 = all 64 cells
    const BlockId V = OA::blockOf(og, p0);
    char* Vs = OA::getBlockTable(og).info(V).start;
    if (p0 != Vs || OA::cellsIn(og, V) != 64 || OA::metaOf(og, V).live_bytes != 0 ||
        !OA::metaOf(og, V).fully_swept || OA::allocState(og, V) != 2 || OA::blockIdAt(og, 0) != V) {
        dumpBlocks(id, og);
        return notReached(id, "V is not a fully claimed 64-cell block with live_bytes 0 at position 0");
    }
    void* p1 = promo(og, w1, 512);   // advanceSharedW retires V (kAllocNone); a new virgin block
    if (OA::allocState(og, V) != 0 || OA::blockOf(og, p1) == V || !OA::getFreeLargeBlocks(og).empty()) {
        dumpBlocks(id, og);
        return notReached(id, "V was not retired while w0's chunk is open");
    }
    const auto& c0 = w0.cur[OA::sizeClass(512)];
    if (c0.block != V || c0.next_cell >= c0.num_cells || c0.pending_live == 0)
        return notReached(id, "w0's cursor does not hold an open chunk of V with pending bytes");
    // Exactly alloc_buffer_size: allocateLargeBlock -> allocateFromEmptyRegularBlocks.
    char* big = static_cast<char*>(promo(og, w1, 32 * 1024, 0xEE));
    if (big == Vs) {
        std::fprintf(stderr, "  %s child: V flipped to large at %p under w0's open chunk (63 cells left)\n", id,
                     static_cast<void*>(big));
        return kDefect;
    }
    char* p2 = static_cast<char*>(og.allocatePromotion(w0, 512, false));   // the stale cursor
    if ((p2 >= big && p2 < big + 32 * 1024) || !byteBufIntact(big, 32 * 1024, 0xEE)) return kDefect;
    formatAsBytes(p2, 512);
    og.endParallelPromotion(ctx);
    return OA::allocStateConsistent(og) ? kCorrect : kDefect;
}

int cr016Stash() {
    const char* id = "CR-016 (stash)";
    auto& a = initAllocator(cr016Config(0.5));
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    void* d = og.allocate(24);   // D: class-24 block, dies
    formatAsBytes(d, 24);
    char* lv = static_cast<char*>(oldByteBuf(og, 20 * 1024, 0x21));   // D': bag page, tail 8K@20K + 4K@28K
    void* dead8 = oldByteBuf(og, 8192, 0x22);                          // pops D'+20K, dies
    const BlockId D = OA::blockOf(og, d), Dp = OA::blockOf(og, lv);
    if (OA::blockCount(og) != 2 || OA::blockIdAt(og, 0) != D || OA::blockIdAt(og, 1) != Dp ||
        dead8 != lv + 20 * 1024) {
        dumpBlocks(id, og);
        std::fprintf(stderr, "  %s child: lv %p dead8 %p\n", id, static_cast<void*>(lv), dead8);
        return notReached(id, "layout is not [D][D' = live 20K, dead 8K]");
    }
    HPointer r = AllocatorTestAccess::toPointer(lv);
    a.getRootSet().addRoot(&r);
    a.majorGC();
    OA::driveSweepToCompletion(og);
    char* Ds = OA::getBlockTable(og).info(D).start;
    char* Dcell = Ds + 16 * 1024;   // 32760 -> 16K@0, 8K@16K, ...
    char* Dpcell = lv + 20 * 1024;
    const size_t c8 = OA::sizeClass(8192);
    FreeCell* h = OA::getFreeList(og, c8);
    if (OA::gcPhase(og) != GCPhase::Idle || !OA::blockLive(og, D) || !OA::demoted(og, D) ||
        !OA::metaOf(og, D).fully_swept || OA::metaOf(og, D).live_bytes != 0 ||
        reinterpret_cast<char*>(h) != Dpcell || h->next_in_class == nullptr ||
        reinterpret_cast<char*>(h->next_in_class) != Dcell || !OA::getFreeLargeBlocks(og).empty()) {
        dumpBlocks(id, og);
        std::fprintf(stderr, "  %s child: 8K list head %p next %p (D' cell %p, D cell %p)\n", id,
                     static_cast<void*>(h), h ? static_cast<void*>(h->next_in_class) : nullptr,
                     static_cast<void*>(Dpcell), static_cast<void*>(Dcell));
        return notReached(id, "D is not an all-dead swept mixed block under [D'-cell, D-cell]");
    }
    auto& ctx = og.promoCtx();
    og.beginParallelPromotion(ctx, 2);
    auto &w0 = ctx.w[0], &w1 = ctx.w[1];
    void* p1 = promo(og, w1, 8192);   // finalizes the D'-cell, stashes the D-cell
    if (p1 != Dpcell || w1.stash_n[c8] != 1 || reinterpret_cast<char*>(w1.stash[c8][0]) != Dcell ||
        OA::metaOf(og, D).live_bytes != 0 || OA::allocState(og, D) != 0)
        return notReached(id, "D's cell is not (only) in w1's stash");
    char* big = static_cast<char*>(promo(og, w0, 32 * 1024, 0xEE));
    if (big == Ds) {
        std::fprintf(stderr, "  %s child: D flipped to large at %p; w1's stashed cell %p is inside it\n", id,
                     static_cast<void*>(big), static_cast<void*>(Dcell));
        return kDefect;
    }
    char* p3 = static_cast<char*>(promo(og, w1, 8192));
    if (p3 >= big && p3 < big + 32 * 1024) return kDefect;
    og.endParallelPromotion(ctx);
    a.getRootSet().removeRoot(&r);
    return kCorrect;
}

}  // namespace

Testing::TestCase testCR016FlipChunk(
    "CR-016 [xfail CR-016]: the empty-block flip never takes a block whose chunk a worker holds (chunk)",
    []() { runXfailGuard("CR-016 (chunk)", cr016Chunk); });

Testing::TestCase testCR016FlipStash(
    "CR-016 [xfail CR-016]: the empty-block flip never takes a block whose cell is in a worker's stash (stash)",
    []() { runXfailGuard("CR-016 (stash)", cr016Stash); });

// ----------------------------------------------------------------------------
// Step 10: CR-028 (validate builds). W1 pops M's first gap cell while M is
// still being swept and has written the body but not yet the header (the
// parallel minor's copy order: copyClaimed writes the body first); W2's slice
// sweeps M to its boundary, and V11's parse-by-header walk reads the torn cell.
// ----------------------------------------------------------------------------

namespace {

int cr028Scenario() {
    const char* id = "CR-028";
    auto& a = initAllocator(tailConfig(8 * 1024, 8, 0.0));
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    char* av = static_cast<char*>(oldByteBuf(og, 12 * 1024, 0xA1));   // M: [a dead][32K@12K][16K@44K][4K@60K]
    char* b = static_cast<char*>(oldByteBuf(og, 32 * 1024, 0xB2));    // split step 1: exact 32K cell
    char* c = static_cast<char*>(oldByteBuf(og, 16 * 1024, 0xC3));    // exact 16K cell
    char* d = static_cast<char*>(oldByteBuf(og, 4096, 0xD4));          // rung-2 pop of the 4K cell
    void* t = oldByteBuf(og, 24, 0x7E);                                // T: uniform block after M
    const BlockId M = OA::blockOf(og, av);
    if (b != av + 12 * 1024 || c != av + 44 * 1024 || d != av + 60 * 1024 || OA::blockIdAt(og, 0) != M ||
        OA::blockCount(og) != 2 || OA::blockIdAt(og, 1) != OA::blockOf(og, t) ||
        av != OA::getBlockTable(og).info(M).start) {
        dumpBlocks(id, og);
        std::fprintf(stderr, "  %s child: a %p b %p c %p d %p t %p\n", id, static_cast<void*>(av),
                     static_cast<void*>(b), static_cast<void*>(c), static_cast<void*>(d), t);
        return notReached(id, "layout is not [M = a b c d][T]");
    }
    std::vector<HPointer> roots;
    for (void* p : {static_cast<void*>(b), static_cast<void*>(c), static_cast<void*>(d), t})
        roots.push_back(AllocatorTestAccess::toPointer(p));
    for (auto& r : roots) a.getRootSet().addRoot(&r);
    a.majorGC();                              // initial slice: gap a (-> 8K@0 + 4K@8K), then b
    OA::lazySweep(og, NUM_SIZE_CLASSES, 8);   // c
    if (OA::getSweepCursor(og) != d ||
        reinterpret_cast<char*>(OA::getFreeList(og, OA::sizeClass(8192))) != av ||
        OA::getFreeList(og, OA::sizeClass(64)) != nullptr || !noMixedOnlyCells(og)) {
        dumpBlocks(id, og);
        std::fprintf(stderr, "  %s child: cursor %p (d %p), 8K head %p\n", id,
                     static_cast<const void*>(OA::getSweepCursor(og)), static_cast<void*>(d),
                     static_cast<void*>(OA::getFreeList(og, OA::sizeClass(8192))));
        return notReached(id, "the sweep is not at d with M's gap cell listed");
    }
    auto& ctx = og.promoCtx();
    og.beginParallelPromotion(ctx, 2);
    char* p1 = static_cast<char*>(og.allocatePromotion(ctx.w[1], 8192, false));
    if (p1 != av) return notReached(id, "W1 did not pop M's first gap cell");
    // copyClaimed's order (NurseryParallel.cpp): the body first; the header is
    // still the finalize's zeroed word (tag 0, 16 bytes): a parse steps into
    // the body, where a copied object's bytes can read as any header.
    std::memset(p1 + sizeof(Header), 0xAB, 8192 - sizeof(Header));
    Header fake{};
    fake.tag = Tag_String;
    fake.size = 0x7FFFFFFFu;
    std::memcpy(p1 + 16, &fake, sizeof fake);
    std::fprintf(stderr, "  %s child: W1 holds M's gap cell %p mid-copy (header tag %u); W2 sweeps d to M's end\n",
                 id, static_cast<void*>(p1), static_cast<unsigned>(getHeader(p1)->tag));
    void* p2 = og.allocatePromotion(ctx.w[0], 64, false);   // sweeps d -> M's boundary -> V11 abort
    if (OA::metaOf(og, M).fully_swept == false) {
        dumpBlocks(id, og);
        return notReached(id, "W2 did not sweep M to its end");
    }
    formatAsBytes(p1, 8192);
    if (p2 != nullptr) formatAsBytes(p2, 64);
    og.endParallelPromotion(ctx);
    for (auto& r : roots) a.getRootSet().removeRoot(&r);
    return kCorrect;
}

}  // namespace

Testing::TestCase testCR028V11ParsesPoppedCell(
    "CR-028 [xfail CR-028]: the V11 walk never parses a cell a worker popped from the block (validate builds)",
    []() {
#if ECO_HEAP_VALIDATE
        runXfailGuard("CR-028", cr028Scenario);
#else
        (void)cr028Scenario;
        std::cout << "  (skipped: needs ECO_HEAP_VALIDATE=ON)\n";
#endif
    });

// ----------------------------------------------------------------------------
// Step 11: CR-037. A large string's header was copied into survivor extent F
// (X, its body, joined F.lb_bodies); X dies at a STW major, which frees X's
// cell and drops its index entry but leaves F.lb_bodies alone. A new YLOS B of
// the same size takes X's cell. At the next minor F is the hand-over extent
// (k = 1) or an ageing extent (k = 2), and its prep re-marks every lb_bodies
// entry "seen" (markLargeBodySeen): B is coloured as reached before any
// scan, so it is neither aged nor scanned (its slot keeps pointing into eden).
// ----------------------------------------------------------------------------

namespace {

uint64_t bits(HPointer p) {
    uint64_t r;
    std::memcpy(&r, &p, 8);
    return r;
}

bool lbHas(const region::Extent& X, void* body) {
    for (const HPointer& b : X.lb_bodies)
        if (AllocatorTestAccess::fromPointer(b) == body) return true;
    return false;
}

// Minor 1 copies a large string's header into the fill F (X joins
// F.lb_bodies); the string dies; an explicit major frees X.
void* deadBodyAfterMajor(Allocator& a, int* ext, const char** why) {
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    OldGenSpace& og = h->getOldGen();
    RegionState* R = NurserySpaceTestAccess::region(h->getNursery());
    HPointer s = alloc::allocString(std::u16string(6404, u'q'));
    a.getRootSet().addRoot(&s);
    if (getHeader(a.resolve(s))->tag != Tag_LargeStringHeader) {
        *why = "the string is not a split large string";
        return nullptr;
    }
    void* X = AllocatorTestAccess::fromPointer(static_cast<LargeStringHeader*>(a.resolve(s))->body);
    a.minorGC();   // minor 1: header -> fill F; X joins F.lb_bodies
    const int j = R->extentOf(a.resolve(s));
    if (j < 0 || !lbHas(R->x[j], X) || R->x[j].state != region::XState::Young || R->x[j].age != 1) {
        *why = "X is not in a Young age-1 extent's lb_bodies";
        return nullptr;
    }
    a.getRootSet().removeRoot(&s);
    s = alloc::listNil();
    a.majorGC();   // frees X; retireDeadLargeBodies erases its index entry
    OA::driveSweepToCompletion(og);
    if (og.largeBodyIndexed(X) || !lbHas(R->x[j], X) || og.cycleActive()) {
        *why = "X still indexed, dropped from lb_bodies, or a cycle is active";
        return nullptr;
    }
    *ext = j;
    return X;
}

int cr037Scenario(uint32_t k, bool control) {
    const char* id = control ? "CR-037 control" : (k == 1 ? "CR-037 (k=1)" : "CR-037 (k=2)");
    auto& a = initRegionAllocator(cr017Config(k));
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    NurserySpace& ns = h->getNursery();
    OldGenSpace& og = h->getOldGen();
    RegionState* R = NurserySpaceTestAccess::region(ns);
    if (!ns.regionMode() || R == nullptr) return notReached(id, "no region nursery");
    int j = -1;
    const char* why = "";
    void* X = deadBodyAfterMajor(a, &j, &why);
    if (X == nullptr) return notReached(id, why);
    const uint64_t seq = R->minor_seq;
    HPointer e = alloc::allocInt(0xE37);
    a.getRootSet().addRoot(&e);
    HPointer B = alloc::arrayFromPointers(std::vector<HPointer>(1600, e));
    a.getRootSet().addRoot(&B);
    a.getRootSet().removeRoot(&e);
    if (R->minor_seq != seq) return notReached(id, "a minor ran before B existed");
    if (a.resolve(B) != X) return notReached(id, "B did not reuse X's cell");
    if (!og.isYoungLarge(X)) return notReached(id, "B is not a YLOS");
    auto* arr = static_cast<ElmArray*>(X);
    if (!NurserySpaceTestAccess::contains(ns, AllocatorTestAccess::fromPointer(arr->elements[0].p)))
        return notReached(id, "B's slot does not point into the nursery");
    const uint64_t e_bits = bits(arr->elements[0].p);
    if (control) ns.test_no_body_remark_ = true;   // skips the lb_bodies re-mark (hand-over and ageing)
    a.minorGC();   // minor 2: the prep colours X
    ns.test_no_body_remark_ = false;
    const bool unaged = getHeader(X)->age == 0;   // a reached YLOS is aged
    const bool unhealed = bits(arr->elements[0].p) == e_bits;
    std::fprintf(stderr, "  %s child: B (YLOS at freed body %p, extent %d) age %u, slot %s\n", id, X, j,
                 static_cast<unsigned>(getHeader(X)->age), unhealed ? "UNHEALED (still into eden)" : "healed");
    a.getRootSet().removeRoot(&B);
    return (unaged || unhealed) ? kDefect : kCorrect;
}

}  // namespace

Testing::TestCase testCR037ReusedYlosK1(
    "CR-037 [xfail CR-037]: region k=1, a new YLOS at a freed lb_bodies address is reached at the hand-over minor",
    []() { runXfailGuard("CR-037 (k=1)", [] { return cr037Scenario(1, false); }); });

Testing::TestCase testCR037ReusedYlosK2(
    "CR-037 [xfail CR-037]: region k=2, a new YLOS at a freed lb_bodies address is reached (ageing extent)",
    []() { runXfailGuard("CR-037 (k=2)", [] { return cr037Scenario(2, false); }); });

Testing::TestCase testCR037Control(
    "CR-037: negative control, no body re-mark: the reused-address YLOS is reached and aged",
    []() { runFixedGuard("CR-037 control", [] { return cr037Scenario(1, true); }); });

// ----------------------------------------------------------------------------
// Step 12: CR-017 R1. X (a large body) is freed by a STW major while its
// header's dead copy stays in F. The next minor triggers a concurrent cycle
// (conc_mark = 2: the mark runs in a HELD background episode) and its t0 young
// walk greys X through the dead header. A YLOS B then takes X's cell: the
// validate build's IM4 aborts (allocation into a marked cell); otherwise the
// released marker scans B, whose slot points into the nursery, and aborts.
// ----------------------------------------------------------------------------

namespace {

HeapConfig cr017ConcConfig(uint32_t k, size_t initial_old = 256 * 1024) {
    HeapConfig cfg = cr017Config(k);
    cfg.conc_mark = 2;
    cfg.gc_mark_threads = 1;
    cfg.conc_mark_threads = 1;
    cfg.conc_mark_priority = 0;
    cfg.initial_old_gen_size = initial_old;
    cfg.validate();
    return cfg;
}

void holdNext(Allocator& a, OldGenSpace& og) {   // = ConcurrentMarkTest.cpp holdNextCycle
    for (int g = 0; g < 256 && og.cycleActive(); ++g) a.minorGC();
    og.test_bg_hold_.store(true);
}

bool waitBg(OldGenSpace& og, int ms = 20000) {   // = ConcurrentMarkTest.cpp waitBackground
    for (int i = 0; i < ms; ++i) {
        if (OA::bgEpisode(og) != OldGenSpace::BgEpisode::Running || OA::bgFinishedApprox(og)) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return false;
}

// k = 2 (M5 MC_deep_boundary_k2_cr017, T0GreyAllocated): the same minor
// count; at the trigger minor the header's extent is an AGEING extent (07b),
// which the t0 young walk reads before that extent's first ageing mark.
int cr017R1Scenario(bool control, uint32_t k = 1) {
    const char* id = k == 1 ? (control ? "CR-017 R1 control" : "CR-017 R1")
                            : (control ? "CR-017 R1 control (k=2)" : "CR-017 R1 (k=2)");
    auto& a = initRegionAllocator(cr017ConcConfig(k));
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    OldGenSpace& og = h->getOldGen();
    RegionState* R = NurserySpaceTestAccess::region(h->getNursery());
    if (R == nullptr) return notReached(id, "no region nursery");
    int j = -1;
    const char* why = "";
    void* X = deadBodyAfterMajor(a, &j, &why);
    if (X == nullptr) return notReached(id, why);
    const BlockId bx = OA::blockOf(og, X);
    if (!bx.valid() || !OA::blockLive(og, bx)) return notReached(id, "X's page was released (floor)");
    if (OA::isMarked(og, X)) return notReached(id, "X marked before t0");
    holdNext(a, og);
    if (og.cycleActive()) return notReached(id, "a cycle is still active before the trigger");
    h->test_snapshot_skip_young_walk_ = control;
    h->test_force_major_trigger_ = true;
    a.minorGC();   // minor 2: F -> hand-over; t0 walks the dead header and greys X
    h->test_snapshot_skip_young_walk_ = false;
    if (!og.cycleActive() || OA::bgEpisode(og) != OldGenSpace::BgEpisode::Running || !og.test_bg_hold_.load())
        return notReached(id, "no held background episode");
    {   // Where the dead header sits at t0: k = 1 the hand-over (Tenuring)
        // extent, k = 2 an ageing (Young, age 2) extent.
        const region::Extent& Xj = R->x[j];
        const bool where = k == 1 ? Xj.state == region::XState::Tenuring
                                  : (Xj.state == region::XState::Young && Xj.age == 2);
        std::fprintf(stderr, "  %s child: at t0 the dead header's extent %d is %s, age %u\n", id, j,
                     Xj.state == region::XState::Tenuring ? "Tenuring" :
                     Xj.state == region::XState::Young ? "Young" : "Free", Xj.age);
        if (!where) {
            og.test_bg_hold_.store(false);
            waitBg(og);
            return notReached(id, k == 1 ? "the header's extent is not the hand-over extent at t0"
                                         : "the header's extent is not an ageing (Young, age 2) extent at t0");
        }
    }
    const bool greyed = OA::isMarked(og, X);
    std::fprintf(stderr, "  %s child: t0 %s the freed body cell X %p (mark stack %s)\n", id,
                 greyed ? "GREYED" : "left unmarked", X, OA::markStackEmpty(og) ? "empty" : "non-empty");
    if (!control && !greyed) return notReached(id, "t0 did not grey X");
    if (control && greyed) return notReached(id, "the control's t0 greyed X");
    const uint64_t seq = R->minor_seq;
    HPointer e = alloc::allocInt(0xE17);
    a.getRootSet().addRoot(&e);
    HPointer B = alloc::arrayFromPointers(std::vector<HPointer>(1600, e));   // validate: IM4 aborts HERE
    a.getRootSet().addRoot(&B);
    a.getRootSet().removeRoot(&e);
    if (R->minor_seq != seq || a.resolve(B) != X) {
        og.test_bg_hold_.store(false);
        waitBg(og);
        return notReached(id, "B not at X, or a minor ran");
    }
    std::fprintf(stderr, "  %s child: YLOS B allocated at X; releasing the background marker\n", id);
    // k = 2: X is still in F.lb_bodies and F is handed over at the next minor,
    // whose prep would colour B (CR-037, TV7 in validate builds): keep that
    // defect out of this guard's cleanup minors.
    if (k == 2) h->getNursery().test_no_body_remark_ = true;
    og.test_bg_hold_.store(false);
    if (!waitBg(og)) return notReached(id, "the background episode never finished");
    for (int g = 0; g < 64 && og.cycleActive(); ++g) a.minorGC();
    a.getRootSet().removeRoot(&B);
    return kCorrect;   // today: the marker scans B and aborts first
}

}  // namespace

Testing::TestCase testCR017R1YlosIntoGreyedCell(
    "CR-017 [xfail CR-017]: region k=1, a YLOS allocated into a body cell the t0 walk greyed (R1)",
    []() { runXfailGuard("CR-017 R1", [] { return cr017R1Scenario(false); }); });

Testing::TestCase testCR017R1Control(
    "CR-017: R1 negative control, no t0 young walk",
    []() { runFixedGuard("CR-017 R1 control", [] { return cr017R1Scenario(true); }); });

Testing::TestCase testCR017R1YlosIntoGreyedCellK2(
    "CR-017 [xfail CR-017]: region k=2, a YLOS allocated into a body cell the t0 walk greyed through an ageing extent (R1)",
    []() { runXfailGuard("CR-017 R1 (k=2)", [] { return cr017R1Scenario(false, 2); }); });

Testing::TestCase testCR017R1ControlK2(
    "CR-017: R1 negative control at k=2, no t0 young walk",
    []() { runFixedGuard("CR-017 R1 control (k=2)", [] { return cr017R1Scenario(true, 2); }); });

// ----------------------------------------------------------------------------
// Step 13: CR-017 R2. c (old, dead) -> d, where d sits inside bag page P; x
// (young, dead) -> c. A STW major frees c's cell (its image stays intact) and
// releases P. The next minor starts a held concurrent cycle whose t0 walk
// greys c through the dead x. P is rematerialised after t0 (a post-t0 block):
// d is now inside a free cell. Released, the marker scans c's stale image and
// sets d's mark bit: a mark bit on a free cell of a post-t0 block.
// ----------------------------------------------------------------------------

namespace {

int cr017R2Scenario(bool control) {
    const char* id = control ? "CR-017 R2 control" : "CR-017 R2";
    // demote_live_fraction = 0: c's block stays uniform (bitmap-swept), so the
    // sweep never writes a free-cell header over c's stale image.
    HeapConfig cfg = cr017ConcConfig(1, 32 * 1024);
    cfg.demote_live_fraction = 0.0;
    cfg.validate();
    auto& a = initRegionAllocator(cfg);
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    NurserySpace& ns = h->getNursery();
    OldGenSpace& og = h->getOldGen();
    auto young = [&](HPointer p) { return NurserySpaceTestAccess::contains(ns, AllocatorTestAccess::fromPointer(p)); };
    // (0) A live 24 KiB object z pins the first bag page: the heap-base page
    //     is never reused for a page request (acquireOldGenBlock), so P must
    //     not be it.
    HPointer z = AllocatorTestAccess::toPointer(oldByteBuf(og, 24 * 1024, 0x2A));
    a.getRootSet().addRoot(&z);
    // Dead filler pages: released with P at the major (see the reorder).
    for (int i = 0; i < 3; ++i) (void)oldByteBuf(og, 24 * 1024, static_cast<uint8_t>(0x60 + i));
    // (1) f and d in one bag page P, d not at P's start.
    char* f = static_cast<char*>(oldByteBuf(og, kEq, 0xF1));
    char* d = static_cast<char*>(oldByteBuf(og, kEq, 0xD1));
    const BlockId Pb = OA::blockOf(og, d);
    if (OA::blockOf(og, f) != Pb || OA::inUniformBlock(og, d) || d == OA::getBlockTable(og).info(Pb).start ||
        OA::getBlockTable(og).info(Pb).start == AllocatorTestAccess::getHeapBase(a)) {
        dumpBlocks(id, og);
        return notReached(id, "f and d are not in one mixed block with d past its start");
    }
    char* const P = OA::getBlockTable(og).info(Pb).start;
    for (int i = 0; i < 3; ++i) (void)oldByteBuf(og, 24 * 1024, static_cast<uint8_t>(0x70 + i));
    // (2) c -> d, tenured, with keepers in c's block.
    std::vector<HPointer> keep;
    keep.reserve(80);
    for (int i = 0; i < 32; ++i) keep.push_back(alloc::tuple2(alloc::boxed(alloc::allocInt(i)), alloc::boxed(alloc::allocInt(i)), 0));
    for (auto& k : keep) a.getRootSet().addRoot(&k);
    HPointer c = alloc::tuple2(alloc::boxed(AllocatorTestAccess::toPointer(d)), alloc::boxed(alloc::allocInt(1)), 0);
    a.getRootSet().addRoot(&c);
    for (int i = 0; i < 32; ++i) {
        keep.push_back(alloc::tuple2(alloc::boxed(alloc::allocInt(100 + i)), alloc::boxed(alloc::allocInt(i)), 0));
        a.getRootSet().addRoot(&keep.back());
    }
    auto anyYoung = [&] {
        if (young(c)) return true;
        for (auto& k : keep) if (young(k)) return true;
        return false;
    };
    for (int g = 0; g < 8 && anyYoung(); ++g) a.minorGC();
    if (anyYoung()) return notReached(id, "c or a keeper was never tenured");
    char* const cA = static_cast<char*>(AllocatorTestAccess::fromPointer(c));
    const BlockId cb = OA::blockOf(og, cA);
    bool shares = false;
    for (auto& k : keep) shares |= OA::blockOf(og, AllocatorTestAccess::fromPointer(k)) == cb;
    if (!shares) return notReached(id, "no keeper shares c's block");
    // (3) x -> c, x young.
    HPointer x = alloc::tuple2(alloc::boxed(c), alloc::boxed(alloc::allocInt(4)), 0);
    a.getRootSet().addRoot(&x);
    a.getRootSet().removeRoot(&c);
    c = alloc::listNil();
    a.minorGC();
    if (!young(x)) return notReached(id, "x is not in a survivor extent");
    // (4) x dies; a STW major frees c and releases P.
    a.getRootSet().removeRoot(&x);
    x = alloc::listNil();
    a.majorGC();
    OA::driveSweepToCompletion(og);
    const Tuple2* ct = reinterpret_cast<const Tuple2*>(cA);
    auto cIntact = [&] { return getHeader(cA)->tag == Tag_Tuple2 && bits(ct->a.p) == bits(AllocatorTestAccess::toPointer(d)); };
    if (OA::isMarked(og, cA) || !OA::blockLive(og, cb) || !cIntact() || OA::blockOf(og, d).valid()) {
        dumpBlocks(id, og);
        std::fprintf(stderr, "  %s child: c marked %d, c's block live %d, c intact %d, P valid %d\n", id,
                     (int)OA::isMarked(og, cA), (int)OA::blockLive(og, cb), (int)cIntact(),
                     (int)OA::blockOf(og, d).valid());
        return notReached(id, "after the major: c not free-but-intact in a live block, or P not released");
    }
    auto dumpFree = [&](const char* when) {
        if (!std::getenv("CR017_DEBUG")) return;
        std::fprintf(stderr, "  %s child: free extents %s:", id, when);
        for (const auto& e : AllocatorTestAccess::freeBlocks(a)) std::fprintf(stderr, " %p+%zu", static_cast<void*>(e.first), e.second);
        std::fprintf(stderr, " | bag %zu\n", OA::getUnassignedBlocks(og).size());
    };
    dumpFree("after the major");
    // Reorder the released extents so that P sits second on the list:
    // acquireOldGenBlock takes the first fit and swap-removes it, so the
    // trigger minor's tenure grants (up to four pages) take the others first
    // and P stays released until after t0.
    {
        const size_t page = 32 * 1024;
        std::vector<char*> ext;
        const size_t n = AllocatorTestAccess::freeBlocks(a).size();
        for (size_t i = 0; i < n; ++i) ext.push_back(AllocatorTestAccess::acquireOldGenBlock(a, page));
        std::vector<char*> order;
        for (char* e : ext) if (e != P) order.push_back(e);
        if (order.size() + 1 != ext.size() || order.size() < 4) {
            for (char* e : ext) AllocatorTestAccess::releaseOldGenBlock(a, e, page);
            return notReached(id, "the released extents are not P plus at least four others");
        }
        order.insert(order.begin() + 1, P);
        for (char* e : order) AllocatorTestAccess::releaseOldGenBlock(a, e, page);
        dumpFree("after the reorder");
    }
    // (5) The held cycle; t0 greys c through the dead x.
    holdNext(a, og);
    dumpFree("after holdNext");
    if (og.cycleActive()) return notReached(id, "a cycle is still active before the trigger");
    h->test_snapshot_skip_young_walk_ = control;
    h->test_force_major_trigger_ = true;
    a.minorGC();
    h->test_snapshot_skip_young_walk_ = false;
    dumpFree("after the trigger minor");
    auto release = [&] { og.test_bg_hold_.store(false); waitBg(og); };
    if (!og.cycleActive() || OA::bgEpisode(og) != OldGenSpace::BgEpisode::Running || !og.test_bg_hold_.load()) {
        release();
        return notReached(id, "no held background episode");
    }
    const bool greyed = OA::isMarked(og, cA);
    std::fprintf(stderr, "  %s child: t0 %s c's freed cell %p (-> d %p in released page %p)\n", id,
                 greyed ? "GREYED" : "left unmarked", static_cast<void*>(cA), static_cast<void*>(d),
                 static_cast<void*>(P));
    if (greyed == control || !cIntact()) { release(); return notReached(id, "t0 greying of c not as expected, or c's image changed"); }
    std::vector<char*> t0starts;
    for (size_t pos = 0; pos < OA::blockCount(og); ++pos)
        t0starts.push_back(OA::getBlockTable(og).info(OA::blockIdAt(og, pos)).start);
    // (6) Rematerialise P after t0.
    bool found = false;
    std::vector<HPointer> fill;
    fill.reserve(64);
    for (int i = 0; i < 64 && !found; ++i) {
        char* q = static_cast<char*>(oldByteBuf(og, kEq, 0x66));
        fill.push_back(AllocatorTestAccess::toPointer(q));
        a.getRootSet().addRoot(&fill.back());
        found = q == P;
    }
    const bool postT0 = std::find(t0starts.begin(), t0starts.end(), P) == t0starts.end();
    if (!found || !postT0 || getHeader(d)->tag != Tag_Free || OA::isMarked(og, d) || !cIntact()) {
        std::fprintf(stderr, "  %s child: P found %d, post-t0 %d, d tag %u, d marked %d, c intact %d\n", id, (int)found,
                     (int)postT0, static_cast<unsigned>(getHeader(d)->tag), (int)OA::isMarked(og, d), (int)cIntact());
        dumpBlocks(id, og);
        release();
        return notReached(id, "P was not rematerialised post-t0 with a clear free cell at d");
    }
    // (7) Release the marker.
    og.test_bg_hold_.store(false);
    if (!waitBg(og)) return notReached(id, "the background episode never finished");
    // (8) The oracle.
    const bool bad = OA::isMarked(og, d) && getHeader(d)->tag == Tag_Free;
    std::fprintf(stderr, "  %s child: after the marker: d %s, tag %u%s\n", id, OA::isMarked(og, d) ? "MARKED" : "unmarked",
                 static_cast<unsigned>(getHeader(d)->tag), bad ? " -- a mark bit on a FREE cell of a post-t0 block" : "");
    for (auto& k : keep) a.getRootSet().removeRoot(&k);
    for (auto& q : fill) a.getRootSet().removeRoot(&q);
    a.getRootSet().removeRoot(&z);
    return bad ? kDefect : kCorrect;
}

}  // namespace

Testing::TestCase testCR017R2MarkOnFreeCell(
    "CR-017 [xfail CR-017]: region k=1, no mark bit lands on a free cell of a post-t0 block at a freed page (R2)",
    []() { runXfailGuard("CR-017 R2", [] { return cr017R2Scenario(false); }); });

Testing::TestCase testCR017R2Control(
    "CR-017: R2 negative control, no t0 young walk",
    []() { runFixedGuard("CR-017 R2 control", [] { return cr017R2Scenario(true); }); });

// ----------------------------------------------------------------------------
// Step 14: CR-007. A promotion worker holding promo_mu_ reaches
// acquireOldGenBlock's reuse of an extent whose Discard job is posted to the
// helper pool behind a long job, and waits for it (PageWork::awaitSlot) while
// still holding promo_mu_ (and thread_mutex_): every other worker's promotion
// that needs the lock stalls for the whole helper backlog.
// ----------------------------------------------------------------------------

namespace {

struct FnJob : gc::HelperJob {   // copy of GCHelperTest.cpp's (file-local there)
    std::function<void()> fn;
    static void call(gc::HelperJob* j) { static_cast<FnJob*>(j)->fn(); }
    explicit FnJob(std::function<void()> f) : fn(std::move(f)) {
        run = &FnJob::call;
        client = gc::HelperClient::Test;
    }
};

HeapConfig cr007Config() {
    HeapConfig cfg;   // promoConfig() (PromoBufferTest.cpp) plus the page-work knobs
    cfg.alloc_buffer_size = 32 * 1024;
    cfg.nursery_block_count = 8;
    cfg.nursery_max_block_count = 8;
    cfg.initial_old_gen_size = 256 * 1024;
    cfg.max_heap_size = 512ULL * 1024 * 1024;
    cfg.large_object_threshold = 8 * 1024;
    cfg.old_gen_bitmap_alloc = true;
    cfg.gc_minor_threads = 2;
    cfg.minor_lab_bytes = 4096;
    cfg.incremental_mark = false;
    cfg.conc_mark = 0;
    cfg.gc_thread_mode = 2;
    cfg.gc_helper_threads = 1;
    cfg.gc_helper_cpu = -1;
    cfg.decommit_on_oldgen_release = true;
    cfg.decommit_delay_syncs = 0;
    cfg.decommit_delay_majors = 0;
    cfg.decommit_pending_max_bytes = 0;
    cfg.commit_ahead_bytes = 0;   // keeps Populate jobs out of the FIFO
    cfg.validate();
    return cfg;
}

int cr007Scenario() {
    const char* id = "CR-007";
    abortMeansNotReached();
    constexpr uint64_t kHold = 200'000'000;   // H = 200 ms
    auto& pool = gc::GCHelperPool::instance();
    {
        HeapConfig q = cr007Config();
        q.gc_thread_mode = 0;
        initAllocator(q);   // quiesce the inherited page work
    }
    if (pool.configured()) {
        pool.drain();
        pool.shutdownForTesting();   // zero the process-wide stats
    }
    const HeapConfig cfg = cr007Config();
    auto& a = initAllocator(cfg);
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    OldGenSpace& og = h->getOldGen();
    gc::PageWork* pw = a.pageWork();
    if (pw == nullptr || !pool.configured() || pool.mode() != gc::HelperMode::Concurrent || pool.threads() != 1)
        return notReached(id, "no concurrent one-thread helper pool with page work");
    const size_t sz = 40, cls = OA::sizeClass(sz), page = cfg.alloc_buffer_size;
    if (OA::cursorBlock(og, cls).valid() || OA::partialQueueLength(og, cls) != 0)
        return notReached(id, "the class is in use");
    for (size_t c = cls; c < NUM_SIZE_CLASSES; ++c)
        if (OA::getFreeList(og, c) != nullptr) return notReached(id, "a free cell exists");
    gc::GCMarkGang& gang = og.ensureGang();
    if (gang.members() < 2) return notReached(id, "the gang has fewer than 2 members");
    OA::drainUnassignedBlocksForTest(og);                          // (1) an empty bag
    char* b = AllocatorTestAccess::acquireOldGenBlock(a, page);    // (2) a fresh bump page
    AllocatorTestAccess::releaseOldGenBlock(a, b, page);           //     -> Pending
    const auto& fl = AllocatorTestAccess::freeBlocks(a);
    if (fl.size() != 1 || fl[0].first != b) return notReached(id, "the free-extent list is not {b}");
    std::atomic<bool> latch{false};
    FnJob blocker([&] { while (!latch.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1)); });
    pool.post(blocker);                                            // (3) the FIFO head
    a.onGCPauseEnd(*h, false);                                     // (4) posts b's Discard behind it
    int st = 0;
    pw->forEachTracked([&](char* p, size_t, int s) { if (p == b) st = s; });
    if (st != gc::PageWork::kPostedDiscard) {
        latch.store(true);
        pool.wait(blocker, false);
        return notReached(id, "b's Discard was not posted");
    }
    auto& ctx = og.promoCtx();
    og.beginParallelPromotion(ctx, 2);                             // (5)
    struct Run {
        Allocator* a;
        OldGenSpace* og;
        OldGenSpace::PromoCtx* ctx;
        size_t sz;
        void* p[2]{};
        uint64_t wait_ns = 0;
        bool reached = false;
        std::atomic<bool> held{false};
    } r{&a, &og, &ctx, sz};
    std::thread releaser([&] {                                     // (6) the latch opens after H
        const uint64_t dl = gc::GCHelperPool::nowNs() + 5'000'000'000ull;
        while (!r.held.load() && gc::GCHelperPool::nowNs() < dl) std::this_thread::yield();
        std::this_thread::sleep_for(std::chrono::nanoseconds(kHold));
        latch.store(true);
    });
    gang.run(
        [](void* v, unsigned m) {
            Run& r = *static_cast<Run*>(v);
            if (m == 1) {   // reaches awaitSlot under promo_mu_ + thread_mutex_
                r.p[1] = r.og->allocatePromotion(r.ctx->w[1], r.sz, false);
                return;
            }
            const uint64_t dl = gc::GCHelperPool::nowNs() + 5'000'000'000ull;
            while (!(OA::promoMuHeld(*r.og) && AllocatorTestAccess::threadMutexHeldElsewhere(*r.a))) {
                if (gc::GCHelperPool::nowNs() > dl) return;
                std::this_thread::yield();
            }
            r.reached = true;
            r.held.store(true);
            const uint64_t t0 = gc::GCHelperPool::nowNs();
            r.p[0] = r.og->allocatePromotion(r.ctx->w[0], r.sz, false);
            r.wait_ns = gc::GCHelperPool::nowNs() - t0;
        },
        &r, 2);
    latch.store(true);
    releaser.join();
    pool.wait(blocker, false);
    const uint64_t mw = ctx.w[0].mutex_wait_ns;   // meaningful only with ENABLE_GC_STATS
    for (void* p : r.p)
        if (p != nullptr) formatAsBytes(p, sz);
    og.endParallelPromotion(ctx);
    if (!r.reached || r.p[0] == nullptr || r.p[1] == nullptr)
        return notReached(id, "member 1 never held both locks");
    std::fprintf(stderr, "  %s child: member 0's promotion took %.1f ms (mutex_wait %.1f ms) while member 1 "
                 "held promo_mu_ in acquireOldGenBlock's reuse wait; stall_max %.1f ms, reuse_waits %llu\n",
                 id, r.wait_ns / 1e6, mw / 1e6, pool.stats().stall_max_ns.load() / 1e6,
                 static_cast<unsigned long long>(pw->counters().reuse_waits));
    return r.wait_ns >= kHold / 2 ? kDefect : kCorrect;
}

}  // namespace

Testing::TestCase testCR007PromoMuHelperWait(
    "CR-007 [xfail CR-007]: a promotion worker never waits on a helper job while holding promo_mu_",
    []() { runXfailGuard("CR-007", cr007Scenario); });

// ----------------------------------------------------------------------------
// Step 15: CR-023. A foreign thread F calls stopAndJoin on episode 1 and
// waits in cv_done_. Before F re-checks the predicate (here: F is parked in a
// signal handler), episode 1 ends, the owner joins it and launches episode 2
// (finished_ = 0 again). F's predicate (finished_ >= members) is generation-
// blind, so F now waits out episode 2, which it never stopped.
// ----------------------------------------------------------------------------

namespace {

std::atomic<bool> g_cr023_parked{false}, g_cr023_unpark{false};   // lock-free: async-signal-safe

void cr023Park(int) {
    g_cr023_parked.store(true, std::memory_order_relaxed);
    while (!g_cr023_unpark.load(std::memory_order_relaxed)) {
        timespec ts{0, 1'000'000};
        nanosleep(&ts, nullptr);
    }
}

struct Cr023Ep {
    std::atomic<bool> release{false};
    std::atomic<bool>* stop = nullptr;
    std::atomic<int> ran{0};
};

void cr023Fn1(void* p, unsigned) {   // ignores its stop flag (a member mid-slice)
    auto& e = *static_cast<Cr023Ep*>(p);
    ++e.ran;
    while (!e.release.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
}

void cr023Fn2(void* p, unsigned) {
    auto& e = *static_cast<Cr023Ep*>(p);
    ++e.ran;
    while (!e.release.load() && !e.stop->load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
}

int cr023Scenario() {
    const char* id = "CR-023";
    abortMeansNotReached();
    constexpr auto H = std::chrono::milliseconds(200);
    struct sigaction sa{};
    sa.sa_handler = cr023Park;
    sa.sa_flags = SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGUSR1, &sa, nullptr);
    gc::GCBackgroundGang::Options o;
    o.members = 1;
    o.name = "eco-cr023";
    gc::GCBackgroundGang gang(o);
    std::atomic<bool> stop1{false}, stop2{false};
    Cr023Ep e1, e2;
    e1.stop = &stop1;
    e2.stop = &stop2;
    auto until = [](auto pred, int ms) {
        const auto dl = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
        while (!pred()) {
            if (std::chrono::steady_clock::now() > dl) return false;
            std::this_thread::yield();
        }
        return true;
    };
    gang.launch(cr023Fn1, &e1, &stop1);                                            // (1) episode 1
    if (!until([&] { return e1.ran.load() == 1; }, 5000)) { e1.release = true; return notReached(id, "fn1 did not start"); }
    std::atomic<bool> f_done{false};
    std::thread F([&] { gang.stopAndJoin(); f_done.store(true); });                 // (2) the foreign stop
    auto bail = [&](const char* why) {
        g_cr023_unpark = true;
        e1.release = true;
        e2.release = true;
        F.join();
        gang.join();
        return notReached(id, why);
    };
    if (!until([&] { return stop1.load(); }, 5000)) return bail("F never set stop1");
    (void)gang.memberTids();   // takes m_: once F has released it, F is inside cv_done_.wait
    if (f_done.load()) return bail("F returned early");
    pthread_kill(F.native_handle(), SIGUSR1);                                      // (3) park F
    if (!until([&] { return g_cr023_parked.load(); }, 5000)) return bail("F not parked");
    e1.release.store(true);                                                        //     episode 1 ends
    if (!until([&] { return gang.finishedApprox(); }, 5000)) return bail("episode 1 did not finish");
    std::atomic<bool> launched{false};
    std::thread O([&] { gang.join(); gang.launch(cr023Fn2, &e2, &stop2); launched.store(true); });   // (4)
    until([&] { return launched.load(); }, 1000);   // a "refuse relaunch" fix may block here
    g_cr023_unpark.store(true);                                                    // (5) F resumes
    std::this_thread::sleep_for(H);
    const bool stalled = !f_done.load();
    std::fprintf(stderr, "  %s child: %lld ms after it resumed, the foreign stopAndJoin is %s; episode 2 launched=%d "
                 "launches=%llu stop2=%d\n", id, static_cast<long long>(H.count()),
                 stalled ? "STILL BLOCKED (waiting out episode 2)" : "returned", static_cast<int>(launched.load()),
                 static_cast<unsigned long long>(gang.stats().launches.load()), static_cast<int>(stop2.load()));
    e2.release.store(true);
    F.join();
    O.join();
    gang.join();
    return (stalled && launched.load()) ? kDefect : kCorrect;
}

}  // namespace

Testing::TestCase testCR023ForeignStopRelaunch(
    "CR-023 [xfail CR-023]: a foreign stopAndJoin returns without waiting out a relaunched episode",
    []() { runXfailGuard("CR-023", cr023Scenario); });

// ----------------------------------------------------------------------------
// Step 16: CR-012 (a)-(d). Two mutators (heaps A and B) share process-wide
// allocator state that each heap's decisions and page work treat as its own:
// (a) the finish trigger reads the process-wide committed bytes; (b) the
// released-extent list; (c) the decommit clock (sync_epoch_) that every
// heap's pauses advance; (d) B's initial region is committed MAP_FIXED over
// the populate window A's helper made resident.
// ----------------------------------------------------------------------------

namespace {

// Heap B: a thread with its own ThreadLocalHeap that runs tasks on request.
class HeapB {
public:
    explicit HeapB(Allocator& a) : a_(a), t_([this] { loop(); }) {
        run([this] { og_ = &AllocatorTestAccess::getThreadHeap(a_)->getOldGen(); });
    }
    ~HeapB() {
        {
            std::lock_guard<std::mutex> lk(m_);
            quit_ = true;
        }
        cv_.notify_all();
        t_.join();
    }
    void run(std::function<void()> f) {   // runs f on B's thread and waits for it
        std::unique_lock<std::mutex> lk(m_);
        task_ = std::move(f);
        done_ = false;
        cv_.notify_all();
        cv_.wait(lk, [this] { return done_; });
    }
    OldGenSpace& og() { return *og_; }

private:
    void loop() {
        a_.initThread();
        std::unique_lock<std::mutex> lk(m_);
        for (;;) {
            cv_.wait(lk, [this] { return quit_ || (task_ && !done_); });
            if (task_ && !done_) {
                auto f = std::move(task_);
                task_ = nullptr;
                lk.unlock();
                f();
                lk.lock();
                done_ = true;
                cv_.notify_all();
                continue;
            }
            if (quit_) break;
        }
        lk.unlock();
        a_.cleanupThread();
    }
    Allocator& a_;
    std::mutex m_;
    std::condition_variable cv_;
    std::function<void()> task_;
    bool done_ = true, quit_ = false;
    OldGenSpace* og_ = nullptr;
    std::thread t_;
};

HeapConfig cr012Config(uint32_t mode) {
    HeapConfig cfg;   // cr018Config's geometry
    cfg.alloc_buffer_size = 64 * 1024;
    cfg.nursery_block_count = 4;
    cfg.nursery_max_block_count = 8;   // two heaps' nursery slices must fit the region
    cfg.initial_old_gen_size = 256 * 1024;
    cfg.max_heap_size = 64ULL * 1024 * 1024;
    cfg.large_object_threshold = 8 * 1024;
    cfg.old_gen_bitmap_alloc = true;
    cfg.incremental_mark = false;
    cfg.conc_mark = 0;
    cfg.commit_ahead_bytes = 0;
    cfg.decommit_on_oldgen_release = false;
    cfg.gc_thread_mode = mode;
    if (mode != 0) {
        cfg.gc_helper_threads = 1;
        cfg.gc_helper_cpu = -1;
    }
    return cfg;
}

// Resident 4 KiB pages of [p, p + n).
size_t residentPages(char* p, size_t n) {
    std::vector<unsigned char> v(n / 4096);
    if (mincore(p, n, v.data()) != 0) return SIZE_MAX;
    size_t r = 0;
    for (unsigned char c : v) r += c & 1;
    return r;
}

// Page work from an earlier test (another mode) is quiesced first, and the
// helper pool returned to unconfigured so the new mode can configure it.
Allocator& cr012Init(const HeapConfig& cfg) {
    abortMeansNotReached();
    HeapConfig q = cfg;
    q.gc_thread_mode = 0;
    q.validate();
    initAllocator(q);
    auto& pool = gc::GCHelperPool::instance();
    if (pool.configured()) {
        pool.drain();
        pool.shutdownForTesting();
    }
    HeapConfig c = cfg;
    c.validate();
    return initAllocator(c);
}

int cr012a() {
    const char* id = "CR-012(a)";
    auto& a = cr012Init(cr012Config(0));
    HeapB B(a);
    bool d0 = true;
    B.run([&] { d0 = OA::cyclePressureFinishDue(B.og()); });
    if (d0) return notReached(id, "B's finish trigger is already due");
    const size_t page = 64 * 1024;
    bool due = false;
    size_t n = 0;
    std::vector<char*> got;
    while (n < 2000 && a.getOldGenCommittedBytes() + page <= a.getOldGenMaxBytes()) {
        got.push_back(AllocatorTestAccess::acquireOldGenBlock(a, page));   // heap A's thread
        ++n;
        B.run([&] { due = OA::cyclePressureFinishDue(B.og()); });
        if (due) break;
    }
    std::fprintf(stderr, "  %s child: after A committed %zu pages (%zu of %zu bytes), B's finish trigger is %s "
                 "although B allocated nothing\n", id, n, a.getOldGenCommittedBytes(), a.getOldGenMaxBytes(),
                 due ? "DUE" : "not due");
    for (char* p : got) AllocatorTestAccess::releaseOldGenBlock(a, p, page);
    return due ? kDefect : kCorrect;
}

int cr012b() {
    const char* id = "CR-012(b)";
    auto& a = cr012Init(cr012Config(0));
    OldGenSpace& ogA = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    HeapB B(a);
    const size_t page = 64 * 1024;
    char* X = nullptr;
    B.run([&] {
        X = AllocatorTestAccess::acquireOldGenBlock(a, page);
        AllocatorTestAccess::releaseOldGenBlock(a, X, page);
    });
    OA::drainUnassignedBlocksForTest(ogA);
    const auto& fl = AllocatorTestAccess::freeBlocks(a);
    if (fl.size() != 1 || fl[0].first != X) return notReached(id, "the free-extent list is not {X}");
    void* p = ogA.allocate(24);
    if (p == nullptr) return notReached(id, "A's allocation failed");
    formatAsBytes(p, 24);
    const BlockId pb = OA::blockOf(ogA, p);
    if (!pb.valid()) return notReached(id, "A's object is not in a valid block");
    char* start = OA::getBlockTable(ogA).info(pb).start;
    std::fprintf(stderr, "  %s child: heap A's new block starts at %p; B released %p\n", id,
                 static_cast<void*>(start), static_cast<void*>(X));
    return start == X ? kDefect : kCorrect;
}

int cr012c() {
    const char* id = "CR-012(c)";
    HeapConfig cfg = cr012Config(2);
    cfg.decommit_on_oldgen_release = true;
    cfg.decommit_delay_syncs = 4;
    auto& a = cr012Init(cfg);
    gc::PageWork* pw = a.pageWork();
    if (pw == nullptr) return notReached(id, "no page work in mode 2");
    HeapB B(a);
    const size_t page = 64 * 1024;
    a.drainHelperWork();
    char* E = AllocatorTestAccess::acquireOldGenBlock(a, page);   // heap A's thread
    std::memset(E, 1, page);
    AllocatorTestAccess::releaseOldGenBlock(a, E, page);
    auto stateOf = [&] {
        int st = 0;
        pw->forEachTracked([&](char* p, size_t, int s) { if (p == E) st = s; });
        return st;
    };
    if (stateOf() != gc::PageWork::kPending) return notReached(id, "E is not Pending after A's release");
    const uint64_t posted0 = pw->counters().discard_posted_extents;
    for (int i = 0; i < 4; ++i) B.run([&] { a.minorGC(); });
    if (stateOf() != gc::PageWork::kPending) return notReached(id, "E is not Pending after B's 4th pause");
    B.run([&] { a.minorGC(); });
    a.drainHelperWork();
    const bool posted = pw->counters().discard_posted_extents == posted0 + 1 && stateOf() == 0;
    const size_t res = residentPages(E, page);
    std::fprintf(stderr, "  %s child: after 5 pauses of heap B (none of A), A's released extent %p is %s, "
                 "%zu of %zu pages resident\n", id, static_cast<void*>(E),
                 posted ? "DISCARDED" : "still tracked", res, page / 4096);
    return (posted && res == 0) ? kDefect : kCorrect;
}

int cr012d() {
    const char* id = "CR-012(d)";
    HeapConfig cfg = cr012Config(2);
    cfg.commit_ahead_bytes = 2ULL << 20;
    auto& a = cr012Init(cfg);
    gc::PageWork* pw = a.pageWork();
    if (pw == nullptr) return notReached(id, "no page work in mode 2");
    a.minorGC();
    a.drainHelperWork();
    const size_t win = 256 * 1024;
    char* bump = AllocatorTestAccess::getHeapBase(a) + a.getOldGenCommitHighWaterBytes();
    const auto& c = pw->counters();
    if (!c.populate_supported) return notReached(id, "MADV_POPULATE_WRITE is not supported");
    if (c.populate_jobs < 1 || pw->windowEnd() < bump + win)
        return notReached(id, "no populate window past the bump");
    const size_t before = residentPages(bump, win);
    if (before != win / 4096) return notReached(id, "the window past the bump is not resident");
    HeapB B(a);   // initThread -> B's old gen region at the bump (commitAt MAP_FIXED)
    char* regionB = B.og().regionBase();
    if (regionB != bump) {
        std::fprintf(stderr, "  %s child: B's region %p, bump %p\n", id, static_cast<void*>(regionB), static_cast<void*>(bump));
        return notReached(id, "B's initial region is not at the bump");
    }
    const size_t after = residentPages(bump, win);
    std::fprintf(stderr, "  %s child: A's helper populated [%p, +256K): %zu pages resident before heap B's "
                 "initThread, %zu after (MAP_FIXED recommit)\n", id, static_cast<void*>(bump), before, after);
    return after < before ? kDefect : kCorrect;
}

}  // namespace

Testing::TestCase testCR012aFinishTrigger(
    "CR-012(a) [xfail CR-012]: a heap's finish trigger never reads another heap's committed bytes",
    []() { runXfailGuard("CR-012(a)", cr012a); });

Testing::TestCase testCR012bFreeList(
    "CR-012(b) [xfail CR-012]: a heap never reuses an extent another heap released",
    []() { runXfailGuard("CR-012(b)", cr012b); });

Testing::TestCase testCR012cDecommitClock(
    "CR-012(c) [xfail CR-012]: another heap's pauses never age a heap's pending discard",
    []() { runXfailGuard("CR-012(c)", cr012c); });

Testing::TestCase testCR012dPopulateWindow(
    "CR-012(d) [xfail CR-012]: a new heap's initial region never drops the populate window",
    []() { runXfailGuard("CR-012(d)", cr012d); });

// ============================================================================
// Serial address-reuse and parse entries found by the TLA+ models (M8, M5,
// M4): CR-033, CR-035, CR-036, CR-038. Each guard derives its scenario from
// the model's counterexample; see the register entry for the trace.
// ============================================================================

// ----------------------------------------------------------------------------
// CR-033 (M8 MC_quick_cr033, BlockParseable). allocateFromBagPage's fresh-page
// carve pushes the remainder only when it is >= MIN_FREE_CELL_SIZE (16 B): a
// request of alloc_buffer_size - 8 leaves an 8-byte tail with no header, so
// the page no longer parses by object size. In legacy old-gen allocation the
// header sweep reads the tail's zero word as a 16-byte Tag_Int, and the free
// cell it pushes there overlaps the next page's first word (S1); the bitmap
// gap sweep never reads the tail (benign).
// ----------------------------------------------------------------------------

namespace {

HeapConfig cr033Config(bool bitmap) {
    HeapConfig cfg = cr018Config();
    cfg.old_gen_bitmap_alloc = bitmap;
    cfg.gc_mark_threads = 1;
    cfg.commit_ahead_bytes = 0;
    cfg.validate();
    return cfg;
}

// A fresh bag page carved at alloc_buffer_size - tail parses by object size.
int cr033Parse(size_t tail) {
    const char* id = tail == 8 ? "CR-033" : "CR-033 control";
    abortMeansNotReached();
    const HeapConfig cfg = cr033Config(true);
    auto& a = initAllocator(cfg);
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    (void)a;
    const size_t page = cfg.alloc_buffer_size;
    const size_t req = page - tail;
    if (req < cfg.large_object_threshold || (req & 7) != 0) return notReached(id, "the request is not in the bag band");
    char* x = static_cast<char*>(oldByteBuf(og, req, 0x33));
    const BlockId b = OA::blockOf(og, x);
    if (!b.valid() || OA::inUniformBlock(og, x)) return notReached(id, "the object is not in a mixed block");
    const BlockInfo& bi = OA::getBlockTable(og).info(b);
    if (x != bi.start || bi.totalBytes() != page || bi.end_of_objects != bi.start + page)
        return notReached(id, "the object is not the carve at the start of a fresh page (Path 4, step 3)");
    uint64_t tailWord = 0;
    std::memcpy(&tailWord, x + req, 8);
    const bool parses = mixedBlockParses(og, b, x);
    std::fprintf(stderr, "  %s child: %zu-byte carve at %p leaves a %zu-byte tail (MIN_FREE_CELL_SIZE %zu), "
                 "first tail word %#llx (tag %u, reads as %zu bytes); the page %s\n", id, req,
                 static_cast<void*>(x), tail, MIN_FREE_CELL_SIZE, static_cast<unsigned long long>(tailWord),
                 static_cast<unsigned>(getHeader(x + req)->tag), getObjectSize(x + req),
                 parses ? "parses to end_of_objects" : "does NOT parse by object size (the walk overruns the page)");
    return parses ? kCorrect : kDefect;
}

// Legacy: the header sweep of the headerless tail never touches the next page.
int cr033S1(bool bitmap) {
    const char* id = bitmap ? "CR-033 S1 control (bitmap)" : "CR-033 S1 (legacy)";
    abortMeansNotReached();
    const HeapConfig cfg = cr033Config(bitmap);
    auto& a = initAllocator(cfg);
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    const size_t page = cfg.alloc_buffer_size;
    constexpr size_t kA = 16 * 1024;
    // A (live) at the start of one bag page; X (live, page - 8) at the start
    // of the page just below it, so X's headerless tail abuts A's header.
    char* A = static_cast<char*>(oldByteBuf(og, kA, 0xA1));
    char* X = static_cast<char*>(oldByteBuf(og, page - 8, 0x58));
    const BlockId ba = OA::blockOf(og, A), bx = OA::blockOf(og, X);
    if (!ba.valid() || !bx.valid() || ba == bx || OA::inUniformBlock(og, A) || OA::inUniformBlock(og, X) ||
        OA::getBlockTable(og).info(ba).start != A || OA::getBlockTable(og).info(bx).start != X) {
        dumpBlocks(id, og);
        return notReached(id, "A and X are not each at the start of their own mixed bag page");
    }
    if (X + page != A) {
        dumpBlocks(id, og);
        return notReached(id, "X's page does not end where A's page starts");
    }
    uint64_t tailWord = 0;
    std::memcpy(&tailWord, X + page - 8, 8);
    if (tailWord != 0) return notReached(id, "the tail word is not the fresh page's zero");
    std::vector<HPointer> roots = {AllocatorTestAccess::toPointer(A), AllocatorTestAccess::toPointer(X)};
    for (auto& r : roots) a.getRootSet().addRoot(&r);
    a.majorGC();
    OA::driveSweepToCompletion(og);
    if (OA::gcPhase(og) != GCPhase::Idle) return notReached(id, "the sweep did not complete");
    if (!OA::blockLive(og, ba) || !OA::blockLive(og, bx)) return notReached(id, "a page was released");
    char* const a2 = static_cast<char*>(AllocatorTestAccess::fromPointer(roots[0]));
    char* const x2 = static_cast<char*>(AllocatorTestAccess::fromPointer(roots[1]));
    if (a2 != A || x2 != X) return notReached(id, "an object moved");
    const bool aOk = byteBufIntact(A, kA, 0xA1);
    const bool xOk = byteBufIntact(X, page - 8, 0x58);
    uint64_t aHdr = 0;
    std::memcpy(&aHdr, A, 8);
    std::fprintf(stderr, "  %s child: after the sweep A's header word is %#llx (tag %u): A %s, X %s\n", id,
                 static_cast<unsigned long long>(aHdr), static_cast<unsigned>(getHeader(A)->tag),
                 aOk ? "intact" : "OVERWRITTEN (the sweep's free cell at X's tail overlaps A's header)",
                 xOk ? "intact" : "overwritten");
    for (auto& r : roots) a.getRootSet().removeRoot(&r);
    return (aOk && xOk) ? kCorrect : kDefect;
}

}  // namespace

Testing::TestCase testCR033FreshPageTailParses(
    "CR-033 [xfail CR-033]: a fresh bag page carved at alloc_buffer_size - 8 parses by object size (bitmap mode)",
    []() { runXfailGuard("CR-033", [] { return cr033Parse(8); }); });

Testing::TestCase testCR033Control(
    "CR-033: negative control, a 64-byte remainder gets a Tag_Free header and the page parses",
    []() { runFixedGuard("CR-033 control", [] { return cr033Parse(64); }); });

Testing::TestCase testCR033LegacySweepS1(
    "CR-033 [xfail CR-033]: legacy old gen, the header sweep of the headerless tail never overwrites the next page's object (S1)",
    []() { runXfailGuard("CR-033 S1 (legacy)", [] { return cr033S1(false); }); });

Testing::TestCase testCR033S1Control(
    "CR-033: S1 negative control, the bitmap gap sweep leaves the next page's object intact",
    []() { runFixedGuard("CR-033 S1 control (bitmap)", [] { return cr033S1(true); }); });

// ----------------------------------------------------------------------------
// CR-035 (M8 MC_quick_cr035 IndexFaithful, MC_quick_cr035_lost NoLostObject).
// A dead YLOS Y sits at the start X of a mixed page P whose live_bytes reads 0
// (CR-018's precondition: Y was carved into P after P's sweep, uncounted). A
// page-sized YLOS Z flips P to large (allocateFromEmptyRegularBlocks, which
// does not purge large_body_index_) and re-registers key X for Z while Y's
// meta still names X. The next minor frees Y's stale meta, which erases key X
// (Z's); the minor after cannot find Z through the index and frees its block
// while Z is live. Serial; the legacy nursery.
// ----------------------------------------------------------------------------

namespace {

int cr035Scenario(bool lostArm) {
    const char* id = lostArm ? "CR-035 (lost object)" : "CR-035 (stale index)";
    abortMeansNotReached();
    HeapConfig cfg = cr018Config();
    cfg.large_ptr_nursery_divisor = 0;   // every pointer-bearing object >= LOT is a YLOS
    cfg.gc_mark_threads = 1;
    cfg.commit_ahead_bytes = 0;
    cfg.validate();
    auto& a = initAllocator(cfg);
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    const size_t page = cfg.alloc_buffer_size;
    // (1) P: a bag page whose only object dies; a STW major (the floor keeps P).
    char* p0 = static_cast<char*>(oldByteBuf(og, 16 * 1024, 0x35));
    const BlockId P = OA::blockOf(og, p0);
    char* const X = OA::getBlockTable(og).info(P).start;
    if (!P.valid() || OA::inUniformBlock(og, p0) || p0 != X) return notReached(id, "the first object is not at a mixed page's start");
    a.majorGC();
    OA::driveSweepToCompletion(og);
    if (!OA::blockLive(og, P) || OA::gcPhase(og) != GCPhase::Idle || !OA::metaOf(og, P).fully_swept ||
        OA::metaOf(og, P).live_bytes != 0)
        return notReached(id, "P is not kept, fully swept and all-dead after the major");
    // (2) Y: a YLOS carved at P's start after the sweep; it dies at once.
    const HPointer nil = alloc::listNil();
    HPointer Yp = alloc::arrayFromPointers(std::vector<HPointer>(1600, nil));
    void* Y = AllocatorTestAccess::fromPointer(Yp);
    if (Y != X || !og.isYoungLarge(Y)) return notReached(id, "Y is not a YLOS at P's start");
    if (!OA::metaOf(og, P).fully_swept || OA::metaOf(og, P).live_bytes != 0 || OA::getBlockTable(og).info(P).is_large)
        return notReached(id, "P's live_bytes counts Y (CR-018's precondition is gone)");
    // (3) Z: a page-sized YLOS; the empty-block flip places it at X.
    const size_t nz = (page - sizeof(ElmArray)) / sizeof(HPointer);
    HPointer Zp = alloc::arrayFromPointers(std::vector<HPointer>(nz, nil));
    a.getRootSet().addRoot(&Zp);
    void* Z = AllocatorTestAccess::fromPointer(Zp);
    if (Z != X || !OA::getBlockTable(og).info(P).is_large || OA::blockOf(og, Z) != P)
        return notReached(id, "Z did not flip P to large at X");
    if (!og.isYoungLarge(Z)) return notReached(id, "Z is not a YLOS");
    const auto& lbs = OA::getLargeBodies(og);
    size_t claim = 0;
    for (OldGenSpace::LargeBodyId b : OA::getNurseryOwnedBodies(og)) {
        if (b < lbs.size() && lbs[b].body_base == X && lbs[b].kind == 1) ++claim;
    }
    std::fprintf(stderr, "  %s child: after the flip, %zu nursery-owned YLOS entries name X %p (Y's dead one and Z's)\n",
                 id, claim, static_cast<void*>(X));
    if (!lostArm) {
        a.getRootSet().removeRoot(&Zp);
        return claim > 1 ? kDefect : kCorrect;
    }
    // (4) The lost object: two minors (Z rooted throughout).
    const Header z0 = *getHeader(Z);
    auto zIntact = [&] {
        const Header* hz = getHeader(Z);
        if (hz->tag != z0.tag || hz->size != z0.size) return false;
        const ElmArray* arr = static_cast<const ElmArray*>(Z);
        for (size_t i = 0; i < nz; ++i) if (bits(arr->elements[i].p) != bits(nil)) return false;
        return true;
    };
    a.minorGC();   // minor 1: Y's stale meta is freed -> erase(X), Z's key
    if (AllocatorTestAccess::fromPointer(Zp) != Z || !zIntact()) return notReached(id, "Z moved or changed at minor 1");
    const bool indexed1 = og.largeBodyIndexed(X);
    std::fprintf(stderr, "  %s child: after minor 1 key X is %s\n", id, indexed1 ? "indexed" : "GONE (Y's free erased Z's key)");
    a.minorGC();   // minor 2: Z is not found through the index
    bool onFreeLarge = false;
    for (BlockId fb : OA::getFreeLargeBlocks(og)) onFreeLarge |= fb == P;
    const bool ok = AllocatorTestAccess::fromPointer(Zp) == Z && zIntact() && !onFreeLarge;
    std::fprintf(stderr, "  %s child: after minor 2 the live Z at %p: header tag %u, %s; P %s free_large_blocks_\n", id, Z,
                 static_cast<unsigned>(getHeader(Z)->tag), ok ? "intact" : "FREED while live",
                 onFreeLarge ? "ON" : "not on");
    a.getRootSet().removeRoot(&Zp);
    return ok ? kCorrect : kDefect;
}

}  // namespace

Testing::TestCase testCR035StaleIndexAtFlip(
    "CR-035 [xfail CR-035]: the empty-block flip leaves no stale large-body entry naming the new object's address",
    []() { runXfailGuard("CR-035 (stale index)", [] { return cr035Scenario(false); }); });

Testing::TestCase testCR035LostObject(
    "CR-035 [xfail CR-035]: a live YLOS placed by the empty-block flip survives the next two minors",
    []() { runXfailGuard("CR-035 (lost object)", [] { return cr035Scenario(true); }); });

// ----------------------------------------------------------------------------
// CR-036 (M8 MC_quick_reissue_witness, witness NoSameIdSameStartReissue). A
// block released at a major comes back, serially, with the same id (LIFO
// BlockTable ids), the same start (first-fit old_gen_free_blocks_) and the
// same class: exactly the key IM5's t0-block check (checkT0BlocksUnchanged:
// id, start, size_class, is_large) compares, so a release-and-re-issue inside
// a cycle would pass it. A validator coverage gap, not a live defect; this
// guard is a WITNESS that the re-issue is reachable. It flips when a re-issued
// block becomes distinguishable (a per-id generation, the register's fix
// candidate; extend the key below when one exists).
// ----------------------------------------------------------------------------

namespace {

int cr036Witness() {
    const char* id = "CR-036 witness";
    abortMeansNotReached();
    HeapConfig cfg = cr018Config();
    cfg.initial_old_gen_size = 64 * 1024;   // the floor is one page: the major may release D
    cfg.gc_mark_threads = 1;
    cfg.commit_ahead_bytes = 0;
    cfg.validate();
    auto& a = initAllocator(cfg);
    OldGenSpace& og = AllocatorTestAccess::getThreadHeap(a)->getOldGen();
    char* const heapBase = AllocatorTestAccess::getHeapBase(a);
    // K (live) takes the initial page (heap_base, never reused for a page).
    HPointer k = AllocatorTestAccess::toPointer(oldByteBuf(og, 16 * 1024, 0x4B));
    a.getRootSet().addRoot(&k);
    // D: a class-24 virgin block on a fresh page; its only cell dies.
    void* d = og.allocate(24);
    formatAsBytes(d, 24);
    const BlockId D = OA::blockOf(og, d);
    const BlockInfo di = OA::getBlockTable(og).info(D);
    if (!D.valid() || !OA::inUniformBlock(og, d) || di.start == heapBase || !OA::getUnassignedBlocks(og).empty())
        return notReached(id, "D is not a uniform block off heap_base with the bag empty");
    a.majorGC();   // reclaimAllDeadBlocksFromMeta releases D (above the floor)
    OA::driveSweepToCompletion(og);
    const bool released = !OA::blockLive(og, D) || OA::getBlockTable(og).info(D).start != di.start;
    const auto& fb = AllocatorTestAccess::freeBlocks(a);
    if (!released || fb.empty() || fb.front().first != di.start || !OA::getUnassignedBlocks(og).empty())
        return notReached(id, "D was not released to the front of the free-extent list with the bag empty");
    // E: the next class-24 allocation materialises a virgin block.
    void* e = og.allocate(24);
    formatAsBytes(e, 24);
    const BlockId E = OA::blockOf(og, e);
    const BlockInfo& ei = OA::getBlockTable(og).info(E);
    const bool sameKey = E == D && ei.start == di.start && ei.size_class == di.size_class && ei.is_large == di.is_large;
    std::fprintf(stderr, "  %s child: D (id %u, start %p, class %zu) released at the major; the next virgin block is "
                 "id %u, start %p, class %zu%s\n", id, D.v, static_cast<void*>(di.start), di.size_class, E.v,
                 static_cast<void*>(ei.start), ei.size_class,
                 sameKey ? " -- IM5's key {id, start, class, is_large} cannot tell the two apart" : "");
    a.getRootSet().removeRoot(&k);
    return sameKey ? kDefect : kCorrect;
}

}  // namespace

Testing::TestCase testCR036ReissueWitness(
    "CR-036 [xfail CR-036]: witness, a released block is never re-issued with the same id, start and class (IM5's key)",
    []() { runXfailGuard("CR-036 witness", cr036Witness); });

// ----------------------------------------------------------------------------
// CR-038 (M5 MC_k2_ylos_walk, YoungWalkValid; k = 2, no major). A PREMISE-
// DRIFT WITNESS, benign today: o is copied into X1 at minor 1; a YLOS Y -> o
// is first reached at minor 2 (it joins X2's generation; X1 is ageing); Y
// dies; at minor 3 X1 is handed over (o tenured) and X2 ages, but the dead Y
// is never scanned, so its slot into X1 is never healed; minor 4 retires X1,
// and that minor's t0 (snapshotYoungLarge) walks every young YLOS, the dead Y
// included, whose slot names a cell of the retired X1. The snapshot drops a
// young target by range, so nothing is greyed; but 07b's zap premise ("no
// dead object's slot is read after its extent is retired") does not hold for
// YLOS. The control keeps Y alive: the ageing mark heals its slot.
// ----------------------------------------------------------------------------

namespace {

int cr038Scenario(bool control) {
    const char* id = control ? "CR-038 control (live Y)" : "CR-038";
    abortMeansNotReached();
    auto& a = initRegionAllocator(cr017Config(2));
    ThreadLocalHeap* h = AllocatorTestAccess::getThreadHeap(a);
    NurserySpace& ns = h->getNursery();
    OldGenSpace& og = h->getOldGen();
    RegionState* R = NurserySpaceTestAccess::region(ns);
    if (!ns.regionMode() || R == nullptr || R->tenure_age != 2) return notReached(id, "no region nursery at k = 2");
    auto inX = [&](int j, const void* p) {
        const char* c = static_cast<const char*>(p);
        return c >= R->x[j].base && c < R->x[j].base + R->set.capacity;
    };
    // minor 1: o -> X1.
    HPointer o = alloc::allocInt(0x38);
    a.getRootSet().addRoot(&o);
    a.minorGC();
    const int j1 = R->extentOf(a.resolve(o));
    if (j1 < 0 || R->x[j1].state != region::XState::Young || R->x[j1].age != 1)
        return notReached(id, "o is not in a Young age-1 extent X1");
    void* const oX1 = a.resolve(o);
    // Y -> o, a YLOS, reached first at minor 2.
    HPointer Yp = alloc::arrayFromPointers(std::vector<HPointer>(1600, o));
    a.getRootSet().addRoot(&Yp);
    void* const Y = AllocatorTestAccess::fromPointer(Yp);
    if (!og.isYoungLarge(Y)) return notReached(id, "Y is not a YLOS");
    auto* arr = static_cast<ElmArray*>(Y);
    const uint64_t slot0 = bits(arr->elements[0].p);
    if (AllocatorTestAccess::fromPointer(arr->elements[0].p) != oX1) return notReached(id, "Y's slot does not name o in X1");
    const uint64_t seq0 = R->minor_seq;
    a.minorGC();   // minor 2: Y joins X2's generation; X1 ages
    int j2 = -1;
    for (unsigned u = 0; u < R->n_surv; ++u) {
        const region::Extent& Ex = R->x[u];
        if (Ex.state == region::XState::Young && Ex.age == 1 &&
            std::find(Ex.ylos_gen.begin(), Ex.ylos_gen.end(), Y) != Ex.ylos_gen.end()) j2 = static_cast<int>(u);
    }
    if (j2 < 0 || j2 == j1 || R->x[j1].state != region::XState::Young || R->x[j1].age != 2 || !og.isYoungLarge(Y))
        return notReached(id, "Y did not join X2's generation with X1 ageing");
    if (!control) a.getRootSet().removeRoot(&Yp);   // Y dies in epoch 2
    a.minorGC();   // minor 3: X1 handed over (o tenured), X2 ages; the dead Y is never scanned
    if (R->x[j1].state != region::XState::Tenuring || R->x[j2].state != region::XState::Young || R->x[j2].age != 2)
        return notReached(id, "X1 is not Tenuring with X2 ageing after minor 3");
    if (!og.isYoungLarge(Y)) return notReached(id, "Y is no longer a young YLOS after minor 3");
    // o's copy is made by the hand-over's tenure job; the extent (and o's
    // forwarded cell in it) stays until X1 retires at minor 4.
    if (!control && bits(arr->elements[0].p) != slot0) return notReached(id, "the dead Y's slot changed at minor 3");
    // minor 4: X1 retires; a forced trigger's t0 walks every young YLOS.
    if (og.cycleActive() || OA::isMarked(og, Y)) return notReached(id, "a cycle is active, or Y is marked, before minor 4");
    h->test_force_major_trigger_ = true;
    a.minorGC();
    if (R->minor_seq != seq0 + 3) return notReached(id, "an extra minor ran");
    if (!og.cycleActive()) return notReached(id, "the forced trigger did not start a mark cycle");
    const bool walked = OA::isMarked(og, Y);   // snapshotYoungLarge marks every young YLOS it walks
    const region::Extent& X1 = R->x[j1];
    const bool retired = X1.state == region::XState::Free ||
                         (X1.state == region::XState::Young && X1.gen_minor > seq0);
    const uint64_t s = bits(arr->elements[0].p);
    const bool intoX1 = inX(j1, AllocatorTestAccess::fromPointer(arr->elements[0].p));
    std::fprintf(stderr, "  %s child: at minor 4's t0 the snapshot %s Y %p; X1 (extent %d) is %s; Y's slot %#llx %s\n",
                 id, walked ? "walked" : "did NOT walk", Y, j1,
                 X1.state == region::XState::Free ? "Free (retired)" :
                 X1.state == region::XState::Tenuring ? "Tenuring" : "Young", static_cast<unsigned long long>(s),
                 intoX1 ? "points into the RETIRED X1 (never healed)" : "does not point into X1");
    if (!walked) return notReached(id, "the t0 snapshot did not walk Y");
    if (!retired) return notReached(id, "X1 is not retired at minor 4");
    for (int g = 0; g < 64 && og.cycleActive(); ++g) a.minorGC();
    if (control) a.getRootSet().removeRoot(&Yp);
    a.getRootSet().removeRoot(&o);
    return intoX1 ? kDefect : kCorrect;
}

}  // namespace

Testing::TestCase testCR038DeadYlosSlotIntoRetired(
    "CR-038 [xfail CR-038]: premise-drift witness, k=2, no young YLOS the t0 snapshot walks holds a slot into a retired extent",
    []() { runXfailGuard("CR-038", [] { return cr038Scenario(false); }); });

Testing::TestCase testCR038Control(
    "CR-038: negative control, a live ageing-generation YLOS's slot is healed before its target's extent retires",
    []() { runFixedGuard("CR-038 control (live Y)", [] { return cr038Scenario(true); }); });
