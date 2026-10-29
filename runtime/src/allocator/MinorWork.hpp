#pragma once

// The rules by which several threads copy nursery objects at the same time without copying any object twice, and
// the allocator they copy into. Together these are the concurrency core of the parallel minor collection.
//
// A minor collection copies each live object out of from-space, the part of the nursery being collected, into
// to-space, and writes over the old object's header word a forward word: a word whose tag is `kTagForward` and
// which holds the new address. Any later reference to the old object is redirected through it. When several threads
// copy at once, two of them can reach the same object, so the header word is where they agree on who copies it.
// Each change to that word is one atomic operation:
//
//   1. Claim. A thread that reads an ordinary header CASes it to BUSY (`kBusy`), a forward word whose address is 0.
//      Only the thread whose CAS succeeds copies the object. A thread whose CAS fails is given the word that beat it.
//   2. Copy. The winner allocates to-space and copies the object. The header in place now reads BUSY, so the copy
//      must be built from the header word the claim replaced.
//   3. Publish. The winner stores the forward word with release ordering. A thread that reads that word with acquire
//      ordering therefore also sees the copied bytes.
//
// A thread that reads BUSY waits for the publish. No object is at address 0, so BUSY is never a published forward
// word. While threads may claim concurrently, every access to a header word that may be claimed must go through
// these functions, which access it atomically.
//
// A forward word keeps the layout of the heap's `Header` and `Forward` bitfields (Heap.hpp): the tag in bits 0..4,
// the colour (the mark colour of `Header.color`) in bits 5..6, and the new address divided by 8 in bits 7..46. This
// header deliberately includes nothing from the allocator, so that it can be compiled and tested on its own, and so
// it does not check that layout itself: `kTagForward` must equal `Tag_Forward`, and the bit positions must match.
//
// To-space is one range of memory shared by all the copying threads, who claim from it by CAS on its top. To keep
// those CASes rare, each thread claims a LAB (local allocation buffer), a run of `ToSpace::lab_bytes` bytes, and
// allocates from it without synchronisation. An object of at least `ToSpace::direct_min` bytes is claimed from
// to-space directly instead. When an object does not fit in what is left of a LAB, a LAB with more than
// `ToSpace::retire_max` bytes left is kept and the object is claimed directly; any other LAB is retired, its unused
// tail becomes a filler (a dead object that covers the range exactly), and a new LAB is claimed. When the copying is
// over, `closeLabs` hands back the LABs that end at the top and turns every other unused tail into a filler, so
// that to-space is left as a sequence of objects. Running out of to-space aborts the process: whoever sets up a
// `ToSpace` must make it large enough for everything that can be copied into it.
//
// The file also defines `SpinMutex`, a lock for very short critical sections.

#include <atomic>
#include <chrono>
#include <thread>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "TlaTrace.hpp"   // ECO_TLA_TRACE event hooks; they compile to nothing outside trace builds.

namespace Elm::minorwork {

// ---------------------------------------------------------------------------
// Header and forward words
// ---------------------------------------------------------------------------
// The mask of the tag, bits 0..4 of a header or forward word.
constexpr uint64_t kTagMask    = 31;
// The tag of a forward word. It must equal the heap's `Tag_Forward`, which this header cannot check.
constexpr uint64_t kTagForward = 26;
// The position of the 2-bit colour field.
constexpr unsigned kColorShift = 5;
// The position of the forward word's address field, which holds the address divided by 8.
constexpr unsigned kFwdShift   = 7;
// The mask of the address field once shifted down: 40 bits, so addresses below 2^43.
constexpr uint64_t kFwdMask    = (1ull << 40) - 1;
// The word that marks an object as claimed and still being copied: a forward word with colour 0 and address 0.
constexpr uint64_t kBusy       = kTagForward;

// Returns the tag of the header or forward word `w`.
inline uint64_t tagOf(uint64_t w) { return w & kTagMask; }
// Returns whether `w` is a forward word. BUSY is one.
inline bool isForwardWord(uint64_t w) { return tagOf(w) == kTagForward; }
// Returns the colour field of the header or forward word `w`.
inline uint64_t colorOf(uint64_t w) { return (w >> kColorShift) & 3; }
// Returns the forward word that redirects to `dst` and carries colour `color`.
//
// `dst` must be 8-byte aligned and below 2^43: its low 3 bits and any bits above bit 42 are dropped. Only the low
// 2 bits of `color` are kept.
inline uint64_t fwdWord(const void* dst, uint64_t color) {
    const uint64_t a = reinterpret_cast<uintptr_t>(dst);
    return kTagForward | ((color & 3) << kColorShift) | (((a >> 3) & kFwdMask) << kFwdShift);
}
// Returns the address held in the forward word `w`, which is null for BUSY.
inline char* fwdAddr(uint64_t w) {
    return reinterpret_cast<char*>(static_cast<uintptr_t>(((w >> kFwdShift) & kFwdMask) << 3));
}

#if ECO_TLA_TRACE_ENABLED
// Trace builds only. A trace records a header word as the model of this protocol sees it; the hooks also record the
// raw word, so that the events touching one header can be put in their order of modification.
// Returns how the model classifies the header word `w`: 0 for a word that is not a forward word, 1 for BUSY, 2 for
// a published forward word.
inline int tlaWordKind(uint64_t w) { return !isForwardWord(w) ? 0 : (w == kBusy ? 1 : 2); }
// Returns the address a published forward word `w` redirects to, or null for any other word.
inline const void* tlaFwdTo(uint64_t w) { return tlaWordKind(w) == 2 ? fwdAddr(w) : nullptr; }
#endif

// Returns an atomic view of the header word of `obj`, which must point to an 8-byte-aligned object. The view refers
// to that word and must not be used after the object's memory is reused.
inline std::atomic_ref<uint64_t> headerRef(void* obj) {
    return std::atomic_ref<uint64_t>(*static_cast<uint64_t*>(obj));
}
// Returns the header word of `obj`, read with acquire ordering, so that if it is a published forward word the copy
// it points to is visible.
inline uint64_t loadHeader(void* obj) {
    return headerRef(obj).load(std::memory_order_acquire);
}
// Claims `obj` for copying by replacing its header word, expected to be `h`, with BUSY, and returns whether this
// call did so.
//
// On success `h` still holds the replaced word, from which the caller must build the copy, and the caller must
// later call `publish`; until then a thread that reads the header finds BUSY and must wait. On failure `h` is set
// to the word found, which is BUSY, a published forward word, or a header that changed since `h` was read.
inline bool claim(void* obj, uint64_t& h) {
    const bool ok = headerRef(obj).compare_exchange_strong(h, kBusy, std::memory_order_acq_rel,
                                                           std::memory_order_acquire);
    if (ok)
        ECO_TLA_TRACE("claim", "obj", tlatrace::obj(obj), "ok", true, "rmw", tlatrace::key("h", obj),
                      "old", tlatrace::key("W", static_cast<int64_t>(h)),
                      "new", tlatrace::key("W", static_cast<int64_t>(kBusy)));
    else
        ECO_TLA_TRACE("claim", "obj", tlatrace::obj(obj), "ok", false, "rd", tlatrace::key("h", obj),
                      "val", tlatrace::key("W", static_cast<int64_t>(h)), "w", tlaWordKind(h),
                      "to", tlatrace::obj(tlaFwdTo(h)));
    return ok;
}
// Publishes the copy of `obj` at `dst` by storing the forward word to `dst`, with colour `color`, over the header of
// `obj`.
//
// The caller must hold the claim on `obj` and must have finished writing the copy: the release store makes every
// earlier write visible to a thread that reads the forward word through `loadHeader` or `waitPublished`.
inline void publish(void* obj, const void* dst, uint64_t color) {
    headerRef(obj).store(fwdWord(dst, color), std::memory_order_release);
    ECO_TLA_TRACE("publish", "obj", tlatrace::obj(obj), "dst", tlatrace::obj(dst),
                  "rmw", tlatrace::key("h", obj), "old", tlatrace::key("W", static_cast<int64_t>(kBusy)),
                  "new", tlatrace::key("W", static_cast<int64_t>(fwdWord(dst, color))));
}
// Waits until the header word of `obj` is no longer BUSY, and returns the first other word read.
//
// The word is read with acquire ordering. Between reads that find BUSY it calls `pause(round)`, with `round`
// counting from 0, so the caller chooses how to back off. There is no time limit: if the claimant never publishes,
// this never returns.
template <class Pause>
inline uint64_t waitPublished(void* obj, Pause&& pause) {
    for (unsigned round = 0;; ++round) {
        const uint64_t w = loadHeader(obj);
        if (w != kBusy) {
            ECO_TLA_TRACE("wait", "obj", tlatrace::obj(obj), "rd", tlatrace::key("h", obj),
                          "val", tlatrace::key("W", static_cast<int64_t>(w)), "w", tlaWordKind(w),
                          "to", tlatrace::obj(tlaFwdTo(w)));
            return w;
        }
        pause(round);
    }
}

// ---------------------------------------------------------------------------
// A spin lock
// ---------------------------------------------------------------------------
// A mutual-exclusion lock for critical sections much shorter than a thread's sleep and wake-up.
//
// A blocking mutex can put a contended waiter to sleep, and a sleep and wake-up can take longer than such a section.
// A waiter here first spins, then yields its processor, then sleeps for 10 microseconds at a time, so that when there
// are more threads than processors a holder that was preempted still gets to run. It meets the standard Lockable
// requirements, so it works with `std::lock_guard` and `std::unique_lock`. It is not recursive, it is not fair, and it
// can be neither copied nor moved.
class SpinMutex {
public:
    // Takes the lock if it is free, without waiting, and returns whether it did.
    bool try_lock() {
        return !f_.load(std::memory_order_relaxed) &&
               !f_.exchange(true, std::memory_order_acquire);
    }
    // Takes the lock, waiting as long as it takes.
    //
    // The first 256 failed attempts are each followed by 16 processor pause hints (none on processors other than
    // x86 and AArch64), the next 256 by a yield, and every later one by a 10 microsecond sleep.
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
    // Releases the lock. The caller must hold it; this is not checked.
    void unlock() { f_.store(false, std::memory_order_release); }

private:
    std::atomic<bool> f_{false};   // Whether the lock is held.
};

// ---------------------------------------------------------------------------
// To-space and LABs
// ---------------------------------------------------------------------------
/**
 * The to-space of one parallel copy: the range still unclaimed, shared by every copying thread, and the sizes
 * that decide how it is handed out.
 *
 * `reset` sets every member; a default-constructed `ToSpace` has no range. `retire_max` and `direct_min` are a 64th
 * and a quarter of `lab_bytes` only because `reset` sets them so; the members are public and nothing keeps them in
 * step.
 */
struct ToSpace {
    // The start of the unclaimed range, advanced by CAS and moved back by `closeLabs`. It does not own the memory.
    std::atomic<char*> top{nullptr};
    // The end of to-space. It does not own the memory.
    char* end = nullptr;
    // The size of a LAB claimed whole.
    size_t lab_bytes = 32 * 1024;
    size_t retire_max = 32 * 1024 / 64;   // A LAB with at most this many bytes left is retired.
    size_t direct_min = 32 * 1024 / 4;    // An object of at least this many bytes bypasses the LABs.
    // Makes `[base, limit)` the unclaimed range and `lab` the LAB size, with `retire_max` a 64th and `direct_min` a
    // quarter of it. The caller must ensure no thread is claiming.
    void reset(char* base, char* limit, size_t lab) {
        top.store(base, std::memory_order_relaxed);
        end = limit;
        lab_bytes = lab;
        retire_max = lab / 64;
        direct_min = lab / 4;
    }
};

/**
 * The unused rest `[ptr, end)` of one thread's LAB, inside a `ToSpace`. Both null means the thread holds no LAB.
 */
struct Lab {
    char* ptr = nullptr;
    char* end = nullptr;
};

/**
 * Counts of what one thread's `labAllocate` calls did.
 */
struct LabCounters {
    uint64_t lab_claims = 0;
    uint64_t direct_claims = 0;   // Objects claimed from to-space outside a LAB, whatever the reason.
    uint64_t filler_bytes = 0;    // Bytes turned into fillers when LABs were retired; `closeLabs` counts its own.
};

// Reports on standard error that `size` bytes could not be claimed from to-space, and aborts the process.
[[noreturn]] inline void tospaceOverflow(size_t size) {
    std::fprintf(stderr, "[minorwork] FATAL: to-space overflow claiming %zu bytes "
                         "(the P§3.2 space bound is wrong)\n", size);
    std::fflush(stderr);
    std::abort();
}

// Claims exactly `size` bytes from `ts` and returns their start. Aborts the process through `tospaceOverflow` if
// fewer are left. Several threads may call this on one `ToSpace` at once.
inline char* tospaceClaim(ToSpace& ts, size_t size) {
    char* t = ts.top.load(std::memory_order_relaxed);
    for (;;) {
        if (static_cast<size_t>(ts.end - t) < size) tospaceOverflow(size);
        if (ts.top.compare_exchange_weak(t, t + size, std::memory_order_relaxed)) return t;
    }
}

// Claims a new LAB from `ts` into `lab`, of `ts.lab_bytes` bytes or whatever is left if that is less, and returns
// true. Returns false, leaving `lab` unchanged, if that LAB would be smaller than `need` bytes. Several threads may
// call this on one `ToSpace` at once.
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

// Allocates `size` bytes of to-space for the calling thread, from its LAB `lab` or directly from `ts`, and returns
// their start. The bytes are not initialised.
//
// An object of at least `ts.direct_min` bytes is claimed directly. Otherwise it goes in `lab` if it fits. If it does
// not, a LAB with more than `ts.retire_max` bytes left is kept and the object claimed directly; any other LAB is
// retired, its tail made a filler, and a new LAB claimed for the object, or the object claimed directly if no LAB
// of at least `size` bytes can be claimed. `c` counts what was done. `size` must be a multiple of 8, as must every
// size this thread's LAB has been carved into, so that a retired tail is too. `fill(p, n)` must format `[p, p + n)`
// as a filler; it is called only for a tail that is not empty. Aborts the process through `tospaceOverflow` if
// to-space has too little left. Other threads may allocate from `ts` at the same time, but `lab` and `c` must
// belong to the calling thread alone.
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

// Closes the `n` LABs at `labs`, once every thread has stopped allocating from `ts`, and returns the number of
// bytes turned into fillers.
//
// A LAB that ends at the top of `ts` is given back by moving the top down to its unused start. Giving one back can
// make another LAB end at the new top, so this repeats until none does. Every other LAB with an unused tail has
// `fill` called on that tail, under the same requirement as in `labAllocate`. Every LAB is left empty.
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
