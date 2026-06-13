// POSIX (Linux + Darwin) implementation of the small VM primitives the
// allocator uses. See PlatformVirtualMemory.hpp for the contract.

#include "PlatformVirtualMemory.hpp"

#include <sys/mman.h>

// Darwin has no MAP_NORESERVE — its VM never reserves swap for PROT_NONE
// mappings, so the flag's effect is the default behavior there.
#ifndef MAP_NORESERVE
#define MAP_NORESERVE 0
#endif

namespace Elm::platform {

void* reserveAddressSpace(std::size_t size) {
    void* p = mmap(nullptr, size, PROT_NONE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE,
                   -1, 0);
    return p == MAP_FAILED ? nullptr : p;
}

void* commitAt(void* addr, std::size_t size) {
    void* p = mmap(addr, size, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                   -1, 0);
    return p == MAP_FAILED ? nullptr : p;
}

bool decommit(void* addr, std::size_t size) {
    // Re-map as PROT_NONE so the pages are unbacked but the address space is
    // still reserved (a fresh PROT_READ|PROT_WRITE commit at the same addr
    // will succeed).
    void* p = mmap(addr, size, PROT_NONE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED | MAP_NORESERVE,
                   -1, 0);
    return p != MAP_FAILED;
}

bool releaseReservation(void* addr, std::size_t size) {
    return munmap(addr, size) == 0;
}

} // namespace Elm::platform
