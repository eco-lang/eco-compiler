//===- Runtime.hpp - Eco.Runtime kernel module ----------------------------===//
//
// The kernel side of the Elm module `Eco.Runtime`: a few facts and services of the running process that Elm code
// cannot get any other way. They are the directory holding the executable, a random Float, and a single saved
// value that lives in this process's memory and nowhere else.
//
// Each of `dirname`, `random`, `saveState` and `loadState` returns a Task, as the encoded 64-bit word of the kernel
// ABI, and does no IO when called. The work happens each time the scheduler runs the Task, through a
// binding body (`Eco::Kernel::makeBinding`), so running one Task twice reads the directory twice, draws two random
// numbers, or stores twice.
//
// The saved value is held in a C++ static, outside the heap's reach, so the collector would neither keep it alive
// nor update it when it moves. `registerGcRootScanner` adds a root scanner that does both.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_RUNTIME_HPP
#define ECO_RUNTIME_HPP

#include <cstdint>

namespace Eco::Kernel::Runtime {

/// Returns a Task that succeeds with the String the runtime's `eco::platform::currentExecutableDir` gives: the
/// executable's path up to its last '/', or "." for a path with no '/'. It fails with the IO error tuple for
/// `ENOENT` (IO_ERR_002, read by `Eco.Runtime.dirname` as an `IOError`) when that String is empty, which includes an
/// executable directly under "/". A GC point.
uint64_t dirname();

/// Returns a Task that succeeds with a Float drawn uniformly from [0, 1), a new one each time the Task is run. The
/// draws come from one `std::mt19937_64` per process, seeded from `std::random_device` on the first draw. A GC
/// point.
uint64_t random();

/// Returns a Task that, when run, makes the value in the encoded word `state` the saved state, replacing any earlier
/// one, and succeeds with Unit. While the Task is reachable, it keeps `state` reachable. Once the Task has run, the
/// saved value survives collections because running the Task registers the root scanner if this heap generation has
/// none yet. A GC point.
uint64_t saveState(uint64_t state);

/// Returns a Task that succeeds with the value most recently saved by a run of a `saveState` Task, as it was given
/// and not wrapped in a `Maybe`. When none has run since the heap was last reset, it succeeds with JSON `null` (the
/// `Json.Encode.null` value) instead. A GC point.
uint64_t loadState();

/// Adds to the allocator's root set a scanner that keeps the saved state alive and updates it when the collector
/// moves it, unless one was already added in the current heap generation. A heap reset (tests only) loses the
/// scanner with the old root set, and the next call, or the next run of a `saveState` Task, adds it again.
void registerGcRootScanner();

} // namespace Eco::Kernel::Runtime

#endif // ECO_RUNTIME_HPP
