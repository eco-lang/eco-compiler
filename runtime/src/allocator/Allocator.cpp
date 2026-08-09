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
#include "HeapConfigJson.hpp"
#include "OldGenSpace.hpp"
#include "PermanentSpace.hpp"
#include "PlatformVirtualMemory.hpp"
#include "ThreadLocalHeap.hpp"
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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
#else
namespace {
[[maybe_unused]] constexpr int MADV_WILLNEED = 0;
[[maybe_unused]] constexpr int MADV_DONTNEED = 0;
[[maybe_unused]] inline int madvise(void*, std::size_t, int) { return 0; }
}
#endif

namespace Elm {

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

Allocator::Allocator() :
    heap_base(nullptr), heap_reserved(0),
    old_gen_committed(0), old_gen_in_use_bytes_(0), old_gen_in_use_peak_(0),
    nursery_offset(0),
    nursery_low_committed_(0), nursery_high_committed_(0),
    nursery_slice_bytes_(0), initialized(false) {
    // Initialization happens in initialize() method.
}

Allocator::~Allocator() {
    // Clean up all thread heaps.
    {
        std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
        thread_heaps_.clear();
    }

    if (heap_base) {
        Elm::platform::releaseReservation(heap_base, heap_reserved);
    }
}

// Initializes the allocator with the given configuration.
// Validates config and reserves address space. Physical memory committed lazily.
void Allocator::initialize(const HeapConfig& config) {
    if (initialized) {
        return;
    }
    ++heap_generation_;  // new heap epoch (invalidates cross-lifetime caches)

    // Apply JSON overrides from $ECO_HEAP_CONFIG, if set, on top of the
    // caller-supplied defaults. Lets us tweak heap parameters without a
    // rebuild — see HeapConfigJson.hpp for the recognised keys.
    config_ = config;
    applyHeapConfigFromEnv(config_);
    config_.validate();

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

    initialized = true;
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

    // Double-check after acquiring lock.
    auto thread_id = std::this_thread::get_id();
    if (thread_heaps_.find(thread_id) != thread_heaps_.end()) {
        tl_heap_ = thread_heaps_[thread_id].get();
        return;
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

    tl_heap_ = heap.get();
    thread_heaps_[thread_id] = std::move(heap);
}

// Cleans up the calling thread's heap space.
void Allocator::cleanupThread() {
    if (tl_heap_ == nullptr) {
        return;  // Nothing to clean up.
    }

    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    auto thread_id = std::this_thread::get_id();
    auto it = thread_heaps_.find(thread_id);
    if (it != thread_heaps_.end()) {
#if ENABLE_GC_STATS
        // Accumulate stats from this thread heap before destroying it.
        accumulated_stats_.combine(it->second->getNursery().getStats());
        accumulated_stats_.combine(it->second->getOldGen().getStats());
        accumulated_stats_.combine(it->second->getStats());
#endif
        thread_heaps_.erase(it);
    }

    tl_heap_ = nullptr;
}

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

// Returns true if the pointer is in the calling thread's nursery.
bool Allocator::isInNursery(void *ptr) {
    return tl_heap_ && tl_heap_->isInNursery(ptr);
}

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
char* Allocator::acquireOldGenBlock(size_t size) {
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

    // First-fit reuse from previously-released old-gen blocks. Splitting an
    // oversized cell is out of scope; we accept the slack on a larger reuse
    // since current callers request whole pages or whole large-block extents.
    for (auto it = old_gen_free_blocks_.begin();
         it != old_gen_free_blocks_.end(); ++it) {
        if (page_request) {
            if (it->first == heap_base) continue;       // pinned heap-base
            if (it->second % kPageSize != 0) continue;  // alignment guard
        }
        if (it->second >= size) {
            char* block = it->first;
            size_t block_size = it->second;
            // swap-remove
            *it = old_gen_free_blocks_.back();
            old_gen_free_blocks_.pop_back();

            // The virtual mapping was never released, just (optionally)
            // decommitted. Hint to the kernel that it'll be touched soon;
            // a no-op if the pages were never decommitted.
            madvise(block, block_size, MADV_WILLNEED);

            // Do NOT increment `old_gen_committed` (the bump pointer):
            // this block is already inside the
            // [heap_base, heap_base + old_gen_committed) bump range.
            // Track it as in-use so getOldGenCommittedBytes() reflects
            // the round-trip correctly.
            old_gen_in_use_bytes_ += block_size;
            noteOldGenInUsePeak();

            if (heapTraceEnabled()) {
                dumpHeapState("oldgen reused released block", block_size);
            }
            return block;
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

    // Commit physical memory for this block.
    void* result = Elm::platform::commitAt(block_base, size);

    if (result == nullptr) {
        if (heapTraceEnabled()) {
            dumpHeapState("acquireOldGenBlock commit failed", size);
        }
        return nullptr;
    }

    size_t before = old_gen_committed;
    old_gen_committed += size;
    old_gen_in_use_bytes_ += size;
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

// Returns a previously-acquired old-gen block for reuse. The virtual mapping
// is retained; physical RSS may be released via madvise. Caller must not
// hold thread_mutex_ (the lock is acquired here).
void Allocator::releaseOldGenBlock(char* block, size_t size) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    size = (size + 7) & ~7;

    if (config_.decommit_on_oldgen_release) {
        // Drop physical RSS while keeping the virtual mapping reserved so a
        // later acquireOldGenBlock can reuse the same address range.
        madvise(block, size, MADV_DONTNEED);
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
    assert(old_gen_in_use_bytes_ >= size &&
           "releaseOldGenBlock: in-use underflow");
    old_gen_in_use_bytes_ -= size;

    if (heapTraceEnabled()) {
        dumpHeapState("oldgen released block", size);
    }
}

void Allocator::ensureOldGenCapacityFor(OldGenSpace& space,
                                        size_t new_capacity_bytes) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    auto currentCapacity = [&]() -> size_t {
        if (space.region_base_ == nullptr || space.region_end_ == nullptr) {
            return 0;
        }
        return static_cast<size_t>(space.region_end_ - space.region_base_);
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

        if (space.region_base_ == nullptr || block_base < space.region_base_) {
            space.region_base_ = block_base;
        }
        if (block_base + block_size > space.region_end_) {
            space.region_end_ = block_base + block_size;
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

    void* result = Elm::platform::commitAt(region_base, initial_size);

    if (result == nullptr) {
        if (heapTraceEnabled()) {
            dumpHeapState("acquireOldGenRegion commit failed", initial_size);
        }
        return nullptr;
    }

    old_gen_committed += initial_size;
    old_gen_in_use_bytes_ += initial_size;
    noteOldGenInUsePeak();
    return region_base;
}

// Resets the allocator to initial state, optionally with a new configuration.
// Accumulates stats from all thread heaps before destroying them.
void Allocator::reset(const HeapConfig* new_config) {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    ++heap_generation_;  // destroys all thread heaps/RootSets below; bump epoch

    // Update config if provided.
    if (new_config) {
        new_config->validate();
        config_ = *new_config;
    }

#if ENABLE_GC_STATS
    // Accumulate stats from all thread heaps before destroying them.
    for (const auto& [thread_id, heap] : thread_heaps_) {
        accumulated_stats_.combine(heap->getNursery().getStats());
        accumulated_stats_.combine(heap->getOldGen().getStats());
        accumulated_stats_.combine(heap->getStats());
    }
#endif

    // Clear all thread heaps.
    thread_heaps_.clear();
    tl_heap_ = nullptr;

    // Reset committed memory tracking.
    old_gen_committed = 0;
    old_gen_in_use_bytes_ = 0;
    old_gen_in_use_peak_ = 0;   // C0 census (TEMPORARY)
    nursery_low_committed_ = 0;
    nursery_high_committed_ = 0;

    old_gen_free_blocks_.clear();

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


#if ENABLE_GC_STATS
// Returns combined statistics from all thread heaps.
GCStats Allocator::getCombinedStats() const {
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);

    // Start with accumulated stats from destroyed thread heaps.
    GCStats combined = accumulated_stats_;

    // Add stats from current thread heaps.
    for (const auto& [thread_id, heap] : thread_heaps_) {
        // Combine nursery, old-gen (allocation-size histogram), and
        // thread-local heap (major-GC) stats.
        combined.combine(heap->getNursery().getStats());
        combined.combine(heap->getOldGen().getStats());
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
