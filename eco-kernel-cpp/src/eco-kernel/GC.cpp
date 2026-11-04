//===- GC.cpp - Eco.GC kernel module implementation -----------------------===//
//
// Each binding body collects first and allocates the result String only after the collection, so no heap value
// is held across it. The Task's captured value is Unit, which the bodies ignore. The report is passed as a JSON
// String so that no kernel record layout is involved.
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

// Returns `r` as the JSON object described in `GC.hpp`, or `{"kind":"error"}` if it does not fit the buffer.
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
        return "{\"kind\":\"error\"}";
    }
    return std::string(buf, static_cast<size_t>(n));
}

// Runs `collectMajorAndRelease` and returns a Task that succeeds with its report. Binding body.
HPointer majorBody(HPointer /*captured*/) {
    const Elm::GCReport r = Elm::Allocator::instance().collectMajorAndRelease();
    return succeedString(toJson(r));
}

// Runs a minor collection and returns a Task that succeeds with its report. Binding body.
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
