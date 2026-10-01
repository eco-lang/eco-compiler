#pragma once

// plans/threaded-gc-register-fixes.md §7.1 (HEAP_075 ForkSafety): the runtime's ONE
// pthread_atfork registration. Every runtime lock a fork must hold across fork() belongs
// to a layer; the prepare handler runs the layers in increasing order (taking their
// locks), the parent and child handlers run them in decreasing order (releasing /
// re-creating). The order is fixed here, not by registration order (glibc runs prepare
// handlers in REVERSE registration order, which made the old three registrations'
// order depend on which object happened to be configured first).
//
// Prepare lock order (checked by M6 and M7 LockOrder):
//   registry -> each background gang's m_ (+ fork_hold_) -> stopAllForFork
//     -> each background gang's m_ held -> mark gang run_m_ -> mark gang m_
//     -> Allocator::thread_mutex_ -> P1 census mu -> helper pool m_ (drained under it)
//
// Standalone like GCHelperPool.{hpp,cpp} (HEAP_058's include-graph rule): no allocator
// includes, so the TSan harnesses build it alone.

namespace Elm::gc {

enum ForkLayer : unsigned {
    kForkGangs = 0,       // GCBackgroundGang registry + gangs (hold, stop, lock), then GCMarkGang
    kForkAllocator = 1,   // Allocator::thread_mutex_
    kForkCensus = 2,      // the validate-only P1 census mutex (a leaf)
    kForkPool = 3,        // GCHelperPool::m_, drained and held (the innermost leaf)
    kForkLayers = 4
};

struct ForkHooks {
    void (*prepare)();
    void (*parent)();
    void (*child)();
};

// Idempotent; the first call (any layer) runs pthread_atfork once (std::call_once).
// `hooks` must outlive the process (a static). Prefer calling it with no runtime lock
// held. The first call takes glibc's atfork lock, but it runs before any GCFork
// handler exists, so a concurrent fork's prepare cannot be waiting for one of our
// locks then; every later call is an atomic store.
void registerForkLayer(ForkLayer layer, const ForkHooks& hooks);

} // namespace Elm::gc
