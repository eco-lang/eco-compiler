// POSIX (Linux + Darwin) implementation of the small VM primitives the
// allocator uses. See PlatformVirtualMemory.hpp for the contract.

#include "PlatformVirtualMemory.hpp"

#include <cstdint>
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

void* reserveAddressSpaceBelow(std::size_t size, std::uintptr_t limit) {
    if (size == 0 || size > limit) return nullptr;

    // Probe low candidate bases, stepping by 1 TB. On Linux MAP_FIXED_NOREPLACE
    // makes mmap fail (rather than relocate) if the requested range is taken.
    // macOS lacks it, so we pass the hint without MAP_FIXED and verify that the
    // kernel actually honored it; if not, we unmap and try the next candidate.
    constexpr std::uintptr_t kStep = 0x0000'0100'0000'0000ULL;  // 1 TB
#ifdef MAP_FIXED_NOREPLACE
    constexpr int kFixed = MAP_FIXED_NOREPLACE;
#else
    constexpr int kFixed = 0;
#endif
    const int kBaseFlags = MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE;

    for (std::uintptr_t base = kStep; base + size <= limit; base += kStep) {
        void* hint = reinterpret_cast<void*>(base);
        void* p = mmap(hint, size, PROT_NONE, kBaseFlags | kFixed, -1, 0);
        if (p == MAP_FAILED) continue;
        std::uintptr_t got = reinterpret_cast<std::uintptr_t>(p);
        if (got == base && got + size <= limit) {
            return p;  // placed exactly where asked, and fits
        }
        munmap(p, size);  // kernel ignored the hint or placed it too high
    }

    // Last resort: let the kernel choose, accept only if it happens to fit.
    void* p = mmap(nullptr, size, PROT_NONE, kBaseFlags, -1, 0);
    if (p == MAP_FAILED) return nullptr;
    if (reinterpret_cast<std::uintptr_t>(p) + size <= limit) return p;
    munmap(p, size);
    return nullptr;
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
