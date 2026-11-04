#ifndef ECO_TIME_CTORS_HPP
#define ECO_TIME_CTORS_HPP

// Constructor tags of the heap values that elm/time's kernel exports build and its effect manager reads, defined
// once so the two sides cannot disagree: `TimeExports.cpp` builds the subscriptions and `TimeEffectManager.cpp`
// matches on them.

#include "allocator/Heap.hpp"

namespace Elm::Kernel::Time {

/// The constructor index of the `Every` subscription that `Time.setInterval` builds and the Time effect manager
/// matches on: field 0 is the interval in milliseconds (an unboxed Float), field 1 the `Posix -> msg` tagger.
inline constexpr u16 CTOR_TIME_EVERY = 0;

} // namespace Elm::Kernel::Time

#endif // ECO_TIME_CTORS_HPP
