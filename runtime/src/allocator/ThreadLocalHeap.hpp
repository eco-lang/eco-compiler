#ifndef ECO_THREAD_LOCAL_HEAP_H
#define ECO_THREAD_LOCAL_HEAP_H

// The heap of the thread that runs Elm code: where its objects are allocated, and the code that decides and runs
// every collection of them.
//
// A process has one such thread, the mutator, and one `ThreadLocalHeap` for it (HEAP_007; `Allocator` owns the heap
// and states the rule and its exceptions). The heap has three parts: a young generation, `NurserySpace`, where
// ordinary objects are bump-allocated; an old generation, `OldGenSpace`, which holds what survives and the objects
// too large for the nursery; and `StackMapRoots`, the list of stack slots that a walk of the mutator's own stack
// finds holding heap pointers. Their memory comes from the process's `Allocator`, the parent; the heap holds no
// address range of its own.
//
// Two facts shape the allocation half.
//
// The first is that a pointer-bearing object is never born old (HEAP_062). Nothing records a pointer from an old
// object to a young one, so an object whose fields may later be filled with young values must itself start young.
// An allocation of at least the large-object threshold (`HeapConfig::large_object_threshold`) is therefore placed
// by `placeLargeFor`: an object that cannot hold pointers goes to the old generation directly, pinned; one that can
// goes to the nursery when it is small enough, and otherwise to the young large-object space (the YLOS): cells in
// the old generation's memory that the collector treats as young. A large String or Bytes is
// split instead (HEAP_026): a small header object in the nursery points at a header-less body in the old
// generation.
//
// The second is that bytes allocated straight into the old generation (pinned objects, YLOS objects, split bodies)
// do not fill the nursery, so they would never by themselves cause a collection. They are counted as a *debt* since
// the last minor collection, and when the debt reaches `directAllocBudget()` the nursery is made to miss its next
// allocation, so a minor collection runs (HEAP_079).
//
// Every allocation that misses the nursery runs the same ladder: a minor collection and a retry; then, if the
// survivors leave less room below the nursery's collection threshold than the object needs, a retry with the
// threshold ignored (`NurserySpace::failSoftUnclamp`); then, for a large object only, the YLOS. A request that
// still fails is out of memory.
//
// The collection half runs entirely on the mutator. A *pause* is the outermost call of `minorGC`, `majorGC` or
// `majorGCAndShrink`, including any collection nested inside it; there is no separate stop-the-world step, because
// there is only one mutator. Helper threads may do collection work inside a pause, and background threads
// (concurrent markers, the region nursery's tenure collector) between pauses, but they are started and joined by
// `NurserySpace` and `OldGenSpace`. At the end of each pause the heap reports a sync point to
// `Allocator::onGCPauseEnd`.
//
// A major collection of the old generation runs in one of two ways. A *stop-the-world major* (`majorGC`) marks
// from every root and sweeps in one pause. A *mark cycle* (HEAP_063) is a snapshot-at-the-beginning mark spread
// over several minor collections: its first pause, *t0*, greys the old-generation objects every root and every
// young object refers to; each later minor end is one step; and the *handoff* pause ends the mark and frees what
// it did not reach. `OldGenSpace` owns the cycle's states and rules; this heap decides when each step runs.
// A major triggered at a minor end runs as a cycle when incremental marking is on or more than one mark thread is
// configured, and as a stop-the-world major otherwise; one that `collectAtSafepoint` triggers without a minor is
// always stop-the-world. A major requested for an allocation failure, or explicitly, finishes any running cycle
// first and then runs a stop-the-world major.
//
// The free functions before the class initialise the header of a freshly allocated object; generated code's
// runtime entry points use them too.

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <unordered_set>
#include "AllocatorCommon.hpp"
#include "NurserySpace.hpp"
#include "OldGenSpace.hpp"
#include "StackMapRoots.hpp"
#include "GCStats.hpp"

namespace Elm {

class Allocator;

/// Writes the header of a fresh object of `size` bytes (its whole aligned size) at `hdr` for `tag`, after zeroing
/// it as `zeroNewObject` does.
///
/// `header.size` is the element count for a variable-size kind and the byte size `size` otherwise: UTF-16 units for
/// `Tag_String`, bytes for `Tag_StringUtf8Leaf`, value slots for `Tag_DynRecord` and `Tag_Closure`, entries for
/// `Tag_FieldGroup`, and 0 for the string slice, rope and UTF-8 view tags, whose constructors set it. For a Custom
/// or Record the size is split into the field count `header.size` and the extension kind words `header.unboxed`
/// (HEAP_019), and those words are zeroed; a size that cannot be split, or more fields than the kind's limit, calls
/// `ecoFatalWideObject`. The header is written with one 8-byte store, so no reader sees a field count without its
/// extension count. In statistics builds the allocation is counted by kind.
void initHeaderForTag(Header* hdr, Tag tag, size_t size);

/// Prints "[eco] FATAL: <where>: <n> slots exceeds the wide-object limit (HEAP_019)" to stderr and aborts, in every
/// build. Called when a Custom or Record's slot count cannot be split into fields and extension words, or its
/// field count is past `CUSTOM_MAX_FIELDS` or `RECORD_MAX_FIELDS`; `n` is the count the caller reports.
[[noreturn]] void ecoFatalWideObject(const char* where, u32 n);

/// Zeroes the header word of a fresh object at `hdr`, and nothing else: the rest of its `size` bytes keep whatever
/// was there before.
///
/// Leaving the payload is safe because no collector reads a payload word the mutator has not yet written. Every
/// fixed-shape object has all of its fields stored by straight-line code with no safepoint in between (HEAP_034),
/// and a `Closure`, the one kind whose used length varies, is traced only up to `n_values`, below which every slot
/// has been written.
///
/// In a build with `ECO_HEAP_VALIDATE`, the environment variable `ECO_PERSITE_ZERO=1` (read once) makes it zero
/// all `size` bytes instead, to find a write that was missed.
inline void zeroNewObject(Header* hdr, size_t size) {
#if ECO_HEAP_VALIDATE
    static const bool full = []{
        const char* e = std::getenv("ECO_PERSITE_ZERO");
        return e != nullptr && e[0] == '1';
    }();
    if (full) { std::memset(hdr, 0, size); return; }
#endif
    (void)size;
    std::memset(hdr, 0, sizeof(Header));
}

/// Returns the byte size of a Custom (when `tag` is `Tag_Custom`) or else a Record with `n` fields: the fixed part,
/// then `n` field words and the extension kind words that `extWords` gives for `n` (HEAP_019).
inline size_t wideByteSize(Tag tag, u32 n) {
    const bool isC = tag == Tag_Custom;
    return (isC ? sizeof(Custom) : sizeof(Record))
         + size_t(n + extWords(n, isC ? CUSTOM_HDR_SLOTS : RECORD_HDR_SLOTS)) * sizeof(Unboxable);
}

/// Writes the header of a fresh Custom (when `tag` is `Tag_Custom`) or else a Record with `n` fields at `hdr`, for
/// a caller that knows `n` rather than the byte size: zeroes it as `zeroNewObject` does, sets `header.size` to `n`
/// and `header.unboxed` to the extension word count in one 8-byte store, and zeroes the extension words (HEAP_077).
///
/// `wideByteSize(tag, n)` bytes must be reserved at `hdr`. Calls `ecoFatalWideObject` when `n` is past the kind's
/// field limit.
inline void initWideHeader(Header* hdr, Tag tag, u32 n) {
    const bool isC = tag == Tag_Custom;
    const u32 cap = isC ? CUSTOM_HDR_SLOTS : RECORD_HDR_SLOTS;
    if (n > (isC ? CUSTOM_MAX_FIELDS : RECORD_MAX_FIELDS)) ecoFatalWideObject("alloc", n);
    const u32 k = extWords(n, cap);
    const size_t base = isC ? sizeof(Custom) : sizeof(Record);
    zeroNewObject(hdr, base + size_t(n + k) * sizeof(Unboxable));
    Header h{};
    h.tag = tag;
    h.size = n;
    h.unboxed = k;
    std::memcpy(hdr, &h, sizeof(Header));
    if (k)
        std::memset(reinterpret_cast<char*>(hdr) + base + size_t(n) * sizeof(Unboxable), 0,
                    size_t(k) * sizeof(Unboxable));
}

/// The heap of the mutator: its nursery, its old generation and its stack-map roots, with the allocation paths into
/// them and the collections of them.
///
/// It is made by `Allocator::initThread` and must be used only by the thread it was made for. Builds with
/// `ECO_HEAP_VALIDATE` check this in `minorGC`, `majorGC` and `majorGCAndShrink`, and abort on another thread. A
/// heap is neither copied nor moved: its nursery and old generation refer to each other and to it by address.
/// Destroying it first stops the region nursery's tenure collector, finishing and merging any job left, and then
/// drops the heap's P1 census table.
///
/// The public functions that take an object size round it up to a multiple of 8. Unless a function says otherwise,
/// one that finds no memory fails an assertion, which aborts unless assertions are compiled out (the `release`
/// preset); there it returns null. Any function that may collect can move every nursery object, so a caller must
/// hold its heap pointers in roots across the call.
class ThreadLocalHeap {
public:
    /// Creates a heap that allocates through `parent` with the settings in `config`, both of which must outlive it.
    /// Neither may be null (asserted). The nursery and the old generation take their memory from `parent` when they
    /// first need it.
    ///
    /// `nursery_base`, `nursery_size`, `old_gen_base`, `old_gen_initial_size` and `old_gen_max_size` are not used.
    ThreadLocalHeap(Allocator* parent,
                    char* nursery_base, size_t nursery_size,
                    char* old_gen_base, size_t old_gen_initial_size, size_t old_gen_max_size,
                    const HeapConfig* config);

    ~ThreadLocalHeap();

    ThreadLocalHeap(const ThreadLocalHeap&) = delete;
    ThreadLocalHeap& operator=(const ThreadLocalHeap&) = delete;
    ThreadLocalHeap(ThreadLocalHeap&&) = delete;
    ThreadLocalHeap& operator=(ThreadLocalHeap&&) = delete;

    // ========== Allocation ==========

    /// Allocates an object of `size` bytes for `tag` and writes its header with `initHeaderForTag`.
    ///
    /// A large object is placed as `placeLarge` says. Otherwise, and for a large object placed in the nursery, it
    /// is bump-allocated in the nursery; on a miss this runs the ladder the file comment describes: a minor
    /// collection, then the threshold ignored, then, for a large object, the YLOS. May run a minor collection,
    /// which may run a major one, and a YLOS allocation may run a major one.
    void* allocate(size_t size, Tag tag);

    /// Bump-allocates `size` bytes in the nursery, or returns null, without collecting and without writing a
    /// header; the caller writes it.
    ///
    /// Returns null when the nursery's limit, normally its collection threshold rather than its end, is reached,
    /// and for a request larger than `NurserySpace::regionLargeCap`. The caller then calls `allocateSlow`.
    void* allocateFast(size_t size);

    /// Allocates an object of `size` bytes for `tag` and writes its header, for a caller whose `allocateFast` just
    /// failed. As `allocate`, except that an object for the nursery is not tried before the minor collection, which
    /// therefore always runs.
    void* allocateSlow(size_t size, Tag tag);

    /// Allocates `size` bytes in the nursery after a minor collection, without writing a header, for compiled
    /// code's inline nursery allocation (HEAP_034), which writes the whole header word itself before its next
    /// safepoint. Always collects. `size` must be below the large-object threshold (asserted), since only a nursery
    /// placement is safe for the caller's stores.
    void* allocateSlowRaw(size_t size);

    /// Makes room for at least `n` bytes of bump allocation in the nursery without allocating, so that compiled
    /// code can then make several allocations totalling at most `n` bytes without checking each (HEAP_041).
    ///
    /// Collects only when the room is not already there: a minor collection, then the threshold ignored. `n` must
    /// be a multiple of 8 and at most 4096 (asserted). The room stays until `n` bytes have been bump-allocated or a
    /// collection runs.
    void ensureNursery(size_t n);

    /// Allocates `total` contiguous bytes in the nursery after a minor collection, for a group of closures that the
    /// caller then divides and gives headers. Always collects.
    ///
    /// The region cannot go to the YLOS, which holds single objects, so a large one must fit the nursery; if it
    /// does not, this prints a message and aborts in every build.
    void* allocateRegionSlow(size_t total);

    /// Allocates an object of `size` bytes for `tag` straight into the old generation, writing its header, without
    /// collecting.
    ///
    /// The object is ordinary old-generation memory: a major collection frees it unless something roots it. A
    /// large one is a pinned old large object. The bytes are not counted towards the direct-allocation debt.
    void* allocatePermanent(size_t size, Tag tag);

    /// Allocates a String of `length` UTF-16 units copied from `chars`, split in two (HEAP_026): a
    /// `Tag_LargeStringHeader` object in the nursery and a header-less body in the old generation. Returns the
    /// header object. If `chars` is null the body is left uninitialised.
    ///
    /// The header is allocated first, because allocating it may run a minor collection, and a body registered
    /// before that collection with nothing yet pointing at it would be freed by it. If the body cannot be
    /// allocated, the header is abandoned with a null body, and the attempt is repeated after a minor collection
    /// and then after a major one; a third failure prints a message and aborts in every build. The body counts
    /// towards the direct-allocation debt.
    HPointer allocLargeString(const u16* chars, size_t length);

    /// Allocates a byte buffer of `length` bytes copied from `data`, or zeroed if `data` is null, split as
    /// `allocLargeString` splits a String, with a `Tag_LargeByteHeader` header object. Returns the header object.
    /// Ordering, retries and failure are as for `allocLargeString`.
    HPointer allocLargeByteBuffer(const u8* data, size_t length);

private:
    /// Allocates a pointer-free object of `size` bytes for `tag` as a pinned old large object, which a major
    /// collection frees when it is unmarked. On failure it runs one major collection and retries. `size` must be
    /// aligned, and `tag` one that cannot hold pointers (asserted).
    void* allocateLargePinned(size_t size, Tag tag);

    /// Allocates a pointer-bearing large object of `size` bytes for `tag` in the YLOS, young with the nursery's
    /// current minor colour, so the next minor collection frees it unless it is reached. On failure it runs one
    /// major collection and retries.
    ///
    /// It runs no minor collection, so no object moves. The major collection, when it runs, can still free in region
    /// mode a nursery object it did not reach (HEAP_074), so a pointer the caller will store into the new object
    /// must be rooted across this call.
    void* allocateYoungLarge(size_t size, Tag tag);

    /// Prints that a closure-group region of `total` bytes exceeds the nursery, and aborts.
    [[noreturn]] void regionTooLarge(size_t total);

    /// Adds `bytes`, just allocated straight into the old generation, to the direct-allocation debt, which starts
    /// again from zero after each minor collection. When the debt reaches `directAllocBudget()`, makes the next
    /// nursery allocation miss so that its caller runs a minor collection (`NurserySpace::requestMinor`).
    void noteDirectAlloc(size_t bytes);

    /// Prints that a large `kind` body of `body_size` bytes could not be allocated after a minor and a major
    /// collection, with the old generation's in-use bytes and cap, and aborts.
    [[noreturn]] void largeBodyExhausted(const char* kind, size_t body_size);

public:

    /// Returns the direct-allocation debt at which a minor collection is requested, or 0 when
    /// `HeapConfig::direct_alloc_minor_budget` is not positive and debt is not counted. Otherwise it is that
    /// fraction of the nursery's collection threshold, at most a 32nd of the old generation's cap when there is
    /// one, and at least 1.
    size_t directAllocBudget() const;

    // ========== Garbage Collection ==========

    /// Runs a minor collection, then whatever major work it makes due.
    ///
    /// It walks the stack for stack-map roots, collects the nursery, and in region mode joins the previous tenure job
    /// before and launches this one's after any cycle work or major in the pause, before its sync point. Then, if a
    /// mark cycle is running, this minor end is one of its steps; otherwise, if an old-generation trigger holds, it
    /// starts a mark cycle or runs a stop-the-world major, as the file comment describes.
    void minorGC();

    /// Runs a stop-the-world major collection, recording `reason` in the statistics.
    ///
    /// It first joins any tenure job and finishes a running mark cycle, then marks the old generation from every
    /// root and sweeps it. In region mode it then turns the nursery survivors it did not reach into fillers
    /// (HEAP_074).
    void majorGC(GCStats::MajorReason reason = GCStats::MajorReason::Forced);

    /// The time each phase of `majorGCAndShrink` took, in nanoseconds, and the bytes its shrink released.
    struct ReleaseTimings {
        uint64_t gc_ns = 0, sweep_ns = 0, shrink_ns = 0;
        size_t shrink_released = 0;   ///< Fall in the old generation's in-use bytes across the shrink.
    };

    /// Runs, in one pause with one sync point, a stop-the-world major collection, the lazy sweep to completion, and a
    /// shrink of the old generation to its floor, and returns how long each took (HEAP_076).
    ///
    /// The sync point comes after the shrink, so the memory it releases is pending at the sync point; discarding
    /// it is left to the caller. Aborts if called inside a pause.
    ReleaseTimings majorGCAndShrink();

    // ========== Accessors ==========

    /// Where an allocation of at least the large-object threshold goes: the nursery, like a small object; the
    /// young large-object space; or, for a tag that cannot hold pointers, the old generation, pinned. `Region` is a
    /// closure-group region, which goes to the nursery; it is used only for statistics and `placeLargeFor` never
    /// returns it.
    enum class LargePlacement : uint8_t { Nursery, Ylos, Region, PointerFree };

    /// Counts one large allocation of `size` bytes with `tag` at `where`, in statistics builds. In builds with
    /// `ECO_HEAP_VALIDATE`, the environment variable `ECO_LARGE_PTR_TRACE` (read once) also logs it: set to 1, as a
    /// line and a backtrace on stderr; set to anything else non-empty, as a line appended to the file it names.
    void noteLargeAlloc(LargePlacement where, size_t size, uint32_t tag);

    /// Returns where a large allocation of `size` bytes with `tag` goes, for a nursery of `nursery_capacity` bytes.
    ///
    /// `PointerFree` when `tag` cannot hold pointers. Otherwise `Nursery` when `size` is at most the nursery cap,
    /// and `Ylos` when it is larger or `cfg.large_ptr_nursery_divisor` is 0. The cap is `nursery_capacity` divided
    /// by that divisor, no more than `cfg.large_ptr_nursery_max_size` when that is not 0, and no more than
    /// `region_cap`. It reads nothing else, so a test can pass any capacity.
    static LargePlacement placeLargeFor(size_t size, uint32_t tag,
                                        size_t nursery_capacity,
                                        const HeapConfig& cfg,
                                        size_t region_cap = SIZE_MAX) {
        if (!tagMayHoldPointers(tag)) return LargePlacement::PointerFree;
        if (cfg.large_ptr_nursery_divisor == 0) return LargePlacement::Ylos;
        size_t cap = nursery_capacity / cfg.large_ptr_nursery_divisor;
        if (cfg.large_ptr_nursery_max_size != 0)
            cap = std::min(cap, cfg.large_ptr_nursery_max_size);
        cap = std::min(cap, region_cap);
        return size <= cap ? LargePlacement::Nursery : LargePlacement::Ylos;
    }
    /// Returns `placeLargeFor` for this heap. The cap also excludes anything larger than the old generation's
    /// largest size class, and in region mode anything above `NurserySpace::regionLargeCap`, so that a nursery
    /// object can always be promoted into a size-class cell.
    LargePlacement placeLarge(size_t size, uint32_t tag) const {
        return placeLargeFor(size, tag, nursery_.capacityBytes(), *config_,
                             std::min(nursery_.regionLargeCap(),
                                      old_gen_.largestUniformClassBytes()));
    }

    /// Returns whether a mark cycle is running (HEAP_063).
    bool markCycleActive() const { return old_gen_.cycleActive(); }

    // Switches for tests only.

    /// When set, t0 does not walk the young objects, as a negative control.
    bool test_snapshot_skip_young_walk_ = false;
    /// When set, t0 does not run the external root scanners, as a negative control.
    bool test_snapshot_skip_external_ = false;
    /// When set, the next minor end acts as if a major trigger held, and clears it.
    bool test_force_major_trigger_ = false;

    /// Returns whether a collection of this heap is running: whether the call is inside a pause.
    bool inPause() const { return pause_depth_ > 0; }

    /// Returns the nursery's root set. Valid for the heap's lifetime.
    RootSet& getRootSet() { return nursery_.getRootSet(); }

    /// Returns the stack-map roots found by the last stack walk. For the collector only.
    StackMapRoots& getStackMapRoots() { return stack_map_roots_; }
    /// Returns the stack-map roots found by the last stack walk. For the collector only.
    const StackMapRoots& getStackMapRoots() const { return stack_map_roots_; }

    /// Returns the nursery. Valid for the heap's lifetime.
    NurserySpace& getNursery() { return nursery_; }

    /// Returns the old generation. Valid for the heap's lifetime.
    OldGenSpace& getOldGen() { return old_gen_; }

    /// Returns the allocator the heap was created with.
    Allocator* getParent() { return parent_; }

    /// Returns the configuration the heap was created with.
    const HeapConfig* getConfig() const { return config_; }

    // ========== Diagnostics ==========

    /// Returns whether `collectAtSafepoint` would collect: whether the nursery is past
    /// `HeapConfig::nursery_gc_threshold` or an old-generation major trigger holds.
    bool shouldCollectAtSafepoint() const;

    /// Collects at a safepoint: a minor collection if the nursery is past `HeapConfig::nursery_gc_threshold`,
    /// otherwise a stop-the-world major if an old-generation trigger holds, otherwise nothing.
    void collectAtSafepoint();

    /// Returns whether the nursery's object bytes have reached the fraction `threshold` of its current capacity
    /// (one extent, which grows over the heap's life).
    bool isNurseryNearFull(float threshold) const;

    /// Returns whether `ptr` is in this heap's nursery.
    bool isInNursery(void* ptr) const { return nursery_.contains(ptr); }

    /// Returns whether `ptr` is in this heap's old generation.
    bool isInOldGen(void* ptr) const { return old_gen_.contains(ptr); }

    /// Returns the bytes allocated in the old generation.
    size_t getOldGenAllocatedBytes() const { return old_gen_.getAllocatedBytes(); }

#if ECO_HEAP_VALIDATE
    /// The thread the heap belongs to, set by whoever made it. A default id means it is not checked.
    std::thread::id owner_;
    /// Prints a message naming `where` and aborts when called on a thread other than `owner_`.
    void assertOwner(const char* where) const;

    /// Aborts if `ptr` is in the nursery's address range but not in any part of it that holds objects.
    void debugAssertValidNurseryPointer(void* ptr) {
        nursery_.debugAssertValidNurseryPointer(ptr);
    }
#endif

#if ENABLE_GC_STATS
    /// Returns this heap's own statistics, apart from those its nursery and old generation keep.
    GCStats& getStats() { return stats_; }
    /// Returns this heap's own statistics, apart from those its nursery and old generation keep.
    const GCStats& getStats() const { return stats_; }
#endif

private:
    Allocator* parent_;           ///< Not owned; outlives the heap.
    const HeapConfig* config_;    ///< Not owned; outlives the heap.
    NurserySpace nursery_;
    OldGenSpace old_gen_;
    StackMapRoots stack_map_roots_;
    bool force_gc_ = false;       ///< Makes the next safepoint collect.
    /// How many `minorGC`, `majorGC` and `majorGCAndShrink` calls are running, nested. The pause ends when it
    /// returns to 0.
    int pause_depth_ = 0;
    bool pause_had_major_ = false;   ///< Whether the current pause ran a major or a cycle handoff.

    /// Calls `f(slot, kind)` for every root slot except the long-lived and JIT roots: kind 0 for stack-map slots,
    /// 1 for the shadow-stack range slots their masks select and for single-slot roots, 2 for each word an external
    /// root scanner offers. A kind-2 slot is a copy of the scanner's word, so writing to it changes nothing.
    template <typename F> void forEachMajorRoot(RootSet& root_set, F&& f);
    /// Returns whether a triggered major runs as a mark cycle: when incremental marking is on, or there is more
    /// than one mark thread. With incremental marking off, the cycle has no steps and runs whole in its t0 pause.
    bool useMarkCycle() const {
        return config_->incremental_mark || old_gen_.markThreads() > 1;
    }
    /// Starts a mark cycle for `reason` with its t0 snapshot. With incremental marking off, finishes the whole
    /// cycle in this pause.
    void startMarkCycle(GCStats::MajorReason reason);
    /// Runs the running cycle's step at a minor end: the handoff when it is due, a finish when the old
    /// generation's pressure requires one, and otherwise one step of marking.
    void stepMarkCycle();
    /// Finishes the running cycle's mark now and runs its handoff, recording `why`.
    void finishMarkCycleNow(OldGenSpace::CycleFinish why);
    /// Runs the handoff of a cycle whose mark has finished, and records it as one major collection.
    void completeMarkCycle(OldGenSpace::CycleFinish why);
    /// Records that the current pause carried cycle work: `what` 0 for t0, 1 for a step, 2 for a handoff.
    void notePauseCycleWork(int what);
    uint64_t cycle_t0_wall_ns_ = 0;   ///< Steady-clock time at the running cycle's t0.
    uint64_t cycle_mark_ns_ = 0;      ///< Time the running cycle has spent marking in pauses.
    uint64_t cycle_inpause_ns_ = 0;   ///< Time the running cycle has spent in pauses.
#if ECO_HEAP_VALIDATE
    /// Returns every old-generation object reachable from the roots, found independently of the mark. Sets
    /// `*complete` to false, and returns what it found so far, if it visits more than five million objects.
    std::vector<void*> traceOldReachableForValidation(bool* complete);
#endif
    friend struct PauseEndHook;

    // The direct-allocation debt: bytes allocated straight into the old generation since minor collection number
    // `direct_debt_seq_`. When the nursery's count has moved on, the debt is reset on the next note.
    size_t direct_debt_bytes_ = 0;
    uint64_t direct_debt_seq_ = 0;

#if ENABLE_GC_STATS
    GCStats stats_;

#if ENABLE_GC_PHASE_TIMERS
    // The pause being timed: how many minorGC, majorGC and majorGCAndShrink calls are running, when the
    // outermost began, and what it has contained so far.
    int      gc_depth_ = 0;
    uint64_t pause_start_ns_ = 0;
    bool     pause_saw_minor_ = false;
    bool     pause_saw_major_ = false;
    bool     pause_saw_t0_ = false;
    bool     pause_saw_slice_ = false;
    bool     pause_saw_handoff_ = false;
    uint64_t pause_cpu_start_ns_ = 0;     ///< The mutator's CPU time when the pause began.
    friend struct GCPauseScope;

    /// Records one pause that began at `start_ns` and took `dur_ns`, of `kind`: 0 minor, 1 minor with a major, 2
    /// major, 3 minor with a t0, 4 minor with a cycle step, 5 minor with a handoff.
    void recordPause(uint64_t start_ns, uint64_t dur_ns, uint8_t kind);

    /// Completes `rec`, one minor collection's phase times, with its pause length, and records it.
    void recordMinorPhases(MinorGCRecord& rec);
#endif
#endif

    /// Returns the long-lived roots of the root set. The reference is to the root set's own set.
    const std::unordered_set<HPointer*>& collectRoots();

    /// Counts of one stack walk: frames visited, frames found in the stack map, and root slots kept.
    struct StackWalkCounts {
        uint64_t frames_walked = 0;
        uint64_t frames_matched = 0;
        uint64_t slots = 0;
    };
    /// Rebuilds the stack-map roots by walking the calling thread's stack and returns the walk's counts.
    ///
    /// Each frame whose return address the stack map records contributes the stack slots it lists, those of its
    /// `Indirect` locations, that hold a pointer into the heap; slots holding null or an embedded constant are
    /// skipped. When the stack map has no records at all, the list is left as it was and the counts are 0. It
    /// writes nothing to the `RootSet` (HEAP_020).
    StackWalkCounts collectStackRootsFromStackMap();
};

} // namespace Elm

#endif // ECO_THREAD_LOCAL_HEAP_H
