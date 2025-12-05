#ifndef ELM_KERNEL_TIME_HPP
#define ELM_KERNEL_TIME_HPP

/**
 * Elm Kernel Time Module - Runtime Heap Integration
 *
 * Provides time-related operations using GC-managed heap values.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "../core/Scheduler.hpp"

namespace Elm::Kernel::Time {

using TaskPtr = Scheduler::TaskPtr;

/**
 * Get current time as Posix (milliseconds since epoch).
 */
TaskPtr now();

/**
 * Get local timezone offset.
 */
TaskPtr here();

/**
 * Get timezone name.
 */
TaskPtr getZoneName();

/**
 * Set up repeating interval timer.
 */
TaskPtr setInterval(f64 intervalMs, TaskPtr task);

} // namespace Elm::Kernel::Time

#endif // ELM_KERNEL_TIME_HPP
