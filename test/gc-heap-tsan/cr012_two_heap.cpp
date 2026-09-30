// Register reproductions, Phase C Step 22 (plans/threaded-gc-register-repros-
// impl.md): CR-012, two mutators (two ThreadLocalHeaps of one Allocator) share
// process-wide state that one heap's code reads without the lock the other
// heap's writer holds.
//
//   gc-heap-tsan cr012 a    old_gen_in_use_bytes_: Allocator::acquireOldGenBlock
//                           (A, under thread_mutex_) vs OldGenSpace::
//                           cyclePressureFinishDue (B, no lock)
//   gc-heap-tsan cr012 e    B's bag / BlockTable: Allocator::validatePageWork
//                           (A's onGCPauseEnd, under thread_mutex_, reads EVERY
//                           heap) vs OldGenSpace::materializeVirginBlock (B's
//                           own allocation, no lock: its bag is non-empty)
//
// Ordered by DetHandshake.hpp's relaxed atomics only; B's initThread takes
// thread_mutex_ BEFORE A's access, and B takes no lock afterwards until its
// cleanupThread. Exit 0 clean, 3 NOT REACHED, 66 (TSan) a report. Not in the
// default run (it reports by design until CR-012 is fixed).
#include "Allocator.hpp"
#include "HeapHelpers.hpp"
#include "OldGenSpace.hpp"
#include "PageWork.hpp"
#include "ThreadLocalHeap.hpp"
#include "DetHandshake.hpp"

#include <cstdio>
#include <cstring>
#include <thread>

using namespace Elm;

int cr012Main(int argc, char** argv) {
    const char arm = argc > 1 ? argv[1][0] : 'a';
    if (arm != 'a' && arm != 'e') {
        std::fprintf(stderr, "usage: gc-heap-tsan cr012 a|e\n");
        return 2;
    }
    const char* name = arm == 'a' ? "cr012 a" : "cr012 e";
    // cr018Config's geometry.
    HeapConfig cfg;
    cfg.alloc_buffer_size = 64 * 1024;
    cfg.nursery_block_count = cfg.nursery_max_block_count = 4;   // two nursery slices fit the region
    cfg.initial_old_gen_size = 256 * 1024;
    cfg.max_heap_size = 64ULL << 20;
    cfg.old_gen_bitmap_alloc = true;
    cfg.conc_mark = 0;
    cfg.incremental_mark = false;
    cfg.nursery_regions = 0;
    cfg.gc_thread_mode = arm == 'e' ? 2 : 0;
    cfg.gc_helper_threads = 1;
    cfg.commit_ahead_bytes = 0;
    cfg.decommit_on_oldgen_release = false;
    cfg.validate();
    auto& a = Allocator::instance();
    a.initialize(cfg);
    AllocatorTestAccess::reset(a, &cfg);
    a.initThread();
    std::atomic<int> step{0};
    int due0 = -1, due1 = -1;
    void* pb = nullptr;
    size_t bag_before = 0, blocks_before = 0;
    std::thread B([&] {
        a.initThread();   // takes thread_mutex_ BEFORE A's access
        OldGenSpace& ogB = AllocatorTestAccess::getThreadHeap(a)->getOldGen();   // B-local; never shared
        if (arm == 'a') due0 = OldGenSpaceTestAccess::cyclePressureFinishDue(ogB) ? 1 : 0;
        bag_before = OldGenSpaceTestAccess::getUnassignedBlocks(ogB).size();
        blocks_before = OldGenSpaceTestAccess::blockCount(ogB);
        det::post(step, 1);
        det::waitFor(step, 2);
        if (arm == 'a') due1 = OldGenSpaceTestAccess::cyclePressureFinishDue(ogB) ? 1 : 0;   // unlocked read
        else pb = ogB.allocate(48);   // a virgin block from B's non-empty bag: no lock
        det::post(step, 3);
        det::waitFor(step, 4);
        if (pb) {
            std::memset(pb, 0, 48);
            getHeader(pb)->tag = Tag_ByteBuffer;
            getHeader(pb)->size = static_cast<u32>(48 - sizeof(ByteBuffer));
        }
        a.cleanupThread();
    });
    det::waitFor(step, 1);
    char* got = nullptr;
    bool had_pw = false;
    if (arm == 'a') {
        got = AllocatorTestAccess::acquireOldGenBlock(a, cfg.alloc_buffer_size);   // the write, under the lock
    } else {
        had_pw = a.pageWork() != nullptr;
        a.onGCPauseEnd(*AllocatorTestAccess::getThreadHeap(a), false);   // validatePageWork reads B's heap
    }
    det::post(step, 2);
    det::waitFor(step, 3);
    det::post(step, 4);
    B.join();
    if (arm == 'a') {
        if (got == nullptr) { std::printf("%s: NOT REACHED: A's acquireOldGenBlock failed\n", name); return 3; }
        if (due0 != 0) { std::printf("%s: NOT REACHED: B's finish trigger was already due\n", name); return 3; }
        std::printf("%s: REACHED (A committed a block under thread_mutex_; B's cyclePressureFinishDue read "
                    "old_gen_in_use_bytes_ unlocked: due %d -> %d)\n", name, due0, due1);
    } else {
        if (!had_pw) { std::printf("%s: NOT REACHED: no page work (gc_thread_mode 2)\n", name); return 3; }
        if (pb == nullptr || bag_before == 0) {
            std::printf("%s: NOT REACHED: B's allocation did not take a bag page (bag %zu)\n", name, bag_before);
            return 3;
        }
        std::printf("%s: REACHED (A's validatePageWork walked B's blocks (%zu) and bag (%zu); B then "
                    "materialized a virgin block with no lock)\n", name, blocks_before, bag_before);
    }
    return 0;
}
