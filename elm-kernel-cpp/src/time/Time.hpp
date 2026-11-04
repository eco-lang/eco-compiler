#ifndef ECO_TIME_HPP
#define ECO_TIME_HPP

// An unused C++ API for elm/time's kernel functions.
//
// Nothing calls the functions declared here. Compiled Elm code reaches elm/time through the C-linkage exports in
// `TimeExports.cpp` (`Time.now`, `Time.here`, `Time.getZoneName`, `Time.setInterval`), which do the work themselves
// and do not call into this namespace. Every function here is a stub: it fails an assertion, and in a build with
// `NDEBUG` defined, where the assertion is compiled out, it returns Unit.

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::Time {

/// Fails an assertion; with `NDEBUG` defined, returns Unit. Not implemented, and not called.
HPointer now();

/// Fails an assertion; with `NDEBUG` defined, returns Unit. Not implemented, and not called.
HPointer here();

/// Fails an assertion; with `NDEBUG` defined, returns Unit. Not implemented, and not called.
HPointer getZoneName();

/// Fails an assertion, ignoring both arguments; with `NDEBUG` defined, returns Unit. Not implemented, and not
/// called.
HPointer setInterval(f64 intervalMs, HPointer task);

} // namespace Elm::Kernel::Time

#endif // ECO_TIME_HPP
