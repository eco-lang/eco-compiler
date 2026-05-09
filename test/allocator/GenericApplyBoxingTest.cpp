/**
 * Tests for generic apply behavior with PAPs whose captures are stored
 * unboxed.
 *
 * Simulates `((==) 5)` where 5 is captured unboxed in a 2-arg PAP. Under
 * the post-Phase-D ABI, `closure->unboxed` is the wrapper's contract for
 * BOTH captures and new args: a 2-bit kind per slot. Captures stored at
 * kind=Int reach the evaluator as raw `int64_t`; new args are converted
 * by the runtime to match the slot's declared kind. There is no implicit
 * auto-boxing of captures — the mock evaluators below honour the same
 * asymmetric encoding the compiler-generated wrappers do.
 */

#include "GenericApplyBoxingTest.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../../elm-kernel-cpp/src/ExportHelpers.hpp"
#include "TestHelpers.hpp"
#include "../TestSuite.hpp"
#include <cstring>
#include <cassert>

using namespace Elm;
using namespace Elm::TestHelpers;

// Helper: convert HPointer (as uint64_t) to raw pointer.
static void* hptrToRaw(uint64_t hptr) {
    if (hptr == 0) return nullptr;
    HPointer hp;
    std::memcpy(&hp, &hptr, sizeof(hp));
    if (hp.constant != 0) return nullptr;
    return Allocator::instance().resolve(hp);
}

// ============================================================================
// Mock evaluator: matches the asymmetric (Int unboxed, Int boxed) signature a
// compiler-generated wrapper for `((==) 5)` produces when slot 0 is captured
// unboxed and slot 1 arrives via the boxed-args generic-apply path. The
// runtime passes args[0] as raw i64 (per `closure->unboxed[0] = Int`) and
// args[1] as a boxed HPointer (per `closure->unboxed[1] = Boxed`).
// ============================================================================

static bool g_evaluator_called = false;
static bool g_args_were_valid_hptrs = false;
static bool g_equality_result = false;

static void* mock_eq_evaluator(void* args[]) {
    g_evaluator_called = true;

    // Slot 0: raw int64_t (unboxed capture). Slot 1: HPointer to ElmInt.
    int64_t a = reinterpret_cast<int64_t>(args[0]);
    uint64_t b = reinterpret_cast<uint64_t>(args[1]);

    void* b_ptr = hptrToRaw(b);
    g_args_were_valid_hptrs = (b_ptr != nullptr);

    if (g_args_were_valid_hptrs) {
        ElmInt* b_int = static_cast<ElmInt*>(b_ptr);
        g_args_were_valid_hptrs = (b_int->header.tag == Tag_Int);
        g_equality_result = (a == b_int->value);
    }

    return reinterpret_cast<void*>(
        Elm::Kernel::Export::encodeBoxedBool(g_equality_result));
}

// Reset global tracking state.
static void reset_tracking() {
    g_evaluator_called = false;
    g_args_were_valid_hptrs = false;
    g_equality_result = false;
}

// ============================================================================
// Test: PAP with unboxed capture, saturated via eco_apply_closure
//
// Simulates: let eq = (==) in eq 5 5
// 1. papCreate with mock_eq_evaluator, arity=2, no captures
// 2. papExtend to capture unboxed i64 5 (bitmap=1) → PAP with 1 remaining
// 3. eco_apply_closure with boxed i64 5 → saturated call
// Evaluator must receive two valid boxed HPointers.
// ============================================================================

static void test_generic_apply_boxes_captured_unboxed_int_equal() {
    initAllocator();
    reset_tracking();

    // Step 1: Create a closure for (==) with arity 2, no captures.
    HPtr eq_closure = eco_alloc_closure(
        reinterpret_cast<void*>(&mock_eq_evaluator), 2);
    TEST_ASSERT(eq_closure.toBits() != 0);

    // Step 2: Partially apply with unboxed i64 value 5.
    // This simulates ((==) 5) — the 5 is stored unboxed in the PAP.
    uint64_t raw_5 = static_cast<uint64_t>(5);
    uint64_t unboxed_bitmap = 1; // bit 0 set → arg[0] is unboxed
    HPtr eq5_pap = eco_pap_extend(eq_closure, &raw_5, 1, unboxed_bitmap);
    TEST_ASSERT(eq5_pap.toBits() != 0);

    // Verify the PAP has 1 captured value, 1 remaining.
    void* pap_ptr = hptrToRaw(eq5_pap.toBits());
    TEST_ASSERT(pap_ptr != nullptr);
    Closure* pap = static_cast<Closure*>(pap_ptr);
    TEST_ASSERT(pap->n_values == 1);
    TEST_ASSERT(pap->max_values == 2);
    TEST_ASSERT((pap->unboxed & 1) == 1); // captured value is unboxed

    // Step 3: Apply with one boxed arg (already an HPointer) to saturate.
    // eco_apply_closure expects HPointer-encoded args.
    uint64_t boxed_5 = eco_alloc_int(5).toBits();
    TEST_ASSERT(boxed_5 != 0);

    HPtr result = eco_apply_closure(eq5_pap, &boxed_5, 1);

    // Verify evaluator was called and received valid boxed HPointers.
    TEST_ASSERT(g_evaluator_called);
    TEST_ASSERT(g_args_were_valid_hptrs);
    TEST_ASSERT(g_equality_result == true); // 5 == 5

    // Verify result is boxed True.
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result.toBits()) == true);
}

// ============================================================================
// Test: Same setup but with unequal values → False
// Simulates: ((==) 5) 7
// ============================================================================

static void test_generic_apply_boxes_captured_unboxed_int_not_equal() {
    initAllocator();
    reset_tracking();

    HPtr eq_closure = eco_alloc_closure(
        reinterpret_cast<void*>(&mock_eq_evaluator), 2);

    uint64_t raw_5 = static_cast<uint64_t>(5);
    uint64_t unboxed_bitmap = 1;
    HPtr eq5_pap = eco_pap_extend(eq_closure, &raw_5, 1, unboxed_bitmap);

    uint64_t boxed_7 = eco_alloc_int(7).toBits();
    HPtr result = eco_apply_closure(eq5_pap, &boxed_7, 1);

    TEST_ASSERT(g_evaluator_called);
    TEST_ASSERT(g_args_were_valid_hptrs);
    TEST_ASSERT(g_equality_result == false); // 5 != 7
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result.toBits()) == false);
}

// ============================================================================
// Test: Use real Elm_Kernel_Utils_equal via a wrapper evaluator.
//
// `real_eq_evaluator_asymmetric` matches the asymmetric (Int unboxed, Int
// boxed) signature used by the papExtend tests above — the wrapper boxes
// its raw-int slot before delegating to the boxed-args runtime kernel.
// `real_eq_evaluator_all_boxed` matches the symmetric all-boxed bitmap
// (closure->unboxed = 0) used by the direct-call test below.
// ============================================================================

static void* real_eq_evaluator_asymmetric(void* args[]) {
    int64_t a_raw = reinterpret_cast<int64_t>(args[0]);
    uint64_t b = reinterpret_cast<uint64_t>(args[1]);
    HPtr a_boxed = eco_alloc_int(a_raw);
    HPtr result = Elm_Kernel_Utils_equal(a_boxed, HPtr::fromBits(b));
    return reinterpret_cast<void*>(result.toBits());
}

static void* real_eq_evaluator_all_boxed(void* args[]) {
    uint64_t a = reinterpret_cast<uint64_t>(args[0]);
    uint64_t b = reinterpret_cast<uint64_t>(args[1]);
    HPtr result = Elm_Kernel_Utils_equal(HPtr::fromBits(a), HPtr::fromBits(b));
    return reinterpret_cast<void*>(result.toBits());
}

static void test_generic_apply_with_real_kernel_equal() {
    initAllocator();

    // Create (==) closure, capture unboxed 42, then apply boxed 42.
    HPtr eq_closure = eco_alloc_closure(
        reinterpret_cast<void*>(&real_eq_evaluator_asymmetric), 2);

    uint64_t raw_42 = static_cast<uint64_t>(42);
    uint64_t bitmap = 1;
    HPtr eq42_pap = eco_pap_extend(eq_closure, &raw_42, 1, bitmap);

    // Apply with boxed 42 → should be True.
    uint64_t boxed_42 = eco_alloc_int(42).toBits();
    HPtr result_eq = eco_apply_closure(eq42_pap, &boxed_42, 1);
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result_eq.toBits()) == true);

    // Apply with boxed 99 → should be False.
    // Need a fresh PAP since the old one was consumed by saturated call.
    HPtr eq42_pap2 = eco_pap_extend(eq_closure, &raw_42, 1, bitmap);
    uint64_t boxed_99 = eco_alloc_int(99).toBits();
    HPtr result_neq = eco_apply_closure(eq42_pap2, &boxed_99, 1);
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result_neq.toBits()) == false);
}

// ============================================================================
// Test: Both args unboxed (fully generic apply, no prior papExtend)
//
// Simulates what happens when lowerGenericApply boxes both i64 args at
// codegen time and calls eco_apply_closure directly.
// ============================================================================

static void test_generic_apply_both_args_boxed_at_callsite() {
    initAllocator();

    HPtr eq_closure = eco_alloc_closure(
        reinterpret_cast<void*>(&real_eq_evaluator_all_boxed), 2);

    // Both args boxed by caller (as lowerGenericApply does).
    uint64_t boxed_10 = eco_alloc_int(10).toBits();
    uint64_t boxed_10b = eco_alloc_int(10).toBits();
    uint64_t args[2] = { boxed_10, boxed_10b };

    HPtr result = eco_apply_closure(eq_closure, args, 2);
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result.toBits()) == true);

    // Different values.
    uint64_t boxed_20 = eco_alloc_int(20).toBits();
    uint64_t args2[2] = { boxed_10, boxed_20 };
    HPtr result2 = eco_apply_closure(eq_closure, args2, 2);
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result2.toBits()) == false);
}

// ============================================================================
// Registration
// ============================================================================

void registerGenericApplyBoxingTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase(
        "generic apply boxes captured unboxed int (equal)",
        test_generic_apply_boxes_captured_unboxed_int_equal));
    suite.add(Testing::TestCase(
        "generic apply boxes captured unboxed int (not equal)",
        test_generic_apply_boxes_captured_unboxed_int_not_equal));
    suite.add(Testing::TestCase(
        "generic apply with real Elm_Kernel_Utils_equal",
        test_generic_apply_with_real_kernel_equal));
    suite.add(Testing::TestCase(
        "generic apply both args boxed at callsite",
        test_generic_apply_both_args_boxed_at_callsite));
}
