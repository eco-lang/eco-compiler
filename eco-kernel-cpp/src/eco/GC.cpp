//===- GC.cpp - Eco.GC kernel module implementation -----------------------===//
//
// plans/frontend-heap-release.md §4.3 (HEAP_076). `minorGC` / `majorGC` are
// Task_Bindings (KERNEL_TASK_IO_001): the value is a CAF and the body runs on
// every scheduler step, on the owning mutator, outside any GC pause. The
// body collects FIRST and allocates the result string AFTER the collection.
// `majorGC` is the full release (Allocator::collectMajorAndRelease).
//
// The report is returned as a JSON string so no kernel-record layout is
// involved; Eco/GC.elm decodes it. Nothing may branch on its values (HEAP_076).
//
//===----------------------------------------------------------------------===//

#include "GC.hpp"
#include "ExportHelpers.hpp"
#include "KernelHelpers.hpp"
#include "TaskBinding.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/GCReport.hpp"
#include <cinttypes>
#include <cstdio>
#include <string>

namespace Eco::Kernel::GC {

namespace {

// Keys are the Elm field names of Eco.GC.GCReport (§4.1); `collected` is
// always 1 natively (a collection always runs).
std::string toJson(const Elm::GCReport& r) {
    char buf[1024];
    const int n = std::snprintf(buf, sizeof buf,
        "{\"kind\":\"%s\",\"collected\":1"
        ",\"totalNs\":%" PRIu64 ",\"gcNs\":%" PRIu64 ",\"sweepNs\":%" PRIu64
        ",\"shrinkNs\":%" PRIu64 ",\"discardNs\":%" PRIu64 ",\"trimNs\":%" PRIu64
        ",\"rssBefore\":%" PRIu64 ",\"rssAfterDiscard\":%" PRIu64 ",\"rssAfter\":%" PRIu64
        ",\"oldInUseBefore\":%" PRIu64 ",\"oldInUseAfter\":%" PRIu64
        ",\"oldPendingBefore\":%" PRIu64 ",\"oldPendingAfter\":%" PRIu64
        ",\"oldHighWater\":%" PRIu64 ",\"liveAfterMark\":%" PRIu64
        ",\"releasedBytes\":%" PRIu64 ",\"shrinkReleasedBytes\":%" PRIu64
        ",\"discardedBytes\":%" PRIu64 ",\"nurseryCommitted\":%" PRIu64
        ",\"minorCount\":%" PRIu64 ",\"majorCount\":%" PRIu64 ",\"majorsRun\":%" PRIu64
        ",\"trimResult\":%" PRId64 "}",
        r.kind == Elm::GCReport::Kind::Major ? "major" : "minor",
        r.total_ns, r.gc_ns, r.sweep_ns, r.shrink_ns, r.discard_ns, r.trim_ns,
        r.rss_before, r.rss_after_discard, r.rss_after,
        r.old_in_use_before, r.old_in_use_after,
        r.old_pending_before, r.old_pending_after,
        r.old_high_water, r.live_after_mark,
        r.released_bytes, r.shrink_released_bytes,
        r.discarded_bytes, r.nursery_committed,
        r.minor_count, r.major_count, r.majors_run,
        r.trim_result);
    if (n < 0 || static_cast<size_t>(n) >= sizeof buf) {
        return "{\"kind\":\"error\"}";   // Eco/GC.elm decodes this to its zero record
    }
    return std::string(buf, static_cast<size_t>(n));
}

HPointer majorBody(HPointer /*captured*/) {
    const Elm::GCReport r = Elm::Allocator::instance().collectMajorAndRelease();
    return succeedString(toJson(r));   // allocated AFTER the collection
}

HPointer minorBody(HPointer /*captured*/) {
    const Elm::GCReport r = Elm::Allocator::instance().collectMinor();
    return succeedString(toJson(r));
}

} // anonymous namespace

uint64_t minorGC() {
    return Export::encode(
        Eco::Kernel::makeBinding<minorBody>(Elm::alloc::unit()));
}

uint64_t majorGC() {
    return Export::encode(
        Eco::Kernel::makeBinding<majorBody>(Elm::alloc::unit()));
}

} // namespace Eco::Kernel::GC
