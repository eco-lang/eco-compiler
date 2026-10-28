#ifndef ECO_RESERVEDARRAY_H
#define ECO_RESERVEDARRAY_H

// Some GC metadata tables grow while another thread holds the address of one of their elements, so
// their storage must never move. This component is an array that grows without moving.
//
// A `ReservedArray<T>` first reserves address space for a fixed number of elements, its capacity,
// and commits none of it. Committing makes memory readable and writable. `ensureCommitted` then
// commits the prefix of the reservation that is in use, as it is needed. The elements stay at
// the base address of the array until it is released, because no code path copies them elsewhere.
// Growth past the capacity is not possible: it aborts.
//
// Elements are never constructed. A newly committed page reads as zero, and an element is set by
// assignment, so `T` must be trivially copyable and trivially destructible, and a zero-filled `T`
// is what a new element holds.
//
// The committed prefix only grows until the array is released. `discard` zeroes a range and gives
// the memory of the whole granules inside it back to the OS where the OS allows, while leaving it
// committed and accessible.
//
// The discard unit is the granule chosen at `reserve`, and the commit unit is the larger of that
// granule and `kCommitChunkBytes`. A large, randomly accessed table can pass `kHugePageBytes`:
// the base is then aligned to 2 MiB, commits happen in whole 2 MiB units, and `discard` gives
// back only whole 2 MiB units, so a 2 MiB range is either wholly committed or not at all and stays
// eligible for a transparent huge page.

#include <atomic>
#include <cassert>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <type_traits>

#include "AllocatorCommon.hpp"
#include "PlatformVirtualMemory.hpp"

namespace Elm {

/// A fixed-capacity array of `T` whose elements never move, grown by committing a longer prefix.
///
/// An array is empty until `reserve` succeeds. From then until `release`, or the next `reserve`,
/// `data()` is fixed, and indices below `committed()` are addressable. Pointers and references to
/// elements stay valid across `ensureCommitted` and `discard`, and are invalidated by `release`,
/// `reserve` and destruction. A `ReservedArray` cannot be copied or moved. The destructor releases
/// the reservation.
///
/// Concurrency: one thread, the owner, calls `reserve`, `ensureCommitted`, `discard` and `release`.
/// `ensureCommitted` publishes the new count with a release store after the memory is committed,
/// and `committed()` reads it with an acquire load, so another thread that reads `committed()` may
/// address the indices below it while the owner grows the array. Nothing here synchronises access
/// to the elements themselves, nor makes `release` or `reserve` safe while another thread reads.
template <class T>
class ReservedArray {
    static_assert(std::is_trivially_copyable_v<T> &&
                      std::is_trivially_destructible_v<T>,
                  "ReservedArray<T> requires a trivially copyable, trivially "
                  "destructible T (elements come from zero pages)");

public:
    /// The default granule, and the unit `ensureCommitted` rounds its commits up to unless the
    /// granule is larger: 64 KiB, or the OS page size if that is larger.
    static constexpr size_t kCommitChunkBytes =
        (size_t{64} * 1024 > OS_PAGE_SIZE) ? size_t{64} * 1024 : OS_PAGE_SIZE;
    /// The size of a transparent huge page where the base page is 4 KiB, for use as the granule
    /// passed to `reserve`.
    static constexpr size_t kHugePageBytes = size_t{2} * 1024 * 1024;

    ReservedArray() = default;
    ReservedArray(const ReservedArray&) = delete;
    ReservedArray& operator=(const ReservedArray&) = delete;
    ReservedArray(ReservedArray&&) = delete;
    ReservedArray& operator=(ReservedArray&&) = delete;
    ~ReservedArray() { release(); }

    /// Releases any previous reservation, then reserves address space for `capacity` elements and
    /// commits none of it. Returns false if the address space cannot be reserved, leaving the array
    /// empty. A zero `capacity` reserves nothing and returns true.
    ///
    /// `granule` must be a power of two, and is raised to the OS page size if smaller. The base of
    /// the array is aligned to it, the reservation is a whole number of granules, `discard` gives
    /// memory back only in whole granules, and `ensureCommitted` commits in units of the larger of
    /// `granule` and `kCommitChunkBytes`. `capacity * sizeof(T)` must not overflow.
    bool reserve(size_t capacity, size_t granule = kCommitChunkBytes) {
        release();
        if (capacity == 0) return true;
        if (granule < OS_PAGE_SIZE) granule = OS_PAGE_SIZE;
        const size_t bytes = roundUp(capacity * sizeof(T), granule);
        // Over-reserve by one granule so the usable base can be aligned. A page-sized granule needs
        // no slack, because the platform already returns a page-aligned address.
        const size_t raw_bytes =
            (granule > OS_PAGE_SIZE) ? bytes + granule : bytes;
        void* p = platform::reserveAddressSpace(raw_bytes);
        if (p == nullptr) return false;
        raw_base_ = p;
        raw_bytes_ = raw_bytes;
        base_ = reinterpret_cast<T*>(
            roundUp(reinterpret_cast<uintptr_t>(p), granule));
        granule_ = granule;
        capacity_ = capacity;
        reserved_bytes_ = bytes;
        committed_bytes_ = 0;
        committed_.store(0, std::memory_order_relaxed);
        return true;
    }

    /// Gives the whole reservation back to the OS and leaves the array empty. Does nothing to an
    /// array that is already empty.
    void release() {
        if (raw_base_ != nullptr) {
            platform::releaseReservation(raw_base_, raw_bytes_);
        }
        raw_base_ = nullptr;
        raw_bytes_ = 0;
        base_ = nullptr;
        capacity_ = 0;
        reserved_bytes_ = 0;
        committed_bytes_ = 0;
        committed_.store(0, std::memory_order_relaxed);
    }

    /// Makes indices `[0, n)` addressable, without moving any element. Newly committed elements
    /// read as zero, and elements already committed keep their values. Does nothing if `n` is not
    /// more than `committed()`. Prints a message and aborts the process if `n` exceeds the
    /// capacity, which includes any `n > 0` on an empty array, or if the commit fails.
    ///
    /// `committed()` may afterwards exceed `n`, up to the end of the last unit committed or the
    /// capacity, whichever is smaller.
    void ensureCommitted(size_t n) {
        if (n <= committed_.load(std::memory_order_relaxed)) return;
        if (n > capacity_) {
            std::fprintf(stderr,
                "[oldgen] ReservedArray overflow (n=%zu, cap=%zu, elem=%zu B)\n",
                n, capacity_, sizeof(T));
            std::abort();
        }
        size_t want = roundUp(n * sizeof(T),
                              granule_ > kCommitChunkBytes ? granule_
                                                           : kCommitChunkBytes);
        if (want > reserved_bytes_) want = reserved_bytes_;
        char* from = reinterpret_cast<char*>(base_) + committed_bytes_;
        const size_t len = want - committed_bytes_;
        if (platform::commitAt(from, len) == nullptr) {
            std::fprintf(stderr,
                "[oldgen] ReservedArray commit failed (n=%zu, cap=%zu, "
                "bytes=%zu)\n", n, capacity_, len);
            std::abort();
        }
        committed_bytes_ = want;
        size_t c = committed_bytes_ / sizeof(T);
        if (c > capacity_) c = capacity_;
        // Other threads read the count while the owner commits, so it is published only after the
        // memory behind it is committed.
        committed_.store(c, std::memory_order_release);
    }

    /// Sets elements `[first, first + count)` to zero, and gives back to the OS the memory of the
    /// granules wholly inside that range where the OS allows (otherwise they are zeroed in place).
    /// The range stays committed, and `committed()` does not change. `first + count` must not
    /// exceed `committed()`, which is asserted when assertions are enabled.
    void discard(size_t first, size_t count) {
        if (count == 0) return;
        assert(first + count <= committed());
        char* lo = reinterpret_cast<char*>(base_ + first);
        char* hi = reinterpret_cast<char*>(base_ + first + count);
        // Only whole granules are given back, so a huge page is never split. If that fails, the
        // granules are zeroed by hand instead.
        char* plo = reinterpret_cast<char*>(
            roundUp(reinterpret_cast<uintptr_t>(lo), granule_));
        char* phi = reinterpret_cast<char*>(
            reinterpret_cast<uintptr_t>(hi) & ~(uintptr_t(granule_) - 1));
        if (plo >= phi) {
            std::memset(lo, 0, static_cast<size_t>(hi - lo));
            return;
        }
        std::memset(lo, 0, static_cast<size_t>(plo - lo));
        if (!platform::resetPagesToZero(plo, static_cast<size_t>(phi - plo))) {
            std::memset(plo, 0, static_cast<size_t>(phi - plo));
        }
        std::memset(phi, 0, static_cast<size_t>(hi - phi));
    }

    /// Returns element `i`. `i` must be less than `committed()`, which is asserted when assertions
    /// are enabled.
    T& operator[](size_t i) {
        assert(i < committed() && "ReservedArray index past committed prefix");
        return base_[i];
    }
    /// Returns element `i` of a const array, as the non-const overload does.
    const T& operator[](size_t i) const {
        assert(i < committed() && "ReservedArray index past committed prefix");
        return base_[i];
    }

    /// Returns the address of element 0, or a null pointer if the array is empty. It stays the same
    /// until `release` or the next `reserve`.
    T* data() { return base_; }
    /// Returns the address of element 0 of a const array, as the non-const overload does.
    const T* data() const { return base_; }
    /// Returns the number of elements the reservation holds, or 0 if the array is empty.
    size_t capacity() const { return capacity_; }
    /// Returns the number of leading elements that are addressable. Safe to call from a thread
    /// other than the owner (see the class comment).
    size_t committed() const { return committed_.load(std::memory_order_acquire); }
    /// Returns the size of the reservation in bytes, excluding the alignment slack: the capacity
    /// in bytes, rounded up to a whole granule.
    size_t reservedBytes() const { return reserved_bytes_; }
    /// Returns the number of bytes committed from the base. Only the owner may call it.
    size_t committedBytes() const { return committed_bytes_; }

private:
    /// Returns `v` rounded up to a multiple of `a`, which must be a power of two.
    static size_t roundUp(size_t v, size_t a) { return (v + a - 1) & ~(a - 1); }

    // The reservation as the platform returned it, including the alignment slack, which is what
    // `release` gives back. Null when the array is empty.
    void* raw_base_ = nullptr;
    size_t raw_bytes_ = 0;
    size_t granule_ = OS_PAGE_SIZE;
    // `raw_base_` rounded up to `granule_`. Null when the array is empty.
    T* base_ = nullptr;
    size_t capacity_ = 0;
    size_t reserved_bytes_ = 0;
    // Written only by the owner. `committed_` is this in elements, capped at `capacity_`.
    size_t committed_bytes_ = 0;
    std::atomic<size_t> committed_{0};
};

}  // namespace Elm

#endif  // ECO_RESERVEDARRAY_H
