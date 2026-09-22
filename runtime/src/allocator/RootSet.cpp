/**
 * RootSet Implementation.
 *
 * Simple implementation of the root set - a collection of pointer locations
 * that the GC must trace during collection. Thread-local, so no locking needed.
 *
 * Uses unordered_set for O(1) add/remove of long-lived roots.
 */

#include "RootSet.hpp"

#include <cstdio>
#include <cstdlib>
#include <new>

namespace Elm {

// The calling thread's shadow stack (plans/gc-root-registration-cost.md O1).
// constinit: no dynamic-initialization guard on a variable compiled code reads.
// See RootSet.hpp for why these three are the ONLY representation of the stack
// and why Allocator::setThreadHeap is their sole publisher.
extern "C" constinit thread_local StackRootRangeRec* eco_tl_root_sp
    __attribute__((tls_model("initial-exec"))) = nullptr;
extern "C" constinit thread_local StackRootRangeRec* eco_tl_root_base
    __attribute__((tls_model("initial-exec"))) = nullptr;
extern "C" constinit thread_local StackRootRangeRec* eco_tl_root_limit
    __attribute__((tls_model("initial-exec"))) = nullptr;

// Single-slot shadow stack (plan §3.3), same discipline.
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

// Allocates this thread's shadow-stack backing array. `Allocator::setThreadHeap`
// publishes base/limit/cursor into TLS; nothing else may.
RootSet::RootSet() {
    range_storage_ = static_cast<StackRootRangeRec*>(std::malloc(
        sizeof(StackRootRangeRec) * (kRootRangeStackSlots + kRootRangeStackSlack)));
    root1_storage_ = static_cast<HPointer**>(std::malloc(
        sizeof(HPointer*) * (kRoot1StackSlots + kRoot1StackSlack)));
    if (!range_storage_ || !root1_storage_)
        throw std::bad_alloc();
}

RootSet::~RootSet() {
    // A RootSet is destroyed with its thread heap, and `setThreadHeap(nullptr)`
    // has already unpublished the cursors by then; clear them defensively so a
    // stray push after teardown faults instead of writing freed memory.
    if (eco_tl_root_base == range_storage_) {
        eco_tl_root_sp = nullptr;
        eco_tl_root_base = nullptr;
        eco_tl_root_limit = nullptr;
        eco_tl_root1_sp = nullptr;
        eco_tl_root1_base = nullptr;
        eco_tl_root1_limit = nullptr;
    }
    std::free(range_storage_);
    std::free(root1_storage_);
    range_storage_ = nullptr;
    root1_storage_ = nullptr;
}

// Registers a pointer location as a GC root. O(1) average.
void RootSet::addRoot(HPointer *root) {
    roots.insert(root);
}

// Unregisters a pointer location from the root set. O(1) average.
void RootSet::removeRoot(HPointer *root) {
    roots.erase(root);
}

// Registers a JIT root (raw 64-bit pointer location). O(1) average.
void RootSet::addJitRoot(uint64_t *root) {
    jit_roots.insert(root);
}

// Unregisters a JIT root. O(1) average.
void RootSet::removeJitRoot(uint64_t *root) {
    jit_roots.erase(root);
}

// Registers an external root scanner callback.
void RootSet::addExternalRootScanner(ExternalRootScanner scanner) {
    external_scanners.push_back(std::move(scanner));
}

// Clears all roots. Used for testing.
void RootSet::reset() {
    roots.clear();
    jit_roots.clear();
    if (eco_tl_root_base == range_storage_) {
        eco_tl_root_sp = eco_tl_root_base;
        eco_tl_root1_sp = eco_tl_root1_base;
    }
    external_scanners.clear();
}

} // namespace Elm
