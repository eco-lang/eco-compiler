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
#include <sys/wait.h>
#include <unistd.h>
#endif

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "GCHelperPool.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "MinorWork.hpp"
#include "NurserySpace.hpp"
#include "OldGenSpace.hpp"
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
