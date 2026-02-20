#ifndef ECO_TIME_HPP
#define ECO_TIME_HPP

/**
 * Elm Kernel Time Module - Runtime Heap Integration
 *
 * Provides time-related operations using GC-managed heap values.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::Time {

/**
 * Get current time as Posix (milliseconds since epoch).
 */
HPointer now();

/**
 * Get local timezone offset.
 */
HPointer here();

/**
 * Get timezone name.
 */
HPointer getZoneName();

/**
 * Set up repeating interval timer.
 */
HPointer setInterval(f64 intervalMs, HPointer task);

} // namespace Elm::Kernel::Time

#endif // ECO_TIME_HPP
