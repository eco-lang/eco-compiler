/**
 * Expected-fail guards for runtime-review defects (cpp-review-bugs.md) that are reproduced but not
 * fixed yet (see ReviewBugGuardsTest.hpp and test/XfailGuard.hpp).
 *
 *   RB-255  HeapConfig::validate accepts an alloc_buffer_size that is not a multiple of the OS page
 *           size; the heap then commits buffers at addresses mmap(MAP_FIXED) rejects (an assert in
 *           acquireOldGenBlock, or an out-of-memory report in a release build).
 *   RB-141  When the old generation is exhausted, a large pointer-bearing (YLOS) allocation does not
 *           report "out of memory": after its major-GC retry it only asserts (a release build returns
 *           null and the caller dereferences it), unlike large String/Bytes bodies, which end in
 *           largeBodyExhausted's "eco: out of memory" abort.
 */

#include "ReviewBugGuardsTest.hpp"

#include <csignal>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

#include "../XfailGuard.hpp"
#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "HeapHelpers.hpp"
#include "TestHelpers.hpp"

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

// RB-255: a non-page-multiple alloc_buffer_size must be rejected by validate(). The control, the
// same configuration with a page-multiple size, must be accepted, so the guard cannot pass because
// some other rule rejects the configuration.
HeapConfig configWithBufferSize(size_t bufferSize) {
    HeapConfig cfg;
    cfg.alloc_buffer_size = bufferSize;
    cfg.large_object_threshold = std::min(cfg.large_object_threshold, bufferSize);
    cfg.initial_old_gen_size = bufferSize * 64;
    return cfg;
}

void testAllocBufferSizePageMultiple() {
    HeapConfig control = configWithBufferSize(2 * OS_PAGE_SIZE);
    try {
        control.validate();
    } catch (const std::invalid_argument& e) {
        TEST_FAIL(std::string("RB-255: the control configuration is rejected: ") + e.what());
    }
    HeapConfig bad = configWithBufferSize(OS_PAGE_SIZE * 3 / 2);
    bool rejected = false;
    std::string why;
    try {
        bad.validate();
    } catch (const std::invalid_argument& e) {
        rejected = true;
        why = e.what();
    }
    XfailGuard::report("RB-255", !rejected,
                       rejected ? "validate rejects alloc_buffer_size = 1.5 pages (" + why + ")"
                                : "validate accepts alloc_buffer_size = 1.5 pages");
}

// RB-141: fills a small heap (a 64 MiB reservation) with rooted large arrays, all placed in the YLOS
// (large_ptr_nursery_divisor = 0), until the old generation is exhausted. The correct end is an
// "out of memory" abort; today it is the assert in allocateYoungLarge (or, in a release build, a
// null pointer).
void testYlosExhaustionReportsOutOfMemory() {
#if !defined(_WIN32)
    XfailGuard::ChildResult r = XfailGuard::runInChild([] {
        HeapConfig cfg;
        cfg.alloc_buffer_size = 64 * 1024;
        cfg.nursery_block_count = 4;
        cfg.nursery_max_block_count = 4;
        cfg.initial_old_gen_size = 256 * 1024;
        cfg.max_heap_size = 64ULL * 1024 * 1024;
        cfg.large_ptr_nursery_divisor = 0;   // every large pointer-bearing object goes to the YLOS
        cfg.validate();
        // The first initialize in a process fixes the reservation (HEAP_043), and initAllocator
        // reserves with the default config first, so the child initializes directly: its old
        // generation is then really bounded by this max_heap_size.
        auto& alloc = Allocator::instance();
        alloc.initialize(cfg);
        alloc.initThread();
        static std::vector<HPointer> keep;
        keep.reserve(8192);
        for (int i = 0; i < 8192; ++i) {   // 8192 x 64 KiB = 512 MiB, far over the 64 MiB heap
            keep.push_back(alloc::allocArray(8000));
            alloc.getRootSet().addRoot(&keep.back());
            // Touch the object, as a caller would: a null result faults here.
            volatile u32 len = static_cast<ElmArray*>(alloc.resolve(keep.back()))->length;
            (void)len;
        }
        std::fprintf(stderr, "old gen in use %zu of max %zu bytes after %zu arrays\n",
                     alloc.getOldGenCommittedBytes(), alloc.getOldGenMaxBytes(), keep.size());
        return 11;   // never exhausted: the scenario did not reach the defect
    });
    if (WIFEXITED(r.status) && WEXITSTATUS(r.status) == 11) {
        TEST_FAIL("RB-141: 512 MiB of rooted YLOS arrays did not exhaust the 64 MiB heap: " + r.stderrText);
    }
    const bool cleanOom = WIFSIGNALED(r.status) && WTERMSIG(r.status) == SIGABRT &&
                          r.stderrText.find("out of memory") != std::string::npos;
    std::string how = cleanOom ? "an \"out of memory\" abort"
                               : "no \"out of memory\" report (wait status " + std::to_string(r.status) +
                                     "; stderr: " + r.stderrText.substr(0, 200) + ")";
    XfailGuard::report("RB-141", !cleanOom, how);
#endif
}

}  // namespace

void registerReviewBugGuards(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase(
        "[xfail RB-255] HeapConfig::validate rejects an alloc_buffer_size that is not a page multiple",
        testAllocBufferSizePageMultiple));
}

void registerReviewBugIsolatedGuards(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
    suite.add(Testing::TestCase(
        "[xfail RB-141] YLOS exhaustion ends in an out-of-memory report, not an assert or null",
        testYlosExhaustionReportsOutOfMemory));
}
