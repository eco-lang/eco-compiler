#include "TLABTest.hpp"
#include <rapidcheck.h>
#include <vector>
#include "HeapGenerators.hpp"
#include "TLAB.hpp"
#include "GarbageCollector.hpp"
#include "OldGenSpace.hpp"

using namespace Elm;

Testing::TestCase testTLABMetricsOnEmpty("Fresh TLAB has correct metrics", []() {
    rc::check([]() {
        // Generate a random TLAB size (64KB to 256KB, aligned to 8 bytes).
        size_t size = *rc::gen::inRange<size_t>(64 * 1024, 256 * 1024);
        size = (size + 7) & ~7;

        // Allocate backing memory for TLAB.
        std::vector<char> backing(size);
        char* base = backing.data();

        // Create TLAB.
        TLAB tlab(base, size);

        // Verify all metrics on empty TLAB.
        RC_ASSERT(tlab.capacity() == size);
        RC_ASSERT(tlab.isEmpty());
        RC_ASSERT(!tlab.isFull());
        RC_ASSERT(tlab.bytesUsed() == 0);
        RC_ASSERT(tlab.bytesRemaining() == size);
        RC_ASSERT(tlab.start == base);
        RC_ASSERT(tlab.end == base + size);
        RC_ASSERT(tlab.alloc_ptr == base);
    });
});

Testing::TestCase testTLABMetricsAfterAllocation("TLAB metrics track allocations correctly", []() {
    rc::check([]() {
        // Fixed TLAB size for this test.
        size_t tlab_size = 128 * 1024;

        // Allocate backing memory.
        std::vector<char> backing(tlab_size);
        char* base = backing.data();

        TLAB tlab(base, tlab_size);

        // Generate number of allocations and their sizes.
        // Size-scaled: 1-20 allocs at size 0, up to 1-120 at size 1000.
        size_t num_allocs = *rc::sizedRange<size_t>(1, 20, 0.1);
        auto alloc_sizes = *rc::gen::container<std::vector<size_t>>(
            num_allocs,
            rc::sizedRange<size_t>(8, 512, 0.5)
        );

        size_t total_allocated = 0;
        std::vector<char*> allocated_ptrs;

        for (size_t requested_size : alloc_sizes) {
            size_t aligned_size = (requested_size + 7) & ~7;

            // Check if allocation would fit.
            if (total_allocated + aligned_size > tlab_size) {
                break;
            }

            void* ptr = tlab.allocate(requested_size);
            if (!ptr) RC_FAIL("Failed to allocate from TLAB");

            allocated_ptrs.push_back(static_cast<char*>(ptr));
            total_allocated += aligned_size;

            // Verify metrics after each allocation.
            RC_ASSERT(tlab.bytesUsed() == total_allocated);
            RC_ASSERT(tlab.bytesRemaining() == tlab_size - total_allocated);
            RC_ASSERT(!tlab.isEmpty());

            // Verify pointer is within TLAB bounds.
            char* char_ptr = static_cast<char*>(ptr);
            RC_ASSERT(char_ptr >= tlab.start);
            RC_ASSERT(char_ptr < tlab.end);
        }

        // Verify all pointers are unique and sequential.
        for (size_t i = 1; i < allocated_ptrs.size(); i++) {
            RC_ASSERT(allocated_ptrs[i] > allocated_ptrs[i-1]);
        }
    });
});

Testing::TestCase testTLABAllocationFillsCorrectly("TLAB fills to capacity and returns nullptr when full", []() {
    rc::check([]() {
        // Use a smaller TLAB for faster testing.
        // Size-scaled: 1KB-8KB at size 0, up to 1KB-28KB at size 1000.
        size_t tlab_size = *rc::sizedRange<size_t>(1024, 8192, 20.0);
        tlab_size = (tlab_size + 7) & ~7;

        std::vector<char> backing(tlab_size);
        char* base = backing.data();

        TLAB tlab(base, tlab_size);

        // Generate a fixed allocation size (size-scaled: 8-128 at size 0, up to 8-628 at size 1000).
        size_t alloc_size = *rc::sizedRange<size_t>(8, 128, 0.5);
        size_t aligned_size = (alloc_size + 7) & ~7;

        std::vector<char*> allocated_ptrs;
        size_t total_allocated = 0;

        // Allocate until TLAB is exhausted.
        while (true) {
            void* ptr = tlab.allocate(alloc_size);

            if (ptr == nullptr) {
                // Allocation failed - TLAB should be nearly full.
                RC_ASSERT(tlab.bytesRemaining() < aligned_size);
                break;
            }

            allocated_ptrs.push_back(static_cast<char*>(ptr));
            total_allocated += aligned_size;

            // Safety check to avoid infinite loop.
            RC_ASSERT(total_allocated <= tlab_size);
        }

        // Verify final state.
        RC_ASSERT(tlab.bytesUsed() == total_allocated);
        RC_ASSERT(tlab.bytesUsed() + tlab.bytesRemaining() == tlab_size);

        // If we completely filled it (no remainder), it should be full.
        if (tlab.bytesRemaining() == 0) {
            RC_ASSERT(tlab.isFull());
        }

        // All allocated pointers should be within TLAB range.
        for (char* char_ptr : allocated_ptrs) {
            RC_ASSERT(char_ptr >= tlab.start);
            RC_ASSERT(char_ptr < tlab.end);
        }

        // Allocations should be sequential (bump pointer).
        for (size_t i = 1; i < allocated_ptrs.size(); i++) {
            ptrdiff_t diff = allocated_ptrs[i] - allocated_ptrs[i-1];
            RC_ASSERT(static_cast<size_t>(diff) == aligned_size);
        }
    });
});

Testing::TestCase testTLABFillAndSeal("Promoting objects beyond TLAB capacity seals TLABs", []() {
    rc::check([]() {
        auto &gc = GarbageCollector::instance();
        gc.initThread();
        gc.reset();

        auto* nursery = gc.getNursery();
        if (!nursery) {
            RC_DISCARD("Nursery not available");
        }

#if ENABLE_GC_STATS
        GCStats& nursery_stats = nursery->getStats();
        uint64_t initial_sealed = nursery_stats.tlabs_sealed;
#endif

        // To seal TLABs, we need to promote enough objects to fill them.
        // TLAB_DEFAULT_SIZE is 128KB, so we need to promote 3x that to seal at least 2.
        size_t tlab_size = OldGenSpace::TLAB_DEFAULT_SIZE;
        size_t target_promoted = tlab_size * 3;

        size_t total_promoted = 0;

        // Use a fixed-size array of roots to avoid accumulation
        // We'll reuse these slots each batch
        constexpr size_t MAX_BATCH_OBJECTS = 4096;
        std::vector<HPointer> root_storage(MAX_BATCH_OBJECTS);
        bool roots_registered = false;

        while (total_promoted < target_promoted) {
            size_t batch_size = 0;
            size_t batch_count = 0;

            // Fill a portion of nursery with objects
            while (batch_size < tlab_size / 2 && batch_count < MAX_BATCH_OBJECTS) {
                size_t obj_size = sizeof(ElmInt);

                void* obj = gc.allocate(obj_size, Tag_Int);
                if (!obj) {
                    RC_FAIL("Allocation failed");
                }

                ElmInt* elm_int = static_cast<ElmInt*>(obj);
                elm_int->value = static_cast<i64>(batch_count);

                root_storage[batch_count] = toPointer(obj);
                batch_count++;
                batch_size += obj_size;
            }

            // Register roots only once
            if (!roots_registered) {
                for (size_t i = 0; i < batch_count; i++) {
                    gc.getRootSet().addRoot(&root_storage[i]);
                }
                roots_registered = true;
            }

            // Run minor GC twice to promote (age 0 -> 1 -> promoted)
            gc.minorGC();
            gc.minorGC();

            total_promoted += batch_size;

            // Unregister roots after promotion so we don't accumulate
            if (roots_registered) {
                for (size_t i = 0; i < batch_count; i++) {
                    gc.getRootSet().removeRoot(&root_storage[i]);
                }
                roots_registered = false;
            }
        }

#if ENABLE_GC_STATS
        uint64_t sealed_count = nursery_stats.tlabs_sealed - initial_sealed;
        // We should have sealed at least 2 TLABs
        RC_ASSERT(sealed_count >= 2);
#endif

        RC_ASSERT(total_promoted >= target_promoted);
    });
});
