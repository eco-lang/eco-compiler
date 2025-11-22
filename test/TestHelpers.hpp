#pragma once

#include <rapidcheck.h>
#include <stdexcept>
#include <vector>
#include "GarbageCollector.hpp"
#include "Heap.hpp"
#include "HeapGenerators.hpp"
#include "OldGenSpace.hpp"
#include "TLAB.hpp"

// Simple assertion for unit tests (outside rc::check).
// Throws std::runtime_error on failure, which the test runner catches.
#define TEST_ASSERT(cond) \
    do { \
        if (!(cond)) { \
            throw std::runtime_error("Assertion failed: " #cond); \
        } \
    } while (0)

// Fail unconditionally with a message.
#define TEST_FAIL(msg) \
    do { \
        throw std::runtime_error(msg); \
    } while (0)

namespace Elm {
namespace TestHelpers {

// ============================================================================
// 1. GC Initialization
// ============================================================================

// Initialize GC for testing: get instance, init thread, reset state.
// Returns reference to the singleton for convenience.
GarbageCollector& initGC();

// ============================================================================
// 2. Create and Root Multiple ElmInts
// ============================================================================

// Result of creating rooted integers
struct RootedInts {
    std::vector<i64> values;
    std::vector<HPointer> roots;

    // Register all roots with the GC
    void registerRoots(GarbageCollector& gc);

    // Unregister all roots from the GC
    void unregisterRoots(GarbageCollector& gc);

    // Number of successfully created objects
    size_t size() const { return roots.size(); }

    // Check if any objects were created
    bool empty() const { return roots.empty(); }
};

// Create multiple ElmInt objects with random values and store them.
// Does NOT register roots - call registerRoots() after.
RootedInts createRootedInts(GarbageCollector& gc, size_t count);

// Create multiple ElmInt objects with specific values.
RootedInts createRootedIntsWithValues(GarbageCollector& gc, const std::vector<i64>& values);

// ============================================================================
// 3. Unregister Roots
// ============================================================================

// Unregister all roots in a vector from the GC
void unregisterRoots(GarbageCollector& gc, std::vector<HPointer>& roots);

// ============================================================================
// 4. Promote Objects to Old Gen
// ============================================================================

// Run enough minor GCs to promote objects (PROMOTION_AGE + 1 cycles)
void promoteToOldGen(GarbageCollector& gc);

// ============================================================================
// 5. Verify ElmInt Values
// ============================================================================

// Verify that all roots point to ElmInts with expected values.
// Uses readBarrier to handle forwarding pointers.
// Fails with RC_FAIL if any object is null or has wrong value.
void verifyIntValues(const std::vector<HPointer>& roots,
                     const std::vector<i64>& expected);

// ============================================================================
// 6. Create Constant HPointer
// ============================================================================

// Create an HPointer representing a constant (Nil, True, False, etc.)
HPointer createConstant(Constant c);

// Convenience for creating Nil
inline HPointer createNil() { return createConstant(Const_Nil); }

// ============================================================================
// 7. Allocate ElmInt into TLAB
// ============================================================================

// Allocate an ElmInt with given value into a TLAB.
// Sets header tag, color (White), and value.
// Returns nullptr if allocation fails.
void* allocateIntIntoTLAB(TLAB* tlab, i64 value);

// ============================================================================
// 8. Run Mark-and-Sweep (Stats-Aware)
// ============================================================================

// Run a complete mark-and-sweep cycle on the old generation.
// Handles ENABLE_GC_STATS conditional compilation internally.
void runMarkAndSweep(GarbageCollector& gc);

// ============================================================================
// 9. Run Compaction Sequence
// ============================================================================

// Run the full compaction sequence:
// selectCompactionSet -> setCompactionInProgress(true) -> performCompaction
// -> optionally reclaimEvacuatedBlocks -> setCompactionInProgress(false)
void runCompaction(OldGenSpace& oldgen, bool reclaimBlocks = true);

// ============================================================================
// 10. Setup Roots from HeapGraphDesc
// ============================================================================

// RAII wrapper for roots created from a HeapGraphDesc
struct GraphRoots {
    GarbageCollector* gc;
    std::vector<HPointer> storage;
    std::vector<HPointer*> ptrs;

    GraphRoots() : gc(nullptr) {}
    ~GraphRoots();

    // Prevent copying
    GraphRoots(const GraphRoots&) = delete;
    GraphRoots& operator=(const GraphRoots&) = delete;

    // Allow moving
    GraphRoots(GraphRoots&& other) noexcept;
    GraphRoots& operator=(GraphRoots&& other) noexcept;

    bool empty() const { return ptrs.empty(); }
    size_t size() const { return ptrs.size(); }
};

// Setup roots from a HeapGraphDesc. Returns RAII wrapper that auto-unregisters.
GraphRoots setupRootsFromGraph(GarbageCollector& gc,
                                const HeapGraphDesc& graph,
                                const std::vector<void*>& allocated_objects);

// ============================================================================
// 11. Allocate Garbage Ints
// ============================================================================

// Allocate unrooted ElmInt objects (garbage).
// Useful for triggering GC or filling nursery.
void allocateGarbageInts(GarbageCollector& gc, size_t count);

// ============================================================================
// 12. Allocate TLAB with Assertion
// ============================================================================

// Allocate a TLAB from old gen, RC_FAIL if allocation fails.
TLAB* allocateTLABOrFail(OldGenSpace& oldgen,
                          size_t size = OldGenSpace::TLAB_DEFAULT_SIZE);

// ============================================================================
// 13. Build Linked List
// ============================================================================

// Result of building a linked list
struct LinkedList {
    HPointer head;
    std::vector<i64> values;  // Values in order they appear when traversing
};

// Build a cons list of ElmInts with random values.
// Returns head pointer and the values (in list order).
LinkedList buildLinkedList(GarbageCollector& gc, size_t length);

// Build a cons list in a TLAB (for old gen tests).
LinkedList buildLinkedListInTLAB(TLAB* tlab, size_t length);

// ============================================================================
// 14. Verify Linked List
// ============================================================================

// Walk a cons list and verify it contains expected values in order.
// Uses readBarrier for forwarding pointer handling.
void verifyLinkedList(HPointer head, const std::vector<i64>& expected);

// ============================================================================
// 15. Assert Object is Int with Value
// ============================================================================

// Assert that an object is an ElmInt with the expected value.
// Uses readBarrier if given an HPointer.
void assertObjectIsInt(void* obj, i64 expected);
void assertObjectIsInt(HPointer ptr, i64 expected);

// ============================================================================
// Additional Utilities
// ============================================================================

// Allocate a Cons cell into a TLAB
void* allocateConsIntoTLAB(TLAB* tlab, HPointer head_ptr, HPointer tail_ptr, bool head_boxed);

// Allocate an ElmInt directly in OldGen free-list
void* allocateIntInOldGen(OldGenSpace& oldgen, i64 value);

} // namespace TestHelpers
} // namespace Elm

// Bring helpers into global namespace for convenience in tests
using namespace Elm::TestHelpers;
