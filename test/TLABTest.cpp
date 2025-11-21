#include "TLABTest.hpp"
#include <rapidcheck.h>
#include <vector>
#include "TLAB.hpp"

using namespace Elm;

Testing::Test testTLABMetricsOnEmpty("TLAB metrics correct on empty TLAB", []() {
    rc::check("Fresh TLAB has correct metrics", []() {
        // Generate a random TLAB size (64KB to 256KB, aligned to 8 bytes)
        size_t size = *rc::gen::inRange<size_t>(64 * 1024, 256 * 1024);
        size = (size + 7) & ~7;  // Align to 8 bytes

        // Allocate backing memory for TLAB
        std::vector<char> backing(size);
        char* base = backing.data();

        // Create TLAB
        TLAB tlab(base, size);

        // Verify all metrics on empty TLAB
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

Testing::Test testTLABMetricsAfterAllocation("TLAB metrics update correctly after allocations", []() {
    rc::check("TLAB metrics track allocations correctly", []() {
        // Fixed TLAB size for this test
        size_t tlab_size = 128 * 1024;  // 128KB

        // Allocate backing memory
        std::vector<char> backing(tlab_size);
        char* base = backing.data();

        TLAB tlab(base, tlab_size);

        // Generate number of allocations and their sizes
        size_t num_allocs = *rc::gen::inRange<size_t>(1, 20);
        auto alloc_sizes = *rc::gen::container<std::vector<size_t>>(
            num_allocs,
            rc::gen::inRange<size_t>(8, 512)
        );

        size_t total_allocated = 0;
        std::vector<char*> allocated_ptrs;

        for (size_t requested_size : alloc_sizes) {
            size_t aligned_size = (requested_size + 7) & ~7;

            // Check if allocation would fit
            if (total_allocated + aligned_size > tlab_size) {
                break;  // Stop before overflow
            }

            void* ptr = tlab.allocate(requested_size);
            if (!ptr) RC_FAIL("Failed to allocate from TLAB");

            allocated_ptrs.push_back(static_cast<char*>(ptr));
            total_allocated += aligned_size;

            // Verify metrics after each allocation
            RC_ASSERT(tlab.bytesUsed() == total_allocated);
            RC_ASSERT(tlab.bytesRemaining() == tlab_size - total_allocated);
            RC_ASSERT(!tlab.isEmpty());

            // Verify pointer is within TLAB bounds
            char* char_ptr = static_cast<char*>(ptr);
            RC_ASSERT(char_ptr >= tlab.start);
            RC_ASSERT(char_ptr < tlab.end);
        }

        // Verify all pointers are unique and sequential
        for (size_t i = 1; i < allocated_ptrs.size(); i++) {
            RC_ASSERT(allocated_ptrs[i] > allocated_ptrs[i-1]);
        }
    });
});

Testing::Test testTLABAllocationFillsCorrectly("TLAB allocation fills correctly until full", []() {
    rc::check("TLAB fills to capacity and returns nullptr when full", []() {
        // Use a smaller TLAB for faster testing
        size_t tlab_size = *rc::gen::inRange<size_t>(1024, 8192);
        tlab_size = (tlab_size + 7) & ~7;

        std::vector<char> backing(tlab_size);
        char* base = backing.data();

        TLAB tlab(base, tlab_size);

        // Generate a fixed allocation size
        size_t alloc_size = *rc::gen::inRange<size_t>(8, 128);
        size_t aligned_size = (alloc_size + 7) & ~7;

        std::vector<char*> allocated_ptrs;
        size_t total_allocated = 0;

        // Allocate until TLAB is exhausted
        while (true) {
            void* ptr = tlab.allocate(alloc_size);

            if (ptr == nullptr) {
                // Allocation failed - TLAB should be nearly full
                RC_ASSERT(tlab.bytesRemaining() < aligned_size);
                break;
            }

            allocated_ptrs.push_back(static_cast<char*>(ptr));
            total_allocated += aligned_size;

            // Safety check to avoid infinite loop
            RC_ASSERT(total_allocated <= tlab_size);
        }

        // Verify final state
        RC_ASSERT(tlab.bytesUsed() == total_allocated);
        RC_ASSERT(tlab.bytesUsed() + tlab.bytesRemaining() == tlab_size);

        // If we completely filled it (no remainder), it should be full
        if (tlab.bytesRemaining() == 0) {
            RC_ASSERT(tlab.isFull());
        }

        // All allocated pointers should be within TLAB range
        for (char* char_ptr : allocated_ptrs) {
            RC_ASSERT(char_ptr >= tlab.start);
            RC_ASSERT(char_ptr < tlab.end);
        }

        // Allocations should be sequential (bump pointer)
        for (size_t i = 1; i < allocated_ptrs.size(); i++) {
            ptrdiff_t diff = allocated_ptrs[i] - allocated_ptrs[i-1];
            RC_ASSERT(static_cast<size_t>(diff) == aligned_size);
        }
    });
});
