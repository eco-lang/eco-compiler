#pragma once

// A process that forks while another thread holds a runtime lock gives its child a copy of that lock
// still held, by a thread the child does not have. This component makes the locks of every registered
// fork layer safe across `fork()` by taking them before the fork and releasing or rebuilding them
// after it.
//
// It is the runtime's one `pthread_atfork` registration. Each lock-holding part of the runtime
// supplies its handlers as a fork layer: a `ForkHooks` slot at a fixed index in `ForkLayer`. Before
// a fork, the layers' `prepare` handlers run in increasing index order, so the locks are taken in
// that order. After it, the `parent` handlers (in the parent) or the `child` handlers (in the child)
// run in decreasing index order. The order is set by the indices, not by the order in which the
// layers register, so the lock order does not depend on which part of the runtime starts first.
//
// The prepare lock order this gives, which the TLA+ model M7's `LockOrder` checks, is:
//   gang registry -> each background gang's `m_` (and `fork_hold_`) -> stopAllForFork
//     -> each background gang's `m_` held -> mark gang `run_m_` -> mark gang `m_`
//     -> `Allocator::thread_mutex_` -> P1 census mutex -> helper pool `m_` (drained under it)
//
// The component includes no allocator header, so it can be built on its own, as `GCHelperPool` is.
// On Windows nothing is registered with the system and the hooks are never called.

namespace Elm::gc {

/// The fork layers, in the order their locks are taken before a fork.
///
/// The values are slot indices and their order is the lock order, so they must not be reordered.
/// `kForkLayers` is the number of layers, not a layer.
enum ForkLayer : unsigned {
    kForkGangs = 0,       // GCBackgroundGang registry + gangs (hold, stop, lock), then GCMarkGang
    kForkAllocator = 1,   // Allocator::thread_mutex_
    kForkCensus = 2,      // the validate-only P1 census mutex (a leaf)
    kForkPool = 3,        // GCHelperPool::m_, drained and held (the innermost leaf)
    kForkLayers = 4
};

/// The three handlers one fork layer supplies, as `pthread_atfork` defines them.
///
/// `prepare` runs in the forking thread before the fork and takes the layer's locks. `parent` runs
/// in the parent after the fork and releases them. `child` runs in the child's only thread after
/// the fork and releases or re-creates them. All three are called without a null check, so none
/// may be null.
struct ForkHooks {
    void (*prepare)();
    void (*parent)();
    void (*child)();
};

/// Installs `hooks` as the handlers of `layer`, replacing any installed before.
///
/// The first call in the process registers this component's handlers with `pthread_atfork`; later
/// calls only store the pointer. `hooks` is kept, so it must live until the process ends (a static,
/// in practice). `layer` must be less than `kForkLayers`, which is not checked. A layer installed
/// after a fork's prepare handler has passed its index is first used by the next fork.
///
/// The first call takes the C library's atfork lock. No handler of this component exists before
/// it, so a concurrent fork cannot be waiting on a runtime lock the caller holds; even so, the
/// call is best made with no runtime lock held.
void registerForkLayer(ForkLayer layer, const ForkHooks& hooks);

} // namespace Elm::gc
