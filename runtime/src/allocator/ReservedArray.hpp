#ifndef ECO_RESERVEDARRAY_H
#define ECO_RESERVEDARRAY_H

// ReservedArray<T> — fixed-capacity array whose storage NEVER MOVES
// (threaded-gc-01, plans/threaded-gc-01-stable-metadata.md P§3.2, HEAP_048).
//
// `reserve(capacity)` reserves address space for `capacity` elements and
// commits nothing. `ensureCommitted(n)` commits whole chunks until indices
// [0, n) are addressable; fresh pages read as zero. The data pointer is fixed
// from `reserve` to `release`, and there is no code path that relocates the
// elements: that is the property the threaded GC phases rely on (a second
// thread may hold `&a[i]` across any growth).
//
// Committed storage only grows (except `discard`, which zeroes a range and
// returns its physical pages but keeps it committed and accessible).
//
// T must be trivially copyable and trivially destructible: elements are
// created by zero-filled pages and assignment, never by constructors.
//
// HUGE-PAGE GRANULE (threaded-gc-01, measured): a large, randomly accessed
// array (the mark-bit arena) must stay eligible for transparent huge pages.
// Committing it at the tail in small MAP_FIXED steps means a 2 MiB-aligned
// range is almost never wholly inside the committed mapping when first
// touched, so it faults in as 4 KiB pages: measured 0 MiB AnonHugePages for
// the 134 MiB arena vs 196 MiB for the former malloc'd std::vector, and
// +5.5 % major-GC mark time from the TLB misses. Pass `granule =
// kHugePageBytes` to reserve(): the base is then 2 MiB-aligned, commits
// happen in whole 2 MiB units, and discard() only returns whole 2 MiB units
// (partial ones are zeroed with memset) so it never splits a huge page.

#include <cassert>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <type_traits>

#include "AllocatorCommon.hpp"
#include "PlatformVirtualMemory.hpp"

namespace Elm {

template <class T>
class ReservedArray {
    static_assert(std::is_trivially_copyable_v<T> &&
                      std::is_trivially_destructible_v<T>,
                  "ReservedArray<T> requires a trivially copyable, trivially "
                  "destructible T (elements come from zero pages)");

public:
    // Commit granularity. Rounded up to the OS page size.
    static constexpr size_t kCommitChunkBytes =
        (size_t{64} * 1024 > OS_PAGE_SIZE) ? size_t{64} * 1024 : OS_PAGE_SIZE;
    // Transparent-huge-page size on x86-64 / arm64 (4 KiB base pages).
    static constexpr size_t kHugePageBytes = size_t{2} * 1024 * 1024;

    ReservedArray() = default;
    ReservedArray(const ReservedArray&) = delete;
    ReservedArray& operator=(const ReservedArray&) = delete;
    ReservedArray(ReservedArray&&) = delete;
    ReservedArray& operator=(ReservedArray&&) = delete;
    ~ReservedArray() { release(); }

    // Reserves address space for `capacity` elements; commits nothing.
    // Releases any previous reservation first. Returns false on failure
    // (the array is then empty). A zero capacity reserves nothing and
    // succeeds.
    // `granule` is the commit/discard unit (a power of two >= the OS page);
    // kHugePageBytes also aligns the base to it (see the file comment).
    bool reserve(size_t capacity, size_t granule = kCommitChunkBytes) {
        release();
        if (capacity == 0) return true;
        if (granule < OS_PAGE_SIZE) granule = OS_PAGE_SIZE;
        const size_t bytes = roundUp(capacity * sizeof(T), granule);
        // Over-reserve by one granule so the usable base can be aligned.
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
        committed_ = 0;
        return true;
    }

    // Returns the whole reservation. Safe to call when nothing is reserved.
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
        committed_ = 0;
    }

    // Makes indices [0, n) addressable. Never moves data. Aborts if n
    // exceeds the capacity or the commit fails: callers cannot recover from
    // losing GC metadata, and a silently short table would corrupt later.
    void ensureCommitted(size_t n) {
        if (n <= committed_) return;
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
        committed_ = committed_bytes_ / sizeof(T);
        if (committed_ > capacity_) committed_ = capacity_;
    }

    // Zeroes elements [first, first+count) and returns the physical memory
    // of the OS pages wholly inside that range; partial edge pages are
    // zeroed with memset. The range stays committed and accessible.
    void discard(size_t first, size_t count) {
        if (count == 0) return;
        assert(first + count <= committed_);
        char* lo = reinterpret_cast<char*>(base_ + first);
        char* hi = reinterpret_cast<char*>(base_ + first + count);
        // Only whole granules are returned (never split a huge page).
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

    T& operator[](size_t i) {
        assert(i < committed_ && "ReservedArray index past committed prefix");
        return base_[i];
    }
    const T& operator[](size_t i) const {
        assert(i < committed_ && "ReservedArray index past committed prefix");
        return base_[i];
    }

    T* data() { return base_; }
    const T* data() const { return base_; }
    size_t capacity() const { return capacity_; }
    size_t committed() const { return committed_; }
    size_t reservedBytes() const { return reserved_bytes_; }
    size_t committedBytes() const { return committed_bytes_; }

private:
    static size_t roundUp(size_t v, size_t a) { return (v + a - 1) & ~(a - 1); }

    void* raw_base_ = nullptr;   // reservation as returned by the platform
    size_t raw_bytes_ = 0;
    size_t granule_ = OS_PAGE_SIZE;
    T* base_ = nullptr;
    size_t capacity_ = 0;
    size_t reserved_bytes_ = 0;
    size_t committed_bytes_ = 0;
    size_t committed_ = 0;
};

}  // namespace Elm

#endif  // ECO_RESERVEDARRAY_H
