// Win64 implementation of the small VM primitives the allocator uses.
// See PlatformVirtualMemory.hpp for the contract.
//
// The reserve / commit-subrange / decommit / release pattern was verified
// against the eco mmap model by experiments/win-jit-smoke/ (E-W2 spike).

#include "PlatformVirtualMemory.hpp"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

namespace Elm::platform {

void* reserveAddressSpace(std::size_t size) {
    return VirtualAlloc(nullptr, size, MEM_RESERVE, PAGE_NOACCESS);
}

void* commitAt(void* addr, std::size_t size) {
    // VirtualAlloc with MEM_COMMIT and an address inside an existing
    // reservation commits the subrange and returns the same address. If the
    // address isn't inside a reservation it returns nullptr — same failure
    // shape as POSIX MAP_FAILED gets translated to.
    return VirtualAlloc(addr, size, MEM_COMMIT, PAGE_READWRITE);
}

bool decommit(void* addr, std::size_t size) {
    return VirtualFree(addr, size, MEM_DECOMMIT) != 0;
}

bool releaseReservation(void* addr, std::size_t /*size*/) {
    // MEM_RELEASE requires size == 0 and releases the entire reservation
    // identified by `addr`. POSIX munmap takes a size; we accept it for
    // symmetry but ignore it.
    return VirtualFree(addr, 0, MEM_RELEASE) != 0;
}

} // namespace Elm::platform
