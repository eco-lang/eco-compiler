#pragma once

// threaded-gc-05b (plans/threaded-gc-05b-parallel-marking.md P§3.1, P§3.3,
// P§3.4; HEAP_064): the std-only core of the old-gen marker.
//
//   - the 8-byte mark entry (object or chunk);
//   - WorkStealingDeque: Chase-Lev, memory orders exactly as in Le, Pop, Cohen,
//     Zappa Nardelli, "Correct and Efficient Work-Stealing for Weak Memory
//     Models" (PPoPP 2013), fig. 1. Do not relax them for x86 (plan trap 1);
//   - runMarkerLoop: the ticketed ring loop with stealing and termination,
//     templated on an environment so that OldGenSpace and the TSan harness
//     (test/gc-helper-tsan) run the SAME loop.
//
// Deliberately standalone: includes nothing from the allocator.

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

namespace Elm::markwork {

// ---------------------------------------------------------------------------
// The mark entry (P§3.1)
// ---------------------------------------------------------------------------
//   bit 63     : 0 = object entry, 1 = chunk entry
//   bits 0..39 : address >> 3 (heap addresses are < 2^43)
//   bits 40..62: object entry = block id + 1 (0 = unknown); chunk = chunk index
constexpr uint64_t kChunkBit   = 1ull << 63;
constexpr uint64_t kAddrMask   = (1ull << 40) - 1;
constexpr uint32_t kFieldMax   = (1u << 23) - 1;
constexpr uint64_t kEmpty      = 0;              // address 0 is never an object
constexpr uint64_t kAbort      = ~0ull;          // steal lost a race (never a valid entry)

inline uint64_t objEntry(const void* p, uint32_t id_plus1) {
    const uint64_t a = reinterpret_cast<uintptr_t>(p);
    assert((a & 7) == 0 && (a >> 43) == 0 && "mark entry: address out of range");
    const uint64_t f = (id_plus1 <= kFieldMax) ? id_plus1 : 0;
    return (a >> 3) | (f << 40);
}
inline uint64_t chunkEntry(const void* arr, uint32_t chunk) {
    const uint64_t a = reinterpret_cast<uintptr_t>(arr);
    assert((a & 7) == 0 && (a >> 43) == 0 && chunk <= kFieldMax);
    return kChunkBit | (a >> 3) | (static_cast<uint64_t>(chunk) << 40);
}
inline bool isChunk(uint64_t e) { return (e & kChunkBit) != 0; }
inline void* entryAddr(uint64_t e) {
    return reinterpret_cast<void*>(static_cast<uintptr_t>((e & kAddrMask) << 3));
}
inline uint32_t entryField(uint64_t e) { return static_cast<uint32_t>((e >> 40) & kFieldMax); }

// ---------------------------------------------------------------------------
// WorkStealingDeque (P§3.4)
// ---------------------------------------------------------------------------
class WorkStealingDeque {
public:
    explicit WorkStealingDeque(int64_t log_initial = 14) {
        array_.store(Array::make(log_initial), std::memory_order_relaxed);
    }
    ~WorkStealingDeque() {
        retireOldArrays();
        Array::destroy(array_.load(std::memory_order_relaxed));
    }
    WorkStealingDeque(const WorkStealingDeque&) = delete;
    WorkStealingDeque& operator=(const WorkStealingDeque&) = delete;

    // Owner only.
    void push(uint64_t e) {
        const int64_t b = bottom_.load(std::memory_order_relaxed);
        const int64_t t = top_.load(std::memory_order_acquire);
        Array* a = array_.load(std::memory_order_relaxed);
        if (b - t > a->mask) {
            a = grow(a, b, t);
        }
        a->buf[b & a->mask].store(e, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_release);
        bottom_.store(b + 1, std::memory_order_relaxed);
    }

    // Owner only. kEmpty when empty.
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

    // Any thread. kEmpty when empty, kAbort when it lost a race.
    uint64_t steal() {
        int64_t t = top_.load(std::memory_order_acquire);
        std::atomic_thread_fence(std::memory_order_seq_cst);
        const int64_t b = bottom_.load(std::memory_order_acquire);
        if (t < b) {
            Array* a = array_.load(std::memory_order_acquire);
            const uint64_t e = a->buf[t & a->mask].load(std::memory_order_relaxed);
            if (!top_.compare_exchange_strong(t, t + 1, std::memory_order_seq_cst,
                                              std::memory_order_relaxed)) {
                return kAbort;
            }
            return e;
        }
        return kEmpty;
    }

    // Termination hint only (relaxed): may be stale.
    bool emptyApprox() const {
        return bottom_.load(std::memory_order_relaxed) <= top_.load(std::memory_order_relaxed);
    }
    size_t sizeApprox() const {
        const int64_t d = bottom_.load(std::memory_order_relaxed) -
                          top_.load(std::memory_order_relaxed);
        return d > 0 ? static_cast<size_t>(d) : 0;
    }
    uint64_t grows() const { return grows_; }

    // Only while no other thread can access the deque (after a gang join).
    void retireOldArrays() {
        for (Array* a : retired_) Array::destroy(a);
        retired_.clear();
    }
    // Same; the deque must be empty (asserted).
    void reset() {
        assert(emptyApprox() && "WorkStealingDeque::reset on a non-empty deque");
        retireOldArrays();
        top_.store(0, std::memory_order_relaxed);
        bottom_.store(0, std::memory_order_relaxed);
    }

private:
    struct Array {
        int64_t mask;
        std::atomic<uint64_t>* buf;
        static Array* make(int64_t log_size) {
            Array* a = new Array;
            const int64_t n = int64_t{1} << log_size;
            a->mask = n - 1;
            a->buf = new std::atomic<uint64_t>[static_cast<size_t>(n)];
            return a;
        }
        static void destroy(Array* a) {
            if (!a) return;
            delete[] a->buf;
            delete a;
        }
    };

    Array* grow(Array* a, int64_t b, int64_t t) {
        int64_t log = 0;
        while ((int64_t{1} << log) <= a->mask) ++log;
        Array* na = Array::make(log + 1);
        for (int64_t i = t; i < b; ++i) {
            na->buf[i & na->mask].store(a->buf[i & a->mask].load(std::memory_order_relaxed),
                                        std::memory_order_relaxed);
        }
        retired_.push_back(a);        // a thief may still read it: free after the join
        array_.store(na, std::memory_order_release);
        ++grows_;
        return na;
    }

    alignas(64) std::atomic<int64_t> top_{0};
    alignas(64) std::atomic<int64_t> bottom_{0};
    alignas(64) std::atomic<Array*> array_{nullptr};
    std::vector<Array*> retired_;     // owner-only
    uint64_t grows_ = 0;
};

// ---------------------------------------------------------------------------
// Slice control, tickets and the marker loop (P§3.3)
// ---------------------------------------------------------------------------
constexpr int64_t kDrainBudget = INT64_MAX / 4;
constexpr int64_t kTicketBatch = 256;
constexpr size_t  kRingDepth   = 16;          // == OldGenSpace::MARK_FIFO_DEPTH (W13d)
static_assert((kRingDepth & (kRingDepth - 1)) == 0, "ring depth must be a power of two");

struct SliceControl {
    // Termination state in ONE word (P§3.3 as built): bits 0..31 = active
    // markers, bits 32..62 = reactivation epoch, bit 63 = done. Deciding
    // "done" is a CAS from the exact word in which the decider saw
    // active == 0 -- so any reactivation (which bumps the epoch) between
    // that observation and the decider's budget/work reads makes the CAS
    // fail. (First build: separate `active`/`done` atomics; a marker could
    // reactivate and claim the whole budget as a local batch between the
    // decider's two reads, and the slice ended with work and budget left --
    // found by the determinism test under a loaded full-suite run.)
    static constexpr uint64_t kActiveMask = 0xFFFFFFFFull;
    static constexpr uint64_t kEpochOne   = 1ull << 32;
    static constexpr uint64_t kDone       = 1ull << 63;
    std::atomic<int64_t>  budget{0};
    std::atomic<uint64_t> state{0};
    // threaded-gc-05c (P§3.3): a stop request. Participants finish their ring,
    // publish their private stack and leave WITHOUT setting done; the unscanned
    // work stays in the deques for a later run.
    std::atomic<bool>     stop{false};
    // threaded-gc-05c: a joiner (assist / closing) bumps this so every running
    // participant publishes its private stack at its next ring refill -- work
    // a private stack holds is otherwise out of the joiners' reach.
    std::atomic<uint32_t> share_epoch{0};
    // threaded-gc-05c: the VICTIM range (every slot a thief may steal from and
    // anyWork() scans), no longer the participant count.
    uint32_t              n = 1;
    unsigned              jitter_us = 0;
    bool                  steal_without_ticket = false;   // negative-control hook only
    // `active` = participants counted active at the start (default: members).
    explicit SliceControl(int64_t b, uint32_t members = 1, unsigned jitter = 0,
                          int64_t active = -1)
        : n(members), jitter_us(jitter) {
        budget.store(b, std::memory_order_relaxed);
        state.store(active < 0 ? members : static_cast<uint64_t>(active),
                    std::memory_order_relaxed);
    }
    bool done() const { return (state.load(std::memory_order_acquire) & kDone) != 0; }
    uint32_t active() const {
        return static_cast<uint32_t>(state.load(std::memory_order_acquire) & kActiveMask);
    }
    bool stopRequested() const { return stop.load(std::memory_order_relaxed); }
    void goIdle() { state.fetch_sub(1, std::memory_order_acq_rel); }
    // false when the slice is already done.
    bool reactivate() {
        uint64_t s = state.load(std::memory_order_acquire);
        for (;;) {
            if (s & kDone) return false;
            if (state.compare_exchange_weak(s, s + 1 + kEpochOne, std::memory_order_acq_rel,
                                            std::memory_order_acquire)) {
                return true;
            }
        }
    }
};

// threaded-gc-05c (P§3.3): how a participant takes part in a run.
//   Member: 5b semantics -- idles until the control terminates.
//   Assist: joins for a bounded ticket pool, never idles; leaves (publishing
//           everything first) when its pool is empty or it finds no work.
enum class Role : uint8_t { Member, Assist };

struct MarkerCounters {
    uint64_t tickets = 0;          // claimed, unconsumed
    uint64_t units = 0;            // consumed this run
    uint64_t steals = 0, steal_aborts = 0, steal_empty = 0;
    uint64_t idle_spins = 0, idle_yields = 0, idle_sleeps = 0;
    uint64_t rng = 0;
    uint32_t share_seen = 0;       // last SliceControl::share_epoch acted on
    void resetRun(unsigned member) {
        share_seen = 0;
        tickets = units = steals = steal_aborts = steal_empty = 0;
        idle_spins = idle_yields = idle_sleeps = 0;
        rng = 0x9E3779B97F4A7C15ull ^ ((static_cast<uint64_t>(member) + 1) * 0xBF58476D1CE4E5B9ull);
    }
    uint64_t next() {                               // xorshift64
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
        return rng;
    }
};

inline bool claimTicket(MarkerCounters& w, std::atomic<int64_t>& pool) {
    if (w.tickets > 0) { --w.tickets; return true; }
    int64_t b = pool.load(std::memory_order_relaxed);
    while (b > 0) {
        const int64_t take = b < kTicketBatch ? b : kTicketBatch;
        if (pool.compare_exchange_weak(b, b - take, std::memory_order_relaxed)) {
            w.tickets = static_cast<uint64_t>(take - 1);
            return true;
        }
    }
    return false;
}
inline bool claimTicket(MarkerCounters& w, SliceControl& c) { return claimTicket(w, c.budget); }
inline void returnTickets(MarkerCounters& w, std::atomic<int64_t>& pool) {
    if (w.tickets) {
        pool.fetch_add(static_cast<int64_t>(w.tickets), std::memory_order_relaxed);
        w.tickets = 0;
    }
}
inline void returnTickets(MarkerCounters& w, SliceControl& c) { returnTickets(w, c.budget); }

inline void cpuRelax() {
#if defined(__x86_64__) || defined(__i386__)
    __builtin_ia32_pause();
#elif defined(__aarch64__)
    asm volatile("yield");
#endif
}

inline void sleepMicros(unsigned us) {
#if !defined(_WIN32)
    timespec ts{0, static_cast<long>(us) * 1000};
    nanosleep(&ts, nullptr);
#else
    std::this_thread::sleep_for(std::chrono::microseconds(us));
#endif
}

// Backoff ladder (plan trap 11): spin, then yield, then sleep.
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

// Env contract:
//   static constexpr bool kParallel;
//   MarkerCounters& counters(unsigned i);
//   uint64_t takeOwn(unsigned self);                 // kEmpty when empty
//   uint64_t stealFrom(unsigned victim);             // kEmpty / kAbort / entry
//   bool     anyWork();                              // parallel: any deque non-empty
//   void     prefetch(uint64_t e);
//   void     scan(unsigned self, uint64_t e);        // may push onto self's grey set
//   void     publishAll(unsigned self);              // parallel: move self's private
//                                                    // stack into its deque (05c)
template <class Env>
inline uint64_t stealAny(Env& env, unsigned self, SliceControl& c, MarkerCounters& w) {
    const unsigned n = c.n;
    if (n <= 1) return kEmpty;
    for (int pass = 0; pass < 4; ++pass) {
        bool aborted = false;
        const unsigned start = static_cast<unsigned>(w.next() % n);
        for (unsigned k = 0; k < n; ++k) {
            const unsigned v = (start + k) % n;
            if (v == self) continue;
            const uint64_t e = env.stealFrom(v);
            if (e == kAbort) { aborted = true; ++w.steal_aborts; continue; }
            if (e != kEmpty) { ++w.steals; return e; }
        }
        if (!aborted) break;
    }
    ++w.steal_empty;
    return kEmpty;
}

// Returns true when reactivated with possible work, false when the slice is done.
// Precondition: the caller already returned its tickets and went idle.
template <class Env>
inline bool idleUntilWorkOrDone(Env& env, SliceControl& c, MarkerCounters& w) {
    for (unsigned round = 0;; ++round) {
        const uint64_t s = c.state.load(std::memory_order_acquire);
        if (s & SliceControl::kDone) return false;
        if (c.stopRequested()) return false;          // 05c: leave idle on a stop
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
                    return false;
                }
            }
            continue;
        }
        backoff(round, w);
    }
}

// threaded-gc-05c (P§3.3): one participant's run.
//   pool   -- its ticket source (&c.budget for Members, an assist pool for Assists);
//   role   -- Member (idle until termination) or Assist (bounded, never idles);
//   joined -- it enters a RUNNING control (c.reactivate(); returns at once when
//             the control already terminated) instead of being counted in the
//             control's initial active count.
// Every exit of a parallel participant that is still active scans its ring,
// publishes its private stack (Env::publishAll), returns its tickets and only
// THEN goes idle (plan trap 5): an idle Member that reads the post-goIdle state
// word also sees the published work and reactivates instead of deciding done.
template <class Env>
inline void runMarkerLoop(Env& env, unsigned self, SliceControl& c,
                          std::atomic<int64_t>& pool, Role role, bool joined) {
    MarkerCounters& w = env.counters(self);
    if constexpr (Env::kParallel) {
        if (joined && !c.reactivate()) return;
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
        // (1) Fill the ring: a ticket per entry, taken from our own grey set.
        while (!stopping && count < kRingDepth) {
            if (!claimTicket(w, pool)) break;
            const uint64_t e = env.takeOwn(self);
            if (e == kEmpty) { ++w.tickets; break; }
            ringPush(e);
        }
        // (2) Scan the oldest entry in the ring.
        if (count > 0) {
            const uint64_t e = ring[head];
            head = (head + 1) & (kRingDepth - 1);
            --count;
            env.scan(self, e);
            ++w.units;
            if (c.jitter_us != 0 && (w.units & 4095) == 0) {
                sleepMicros(static_cast<unsigned>(w.next() % (c.jitter_us + 1)));
            }
            continue;
        }
        if constexpr (Env::kParallel) {
            if (stopping) break;                     // ring empty; still active
            // (3) Steal, with a ticket in hand (plan trap 2).
            if (c.steal_without_ticket) {
                const uint64_t e = stealAny(env, self, c, w);
                if (e != kEmpty) {
                    if (claimTicket(w, pool)) { ringPush(e); continue; }
                    env.scan(self, e);   // deliberately unaccounted: the hook's bug
                    continue;
                }
            } else if (claimTicket(w, pool)) {
                const uint64_t e = stealAny(env, self, c, w);
                if (e != kEmpty) { ringPush(e); continue; }
                ++w.tickets;
            }
            if (role == Role::Assist) break;         // never idles: leave (active)
            // (4) Idle: publish, return tickets first (plan trap 3), then termination.
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
            return;
        }
        env.publishAll(self);   // after termination: nobody runs; normally a no-op
    }
    returnTickets(w, pool);
}

// 5b entry point: a Member counted in the initial active set, drawing on c.budget.
template <class Env>
inline void runMarkerLoop(Env& env, unsigned self, SliceControl& c) {
    runMarkerLoop(env, self, c, c.budget, Role::Member, /*joined=*/false);
}

}  // namespace Elm::markwork
