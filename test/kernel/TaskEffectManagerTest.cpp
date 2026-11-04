// Unit tests of the Task effect manager's registrar (elm-kernel-cpp/src/core/TaskEffectManager.cpp).
//
// closures-rooted-across-a-minor (TASK-01): `eco_register_task_effect_manager` held each closure it allocates in
// an unrooted local across the next `allocClosure`, which may collect. A minor collection that falls after
// `initCl` is allocated did not see it, so the word registered for `init` still held the pre-collection address
// (a from-space or evacuated-eden copy). The case arranges for exactly one arity-0 closure to fit before the
// collection limit, so the second allocation (`onEffectsCl`) collects, and then reads the registered words back
// through `PlatformRuntime::findManagerForTest`. Fixed, the registrar roots each closure, so the word is
// updated. Run once with the legacy (semi-space) nursery and once in region mode.

#include "TaskEffectManagerTest.hpp"

#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"

#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "NurserySpace.hpp"
#include "platform/PlatformRuntime.hpp"
#include "platform/TestHooks.hpp"

#include <cstdint>
#include <cstring>
#include <string>

extern "C" void eco_register_task_effect_manager();

using namespace Elm;

namespace {

#if ECO_TEST_HOOKS

HPointer wordToHP(uint64_t w) {
    HPointer h;
    std::memcpy(&h, &w, sizeof h);
    return h;
}

void* dummyEval(void**) { return nullptr; }

// The TASK-01 scenario on allocator `a`: a minor collection lands between the first and second
// closure allocation of the registrar.
void taskRegistrarMinorAfterInit(Allocator& a, const char* mode) {
    auto& pr = Platform::PlatformRuntime::instance();   // created before arming: it may allocate
    NurserySpace* nursery = AllocatorTestAccess::getNursery(a);
    TEST_ASSERT(nursery != nullptr);
    NurserySpace::NurseryBump* bump = nursery->bumpState();

    // The size of an arity-0 closure, as the registrar's first allocation takes it.
    char* before = bump->ptr;
    (void)alloc::allocClosure(dummyEval, 0);
    const size_t closure0 = static_cast<size_t>(bump->ptr - before);
    TEST_ASSERT(closure0 > 0 && closure0 < 256);

    // Control, the fixed registrar's pattern: a closure rooted across the collecting allocation
    // moves, and its root is updated, so the defect check below can tell the two apart.
    if (bump->end < bump->ptr + 4096) a.minorGC();
    {
        char* const at = bump->ptr;
        bump->end = bump->ptr + closure0;
        const uint64_t s0 = nursery->minorSeq();
        HPointer rooted = alloc::allocClosure(dummyEval, 0);
        Elm::StackRootGuard g(&rooted);
        (void)alloc::allocClosure(dummyEval, 4);
        if (nursery->minorSeq() != s0 + 1 || a.resolve(rooted) == static_cast<void*>(at)) {
            TEST_FAIL(std::string("TASK-01 (") + mode + "): control: a rooted closure did not move across the minor");
        }
    }

    // Room for exactly one arity-0 closure before the collection limit.
    if (bump->end < bump->ptr + 4096) a.minorGC();   // a fresh limit with ample room
    TEST_ASSERT(bump->end >= bump->ptr + closure0);
    char* const initAt = bump->ptr;
    bump->end = bump->ptr + closure0;
    const uint64_t seq0 = nursery->minorSeq();

    eco_register_task_effect_manager();

    const uint64_t seq1 = nursery->minorSeq();
    const Platform::PlatformRuntime::ManagerInfo* info = pr.findManagerForTest("Task");
    TEST_ASSERT(info != nullptr);
    void* initObj = a.resolve(wordToHP(info->init));
    void* onEffectsObj = a.resolve(wordToHP(info->onEffects));

    // Preconditions: exactly one minor ran, and it ran after `init` was allocated at `initAt`
    // (the second closure, `onEffects`, was allocated after the collection, elsewhere).
    if (seq1 != seq0 + 1) {
        TEST_FAIL(std::string("TASK-01 (") + mode + "): expected exactly one minor during registration, saw " +
                  std::to_string(seq1 - seq0));
    }
    if (onEffectsObj == static_cast<void*>(initAt)) {
        TEST_FAIL(std::string("TASK-01 (") + mode + "): the collection did not fall after the first closure");
    }

    // The defect: `init` was not a root during the collection, so its word still names the closure's
    // pre-collection address. Fixed, the closure is rooted, evacuated, and the word updated.
    const bool defect = initObj == static_cast<void*>(initAt);
    const std::string how = std::string(mode) + ": init word -> " +
                            std::to_string(reinterpret_cast<uintptr_t>(initObj)) +
                            ", pre-collection address " + std::to_string(reinterpret_cast<uintptr_t>(initAt)) +
                            ", tag at word " + std::to_string(getHeader(initObj)->tag);

    // Re-register with no collection pending, so no stale word stays registered for the process exit.
    eco_register_task_effect_manager();

    if (defect) TEST_FAIL("TASK-01 " + how);
}

void testTaskRegistrarLegacy() {
    HeapConfig cfg;
    cfg.gc_minor_threads = 1;
    taskRegistrarMinorAfterInit(initLegacyAllocator(cfg), "legacy nursery");
}

void testTaskRegistrarRegion() { taskRegistrarMinorAfterInit(initAllocator(), "region nursery"); }

#endif  // ECO_TEST_HOOKS

}  // namespace

void registerTaskEffectManagerTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
#if ECO_TEST_HOOKS
    suite.add(Testing::TestCase("task-effect-manager/closures-rooted-across-a-minor (legacy nursery)",
                                testTaskRegistrarLegacy));
    suite.add(Testing::TestCase("task-effect-manager/closures-rooted-across-a-minor (region nursery)",
                                testTaskRegistrarRegion));
#else
    (void)suite;
#endif
}
