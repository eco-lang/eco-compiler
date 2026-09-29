#pragma once

// threaded-gc-07 (plans/threaded-gc-07-concurrent-tenuring.md P§3.10-P§3.11;
// HEAP_070): the std-only core of the tenure job.
//
//   - the SHADOW ENTRY: one 64-bit word per granule of a survivor extent, the
//     off-header forwarding of that extent's objects:
//       bits 0..2   state (0 unvisited, 1 BUSY, 2 FWD)
//       bits 3..42  the destination's absolute address (0 unless FWD)
//       bits 43..63 gen, the extent's generation at its hand-over
//     An entry whose gen differs from the extent's current gen reads as
//     unvisited, so retired entries never need clearing (trap 11: the claim
//     CAS compares against the OBSERVED stale word, never against zero);
//   - claim (CAS to BUSY), publish (release store of FWD), lookup;
//   - tenureDrainSerial: the EXACT, resumable engine. All state lives in the
//     job; `stop` is honoured only between items (one object copy, or one
//     spine run with its heads pass), and a restart continues the same item
//     sequence, so a job stopped anywhere and finished on another thread
//     produces the same copies at the same addresses (P§3.18).
//   - threaded-gc-07b (tenure age k > 1): two phases run first. MARK traces,
//     read-only, the objects of the ageing extents (and ageing-generation YLOS)
//     reachable from the pause's age sources; each marked object's slot into
//     the tenuring extent joins `heal` (a start and a heal slot). SWEEP scans
//     each ageing extent's mark bitmap in address order and lists every GAP
//     between marked objects (dead objects and fillers) in `zap`; the merge
//     writes one filler header per gap. Only marked objects' headers are read.
//
// Deliberately standalone (includes nothing from the allocator) so the TSan
// harness (test/gc-helper-tsan/tenure_harness.cpp) runs the same engine over
// a synthetic heap. The heap side supplies an Env (NurseryTenure.cpp).
//
// The collector writes ONLY: shadow entries of the extent it tenures, cells
// of its own grant (through Env::allocate / Env::copy), and the job's private
// state (rule 4, FORBID_HEAP_004). It never writes a slot of a published
// object: slots of its own fresh copies are the only slots it stores.

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

#include "TlaTrace.hpp"   // compiled-out hooks (trace builds only: M5's trace, test/tla/)

namespace Elm::tenurework {

// ---------------------------------------------------------------------------
// Shadow entries (P§3.10)
// ---------------------------------------------------------------------------
constexpr uint64_t kStateMask  = 7;
constexpr uint64_t kStateBusy  = 1;
constexpr uint64_t kStateFwd   = 2;
constexpr unsigned kGenShift   = 43;
constexpr uint32_t kGenMask    = (1u << 21) - 1;
constexpr uint64_t kAddrMask   = ((uint64_t{1} << kGenShift) - 1) & ~kStateMask;

inline uint64_t make(const void* dst, uint64_t state, uint32_t gen) {
    return (reinterpret_cast<uintptr_t>(dst) & kAddrMask) | state |
           (static_cast<uint64_t>(gen & kGenMask) << kGenShift);
}
inline uint32_t genOf(uint64_t e) { return static_cast<uint32_t>(e >> kGenShift); }
inline uint64_t stateOf(uint64_t e) { return e & kStateMask; }
inline char* addrOf(uint64_t e) { return reinterpret_cast<char*>(static_cast<uintptr_t>(e & kAddrMask)); }

inline std::atomic_ref<uint64_t> ref(uint64_t* w) { return std::atomic_ref<uint64_t>(*w); }

// The destination when `e` is FWD in generation `gen`, else nullptr.
inline char* fwdOf(uint64_t e, uint32_t gen) {
    return (genOf(e) == (gen & kGenMask) && stateOf(e) == kStateFwd) ? addrOf(e) : nullptr;
}
// Acquire load + fwdOf (the pause after a join, the job itself, the STW major).
inline char* lookup(uint64_t* w, uint32_t gen) {
    return fwdOf(ref(w).load(std::memory_order_acquire), gen);
}
// CAS `observed` -> BUSY. False when another claimant won (observed then
// holds its word). `observed` must be what the caller loaded: a stale entry
// from the extent's previous use is claimed by comparing against IT.
inline bool claim(uint64_t* w, uint64_t& observed, uint32_t gen) {
    return ref(w).compare_exchange_strong(observed, make(nullptr, kStateBusy, gen),
                                          std::memory_order_acq_rel, std::memory_order_acquire);
}
// Release: orders the copy before the address.
inline void publish(uint64_t* w, const void* dst, uint32_t gen) {
    ref(w).store(make(dst, kStateFwd, gen), std::memory_order_release);
}
// Waits out BUSY (parallel engine only). `pause(round)` is the backoff.
template <class Pause>
inline uint64_t waitPublished(uint64_t* w, uint32_t gen, Pause&& pause) {
    for (unsigned round = 0;; ++round) {
        const uint64_t e = ref(w).load(std::memory_order_acquire);
        if (!(genOf(e) == (gen & kGenMask) && stateOf(e) == kStateBusy)) return e;
        pause(round);
    }
}

// ---------------------------------------------------------------------------
// The job's serial engine state (P§3.11). Owned by the job from the hand-over
// pause to the merge; published by the gang's launch / join mutexes.
// ---------------------------------------------------------------------------
struct YlosEntry {
    const char* obj;
    const char* end;
};

// A dead range of an ageing extent (threaded-gc-07b): the merge writes one
// Tag_Free filler of `bytes` at `p`.
struct Span {
    char* p;
    size_t bytes;
};

struct SerialState {
    // Inputs, fixed in the hand-over pause.
    std::vector<void*>     starts;      // S_m: Hand targets (tenuring objects)
    std::vector<uint64_t*> heal;        // H_m: slots whose *value* is a tenuring object (read-only here)
    std::vector<YlosEntry> ylos;        // sorted by obj: the generation's YLOS snapshot
    std::vector<uint8_t>   reached;     // per ylos entry: reached (by the pause or the job)
    // Resumable progress.
    size_t next_start = 0;
    size_t next_heal = 0;
    std::vector<void*>  stack;          // copies to scan (LIFO; FIFO from stack_head when fifo)
    size_t stack_head = 0;
    bool fifo = false;                  // breadth-first promotion order (a retention lever)
    std::vector<uint32_t> ylos_pending; // snapshot indices to scan (FIFO by index order of reach)
    size_t ylos_next = 0;
    // threaded-gc-07b: the mark / sweep phases over the ageing extents.
    std::vector<void*>     age_starts;     // pause sources: ageing objects / ageing YLOS
    std::vector<YlosEntry> age_ylos;       // sorted: the ageing generations' YLOS snapshot
    std::vector<uint8_t>   age_ylos_marked;
    unsigned n_age = 0;                    // ageing extents to sweep
    size_t next_age_start = 0;
    std::vector<void*> age_stack;
    unsigned sweep_x = 0;                  // extent being swept
    size_t sweep_w = 0;                    // next bitmap word of it
    char* sweep_gap = nullptr;             // start of the current dead gap (nullptr: extent not begun)
    std::vector<Span> zap;                 // dead gaps (the merge fills them)
    uint64_t age_marked = 0, age_marked_bytes = 0, age_heal = 0, zapped = 0, zapped_bytes = 0;
    // Counters (object class: identical in every mode).
    uint64_t tenured = 0, tenured_bytes = 0, items = 0, spine_runs = 0, ylos_reached = 0;
    // Test hooks (written only while no job runs).
    uint64_t test_skip_start_every = 0;   // negative control: skip every k-th start entry
    uint64_t test_stop_after = 0;         // determinism probe: stop after this many items (0 = never)
    uint64_t test_sleep_us_per_item = 0;  // a slowed collector (late-job tests)

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
    bool markPhasesDone() const {
        return age_stack.empty() && next_age_start >= age_starts.size() && sweep_x >= n_age;
    }
    bool done() const {
        return markPhasesDone() && stack.size() == stack_head && next_start >= starts.size() &&
               next_heal >= heal.size() && ylos_next >= ylos_pending.size();
    }
};

enum class DrainResult { Done, Stopped };

constexpr size_t kSpineRun = 512;   // == MINOR_SPINE_RUN (phase 6's bounded spine run)

// Index of the snapshot entry whose object starts at `p`, or -1. The snapshot
// is sorted by start address; objects never overlap.
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
// The exact engine. Env supplies (all over job-private or immutable data):
//   void*     target(uint64_t word)          heap object address of a slot word, or nullptr
//   uint64_t  word(const void* obj)           the slot word naming obj
//   bool      inTenuring(const void* p)       p in [base, surv_top) of the tenuring extent
//   bool      ylosMaybe(const void* p)        cheap bounding-box filter for the snapshot
//   bool      youngElsewhere(const void* p)   in this heap's nursery block, outside the range
//   uint64_t* shadow(const void* obj)         the object's shadow word
//   uint32_t  gen()                           the job's generation
//   size_t    sizeOf(const void* obj)         object bytes (from its header)
//   void*     copy(const void* obj, size_t)   allocate from the grant, copy, fix the header,
//                                             log side effects (large bodies); returns dst
//   template<F> void forEachChildSlot(void* obj, F f)   f(uint64_t* slot) per boxed slot
//   uint64_t* consTail(void* obj)             tail slot if obj is a Cons, else nullptr
//   uint64_t* consHead(void* obj)             boxed head slot of a Cons, else nullptr
//   [[noreturn]] void abortYoungChild(const void* parent, const void* child)
// and, for the ageing phases (threaded-gc-07b):
//   int       ageIndex(const void* p)          ageing extent of p's survivor part, or -1
//   bool      markAge(int i, const void* obj)  test-and-set obj's mark bit; true if newly set
//   bool      isMarkedAge(int i, const void* obj)
//   char*     ageBase(unsigned i), ageTop(unsigned i)
//   bool      ageYlosMaybe(const void* p)     cheap bounding-box filter for the age snapshot
//   const uint64_t* ageBits(unsigned i)       extent i's mark bitmap (bit per 8-byte granule)
// ---------------------------------------------------------------------------
template <class Env>
class SerialEngine {
public:
    SerialEngine(SerialState& st, Env& env) : st_(st), env_(env) {}

    DrainResult run(const std::atomic<bool>* stop) {
        for (;;) {
            if (stop != nullptr && stop->load(std::memory_order_relaxed)) {
                // M5 trace: the stop request (keyed by the flag and the job's gen) is before this.
                ECO_TLA_TRACE("tstop", "get", ::Elm::tlatrace::key("S", stop, static_cast<int64_t>(env_.gen())));
                return DrainResult::Stopped;
            }
            if (st_.test_stop_after != 0 && st_.items >= st_.test_stop_after) {
                st_.test_stop_after = 0;          // a one-shot forced stop
                return DrainResult::Stopped;
            }
            if (!step()) {
                ECO_TLA_TRACE("tend");            // M5 trace: no item left
                return DrainResult::Done;
            }
            ++st_.items;
            if (st_.test_sleep_us_per_item != 0) sleepUs(st_.test_sleep_us_per_item);
        }
    }

    // threaded-gc-07b: only the mark and sweep phases (the parallel engines
    // take the tenure phase after them). Never stops.
    void runMarkPhases() {
        while (!st_.markPhasesDone()) {
            markOrSweepStep();
            ++st_.items;
        }
    }
    // Finishes the extent a stopped sweep is inside (a parallel sweep starts
    // only at an extent boundary).
    void finishSweepExtent() {
        while (st_.sweep_x < st_.n_age && st_.sweep_gap != nullptr) {
            sweepStep();
            ++st_.items;
        }
    }

    // Tenures `obj` (in the tenuring range) if it is not yet, returning its
    // copy. Pushes a fresh copy for scanning when `push`.
    char* tenure(void* obj, bool push = true) {
        uint64_t* w = env_.shadow(obj);
        const uint32_t g = env_.gen();
        // The exact engine is the only writer of this shadow while it runs
        // (the parallel engine starts only after a stop and a join), so it
        // needs no claim: FWD is published once, after the copy. Readers
        // (the pause after the join) synchronise through the join.
        uint64_t e = ref(w).load(std::memory_order_relaxed);
        ECO_TLA_TRACE("tload", "obj", ::Elm::tlatrace::obj(obj), "st", stateOf(e), "g", genOf(e),
                      "dst", ::Elm::tlatrace::obj(fwdOf(e, g)));   // M5 trace: the entry observed
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
        publish(w, dst, g);
        ECO_TLA_TRACE("tpub", "obj", ::Elm::tlatrace::obj(obj), "dst", ::Elm::tlatrace::obj(dst));
        if (push) st_.stack.push_back(dst);
        return dst;
    }

private:
    SerialState& st_;
    Env& env_;

    static void sleepUs(uint64_t us);

    // One item. False when there is nothing left.
    bool step() {
        if (!st_.markPhasesDone()) {
            markOrSweepStep();
            return true;
        }
        if (st_.stack.size() != st_.stack_head) {
            void* c;
            if (st_.fifo) {
                c = st_.stack[st_.stack_head++];
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
            scanCopy(c);
            return true;
        }
        if (st_.next_start < st_.starts.size()) {
            const size_t i = st_.next_start++;
            ECO_TLA_TRACE("titem", "k", "start", "idx", i, "tgt", ::Elm::tlatrace::obj(st_.starts[i]));
            if (i + 8 < st_.starts.size()) prefetchTarget(st_.starts[i + 8]);
            if (st_.test_skip_start_every != 0 && (i + 1) % st_.test_skip_start_every == 0) return true;
            tenure(st_.starts[i]);
            return true;
        }
        if (st_.next_heal < st_.heal.size()) {
            if (st_.next_heal + 16 < st_.heal.size()) __builtin_prefetch(st_.heal[st_.next_heal + 16], 0, 3);
            const uint64_t v = *st_.heal[st_.next_heal++];   // immutable under P1
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

    // ---- threaded-gc-07b: the ageing phases ----
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

    // A reference `t` (from the pause when parent == nullptr, else from the
    // marked object `parent`'s slot `s`).
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
            st_.heal.push_back(s);   // a tenure start whose slot the merge heals
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
        if (env_.youngElsewhere(t)) env_.abortYoungChild(parent, t);   // TV6 (every build)
    }

    void scanAge(void* o) {
        env_.forEachChildSlot(o, [&](uint64_t* s) {
            void* t = env_.target(*s);
            if (t != nullptr) markTarget(t, o, s);
        });
    }

    void emitGap(char* p, size_t bytes) {
        st_.zap.push_back(Span{p, bytes});
        ++st_.zapped;
        st_.zapped_bytes += bytes;
    }

    // One bitmap word of the address-order scan over an ageing survivor part:
    // the gap before each marked object becomes a zap span.
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

    void reachYlos(const void* t) {
        const long k = ylosFind(st_.ylos, t);
        if (k < 0) return;   // a YLOS object outside the snapshot: TV6 at the merge (validate)
        ECO_TLA_TRACE("treach", "obj", ::Elm::tlatrace::obj(t), "new", st_.reached[static_cast<size_t>(k)] == 0);
        if (st_.reached[static_cast<size_t>(k)]) return;
        st_.reached[static_cast<size_t>(k)] = 1;
        ++st_.ylos_reached;
        st_.ylos_pending.push_back(static_cast<uint32_t>(k));
    }

    // A child slot of one of the job's own copies: the only slots it writes.
    void childOfCopy(void* parent, uint64_t* s) {
        void* t = env_.target(*s);
        ECO_TLA_TRACE("tchild", "par", ::Elm::tlatrace::obj(parent), "off",
                      static_cast<int64_t>(reinterpret_cast<char*>(s) - static_cast<char*>(parent)),
                      "tgt", ::Elm::tlatrace::obj(t));   // M5 trace: one slot of a copy's scan
        if (t == nullptr) return;
        if (env_.inTenuring(t)) {
            *s = env_.word(tenure(t));
            ECO_TLA_TRACE("tfix", "par", ::Elm::tlatrace::obj(parent), "off",
                          static_cast<int64_t>(reinterpret_cast<char*>(s) - static_cast<char*>(parent)),
                          "val", ::Elm::tlatrace::obj(env_.target(*s)));
            return;
        }
        if (env_.ylosMaybe(t)) { reachYlos(t); return; }
        if (env_.youngElsewhere(t)) env_.abortYoungChild(parent, t);   // TV6 (every build)
    }

    // Software prefetch (measured: 81 % of tenure() was the shadow-word miss).
    // Order-neutral: it changes no decision, so the engine stays exact.
    void prefetchTarget(void* t) {
        __builtin_prefetch(env_.shadow(t), 0, 3);
        __builtin_prefetch(t, 0, 3);
    }

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

    // P§3.11 spines: the tail spine is tenured cell by cell without pushing,
    // then one heads pass over the run's copies (phase 6's spineRun shape).
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
            if (env_.consTail(t) == nullptr) { childOfCopy(prev, tail); break; }   // not a Cons
            if (k == kSpineRun) {
                st_.stack.push_back(prev);   // bounded run: its scan continues the spine
                truncated = true;
                break;
            }
            char* d = tenure(t, /*push=*/false);
            *tail = env_.word(d);
            run[k++] = d;
            prev = d;
        }
        if (k > 0) ++st_.spine_runs;
        const size_t m = truncated ? k - 1 : k;   // a pushed last cell does its own head
        for (size_t i = 0; i < m; ++i) {
            if (uint64_t* h = env_.consHead(run[i])) childOfCopy(run[i], h);
        }
    }

    // Read-only: a generation YLOS object is never written by the job; its
    // tenuring children are tenured, and the merge rewrites the slots.
    void scanYlos(uint32_t k) {
        void* y = const_cast<char*>(st_.ylos[k].obj);
        env_.forEachChildSlot(y, [&](uint64_t* s) {
            void* t = env_.target(*s);
            ECO_TLA_TRACE("tchild", "par", ::Elm::tlatrace::obj(y), "off",
                          static_cast<int64_t>(reinterpret_cast<char*>(s) - static_cast<char*>(y)),
                          "tgt", ::Elm::tlatrace::obj(t));   // M5 trace: one slot of a YLOS scan
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

template <class Env>
inline DrainResult tenureDrainSerial(SerialState& st, Env& env, const std::atomic<bool>* stop) {
    SerialEngine<Env> e(st, env);
    return e.run(stop);
}

// threaded-gc-07b: finish only the mark and sweep phases (before a parallel
// engine takes the tenure phase).
template <class Env>
inline void finishMarkPhases(SerialState& st, Env& env) {
    SerialEngine<Env> e(st, env);
    e.runMarkPhases();
}

template <class Env>
inline void finishSweepExtent(SerialState& st, Env& env) {
    SerialEngine<Env> e(st, env);
    e.finishSweepExtent();
}

}  // namespace Elm::tenurework
