#pragma once

// The heap-independent core of a parallel marker: how grey work is encoded, shared and metered, and how a group of
// marking threads agrees that it has finished. It knows nothing of the heap, so the same loop can run against the
// real heap and against a test harness. Apart from the trace hooks of TlaTrace.hpp it uses only the standard library
// and, outside Windows, two POSIX headers.
//
// Marking finds every object reachable from the roots. An object found but not yet scanned is grey, and is held as a
// mark entry: one 64-bit word naming either an object or one chunk of an array (`objEntry`, `chunkEntry`). Scanning
// an entry may produce more entries. Several threads mark at once; each is a participant with a slot number. A
// participant keeps its grey entries in a `WorkStealingDeque` of its own, pushing and taking at one end, while any
// other participant whose own work has run out may steal from the other end. The deque is the Chase-Lev algorithm
// with the memory orders of its published weak-memory version; do not weaken them, even where x86 would allow
// weaker ones.
//
// The rest of the file is `runMarkerLoop`, one participant's run, and it rests on two rules.
//
// Work is metered by tickets. A run is governed by a `SliceControl`, whose budget is the number of entries the
// Members may scan between them. A participant needs a ticket to take or steal an entry, and each entry scanned uses
// one, so the Members scan at most the budget and each Assist at most its own pool. (The one exception is the
// `steal_without_ticket` test switch.)
// Tickets are claimed from a pool `kTicketBatch` at a time and held locally; unused ones go back to the pool. A
// Member draws on the control's budget; an Assist (see `Role`) brings a pool of its own.
//
// A run ends when no participant can find work or no budget is left. A Member that finds nothing to take or steal, or
// has no ticket, goes idle, which counts it out of the control's active count, and then watches: if budget and work
// appear it reactivates; if it sees every participant idle and, on looking again, no budget or no work, it decides the
// run is done. That decision is a CAS from the exact state word in which it saw the active count at zero, and every
// reactivation changes that word, so a participant reactivating in between makes the decision fail. For that decision
// to be right, every participant must make its work visible and return its tickets before it goes idle; `runMarkerLoop`
// does both.
//
// Entries a participant takes or steals wait in a ring of `kRingDepth` entries, prefetched when they enter it and
// scanned oldest first, so that each one's memory has time to arrive.
//
// The heap side is supplied by an environment, a template argument `Env` that must provide:
//   static constexpr bool kParallel;      false: a single participant, with no stealing and no termination protocol;
//   MarkerCounters& counters(unsigned i); participant i's counters, kept by the Env across the run;
//   uint64_t takeOwn(unsigned self);      an entry from self's own grey work, or kEmpty;
//   uint64_t stealFrom(unsigned victim);  an entry stolen from victim, kEmpty, or kAbort for a lost race;
//   bool anyWork();                       (parallel) whether any participant may have work, including private work;
//   void prefetch(uint64_t e);            a hint to start loading what e names;
//   void scan(unsigned self, uint64_t e); scans e, adding any new grey entries to self's work;
//   void publishAll(unsigned self);       (parallel) moves any of self's work that only self can reach, such as a
//                                         private stack, into its deque.
// `counters`, `takeOwn`, `scan` and `publishAll` are called on the thread of the participant whose slot they are
// given; `stealFrom` is called on the thief's thread, so it runs concurrently with the victim's own calls.
//
// In a trace build (see TlaTrace.hpp) the loop records events for checking against the TLA+ model of this protocol.

#include <atomic>
#include <cassert>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <thread>
#include <vector>
#if !defined(_WIN32)
#include <sched.h>
#include <time.h>
#endif

#include "TlaTrace.hpp"   // trace hooks; they compile to nothing outside trace builds

namespace Elm::markwork {

#if ECO_TLA_TRACE_ENABLED
// Trace builds only: what the hooks' fields need to name the locations and the participant of an event.

/// Returns a fresh serial number, from 1 up, for a `SliceControl`; trace events name its state word and its budget
/// by it. Safe to call from any thread.
inline int64_t tlaNextCtl() {
    static std::atomic<int64_t> n{0};
    return n.fetch_add(1, std::memory_order_relaxed) + 1;
}
/// The run on one thread, as trace events name it: its slot, its control's serial (`tlaNextCtl`), and whether its
/// ticket pool is the control's budget (`shared`) rather than an assist's own pool. -1 means no run yet.
struct TlaRun { int64_t slot = -1; int64_t ctl = -1; bool shared = false; };
/// The calling thread's run, set when `runMarkerLoop` starts and left in place after it returns.
inline thread_local TlaRun tla_run;
/// Records ticket-pool event `ev`, which changed the pool from `o` to `nw`, with the further key/value fields `...`.
/// A control's budget is one location of the trace, so its events carry the "rmw" ordering fields that chain them by
/// value; an assist's pool is not chained. Expands to a statement. It reads `tla_run`, so it must be expanded on the
/// thread of the run it describes. A macro so that, like `ECO_TLA_TRACE`, it vanishes with its arguments outside
/// trace builds.
#define ECO_MW_TRACE_POOL(ev, o, nw, ...)                                                    \
    do {                                                                                     \
        if (::Elm::markwork::tla_run.shared)                                                 \
            ECO_TLA_TRACE(ev, "rmw", ::Elm::tlatrace::key("B", ::Elm::markwork::tla_run.ctl),  \
                          "old", (o), "new", (nw), "pool", "budget", __VA_ARGS__);           \
        else                                                                                 \
            ECO_TLA_TRACE(ev, "old", (o), "new", (nw), "pool", "assist", __VA_ARGS__);       \
    } while (0)
#else
/// Records nothing outside trace builds; its arguments are not evaluated.
#define ECO_MW_TRACE_POOL(...) ((void)0)
#endif

// ---------------------------------------------------------------------------
// The mark entry
// ---------------------------------------------------------------------------
//   bit 63     : 0 = object entry, 1 = chunk entry
//   bits 0..39 : the address >> 3, so addresses must be 8-byte aligned and below 2^43
//   bits 40..62: the field: for an object entry, its block id + 1 (0 = unknown); for a chunk entry, the chunk index

/// The bit that makes an entry a chunk entry rather than an object entry.
constexpr uint64_t kChunkBit   = 1ull << 63;
/// The mask of an entry's address field, which holds the address shifted right by 3.
constexpr uint64_t kAddrMask   = (1ull << 40) - 1;
/// The largest value the 23-bit field of an entry can hold.
constexpr uint32_t kFieldMax   = (1u << 23) - 1;
/// The value that means "no entry". It is the encoding of address 0, which is never an object.
constexpr uint64_t kEmpty      = 0;
/// The value a steal returns when another thread won the race for the entry it read. Nothing rejects it as an
/// entry: it is also the chunk entry for chunk `kFieldMax` of an array at address 2^43 - 8.
constexpr uint64_t kAbort      = ~0ull;

/// Returns the object entry for the object at `p`, with `id_plus1` (its block id + 1, or 0 for unknown) in its
/// field. An `id_plus1` above `kFieldMax` is stored as 0. `p` must be 8-byte aligned and below 2^43; this is
/// asserted only in builds with assertions.
inline uint64_t objEntry(const void* p, uint32_t id_plus1) {
    const uint64_t a = reinterpret_cast<uintptr_t>(p);
    assert((a & 7) == 0 && (a >> 43) == 0 && "mark entry: address out of range");
    const uint64_t f = (id_plus1 <= kFieldMax) ? id_plus1 : 0;
    return (a >> 3) | (f << 40);
}
/// Returns the chunk entry for chunk number `chunk` of the array at `arr`. `arr` must be 8-byte aligned and below
/// 2^43, and `chunk` at most `kFieldMax`. This is asserted only in builds with assertions; otherwise a larger `chunk`
/// loses its high bits.
inline uint64_t chunkEntry(const void* arr, uint32_t chunk) {
    const uint64_t a = reinterpret_cast<uintptr_t>(arr);
    assert((a & 7) == 0 && (a >> 43) == 0 && chunk <= kFieldMax);
    return kChunkBit | (a >> 3) | (static_cast<uint64_t>(chunk) << 40);
}
/// Returns whether `e` is a chunk entry.
inline bool isChunk(uint64_t e) { return (e & kChunkBit) != 0; }
/// Returns the address `e` names: the object, or the array a chunk belongs to.
inline void* entryAddr(uint64_t e) {
    return reinterpret_cast<void*>(static_cast<uintptr_t>((e & kAddrMask) << 3));
}
/// Returns the field of `e`: an object entry's block id + 1 (0 for unknown), or a chunk entry's chunk number.
inline uint32_t entryField(uint64_t e) { return static_cast<uint32_t>((e >> 40) & kFieldMax); }

// ---------------------------------------------------------------------------
// WorkStealingDeque
// ---------------------------------------------------------------------------

/// A double-ended queue of mark entries with one owner and any number of thieves.
///
/// The owner pushes and takes at the bottom, last in first out; any thread may steal from the top, oldest first. Each
/// entry pushed is returned by at most one `take` or one successful `steal`: when the owner and thieves contend for the
/// same entry, a CAS on the top index decides, and the loser gets `kEmpty` (owner) or `kAbort` (thief).
///
/// The buffer doubles when full and never shrinks. A thief may still be reading an outgrown buffer, so the deque
/// keeps it until `retireOldArrays` or `reset` frees it, which may be called only while no other thread can access
/// the deque. The destructor frees every buffer. A deque cannot be copied or moved.
class WorkStealingDeque {
public:
    /// Creates an empty deque whose first buffer holds 2^`log_initial` entries.
    explicit WorkStealingDeque(int64_t log_initial = 14) {
        array_.store(Array::make(log_initial), std::memory_order_relaxed);
    }
    ~WorkStealingDeque() {
        retireOldArrays();
        Array::destroy(array_.load(std::memory_order_relaxed));
    }
    WorkStealingDeque(const WorkStealingDeque&) = delete;
    WorkStealingDeque& operator=(const WorkStealingDeque&) = delete;

    /// Pushes `e` at the bottom, growing the buffer if it is full. Owner only. A thief that steals `e` also sees
    /// everything the owner wrote before pushing it.
    void push(uint64_t e) {
        const int64_t b = bottom_.load(std::memory_order_relaxed);
        const int64_t t = top_.load(std::memory_order_acquire);
        Array* a = array_.load(std::memory_order_relaxed);
        if (b - t > a->mask) {
            a = grow(a, b, t);
        }
        // The element store is a release, paired with the acquire of a thief's element load. The release fence
        // below already orders the owner's earlier writes before it, but ThreadSanitizer does not model
        // stand-alone fences, so the store carries the order as well. Keep both.
        a->buf[b & a->mask].store(e, std::memory_order_release);
        std::atomic_thread_fence(std::memory_order_release);
        bottom_.store(b + 1, std::memory_order_relaxed);
    }

    /// Takes the most recently pushed entry. Owner only. Returns `kEmpty` when the deque is empty, or when a thief
    /// won the race for its last entry.
    uint64_t take() {
        const int64_t b = bottom_.load(std::memory_order_relaxed) - 1;
        Array* a = array_.load(std::memory_order_relaxed);
        bottom_.store(b, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_seq_cst);
        int64_t t = top_.load(std::memory_order_relaxed);
        uint64_t e;
        if (t <= b) {
            e = a->buf[b & a->mask].load(std::memory_order_relaxed);
            if (t == b) {
                if (!top_.compare_exchange_strong(t, t + 1, std::memory_order_seq_cst,
                                                  std::memory_order_relaxed)) {
                    e = kEmpty;
                }
                bottom_.store(b + 1, std::memory_order_relaxed);
            }
        } else {
            e = kEmpty;
            bottom_.store(b + 1, std::memory_order_relaxed);
        }
        return e;
    }

    /// Steals the oldest entry. Any thread may call it. Returns `kEmpty` when the deque looked empty, and `kAbort`
    /// when another take or steal won the race for the entry; the deque may still hold others.
    uint64_t steal() {
        int64_t t = top_.load(std::memory_order_acquire);
        std::atomic_thread_fence(std::memory_order_seq_cst);
        const int64_t b = bottom_.load(std::memory_order_acquire);
        if (t < b) {
            Array* a = array_.load(std::memory_order_acquire);
            const uint64_t e = a->buf[t & a->mask].load(std::memory_order_acquire);
            if (!top_.compare_exchange_strong(t, t + 1, std::memory_order_seq_cst,
                                              std::memory_order_relaxed)) {
                return kAbort;
            }
            return e;
        }
        return kEmpty;
    }

    /// Returns whether the deque looked empty. The two indices are read with relaxed loads, so while other threads
    /// use the deque the answer may be stale: it is a hint, not a fact a decision can rest on alone.
    bool emptyApprox() const {
        return bottom_.load(std::memory_order_relaxed) <= top_.load(std::memory_order_relaxed);
    }
    /// Returns how many entries the deque looked to hold, as stale as `emptyApprox`.
    size_t sizeApprox() const {
        const int64_t d = bottom_.load(std::memory_order_relaxed) -
                          top_.load(std::memory_order_relaxed);
        return d > 0 ? static_cast<size_t>(d) : 0;
    }
    /// Returns how many times the buffer has grown since the deque was created. Owner only.
    uint64_t grows() const { return grows_; }

    /// Frees the buffers the deque has outgrown. May be called only while no other thread can access the deque.
    void retireOldArrays() {
        for (Array* a : retired_) Array::destroy(a);
        retired_.clear();
    }
    /// Frees the outgrown buffers and sets both indices back to 0, keeping the current buffer and its size. The deque
    /// must be empty, which is asserted only in builds with assertions, and no other thread may access it.
    void reset() {
        assert(emptyApprox() && "WorkStealingDeque::reset on a non-empty deque");
        retireOldArrays();
        top_.store(0, std::memory_order_relaxed);
        bottom_.store(0, std::memory_order_relaxed);
    }

private:
    /// One buffer: a power-of-two number of slots, where position i lives in slot `i & mask`. Owns `buf`; freed only
    /// by `destroy`.
    struct Array {
        int64_t mask;
        std::atomic<uint64_t>* buf;
        /// Allocates a buffer of 2^`log_size` slots, which the caller frees with `destroy`.
        static Array* make(int64_t log_size) {
            Array* a = new Array;
            const int64_t n = int64_t{1} << log_size;
            a->mask = n - 1;
            a->buf = new std::atomic<uint64_t>[static_cast<size_t>(n)];
            return a;
        }
        /// Frees `a` and its slots. `a` may be null.
        static void destroy(Array* a) {
            if (!a) return;
            delete[] a->buf;
            delete a;
        }
    };

    /// Installs and returns a buffer twice the size of `a` holding the entries at positions [`t`, `b`). `a` is kept
    /// until the outgrown buffers are freed. Owner only.
    Array* grow(Array* a, int64_t b, int64_t t) {
        int64_t log = 0;
        while ((int64_t{1} << log) <= a->mask) ++log;
        Array* na = Array::make(log + 1);
        for (int64_t i = t; i < b; ++i) {
            na->buf[i & na->mask].store(a->buf[i & a->mask].load(std::memory_order_relaxed),
                                        std::memory_order_release);
        }
        retired_.push_back(a);        // a thief may still read it
        array_.store(na, std::memory_order_release);
        ++grows_;
        return na;
    }

    // Shared with thieves, each on its own cache line. top_ is the position of the oldest entry, bottom_ one past
    // the newest; between operations the deque holds bottom_ - top_ entries.
    alignas(64) std::atomic<int64_t> top_{0};
    alignas(64) std::atomic<int64_t> bottom_{0};
    alignas(64) std::atomic<Array*> array_{nullptr};
    // Owner only.
    std::vector<Array*> retired_;     // outgrown buffers a thief may still be reading
    uint64_t grows_ = 0;
};

// ---------------------------------------------------------------------------
// Slice control, tickets and the marker loop
// ---------------------------------------------------------------------------

/// A budget that stands for "no limit": a run given it ends when no work is left, or on a stop, long before its
/// tickets run out.
constexpr int64_t kDrainBudget = INT64_MAX / 4;
/// The number of tickets a participant claims from a pool in one CAS (fewer if the pool holds fewer), so that the
/// shared counter is touched once per batch rather than once per entry.
constexpr int64_t kTicketBatch = 256;
/// The number of entries a participant's ring holds: entries taken but not yet scanned, prefetched while they wait.
/// It must be a power of two. It has the same value as `OldGenSpace::MARK_FIFO_DEPTH`, and nothing ties the two.
constexpr size_t  kRingDepth   = 16;
static_assert((kRingDepth & (kRingDepth - 1)) == 0, "ring depth must be a power of two");

/// The shared state of one marking run: its ticket budget, its termination state, and the requests its participants
/// watch for.
///
/// Every participant of the run refers to the same control, which must outlive every `runMarkerLoop` call given it.
/// The run is done once the done bit of `state` is set, and that bit is never cleared.
struct SliceControl {
    // The termination state is one word, so that a participant can decide "done" by a CAS from the exact word in
    // which it saw no participant active. Bits 0..31 count the active participants, bits 32..62 are the reactivation
    // epoch, which every reactivation advances, and bit 63 is the done bit. A participant that reactivates between
    // the decider's look at the word and its CAS, possibly claiming the whole remaining budget, changes the word and
    // makes the CAS fail.

    /// The mask of the active count in `state`.
    static constexpr uint64_t kActiveMask = 0xFFFFFFFFull;
    /// One step of the reactivation epoch in `state`.
    static constexpr uint64_t kEpochOne   = 1ull << 32;
    /// The done bit of `state`.
    static constexpr uint64_t kDone       = 1ull << 63;
    /// The tickets not yet claimed from the Members' pool.
    std::atomic<int64_t>  budget{0};
    std::atomic<uint64_t> state{0};
    /// A stop request. A participant that sees it scans the entries already in its ring, publishes its work, returns
    /// its tickets and leaves without setting done; the unscanned work stays in the deques for a later run.
    std::atomic<bool>     stop{false};
    /// A request to share. A participant compares it with the last value it acted on before each refill of its ring,
    /// and publishes its work when it has changed, so that a participant joining later can steal work that was
    /// private.
    std::atomic<uint32_t> share_epoch{0};
    /// The victim range: `stealAny` steals from slots 0 to n - 1. It need not be the number of participants running.
    uint32_t              n = 1;
    /// When not 0, the most microseconds a participant sleeps, at random, after every 4096th entry it scans, which
    /// varies how participants interleave.
    unsigned              jitter_us = 0;
    /// A deliberate fault for negative tests. When set, a participant steals before claiming a ticket, and an entry
    /// it then has no ticket for is scanned without being counted.
    bool                  steal_without_ticket = false;
    ECO_TLA_TRACE_ONLY(int64_t tla_ctl = tlaNextCtl();)   // trace builds: this control's serial
    /// Creates the control for a run with `b` tickets in its budget and slots 0 to `members` - 1 as its victim range.
    /// `active` is the number of participants counted active at the start, or `members` when negative; each one
    /// counted must run and go idle before the run can be decided done. A participant that joins later is not
    /// counted here. `jitter` sets `jitter_us`.
    explicit SliceControl(int64_t b, uint32_t members = 1, unsigned jitter = 0,
                          int64_t active = -1)
        : n(members), jitter_us(jitter) {
        budget.store(b, std::memory_order_relaxed);
        state.store(active < 0 ? members : static_cast<uint64_t>(active),
                    std::memory_order_relaxed);
    }
    /// Returns whether the run has been decided done.
    bool done() const { return (state.load(std::memory_order_acquire) & kDone) != 0; }
    /// Returns how many participants are counted active.
    uint32_t active() const {
        return static_cast<uint32_t>(state.load(std::memory_order_acquire) & kActiveMask);
    }
    /// Returns whether a stop has been requested. A relaxed load: it orders nothing else.
    bool stopRequested() const { return stop.load(std::memory_order_relaxed); }
    /// Counts the calling participant, which must be counted active, out of the active set. The decrement is an
    /// acquire-release RMW, so a participant that later reads `state` with acquire also sees what the caller did
    /// before it, such as publishing work and returning tickets.
    void goIdle() {
        ECO_TLA_TRACE_ONLY(const uint64_t o =) state.fetch_sub(1, std::memory_order_acq_rel);
        ECO_TLA_TRACE("mw.idle", "w", tla_run.slot, "rmw", ::Elm::tlatrace::key("S", tla_ctl),
                      "old", o, "new", o - 1, "act", (o - 1) & kActiveMask);
    }
    /// Counts the caller into the active set and advances the reactivation epoch, so that a done decision resting on
    /// an earlier state word fails. Returns false, changing nothing, if the run is already done.
    bool reactivate() {
        uint64_t s = state.load(std::memory_order_acquire);
        for (;;) {
            if (s & kDone) {
                ECO_TLA_TRACE("mw.reactDone", "w", tla_run.slot,
                              "rd", ::Elm::tlatrace::key("S", tla_ctl), "val", s);
                return false;
            }
            if (state.compare_exchange_weak(s, s + 1 + kEpochOne, std::memory_order_acq_rel,
                                            std::memory_order_acquire)) {
                ECO_TLA_TRACE("mw.react", "w", tla_run.slot, "rmw", ::Elm::tlatrace::key("S", tla_ctl),
                              "old", s, "new", s + 1 + kEpochOne, "act", (s + 1) & kActiveMask);
                return true;
            }
        }
    }
};

/// How a participant takes part in a run.
///
/// Member: draws on the control's budget and, when it finds no work, idles until there is work again or the run
/// is done or stopped.
/// Assist: draws on a pool of its own and never idles. It leaves, publishing its work and returning its tickets
/// first, when its pool is empty, it finds nothing to take or steal, or a stop is requested.
enum class Role : uint8_t { Member, Assist };

/// One participant's tickets, statistics and random state for a run. Only that participant's thread uses it while
/// the run lasts.
struct MarkerCounters {
    uint64_t tickets = 0;          ///< Tickets claimed from the pool and not yet used.
    uint64_t units = 0;            ///< Entries scanned this run.
    uint64_t steals = 0, steal_aborts = 0, steal_empty = 0;
    uint64_t idle_spins = 0, idle_yields = 0, idle_sleeps = 0;
    uint64_t rng = 0;              ///< The state of `next`'s generator.
    uint32_t share_seen = 0;       ///< The last `SliceControl::share_epoch` acted on.
    /// Zeroes the counters for a new run and seeds the generator from `member`, so that a slot draws the same
    /// sequence of random numbers in every run.
    void resetRun(unsigned member) {
        share_seen = 0;
        tickets = units = steals = steal_aborts = steal_empty = 0;
        idle_spins = idle_yields = idle_sleeps = 0;
        rng = 0x9E3779B97F4A7C15ull ^ ((static_cast<uint64_t>(member) + 1) * 0xBF58476D1CE4E5B9ull);
    }
    /// Returns the next number of an xorshift64 generator.
    uint64_t next() {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
        return rng;
    }
};

/// Claims one ticket for `w`: one it already holds if it has any, otherwise a batch of up to `kTicketBatch` taken
/// from `pool` in one CAS, of which `w` keeps the rest. Returns false when both are empty. The pool is changed with
/// relaxed atomics: a ticket carries no memory ordering.
inline bool claimTicket(MarkerCounters& w, std::atomic<int64_t>& pool) {
    if (w.tickets > 0) { --w.tickets; return true; }
    int64_t b = pool.load(std::memory_order_relaxed);
    while (b > 0) {
        const int64_t take = b < kTicketBatch ? b : kTicketBatch;
        if (pool.compare_exchange_weak(b, b - take, std::memory_order_relaxed)) {
            w.tickets = static_cast<uint64_t>(take - 1);
            ECO_MW_TRACE_POOL("mw.claim", b, b - take, "w", tla_run.slot, "took", take);
            return true;
        }
    }
    return false;
}
/// Claims one ticket for `w` as the other overload does, from `c`'s budget.
inline bool claimTicket(MarkerCounters& w, SliceControl& c) { return claimTicket(w, c.budget); }
/// Returns every ticket `w` holds to `pool`, with a relaxed add.
inline void returnTickets(MarkerCounters& w, std::atomic<int64_t>& pool) {
    if (w.tickets) {
        ECO_TLA_TRACE_ONLY(const int64_t o =)
        pool.fetch_add(static_cast<int64_t>(w.tickets), std::memory_order_relaxed);
        ECO_MW_TRACE_POOL("mw.ret", o, o + static_cast<int64_t>(w.tickets), "w", tla_run.slot,
                          "cnt", w.tickets);
        w.tickets = 0;
    }
}
/// Returns every ticket `w` holds to `c`'s budget.
inline void returnTickets(MarkerCounters& w, SliceControl& c) { returnTickets(w, c.budget); }

/// Issues the processor's spin-wait hint on x86 and AArch64, and does nothing on other architectures.
inline void cpuRelax() {
#if defined(__x86_64__) || defined(__i386__)
    __builtin_ia32_pause();
#elif defined(__aarch64__)
    asm volatile("yield");
#endif
}

/// Sleeps the calling thread for about `us` microseconds. Outside Windows `us` must be below 1,000,000: `nanosleep`
/// rejects a longer request without sleeping.
inline void sleepMicros(unsigned us) {
#if !defined(_WIN32)
    timespec ts{0, static_cast<long>(us) * 1000};
    nanosleep(&ts, nullptr);
#else
    std::this_thread::sleep_for(std::chrono::microseconds(us));
#endif
}

/// Waits once, for the `round`th time in a row that a thread found nothing to do: a short spin for rounds 0 to 63,
/// a yield of the processor for rounds 64 to 127, and a 50 µs sleep after that, so that a thread that stays idle
/// stops taking processor time from those working. Counts the kind of wait in `w`.
inline void backoff(unsigned round, MarkerCounters& w) {
    if (round < 64) {
        for (int i = 0; i < 16; ++i) cpuRelax();
        ++w.idle_spins;
    } else if (round < 128) {
        std::this_thread::yield();
        ++w.idle_yields;
    } else {
        sleepMicros(50);
        ++w.idle_sleeps;
    }
}

/// Tries to steal one entry for participant `self` from the other slots of `c`'s victim range, starting at a random
/// one. Returns the entry, or `kEmpty` when the range has no other slot, when every victim looked empty in a pass, or
/// after four passes in each of which some steal lost a race. Counts steals, lost races and empty results of a search
/// in `w`. `Env` is as the file comment describes.
template <class Env>
inline uint64_t stealAny(Env& env, unsigned self, SliceControl& c, MarkerCounters& w) {
    const unsigned n = c.n;
    if (n <= 1) {
        ECO_TLA_TRACE("mw.stealNone", "w", self);
        return kEmpty;
    }
    for (int pass = 0; pass < 4; ++pass) {
        bool aborted = false;
        const unsigned start = static_cast<unsigned>(w.next() % n);
        for (unsigned k = 0; k < n; ++k) {
            const unsigned v = (start + k) % n;
            if (v == self) continue;
            const uint64_t e = env.stealFrom(v);
            if (e == kAbort) { aborted = true; ++w.steal_aborts; continue; }
            if (e != kEmpty) {
                ++w.steals;
                ECO_TLA_TRACE("mw.steal", "w", self, "v", v, "e", e,
                              "get", ::Elm::tlatrace::key("mwe", static_cast<int64_t>(e)));
                return e;
            }
        }
        if (!aborted) break;
    }
    ++w.steal_empty;
    ECO_TLA_TRACE("mw.stealNone", "w", self);
    return kEmpty;
}

/// Waits, as an idle participant, until there may be work for it or the run ends. Returns true once it has counted
/// the caller back in with `reactivate`, having seen budget left and `Env::anyWork` true. Returns false, with the
/// caller still idle, when the run is done (seen, or decided by this call), when a stop has been requested, or when
/// the run became done before the caller could reactivate.
///
/// The caller must already have published its work, returned its tickets and gone idle. This call decides the run done
/// when it sees the active count at zero in a state word and then, reading again, no budget or no work; the decision is
/// a CAS from that word, and if it fails the wait goes on. Between looks it backs off as `backoff` does, except while
/// it sees no participant active.
template <class Env>
inline bool idleUntilWorkOrDone(Env& env, SliceControl& c, MarkerCounters& w) {
    for (unsigned round = 0;; ++round) {
        const uint64_t s = c.state.load(std::memory_order_acquire);
        if (s & SliceControl::kDone) {
            ECO_TLA_TRACE("mw.seeDone", "w", tla_run.slot, "rd", ::Elm::tlatrace::key("S", c.tla_ctl),
                          "val", s);
            return false;
        }
        if (c.stopRequested()) {                      // leave idle, without deciding done
            ECO_TLA_TRACE("mw.seeStop", "w", tla_run.slot, "get", ::Elm::tlatrace::key("stop", c.tla_ctl));
            return false;
        }
        if (c.budget.load(std::memory_order_acquire) > 0 && env.anyWork()) {
            if (!c.reactivate()) return false;
            return true;
        }
        if ((s & SliceControl::kActiveMask) == 0) {
            // Everyone looked idle in word `s`. Re-read budget and work; commit
            // "done" only if `s` is still the word (nobody reactivated since).
            const bool work = c.budget.load(std::memory_order_acquire) > 0 && env.anyWork();
            if (!work) {
                uint64_t expect = s;
                if (c.state.compare_exchange_strong(expect, s | SliceControl::kDone,
                                                    std::memory_order_acq_rel,
                                                    std::memory_order_acquire)) {
                    ECO_TLA_TRACE("mw.decide", "w", tla_run.slot, "ok", true,
                                  "rmw", ::Elm::tlatrace::key("S", c.tla_ctl), "old", s,
                                  "new", s | SliceControl::kDone);
                    return false;
                }
                ECO_TLA_TRACE("mw.decide", "w", tla_run.slot, "ok", false,
                              "rd", ::Elm::tlatrace::key("S", c.tla_ctl), "val", expect);
            }
            continue;
        }
        backoff(round, w);
    }
}

/// Runs participant `self`'s share of the marking run `c`, scanning entries until the run stops or is done or, for an
/// Assist, until it finds no work or its tickets run out.
///
/// `pool` is where the participant claims its tickets: `c.budget` for a Member, a pool of its own for an Assist. It
/// must outlive the call. `role` is as `Role` describes. When `joined` is true the participant enters a run already
/// under way, counting itself in with `reactivate` (and returning at once if the run is already done) instead of
/// being one of those `c` counted active at the start.
///
/// Each pass of the loop first publishes the participant's work if `c.share_epoch` has changed, then, unless a stop
/// has been requested, fills the ring from its own work, one ticket per entry, and scans the oldest entry in the
/// ring. With the ring empty, a parallel participant leaves if a stop has been requested, and otherwise steals one
/// entry, claiming its ticket first; failing that an Assist leaves while a Member goes idle and waits in
/// `idleUntilWorkOrDone`. Before it calls `goIdle`, whether to wait or to leave, a participant publishes its work
/// and returns its tickets, so that a participant reading the state word after that `goIdle` also sees that work
/// and budget and does not decide the run done while they remain. `Env` is as the file comment describes; with a
/// serial `Env` the loop only fills and scans, returns when its own work or its tickets run out, and then returns
/// its unused tickets; `joined`, stop and `c.share_epoch` are ignored.
template <class Env>
inline void runMarkerLoop(Env& env, unsigned self, SliceControl& c,
                          std::atomic<int64_t>& pool, Role role, bool joined) {
    MarkerCounters& w = env.counters(self);
    ECO_TLA_TRACE_ONLY(tla_run = TlaRun{self, c.tla_ctl, &pool == &c.budget};)
    ECO_TLA_TRACE("mw.run", "w", self, "ctl", c.tla_ctl, "assist", role == Role::Assist,
                  "joined", joined);
    if constexpr (Env::kParallel) {
        if (joined && !c.reactivate()) {
            ECO_TLA_TRACE("mw.exit", "w", self, "why", "join");
            return;
        }
    }
    uint64_t ring[kRingDepth];
    size_t head = 0, count = 0;
    auto ringPush = [&](uint64_t e) {
        env.prefetch(e);
        ring[(head + count) & (kRingDepth - 1)] = e;
        ++count;
    };
    bool active = true;
    for (;;) {
        const bool stopping = Env::kParallel && c.stopRequested();
        if constexpr (Env::kParallel) {
            const uint32_t se = c.share_epoch.load(std::memory_order_relaxed);
            if (se != w.share_seen) { w.share_seen = se; env.publishAll(self); }
        }
        // (1) Fill the ring from our own work, a ticket per entry. A ticket claimed for no entry is kept.
        while (!stopping && count < kRingDepth) {
            if (!claimTicket(w, pool)) break;
            const uint64_t e = env.takeOwn(self);
            ECO_TLA_TRACE("mw.take", "w", self, "e", e);
            if (e == kEmpty) { ++w.tickets; break; }
            ringPush(e);
        }
        // (2) Scan the oldest entry in the ring.
        if (count > 0) {
            const uint64_t e = ring[head];
            head = (head + 1) & (kRingDepth - 1);
            --count;
            ECO_TLA_TRACE("mw.scan", "w", self, "e", e);
            env.scan(self, e);
            ++w.units;
            if (c.jitter_us != 0 && (w.units & 4095) == 0) {
                sleepMicros(static_cast<unsigned>(w.next() % (c.jitter_us + 1)));
            }
            continue;
        }
        if constexpr (Env::kParallel) {
            if (stopping) break;                     // ring empty; still active
            // (3) Steal, holding a ticket first, so that a stolen entry is always paid for (except under the
            // steal_without_ticket fault).
            if (c.steal_without_ticket) {
                const uint64_t e = stealAny(env, self, c, w);
                if (e != kEmpty) {
                    if (claimTicket(w, pool)) { ringPush(e); continue; }
                    ECO_TLA_TRACE("mw.scan", "w", self, "e", e);
                    env.scan(self, e);   // deliberately unaccounted: the hook's bug
                    continue;
                }
            } else if (claimTicket(w, pool)) {
                const uint64_t e = stealAny(env, self, c, w);
                if (e != kEmpty) { ringPush(e); continue; }
                ++w.tickets;
            }
            if (role == Role::Assist) break;         // never idles: leave (active)
            // (4) Idle: publish and return tickets before goIdle, then wait for work or the end of the run.
            env.publishAll(self);
            returnTickets(w, pool);
            c.goIdle();
            active = false;
            if (!idleUntilWorkOrDone(env, c, w)) break;
            active = true;
        } else {
            break;
        }
    }
    if constexpr (Env::kParallel) {
        if (active) {
            env.publishAll(self);
            returnTickets(w, pool);
            c.goIdle();
            ECO_TLA_TRACE("mw.exit", "w", self, "why", "active",
                          "get", ::Elm::tlatrace::key(c.stopRequested() ? "stop" : "nostop", c.tla_ctl));
            return;
        }
        env.publishAll(self);   // published before goIdle already, so normally this moves nothing
    }
    returnTickets(w, pool);
    ECO_TLA_TRACE("mw.exit", "w", self, "why", "idle");
}

/// Runs participant `self` as a Member counted in `c`'s initial active set, drawing on `c.budget`.
template <class Env>
inline void runMarkerLoop(Env& env, unsigned self, SliceControl& c) {
    runMarkerLoop(env, self, c, c.budget, Role::Member, /*joined=*/false);
}

}  // namespace Elm::markwork
