#pragma once

// threaded-gc-06 (plans/threaded-gc-06-parallel-minor.md P§3.3-P§3.4;
// HEAP_067/HEAP_068): the std-only core of the parallel minor GC.
//
//   - the header-word protocol: CLAIM a from-space object by CASing its header
//     word to BUSY (Tag_Forward, forward_ptr 0), copy it, then PUBLISH the
//     forward word (Tag_Forward | colour << 5 | (addr >> 3) << 7) with a
//     release store. Readers load with acquire and wait out BUSY;
//   - the to-space LAB allocator: per-worker LABs claimed from an atomic top,
//     objects >= lab/4 claimed directly, a LAB with more than lab/64 left is
//     kept when an object does not fit (the object is claimed directly), a LAB
//     with less is retired and its tail becomes a filler.
//
// Deliberately standalone (includes nothing from the allocator) so the TSan
// harness (test/gc-helper-tsan/minor_harness.cpp) runs the same code. The
// word layout is pinned against Heap.hpp's bitfields in NurseryParallel.cpp
// (static_assert on the tag, runtime test on the composed words).

#include <atomic>
#include <chrono>
#include <thread>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

namespace Elm::minorwork {

// ---------------------------------------------------------------------------
// Header words (P§3.3)
// ---------------------------------------------------------------------------
constexpr uint64_t kTagMask    = 31;          // Header / Forward: tag = bits 0..4
constexpr uint64_t kTagForward = 26;          // == Tag_Forward (asserted by the heap)
constexpr unsigned kColorShift = 5;           // colour = bits 5..6
constexpr unsigned kFwdShift   = 7;           // forward_ptr = bits 7..46 (addr >> 3)
constexpr uint64_t kFwdMask    = (1ull << 40) - 1;
constexpr uint64_t kBusy       = kTagForward; // colour 0, forward_ptr 0: address 0 is never an object

inline uint64_t tagOf(uint64_t w) { return w & kTagMask; }
inline bool isForwardWord(uint64_t w) { return tagOf(w) == kTagForward; }
inline uint64_t colorOf(uint64_t w) { return (w >> kColorShift) & 3; }
inline uint64_t fwdWord(const void* dst, uint64_t color) {
    const uint64_t a = reinterpret_cast<uintptr_t>(dst);
    return kTagForward | ((color & 3) << kColorShift) | (((a >> 3) & kFwdMask) << kFwdShift);
}
inline char* fwdAddr(uint64_t w) {
    return reinterpret_cast<char*>(static_cast<uintptr_t>(((w >> kFwdShift) & kFwdMask) << 3));
}

inline std::atomic_ref<uint64_t> headerRef(void* obj) {
    return std::atomic_ref<uint64_t>(*static_cast<uint64_t*>(obj));
}
inline uint64_t loadHeader(void* obj) {
    return headerRef(obj).load(std::memory_order_acquire);
}
// CAS the header word from `h` to BUSY. On failure `h` holds the observed word.
inline bool claim(void* obj, uint64_t& h) {
    return headerRef(obj).compare_exchange_strong(h, kBusy, std::memory_order_acq_rel,
                                                  std::memory_order_acquire);
}
// Publish the forward word (release: orders the copy before the address).
inline void publish(void* obj, const void* dst, uint64_t color) {
    headerRef(obj).store(fwdWord(dst, color), std::memory_order_release);
}
// Waits until the header word is no longer BUSY and returns it. `pause(round)`
// is the caller's backoff (markwork::backoff); each call counts one round.
template <class Pause>
inline uint64_t waitPublished(void* obj, Pause&& pause) {
    for (unsigned round = 0;; ++round) {
        const uint64_t w = loadHeader(obj);
        if (w != kBusy) return w;
        pause(round);
    }
}

// ---------------------------------------------------------------------------
// The promotion lock (P§3.8.3, as built): critical sections are a few hundred
// ns (a free-list pop, a cursor refill), so a blocking std::mutex made every
// contended acquisition a futex sleep + wake (~tens of us) and convoys formed
// in promotion-heavy minors (E2: 4.3 s of summed wait at N = 8). Spin with
// pause, then yield, then sleep briefly, so an oversubscribed machine (E5)
// still lets a preempted holder run.
// ---------------------------------------------------------------------------
class SpinMutex {
public:
    bool try_lock() {
        return !f_.load(std::memory_order_relaxed) &&
               !f_.exchange(true, std::memory_order_acquire);
    }
    void lock() {
        for (unsigned round = 0;; ++round) {
            if (try_lock()) return;
            if (round < 256) {
                for (int i = 0; i < 16; ++i) {
#if defined(__x86_64__) || defined(__i386__)
                    __builtin_ia32_pause();
#elif defined(__aarch64__)
                    asm volatile("yield");
#endif
                }
            } else if (round < 512) {
                std::this_thread::yield();
            } else {
                std::this_thread::sleep_for(std::chrono::microseconds(10));
            }
        }
    }
    void unlock() { f_.store(false, std::memory_order_release); }

private:
    std::atomic<bool> f_{false};
};

// ---------------------------------------------------------------------------
// To-space LABs (P§3.4)
// ---------------------------------------------------------------------------
struct ToSpace {
    std::atomic<char*> top{nullptr};
    char* end = nullptr;
    size_t lab_bytes = 32 * 1024;
    size_t retire_max = 32 * 1024 / 64;   // a LAB with at most this left is retired
    size_t direct_min = 32 * 1024 / 4;    // objects at least this big bypass the LAB
    void reset(char* base, char* limit, size_t lab) {
        top.store(base, std::memory_order_relaxed);
        end = limit;
        lab_bytes = lab;
        retire_max = lab / 64;
        direct_min = lab / 4;
    }
};

struct Lab {
    char* ptr = nullptr;
    char* end = nullptr;
};

struct LabCounters {
    uint64_t lab_claims = 0;
    uint64_t direct_claims = 0;
    uint64_t filler_bytes = 0;
};

[[noreturn]] inline void tospaceOverflow(size_t size) {
    std::fprintf(stderr, "[minorwork] FATAL: to-space overflow claiming %zu bytes "
                         "(the P§3.2 space bound is wrong)\n", size);
    std::fflush(stderr);
    std::abort();
}

// Claims exactly `size` bytes of to-space (a CAS loop on the top).
inline char* tospaceClaim(ToSpace& ts, size_t size) {
    char* t = ts.top.load(std::memory_order_relaxed);
    for (;;) {
        if (static_cast<size_t>(ts.end - t) < size) tospaceOverflow(size);
        if (ts.top.compare_exchange_weak(t, t + size, std::memory_order_relaxed)) return t;
    }
}

// Claims a new LAB of min(lab_bytes, what is left) bytes. Returns false when
// fewer than `need` bytes are left (the caller then overflows).
inline bool tospaceClaimLab(ToSpace& ts, Lab& lab, size_t need) {
    char* t = ts.top.load(std::memory_order_relaxed);
    for (;;) {
        const size_t left = static_cast<size_t>(ts.end - t);
        const size_t take = left < ts.lab_bytes ? left : ts.lab_bytes;
        if (take < need) return false;
        if (ts.top.compare_exchange_weak(t, t + take, std::memory_order_relaxed)) {
            lab.ptr = t;
            lab.end = t + take;
            return true;
        }
    }
}

// Allocates `size` (8-aligned) bytes of to-space for this worker. `fill(p, n)`
// formats [p, p + n) as a filler object (n >= 8, multiple of 8).
template <class Fill>
inline char* labAllocate(ToSpace& ts, Lab& lab, LabCounters& c, size_t size, Fill&& fill) {
    if (size >= ts.direct_min) {
        ++c.direct_claims;
        return tospaceClaim(ts, size);
    }
    if (static_cast<size_t>(lab.end - lab.ptr) >= size) {
        char* p = lab.ptr;
        lab.ptr += size;
        return p;
    }
    const size_t rem = static_cast<size_t>(lab.end - lab.ptr);
    if (rem > ts.retire_max) {           // keep the LAB; place this object directly
        ++c.direct_claims;
        return tospaceClaim(ts, size);
    }
    if (rem > 0) {                       // retire: the tail becomes a filler
        fill(lab.ptr, rem);
        c.filler_bytes += rem;
    }
    lab.ptr = lab.end = nullptr;
    if (!tospaceClaimLab(ts, lab, size)) {
        ++c.direct_claims;
        return tospaceClaim(ts, size);   // overflows loudly if even this does not fit
    }
    ++c.lab_claims;
    char* p = lab.ptr;
    lab.ptr += size;
    return p;
}

// End of the drain (single-threaded, after the join). The LAB that ends at the
// top is trimmed (the top moves back); every other non-empty tail becomes a
// filler. Returns the filler bytes written. Call once per worker, in any
// order: a trim can expose another LAB's end as the new top, so trimming is
// retried until no LAB ends at the top.
template <class Fill>
inline uint64_t closeLabs(ToSpace& ts, Lab* labs, unsigned n, Fill&& fill) {
    bool trimmed = true;
    while (trimmed) {
        trimmed = false;
        char* t = ts.top.load(std::memory_order_relaxed);
        for (unsigned i = 0; i < n; ++i) {
            if (labs[i].ptr != nullptr && labs[i].end == t) {
                ts.top.store(labs[i].ptr, std::memory_order_relaxed);
                labs[i].ptr = labs[i].end = nullptr;
                trimmed = true;
                break;
            }
        }
    }
    uint64_t bytes = 0;
    for (unsigned i = 0; i < n; ++i) {
        if (labs[i].ptr != nullptr && labs[i].ptr < labs[i].end) {
            const size_t rem = static_cast<size_t>(labs[i].end - labs[i].ptr);
            fill(labs[i].ptr, rem);
            bytes += rem;
        }
        labs[i].ptr = labs[i].end = nullptr;
    }
    return bytes;
}

}  // namespace Elm::minorwork
