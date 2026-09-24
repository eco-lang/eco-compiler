/**
 * threaded-gc-00 Step 8: the print-time pause statistics are pure functions
 * of a PauseEvent list, so they are pinned here with synthetic events whose
 * answers can be worked out by hand.
 */

#include "GCPauseStatsTest.hpp"

#include <cmath>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <vector>

#include "GCStats.hpp"

using namespace Elm;

#define PS_ASSERT(cond)                                                     \
    do {                                                                    \
        if (!(cond)) {                                                      \
            std::ostringstream oss;                                         \
            oss << "GCPauseStats assertion failed: " #cond                  \
                << " at " __FILE__ ":" << __LINE__;                         \
            std::cerr << oss.str() << std::endl;                            \
            throw std::runtime_error(oss.str());                            \
        }                                                                   \
    } while (0)

namespace {

constexpr uint64_t kMs = 1000000ull;

bool near(double a, double b) { return std::fabs(a - b) < 1e-9; }

}  // namespace

Testing::TestCase testGCPauseStatsMMU(
    "threaded-gc-00: MMU of synthetic pause logs",
    []() {
        // (a) One 10 ms pause in a 1 s run.
        std::vector<PauseEvent> one = {{500 * kMs, 10 * kMs, 0}};
        PS_ASSERT(near(GCPhaseTotals::mmu(one, 1000 * kMs, 10 * kMs), 0.0));
        PS_ASSERT(near(GCPhaseTotals::mmu(one, 1000 * kMs, 20 * kMs), 0.5));
        PS_ASSERT(near(GCPhaseTotals::mmu(one, 1000 * kMs, 1000 * kMs), 0.99));

        // (b) Two 5 ms pauses 1 ms apart: a window of 11 ms holds 10 ms of GC.
        std::vector<PauseEvent> two = {{0, 5 * kMs, 0}, {6 * kMs, 5 * kMs, 0}};
        PS_ASSERT(near(GCPhaseTotals::mmu(two, 1000 * kMs, 11 * kMs), 1.0 / 11.0));

        // Pause at the very start of the run: the window must clamp to 0.
        std::vector<PauseEvent> start = {{0, 4 * kMs, 2}};
        PS_ASSERT(near(GCPhaseTotals::mmu(start, 100 * kMs, 8 * kMs), 0.5));

        // No pauses: full utilisation.
        std::vector<PauseEvent> none;
        PS_ASSERT(near(GCPhaseTotals::mmu(none, 100 * kMs, 10 * kMs), 1.0));
    });

Testing::TestCase testGCPauseStatsPercentiles(
    "threaded-gc-00: nearest-rank pause percentiles",
    []() {
        std::vector<uint64_t> d;
        for (uint64_t i = 1; i <= 100; ++i) d.push_back(i * kMs);
        PS_ASSERT(GCPhaseTotals::percentile(d, 0.50) == 50 * kMs);
        PS_ASSERT(GCPhaseTotals::percentile(d, 0.99) == 99 * kMs);
        PS_ASSERT(GCPhaseTotals::percentile(d, 1.00) == 100 * kMs);
        PS_ASSERT(GCPhaseTotals::percentile({}, 0.5) == 0);

        // log2 bucket: [2^b, 2^(b+1)) microseconds; < 2 us is bucket 0.
        PS_ASSERT(GCPhaseTotals::pauseBucket(1500) == 0);
        PS_ASSERT(GCPhaseTotals::pauseBucket(3000) == 1);
        PS_ASSERT(GCPhaseTotals::pauseBucket(31 * kMs) == 14);  // 31000 us
    });

Testing::TestCase testGCPauseStatsCombine(
    "threaded-gc-00: combine() concatenates pause logs and sums counts",
    []() {
        GCStats a, b;
        a.tg.addPause(10 * kMs, 3 * kMs, 0);
        a.tg.addPause(20 * kMs, 7 * kMs, 1);
        b.tg.addPause(5 * kMs, 2 * kMs, 2);
        a.combine(b);
        PS_ASSERT(a.tg.pause_count == 3);
        PS_ASSERT(a.tg.pause_events.size() == 3);
        PS_ASSERT(a.tg.pause_total_ns == 12 * kMs);
        PS_ASSERT(a.tg.pause_max_ns == 7 * kMs);
        PS_ASSERT(a.tg.pause_count_by_kind[0] == 1);
        PS_ASSERT(a.tg.pause_count_by_kind[1] == 1);
        PS_ASSERT(a.tg.pause_count_by_kind[2] == 1);

        // Scanners merge by name, not by index.
        MinorGCRecord r;
        r.ext_count = 2;
        r.ext_ns[0] = 100; r.ext_slots[0] = 1;
        r.ext_ns[1] = 200; r.ext_slots[1] = 5;
        const char* n1[] = {"scheduler", "cellstore"};
        const char* n2[] = {"cellstore", "scheduler"};
        GCStats c, d;
        c.tg.addMinor(r, n1, 2);
        d.tg.addMinor(r, n2, 2);
        c.combine(d);
        PS_ASSERT(c.tg.ext_count == 2);
        PS_ASSERT(c.tg.ext_ns[0] == 300);          // scheduler: 100 + 200
        PS_ASSERT(c.tg.ext_slots[1] == 6);         // cellstore: 5 + 1
        PS_ASSERT(c.tg.ext_slots_max[1] == 5);

        c.reset();
        PS_ASSERT(c.tg.minor_records == 0 && c.tg.pause_events.empty());
    });
