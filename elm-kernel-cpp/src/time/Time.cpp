/**
 * Elm Kernel Time Module - Runtime Heap Integration
 *
 * Provides time-related operations using GC-managed heap values.
 */

#include "Time.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"
#include <cassert>

namespace Elm::Kernel::Time {

HPointer now() {
    assert(false && "not implemented");
    return alloc::unit();
}

HPointer here() {
    assert(false && "not implemented");
    return alloc::unit();
}

HPointer getZoneName() {
    assert(false && "not implemented");
    return alloc::unit();
}

HPointer setInterval(f64 intervalMs, HPointer task) {
    (void)intervalMs;
    (void)task;
    assert(false && "not implemented");
    return alloc::unit();
}

} // namespace Elm::Kernel::Time
