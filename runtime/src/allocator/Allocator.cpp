/**
 * Allocator Implementation.
 *
 * This file implements the central allocator that manages:
 *   - Unified heap address space (reserved via mmap, committed on demand).
 *   - Thread-local heaps for each thread (nursery + old gen + stats).
 *   - Delegation to thread-local heaps for allocation and GC.
 *
 * Memory layout (HEAP_043 — the split is configuration, not a constant):
 *   [0 .. nursery_offset)       - Old generation region (carved up per-thread),
 *                                 where nursery_offset = max_heap_size
 *                                 - nursery_region_bytes (20 GiB by default).
 *   [nursery_offset .. end)     - Nursery region, halved into low and high
 *                                 halves and carved into fixed-size slices,
 *                                 one pair per thread heap (HEAP_042).
 */

#include "Allocator.hpp"
#include "GCFork.hpp"
#include "GCHelperPool.hpp"
#include "HeapConfigJson.hpp"
#include "PageWork.hpp"
#include "OldGenSpace.hpp"
#include "PermanentSpace.hpp"
#include "PlatformVirtualMemory.hpp"
#include "ThreadLocalHeap.hpp"
#include "TlaTrace.hpp"   // compiled-out hooks (trace builds only: the M6 fork harness)
#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <new>
#include <stdexcept>
// musl (Stage B static build) ships no <execinfo.h>/backtrace; stub them as
// no-ops so the debug paths compile. glibc keeps its real backtrace. See
// plans/static-link-eco-binary.md. Windows ships no <execinfo.h> either —
// the same stub path serves there. Crash backtraces on Win64 will route
// through `RtlVirtualUnwind` once W2 item 11b lands.
#if defined(__has_include) && __has_include(<execinfo.h>)
#  include <execinfo.h>
#else
[[maybe_unused]] static inline int backtrace(void**, int) { return 0; }
[[maybe_unused]] static inline char** backtrace_symbols(void* const*, int) { return nullptr; }
[[maybe_unused]] static inline void backtrace_symbols_fd(void* const*, int, int) {}
#endif

// madvise(MADV_WILLNEED / MADV_DONTNEED) lives in <sys/mman.h> on POSIX. On
// Windows there is no equivalent advisory call — the working set is
// managed by the OS — so we stub madvise to a no-op and define the macros
// to harmless integers. Callers don't inspect the return value.
#if !defined(_WIN32)
#include <sys/mman.h>
#if defined(__GLIBC__)
#include <malloc.h>   // malloc_trim (collectMajorAndRelease)
#endif
#else
namespace {
[[maybe_unused]] constexpr int MADV_WILLNEED = 0;
[[maybe_unused]] constexpr int MADV_DONTNEED = 0;
[[maybe_unused]] inline int madvise(void*, std::size_t, int) { return 0; }
}
#endif

namespace Elm {
ECO_TLA_TRACE_ONLY(namespace gc { extern bool tla_m6; })   // GCHelperPool.cpp: M6 probes fire while set

// Global heap base for pointer conversion (used by fromPointerRaw/toPointerRaw).
char* g_heap_base = nullptr;

namespace {

// Coarse milestone interval for heap-growth traces. Emitting one line per
// block acquire is prohibitively spammy (a 4 GB old-gen fill is ~32k blocks
// at 128 KB each); logging only when the committed counter crosses a
// multiple of this granularity gives a readable growth history.
constexpr size_t HEAP_TRACE_OLDGEN_INTERVAL   = 32 * 1024 * 1024;  // 32 MB.
constexpr size_t HEAP_TRACE_NURSERY_INTERVAL  = 16 * 1024 * 1024;  // 16 MB.

}  // namespace

bool Allocator::heapTraceEnabled() {
#if ECO_HEAP_TRACE
    static const bool enabled = []{
        const char* e = std::getenv("ECO_HEAP_TRACE");
        if (e == nullptr || e[0] == '\0') return false;
        // Treat "0" (single-char) as disabled, everything else as enabled.
        return !(e[0] == '0' && e[1] == '\0');
    }();
    return enabled;
#else
    // Compile-time off: every `if (heapTraceEnabled())` guard becomes dead
    // code and the trace block is eliminated by the optimiser. Build with
    // `-DECO_HEAP_TRACE=ON` to re-enable.
    return false;
#endif
}

void Allocator::dumpHeapState([[maybe_unused]] const char* label,
                              [[maybe_unused]] size_t pending_size) const {
#if ECO_HEAP_TRACE
    // Aggregate size of released-but-not-yet-reused old-gen blocks.
    size_t free_blocks_bytes = 0;
    for (const auto& fb : old_gen_free_blocks_) free_blocks_bytes += fb.second;

    std::fprintf(stderr,
        "[heap-trace] %s oldgen_committed=%.2f MB nursery_low=%.2f MB "
        "nursery_high=%.2f MB (oldgen_cap=%.2f GB, heap_reserved=%.2f GB) "
        "freed_oldgen_blocks=%zu (%.2f MB)",
        label,
        old_gen_committed / (1024.0 * 1024.0),
        nursery_low_committed_ / (1024.0 * 1024.0),
        nursery_high_committed_ / (1024.0 * 1024.0),
        nursery_offset / (1024.0 * 1024.0 * 1024.0),
        heap_reserved / (1024.0 * 1024.0 * 1024.0),
        old_gen_free_blocks_.size(),
        free_blocks_bytes / (1024.0 * 1024.0));

    if (pending_size != 0) {
        std::fprintf(stderr, " pending_size=%zu B (%.2f KB)",
                     pending_size, pending_size / 1024.0);
    }

    // Thread-local detail for the calling thread (other thread heaps exist
    // but walking them requires the mutex; the caller may already hold it,
    // so we stick to the cheap current-thread view).
    if (tl_heap_) {
        const OldGenSpace& og = tl_heap_->getOldGen();
        const auto& meta = OldGenSpaceTestAccess::getBufferMeta(og);
        size_t free_pages = 0;
        for (const auto& m : meta) {
            if (m.fully_swept && m.live_bytes == 0) ++free_pages;
        }
        const auto& frag = OldGenSpaceTestAccess::getFragStats(og);
        const double util = frag.heap_bytes > 0
            ? static_cast<double>(frag.live_bytes) / frag.heap_bytes
            : 0.0;
        std::fprintf(stderr,
                     " tl.oldgen_allocated=%.2f MB tl.committed=%.2f MB"
                     " tl.live=%.2f MB tl.heap=%.2f MB tl.util=%.2f"
                     " tl.free_large=%zu tl.free_pages=%zu tl.unassigned=%zu",
                     tl_heap_->getOldGenAllocatedBytes() / (1024.0 * 1024.0),
                     og.getCommittedBytes() / (1024.0 * 1024.0),
                     frag.live_bytes / (1024.0 * 1024.0),
                     frag.heap_bytes / (1024.0 * 1024.0),
                     util,
                     OldGenSpaceTestAccess::getFreeLargeBlocks(og).size(),
                     free_pages,
                     OldGenSpaceTestAccess::getUnassignedBlocks(og).size());
    }
    std::fputc('\n', stderr);
#endif  // ECO_HEAP_TRACE
}

// Thread-local heap pointer for fast access.
constinit thread_local ThreadLocalHeap* Allocator::tl_heap_ = nullptr;

// Codegen-visible cache of `tl_heap_->getNursery().bumpState()`
// (plans/inline-bump-state-tls.md). Holds exactly what eco_bump_state()
// returns, so expandInlineAllocs can read the nursery bump state with a TLS
// load instead of a call — 10.46 B calls on one self-compile per the survivor
// census. `extern "C"`: the backend references this symbol by name, so it must
// not be mangled. constinit + initial-exec for the same reasons as `tl_heap_`
// (no dynamic-init guard, no __tls_get_addr call under -fPIC).
//
// The address is thread-stable: `nursery_` is a direct member of
// ThreadLocalHeap and `bump_` a direct member of NurserySpace, so `&bump_`
// never moves for the heap's lifetime — only its contents change, and the
// inline expansion re-loads those per allocation.
//
// NEVER assign this outside Allocator::setThreadHeap: a value that disagrees
// with `tl_heap_` is heap corruption, not a wrong statistic.
extern "C" constinit thread_local void* eco_tl_bump_state
    __attribute__((tls_model("initial-exec"))) = nullptr;

// The ONLY writer of `tl_heap_`. Keeping both in one function is what makes
// the compiled-code bump-state cache correct by construction rather than by
// remembering to update two things at four call sites.
void Allocator::setThreadHeap(ThreadLocalHeap* h) {
    tl_heap_ = h;
    eco_tl_bump_state = h ? static_cast<void*>(h->getNursery().bumpState())
                          : nullptr;

    // GC shadow root stack (plans/gc-root-registration-cost.md O1). Same rule,
    // same place, same reason as the bump-state cache above: the three cursors
    // must never disagree with `tl_heap_`, and keeping every write in this one
    // function is what makes that true by construction.
    //
    // The cursor is reset to the array start on attach. Both transitions that
    // reach here — initThread on a fresh thread, cleanupThread/reset on
    // teardown — happen with no C++ or compiled frame holding a pushed range,
    // so there is never a live entry to preserve across them.
    if (h) {
        RootSet& rs = h->getRootSet();
        StackRootRangeRec* storage = rs.rangeStorage();
        eco_tl_root_base = storage;
        eco_tl_root_limit = storage + kRootRangeStackSlots;
        eco_tl_root_sp = storage;
        HPointer** one = rs.root1Storage();
        eco_tl_root1_base = one;
        eco_tl_root1_limit = one + kRoot1StackSlots;
        eco_tl_root1_sp = one;
    } else {
        eco_tl_root_base = nullptr;
        eco_tl_root_limit = nullptr;
        eco_tl_root_sp = nullptr;
        eco_tl_root1_base = nullptr;
        eco_tl_root1_limit = nullptr;
        eco_tl_root1_sp = nullptr;
    }
}

Allocator::Allocator() :
    heap_base(nullptr), heap_reserved(0),
    old_gen_committed(0), old_gen_in_use_bytes_(0), old_gen_in_use_peak_(0),
    nursery_offset(0),
    nursery_low_committed_(0), nursery_high_committed_(0),
    nursery_slice_bytes_(0), initialized(false) {
    // Initialization happens in initialize() method.
}

// TLA-REGION(AL.destructor) begin
Allocator::~Allocator() {
    // Clean up all thread heaps.
    std::unordered_map<std::thread::id, std::unique_ptr<ThreadLocalHeap>> doomed;
    {
        std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
        // threaded-gc-03: no helper job may outlive the PageWork it points at.
        if (page_work_) page_work_->drainAll(/*discard_pending=*/false);
        dropForkDeadHeapsLocked();   // CR-031 / HEAP_007: never tear down a dead heap
        doomed.swap(thread_heaps_);
    }
    // HEAP_075: the teardown (tenureTeardown -> stopAndJoin, ~GCBackgroundGang's
    // registry) runs OUTSIDE thread_mutex_; a heap's destruction re-takes it per call.
    doomed.clear();

    if (heap_base) {
        Elm::platform::releaseReservation(heap_base, heap_reserved);
    }
}
// TLA-REGION(AL.destructor) end

// The configuration a process runs: `base`, then the JSON overrides from
// $ECO_HEAP_CONFIG (HeapConfigJson.hpp), then the ECO_GC_* / ECO_NURSERY_*
// variables (threaded-gc-03: they win over JSON), resolved and validated.
// initialize() adopts it; EcoRunner::reset() re-installs it in every E2E
// child (plans/region-nursery-everywhere.md Phase 2).
HeapConfig Allocator::environmentConfig(const HeapConfig& base, uint32_t& helper_jitter_us) {
    HeapConfig c = base;
    applyHeapConfigFromEnv(c);
    applyGcThreadEnv(c, helper_jitter_us);
    c.resolveNurseryRegions();   // TG7d: auto -> 1; incompatible throws
    c.validate();
    return c;
}

// Initializes the allocator with the given configuration.
// Validates config and reserves address space. Physical memory committed lazily.
void Allocator::initialize(const HeapConfig& config) {
    // HEAP_075: GCFork's allocator layer (thread_mutex_). Registered with no runtime
    // lock held (GCFork.hpp); idempotent.
    static const gc::ForkHooks kAllocatorHooks{&Allocator::forkPrepare, &Allocator::forkParent,
                                               &Allocator::forkChild};
    gc::registerForkLayer(gc::kForkAllocator, kAllocatorHooks);
    if (initialized) {
        return;
    }
    ++heap_generation_;  // new heap epoch (invalidates cross-lifetime caches)

    // Apply JSON overrides from $ECO_HEAP_CONFIG, if set, on top of the
    // caller-supplied defaults. Lets us tweak heap parameters without a
    // rebuild — see HeapConfigJson.hpp for the recognised keys.
    config_ = environmentConfig(config, helper_jitter_us_);

    heap_reserved = config_.max_heap_size;

    // The HPointer representation stores raw absolute heap addresses in the low
    // 43 bits of a 64-bit word, so the entire heap must live below 2^43 (8 TB).
    // Reject configurations that cannot fit, then reserve a low base. This is
    // harmless under the legacy heap_base-relative encoding (pointers are
    // offsets from heap_base wherever it lands) and de-risks the representation
    // flip. See plan D7.
    if (heap_reserved > HPOINTER_ADDRESS_LIMIT) {
        throw std::invalid_argument(
            "max_heap_size exceeds the 8 TB HPointer address limit");
    }

    // Reserve address space without committing physical memory — see
    // PlatformVirtualMemory.hpp for the POSIX (mmap PROT_NONE) and Win64
    // (VirtualAlloc MEM_RESERVE PAGE_NOACCESS) implementations.
    heap_base = static_cast<char *>(
        Elm::platform::reserveAddressSpaceBelow(heap_reserved,
                                                HPOINTER_ADDRESS_LIMIT));

    if (heap_base == nullptr) {
        throw std::bad_alloc();
    }

    // Post-condition: the whole reservation fits below the HPointer address
    // limit, so every heap address round-trips through an HPointer word.
    assert(reinterpret_cast<uintptr_t>(heap_base) + heap_reserved
               <= HPOINTER_ADDRESS_LIMIT &&
           "heap reservation must fit below 2^43 for HPointer encoding");

    // Set global heap_base for pointer conversion.
    g_heap_base = heap_base;

    // The nursery region occupies the TOP `nursery_region_bytes` of the
    // reservation; the old generation gets everything below it (HEAP_043).
    // Computed once — first init wins for the process lifetime, exactly as
    // before (reset() re-derives slice geometry but never the region).
    nursery_offset = heap_reserved - config_.nurseryRegionBytes();

    // Slice geometry follows the config against that region (HEAP_042).
    rebuildNurserySliceTable();

    runtime_start_ns_ = static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());

    // threaded-gc-03: helper pool + page work (modes 1/2 only).
    rebuildPageWork();

    initialized = true;
}

// CR-031 / HEAP_007 (plans/threaded-gc-register-fixes.md §7.1, §7.2 step 7): in a
// forked child only the forking thread's heap is live; the others' mutators do not
// exist here, and their tables (RootSet, the tenure job, gang state) may have been
// mid-update at the fork. They are leaked: never collected, never torn down, never
// read. Caller holds thread_mutex_.
void Allocator::dropForkDeadHeapsLocked() {
    if (!fork_child_) return;
    for (auto it = thread_heaps_.begin(); it != thread_heaps_.end();) {
        if (it->first != fork_owner_) {
            (void)it->second.release();
            it = thread_heaps_.erase(it);
        } else {
            ++it;
        }
    }
}

// HEAP_075 / CR-015 (plans/threaded-gc-register-fixes.md §7.2 step 3): the allocator
// layer of the one fork registration. It runs after the gangs layer (a gang member
// may block on thread_mutex_ under promo_mu_ while its run holds run_m_) and before
// the census and the pool (every post and wait holds thread_mutex_, so with it held
// no post can land between the pool's drain and its lock).
void Allocator::forkPrepare() { instance().thread_mutex_.lock(); }
void Allocator::forkParent() { instance().thread_mutex_.unlock(); }
void Allocator::forkChild() {
    Allocator& a = instance();
    // Re-create in place: unlocking the recursive mutex here would fail (glibc checks
    // the owner TID, which differs in the child).
    new (&a.thread_mutex_) std::recursive_mutex();
    a.fork_child_ = true;
    a.fork_owner_ = std::this_thread::get_id();
}

// Commits physical memory for a nursery region.
void Allocator::commitNursery(char *nursery_base, size_t size) {
    void *result = Elm::platform::commitAt(nursery_base, size);

    if (result == nullptr) {
        throw std::bad_alloc();
    }
}

// Singleton storage for `Allocator::instance()`. Namespace-scope so the
// accessor can be inlined to a single fixed-address load. The default
// constructor is trivial (just zeros pointers/counters), so static-init-order
// concerns do not apply — real initialization runs in `initialize()`.
Allocator g_allocator_storage;

// Initializes the calling thread's heap space.
void Allocator::initThread() {
    // Ensure allocator is initialized.
    if (!initialized) {
        initialize();
    }

    // Check if this thread already has a heap.
    if (tl_heap_ != nullptr) {
        return;  // Already initialized.
    }

    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
    // HEAP_007: a forked child may call initThread for a fresh heap; dead heaps of
    // threads that do not exist in it are not live mutators (CR-012's check below).
    dropForkDeadHeapsLocked();

    // Double-check after acquiring lock.
    auto thread_id = std::this_thread::get_id();
    if (thread_heaps_.find(thread_id) != thread_heaps_.end()) {
        setThreadHeap(thread_heaps_[thread_id].get());
        return;
    }

    // HEAP_007 / CR-012 (option F): one live mutator per process. A second
    // live ThreadLocalHeap shares the process-wide committed bytes, decommit
    // clocks and released-extent list with the first (per-heap GC_DET_001
    // breaks), so it is forbidden outside the benchmark/test opt-in.
    if (!thread_heaps_.empty() && !multi_mutator_opt_in_) {
        std::fprintf(stderr, "[eco] FATAL: a second mutator thread called initThread while "
            "another ThreadLocalHeap is live (HEAP_007: one mutator per process; CR-012). "
            "Only benchmark/test harnesses may call Allocator::allowMultipleMutators(true).\n");
        std::fflush(stderr);
        std::abort();
    }

    // Create ThreadLocalHeap.
    // Memory is allocated on demand by NurserySpace (via
    // acquireNurserySlicePair, HEAP_042) and OldGenSpace (via
    // acquireAllocBuffer).
    auto heap = std::make_unique<ThreadLocalHeap>(
        this,
        nullptr, 0,    // Nursery base/size - allocated on demand
        nullptr, 0, 0, // Old gen base/initial/max - allocated on demand
        &config_
    );

#if ECO_HEAP_VALIDATE
    heap->owner_ = thread_id;   // HEAP_007 / CR-031: minorGC / majorGC check it
#endif
    setThreadHeap(heap.get());
    thread_heaps_[thread_id] = std::move(heap);
}

// Cleans up the calling thread's heap space.
// TLA-REGION(AL.cleanupThread) begin
void Allocator::cleanupThread() {
    if (tl_heap_ == nullptr) {
        return;  // Nothing to clean up.
    }

    // HEAP_075 (plans/threaded-gc-register-fixes.md §7.2 step 2): no teardown holds
    // thread_mutex_ while it takes a gang lock (tenureTeardown -> stopAndJoin,
    // ~GCBackgroundGang's registry): a fork's prepare holds the gangs and then asks
    // for thread_mutex_ (M7 LockOrder, mutant teardown_under_tm).
    std::unique_ptr<ThreadLocalHeap> doomed;
    {
        std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
        auto it = thread_heaps_.find(std::this_thread::get_id());
        if (it != thread_heaps_.end()) {
            doomed = std::move(it->second);
            thread_heaps_.erase(it);
        }
    }
    if (doomed) {
        // threaded-gc-07 (P§3.15): the last tenure job is finished and given
        // a stats-only merge before the heap's stats are folded.
        doomed->getNursery().tenureTeardown(doomed->getOldGen());
#if ENABLE_GC_STATS
        {
            // Accumulate stats from this thread heap before destroying it.
            std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
            accumulated_stats_.combine(doomed->getNursery().getStats());
            accumulated_stats_.combine(doomed->getOldGen().getStats());
            accumulated_stats_.combine(doomed->getStats());
        }
#endif
        doomed.reset();
    }

    setThreadHeap(nullptr);
}
// TLA-REGION(AL.cleanupThread) end

// threaded-gc-07 (P§3.15): at process exit, before the stats banner, the
// calling thread's last tenure job is stopped or joined, finished on this
// thread if needed and given a stats-only merge, so run totals include it.
// TLA-REGION(AL.finishTenureForExit) begin
void Allocator::finishTenureForExit() {
    if (tl_heap_ == nullptr) return;
    // HEAP_075: no thread_mutex_ around the teardown (it joins the tenure collector).
    tl_heap_->getNursery().tenureTeardown(tl_heap_->getOldGen());
}
// TLA-REGION(AL.finishTenureForExit) end

// Slow path for `getRootSet()` — used by external callers that may run
// before `initThread()` has been called on the current thread (e.g.
// Scheduler, PlatformRuntime registering external root scanners).
RootSet &Allocator::getRootSetSlow() {
    if (!tl_heap_) {
        initThread();
    }
    return tl_heap_->getRootSet();
}

// Allocates a heap object of the given size with the specified tag.
void *Allocator::allocate(size_t size, Tag tag) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocate(size, tag);
}

// Fast-path: bump-pointer only, no GC.
void *Allocator::allocateFast(size_t size) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocateFast(size);
}

// Slow-path: may GC, always succeeds or aborts.
void *Allocator::allocateSlow(size_t size, Tag tag) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocateSlow(size, tag);
}

// Inline-alloc slow path: minor GC + retry, no header init (HEAP_034).
void *Allocator::allocateSlowRaw(size_t size) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocateSlowRaw(size);
}

// Address of the calling thread's nursery bump state (HEAP_034).
void *Allocator::bumpState() {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->getNursery().bumpState();
}

// Hoisted-capacity-check guarantee: headroom without allocation (HEAP_041).
void Allocator::ensureNursery(size_t n) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    tl_heap_->ensureNursery(n);
}

// Slow-path region: contiguous allocation, may GC.
void *Allocator::allocateRegionSlow(size_t total) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocateRegionSlow(total);
}

// Allocates directly in old generation (bypasses nursery).
void *Allocator::allocatePermanent(size_t size, Tag tag) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocatePermanent(size, tag);
}

HPointer Allocator::allocLargeString(const u16* chars, size_t length) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocLargeString(chars, length);
}

HPointer Allocator::allocLargeByteBuffer(const u8* data, size_t length) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocLargeByteBuffer(data, length);
}

// Triggers a minor GC on the thread-local nursery.
void Allocator::minorGC() {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    tl_heap_->minorGC();
}

// Triggers a major GC on the thread-local old gen.
void Allocator::majorGC() {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    tl_heap_->majorGC();
}

bool Allocator::shouldCollectAtSafepoint() {
    return tl_heap_ && tl_heap_->shouldCollectAtSafepoint();
}

void Allocator::collectAtSafepoint() {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    tl_heap_->collectAtSafepoint();
}

// Returns true if the thread-local nursery usage exceeds the threshold.
bool Allocator::isNurseryNearFull(float threshold) {
    if (tl_heap_) {
        return tl_heap_->isNurseryNearFull(threshold);
    }
    return false;
}

// `Allocator::isInNursery` is defined inline at the bottom of Allocator.hpp.

// Validates an HPointer without dereferencing (so it's SEGV-safe even when
// fed unboxed Int bits that happen to decode to a wild address). Decodes
// the address via base + (ptr<<3); if it lands inside the nursery, hands
// off to debugAssertValidNurseryPointer (the free-region check).
// Compiles to a no-op when ECO_HEAP_VALIDATE is off — see HeapHelpers.hpp.
void Allocator::validateInNurserySafe(HPointer hp) {
#if ECO_HEAP_VALIDATE
    if (hp.ptr_ind != 0 || hp.ptr == 0) return;
    void* obj = fromPointerRaw(hp);
    if (tl_heap_ && tl_heap_->isInNursery(obj)) {
        tl_heap_->debugAssertValidNurseryPointer(obj);
    }
#else
    (void)hp;
#endif
}

// Returns true if the pointer is in the calling thread's old gen.
bool Allocator::isInOldGen(void *ptr) {
    return tl_heap_ && tl_heap_->isInOldGen(ptr);
}

// Returns the current allocated bytes in thread-local old gen.
size_t Allocator::getOldGenAllocatedBytes() const {
    if (tl_heap_) {
        return tl_heap_->getOldGenAllocatedBytes();
    }
    return 0;
}

// ============================================================================
// Nursery slice allocation (HEAP_042)
// ============================================================================
//
// The nursery region's two halves are carved into `nursery_slots_.size()`
// fixed-size slots each. A heap owns the low and high slice at ONE slot,
// so both of its semi-spaces are single contiguous extents and the bump
// limit can span the whole from-space instead of one 512 KiB block.

void Allocator::rebuildNurserySliceTable() {
    // Region geometry is first-init-wins (nursery_offset never moves after
    // initialize()); slice geometry follows the CURRENT config.
    const size_t nursery_space = heap_reserved - nursery_offset;
    const size_t per_side      = nursery_space / 2;

    size_t want = (config_.nursery_max_block_count / 2) * config_.alloc_buffer_size;
    if (want > per_side) want = per_side;         // clamp to the region
    if (config_.alloc_buffer_size != 0) {
        want -= want % config_.alloc_buffer_size;  // keep growth quantized
    }
    nursery_slice_bytes_ = want;

    const size_t slots = (want == 0) ? 0 : (per_side / want);
    // assign() also drops every retained-commit record, which is required:
    // slot bases move whenever alloc_buffer_size or the block caps change.
    nursery_slots_.assign(slots, NurserySliceSlot{});

    // threaded-gc-07 (HEAP_069): the region layout when the config selects
    // it. The two tables describe the same addresses; only one is used per
    // configuration, and both drop their retained records here.
    region_slots_.clear();
    region_stride_log2_ = 0;
    region_extents_ = 0;
    region_growth_bytes_ = 0;
    if (config_.nursery_regions == 1) {
        const size_t stride = config_.regionStrideBytes();
        size_t lg = 0;
        while ((size_t{1} << lg) < stride) ++lg;
        region_stride_log2_ = lg;
        region_extents_ = config_.regionExtents();
        size_t g = (config_.nursery_max_block_count / 2) * config_.alloc_buffer_size;
        if (config_.alloc_buffer_size != 0) g -= g % config_.alloc_buffer_size;
        region_growth_bytes_ = g;
        const size_t per_slot = static_cast<size_t>(region_extents_) << lg;
        region_slots_.assign(per_slot == 0 ? 0 : nursery_space / per_slot, NurseryRegionSlot{});
        // The nursery slice geometry the legacy table would report is the
        // per-extent ceiling in region mode (NurserySpace's growth ceiling).
        nursery_slice_bytes_ = region_growth_bytes_;
    }
}

NurserySliceSet Allocator::acquireNurserySliceSet(size_t initial) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
    if (initial > region_growth_bytes_) initial = region_growth_bytes_;
    size_t slot = SIZE_MAX;
    for (size_t i = 0; i < region_slots_.size(); ++i) {
        if (!region_slots_[i].in_use) { slot = i; break; }
    }
    if (slot == SIZE_MAX) {
        std::fprintf(stderr,
            "[eco] FATAL: region nursery heap slots exhausted (%zu slot(s) of %u extents x "
            "%zu MiB, region %zu MiB). Raise max_heap_size (or nursery_region_bytes) to "
            "widen the region, or lower nursery_max_block_count to shrink each extent "
            "(threaded-gc-07 HEAP_069: region mode has half the legacy slots).\n",
            region_slots_.size(), region_extents_,
            (size_t{1} << region_stride_log2_) / (1024 * 1024),
            (heap_reserved - nursery_offset) / (1024 * 1024));
        std::fflush(stderr);
        std::abort();
    }
    NurseryRegionSlot& s = region_slots_[slot];
    NurserySliceSet set;
    set.slot_base = heap_base + nursery_offset +
                    slot * (static_cast<size_t>(region_extents_) << region_stride_log2_);
    set.stride_log2 = region_stride_log2_;
    set.n = region_extents_;
    set.slot = slot;
    set.capacity = 0;
    for (unsigned k = 0; k < region_extents_; ++k) {
        if (initial > s.retained[k]) {
            const size_t add = initial - s.retained[k];
            if (Elm::platform::commitAt(set.extent(k) + s.retained[k], add) == nullptr) {
                if (heapTraceEnabled()) dumpHeapState("nursery region commit failed", add);
                return set;                      // capacity 0 == failure
            }
            s.retained[k] = initial;
            nursery_low_committed_ += add;
        }
    }
    s.in_use = true;
    set.capacity = initial;
    if (heapTraceEnabled()) dumpHeapState("nursery region set acquired", initial);
    return set;
}

bool Allocator::growNurserySliceSet(NurserySliceSet& set, size_t delta) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
    if (delta == 0) return false;
    const size_t new_cap = set.capacity + delta;
    if (new_cap > region_growth_bytes_) return false;
    if (set.slot >= region_slots_.size()) return false;
    NurseryRegionSlot& s = region_slots_[set.slot];
    for (unsigned k = 0; k < set.n; ++k) {
        if (new_cap > s.retained[k]) {
            const size_t add = new_cap - s.retained[k];
            if (Elm::platform::commitAt(set.extent(k) + s.retained[k], add) == nullptr) {
                return false;   // earlier extents keep dormant retained commit; capacity untouched
            }
            s.retained[k] = new_cap;
            nursery_low_committed_ += add;
        }
    }
    set.capacity = new_cap;
    if (heapTraceEnabled()) dumpHeapState("nursery region set grew", delta);
    return true;
}

void Allocator::releaseNurserySliceSet(const NurserySliceSet& set) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
    if (set.slot < region_slots_.size()) region_slots_[set.slot].in_use = false;
}

NurserySlicePair Allocator::acquireNurserySlicePair(size_t initial) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    if (initial > nursery_slice_bytes_) initial = nursery_slice_bytes_;

    size_t slot = SIZE_MAX;
    for (size_t i = 0; i < nursery_slots_.size(); ++i) {
        if (!nursery_slots_[i].in_use) { slot = i; break; }
    }
    if (slot == SIZE_MAX) {
        // Loud, not silent: a heap without a nursery cannot run, and the
        // two knobs that size the geometry are the actionable information.
        std::fprintf(stderr,
            "[eco] FATAL: nursery slice slots exhausted (%zu slot(s) of "
            "%zu MiB per side, region %zu MiB per side). Raise max_heap_size "
            "(or nursery_region_bytes) to widen the region, or lower "
            "nursery_max_block_count to shrink each slice.\n",
            nursery_slots_.size(), nursery_slice_bytes_ / (1024 * 1024),
            ((heap_reserved - nursery_offset) / 2) / (1024 * 1024));
        std::fflush(stderr);
        std::abort();
    }

    const size_t nursery_space     = heap_reserved - nursery_offset;
    const size_t high_region_start = nursery_space / 2;

    NurserySliceSlot& s = nursery_slots_[slot];
    NurserySlicePair pair;
    pair.low_base  = heap_base + nursery_offset + slot * nursery_slice_bytes_;
    pair.high_base = heap_base + nursery_offset + high_region_start
                                + slot * nursery_slice_bytes_;
    pair.slot      = slot;
    pair.capacity  = 0;

    // Commit only what this slot has never had committed. Re-commitAt of a
    // retained range would MAP_FIXED-remap it and DISCARD the pages, which
    // is exactly what retention exists to avoid.
    if (initial > s.retained_low) {
        const size_t add = initial - s.retained_low;
        if (Elm::platform::commitAt(pair.low_base + s.retained_low, add) == nullptr) {
            if (heapTraceEnabled()) dumpHeapState("nursery slice low commit failed", add);
            return pair;                     // capacity 0 == failure
        }
        s.retained_low = initial;
        nursery_low_committed_ += add;
    }
    if (initial > s.retained_high) {
        const size_t add = initial - s.retained_high;
        if (Elm::platform::commitAt(pair.high_base + s.retained_high, add) == nullptr) {
            if (heapTraceEnabled()) dumpHeapState("nursery slice high commit failed", add);
            return pair;                     // capacity 0 == failure
        }
        s.retained_high = initial;
        nursery_high_committed_ += add;
    }

    s.in_use     = true;
    pair.capacity = initial;

    if (heapTraceEnabled()) {
        dumpHeapState("nursery slice acquired", initial);
    }
    return pair;
}

bool Allocator::growNurserySlicePair(NurserySlicePair& pair, size_t delta) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    if (delta == 0) return false;
    const size_t new_cap = pair.capacity + delta;
    if (new_cap > nursery_slice_bytes_) return false;
    if (pair.slot >= nursery_slots_.size()) return false;

    NurserySliceSlot& s = nursery_slots_[pair.slot];

    if (new_cap > s.retained_low) {
        const size_t add = new_cap - s.retained_low;
        if (Elm::platform::commitAt(pair.low_base + s.retained_low, add) == nullptr) {
            return false;                    // capacity untouched
        }
        s.retained_low = new_cap;
        nursery_low_committed_ += add;
    }
    if (new_cap > s.retained_high) {
        const size_t add = new_cap - s.retained_high;
        if (Elm::platform::commitAt(pair.high_base + s.retained_high, add) == nullptr) {
            // The low side may already have grown its retained commit; that
            // is dormant, accounted memory, not a leak, and capacity stays
            // where it was so both extents remain equal.
            return false;
        }
        s.retained_high = new_cap;
        nursery_high_committed_ += add;
    }

    pair.capacity = new_cap;

    if (heapTraceEnabled()) {
        dumpHeapState("nursery slice grew", delta);
    }
    return true;
}

void Allocator::releaseNurserySlicePair(const NurserySlicePair& pair) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
    if (pair.slot < nursery_slots_.size()) {
        nursery_slots_[pair.slot].in_use = false;   // retained commit kept
    }
}

// Acquires a block from the old gen region.
// Thread-safe: acquires thread_mutex_ to update shared committed counters.
// First-fit reuse: scan the free list for a released block with size >= request.
// TLA-REGION(AL.acquireOldGenBlock) begin
char* Allocator::acquireOldGenBlock(size_t size, AcquireWait w) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    // Align size to 8 bytes.
    size = (size + 7) & ~7;

    // BBoP page-sized requests must always land on a page-aligned, page-sized
    // extent and must never base at heap_base (the heap-base block is pinned
    // by OldGenSpace's release path; this is a regression guard). Large-block
    // requests already arrive page-aligned (allocateLargeBlock rounds up to
    // OS_PAGE_SIZE before calling here) — that contract is what keeps the
    // bump pointer aligned across calls, which Darwin arm64 requires for
    // mmap(MAP_FIXED) to succeed at all.
    constexpr size_t kPageSize = OS_PAGE_SIZE;
    const bool page_request = (size == config_.alloc_buffer_size);
    if (page_request) {
        assert(size % kPageSize == 0 &&
               "acquireOldGenBlock: page request size must be OS-page-multiple");
    }
    auto fits = [&](const std::pair<char*, size_t>& e) {
        if (page_request) {
            if (e.first == heap_base) return false;       // pinned heap-base
            if (e.second % kPageSize != 0) return false;  // alignment guard
        }
        return e.second >= size;
    };

    // Takes the free-list extent at `it` (swap-remove), runs onReuse BEFORE
    // the pages are touched, and accounts for it.
    auto takeFreeAt = [&](std::vector<std::pair<char*, size_t>>::iterator it) -> char* {
            char* block = it->first;
            size_t block_size = it->second;
            // swap-remove
            *it = old_gen_free_blocks_.back();
            old_gen_free_blocks_.pop_back();

            // threaded-gc-03 (HEAP_059): in modes 1/2 a pending discard is
            // cancelled, a posted one is waited for — BEFORE the pages are
            // touched. Which extent was chosen does not depend on it.
            if (page_work_) {
                const auto r = page_work_->onReuse(block, block_size, callerInPause());
#if ECO_HEAP_VALIDATE
                // V1: the extent handed out is neither pending nor posted.
                if (page_work_->isPendingOrPosted(block)) {
                    std::fprintf(stderr, "[heap-validate] V1: reused extent %p still tracked\n",
                                 static_cast<void*>(block));
                    std::abort();
                }
#endif
                if (r == gc::PageWork::Reuse::AfterDiscard) {
                    page_supply_.reuse_after_discard_bytes += block_size;
                } else {
                    page_supply_.reuse_resident_bytes += block_size;
#if ECO_HEAP_VALIDATE
                    // V4: nothing may rely on a reacquired extent reading as
                    // zero; poison resident old contents (0xD8, not 0xDD).
                    std::memset(block, 0xD8, block_size);
#endif
                }
            } else if (config_.decommit_on_oldgen_release) {
                page_supply_.reuse_after_discard_bytes += block_size;
            } else {
                page_supply_.reuse_resident_bytes += block_size;
            }

            // The virtual mapping was never released, just (optionally)
            // decommitted. Hint to the kernel that it'll be touched soon;
            // a no-op if the pages were never decommitted.
            madvise(block, block_size, MADV_WILLNEED);

            // Do NOT increment `old_gen_committed` (the bump pointer):
            // this block is already inside the
            // [heap_base, heap_base + old_gen_committed) bump range.
            // Track it as in-use so getOldGenCommittedBytes() reflects
            // the round-trip correctly.
            addOldGenInUse(block_size);
            noteOldGenInUsePeak();

            if (heapTraceEnabled()) {
                dumpHeapState("oldgen reused released block", block_size);
            }

            // plans/large-object-space.md D1 (O7): the caller records only
            // `size` as its extent and releases only that, so a larger
            // extent's tail would be lost from old_gen_free_blocks_ and stay
            // counted as in use. Hand the tail straight back as its own free
            // extent: an ordinary release (thread_mutex_ is recursive), so
            // PageWork sees reuse-then-release, two actions it already models.
            if (block_size > size) {
                assert(size % kPageSize == 0 && block_size % kPageSize == 0 &&
                       "acquireOldGenBlock: extents and requests are OS-page multiples");
#if ECO_HEAP_VALIDATE
                // The tail lies below the bump and was awaited at its own release;
                // populates are posted only above the bump (topUpWindow), so this
                // release never waits (CR-007's no-wait rule under promo_mu_ holds).
                const uint64_t waits0 = page_work_ ? page_work_->counters().release_waits : 0;
#endif
                releaseOldGenBlock(block + size, block_size - size);
#if ECO_HEAP_VALIDATE
                if (page_work_ && page_work_->counters().release_waits != waits0) {
                    std::fprintf(stderr, "[heap-validate] O7: the tail release of a reused extent waited\n");
                    std::abort();
                }
#endif
            }
            return block;
    };

    // CR-007 (HEAP_058/HEAP_059): a promo_mu_ holder of a parallel promotion
    // with n > 1 workers never waits on a helper job unless the cap forces it.
    // (1) the first fitting Pending extent (its discard is cancelled: no
    // wait); (2) else a fresh bump; (3) else -- the old-gen cap leaves no bump
    // room -- today's first fit, which may wait. The skip test is membership in
    // pending_, which is job-blind (GC_DET_001): never a job's state.
    bool skip_reuse = false;
    if (w == AcquireWait::AvoidUnderPromo && page_work_ && page_work_->decommitOn()) {
        char* first_fit = nullptr;
        for (auto it = old_gen_free_blocks_.begin(); it != old_gen_free_blocks_.end(); ++it) {
            if (!fits(*it)) continue;
            if (!page_work_->isPending(it->first)) {
                if (first_fit == nullptr) first_fit = it->first;
                page_work_->noteNoWaitSkip();
                continue;
            }
            page_work_->noteNoWait(gc::PageWork::NoWaitPick::PendingReuse, it->first, it->second);
#if ECO_HEAP_VALIDATE
            const uint64_t waits0 = page_work_->counters().reuse_waits;
#endif
            char* const b = takeFreeAt(it);   // onReuse -> Cancelled, never waits
#if ECO_HEAP_VALIDATE
            if (page_work_->counters().reuse_waits != waits0) {
                std::fprintf(stderr, "[heap-validate] CR-007: a no-wait reuse of a Pending extent waited\n");
                std::abort();
            }
#endif
            return b;
        }
        if (old_gen_committed + size <= nursery_offset) {
            page_work_->noteNoWait(gc::PageWork::NoWaitPick::Fresh, heap_base + old_gen_committed, size);
            skip_reuse = true;                    // (2) the fresh bump below
        } else if (first_fit != nullptr) {
            // (3) the cap fallback: a discard-issued extent; the wait (if any) is
            // a pause stall (CR-025) like any other reuse wait.
            page_work_->noteNoWait(gc::PageWork::NoWaitPick::Fallback, first_fit, size);
        }
    }

    // First-fit reuse from previously-released old-gen blocks. A larger
    // extent is split: takeFreeAt releases the tail as its own free extent.
    if (!skip_reuse) {
        for (auto it = old_gen_free_blocks_.begin();
             it != old_gen_free_blocks_.end(); ++it) {
            if (fits(*it)) return takeFreeAt(it);
        }
    }

    // Check if we have space in old gen region.
    if (old_gen_committed + size > nursery_offset) {
        // Always log the exhaustion: this is the failure path that triggers
        // the OldGenSpace::bumpAllocate assertion further up the stack.
        dumpHeapState("acquireOldGenBlock OUT OF SPACE (returning nullptr)", size);
        return nullptr;  // Out of old gen address space.
    }

    char* block_base = heap_base + old_gen_committed;

    // Commit physical memory for this block. threaded-gc-03 (HEAP_060): in
    // modes 1/2 the part inside the commit-ahead window is already mapped
    // (and populated) and must NOT be re-mapped.
    char* commit_from = block_base;
    size_t commit_bytes = size;
    if (page_work_) commit_bytes = page_work_->onFreshBump(block_base, size, &commit_from);
    void* result = block_base;
    if (commit_bytes > 0) {
        if (commit_observer_for_testing) commit_observer_for_testing(commit_from, commit_bytes);
        if (Elm::platform::commitAt(commit_from, commit_bytes) == nullptr) result = nullptr;
    }
    page_supply_.fresh_bytes += size;

    if (result == nullptr) {
        if (heapTraceEnabled()) {
            dumpHeapState("acquireOldGenBlock commit failed", size);
        }
        return nullptr;
    }

    size_t before = old_gen_committed;
    old_gen_committed += size;
    addOldGenInUse(size);
    noteOldGenInUsePeak();

    if (page_request) {
        assert(old_gen_committed % kPageSize == 0 &&
               "acquireOldGenBlock: committed misaligned after page bump");
    }

    // Milestone-based growth log so we can see the committed counter
    // climbing through the available old-gen region.
    if (heapTraceEnabled() &&
        before / HEAP_TRACE_OLDGEN_INTERVAL !=
            old_gen_committed / HEAP_TRACE_OLDGEN_INTERVAL) {
        dumpHeapState("oldgen grew", size);
    }

    return block_base;
}
// TLA-REGION(AL.acquireOldGenBlock) end

// Returns a previously-acquired old-gen block for reuse. The virtual mapping
// is retained; physical RSS may be released via madvise. Caller must not
// hold thread_mutex_ (the lock is acquired here).
// TLA-REGION(AL.releaseOldGenBlock) begin
void Allocator::releaseOldGenBlock(char* block, size_t size) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    size = (size + 7) & ~7;

    page_supply_.released_bytes += size;
    page_supply_.released_extents += 1;
    if (page_work_) {
        // threaded-gc-03 (HEAP_059): the discard is deferred (Pending) and
        // later posted to the helper pool; see PageWork.
        page_work_->onRelease(block, size, callerInPause());
    } else if (config_.decommit_on_oldgen_release) {
        // Drop physical RSS while keeping the virtual mapping reserved so a
        // later acquireOldGenBlock can reuse the same address range.
#if ENABLE_GC_STATS
        const auto t0 = std::chrono::steady_clock::now();
#endif
        madvise(block, size, MADV_DONTNEED);
#if ENABLE_GC_STATS
        page_supply_.discard_inline_ns += static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - t0).count());
#endif
        page_supply_.discarded_bytes += size;
        page_supply_.discarded_extents += 1;
    }

    // Do NOT decrement `old_gen_committed`. The field is the bump pointer
    // (high-water mark) for fresh mmap calls — `acquireOldGenBlock`'s
    // bump path computes the next mapping address as
    //   `heap_base + old_gen_committed`
    // and any size+address check uses the same value. Decrementing here
    // for non-LIFO releases (e.g. major-GC reclaimAllDeadBlocksFromMeta
    // releasing low-address blocks) would move the bump pointer back over
    // still-mapped, still-live high-address regions; the next bump+mmap
    // would then `MAP_FIXED`-overlay live data with a fresh allocation.
    // Released bytes are recovered by `acquireOldGenBlock`'s first-fit
    // scan over `old_gen_free_blocks_`, not by reusing the bump.
    old_gen_free_blocks_.emplace_back(block, size);

    // Decrement the in-use byte counter so post-shrink reporting is correct.
    assert(old_gen_in_use_bytes_.load(std::memory_order_relaxed) >= size &&
           "releaseOldGenBlock: in-use underflow");
    subOldGenInUse(size);

    if (heapTraceEnabled()) {
        dumpHeapState("oldgen released block", size);
    }
}
// TLA-REGION(AL.releaseOldGenBlock) end

void Allocator::ensureOldGenCapacityFor(OldGenSpace& space,
                                        size_t new_capacity_bytes) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    auto currentCapacity = [&]() -> size_t {
        char* const base = space.regionBase();   // CR-021: through atomic_ref
        char* const end = space.regionEnd();
        if (base == nullptr || end == nullptr) {
            return 0;
        }
        return static_cast<size_t>(end - base);
    };

    if (new_capacity_bytes <= currentCapacity()) return;

    // Grow by acquiring fresh old-gen blocks. `acquireOldGenBlock` enforces
    // the global `nursery_offset` cap, so we just loop until we hit the
    // requested capacity or the allocator refuses.
    const size_t block_size = config_.alloc_buffer_size;

    while (currentCapacity() < new_capacity_bytes) {
        char* block_base = acquireOldGenBlock(block_size);
        if (block_base == nullptr) {
            // Hit the global old-gen cap — stop, caller tolerates partial grow.
            break;
        }

        // Add to the bag of unassigned pages; the BBoP allocator will pull it
        // out and materialize a BlockInfo on first use.
        space.unassigned_blocks_.emplace_back(block_base, block_base + block_size);

        if (char* const rb = space.regionBase(); rb == nullptr || block_base < rb) {
            space.setRegionBase(block_base);
        }
        if (block_base + block_size > space.regionEnd()) {
            space.setRegionEnd(block_base + block_size);
        }
    }

    // Resize the page-index for the (possibly grown) committed region. New
    // slots default to NO_BLOCK; populateFromBlock / allocateFromBagPage
    // assigns them as bag pages get materialized.
    space.resizePageIndexForRegion();
}

// Commits a contiguous region of `initial_size` bytes in the old-gen address
// space and returns the base. Used by `OldGenSpace::initialize` to obtain
// the BBoP region in a single mmap. The `max_size` parameter is retained for
// signature compatibility but only `initial_size` is committed and reserved.
// Pre-condition: caller must hold thread_mutex_.
// TLA-REGION(AL.acquireOldGenRegion) begin
char* Allocator::acquireOldGenRegion(size_t initial_size, size_t /*max_size*/) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    // Align size to 8 bytes.
    initial_size = (initial_size + 7) & ~7;

    if (initial_size == 0) return nullptr;

    if (old_gen_committed + initial_size > nursery_offset) {
        if (heapTraceEnabled()) {
            dumpHeapState("acquireOldGenRegion OUT OF SPACE", initial_size);
        }
        return nullptr;
    }

    char* region_base = heap_base + old_gen_committed;

    // HEAP_060 / CR-012(d): like acquireOldGenBlock's bump, the part of the
    // region inside the commit-ahead window is already mapped (and maybe
    // populated, or being populated) and must NOT be re-mapped MAP_FIXED.
    // Needed with sequential mutators too (a later heap's region starts at
    // the bump the previous heap's pause end opened a window over).
    char* commit_from = region_base;
    size_t commit_bytes = initial_size;
    if (page_work_) commit_bytes = page_work_->onFreshBump(region_base, initial_size, &commit_from);
    void* result = region_base;
    if (commit_bytes > 0) {
        if (commit_observer_for_testing) commit_observer_for_testing(commit_from, commit_bytes);
        if (Elm::platform::commitAt(commit_from, commit_bytes) == nullptr) result = nullptr;
    }

    if (result == nullptr) {
        if (heapTraceEnabled()) {
            dumpHeapState("acquireOldGenRegion commit failed", initial_size);
        }
        return nullptr;
    }

    old_gen_committed += initial_size;
    addOldGenInUse(initial_size);
    noteOldGenInUsePeak();
    return region_base;
}
// TLA-REGION(AL.acquireOldGenRegion) end

// Resets the allocator to initial state, optionally with a new configuration.
// Accumulates stats from all thread heaps before destroying them.
void Allocator::reset(const HeapConfig* new_config) {
    std::unique_lock<std::recursive_mutex> lock(thread_mutex_);

    ++heap_generation_;  // destroys all thread heaps/RootSets below; bump epoch

    // threaded-gc-03: finish every helper job and discard the pending extents
    // BEFORE the heaps and the free list go away (P§7 trap 5).
    if (page_work_) {
        page_work_->drainAll(/*discard_pending=*/true);
#if ECO_HEAP_VALIDATE
        if (page_work_->trackedCount() != 0 || !page_work_->allSlotsIdle()) {
            std::fprintf(stderr, "[heap-validate] V5: page work not drained at reset\n");
            std::abort();
        }
#endif
        page_work_.reset();
    }

    // Update config if provided.
    if (new_config) {
        HeapConfig c = *new_config;
        c.resolveNurseryRegions();   // TG7d: auto -> 1; incompatible throws
        c.validate();
        config_ = c;
    }

#if ENABLE_GC_STATS
    // Accumulate stats from all thread heaps before destroying them.
    for (const auto& [thread_id, heap] : thread_heaps_) {
        accumulated_stats_.combine(heap->getNursery().getStats());
        accumulated_stats_.combine(heap->getOldGen().getStats());
        accumulated_stats_.combine(heap->getStats());
    }
#endif

    // Clear all thread heaps. HEAP_075 (§7.2 step 2): swapped out under the lock and
    // destroyed after unlocking -- a heap's teardown joins its gangs (tenureTeardown ->
    // stopAndJoin, ~GCBackgroundGang's registry), which must not run under
    // thread_mutex_. Each heap's destruction re-takes thread_mutex_ per call
    // (releaseOldGenBlock, releaseNurserySlicePair) against the still-valid tables.
    {
        std::unordered_map<std::thread::id, std::unique_ptr<ThreadLocalHeap>> doomed;
        doomed.swap(thread_heaps_);
        setThreadHeap(nullptr);
        lock.unlock();
        doomed.clear();
        lock.lock();
    }

    // Reset committed memory tracking.
    old_gen_committed = 0;
    old_gen_in_use_bytes_.store(0, std::memory_order_relaxed);
    multi_mutator_opt_in_ = false;   // CR-012: the opt-in is per reset
    old_gen_in_use_peak_ = 0;   // C0 census (TEMPORARY)
    nursery_low_committed_ = 0;
    nursery_high_committed_ = 0;

    old_gen_free_blocks_.clear();
    page_supply_ = PageSupplyStats{};
    sync_epoch_ = 0;
    major_epoch_ = 0;
    rebuildPageWork();

    // Rebuild the nursery slice table against the (possibly new) config,
    // dropping every retained-commit record: slot bases move when
    // alloc_buffer_size or the block caps change, and a stale record would
    // make the next acquire skip committing pages that were never mapped at
    // the new base. Re-committing after a reset is the safe, cheap path —
    // this mirrors the block free-list clear it replaces. Runs AFTER
    // thread_heaps_.clear() above, whose ~NurserySpace calls
    // releaseNurserySlicePair against the still-valid old table.
    rebuildNurserySliceTable();
}

// ============================================================================
// Safe Public Pointer API
// ============================================================================

// Resolves an HPointer to its physical address, following forwarding pointers.
//
// Hot path (plan D9): under HEAP_028 the word IS the address, so the common
// no-forwarding case is a pure reinterpret (fromPointerRaw). The four
// correctness asserts (ptr_ind, non-null, heap-bounds x2) and the nursery
// stale-pointer tripwire are demoted to ECO_HEAP_VALIDATE builds only — they
// fired on every dereference of every Elm program under the asserts-on `build`
// preset, which is pure overhead in production. Only the forward-follow loop is
// real semantic work, and it iterates only while old-gen compaction has a
// forwarding window open (rare; see the __builtin_expect hint).
void* Allocator::resolve(HPointer ptr) {
    void* obj = fromPointerRaw(ptr);

#if ECO_HEAP_VALIDATE
    assert(ptr.ptr_ind == 0 && "Cannot resolve an embedded constant HPointer");
    assert(obj && "Null pointer from valid HPointer");
    // Stale-pointer tripwire: if obj is in nursery, verify it points at an
    // allocated region (not post-swap to-space-free). Hot path — only run
    // in validator builds.
    {
        ThreadLocalHeap* heap = getThreadHeap();
        if (heap != nullptr && heap->isInNursery(obj)) {
            heap->debugAssertValidNurseryPointer(obj);
        }
    }
    // Validate pointer is within the reserved heap address space OR the
    // permanent space (HEAP_036: immortal CAF values live outside the heap
    // range and resolve like any other object — headers are well-formed,
    // never forwarded).
    assert(((static_cast<char*>(obj) >= heap_base &&
             static_cast<char*>(obj) < heap_base + heap_reserved) ||
            PermanentSpace::instance().contains(obj)) &&
           "Pointer outside heap and permanent space");
#endif

    // Follow forwarding chain to final location.
    Header* hdr = getHeader(obj);
    while (__builtin_expect(hdr->tag == Tag_Forward, 0)) {
        Forward* fwd = static_cast<Forward*>(obj);
        obj = decodeForwardPtr(fwd->header.forward_ptr, heap_base);
        hdr = getHeader(obj);
    }

    assert(hdr->tag < Tag_Forward && "Invalid tag after forward resolution");
    return obj;
}

// Wraps a physical address as an HPointer.
HPointer Allocator::wrap(void* obj) {
    assert(obj && "Cannot wrap null pointer - Elm never produces null pointers");
    assert((reinterpret_cast<uintptr_t>(obj) & 7) == 0 && "Pointer must be 8-byte aligned");
    // Permanent-space objects (HEAP_036) wrap like any heap object — the
    // HPointer word is the raw address in both cases.
    assert((isInHeap(obj) || PermanentSpace::instance().contains(obj)) &&
           "Pointer must be within heap or permanent space");
    return toPointerRaw(obj);
}


// ============================================================================
// GC helper threads (threaded-gc-03, plans/threaded-gc-03-helper-threads.md)
// ============================================================================

void (*Allocator::commit_observer_for_testing)(char* p, size_t n) = nullptr;

namespace {

bool pageOpDiscard(void*, char* p, size_t n) {
    return Elm::platform::discardPages(p, n);
}
bool pageOpPopulate(void*, char* p, size_t n) {
    return Elm::platform::populatePagesWrite(p, n);
}
bool pageOpCommit(void*, char* p, size_t n) {
    if (Allocator::commit_observer_for_testing) Allocator::commit_observer_for_testing(p, n);
    return Elm::platform::commitAt(p, n) != nullptr;
}

// Stall observer: a stall OUTSIDE a pause goes to the MMU stall list of the
// calling thread's heap (phase-timer builds) and to the event log.
void pageHookStall(void*, uint64_t start_ns, uint64_t dur_ns, gc::HelperClient client,
                   bool in_pause) {
#if ENABLE_GC_STATS
    const uint64_t origin = GCStats::processStartSteadyNs();
    const uint64_t rel = start_ns > origin ? start_ns - origin : 0;
#if ENABLE_GC_PHASE_TIMERS
    if (!in_pause) {
        if (ThreadLocalHeap* h = Allocator::instance().getCurrentThreadHeap()) {
            h->getStats().tg.addStall(rel, dur_ns);
        }
    }
#endif
    if (gcEventLogEnabled()) gcEventLogStall(rel, dur_ns, gc::helperClientName(client), in_pause);
#else
    (void)start_ns; (void)dur_ns; (void)client; (void)in_pause;
#endif
}

void pageHookJobReaped(void*, const gc::HelperJob& job) {
#if ENABLE_GC_STATS
    if (!gcEventLogEnabled()) return;
    const uint64_t origin = GCStats::processStartSteadyNs();
    auto rel = [&](uint64_t t) { return t > origin ? t - origin : 0; };
    gcEventLogJob(rel(job.post_ns), rel(job.start_ns), rel(job.end_ns), job.bytes,
                  gc::helperClientName(job.client));
#else
    (void)job;
#endif
}

}  // namespace

size_t Allocator::nurseryCapacityBytes() const {
    return tl_heap_ != nullptr ? tl_heap_->getNursery().capacityBytes() : 0;
}

// TLA-REGION(AL.callerInPause) begin
bool Allocator::callerInPause() const {
    // CR-025: a GCMarkGang member (a parallel-minor or pause-tenure worker
    // waiting on a helper job under promo_mu_) has no ThreadLocalHeap, but
    // every gang run is inside its owner's pause (HEAP_058), so its stall is
    // a pause stall, not a stall_outside_pause / MMU stall.
    return (tl_heap_ != nullptr && tl_heap_->inPause()) || gc::GCMarkGang::onMemberRun();
}
// TLA-REGION(AL.callerInPause) end

// TLA-REGION(AL.rebuildPageWork) begin
void Allocator::rebuildPageWork() {
    page_work_.reset();
    if (config_.gc_thread_mode == 0) return;   // mode 0: today's inline path
    auto& pool = gc::GCHelperPool::instance();
    const auto mode = static_cast<gc::HelperMode>(config_.gc_thread_mode);
    if (pool.configured() &&
        (pool.mode() != mode || pool.threads() != config_.gc_helper_threads ||
         pool.pinCpu() != config_.gc_helper_cpu)) {
        // Only test harnesses get here (a reset() that configured the pool
        // before initialize(), or a reset to new settings); every earlier
        // PageWork was drained and destroyed, so the idle pool may restart.
        pool.shutdownForTesting();
    }
    // Jitter is a process-level probe (ECO_GC_HELPER_JITTER_US); a pool a
    // test configured with its own jitter keeps it.
    const unsigned jitter = pool.configured() ? pool.jitterUs() : helper_jitter_us_;
    pool.configure(mode, config_.gc_helper_threads, config_.gc_helper_cpu, jitter);
    gc::PageOps ops;
    ops.discard = &pageOpDiscard;
    ops.populate = &pageOpPopulate;
    ops.commit = &pageOpCommit;
    gc::PageWorkConfig cfg;
    cfg.decommit = config_.decommit_on_oldgen_release;
    cfg.delay = config_.decommit_delay_syncs;
    cfg.pending_cap = config_.decommit_pending_max_bytes;
    cfg.delay_majors = config_.decommit_delay_majors;
    cfg.ahead_bytes = config_.commit_ahead_bytes;
    gc::PageWorkHooks hooks;
    hooks.on_stall = &pageHookStall;
    hooks.on_job_reaped = &pageHookJobReaped;
    page_work_ = std::make_unique<gc::PageWork>(ops, cfg, pool, hooks);
}
// TLA-REGION(AL.rebuildPageWork) end

// TLA-REGION(AL.onGCPauseEnd) begin
void Allocator::onGCPauseEnd(ThreadLocalHeap& heap, bool had_major) {
    (void)heap;
#if ECO_HEAP_VALIDATE
    // V6: mode 0 is inert (no page work exists).
    if (config_.gc_thread_mode == 0 && page_work_) {
        std::fprintf(stderr, "[heap-validate] V6: page work alive in gc_thread_mode 0\n");
        std::abort();
    }
#endif
    if (!page_work_) return;   // mode 0: one predictable branch per pause
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
    // M6 fork harness (det-cr015): a pause point holding thread_mutex_ only (CR-015; since
    // GCFork's allocator layer a fork's prepare waits for it: the pause must be bounded).
    ECO_TLA_TRACE_ONLY(if (::Elm::gc::tla_m6) ::Elm::tlatrace::probe("m6.tm.held");)
    if (!page_work_) return;
    ++sync_epoch_;
    if (had_major) ++major_epoch_;
    page_work_->syncPoint(sync_epoch_, major_epoch_, heap_base + old_gen_committed,
                          heap_base + nursery_offset, /*in_pause=*/true);
#if ECO_HEAP_VALIDATE
    validatePageWork("onGCPauseEnd");
#endif
}
// TLA-REGION(AL.onGCPauseEnd) end

// TLA-REGION(AL.drainHelperWork) begin
void Allocator::drainHelperWork() {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
    if (page_work_) page_work_->drainAll(/*discard_pending=*/false);
}
// TLA-REGION(AL.drainHelperWork) end

// ========== Explicit collections (plans/frontend-heap-release.md §3.5, HEAP_076) ==========

namespace {
uint64_t explicitNowNs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

[[noreturn]] void explicitFatal(const char* what) {
    std::fprintf(stderr, "[gc] FATAL: %s (HEAP_076)\n", what);
    std::fflush(stderr);
    std::abort();
}
}  // namespace

GCReport Allocator::collectMajorAndRelease() {
    ThreadLocalHeap* h = tl_heap_;
    if (h == nullptr) explicitFatal("collectMajorAndRelease without a thread heap");
    if (h->inPause()) explicitFatal("collectMajorAndRelease inside a GC pause");
    GCReport r;
    r.kind = GCReport::Kind::Major;
    const uint64_t t0 = explicitNowNs();
    r.rss_before = platform::processResidentBytes();
    uint64_t rel0 = 0, dis0 = 0;
    {   // snapshot only
        std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
        rel0 = page_supply_.released_bytes;
        dis0 = page_work_ ? page_work_->counters().discard_posted_bytes
                          : page_supply_.discarded_bytes;
        r.old_pending_before = page_work_ ? page_work_->counters().pending_bytes : 0;
    }
    r.old_in_use_before = getOldGenCommittedBytes();
    const uint64_t ep0 = h->getOldGen().majorEpoch();
    // NO lock held across the collection and the shrink (HEAP_075).
    const ThreadLocalHeap::ReleaseTimings t = h->majorGCAndShrink();
    const uint64_t td = explicitNowNs();
    // TLA-REGION(AL.releaseDiscard) begin
    {
        std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
        // Waits for every slot, then discards every Pending extent (with
        // decommit off nothing is Pending: the config is respected).
        if (page_work_) page_work_->drainAll(/*discard_pending=*/page_work_->decommitOn());
#if ECO_HEAP_VALIDATE
        validatePageWork("collectMajorAndRelease");
#endif
        r.released_bytes = page_supply_.released_bytes - rel0;
        r.discarded_bytes = (page_work_ ? page_work_->counters().discard_posted_bytes
                                        : page_supply_.discarded_bytes) - dis0;
        r.old_pending_after = page_work_ ? page_work_->counters().pending_bytes : 0;
        r.nursery_committed = nursery_low_committed_ + nursery_high_committed_;
        r.old_high_water = old_gen_committed;
    }
    // TLA-REGION(AL.releaseDiscard) end
    r.discard_ns = explicitNowNs() - td;
    r.rss_after_discard = platform::processResidentBytes();
#if defined(__GLIBC__)
    {   // outside thread_mutex_: it can take milliseconds
        const uint64_t tt = explicitNowNs();
        r.trim_result = malloc_trim(0);
        r.trim_ns = explicitNowNs() - tt;
    }
#endif
    r.gc_ns = t.gc_ns;
    r.sweep_ns = t.sweep_ns;
    r.shrink_ns = t.shrink_ns;
    r.shrink_released_bytes = t.shrink_released;
    r.old_in_use_after = getOldGenCommittedBytes();
    r.major_count = h->getOldGen().majorEpoch();
    r.majors_run = r.major_count - ep0;
    if (r.majors_run > 0) r.live_after_mark = h->getOldGen().majorLiveBytes();
    r.minor_count = h->getNursery().minorSeq();
    r.rss_after = platform::processResidentBytes();
    r.total_ns = explicitNowNs() - t0;
    return r;
}

GCReport Allocator::collectMinor() {
    ThreadLocalHeap* h = tl_heap_;
    if (h == nullptr) explicitFatal("collectMinor without a thread heap");
    if (h->inPause()) explicitFatal("collectMinor inside a GC pause");
    GCReport r;
    r.kind = GCReport::Kind::Minor;
    const uint64_t t0 = explicitNowNs();
    r.rss_before = platform::processResidentBytes();
    uint64_t rel0 = 0, dis0 = 0;
    {   // snapshot only
        std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
        rel0 = page_supply_.released_bytes;
        dis0 = page_work_ ? page_work_->counters().discard_posted_bytes
                          : page_supply_.discarded_bytes;
        r.old_pending_before = page_work_ ? page_work_->counters().pending_bytes : 0;
    }
    r.old_in_use_before = getOldGenCommittedBytes();
    const uint64_t ep0 = h->getOldGen().majorEpoch();
    h->minorGC();                                // may chain into a major (majors_run)
    r.gc_ns = explicitNowNs() - t0;
    {   // snapshot only
        std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
        r.released_bytes = page_supply_.released_bytes - rel0;
        r.discarded_bytes = (page_work_ ? page_work_->counters().discard_posted_bytes
                                        : page_supply_.discarded_bytes) - dis0;
        r.old_pending_after = page_work_ ? page_work_->counters().pending_bytes : 0;
        r.nursery_committed = nursery_low_committed_ + nursery_high_committed_;
        r.old_high_water = old_gen_committed;
    }
    r.old_in_use_after = getOldGenCommittedBytes();
    r.major_count = h->getOldGen().majorEpoch();
    r.majors_run = r.major_count - ep0;
    if (r.majors_run > 0) r.live_after_mark = h->getOldGen().majorLiveBytes();
    r.minor_count = h->getNursery().minorSeq();
    r.rss_after_discard = r.rss_after = platform::processResidentBytes();
    r.total_ns = explicitNowNs() - t0;
    return r;
}

#if ECO_HEAP_VALIDATE
// V2 + V3 (plans/threaded-gc-03-helper-threads.md Step 6). Caller holds
// thread_mutex_.
void Allocator::validatePageWork(const char* where) const {
    if (!page_work_) return;
    auto fail = [&](const char* what, char* p) {
        std::fprintf(stderr, "[heap-validate] page-work %s at %s: extent %p\n", what,
                     where, static_cast<void*>(p));
        std::fflush(stderr);
        std::abort();
    };
    // Sorted in-use ranges of every heap: materialized blocks + unassigned.
    std::vector<std::pair<char*, char*>> used;
    for (const auto& [tid, h] : thread_heaps_) {
        if (fork_child_ && tid != fork_owner_) continue;   // HEAP_007: a dead heap is never read
        const OldGenSpace& og = h->getOldGen();
        for (size_t pos = 0; pos < og.blocks_.size(); ++pos) {
            const BlockInfo& bi = og.blocks_.info(og.blocks_.idAt(pos));
            used.emplace_back(bi.start, bi.end);
        }
        for (const auto& e : og.unassigned_blocks_) used.emplace_back(e.first, e.second);
    }
    std::sort(used.begin(), used.end());
    page_work_->forEachTracked([&](char* p, size_t n, int) {
        // V2a: exactly once in the free list.
        size_t hits = 0;
        for (const auto& fb : old_gen_free_blocks_) {
            if (fb.first == p) {
                ++hits;
                if (fb.second != n) fail("size differs from the free-list extent", p);
            }
        }
        if (hits != 1) fail("tracked extent not exactly once in old_gen_free_blocks_", p);
        // V2b: overlaps no heap-owned range.
        auto it = std::upper_bound(used.begin(), used.end(), std::make_pair(p + n, p + n));
        if (it != used.begin()) {
            --it;
            if (it->second > p && it->first < p + n) fail("tracked extent overlaps a heap block", p);
        }
    });
    // V3: populate jobs stay inside old-gen address space.
    char* lo_bound = heap_base;
    char* hi_bound = heap_base + nursery_offset;
    page_work_->forEachPopulateInFlight([&](char* lo, char* hi) {
        if (lo < lo_bound || hi > hi_bound || lo >= hi) fail("populate range out of bounds", lo);
    });
}
#endif

#if ENABLE_GC_STATS
// Returns combined statistics from all thread heaps.
GCStats Allocator::getCombinedStats() const {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    // Start with accumulated stats from destroyed thread heaps.
    GCStats combined = accumulated_stats_;

    // Add stats from current thread heaps.
    for (const auto& [thread_id, heap] : thread_heaps_) {
        if (fork_child_ && thread_id != fork_owner_) continue;   // HEAP_007: never read a dead heap
        // Combine nursery, old-gen (allocation-size histogram), and
        // thread-local heap (major-GC) stats.
        combined.combine(heap->getNursery().getStats());
        // threaded-gc-02: fold the bitmap cursors' pending counts first.
        heap->getOldGen().syncCursorLiveBytes();
        combined.combine(heap->getOldGen().getStats());
        {   // plans/large-object-space.md: the heap's LOS counters.
            const LargeObjectSpace& los = heap->getOldGen().largeObjectSpace();
            const LargeObjectSpace::Stats& ls = los.stats();
            combined.los.allocs += ls.allocs;
            combined.los.frees += ls.frees;
            combined.los.alloc_bytes += ls.alloc_bytes;
            combined.los.free_bytes += ls.free_bytes;
            combined.los.object_bytes += ls.object_bytes;
            combined.los.blocks_added += ls.blocks_added;
            combined.los.blocks_removed += ls.blocks_removed;
            combined.los.fit_misses += ls.fit_misses;
            combined.los.aligned_allocs += ls.aligned_allocs;
            combined.los.blocks_now += los.blockCount();
            combined.los.used_bytes_now += los.usedBytesTotal();
        }
        combined.combine(heap->getStats());
    }
    if (runtime_start_ns_ != 0) {
        const uint64_t now_ns = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count());
        combined.wall_time_ns = now_ns - runtime_start_ns_;
    }
    // C0 census (TEMPORARY, plans/contiguous-nursery-space.md §3.3): both
    // old-gen walls are allocator-global, so they are read from the live
    // allocator rather than merged out of the per-thread stats.
    combined.oldgen_inuse_peak_bytes = old_gen_in_use_peak_;
    combined.oldgen_hiwater_bytes    = old_gen_committed;

    // threaded-gc-03 (P§3.9): page supply + helper snapshot, allocator-global.
    combined.page_supply = page_supply_;
    if (page_work_) {
        const gc::PageWorkCounters& c = page_work_->counters();
        combined.page_supply.discarded_bytes = c.discard_posted_bytes;
        combined.page_supply.discarded_extents = c.discard_posted_extents;
        combined.page_supply.fresh_ahead_hit_bytes = c.fresh_ahead_hit_bytes;
        combined.page_supply.fresh_ahead_miss_bytes = c.fresh_ahead_miss_bytes;
        combined.page_supply.pending_peak_bytes = c.pending_peak_bytes;
        const auto& pool = gc::GCHelperPool::instance();
        const auto& ps = pool.stats();
        HelperStatsSnapshot& h = combined.helper;
        h.mode = config_.gc_thread_mode;
        h.threads = pool.threads();
        h.pin_cpu = pool.pinCpu();
        h.jitter_us = pool.jitterUs();
        for (int i = 0; i < HelperStatsSnapshot::kClients; ++i) {
            h.jobs[i] = ps.client[i].jobs.load(std::memory_order_relaxed);
            h.bytes[i] = ps.client[i].bytes.load(std::memory_order_relaxed);
            h.cpu_ns[i] = ps.client[i].cpu_ns.load(std::memory_order_relaxed);
            h.inline_cpu_ns[i] = ps.client[i].inline_cpu_ns.load(std::memory_order_relaxed);
        }
        h.posts = ps.posts.load(std::memory_order_relaxed);
        h.stall_count = ps.stall_count.load(std::memory_order_relaxed);
        h.stall_ns = ps.stall_ns.load(std::memory_order_relaxed);
        h.stall_max_ns = ps.stall_max_ns.load(std::memory_order_relaxed);
        h.stall_outside_pause = ps.stall_outside_pause.load(std::memory_order_relaxed);
        h.stall_outside_pause_ns = ps.stall_outside_pause_ns.load(std::memory_order_relaxed);
        h.reuse_waits = c.reuse_waits;
        h.release_waits = c.release_waits;
        h.slot_full_waits = c.slot_full_waits;
        h.cancelled_bytes = c.cancelled_bytes;
        h.cancelled_extents = c.cancelled_extents;
        h.discard_jobs = c.discard_jobs;
        h.discard_failures = c.discard_failures;
        h.populate_jobs = c.populate_jobs;
        h.populate_bytes = c.populate_posted_bytes;
        h.populate_failures = c.populate_failures;
        h.window_commit_failures = c.window_commit_failures;
        h.populate_supported = c.populate_supported;
        h.commit_ahead_bytes = config_.commit_ahead_bytes;
        h.decommit_delay = config_.decommit_delay_syncs;
        h.pending_cap = config_.decommit_pending_max_bytes;
        h.decommit_delay_majors = config_.decommit_delay_majors;
#if !defined(_WIN32)
        timespec ts;
        if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts) == 0) {
            h.process_cpu_ns = static_cast<uint64_t>(ts.tv_sec) * 1000000000ull +
                               static_cast<uint64_t>(ts.tv_nsec);
        }
#endif
    }
    return combined;
}
#endif

// ============================================================================
// Test Access Helper
// ============================================================================

// Returns the thread-local nursery for testing.
NurserySpace* AllocatorTestAccess::getNursery(Allocator& alloc) {
    ThreadLocalHeap* heap = alloc.getThreadHeap();
    return heap ? &heap->getNursery() : nullptr;
}

// Returns the thread-local old gen for testing.
OldGenSpace* AllocatorTestAccess::getOldGen(Allocator& alloc) {
    ThreadLocalHeap* heap = alloc.getThreadHeap();
    return heap ? &heap->getOldGen() : nullptr;
}

} // namespace Elm
