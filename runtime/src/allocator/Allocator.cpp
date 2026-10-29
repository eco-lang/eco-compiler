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
// Where the C library has no <execinfo.h> (musl, Windows), the backtrace functions are no-ops returning
// nothing, so that code calling them compiles everywhere.
#if defined(__has_include) && __has_include(<execinfo.h>)
#  include <execinfo.h>
#else
[[maybe_unused]] static inline int backtrace(void**, int) { return 0; }
[[maybe_unused]] static inline char** backtrace_symbols(void* const*, int) { return nullptr; }
[[maybe_unused]] static inline void backtrace_symbols_fd(void* const*, int, int) {}
#endif

// On Windows there is no `madvise`, so it is a no-op here and its advice constants are placeholders. No
// caller reads its result. Releasing an extent in `gc_thread_mode` 0 therefore discards nothing on Windows.
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

// The start of the heap reservation: null until the first `Allocator::initialize` sets it, and never changed
// after. `OldGenSpace` passes it to the forward-word codec in `Heap.hpp`, which does not use it.
char* g_heap_base = nullptr;

namespace {

// The step in the old-generation bump, in bytes, at which a heap trace reports growth: a fresh block is
// traced only when the bump crosses a multiple of it, since one line per block would be too many.
constexpr size_t HEAP_TRACE_OLDGEN_INTERVAL   = 32 * 1024 * 1024;  // 32 MB.
// The matching step for nursery growth, in bytes. Nothing uses it.
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

constinit thread_local ThreadLocalHeap* Allocator::tl_heap_ = nullptr;

// The address of the calling thread's nursery bump state, the same address `Allocator::bumpState` returns,
// or null when the thread has no heap.
//
// Compiled code reads it with one thread-local load where it would otherwise call for the address, and
// refers to it by this unmangled name. The address stays the same while the heap lives, because the bump
// state is held by value inside the heap; only its contents change. `Allocator::setThreadHeap` is the only
// writer, and a value that disagrees with the thread's heap makes compiled code allocate from the wrong
// nursery.
extern "C" constinit thread_local void* eco_tl_bump_state
    __attribute__((tls_model("initial-exec"))) = nullptr;

void Allocator::setThreadHeap(ThreadLocalHeap* h) {
    tl_heap_ = h;
    eco_tl_bump_state = h ? static_cast<void*>(h->getNursery().bumpState())
                          : nullptr;

    // The root-stack words follow the heap, as the bump state does. Resetting the cursors to the start loses
    // nothing, because no frame holds a pushed range when a thread gains or loses its heap.
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
}

// TLA-REGION(AL.destructor) begin
Allocator::~Allocator() {
    // Clean up all thread heaps.
    std::unordered_map<std::thread::id, std::unique_ptr<ThreadLocalHeap>> doomed;
    {
        std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
        // No helper job may outlive the PageWork it points at.
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

HeapConfig Allocator::environmentConfig(const HeapConfig& base, uint32_t& helper_jitter_us) {
    HeapConfig c = base;
    applyHeapConfigFromEnv(c);
    applyGcThreadEnv(c, helper_jitter_us);
    c.resolveNurseryRegions();   // auto becomes 1; an incompatible setting throws
    c.validate();
    return c;
}

void Allocator::initialize(const HeapConfig& config) {
    // HEAP_075: GCFork's allocator layer. Registered on every call, with no runtime lock held; registering
    // the same layer again changes nothing.
    static const gc::ForkHooks kAllocatorHooks{&Allocator::forkPrepare, &Allocator::forkParent,
                                               &Allocator::forkChild};
    gc::registerForkLayer(gc::kForkAllocator, kAllocatorHooks);
    if (initialized) {
        return;
    }
    ++heap_generation_;

    config_ = environmentConfig(config, helper_jitter_us_);

    heap_reserved = config_.max_heap_size;

    // An HPointer holds a heap address in its low 43 bits, so the whole reservation must lie below 2^43.
    if (heap_reserved > HPOINTER_ADDRESS_LIMIT) {
        throw std::invalid_argument(
            "max_heap_size exceeds the 8 TB HPointer address limit");
    }

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

    g_heap_base = heap_base;

    // The nursery region is the top of the reservation and the old generation the rest (HEAP_043). Only
    // this first initialize sets it; reset() rebuilds the slots within it.
    nursery_offset = heap_reserved - config_.nurseryRegionBytes();

    // Slice geometry follows the config against that region (HEAP_042).
    rebuildNurserySliceTable();

    runtime_start_ns_ = static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());

    rebuildPageWork();

    initialized = true;
}

// CR-031: a dead heap's tables (RootSet, the tenure job, gang state) may have been part way through an update
// at the fork, so even its destructor must not run.
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

// HEAP_075 / CR-015: this layer runs after the gangs layer (a gang member may block on thread_mutex_
// under promo_mu_ while its run holds run_m_) and before the census and the pool (every post and wait
// holds thread_mutex_, so with it held no post can land between the pool's drain and its lock).
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

void Allocator::commitNursery(char *nursery_base, size_t size) {
    void *result = Elm::platform::commitAt(nursery_base, size);

    if (result == nullptr) {
        throw std::bad_alloc();
    }
}

// The constructor only stores constants, so the order of static initialization across files does not matter.
Allocator g_allocator_storage;

void Allocator::initThread() {
    if (!initialized) {
        initialize();
    }

    if (tl_heap_ != nullptr) {
        return;
    }

    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
    // HEAP_007: in a forked child the dead heaps are dropped first, so they do not count as live mutators
    // in the check below.
    dropForkDeadHeapsLocked();

    // Reached with tl_heap_ null but a heap registered for this thread, as after adoptThreadHeap(nullptr).
    auto thread_id = std::this_thread::get_id();
    if (thread_heaps_.find(thread_id) != thread_heaps_.end()) {
        setThreadHeap(thread_heaps_[thread_id].get());
        return;
    }

    // HEAP_007 / CR-012: one live mutator per process.
    if (!thread_heaps_.empty() && !multi_mutator_opt_in_) {
        std::fprintf(stderr, "[eco] FATAL: a second mutator thread called initThread while "
            "another ThreadLocalHeap is live (HEAP_007: one mutator per process; CR-012). "
            "Only benchmark/test harnesses may call Allocator::allowMultipleMutators(true).\n");
        std::fflush(stderr);
        std::abort();
    }

    // The heap's spaces take their memory from this allocator when they need it, not here.
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

// TLA-REGION(AL.cleanupThread) begin
void Allocator::cleanupThread() {
    if (tl_heap_ == nullptr) {
        return;
    }

    // HEAP_075: no teardown holds
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
        // The last tenure job is finished and given a stats-only merge before the heap's stats are folded.
        doomed->getNursery().tenureTeardown(doomed->getOldGen());
#if ENABLE_GC_STATS
        {
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

// TLA-REGION(AL.finishTenureForExit) begin
void Allocator::finishTenureForExit() {
    if (tl_heap_ == nullptr) return;
    // HEAP_075: no thread_mutex_ around the teardown (it joins the tenure collector).
    tl_heap_->getNursery().tenureTeardown(tl_heap_->getOldGen());
}
// TLA-REGION(AL.finishTenureForExit) end

RootSet &Allocator::getRootSetSlow() {
    if (!tl_heap_) {
        initThread();
    }
    return tl_heap_->getRootSet();
}

void *Allocator::allocate(size_t size, Tag tag) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocate(size, tag);
}

void *Allocator::allocateFast(size_t size) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocateFast(size);
}

void *Allocator::allocateSlow(size_t size, Tag tag) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocateSlow(size, tag);
}

void *Allocator::allocateSlowRaw(size_t size) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocateSlowRaw(size);
}

void *Allocator::bumpState() {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->getNursery().bumpState();
}

void Allocator::ensureNursery(size_t n) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    tl_heap_->ensureNursery(n);
}

void *Allocator::allocateRegionSlow(size_t total) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocateRegionSlow(total);
}

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

void Allocator::minorGC() {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    tl_heap_->minorGC();
}

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

bool Allocator::isNurseryNearFull(float threshold) {
    if (tl_heap_) {
        return tl_heap_->isNurseryNearFull(threshold);
    }
    return false;
}

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

bool Allocator::isInOldGen(void *ptr) {
    return tl_heap_ && tl_heap_->isInOldGen(ptr);
}

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
// A heap's two semi-spaces are each one contiguous extent, so its bump range can span a whole semi-space.

void Allocator::rebuildNurserySliceTable() {
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

    // HEAP_069: the two tables describe the same addresses; only one is used per configuration, and both
    // drop their retained records here.
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
        // In region mode the slice size reported is the per-extent ceiling, NurserySpace's growth ceiling.
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

// TLA-REGION(AL.acquireOldGenBlock) begin
char* Allocator::acquireOldGenBlock(size_t size, AcquireWait w) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    size = (size + 7) & ~7;

    // BBoP page-sized requests must always land on a page-aligned, page-sized
    // extent and must never base at heap_base (the heap-base block is pinned
    // by OldGenSpace's release path). Large-block
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

            // HEAP_059: in modes 1/2 a pending discard is
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

            // The caller records only `size` as its extent and releases only that, so a larger
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
    // room -- the ordinary first fit, which may wait. The skip test is membership in
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

    if (old_gen_committed + size > nursery_offset) {
        // Always log the exhaustion: this is the failure path that triggers
        // the OldGenSpace::bumpAllocate assertion further up the stack.
        dumpHeapState("acquireOldGenBlock OUT OF SPACE (returning nullptr)", size);
        return nullptr;  // Out of old gen address space.
    }

    char* block_base = heap_base + old_gen_committed;

    // HEAP_060: in modes 1/2 the part inside the commit-ahead window is already mapped
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

// TLA-REGION(AL.releaseOldGenBlock) begin
void Allocator::releaseOldGenBlock(char* block, size_t size) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    size = (size + 7) & ~7;

    page_supply_.released_bytes += size;
    page_supply_.released_extents += 1;
    if (page_work_) {
        // HEAP_059: the discard is deferred (Pending) and
        // later posted to the helper pool; see PageWork.
        page_work_->onRelease(block, size, callerInPause());
    } else if (config_.decommit_on_oldgen_release) {
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

    // acquireOldGenBlock enforces the nursery_offset limit, so the loop stops when it refuses.
    const size_t block_size = config_.alloc_buffer_size;

    while (currentCapacity() < new_capacity_bytes) {
        char* block_base = acquireOldGenBlock(block_size);
        if (block_base == nullptr) {
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

// TLA-REGION(AL.acquireOldGenRegion) begin
char* Allocator::acquireOldGenRegion(size_t initial_size, size_t /*max_size*/) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

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

void Allocator::reset(const HeapConfig* new_config) {
    std::unique_lock<std::recursive_mutex> lock(thread_mutex_);

    ++heap_generation_;

    // Every helper job finishes and every pending extent is discarded BEFORE the heaps and the free list
    // go away.
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

    if (new_config) {
        HeapConfig c = *new_config;
        c.resolveNurseryRegions();   // auto becomes 1; an incompatible setting throws
        c.validate();
        config_ = c;
    }

#if ENABLE_GC_STATS
    for (const auto& [thread_id, heap] : thread_heaps_) {
        accumulated_stats_.combine(heap->getNursery().getStats());
        accumulated_stats_.combine(heap->getOldGen().getStats());
        accumulated_stats_.combine(heap->getStats());
    }
#endif

    // HEAP_075: the heaps are swapped out under the lock and
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

    old_gen_committed = 0;
    old_gen_in_use_bytes_.store(0, std::memory_order_relaxed);
    multi_mutator_opt_in_ = false;   // CR-012: the opt-in is per reset
    old_gen_in_use_peak_ = 0;
    nursery_low_committed_ = 0;
    nursery_high_committed_ = 0;

    old_gen_free_blocks_.clear();
    page_supply_ = PageSupplyStats{};
    sync_epoch_ = 0;
    major_epoch_ = 0;
    rebuildPageWork();

    // A retained-commit record from the old geometry would make the next acquire skip committing pages that
    // were never mapped at the new slot base, so all are dropped. This runs after the heaps are destroyed
    // above, because ~NurserySpace releases its slot against the old table.
    rebuildNurserySliceTable();
}

// ============================================================================
// Safe Public Pointer API
// ============================================================================

// The checks on `ptr` are only in ECO_HEAP_VALIDATE builds because this runs on every dereference, and
// the standard build keeps assertions on. The tag assertion after the loop stays in every build that has
// assertions.
void* Allocator::resolve(HPointer ptr) {
    void* obj = fromPointerRaw(ptr);

#if ECO_HEAP_VALIDATE
    assert(ptr.ptr_ind == 0 && "Cannot resolve an embedded constant HPointer");
    assert(obj && "Null pointer from valid HPointer");
    // Stale-pointer tripwire: a nursery address must point into an allocated part of the nursery.
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

    Header* hdr = getHeader(obj);
    while (__builtin_expect(hdr->tag == Tag_Forward, 0)) {
        Forward* fwd = static_cast<Forward*>(obj);
        obj = decodeForwardPtr(fwd->header.forward_ptr, heap_base);
        hdr = getHeader(obj);
    }

    assert(hdr->tag < Tag_Forward && "Invalid tag after forward resolution");
    return obj;
}

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
// GC helper threads
// ============================================================================

void (*Allocator::commit_observer_for_testing)(char* p, size_t n) = nullptr;

namespace {

// Discards the `n` bytes of pages at `p` for the page work, returning whether that succeeded.
bool pageOpDiscard(void*, char* p, size_t n) {
    return Elm::platform::discardPages(p, n);
}
// Populates the `n` bytes of committed pages at `p` for writing, for the page work, returning whether that
// succeeded.
bool pageOpPopulate(void*, char* p, size_t n) {
    return Elm::platform::populatePagesWrite(p, n);
}
// Commits the `n` bytes at `p` for the page work, after showing them to `commit_observer_for_testing`,
// returning whether the commit succeeded.
bool pageOpCommit(void*, char* p, size_t n) {
    if (Allocator::commit_observer_for_testing) Allocator::commit_observer_for_testing(p, n);
    return Elm::platform::commitAt(p, n) != nullptr;
}

// Records a wait on a helper job of `dur_ns` nanoseconds starting at `start_ns` on the steady clock: in
// the GC event log, when it is on, and, in phase-timer builds, in the calling thread's stall list when the
// wait was outside a pause. Does nothing without GC statistics.
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

// Records a finished helper job in the GC event log, when GC statistics are built and the log is on.
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
    if (config_.gc_thread_mode == 0) return;   // mode 0: no page work
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
    // A pause point holding thread_mutex_ only (CR-015). A fork's prepare waits for
    // thread_mutex_, so this hold must be bounded.
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

// ========== Explicit collections (HEAP_076) ==========

namespace {
// Returns the steady clock's reading in nanoseconds.
uint64_t explicitNowNs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

// Prints `what` as a fatal explicit-collection error and aborts.
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
GCStats Allocator::getCombinedStats() const {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    GCStats combined = accumulated_stats_;

    for (const auto& [thread_id, heap] : thread_heaps_) {
        if (fork_child_ && thread_id != fork_owner_) continue;   // HEAP_007: never read a dead heap
        combined.combine(heap->getNursery().getStats());
        // The bitmap cursors' pending counts are folded in first.
        heap->getOldGen().syncCursorLiveBytes();
        combined.combine(heap->getOldGen().getStats());
        {   // the heap's large-object-space counters
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
    // Both old-gen figures belong to the allocator, not to a heap, so they are read here, not merged.
    combined.oldgen_inuse_peak_bytes = old_gen_in_use_peak_;
    combined.oldgen_hiwater_bytes    = old_gen_committed;

    // Page supply and the helper pool also belong to the allocator.
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

NurserySpace* AllocatorTestAccess::getNursery(Allocator& alloc) {
    ThreadLocalHeap* heap = alloc.getThreadHeap();
    return heap ? &heap->getNursery() : nullptr;
}

OldGenSpace* AllocatorTestAccess::getOldGen(Allocator& alloc) {
    ThreadLocalHeap* heap = alloc.getThreadHeap();
    return heap ? &heap->getOldGen() : nullptr;
}

} // namespace Elm
