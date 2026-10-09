#pragma once

// plans/region-nursery-everywhere.md Phase 2: every Elm program the test
// harness runs must run the production nursery (the region nursery,
// HEAP_069). Until 2026-10-09 every E2E child silently inherited the legacy
// nursery that the in-process unit tests had installed; this guard turns
// that class of mistake into a test failure.
//
// The one exception is an explicit request for legacy through the
// environment (ECO_NURSERY_REGIONS=0, or nursery_regions 0 in the
// $ECO_HEAP_CONFIG JSON): the explicit legacy validate arm.

#include "../runtime/src/allocator/Allocator.hpp"
#include "../runtime/src/allocator/AllocatorCommon.hpp"
#include "../runtime/src/allocator/HeapConfigJson.hpp"

#include <cstdlib>
#include <stdexcept>
#include <string>

namespace eco_test {

// True when the environment explicitly asks for the legacy nursery.
inline bool environmentRequestsLegacyNursery() {
    Elm::HeapConfig c;
    Elm::applyHeapConfigFromEnv(c);
    Elm::applyRegionEnv(c, std::getenv("ECO_NURSERY_REGIONS"), nullptr, nullptr);
    return c.nursery_regions == 0;
}

// Throws unless the current heap runs the region nursery (or the
// environment explicitly asked for legacy). Call right after
// EcoRunner::reset().
inline void requireRegionNursery() {
    const uint32_t regions = Elm::Allocator::instance().getConfig().nursery_regions;
    if (regions == 1 || environmentRequestsLegacyNursery()) return;
    throw std::runtime_error(
        "E2E child is not on the region nursery (nursery_regions = " + std::to_string(regions) +
        "): EcoRunner::reset() must install Allocator::environmentConfig() "
        "(plans/region-nursery-everywhere.md Phase 2)");
}

} // namespace eco_test
