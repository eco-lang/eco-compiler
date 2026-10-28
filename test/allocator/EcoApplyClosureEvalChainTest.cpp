/**
 * RUNTIME_CLOSURE_004: over-saturated generic apply chains per-stage
 * evaluators.
 *
 * `eco_apply_closure_eval` with num_args > remaining (max_values - n_values)
 * saturates the current stage through `eco_closure_call_saturated`, then
 * applies the trailing args to the intermediate closure that stage returned,
 * with a sub-layout built from the trailing kinds. The GC-safety story the
 * rule relies on:
 *
 *   - the trailing args sit in the caller's typed-args buffer, which the
 *     outer frame roots IN PLACE with `pushRootsByKinds` over ALL num_args
 *     slots, so a GC inside stage 1 updates them before stage 2 reads them;
 *   - the intermediate lives only in a C local up to the recursive call (no
 *     GC point in between), and the recursive call roots it with
 *     `ecoRoot1Push` before any allocation.
 *
 * Each stage's evaluator forces collections (minor, then major) while it
 * runs, so every boxed value the chain still needs -- trailing args, boxed
 * captures carried from stage to stage, the intermediate closures -- must
 * survive a moving GC. The arguments are mixed kinds (Int, Float, Char,
 * boxed), so a sub-layout that drops or shifts kinds would hand the next
 * stage raw primitive bits where it expects an HPointer (or vice versa).
 *
 * Each scenario runs under the region nursery (production default) and the
 * legacy semi-space nursery. The legacy nursery always evacuates, so there
 * the test also asserts that the trailing boxed arg actually MOVED (the
 * check is not vacuous); under the region nursery the move is reported only.
 */

#include "EcoApplyClosureEvalChainTest.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "TestHelpers.hpp"
#include "../TestSuite.hpp"
#include <cstring>
#include <cstdint>
#include <iostream>

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

void* hptrToRaw(uint64_t hptr) {
    if (hptr == 0) return nullptr;
    HPointer hp;
    std::memcpy(&hp, &hptr, sizeof(hp));
    if (hp.constant != 0) return nullptr;
    return Allocator::instance().resolve(hp);
}

// Reads a boxed ElmInt; returns `bad` (and flags it) when the word does not
// resolve to a Tag_Int object, e.g. a stale pointer into evacuated space.
int64_t boxedIntOr(uint64_t raw, int64_t bad, bool& ok) {
    void* p = hptrToRaw(raw);
    if (!p || getHeader(p)->tag != Tag_Int) {
        ok = false;
        return bad;
    }
    return static_cast<ElmInt*>(p)->value;
}

void setSlotKinds(HPtr closure, uint64_t bitmap) {
    Closure* c = static_cast<Closure*>(hptrToRaw(closure.toBits()));
    TEST_ASSERT(c != nullptr);
    c->unboxed = bitmap;
}

double asDouble(void* slot) {
    double d;
    uint64_t bits = reinterpret_cast<uint64_t>(slot);
    std::memcpy(&d, &bits, sizeof(d));
    return d;
}

void forceCollections(bool major) {
    Allocator& a = Allocator::instance();
    a.minorGC();
    if (major) a.majorGC();
}

// ---------------------------------------------------------------------------
// Scenario 1: two stages, primitive (Int) final result.
//
//   A : arity 3, kinds [Int, Boxed, Float], K = Boxed  -> returns B'
//   B : arity 5, kinds [Int, Boxed, Float, Char, Boxed], K = Int
//   B' = B with A's three args captured (2 trailing params remain)
//
// Called with 5 args [42, box 77, 2.5, 'Q', box 1000] and desired_kind = Int.
// A forces a minor + major GC before building B'.
// ---------------------------------------------------------------------------

struct TwoStageRecord {
    int a_calls = 0;
    int b_calls = 0;
    bool a_ok = true;
    bool b_ok = true;
    int64_t a_int = 0;
    double a_float = 0;
    int64_t a_boxed_val = 0;
    uint64_t b_args[5] = {};
    int64_t b_int = 0;
    int64_t b_cap_boxed_val = 0;
    double b_float = 0;
    uint32_t b_char = 0;
    int64_t b_trail_boxed_val = 0;
    bool major = false;
};
TwoStageRecord g2;

int64_t evalB_int(void* args[]) {
    g2.b_calls++;
    for (int i = 0; i < 5; ++i) g2.b_args[i] = reinterpret_cast<uint64_t>(args[i]);
    g2.b_int = reinterpret_cast<int64_t>(args[0]);
    g2.b_cap_boxed_val = boxedIntOr(g2.b_args[1], -1, g2.b_ok);
    g2.b_float = asDouble(args[2]);
    g2.b_char = static_cast<uint32_t>(g2.b_args[3] & 0xFFFFFFFFu);
    g2.b_trail_boxed_val = boxedIntOr(g2.b_args[4], -1, g2.b_ok);
    return g2.b_int + g2.b_cap_boxed_val + static_cast<int64_t>(g2.b_float * 2.0) +
           static_cast<int64_t>(g2.b_char) + g2.b_trail_boxed_val;
}

void* evalA_returnsB(void* args[]) {
    g2.a_calls++;
    g2.a_int = reinterpret_cast<int64_t>(args[0]);
    g2.a_float = asDouble(args[2]);
    // The GC point between the stages: the trailing args (still in the
    // caller's buffer) and this stage's boxed arg must all survive.
    forceCollections(g2.major);
    // args[] is the runtime's combined-args buffer, rooted in place.
    g2.a_boxed_val = boxedIntOr(reinterpret_cast<uint64_t>(args[1]), -1, g2.a_ok);

    HPtr b = eco_alloc_closure_fn(reinterpret_cast<void*>(&evalB_int), 5, /*K=*/PK_Int);
    // slot0 Int 01, slot1 Boxed 00, slot2 Float 10, slot3 Char 11, slot4 Boxed 00
    setSlotKinds(b, 0x1ULL | (0x2ULL << 4) | (0x3ULL << 6));
    static constexpr auto kCap = makeEvalParamLayout<3>(0, {PK_Int, PK_Boxed, PK_Float});
    HPtr bp = eco_pap_extend_l(b, reinterpret_cast<uint64_t*>(args), 3, asLayout(&kCap));
    return reinterpret_cast<void*>(bp.toBits());
}

void runTwoStage(bool legacy, bool major) {
    if (legacy) initLegacyAllocator(); else initAllocator();
    g2 = TwoStageRecord{};
    g2.major = major;

    HPtr a = eco_alloc_closure_fn(reinterpret_cast<void*>(&evalA_returnsB), 3, /*K=*/PK_Boxed);
    // slot0 Int 01, slot1 Boxed 00, slot2 Float 10
    setSlotKinds(a, 0x1ULL | (0x2ULL << 4));
    // Root the closure across the two boxed-arg allocations below.
    uint64_t a_bits = a.toBits();
    EcoRootMark mark = ecoRootMark();
    ecoRoot1Push(reinterpret_cast<HPointer*>(&a_bits));

    int64_t typed[5];
    typed[0] = 42;
    typed[1] = 0;
    double f = 2.5;
    std::memcpy(&typed[2], &f, sizeof(f));
    typed[3] = 'Q';
    typed[4] = 0;
    typed[1] = static_cast<int64_t>(eco_alloc_int(77).toBits());
    ecoRoot1Push(reinterpret_cast<HPointer*>(&typed[1]));
    typed[4] = static_cast<int64_t>(eco_alloc_int(1000).toBits());
    ecoRootRelease(mark);
    // No allocation from here to the call: the words are current.
    const uint64_t trail_before = static_cast<uint64_t>(typed[4]);

    auto layout = makeEvalParamLayout<5>(PK_Boxed, {PK_Int, PK_Boxed, PK_Float, PK_Char, PK_Boxed});
    int64_t result = -12345;
    eco_apply_closure_eval(HPtr::fromBits(a_bits), typed, 5, asLayout(&layout), &result,
                           /*desired_kind=*/PK_Int);

    TEST_ASSERT(g2.a_calls == 1);
    TEST_ASSERT(g2.b_calls == 1);
    TEST_ASSERT(g2.a_int == 42);
    TEST_ASSERT(g2.a_float == 2.5);
    TEST_ASSERT(g2.a_ok && g2.a_boxed_val == 77);   // stage-1 boxed arg survived its own GC
    TEST_ASSERT(g2.b_ok);                           // every boxed word stage 2 saw resolves to an Int
    TEST_ASSERT(g2.b_int == 42);                    // unboxed Int capture carried into stage 2
    TEST_ASSERT(g2.b_cap_boxed_val == 77);          // boxed capture carried into stage 2
    TEST_ASSERT(g2.b_float == 2.5);                 // unboxed Float capture
    TEST_ASSERT(g2.b_char == 'Q');                  // trailing Char kept its kind
    TEST_ASSERT(g2.b_trail_boxed_val == 1000);      // trailing boxed arg survived the GC
    TEST_ASSERT(result == 42 + 77 + 5 + 'Q' + 1000);

    // The outer frame rooted the caller's buffer in place: stage 2 received
    // exactly the (possibly forwarded) word now in typed[4].
    TEST_ASSERT(g2.b_args[4] == static_cast<uint64_t>(typed[4]));
    const bool moved = trail_before != static_cast<uint64_t>(typed[4]);
    if (legacy) {
        if (!moved) TEST_FAIL("precondition: the legacy minor GC did not move the trailing "
                              "boxed arg, so the GC-between-stages check is vacuous");
    } else {
        std::cout << "    region nursery: trailing boxed arg "
                  << (moved ? "moved" : "did not move") << " across the stage-1 GC\n";
    }
    bool ok = true;
    TEST_ASSERT(boxedIntOr(static_cast<uint64_t>(typed[4]), -1, ok) == 1000 && ok);
}

// ---------------------------------------------------------------------------
// Scenario 2: three stages, boxed final result (eco_apply_closure_typed), a
// GC in each of the first two stages, and a Float-returning last stage so
// the final delivery boxes.
//
//   A : arity 1, [Int],                      K = Boxed -> returns B'
//   B : arity 2, [Int, Float],               K = Boxed -> returns C'
//   C : arity 4, [Int, Float, Char, Boxed],  K = Float
//
// Called with 4 args [7, 0.5, 'z', box 5]. Stage B runs while ITS closure
// (the stage-1 intermediate) is rooted only by the recursive call's
// ecoRoot1Push, and the GC inside B moves it.
// ---------------------------------------------------------------------------

struct ThreeStageRecord {
    int a_calls = 0, b_calls = 0, c_calls = 0;
    int64_t b_cap_int = 0;
    double b_float = 0;
    int64_t c_int = 0;
    double c_float = 0;
    uint32_t c_char = 0;
    int64_t c_boxed_val = 0;
    bool c_ok = true;
    bool major = false;
};
ThreeStageRecord g3;

double evalC_float(void* args[]) {
    g3.c_calls++;
    g3.c_int = reinterpret_cast<int64_t>(args[0]);
    g3.c_float = asDouble(args[1]);
    g3.c_char = static_cast<uint32_t>(reinterpret_cast<uint64_t>(args[2]) & 0xFFFFFFFFu);
    g3.c_boxed_val = boxedIntOr(reinterpret_cast<uint64_t>(args[3]), -1, g3.c_ok);
    return static_cast<double>(g3.c_int) + g3.c_float + static_cast<double>(g3.c_char) +
           static_cast<double>(g3.c_boxed_val);
}

void* evalB_returnsC(void* args[]) {
    g3.b_calls++;
    g3.b_cap_int = reinterpret_cast<int64_t>(args[0]);
    g3.b_float = asDouble(args[1]);
    forceCollections(g3.major);
    HPtr c = eco_alloc_closure_fn(reinterpret_cast<void*>(&evalC_float), 4, /*K=*/PK_Float);
    // slot0 Int 01, slot1 Float 10, slot2 Char 11, slot3 Boxed 00
    setSlotKinds(c, 0x1ULL | (0x2ULL << 2) | (0x3ULL << 4));
    static constexpr auto kCap = makeEvalParamLayout<2>(0, {PK_Int, PK_Float});
    return reinterpret_cast<void*>(
        eco_pap_extend_l(c, reinterpret_cast<uint64_t*>(args), 2, asLayout(&kCap)).toBits());
}

void* evalA_returnsBC(void* args[]) {
    g3.a_calls++;
    forceCollections(g3.major);
    HPtr b = eco_alloc_closure_fn(reinterpret_cast<void*>(&evalB_returnsC), 2, /*K=*/PK_Boxed);
    // slot0 Int 01, slot1 Float 10
    setSlotKinds(b, 0x1ULL | (0x2ULL << 2));
    static constexpr auto kCap = makeEvalParamLayout<1>(0, {PK_Int});
    return reinterpret_cast<void*>(
        eco_pap_extend_l(b, reinterpret_cast<uint64_t*>(args), 1, asLayout(&kCap)).toBits());
}

void runThreeStage(bool legacy, bool major) {
    if (legacy) initLegacyAllocator(); else initAllocator();
    g3 = ThreeStageRecord{};
    g3.major = major;

    HPtr a = eco_alloc_closure_fn(reinterpret_cast<void*>(&evalA_returnsBC), 1, /*K=*/PK_Boxed);
    setSlotKinds(a, 0x1ULL);   // slot0 Int
    uint64_t a_bits = a.toBits();

    int64_t typed[4];
    typed[0] = 7;
    double f = 0.5;
    std::memcpy(&typed[1], &f, sizeof(f));
    typed[2] = 'z';
    typed[3] = 0;
    EcoRootMark mark = ecoRootMark();
    ecoRoot1Push(reinterpret_cast<HPointer*>(&a_bits));
    typed[3] = static_cast<int64_t>(eco_alloc_int(5).toBits());
    ecoRootRelease(mark);
    const uint64_t trail_before = static_cast<uint64_t>(typed[3]);

    auto layout = makeEvalParamLayout<4>(PK_Boxed, {PK_Int, PK_Float, PK_Char, PK_Boxed});
    HPtr result = eco_apply_closure_typed(HPtr::fromBits(a_bits), typed, 4, asLayout(&layout));

    TEST_ASSERT(g3.a_calls == 1);
    TEST_ASSERT(g3.b_calls == 1);
    TEST_ASSERT(g3.c_calls == 1);
    TEST_ASSERT(g3.b_cap_int == 7);
    TEST_ASSERT(g3.b_float == 0.5);
    TEST_ASSERT(g3.c_int == 7);
    TEST_ASSERT(g3.c_float == 0.5);
    TEST_ASSERT(g3.c_char == 'z');
    TEST_ASSERT(g3.c_ok && g3.c_boxed_val == 5);

    // K = Float with desired_kind = Boxed: the runtime boxes the final double.
    void* rp = hptrToRaw(result.toBits());
    TEST_ASSERT(rp != nullptr);
    TEST_ASSERT(getHeader(rp)->tag == Tag_Float);
    TEST_ASSERT(static_cast<ElmFloat*>(rp)->value == 7.0 + 0.5 + 'z' + 5.0);

    const bool moved = trail_before != static_cast<uint64_t>(typed[3]);
    if (legacy && !moved) {
        TEST_FAIL("precondition: the legacy minor GC did not move the trailing boxed arg, "
                  "so the GC-between-stages check is vacuous");
    }
}

void test_two_stage_region_minor()       { runTwoStage(false, false); }
void test_two_stage_region_minor_major() { runTwoStage(false, true); }
void test_two_stage_legacy_minor()       { runTwoStage(true, false); }
void test_two_stage_legacy_minor_major() { runTwoStage(true, true); }
void test_three_stage_region_minor()       { runThreeStage(false, false); }
void test_three_stage_region_minor_major() { runThreeStage(false, true); }
void test_three_stage_legacy_minor()       { runThreeStage(true, false); }
void test_three_stage_legacy_minor_major() { runThreeStage(true, true); }

} // namespace

void registerEcoApplyClosureEvalChainTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase(
        "RUNTIME_CLOSURE_004 two-stage over-saturated eval, Int result, minor GC (region)",
        test_two_stage_region_minor));
    suite.add(Testing::TestCase(
        "RUNTIME_CLOSURE_004 two-stage over-saturated eval, Int result, minor+major GC (region)",
        test_two_stage_region_minor_major));
    suite.add(Testing::TestCase(
        "RUNTIME_CLOSURE_004 two-stage over-saturated eval, Int result, minor GC (legacy)",
        test_two_stage_legacy_minor));
    suite.add(Testing::TestCase(
        "RUNTIME_CLOSURE_004 two-stage over-saturated eval, Int result, minor+major GC (legacy)",
        test_two_stage_legacy_minor_major));
    suite.add(Testing::TestCase(
        "RUNTIME_CLOSURE_004 three-stage over-saturated apply, boxed Float result, minor GC (region)",
        test_three_stage_region_minor));
    suite.add(Testing::TestCase(
        "RUNTIME_CLOSURE_004 three-stage over-saturated apply, boxed Float result, minor+major GC (region)",
        test_three_stage_region_minor_major));
    suite.add(Testing::TestCase(
        "RUNTIME_CLOSURE_004 three-stage over-saturated apply, boxed Float result, minor GC (legacy)",
        test_three_stage_legacy_minor));
    suite.add(Testing::TestCase(
        "RUNTIME_CLOSURE_004 three-stage over-saturated apply, boxed Float result, minor+major GC (legacy)",
        test_three_stage_legacy_minor_major));
}
