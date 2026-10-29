// The allocator needs a heap whose addresses never move, and that grows and shrinks
// in physical memory without moving. This component is the operating-system
// virtual-memory calls that make that possible, with one implementation for POSIX
// (Linux and Darwin) and one for Win64 behind the same functions.
//
// Two ideas run through it. To *reserve* a range is to claim addresses only: no
// memory backs them and any access faults. To *commit* a subrange of a reservation
// is to make it readable and writable at the address it already has. A heap is
// therefore reserved once at its full size, committed piece by piece as it grows,
// and released as a whole at the end.
//
// On POSIX a reservation is an anonymous `mmap` with `PROT_NONE`, and a commit is
// a fresh `MAP_FIXED` read/write mapping over part of it. On Win64 they are
// `VirtualAlloc` with `MEM_RESERVE` / `PAGE_NOACCESS` and with `MEM_COMMIT` /
// `PAGE_READWRITE` at an address inside the reservation.
//
// Failure is reported the same way on both platforms: a function returning a
// pointer returns `nullptr`, and one returning `bool` returns false. No error code
// is kept.
#pragma once

#include <cstddef>
#include <cstdint>

namespace Elm::platform {

// Reserves `size` bytes of address space at an address the OS chooses, and
// returns its base, or `nullptr` on failure. The range is not accessible until
// subranges of it are committed with `commitAt`.
void* reserveAddressSpace(std::size_t size);

// Reserves `size` bytes of address space and returns its base `b`, or `nullptr`
// if `size` is zero, exceeds `limit`, or no fitting range could be reserved.
// Except in ThreadSanitizer builds with `limit` below 512 GB, `b + size <= limit`.
//
// It tries bases at multiples of 1 TB from 1 TB upwards (after, under
// ThreadSanitizer, 64 GB steps below 512 GB), then accepts an OS-chosen address
// only if it happens to fit. Like `reserveAddressSpace`, the range is not
// accessible until committed.
void* reserveAddressSpaceBelow(std::size_t size, std::uintptr_t limit);

// Makes `[addr, addr + size)` readable and writable, and returns `addr`, or
// `nullptr` on failure. The range must lie wholly within one reservation, and
// `addr` and `size` must be multiples of the OS page size.
//
// On POSIX this maps fresh zero pages over the range, so committing a range that
// is already committed discards its contents. On Win64 committing it again keeps
// them.
void* commitAt(void* addr, std::size_t size);

// Returns `[addr, addr + size)` to the reserved state: it stays claimed, its
// memory is given back, and any access faults until it is committed again.
// Returns true on success.
bool decommit(void* addr, std::size_t size);

// Gives the memory of a committed range back to the OS and leaves the range
// committed, readable and writable, reading as zero. Unlike `decommit`, the
// range stays accessible. `addr` and `size` must be multiples of the OS page
// size. Returns true on success.
bool resetPagesToZero(void* addr, std::size_t size);

// Asks the OS to drop the memory behind a committed range, keeping the range
// mapped, and returns true on success. On POSIX this is
// `madvise(MADV_DONTNEED)`; on Linux the range then reads as zero, but on other
// systems its contents are not specified. On Win64 it does nothing and returns
// true, so the contents are kept.
bool discardPages(void* addr, std::size_t size);

// Faults a committed range into memory as writable without changing its
// contents, and returns true on success. Only Linux supports it, through
// `madvise(MADV_POPULATE_WRITE)`, which kernels older than 5.14 refuse; anywhere
// else, and on such kernels, it returns false.
bool populatePagesWrite(void* addr, std::size_t size);

// Returns the process's resident set size in bytes: on Linux, the second field
// of `/proc/self/statm` times the page size. Returns 0 on other platforms, or if
// the file cannot be read.
std::size_t processResidentBytes();

// Releases a whole reservation, committed parts included, and returns true on
// success. `addr` must be the base a reserve function returned and `size` the
// size that was requested. Win64 ignores `size` and releases the whole
// reservation at `addr`; POSIX unmaps exactly `[addr, addr + size)`.
bool releaseReservation(void* addr, std::size_t size);

} // namespace Elm::platform
