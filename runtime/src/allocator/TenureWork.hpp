#pragma once

// The part of the region nursery's tenure job that does not depend on the allocator: the record of where each
// object has been copied, and a single-threaded engine that does the copying and can be stopped and resumed.
//
// In the region nursery, objects that survive a minor collection are kept in survivor extents and promoted to the
// old generation later, by a tenure job. A tenure job runs on a collector thread while the mutator keeps running
// Elm code. The extent it promotes is the tenuring extent; it is handed to the job in a pause (the hand-over pause),
// and the job's results are installed in a later pause (the merge). Each use of an extent has a generation number,
// its gen, which the job is told at the hand-over.
//
// Three facts shape everything here.
//
// First, the objects of the tenuring extent are visible to Elm while the job runs, so the job may not write them,
// not even their headers. Where an object has been copied is therefore kept off the object, in a shadow entry: a
// 64-bit word per object, located by the heap side. A shadow entry holds
//     bits 0..2    the state: 0 unvisited, 1 BUSY (a copier has claimed the object and is copying it), 2 FWD
//                  (copied);
//     bits 3..42   the copy's absolute address when FWD, else 0 in an entry written as BUSY (so addresses must
//                  be 8-byte aligned and below 2^43);
//     bits 43..63  the gen of the extent when the entry was written.
// An entry whose gen differs from the job's gen reads as unvisited, so entries left from an extent's earlier use
// need not be cleared. The cost is that a claim must compare against the word actually loaded, which may be such
// a stale entry, and never against zero.
//
// Second, the job writes only what no one else can see: shadow entries of the extent it tenures, memory the Env's
// `copy` gives it, and the job's own state. The only object slots it stores to are slots of its own fresh copies.
// Slots of other objects that point into the tenuring extent (the heal slots, and the slots of young large objects
// in the YLOS) are read here and left for the merge to rewrite.
//
// Third, the job must be exact: stopped at any point and finished on another thread, it must make the same copies
// at the same addresses as a run that was never stopped. `SerialEngine` gets this by keeping all its progress in
// `SerialState` and doing its work in items (each a small bounded unit of work, such as one object copy), and by
// checking for a stop only between items.
//
// When survivors age for more than one minor before tenuring, the extents still ageing are cleaned up by the same
// engine before it tenures. A mark phase traces, without writing any object, the objects of the ageing extents (and
// the ageing generations' YLOS objects) reachable from the sources the pause found; a marked object's slot into the
// tenuring extent becomes a heal slot. A sweep phase then walks each ageing extent's mark bitmap in address order
// and records each run of unmarked memory between marked objects as a zap span, which the merge covers with a filler
// object. The sweep reads the headers of marked objects only.
//
// Most of the file is `SerialEngine`. The shadow-entry functions also serve a copier that does claim entries
// (`claim`, `waitPublished`), which the serial engine never does. Nothing here includes the allocator: the heap
// side reaches the engine only through the Env template argument, so a test harness can run the same engine over a
// synthetic heap.

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

#include "TlaTrace.hpp"   // ECO_TLA_TRACE hooks; they compile to nothing outside a trace build

namespace Elm::tenurework {

#if ECO_TLA_TRACE_ENABLED
/// Whether the engine calls `tlatrace::probe` at its pause points (an item taken, a copy made but not yet
/// published, a copy popped but not yet scanned). Trace builds only; a harness sets it.
inline bool tla_probes = false;
#endif

// ---------------------------------------------------------------------------
// Shadow entries
// ---------------------------------------------------------------------------
/// The bits of a shadow entry that hold its state.
constexpr uint64_t kStateMask  = 7;
/// The state of an entry whose object a copier has claimed and not yet published.
constexpr uint64_t kStateBusy  = 1;
/// The state of an entry whose object has been copied; the address bits name the copy.
constexpr uint64_t kStateFwd   = 2;
/// The position of the gen in a shadow entry.
constexpr unsigned kGenShift   = 43;
/// The gen bits, after shifting down: a gen is kept modulo 2^21.
constexpr uint32_t kGenMask    = (1u << 21) - 1;
/// The bits of a shadow entry that hold the copy's address (bits 3..42).
constexpr uint64_t kAddrMask   = ((uint64_t{1} << kGenShift) - 1) & ~kStateMask;

/// Returns the shadow entry with state `state`, gen `gen` and address `dst`. Bits of `dst` outside bits 3..42 are
/// dropped.
inline uint64_t make(const void* dst, uint64_t state, uint32_t gen) {
    return (reinterpret_cast<uintptr_t>(dst) & kAddrMask) | state |
           (static_cast<uint64_t>(gen & kGenMask) << kGenShift);
}
/// Returns the gen of entry `e`.
inline uint32_t genOf(uint64_t e) { return static_cast<uint32_t>(e >> kGenShift); }
/// Returns the state of entry `e`, ignoring its gen.
inline uint64_t stateOf(uint64_t e) { return e & kStateMask; }
/// Returns the address bits of entry `e`, ignoring its state and gen.
inline char* addrOf(uint64_t e) { return reinterpret_cast<char*>(static_cast<uintptr_t>(e & kAddrMask)); }

/// Returns an atomic view of the shadow entry at `w`, valid while `w` is.
inline std::atomic_ref<uint64_t> ref(uint64_t* w) { return std::atomic_ref<uint64_t>(*w); }

/// Returns the copy's address when `e` is FWD in generation `gen`, else nullptr.
inline char* fwdOf(uint64_t e, uint32_t gen) {
    return (genOf(e) == (gen & kGenMask) && stateOf(e) == kStateFwd) ? addrOf(e) : nullptr;
}
/// Returns the copy's address if the entry at `w` is FWD in generation `gen`, else nullptr. The load is an acquire,
/// so a non-null result may be read as a complete copy.
inline char* lookup(uint64_t* w, uint32_t gen) {
    return fwdOf(ref(w).load(std::memory_order_acquire), gen);
}
/// Tries to change the entry at `w` from `observed` to BUSY in generation `gen`, and returns whether it did. On
/// failure `observed` holds the entry's current value.
///
/// `observed` must be the value the caller loaded, not zero: an entry from the extent's earlier use is unvisited
/// but nonzero, and can only be claimed by comparing against it.
inline bool claim(uint64_t* w, uint64_t& observed, uint32_t gen) {
    return ref(w).compare_exchange_strong(observed, make(nullptr, kStateBusy, gen),
                                          std::memory_order_acq_rel, std::memory_order_acquire);
}
/// Sets the entry at `w` to FWD at `dst` in generation `gen`. The store is a release, so a reader that sees it with
/// an acquire load also sees the copy written before the call.
inline void publish(uint64_t* w, const void* dst, uint32_t gen) {
    ref(w).store(make(dst, kStateFwd, gen), std::memory_order_release);
}
/// Waits until the entry at `w` is not BUSY in generation `gen`, calling `pause(round)` between loads, and returns
/// the entry last loaded. The result may be FWD, or an unvisited or stale entry. It never returns while the entry
/// stays BUSY.
template <class Pause>
inline uint64_t waitPublished(uint64_t* w, uint32_t gen, Pause&& pause) {
    for (unsigned round = 0;; ++round) {
        const uint64_t e = ref(w).load(std::memory_order_acquire);
        if (!(genOf(e) == (gen & kGenMask) && stateOf(e) == kStateBusy)) return e;
        pause(round);
    }
}

// ---------------------------------------------------------------------------
// The serial engine's state
// ---------------------------------------------------------------------------
/// One young large object (YLOS object) in a snapshot: it occupies [`obj`, `end`).
struct YlosEntry {
    const char* obj;
    const char* end;
};

/// A run of dead memory in an ageing extent, which the merge covers with one filler object of `bytes` bytes at `p`.
struct Span {
    char* p;
    size_t bytes;
};

/// Everything a tenure job knows, so that a stopped job can be resumed by a fresh `SerialEngine` on any thread.
///
/// The inputs are filled in by the hand-over pause; the rest is the engine's progress and counters. Nothing here
/// synchronises access: whoever runs the job must hand it between threads with some synchronisation of its own.
struct SerialState {
    // Inputs, filled in the hand-over pause (the job appends to `heal` and sets `reached`).
    std::vector<void*>     starts;      ///< Objects of the tenuring extent to tenure first.
    /// Slots outside the tenuring extent whose value may point into it. Read here, rewritten by the merge. The mark
    /// phase appends to it.
    std::vector<uint64_t*> heal;
    std::vector<YlosEntry> ylos;        ///< The tenuring generation's YLOS objects, sorted by `obj`.
    std::vector<uint8_t>   reached;     ///< Per `ylos` entry: nonzero once the pause or the job has reached it.
    // Resumable progress.
    size_t next_start = 0;
    size_t next_heal = 0;
    /// Copies still to be scanned. Taken from the back, or from `stack_head` forwards when `fifo` is set.
    std::vector<void*>  stack;
    size_t stack_head = 0;              ///< In FIFO order: entries before this index are already taken.
    bool fifo = false;                  ///< Scan copies breadth first instead of depth first.
    std::vector<uint32_t> ylos_pending; ///< Indices into `ylos` of reached objects, in the order they were reached.
    size_t ylos_next = 0;
    // The mark and sweep phases over the ageing extents.
    std::vector<void*>     age_starts;     ///< The pause's mark sources: ageing objects and ageing YLOS objects.
    std::vector<YlosEntry> age_ylos;       ///< The ageing generations' YLOS objects, sorted by `obj`.
    std::vector<uint8_t>   age_ylos_marked;   ///< Per `age_ylos` entry: nonzero once marked.
    unsigned n_age = 0;                    ///< The number of ageing extents to sweep.
    size_t next_age_start = 0;
    std::vector<void*> age_stack;          ///< Marked objects still to be scanned.
    unsigned sweep_x = 0;                  ///< The ageing extent being swept.
    size_t sweep_w = 0;                    ///< The next word of that extent's mark bitmap.
    char* sweep_gap = nullptr;             ///< Start of the current dead run; nullptr between extents.
    std::vector<Span> zap;                 ///< The dead runs found, for the merge to fill.
    uint64_t age_marked = 0, age_marked_bytes = 0, age_heal = 0, zapped = 0, zapped_bytes = 0;
    // Counters.
    uint64_t tenured = 0, tenured_bytes = 0, items = 0, spine_runs = 0, ylos_reached = 0;
    // Test hooks, to be set only while no job runs.
    uint64_t test_skip_start_every = 0;   ///< When k is nonzero, skips every k-th start, so a test can see it missed.
    uint64_t test_stop_after = 0;         ///< When nonzero, `run` stops once, after this many items, and clears it.
    uint64_t test_sleep_us_per_item = 0;  ///< When nonzero, sleeps this many microseconds after each item.

    /// Resets the progress and counters to the start of a job, keeping the inputs (`starts`, `heal`, `ylos`,
    /// `reached`, the `age_*` inputs, `n_age`) and the test hooks.
    void clearProgress() {
        next_start = next_heal = 0;
        stack.clear();
        stack_head = 0;
        ylos_pending.clear();
        ylos_next = 0;
        tenured = tenured_bytes = items = spine_runs = ylos_reached = 0;
        next_age_start = 0;
        age_stack.clear();
        sweep_x = 0;
        sweep_w = 0;
        sweep_gap = nullptr;
        zap.clear();
        age_marked = age_marked_bytes = age_heal = zapped = zapped_bytes = 0;
    }
    /// Returns whether the mark and sweep phases have nothing left to do.
    bool markPhasesDone() const {
        return age_stack.empty() && next_age_start >= age_starts.size() && sweep_x >= n_age;
    }
    /// Returns whether the job has nothing left to do in any phase.
    bool done() const {
        return markPhasesDone() && stack.size() == stack_head && next_start >= starts.size() &&
               next_heal >= heal.size() && ylos_next >= ylos_pending.size();
    }
};

/// How a run of the engine ended: `Done` when no work is left, `Stopped` when a stop was requested, in which case
/// the state is between items and the job can be resumed.
enum class DrainResult { Done, Stopped };

/// The most list cells one spine run tenures before the rest of the list is left for a later item. It has the same
/// value as `MINOR_SPINE_RUN`, the minor collector's bound; nothing checks that the two agree.
constexpr size_t kSpineRun = 512;

/// Returns the index of the entry in `ys` whose object starts exactly at `p`, or -1 if there is none. `ys` must be
/// sorted by `obj`. A binary search.
inline long ylosFind(const std::vector<YlosEntry>& ys, const void* p) {
    size_t lo = 0, hi = ys.size();
    const char* q = static_cast<const char*>(p);
    while (lo < hi) {
        const size_t mid = (lo + hi) / 2;
        if (ys[mid].obj < q) lo = mid + 1;
        else hi = mid;
    }
    return (lo < ys.size() && ys[lo].obj == q) ? static_cast<long>(lo) : -1;
}

// ---------------------------------------------------------------------------
// The serial engine
// ---------------------------------------------------------------------------
/// The exact, resumable engine of one tenure job, over the state in a `SerialState` and the heap behind an `Env`.
///
/// An engine holds references to both and owns nothing; each must outlive it. Engines are cheap, and a stopped job
/// is resumed by building a new one over the same state. The engine copies without claiming shadow entries, so no
/// other copier may work on the same extent while it runs; it aborts the process if it finds a BUSY entry.
///
/// `Env` must provide the following, all over data that is private to the job or does not change while it runs:
///   void*     target(uint64_t word)           the heap object a slot word names, or nullptr
///   uint64_t  word(const void* obj)           the slot word that names obj
///   bool      inTenuring(const void* p)       whether p is in the tenuring extent's survivor part
///   bool      ylosMaybe(const void* p)        a cheap filter: false only if p is not in the YLOS snapshot
///   bool      youngElsewhere(const void* p)   whether p is in the nursery but outside the tenuring extent
///   uint64_t* shadow(const void* obj)         obj's shadow entry
///   uint32_t  gen()                           the job's gen
///   size_t    sizeOf(const void* obj)         obj's size in bytes, read from its header
///   void*     copy(const void* obj, size_t)   allocates in memory given to the job, copies obj there, and
///                                             returns the copy
///   template<F> void forEachChildSlot(void* obj, F f)   calls f(uint64_t* slot) for each boxed slot of obj
///   uint64_t* consTail(void* obj)             the tail slot if obj is a list cell, else nullptr
///   uint64_t* consHead(void* obj)             the boxed head slot of a list cell, else nullptr
///   [[noreturn]] void abortYoungChild(const void* parent, const void* child)
///                                             reports a nursery child outside the tenuring extent; does not return
/// and, for the mark and sweep phases:
///   int       ageIndex(const void* p)          the ageing extent whose survivor part holds p, or -1
///   bool      markAge(int i, const void* obj)  sets obj's mark bit in extent i; true if it was not already set
///   char*     ageBase(unsigned i), ageTop(unsigned i)   the bounds of extent i's survivor part
///   bool      ageYlosMaybe(const void* p)     a cheap filter for the ageing YLOS snapshot
///   const uint64_t* ageBits(unsigned i)       extent i's mark bitmap, one bit per 8-byte granule
template <class Env>
class SerialEngine {
public:
    /// Creates an engine over `st` and `env`, keeping references to both.
    SerialEngine(SerialState& st, Env& env) : st_(st), env_(env) {}

    /// Does items until the job is done or `stop` (if not null) is set, and says which. `stop` is read with a
    /// relaxed load before each item, so the item in progress always finishes. The state's one-shot
    /// `test_stop_after` also stops the run.
    DrainResult run(const std::atomic<bool>* stop) {
        for (;;) {
            if (stop != nullptr && stop->load(std::memory_order_relaxed)) {
                ECO_TLA_TRACE("tstop", "get", ::Elm::tlatrace::key("S", stop, static_cast<int64_t>(env_.gen())));
                return DrainResult::Stopped;
            }
            if (st_.test_stop_after != 0 && st_.items >= st_.test_stop_after) {
                st_.test_stop_after = 0;          // a one-shot forced stop
                return DrainResult::Stopped;
            }
            if (!step()) {
                ECO_TLA_TRACE("tend");
                return DrainResult::Done;
            }
            ++st_.items;
            if (st_.test_sleep_us_per_item != 0) sleepUs(st_.test_sleep_us_per_item);
        }
    }

    /// Finishes the mark and sweep phases, leaving the tenuring itself undone. Takes no stop request.
    void runMarkPhases() {
        while (!st_.markPhasesDone()) {
            markOrSweepStep();
            ++st_.items;
        }
    }
    /// Finishes sweeping the ageing extent a stopped run was partway through, if any, so that the remaining sweep
    /// starts at an extent boundary.
    void finishSweepExtent() {
        while (st_.sweep_x < st_.n_age && st_.sweep_gap != nullptr) {
            sweepStep();
            ++st_.items;
        }
    }

    /// Returns the copy of `obj`, which must be in the tenuring extent, copying it first if it has not been. A new
    /// copy is published in its shadow entry and, when `push` is set, queued to have its slots scanned.
    char* tenure(void* obj, bool push = true) {
        uint64_t* w = env_.shadow(obj);
        const uint32_t g = env_.gen();
        // No claim: this engine is the only writer of the extent's shadow entries while it runs (see the class
        // comment), and a relaxed load sees its own earlier stores. FWD is published once, after the copy.
        uint64_t e = ref(w).load(std::memory_order_relaxed);
        ECO_TLA_TRACE("tload", "obj", ::Elm::tlatrace::obj(obj), "st", stateOf(e), "g", genOf(e),
                      "dst", ::Elm::tlatrace::obj(fwdOf(e, g)));
        if (char* d = fwdOf(e, g)) return d;
        if (genOf(e) == (g & kGenMask) && stateOf(e) == kStateBusy) {
            std::fprintf(stderr, "[tenure] FATAL: BUSY shadow entry in the exact engine (%p)\n", obj);
            std::abort();
        }
        const size_t size = env_.sizeOf(obj);
        char* dst = static_cast<char*>(env_.copy(obj, size));
        ECO_TLA_TRACE("tcopy", "obj", ::Elm::tlatrace::obj(obj), "dst", ::Elm::tlatrace::obj(dst));
        ++st_.tenured;
        st_.tenured_bytes += size;
        ECO_TLA_TRACE_ONLY(if (tla_probes) ::Elm::tlatrace::probe("m5.item.copied");)   // copied, unpublished
        publish(w, dst, g);
        ECO_TLA_TRACE("tpub", "obj", ::Elm::tlatrace::obj(obj), "dst", ::Elm::tlatrace::obj(dst));
        if (push) st_.stack.push_back(dst);
        return dst;
    }

private:
    SerialState& st_;   ///< The job's state; the caller's, which must outlive the engine.
    Env& env_;          ///< The heap side; the caller's, which must outlive the engine.

    /// Sleeps the calling thread for `us` microseconds.
    static void sleepUs(uint64_t us);

    /// Does one item and returns true, or returns false if there is nothing left. Work is taken in this order: the
    /// mark and sweep phases, then queued copies, then starts, then heal slots, then reached YLOS objects.
    bool step() {
        if (!st_.markPhasesDone()) {
            markOrSweepStep();
            return true;
        }
        if (st_.stack.size() != st_.stack_head) {
            void* c;
            if (st_.fifo) {
                c = st_.stack[st_.stack_head++];
                // Drop the taken prefix once it is at least half the vector, so the queue stays bounded.
                if (st_.stack_head == st_.stack.size()) {
                    st_.stack.clear();
                    st_.stack_head = 0;
                } else if (st_.stack_head >= 4096 && st_.stack_head * 2 >= st_.stack.size()) {
                    st_.stack.erase(st_.stack.begin(),
                                    st_.stack.begin() + static_cast<std::ptrdiff_t>(st_.stack_head));
                    st_.stack_head = 0;
                }
            } else {
                c = st_.stack.back();
                st_.stack.pop_back();
            }
            ECO_TLA_TRACE_ONLY(if (tla_probes) ::Elm::tlatrace::probe("m5.item.popped");)   // popped, unscanned
            scanCopy(c);
            return true;
        }
        if (st_.next_start < st_.starts.size()) {
            const size_t i = st_.next_start++;
            ECO_TLA_TRACE_ONLY(if (tla_probes) ::Elm::tlatrace::probe("m5.item.taken");)   // taken, not copied
            ECO_TLA_TRACE("titem", "k", "start", "idx", i, "tgt", ::Elm::tlatrace::obj(st_.starts[i]));
            if (i + 8 < st_.starts.size()) prefetchTarget(st_.starts[i + 8]);
            if (st_.test_skip_start_every != 0 && (i + 1) % st_.test_skip_start_every == 0) return true;
            tenure(st_.starts[i]);
            return true;
        }
        if (st_.next_heal < st_.heal.size()) {
            if (st_.next_heal + 16 < st_.heal.size()) __builtin_prefetch(st_.heal[st_.next_heal + 16], 0, 3);
            const uint64_t v = *st_.heal[st_.next_heal++];   // the slot's object is visible to Elm, so v is fixed
            void* t = env_.target(v);
            ECO_TLA_TRACE("titem", "k", "heal", "idx", st_.next_heal - 1, "tgt", ::Elm::tlatrace::obj(t));
            if (t != nullptr && env_.inTenuring(t)) tenure(t);
            return true;
        }
        if (st_.ylos_next < st_.ylos_pending.size()) {
            scanYlos(st_.ylos_pending[st_.ylos_next++]);
            return true;
        }
        return false;
    }

    // ---- The mark and sweep phases over the ageing extents ----

    /// Does one item of the mark and sweep phases: scans a marked object, else marks from the next pause source,
    /// else sweeps one bitmap word.
    void markOrSweepStep() {
        if (!st_.age_stack.empty()) {
            void* o = st_.age_stack.back();
            st_.age_stack.pop_back();
            scanAge(o);
            return;
        }
        if (st_.next_age_start < st_.age_starts.size()) {
            const size_t i = st_.next_age_start++;
            if (i + 8 < st_.age_starts.size()) __builtin_prefetch(st_.age_starts[i + 8], 0, 3);
            markTarget(st_.age_starts[i], nullptr, nullptr);
            return;
        }
        sweepStep();
    }

    /// Marks `t` and queues it for scanning if it is an unmarked object of the ageing YLOS snapshot. Returns whether
    /// `t` is in that snapshot.
    bool markAgeYlos(void* t) {
        const long k = ylosFind(st_.age_ylos, t);
        if (k < 0) return false;
        if (st_.age_ylos_marked[static_cast<size_t>(k)]) return true;
        st_.age_ylos_marked[static_cast<size_t>(k)] = 1;
        ++st_.age_marked;
        st_.age_marked_bytes += env_.sizeOf(t);
        st_.age_stack.push_back(t);
        return true;
    }

    /// Handles a reference to `t` found by the mark phase: from a pause source when `parent` is null, else from slot
    /// `s` of the marked object `parent`. An ageing object or ageing YLOS object is marked and queued. A child in
    /// the tenuring extent makes `s` a heal slot, and a child in the tenuring generation's YLOS snapshot is reached.
    /// A pause source that is not an ageing object or ageing YLOS object aborts the process, and so does a child
    /// that is young elsewhere.
    void markTarget(void* t, void* parent, uint64_t* s) {
        const int i = env_.ageIndex(t);
        if (i >= 0) {
            if (env_.markAge(i, t)) {
                ++st_.age_marked;
                st_.age_marked_bytes += env_.sizeOf(t);
                st_.age_stack.push_back(t);
            }
            return;
        }
        if (parent != nullptr && env_.inTenuring(t)) {
            st_.heal.push_back(s);
            ++st_.age_heal;
            return;
        }
        if (parent != nullptr && env_.ylosMaybe(t) && ylosFind(st_.ylos, t) >= 0) {
            reachYlos(t);
            return;
        }
        if (env_.ageYlosMaybe(t) && markAgeYlos(t)) return;
        if (parent == nullptr) {
            std::fprintf(stderr, "[tenure] FATAL: an age source outside the ageing extents (%p)\n", t);
            std::abort();
        }
        if (env_.youngElsewhere(t)) env_.abortYoungChild(parent, t);   // checked in every build
    }

    /// Passes each non-null boxed child of the marked object `o` to `markTarget`.
    void scanAge(void* o) {
        env_.forEachChildSlot(o, [&](uint64_t* s) {
            void* t = env_.target(*s);
            if (t != nullptr) markTarget(t, o, s);
        });
    }

    /// Records [`p`, `p` + `bytes`) as a zap span.
    void emitGap(char* p, size_t bytes) {
        st_.zap.push_back(Span{p, bytes});
        ++st_.zapped;
        st_.zapped_bytes += bytes;
    }

    /// Sweeps one word of the current ageing extent's mark bitmap, recording the dead run before each marked
    /// object it covers. At the end of the extent, records the dead run up to the extent's top and moves to the
    /// next extent.
    void sweepStep() {
        const unsigned x = st_.sweep_x;
        char* base = env_.ageBase(x);
        char* top = env_.ageTop(x);
        if (st_.sweep_gap == nullptr) {
            st_.sweep_gap = base;
            st_.sweep_w = 0;
        }
        const size_t words = ((static_cast<size_t>(top - base) >> 3) + 63) / 64;
        if (st_.sweep_w >= words) {
            if (st_.sweep_gap < top) emitGap(st_.sweep_gap, static_cast<size_t>(top - st_.sweep_gap));
            ++st_.sweep_x;
            st_.sweep_gap = nullptr;
            st_.sweep_w = 0;
            return;
        }
        uint64_t bits = env_.ageBits(x)[st_.sweep_w];
        while (bits != 0) {
            const unsigned b = static_cast<unsigned>(__builtin_ctzll(bits));
            bits &= bits - 1;
            char* p = base + ((st_.sweep_w * 64 + b) << 3);
            if (p > st_.sweep_gap) emitGap(st_.sweep_gap, static_cast<size_t>(p - st_.sweep_gap));
            st_.sweep_gap = p + env_.sizeOf(p);
        }
        ++st_.sweep_w;
    }

    /// Marks the tenuring generation's YLOS object at `t` as reached and queues it for scanning, if it is in the
    /// snapshot and not already reached. An object outside the snapshot is ignored here.
    void reachYlos(const void* t) {
        const long k = ylosFind(st_.ylos, t);
        if (k < 0) return;
        ECO_TLA_TRACE("treach", "obj", ::Elm::tlatrace::obj(t), "new", st_.reached[static_cast<size_t>(k)] == 0);
        if (st_.reached[static_cast<size_t>(k)]) return;
        st_.reached[static_cast<size_t>(k)] = 1;
        ++st_.ylos_reached;
        st_.ylos_pending.push_back(static_cast<uint32_t>(k));
    }

    /// Handles slot `s` of `parent`, one of the job's own copies. A child in the tenuring extent is tenured and `s`
    /// is rewritten to name its copy; a YLOS child is reached; a child that is young elsewhere aborts the process.
    void childOfCopy(void* parent, uint64_t* s) {
        void* t = env_.target(*s);
        ECO_TLA_TRACE("tchild", "par", ::Elm::tlatrace::obj(parent), "off",
                      static_cast<int64_t>(reinterpret_cast<char*>(s) - static_cast<char*>(parent)),
                      "tgt", ::Elm::tlatrace::obj(t));
        if (t == nullptr) return;
        if (env_.inTenuring(t)) {
            *s = env_.word(tenure(t));
            ECO_TLA_TRACE("tfix", "par", ::Elm::tlatrace::obj(parent), "off",
                          static_cast<int64_t>(reinterpret_cast<char*>(s) - static_cast<char*>(parent)),
                          "val", ::Elm::tlatrace::obj(env_.target(*s)));
            return;
        }
        if (env_.ylosMaybe(t)) { reachYlos(t); return; }
        if (env_.youngElsewhere(t)) env_.abortYoungChild(parent, t);   // checked in every build
    }

    /// Prefetches `t`'s shadow entry and header. It changes no decision, so the engine stays exact.
    void prefetchTarget(void* t) {
        __builtin_prefetch(env_.shadow(t), 0, 3);
        __builtin_prefetch(t, 0, 3);
    }

    /// Scans the copy `c`, handling each of its child slots. For a list cell, the head is handled and the tail is
    /// followed as a spine run instead of being queued.
    void scanCopy(void* c) {
        uint64_t* tail = env_.consTail(c);
        if (tail == nullptr) {
            env_.forEachChildSlot(c, [&](uint64_t* s) {
                void* t = env_.target(*s);
                if (t != nullptr && env_.inTenuring(t)) prefetchTarget(t);
            });
            env_.forEachChildSlot(c, [&](uint64_t* s) { childOfCopy(c, s); });
            return;
        }
        if (uint64_t* h = env_.consHead(c)) {
            void* t = env_.target(*h);
            if (t != nullptr && env_.inTenuring(t)) prefetchTarget(t);
        }
        {
            void* t = env_.target(*tail);
            if (t != nullptr && env_.inTenuring(t)) prefetchTarget(t);
        }
        if (uint64_t* h = env_.consHead(c)) childOfCopy(c, h);
        spineRun(c);
    }

    /// Tenures the list spine after the copied cell `first_parent`, cell by cell, rewriting each tail slot, until
    /// it reaches a cell that is not in the tenuring extent, already copied, or not a list cell. Then handles the
    /// heads of the cells copied. A run stops after `kSpineRun` cells; the last cell is then queued and its own scan
    /// continues the spine and handles its head. Cells copied here are never queued otherwise, so a long list
    /// does not fill the queue.
    void spineRun(void* first_parent) {
        void* prev = first_parent;
        void* run[kSpineRun];
        size_t k = 0;
        bool truncated = false;
        for (;;) {
            uint64_t* tail = env_.consTail(prev);
            void* t = env_.target(*tail);
            if (t == nullptr) break;
            if (!env_.inTenuring(t)) { childOfCopy(prev, tail); break; }
            if (char* d = lookup(env_.shadow(t), env_.gen())) { *tail = env_.word(d); break; }
            if (env_.consTail(t) == nullptr) { childOfCopy(prev, tail); break; }   // not a list cell
            if (k == kSpineRun) {
                st_.stack.push_back(prev);
                truncated = true;
                break;
            }
            char* d = tenure(t, /*push=*/false);
            *tail = env_.word(d);
            run[k++] = d;
            prev = d;
        }
        if (k > 0) ++st_.spine_runs;
        const size_t m = truncated ? k - 1 : k;   // a queued last cell handles its own head
        for (size_t i = 0; i < m; ++i) {
            if (uint64_t* h = env_.consHead(run[i])) childOfCopy(run[i], h);
        }
    }

    /// Scans the reached YLOS object at index `k` of the snapshot: its children in the tenuring extent are tenured
    /// and its YLOS children are reached. The object itself is not written; the merge rewrites its slots.
    void scanYlos(uint32_t k) {
        void* y = const_cast<char*>(st_.ylos[k].obj);
        env_.forEachChildSlot(y, [&](uint64_t* s) {
            void* t = env_.target(*s);
            ECO_TLA_TRACE("tchild", "par", ::Elm::tlatrace::obj(y), "off",
                          static_cast<int64_t>(reinterpret_cast<char*>(s) - static_cast<char*>(y)),
                          "tgt", ::Elm::tlatrace::obj(t));
            if (t == nullptr) return;
            if (env_.inTenuring(t)) { (void)tenure(t); return; }
            if (env_.ylosMaybe(t)) reachYlos(t);
        });
    }
};

template <class Env>
void SerialEngine<Env>::sleepUs(uint64_t us) {
    std::this_thread::sleep_for(std::chrono::microseconds(us));
}

/// Runs the job in `st` over `env` until it is done or `stop` is set, as `SerialEngine::run` does.
template <class Env>
inline DrainResult tenureDrainSerial(SerialState& st, Env& env, const std::atomic<bool>* stop) {
    SerialEngine<Env> e(st, env);
    return e.run(stop);
}

/// Finishes the mark and sweep phases of the job in `st`, as `SerialEngine::runMarkPhases` does.
template <class Env>
inline void finishMarkPhases(SerialState& st, Env& env) {
    SerialEngine<Env> e(st, env);
    e.runMarkPhases();
}

/// Finishes sweeping the ageing extent the job in `st` is partway through, as `SerialEngine::finishSweepExtent` does.
template <class Env>
inline void finishSweepExtent(SerialState& st, Env& env) {
    SerialEngine<Env> e(st, env);
    e.finishSweepExtent();
}

}  // namespace Elm::tenurework
