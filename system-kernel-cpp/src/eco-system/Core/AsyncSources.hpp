//===- AsyncSources.hpp - The single eco/system scheduler async source ----===//
//
// eco/system registers exactly ONE async source with the Scheduler
// (std::call_once, F3) and multiplexes every Core drain (pool, channels,
// signals) and any later eco/system drain through it.
//
// Why one: Scheduler::processReadyAsync iterates its source vector with a
// range-for, so a registerAsyncSource call made while a drain runs (a drain
// that resumes a task, then drain()s, then steps a binding that registers a
// new source) would invalidate that iteration. Our own list is iterated by
// index, so adding a source from inside one of our drains is safe.
//
// Main thread only (G1). The ready predicates must be cheap and lock-free:
// the Scheduler evaluates them while holding its own mutex.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_ASYNC_SOURCES_HPP
#define ECO_SYSTEM_CORE_ASYNC_SOURCES_HPP

namespace Eco::System {

using DrainFn = void (*)();
using ReadyFn = bool (*)();

// Registers the eco/system async source with the Scheduler (once).
void ensureAsyncSource();

// Adds a drain to the eco/system source (and ensures the source). Adding the
// same `drain` twice is a no-op. Main thread only.
void addDrainSource(DrainFn drain, ReadyFn ready);

// Runs every registered drain once (what the Scheduler calls). Exposed for
// tests that drive the drains without the event loop.
void runDrainSources();

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_ASYNC_SOURCES_HPP
