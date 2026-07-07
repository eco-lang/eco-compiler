// Win64 implementation of the small VM primitives the allocator uses.
// See PlatformVirtualMemory.hpp for the contract.
//
// The reserve / commit-subrange / decommit / release pattern was verified
// against the eco mmap model by experiments/win-jit-smoke/ (E-W2 spike).

#include "PlatformVirtualMemory.hpp"

#include <cstdint>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

namespace Elm::platform {

void* reserveAddressSpace(std::size_t size) {
    return VirtualAlloc(nullptr, size, MEM_RESERVE, PAGE_NOACCESS);
}

void* reserveAddressSpaceBelow(std::size_t size, std::uintptr_t limit) {
    if (size == 0 || size > limit) return nullptr;

    // Probe low candidate bases, stepping by 1 TB. VirtualAlloc with an
    // explicit base reserves there (rounded to the 64 KB allocation
    // granularity) or returns nullptr if the range is taken.
    constexpr std::uintptr_t kStep = 0x0000'0100'0000'0000ULL;  // 1 TB
    for (std::uintptr_t base = kStep; base + size <= limit; base += kStep) {
        void* p = VirtualAlloc(reinterpret_cast<void*>(base), size,
                               MEM_RESERVE, PAGE_NOACCESS);
        if (p == nullptr) continue;
        if (reinterpret_cast<std::uintptr_t>(p) + size <= limit) return p;
        VirtualFree(p, 0, MEM_RELEASE);
    }

    // Last resort: let the OS choose, accept only if it happens to fit.
    void* p = VirtualAlloc(nullptr, size, MEM_RESERVE, PAGE_NOACCESS);
    if (p == nullptr) return nullptr;
    if (reinterpret_cast<std::uintptr_t>(p) + size <= limit) return p;
    VirtualFree(p, 0, MEM_RELEASE);
    return nullptr;
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
