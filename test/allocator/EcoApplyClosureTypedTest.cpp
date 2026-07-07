/**
 * Tests for eco_apply_closure_typed (Phase D Part 1) and the migrated
 * eco_apply_segmentation_unknown (Phase D Part 2).
 *
 * The typed entry points take a single `int64_t*` args buffer plus an
 * `EvalParamLayout` describing each slot's primitive kind. The runtime
 * helper re-boxes any non-PK_Boxed slot via eco_alloc_int / eco_alloc_float
 * / eco_alloc_char before invoking the evaluator. These tests pin down:
 *
 *   1. Mixed primitive kinds (Int/Float/Char/Boxed) in a single call.
 *   2. The legacy null-layout path (every slot treated as PK_Boxed).
 *   3. Zero-arg calls go through cleanly.
 *   4. eco_apply_segmentation_unknown saturated branch (typed args only).
 */

#include "EcoApplyClosureTypedTest.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../elm-kernel-cpp/src/ExportHelpers.hpp"
#include "TestHelpers.hpp"
#include "../TestSuite.hpp"
#include <cstring>
#include <cstdint>

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

// Backing storage for a stack-built EvalParamLayout. The struct has two
// header bytes (num_params + result_kind) BEFORE the flexible kinds[] array,
// so we need `2 + MaxN` bytes — not `1 + MaxN`. The earlier off-by-one let
// the final kinds[] write spill past the buffer; the runtime then read an
// uninitialized byte for that slot's kind and silently treated it as
// PK_Boxed, leaking raw primitive bits straight through to the evaluator.
template <unsigned MaxN>
struct LayoutStorage {
    alignas(EvalParamLayout) unsigned char buf[2 + MaxN] = {};

    EvalParamLayout* layout() {
        return reinterpret_cast<EvalParamLayout*>(buf);
    }

    static LayoutStorage build(std::initializer_list<unsigned char> kinds) {
        LayoutStorage s;
        EvalParamLayout* l = s.layout();
        l->num_params = static_cast<unsigned char>(kinds.size());
        unsigned i = 0;
        for (unsigned char k : kinds) l->kinds[i++] = k;
        return s;
    }
};

// Helper: convert HPointer (as uint64_t) to raw pointer.
void* hptrToRaw(uint64_t hptr) {
    if (hptr == 0) return nullptr;
    HPointer hp;
    std::memcpy(&hp, &hptr, sizeof(hp));
    if (hp.constant != 0) return nullptr;
    return Allocator::instance().resolve(hp);
}

// Mock evaluator state. The evaluator records each received arg's tag and
// payload; the test then asserts they match what was passed in.
struct EvalRecord {
    bool called = false;
    int n_args = 0;
    int tags[8] = {};        // Tag_Int / Tag_Float / Tag_Char / 0
    int64_t int_vals[8] = {};
    double  float_vals[8] = {};
    uint16_t char_vals[8] = {};
    uint64_t boxed_raw[8] = {};
};

EvalRecord g_record;

void resetRecord() {
    g_record = EvalRecord{};
}

// Evaluator wrapper: receives all args HPointer-encoded, decodes by tag.
// The *first* arg is considered the "result" producer — it builds a boxed
// Bool(true) so callers can verify a clean round-trip.
void* mock_recording_evaluator(void* args[]) {
    g_record.called = true;
    int n = g_record.n_args;
    for (int i = 0; i < n && i < 8; ++i) {
        uint64_t raw = reinterpret_cast<uint64_t>(args[i]);
        g_record.boxed_raw[i] = raw;
        void* p = hptrToRaw(raw);
        if (!p) {
            g_record.tags[i] = -1;  // not a heap pointer
            continue;
        }
        Header* h = static_cast<Header*>(p) - 0; // Header* points to head of object
        // The runtime objects begin with a Header field; reinterpret as such.
        Header* hdr = getHeader(p);
        g_record.tags[i] = hdr->tag;
        switch (hdr->tag) {
            case Tag_Int:   g_record.int_vals[i]   = static_cast<ElmInt*>(p)->value;   break;
            case Tag_Float: g_record.float_vals[i] = static_cast<ElmFloat*>(p)->value; break;
            case Tag_Char:  g_record.char_vals[i]  = static_cast<ElmChar*>(p)->value;  break;
            default: break; // leave zero
        }
    }
    // Return a boxed True so callers can verify the result round-trips.
    return reinterpret_cast<void*>(Elm::Kernel::Export::encodeBoxedBool(true));
}

} // namespace

// ============================================================================
// Test: mixed primitive kinds in one call (Int, Float, Char, Boxed)
// ============================================================================

static void test_eco_apply_closure_typed_mixed_kinds() {
    initAllocator();
    resetRecord();

    // 4-arg closure, no captures.
    g_record.n_args = 4;
    HPtr closure = eco_alloc_closure(
        reinterpret_cast<void*>(&mock_recording_evaluator), 4);
    TEST_ASSERT(closure.toBits() != 0);

    // Pre-allocate the boxed input that backs slot 3 (PK_Boxed).
    // Use an already-boxed Int(123) so we can verify identity preservation.
    uint64_t pre_boxed = eco_alloc_int(123).toBits();
    TEST_ASSERT(pre_boxed != 0);

    // Build typed args: Int=42, Float=3.5, Char='Z'(0x5A), Boxed=pre_boxed
    int64_t typed_args[4];
    typed_args[0] = 42;
    double f = 3.5;
    std::memcpy(&typed_args[1], &f, sizeof(double));
    typed_args[2] = static_cast<int64_t>(0x5A);
    typed_args[3] = static_cast<int64_t>(pre_boxed);

    auto layoutBuf = LayoutStorage<4>::build(
        {/*PK_Int*/1, /*PK_Float*/2, /*PK_Char*/3, /*PK_Boxed*/0});

    HPtr result = eco_apply_closure_typed(closure, typed_args, 4, layoutBuf.layout());

    TEST_ASSERT(g_record.called);
    TEST_ASSERT(g_record.n_args == 4);

    // Slot 0: Int 42 was re-boxed into a fresh ElmInt.
    TEST_ASSERT(g_record.tags[0] == Tag_Int);
    TEST_ASSERT(g_record.int_vals[0] == 42);

    // Slot 1: Float 3.5 was re-boxed into a fresh ElmFloat.
    TEST_ASSERT(g_record.tags[1] == Tag_Float);
    TEST_ASSERT(g_record.float_vals[1] == 3.5);

    // Slot 2: Char 'Z' was re-boxed into a fresh ElmChar.
    TEST_ASSERT(g_record.tags[2] == Tag_Char);
    TEST_ASSERT(g_record.char_vals[2] == 0x5A);

    // Slot 3: pre-existing boxed Int(123) was passed through unchanged.
    TEST_ASSERT(g_record.tags[3] == Tag_Int);
    TEST_ASSERT(g_record.int_vals[3] == 123);
    TEST_ASSERT(g_record.boxed_raw[3] == pre_boxed);

    // Result round-trips.
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result.toBits()) == true);
}

// ============================================================================
// Test: null layout = legacy all-boxed semantics
// ============================================================================

static void test_eco_apply_closure_typed_null_layout_treats_all_as_boxed() {
    initAllocator();
    resetRecord();

    g_record.n_args = 2;
    HPtr closure = eco_alloc_closure(
        reinterpret_cast<void*>(&mock_recording_evaluator), 2);

    uint64_t a = eco_alloc_int(7).toBits();
    uint64_t b = eco_alloc_int(11).toBits();
    int64_t typed_args[2] = { static_cast<int64_t>(a), static_cast<int64_t>(b) };

    HPtr result = eco_apply_closure_typed(closure, typed_args, 2, /*args_layout=*/nullptr);

    TEST_ASSERT(g_record.called);
    TEST_ASSERT(g_record.tags[0] == Tag_Int);
    TEST_ASSERT(g_record.int_vals[0] == 7);
    TEST_ASSERT(g_record.tags[1] == Tag_Int);
    TEST_ASSERT(g_record.int_vals[1] == 11);
    TEST_ASSERT(g_record.boxed_raw[0] == a);
    TEST_ASSERT(g_record.boxed_raw[1] == b);
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result.toBits()) == true);
}

// ============================================================================
// Test: zero-arg call short-circuits to eco_apply_closure
// ============================================================================

static void test_eco_apply_closure_typed_zero_args() {
    initAllocator();
    resetRecord();

    g_record.n_args = 0;
    // Build a 0-arg closure to satisfy max_values check on the apply path.
    // (This evaluator is never invoked for true 0-arg apply, but
    // eco_apply_closure handles num_args=0 by returning the closure as-is.)
    HPtr closure = eco_alloc_closure(
        reinterpret_cast<void*>(&mock_recording_evaluator), 1);

    HPtr result = eco_apply_closure_typed(closure, nullptr, 0, /*args_layout=*/nullptr);
    // We do not assert on result content here — the contract for num_args=0
    // is "forward to eco_apply_closure(closure, nullptr, 0)" which today
    // returns the closure HPtr unchanged. Just check it didn't crash and
    // produced a non-null HPtr.
    TEST_ASSERT(result.toBits() != 0);
    TEST_ASSERT(!g_record.called);
}

// ============================================================================
// Test: eco_apply_segmentation_unknown (saturated branch) goes through the
// typed-args path and reaches the evaluator with re-boxed args.
// ============================================================================

static void test_eco_apply_segmentation_unknown_saturated_typed() {
    initAllocator();
    resetRecord();

    g_record.n_args = 2;
    HPtr closure = eco_alloc_closure(
        reinterpret_cast<void*>(&mock_recording_evaluator), 2);

    // Saturate with one Int and one Float at once (no captures, max=2).
    int64_t typed_args[2];
    typed_args[0] = 99;
    double f = -2.25;
    std::memcpy(&typed_args[1], &f, sizeof(double));

    auto layoutBuf = LayoutStorage<2>::build({/*PK_Int*/1, /*PK_Float*/2});

    HPtr result = eco_apply_segmentation_unknown(
        closure, typed_args, 2, layoutBuf.layout());

    TEST_ASSERT(g_record.called);
    TEST_ASSERT(g_record.tags[0] == Tag_Int);
    TEST_ASSERT(g_record.int_vals[0] == 99);
    TEST_ASSERT(g_record.tags[1] == Tag_Float);
    TEST_ASSERT(g_record.float_vals[1] == -2.25);
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result.toBits()) == true);
}

// ============================================================================
// Phase D Part 3: typed-newargs fast path
//
// `eco_apply_closure_typed` dispatches to the closure's evaluator directly
// with the typed args buffer — NO re-boxing of Int/Float/Char slots, hence
// zero eco_alloc_int/_float/_char calls on the apply path. Per-slot kind
// is read from `closure->unboxed[i]` (Phase F retired the dedicated flag
// bit; the bitmap is the single source of truth).
// ============================================================================

namespace {

// Records what each slot in the typed args array was, decoded according to
// a known kind sequence. The test then asserts the decode matches the
// caller's intent.
struct TypedRecord {
    bool called = false;
    int64_t  int_val   = 0;
    double   float_val = 0.0;
    uint16_t char_val  = 0;
};

TypedRecord g_typed_record;

void resetTypedRecord() {
    g_typed_record = TypedRecord{};
}

// Typed evaluator: signature is the standard `void*(void*[])`, but the args
// array slots hold raw primitives at known kinds (no HPtr unbox needed).
// Kind sequence for this evaluator: {PK_Int, PK_Float, PK_Char}.
void* mock_typed_evaluator(void* args[]) {
    g_typed_record.called = true;
    int64_t* slots = reinterpret_cast<int64_t*>(args);

    g_typed_record.int_val = slots[0];
    std::memcpy(&g_typed_record.float_val, &slots[1], sizeof(double));
    g_typed_record.char_val = static_cast<uint16_t>(
        static_cast<uint64_t>(slots[2]) & 0xFFFFu);

    // Return a boxed True so callers can verify a clean round-trip.
    return reinterpret_cast<void*>(Elm::Kernel::Export::encodeBoxedBool(true));
}

}  // namespace

static void test_typed_newargs_skips_reboxing() {
    initAllocator();
    resetTypedRecord();

    // Allocate a 3-arg closure for the typed evaluator.
    HPtr closure_hptr = eco_alloc_closure(
        reinterpret_cast<void*>(&mock_typed_evaluator), 3);
    TEST_ASSERT(closure_hptr.toBits() != 0);

    // Phase F semantics: the closure header records per-slot kinds in
    // `unboxed` (2 bits per slot). The runtime dispatches directly per
    // these kinds — no flag bit needed.
    {
        void* p = Allocator::instance().resolve(
            closure_hptr.toHPointer());
        TEST_ASSERT(p != nullptr);
        Closure* closure = static_cast<Closure*>(p);
        // kinds: slot0=PK_Int(0b01), slot1=PK_Float(0b10), slot2=PK_Char(0b11)
        // packed 2-bit-per-slot bitmap = 0b11_10_01 = 0x39.
        closure->unboxed = 0x39;
    }

    // Build typed args: Int 7, Float 1.25, Char 'X' (0x58).
    int64_t typed_args[3];
    typed_args[0] = 7;
    double f = 1.25;
    std::memcpy(&typed_args[1], &f, sizeof(double));
    typed_args[2] = static_cast<int64_t>(0x58);

    auto layoutBuf = LayoutStorage<3>::build(
        {/*PK_Int*/1, /*PK_Float*/2, /*PK_Char*/3});

    // Snapshot the allocator's object counter ACROSS the apply call only.
    // Anything before this point (closure alloc, etc.) is excluded.
    uint64_t before = Allocator::instance().getCombinedStats().objects_allocated;

    HPtr result = eco_apply_closure_typed(
        closure_hptr, typed_args, 3, layoutBuf.layout());

    uint64_t after = Allocator::instance().getCombinedStats().objects_allocated;

    // Evaluator received raw primitives intact.
    TEST_ASSERT(g_typed_record.called);
    TEST_ASSERT(g_typed_record.int_val == 7);
    TEST_ASSERT(g_typed_record.float_val == 1.25);
    TEST_ASSERT(g_typed_record.char_val == 0x58);

    // The evaluator allocates ONE object (the boxed Bool result via
    // encodeBoxedBool — but encodeBoxedBool is a constant HPointer, not a
    // heap alloc; verify by counter delta == 0).
    //
    // Re-boxing of three primitive args would have added 3 to the counter
    // (eco_alloc_int + eco_alloc_float + eco_alloc_char). The typed-newargs
    // path must do none of that.
    TEST_ASSERT(after - before == 0);

    // Result round-trips.
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result.toBits()) == true);
}

// Negative control: same closure config but WITHOUT the flag → re-boxing
// happens, counter delta is non-zero. This proves the previous test isn't
// trivially passing because no boxing would have occurred.
static void test_legacy_path_still_reboxes() {
    initAllocator();
    resetRecord();

    g_record.n_args = 3;
    HPtr closure_hptr = eco_alloc_closure(
        reinterpret_cast<void*>(&mock_recording_evaluator), 3);

    int64_t typed_args[3];
    typed_args[0] = 7;
    double f = 1.25;
    std::memcpy(&typed_args[1], &f, sizeof(double));
    typed_args[2] = static_cast<int64_t>(0x58);

    auto layoutBuf = LayoutStorage<3>::build(
        {/*PK_Int*/1, /*PK_Float*/2, /*PK_Char*/3});

    uint64_t before = Allocator::instance().getCombinedStats().objects_allocated;
    HPtr result = eco_apply_closure_typed(
        closure_hptr, typed_args, 3, layoutBuf.layout());
    uint64_t after = Allocator::instance().getCombinedStats().objects_allocated;

    // Three primitives → three eco_alloc_* calls on the legacy path.
    TEST_ASSERT(after - before >= 3);
    TEST_ASSERT(Elm::Kernel::Export::decodeBoxedBool(result.toBits()) == true);
}

// ============================================================================
// Registration
// ============================================================================

void registerEcoApplyClosureTypedTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase(
        "eco_apply_closure_typed mixed primitive kinds",
        test_eco_apply_closure_typed_mixed_kinds));
    suite.add(Testing::TestCase(
        "eco_apply_closure_typed null layout treats all as boxed",
        test_eco_apply_closure_typed_null_layout_treats_all_as_boxed));
    suite.add(Testing::TestCase(
        "eco_apply_closure_typed zero args",
        test_eco_apply_closure_typed_zero_args));
    suite.add(Testing::TestCase(
        "typed-newargs flag skips reboxing (zero allocs)",
        test_typed_newargs_skips_reboxing));
    suite.add(Testing::TestCase(
        "legacy path still reboxes primitive args",
        test_legacy_path_still_reboxes));
    suite.add(Testing::TestCase(
        "eco_apply_segmentation_unknown saturated typed",
        test_eco_apply_segmentation_unknown_saturated_typed));
}
