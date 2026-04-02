/**
 * Tests for generic apply boxing behavior with AllBoxed evaluator wrappers.
 *
 * Simulates the scenario where (==) is passed as a higher-order argument
 * (e.g. List.filter ((==) 5) list). The PAP captures an unboxed i64 and
 * the evaluator expects all-boxed (!eco.value) arguments. The generic apply
 * path must box captured unboxed values before calling the evaluator.
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
// Mock evaluator: simulates Basics_eq_$_4's evaluator wrapper ($clo clone).
//
// The real compiler-generated wrapper receives void*[] where all values are
// HPointer-encoded (boxed). It calls Elm_Kernel_Utils_equal on them.
// This mock does the same, plus validation.
// ============================================================================

static bool g_evaluator_called = false;
static bool g_args_were_valid_hptrs = false;
static bool g_equality_result = false;

static void* mock_eq_evaluator(void* args[]) {
    g_evaluator_called = true;

    // args[0] and args[1] should be boxed HPointer values (not raw i64).
    uint64_t a = reinterpret_cast<uint64_t>(args[0]);
    uint64_t b = reinterpret_cast<uint64_t>(args[1]);

    // Verify both are valid heap pointers to ElmInt objects.
    void* a_ptr = hptrToRaw(a);
    void* b_ptr = hptrToRaw(b);

    g_args_were_valid_hptrs = (a_ptr != nullptr && b_ptr != nullptr);

    if (g_args_were_valid_hptrs) {
        ElmInt* a_int = static_cast<ElmInt*>(a_ptr);
        ElmInt* b_int = static_cast<ElmInt*>(b_ptr);

        g_args_were_valid_hptrs =
            (a_int->header.tag == Tag_Int && b_int->header.tag == Tag_Int);

        g_equality_result = (a_int->value == b_int->value);
    }

    // Return boxed Bool, same as real Elm_Kernel_Utils_equal.
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
    uint64_t eq_closure = eco_alloc_closure(
        reinterpret_cast<void*>(&mock_eq_evaluator), 2);
    TEST_ASSERT(eq_closure != 0);

    // Step 2: Partially apply with unboxed i64 value 5.
    // This simulates ((==) 5) — the 5 is stored unboxed in the PAP.
    uint64_t raw_5 = static_cast<uint64_t>(5);
    uint64_t unboxed_bitmap = 1; // bit 0 set → arg[0] is unboxed
    uint64_t eq5_pap = eco_pap_extend(eq_closure, &raw_5, 1, unboxed_bitmap);
    TEST_ASSERT(eq5_pap != 0);

    // Verify the PAP has 1 captured value, 1 remaining.
    void* pap_ptr = hptrToRaw(eq5_pap);
    TEST_ASSERT(pap_ptr != nullptr);
    Closure* pap = static_cast<Closure*>(pap_ptr);
    TEST_ASSERT(pap->n_values == 1);
    TEST_ASSERT(pap->max_values == 2);
    TEST_ASSERT((pap->unboxed & 1) == 1); // captured value is unboxed

    // Step 3: Apply with one boxed arg (already an HPointer) to saturate.
    // eco_apply_closure expects HPointer-encoded args.
    uint64_t boxed_5 = eco_alloc_int(5);
    TEST_ASSERT(boxed_5 != 0);

    uint64_t result = eco_apply_closure(eq5_pap, &boxed_5, 1);

    // Verify evaluator was called and received valid boxed HPointers.
    TEST_ASSERT(g_evaluator_called);
    TEST_ASSERT(g_args_were_valid_hptrs);
    TEST_ASSERT(g_equality_result == true); // 5 == 5

    // Verify result is boxed True.
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result) == true);
}

// ============================================================================
// Test: Same setup but with unequal values → False
// Simulates: ((==) 5) 7
// ============================================================================

static void test_generic_apply_boxes_captured_unboxed_int_not_equal() {
    initAllocator();
    reset_tracking();

    uint64_t eq_closure = eco_alloc_closure(
        reinterpret_cast<void*>(&mock_eq_evaluator), 2);

    uint64_t raw_5 = static_cast<uint64_t>(5);
    uint64_t unboxed_bitmap = 1;
    uint64_t eq5_pap = eco_pap_extend(eq_closure, &raw_5, 1, unboxed_bitmap);

    uint64_t boxed_7 = eco_alloc_int(7);
    uint64_t result = eco_apply_closure(eq5_pap, &boxed_7, 1);

    TEST_ASSERT(g_evaluator_called);
    TEST_ASSERT(g_args_were_valid_hptrs);
    TEST_ASSERT(g_equality_result == false); // 5 != 7
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result) == false);
}

// ============================================================================
// Test: Use real Elm_Kernel_Utils_equal via a wrapper evaluator
//
// This is closer to what the compiler actually generates: the evaluator
// calls Elm_Kernel_Utils_equal on its boxed args.
// ============================================================================

static void* real_eq_evaluator(void* args[]) {
    uint64_t a = reinterpret_cast<uint64_t>(args[0]);
    uint64_t b = reinterpret_cast<uint64_t>(args[1]);
    uint64_t result = Elm_Kernel_Utils_equal(a, b);
    return reinterpret_cast<void*>(result);
}

static void test_generic_apply_with_real_kernel_equal() {
    initAllocator();

    // Create (==) closure, capture unboxed 42, then apply boxed 42.
    uint64_t eq_closure = eco_alloc_closure(
        reinterpret_cast<void*>(&real_eq_evaluator), 2);

    uint64_t raw_42 = static_cast<uint64_t>(42);
    uint64_t bitmap = 1;
    uint64_t eq42_pap = eco_pap_extend(eq_closure, &raw_42, 1, bitmap);

    // Apply with boxed 42 → should be True.
    uint64_t boxed_42 = eco_alloc_int(42);
    uint64_t result_eq = eco_apply_closure(eq42_pap, &boxed_42, 1);
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result_eq) == true);

    // Apply with boxed 99 → should be False.
    // Need a fresh PAP since the old one was consumed by saturated call.
    uint64_t eq42_pap2 = eco_pap_extend(eq_closure, &raw_42, 1, bitmap);
    uint64_t boxed_99 = eco_alloc_int(99);
    uint64_t result_neq = eco_apply_closure(eq42_pap2, &boxed_99, 1);
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result_neq) == false);
}

// ============================================================================
// Test: Both args unboxed (fully generic apply, no prior papExtend)
//
// Simulates what happens when lowerGenericApply boxes both i64 args at
// codegen time and calls eco_apply_closure directly.
// ============================================================================

static void test_generic_apply_both_args_boxed_at_callsite() {
    initAllocator();

    uint64_t eq_closure = eco_alloc_closure(
        reinterpret_cast<void*>(&real_eq_evaluator), 2);

    // Both args boxed by caller (as lowerGenericApply does).
    uint64_t boxed_10 = eco_alloc_int(10);
    uint64_t boxed_10b = eco_alloc_int(10);
    uint64_t args[2] = { boxed_10, boxed_10b };

    uint64_t result = eco_apply_closure(eq_closure, args, 2);
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result) == true);

    // Different values.
    uint64_t boxed_20 = eco_alloc_int(20);
    uint64_t args2[2] = { boxed_10, boxed_20 };
    uint64_t result2 = eco_apply_closure(eq_closure, args2, 2);
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result2) == false);
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
