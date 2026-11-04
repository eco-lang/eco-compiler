//===- AsyncSources.hpp - The single eco/system scheduler async source ----===//
//
// eco/system has many services that finish work outside the eco thread (the work pool, channels, signals,
// sockets and others), and each needs the Scheduler to call it back when that work is ready. This component
// gives them one shared async source instead of one Scheduler registration each.
//
// A service adds a drain source: a drain, which the Scheduler's loop calls to deliver finished work, and a
// ready predicate, which says whether the drain has work. The first `addDrainSource` or `ensureAsyncSource`
// registers one source with the Scheduler (`Scheduler::registerAsyncSource`). Its drain runs every drain
// source in the order added, and its ready predicate is true when any drain source's predicate is.
//
// The drain source list has no lock: it is read and changed on the eco thread only. A drain may add a drain
// source while the list is being run; the new one runs later in the same pass. The list is never destroyed,
// so a drain or predicate called during process exit still finds it.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_ASYNC_SOURCES_HPP
#define ECO_SYSTEM_CORE_ASYNC_SOURCES_HPP

namespace Eco::System {

/// A drain: delivers whatever work its service has finished. Called on the eco thread on every pass of the
/// Scheduler's loop, whether or not any ready predicate returned true, so it may find no work.
using DrainFn = void (*)();
/// A ready predicate: returns whether its drain has work to deliver. The Scheduler calls it with the
/// Scheduler's lock held, so it must not block and must not call into the Scheduler. It may take a lock of its
/// own service.
using ReadyFn = bool (*)();

/// Registers the eco/system async source with the Scheduler, the first time it is called from any thread;
/// later calls do nothing.
void ensureAsyncSource();

/// Adds the drain source `drain` with predicate `ready`, first calling `ensureAsyncSource`. If `drain` was
/// already added, does nothing, and the `ready` of the earlier call stays in use. Must be called on the eco
/// thread.
void addDrainSource(DrainFn drain, ReadyFn ready);

/// Calls every added drain once, in the order added, including any added by a drain during this call. This is
/// the drain of the source `ensureAsyncSource` registers. Must be called on the eco thread.
void runDrainSources();

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_ASYNC_SOURCES_HPP
