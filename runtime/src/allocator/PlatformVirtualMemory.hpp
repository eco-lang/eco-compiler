/**
 * Platform abstraction for the small slice of virtual-memory primitives the
 * eco allocator uses: reserve a large contiguous address range with no
 * backing, then commit subranges at fixed addresses as the heap grows, and
 * release the whole reservation at teardown.
 *
 * On POSIX (Linux + Darwin) this is mmap(PROT_NONE) for reserve and
 * mmap(MAP_FIXED, PROT_READ|PROT_WRITE) for commit.
 *
 * On Win64 this is VirtualAlloc(MEM_RESERVE, PAGE_NOACCESS) for reserve and
 * VirtualAlloc(addr, MEM_COMMIT, PAGE_READWRITE) for commit — Windows
 * supports committing arbitrary subranges of a reservation, so the heap
 * model maps 1:1 (verified by experiments/win-jit-smoke/, the E-W2 spike).
 *
 * The functions return a tri-state: nullptr on failure (so call sites can
 * keep their existing MAP_FAILED-style branches almost unchanged), the
 * platform's failure sentinel is converted to nullptr inside the
 * implementation. The contract is that the returned address equals the
 * requested address on success for fixed commits, just like POSIX
 * MAP_FIXED.
 */
#pragma once

#include <cstddef>
#include <cstdint>

namespace Elm::platform {

// Reserve `size` bytes of address space starting at any address. The returned
// region is unbacked (PROT_NONE / PAGE_NOACCESS) and must be committed in
// subranges before use. Returns nullptr on failure.
void* reserveAddressSpace(std::size_t size);

// Reserve `size` bytes of address space placed entirely below `limit` — that
// is, the returned base `b` satisfies `b + size <= limit`. Probes a series of
// low candidate bases and verifies placement, falling back to a kernel-chosen
// address only if it happens to fit. Returns nullptr if no fitting region
// could be reserved. Used by the HPointer representation, which stores raw
// absolute heap addresses in the low bits of a 64-bit word and therefore
// requires the whole heap to live below 2^43 (8 TB). The region is unbacked
// (PROT_NONE / PAGE_NOACCESS), same as reserveAddressSpace.
void* reserveAddressSpaceBelow(std::size_t size, std::uintptr_t limit);

// Commit a subrange of an existing reservation. `addr` must be inside a
// previous reservation and the [addr, addr+size) range must lie wholly
// within it. Returns `addr` on success, nullptr on failure. The committed
// pages are PROT_READ|PROT_WRITE / PAGE_READWRITE.
void* commitAt(void* addr, std::size_t size);

// Decommit a subrange — the address space stays reserved, the pages become
// unbacked again. Returns true on success.
bool decommit(void* addr, std::size_t size);

// Zero a committed, page-aligned subrange and return its physical memory to
// the OS, keeping the pages committed and read/write (they fault back in as
// zero pages on the next touch). Unlike `decommit`, the range stays
// accessible. POSIX: a fresh MAP_FIXED anonymous RW mapping over the range
// (portable: Darwin's MADV_DONTNEED does not guarantee zeros). Win64:
// MEM_DECOMMIT then MEM_COMMIT. `addr` and `size` must be OS-page aligned.
// Returns true on success. (threaded-gc-01: ReservedArray::discard.)
bool resetPagesToZero(void* addr, std::size_t size);

// threaded-gc-03 (PageWork's ops). discardPages: drop the physical pages of a
// committed RW range, keeping it mapped (POSIX madvise(MADV_DONTNEED): the
// range reads as zero afterwards on Linux; Win64: a no-op returning true, the
// parity of Allocator.cpp's madvise stub). populatePagesWrite: fault the
// range in writable without touching its contents (Linux >= 5.14
// MADV_POPULATE_WRITE); returns false where unsupported, and callers must not
// fall back to touching pages.
bool discardPages(void* addr, std::size_t size);
bool populatePagesWrite(void* addr, std::size_t size);

// The process's resident set size in bytes, for observations only (GCReport
// rss_*, plans/frontend-heap-release.md §3.2; no GC decision may read it,
// HEAP_076). Linux: field 2 of /proc/self/statm times the page size. Other
// platforms: 0 (unavailable).
std::size_t processResidentBytes();

// Release a whole reservation (must be the same `addr` that was returned by
// reserveAddressSpace; `size` is the originally-requested size on POSIX,
// ignored on Windows where MEM_RELEASE keys on the reservation base).
// Returns true on success.
bool releaseReservation(void* addr, std::size_t size);

} // namespace Elm::platform
