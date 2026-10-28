
#include "RootSet.hpp"
#if !defined(_WIN32)
#include <dlfcn.h>
#endif
#include <string>
#include <deque>
#include <cstring>

#include <cstdio>
#include <cstdlib>
#include <new>

#include "PlatformVirtualMemory.hpp"

namespace Elm {

// `constinit` keeps these free of a dynamic-initialisation guard, which compiled code, reading them by
// name, would not run.
extern "C" constinit thread_local StackRootRangeRec* eco_tl_root_sp
    __attribute__((tls_model("initial-exec"))) = nullptr;
extern "C" constinit thread_local StackRootRangeRec* eco_tl_root_base
    __attribute__((tls_model("initial-exec"))) = nullptr;
extern "C" constinit thread_local StackRootRangeRec* eco_tl_root_limit
    __attribute__((tls_model("initial-exec"))) = nullptr;

extern "C" constinit thread_local HPointer** eco_tl_root1_sp
    __attribute__((tls_model("initial-exec"))) = nullptr;
extern "C" constinit thread_local HPointer** eco_tl_root1_base
    __attribute__((tls_model("initial-exec"))) = nullptr;
extern "C" constinit thread_local HPointer** eco_tl_root1_limit
    __attribute__((tls_model("initial-exec"))) = nullptr;

[[noreturn]] void ecoRootStackOverflow(std::size_t depth) {
    std::fprintf(stderr,
                 "[eco] FATAL: GC shadow root stack overflow at depth %zu "
                 "(capacity %zu). Raise kRootRangeStackSlots in RootSet.hpp, or "
                 "find the unbalanced push.\n",
                 depth, kRootRangeStackSlots);
    std::abort();
}

// Returns `bytes` rounded up to a whole number of pages: the accessible part of a guarded mapping.
static std::size_t guardedBody(std::size_t bytes) {
    return (bytes + OS_PAGE_SIZE - 1) / OS_PAGE_SIZE * OS_PAGE_SIZE;
}

// Returns the size of a guarded mapping of `bytes`: its accessible part plus one guard page.
static std::size_t guardedSize(std::size_t bytes) {
    return guardedBody(bytes) + OS_PAGE_SIZE;
}

// Maps at least `bytes` of read-write memory followed by one inaccessible guard page, and returns its start.
// The whole range is reserved and only the accessible part committed, so the page after it stays
// inaccessible. Throws `std::bad_alloc`, leaving nothing mapped, if either step fails.
static void* mapGuarded(std::size_t bytes) {
    const std::size_t total = guardedSize(bytes);
    void* p = platform::reserveAddressSpace(total);
    if (p == nullptr) throw std::bad_alloc();
    if (platform::commitAt(p, guardedBody(bytes)) != p) {
        platform::releaseReservation(p, total);
        throw std::bad_alloc();
    }
    return p;
}

// Releases a mapping that `mapGuarded(bytes)` returned as `p`.
static void unmapGuarded(void* p, std::size_t bytes) {
    platform::releaseReservation(p, guardedSize(bytes));
}

// The bytes of the range-stack array, slack included.
static constexpr std::size_t kRangeBytes =
    sizeof(StackRootRangeRec) * (kRootRangeStackSlots + kRootRangeStackSlack);
// The bytes of the single-slot-stack array, slack included.
static constexpr std::size_t kRoot1Bytes =
    sizeof(HPointer*) * (kRoot1StackSlots + kRoot1StackSlack);

RootSet::RootSet() {
    range_storage_ = static_cast<StackRootRangeRec*>(mapGuarded(kRangeBytes));
    try {
        root1_storage_ = static_cast<HPointer**>(mapGuarded(kRoot1Bytes));
    } catch (...) {
        unmapGuarded(range_storage_, kRangeBytes);
        throw;
    }
}

RootSet::~RootSet() {
    // Clearing the TLS words keeps a push after teardown from writing into unmapped memory: in an unchecked
    // build it faults on a null cursor, and with the bounds check it reports an overflow at depth 0.
    if (eco_tl_root_base == range_storage_) {
        eco_tl_root_sp = nullptr;
        eco_tl_root_base = nullptr;
        eco_tl_root_limit = nullptr;
        eco_tl_root1_sp = nullptr;
        eco_tl_root1_base = nullptr;
        eco_tl_root1_limit = nullptr;
    }
    if (range_storage_) unmapGuarded(range_storage_, kRangeBytes);
    if (root1_storage_) unmapGuarded(root1_storage_, kRoot1Bytes);
    range_storage_ = nullptr;
    root1_storage_ = nullptr;
}

void RootSet::addRoot(HPointer *root) {
    roots.insert(root);
}

void RootSet::removeRoot(HPointer *root) {
    roots.erase(root);
}

void RootSet::addJitRoot(uint64_t *root) {
    jit_roots.insert(root);
}

void RootSet::removeJitRoot(uint64_t *root) {
    jit_roots.erase(root);
}

// Returns a label for a scanner registered from `caller`, a return address: `unnamed@` followed by the
// symbol `dladdr` finds for it, or else its offset within the loaded object, or else the address itself
// (always the address on Windows). Each label is kept in a list that is never freed, so it has static
// lifetime; a new one is made on every call.
static const char* labelForUnnamedScanner(void* caller) {
    static std::deque<std::string>* owned = new std::deque<std::string>();
    char buf[256];
#if defined(_WIN32)
    // No dladdr: label by address only.
    std::snprintf(buf, sizeof buf, "unnamed@%p", caller);
#else
    Dl_info info{};
    if (caller && dladdr(caller, &info) && info.dli_sname) {
        std::snprintf(buf, sizeof buf, "unnamed@%s", info.dli_sname);
    } else if (caller && info.dli_fbase) {
        std::snprintf(buf, sizeof buf, "unnamed@+0x%lx",
                      (unsigned long)(reinterpret_cast<uintptr_t>(caller) -
                                      reinterpret_cast<uintptr_t>(info.dli_fbase)));
    } else {
        std::snprintf(buf, sizeof buf, "unnamed@%p", caller);
    }
#endif
    owned->emplace_back(buf);
    return owned->back().c_str();
}

void RootSet::addExternalRootScanner(ExternalRootScanner scanner, const char* name) {
    external_scanners.push_back(std::move(scanner));
    if (name == nullptr || std::strcmp(name, "unnamed") == 0) {
        name = labelForUnnamedScanner(__builtin_return_address(0));
    }
    external_scanner_names.push_back(name);
}

void RootSet::reset() {
    roots.clear();
    jit_roots.clear();
    if (eco_tl_root_base == range_storage_) {
        eco_tl_root_sp = eco_tl_root_base;
        eco_tl_root1_sp = eco_tl_root1_base;
    }
    external_scanners.clear();
    external_scanner_names.clear();
}

} // namespace Elm
