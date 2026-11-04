// Kernel state that lives outside the heap, across a heap reset.
//
// A heap reset (`Allocator::reset`, reached through `initAllocator()`) bumps `heapGeneration` and replaces the
// calling thread's RootSet. Kernel state that lives outside the heap must notice the new generation: forget the
// values of the old heap, and register its root scanner again on the new RootSet. Every case here does
// "use the kernel state -> reset the heap -> use it again" in one process, so each is an isolated case.
// The eco/system tables are covered by test/eco-system-core/HeapResetTest.cpp.
//
// The scheduler and the platform runtime start afresh on the first use in a new generation (D21), so the
// cases may run processes after the reset; none resumes a closure parked before it.
//
//   runtime-load-state    Eco.Kernel.Runtime.loadState after a reset must give the JSON-null constant a fresh
//                         heap gives, not the value saved in the OLD heap (RESET-01: `s_hasState` was never
//                         cleared).
//   runtime-saved-state   After a reset, a value saved in the new heap must survive minor GCs: the saved-state
//                         scanner is registered again by `saveState` (RESET-01: it was gone with the old RootSet).
//   time-effects-scanner  After a reset the Time manager's "time-effects" scanner must be on the new RootSet and
//                         the post-reset onEffects must schedule a fresh tick (RESET-02: the scanner was
//                         registered under std::call_once, and the stale `g_intervals` entry took the "already
//                         present" branch).
//   http-effects-scanner  After a reset the Http kernel's "http-effects" scanner must be on the new RootSet once a
//                         request Task is made (RESET-12: it was registered under std::call_once, so the tracked
//                         requests' router and tracker words were never scanned again).
//   mvar                  After a reset the MVar kernel's "eco-mvar" scanner must be on the new RootSet once an
//                         MVar is made, a value put into a new MVar must survive minor GCs, and an MVar of the old
//                         heap must be gone ("MVar not found"), not a slot holding a word of the dead heap
//                         (RESET-03).

#include "HeapResetKernelStateTest.hpp"

#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"

#include "../../eco-kernel-cpp/src/eco-kernel/MVar.hpp"
#include "../../eco-kernel-cpp/src/eco-kernel/Runtime.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/StringOps.hpp"
#include "../../runtime/src/platform/PlatformRuntime.hpp"
#include "../../runtime/src/platform/Scheduler.hpp"
#include "../../runtime/src/platform/TaskBinding.hpp"
#include "platform/TestHooks.hpp"

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

extern "C" void Eco_Kernel_register_all_gc_roots();
extern "C" void eco_register_time_effect_manager();
extern "C" Elm::HPtr Elm_Kernel_Http_toTask(Elm::HPtr router, Elm::HPtr resultToTask, Elm::HPtr request);

namespace {

using Elm::HPointer;
using Elm::Platform::Scheduler;
using Elm::Platform::detail::decodeBits;
using Elm::Platform::detail::encodeBits;

// ---- Running a Task to completion and reading its value -------------------------------------------------

// The encoded value the last `runTask` produced.
uint64_t g_taskValue = 0;
bool g_taskDone = false;

// The `andThen` callback `runTask` appends: records its argument and succeeds with unit.
void* recordValueEval(void* args[]) {
    g_taskValue = reinterpret_cast<uint64_t>(args[0]);
    g_taskDone = true;
    return reinterpret_cast<void*>(encodeBits(Scheduler::instance().taskSucceed(Elm::alloc::unit())));
}

// Spawns `task andThen record`, drains the run queue and returns the value the task succeeded with (its
// encoded word). Sets `g_taskDone`.
uint64_t runTask(HPointer task) {
    auto& s = Scheduler::instance();
    g_taskDone = false;
    g_taskValue = 0;
    HPointer cb = Elm::alloc::listNil();
    Elm::StackRootGuard g(&task, &cb);
    cb = Elm::alloc::allocClosure(&recordValueEval, 1);
    HPointer chained = s.taskAndThen(cb, task);
    (void)s.rawSpawn(chained);
    s.drain();
    return g_taskValue;
}

bool hasScanner(const char* name) {
    for (const char* n : Elm::Allocator::instance().getRootSet().getExternalRootScannerNames()) {
        if (n != nullptr && std::strcmp(n, name) == 0) return true;
    }
    return false;
}

std::string scannerNames() {
    std::string out;
    for (const char* n : Elm::Allocator::instance().getRootSet().getExternalRootScannerNames()) {
        if (!out.empty()) out += ",";
        out += n ? n : "(null)";
    }
    return out.empty() ? std::string("(none)") : out;
}

// ---- RESET-01 a: loadState after a reset ------------------------------------------------------------------

void testRuntimeLoadStateAfterReset() {
    initAllocator();
    (void)Scheduler::instance();
    Eco_Kernel_register_all_gc_roots();

    HPointer str = Elm::alloc::allocStringFromUTF8("x");
    Elm::StackRootGuard g(&str);
    (void)runTask(decodeBits(Eco::Kernel::Runtime::saveState(encodeBits(str))));
    TEST_ASSERT(g_taskDone);
    const uint64_t savedBits = runTask(decodeBits(Eco::Kernel::Runtime::loadState()));
    TEST_ASSERT(g_taskDone);
    TEST_ASSERT(savedBits == encodeBits(str));   // precondition: the save worked in the first heap

    initAllocator();                     // the heap reset
    Eco_Kernel_register_all_gc_roots();  // what a test must do after a reset

    const uint64_t got = runTask(decodeBits(Eco::Kernel::Runtime::loadState()));
    TEST_ASSERT(g_taskDone);
    const uint64_t nullBits = Elm::nullConsWordFor(0);
    const bool defect = got != nullBits;
    if (defect)
        TEST_FAIL("RESET-01: loadState after reset returned word " + std::to_string(got) +
                  (got == savedBits ? " (the pre-reset saved HPointer)" : "") +
                  ", expected the JSON-null constant " + std::to_string(nullBits));
}

// ---- RESET-01 b: the saved-state scanner after a reset -----------------------------------------------------

// Whether `tag` is one of the String representations (allocStringFromUTF8 gives an all-ASCII Utf8Leaf).
bool isStringTag(unsigned tag) {
    return tag == Elm::Tag_String || tag == Elm::Tag_StringRope || tag == Elm::Tag_StringSlice ||
           tag == Elm::Tag_StringUtf8View || tag == Elm::Tag_StringUtf8Leaf || tag == Elm::Tag_LargeStringHeader;
}

void testRuntimeSavedStateRootedAfterReset() {
    // The legacy semispace nursery: two minors return allocation to the semispace the saved string was born in.
    Elm::Allocator& a0 = initLegacyAllocator();
    (void)a0;
    (void)Scheduler::instance();
    Eco_Kernel_register_all_gc_roots();   // registers the scanner on the first heap's RootSet
    const size_t scannersBefore = Elm::Allocator::instance().getRootSet().getExternalRootScannerNames().size();
    TEST_ASSERT(scannersBefore > 0);

    Elm::Allocator& alloc = initLegacyAllocator();   // the heap reset; the hook is NOT called again
    const std::string namesAfterReset = scannerNames();

    {
        HPointer str = Elm::alloc::allocStringFromUTF8("x");
        Elm::StackRootGuard g(&str);
        (void)runTask(decodeBits(Eco::Kernel::Runtime::saveState(encodeBits(str))));
        TEST_ASSERT(g_taskDone);
    }
    alloc.minorGC();   // must evacuate the saved string
    alloc.minorGC();
    for (int j = 0; j < 4096; j++) (void)Elm::alloc::allocInt(-1);   // overwrite the old semispace

    const uint64_t got = runTask(decodeBits(Eco::Kernel::Runtime::loadState()));
    TEST_ASSERT(g_taskDone);
    std::string what;
    bool intact = false;
    void* obj = alloc.resolve(decodeBits(got));
    if (obj == nullptr) {
        what = "the saved word no longer resolves";
    } else if (!isStringTag(Elm::getHeader(obj)->tag)) {
        what = "the saved word now points at an object with tag " + std::to_string(Elm::getHeader(obj)->tag);
    } else {
        std::string s = Elm::StringOps::toStdString(obj);
        intact = s == "x";
        what = "the saved string reads \"" + s + "\"";
    }
    if (!intact)
        TEST_FAIL("RESET-01: " + what + " after a reset, two minor GCs and garbage (scanners after the reset: " +
                  namesAfterReset + ")");
}

// ---- RESET-02: the Time manager after a reset -------------------------------------------------------------

void* ignoreEval(void*[]) {
    return reinterpret_cast<void*>(encodeBits(Elm::alloc::unit()));
}

// Calls the registered Time manager's onEffects with one `Time.every 1.0e9 tagger` subscription (built as
// TimeExports.cpp / timeSubMapEvaluator build it: ctor 0, Float interval, boxed tagger).
void timeOnEffectsEvery1e9() {
#if ECO_TEST_HOOKS
    const auto* info = Elm::Platform::PlatformRuntime::instance().findManagerForTest("Time");
    TEST_ASSERT(info != nullptr);
    HPointer tagger = Elm::alloc::listNil(), sub = Elm::alloc::listNil(), subs = Elm::alloc::listNil();
    Elm::StackRootGuard g({&tagger, &sub, &subs});
    tagger = Elm::alloc::allocClosure(&ignoreEval, 1);
    std::vector<Elm::Unboxable> values(2);
    values[0].f = 1.0e9;
    values[1].p = tagger;
    sub = Elm::alloc::custom(0, values, 0b10);
    subs = Elm::alloc::cons(Elm::alloc::boxed(sub), Elm::alloc::listNil(), true);
    HPointer router = Elm::alloc::unit();
    (void)Scheduler::callClosure4(decodeBits(info->onEffects), router, Elm::alloc::listNil(), subs,
                                  Elm::alloc::listNil());
#else
    TEST_FAIL("RESET-02 needs ECO_TEST_HOOKS (PlatformRuntime::findManagerForTest)");
#endif
}

void testTimeScannerAfterReset() {
    initAllocator();
    auto& s = Scheduler::instance();
    eco_register_time_effect_manager();
    timeOnEffectsEvery1e9();
    TEST_ASSERT(hasScanner("time-effects"));   // precondition: registered on the first heap
    TEST_ASSERT(s.pendingAsync() == 1);        // the first tick's Task hold

    initAllocator();                     // the heap reset
    eco_register_time_effect_manager();  // the manager closures of the new heap
    const uint64_t serialBefore = s.acquireSerial();
    timeOnEffectsEvery1e9();
    const uint64_t acquired = s.acquireSerial() - serialBefore;
    const bool scanner = hasScanner("time-effects");
    const bool defect = !scanner || acquired == 0;
    if (defect)
        TEST_FAIL(std::string("RESET-02: after the reset: time-effects scanner ") + (scanner ? "present" : "absent") +
                  " (scanners: " + scannerNames() + "); holds acquired by the post-reset onEffects: " +
                  std::to_string(acquired) + " (want 1, a fresh tick); pendingAsync " +
                  std::to_string(s.pendingAsync()));
}

// ---- RESET-12: the Http kernel's tracking scanner after a reset ---------------------------------------------

// Makes (and drops) an Http request Task, which is where the kernel registers its tracking scanner. Making the
// Task reads nothing of its arguments, so unit stands in for all three.
void makeHttpTask() {
    const Elm::HPtr u = Elm::HPtr::fromBits(encodeBits(Elm::alloc::unit()));
    (void)Elm_Kernel_Http_toTask(u, u, u);
}

void testHttpScannerAfterReset() {
    initAllocator();
    (void)Scheduler::instance();
    makeHttpTask();
    TEST_ASSERT(hasScanner("http-effects"));   // precondition: registered on the first heap

    initAllocator();   // the heap reset
    (void)Scheduler::instance();
    makeHttpTask();
    if (!hasScanner("http-effects"))
        TEST_FAIL("RESET-12: after the reset no http-effects scanner on the new RootSet (scanners: " +
                  scannerNames() + ")");
}

// ---- RESET-03: MVars after a reset ---------------------------------------------------------------------------

namespace MVar = Eco::Kernel::MVar;

void testMVarAfterReset() {
    Elm::Allocator& a0 = initLegacyAllocator();
    (void)a0;
    (void)Scheduler::instance();
    Eco_Kernel_register_all_gc_roots();
    const int64_t oldId = MVar::newEmpty();
    {
        HPointer str = Elm::alloc::allocStringFromUTF8("old");
        Elm::StackRootGuard g(&str);
        (void)runTask(decodeBits(MVar::put(static_cast<uint64_t>(oldId), encodeBits(str))));
        TEST_ASSERT(g_taskDone);
    }
    TEST_ASSERT(hasScanner("eco-mvar"));   // precondition: registered on the first heap
    (void)runTask(decodeBits(MVar::read(static_cast<uint64_t>(oldId))));
    TEST_ASSERT(g_taskDone);               // precondition: the old MVar is full

    Elm::Allocator& alloc = initLegacyAllocator();   // the heap reset; the hook is NOT called again
    (void)Scheduler::instance();

    // The old heap's MVar: the read must fail (MVar not found), so the recording callback never runs.
    (void)runTask(decodeBits(MVar::read(static_cast<uint64_t>(oldId))));
    const bool oldStillThere = g_taskDone;

    const int64_t id = MVar::newEmpty();
    const bool scanner = hasScanner("eco-mvar");
    {
        HPointer str = Elm::alloc::allocStringFromUTF8("x");
        Elm::StackRootGuard g(&str);
        (void)runTask(decodeBits(MVar::put(static_cast<uint64_t>(id), encodeBits(str))));
        TEST_ASSERT(g_taskDone);
    }
    alloc.minorGC();   // must evacuate the MVar's string
    alloc.minorGC();
    for (int j = 0; j < 4096; j++) (void)Elm::alloc::allocInt(-1);   // overwrite the old semispace
    const uint64_t got = runTask(decodeBits(MVar::read(static_cast<uint64_t>(id))));
    TEST_ASSERT(g_taskDone);
    std::string what;
    bool intact = false;
    void* obj = alloc.resolve(decodeBits(got));
    if (obj == nullptr) {
        what = "the MVar's word no longer resolves";
    } else if (!isStringTag(Elm::getHeader(obj)->tag)) {
        what = "the MVar's word now points at an object with tag " + std::to_string(Elm::getHeader(obj)->tag);
    } else {
        std::string text = Elm::StringOps::toStdString(obj);
        intact = text == "x";
        what = "the MVar's string reads \"" + text + "\"";
    }
    if (oldStillThere || !scanner || !intact)
        TEST_FAIL(std::string("RESET-03: after the reset: old MVar ") + (oldStillThere ? "still readable" : "gone") +
                  "; eco-mvar scanner " + (scanner ? "present" : "absent") + " (scanners: " + scannerNames() +
                  "); " + what + " after two minor GCs and garbage");
}

}  // namespace

void registerHeapResetKernelStateTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
    // Each case resets the heap, so each runs in its own spawned process.
    suite.add(Testing::TestCase("heap-reset/runtime-load-state-gives-null", testRuntimeLoadStateAfterReset));
    suite.add(Testing::TestCase("heap-reset/runtime-saved-state-rooted", testRuntimeSavedStateRootedAfterReset));
    suite.add(Testing::TestCase("heap-reset/time-effects-scanner", testTimeScannerAfterReset));
    suite.add(Testing::TestCase("heap-reset/http-effects-scanner", testHttpScannerAfterReset));
    suite.add(Testing::TestCase("heap-reset/mvar-scanner-and-old-mvars-gone", testMVarAfterReset));
}
