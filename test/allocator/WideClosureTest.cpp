/**
 * Closure layout v2 tests (plans/wide-object-tail-kind-words-phase-2.md 2.6.7, 2.6.8, 2.3).
 *
 * Packed word n_values:11 | max_values:11 | result_kind:2 | unboxed:40 (params 0..19 inline);
 * params 20.. live in K = extWords(max_values, 20) extension kind words, the LAST K words of
 * the object (header.size = value slots + K). These tests build "compiled" closures of stage
 * arity 20..2047 with kinds cycling Int/Float/Char/boxed, grow them with eco_pap_extend_l in
 * steps of 1, 7, 20 and 63 (with caller-kind conversions), force minor and major GCs between
 * the extends, and saturate into an evaluator that checks every slot. Each arity runs in a
 * fork()ed child so a regression fails one test, not the binary.
 */

#include "WideClosureTest.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "TestHelpers.hpp"
#include "../TestSuite.hpp"
#include <csignal>
#include <cstring>
#if !defined(_WIN32)
#include <sys/wait.h>
#include <unistd.h>
#endif
#include <vector>

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

// ---- compile-time layout checks (2.3, 2.4, 2.6.1) ----
static_assert(sizeof(Closure) == 24, "Closure base is 24 bytes");
static_assert(offsetof(EvaluatorDesc, stage_arity) == 18, "stage_arity:u16 at +18");
static_assert(offsetof(EvaluatorDesc, result_kind) == 17, "result_kind at +17");
static_assert(offsetof(EvaluatorDesc, sat) == 24, "sat at +24");
static_assert(sizeof(EvaluatorDesc) == 24, "EvaluatorDesc header is 24 bytes");
static_assert(offsetof(EvalParamLayout, num_params) == 0, "num_params at +0");
static_assert(offsetof(EvalParamLayout, result_kind) == 2, "result_kind at +2");
static_assert(offsetof(EvalParamLayout, kinds) == 4, "kinds at +4");
static_assert(CLOSURE_HDR_SLOTS == 20 && CLOSURE_MAX_ARITY == 2047 && SAT_MAX_ARITY == 20);
static_assert(extWords(20, CLOSURE_HDR_SLOTS) == 0 && extWords(21, CLOSURE_HDR_SLOTS) == 1);
static_assert(extWords(52, CLOSURE_HDR_SLOTS) == 1 && extWords(53, CLOSURE_HDR_SLOTS) == 2);
static_assert(extWords(2047, CLOSURE_HDR_SLOTS) == 64);

#if !defined(_WIN32)   // fork()ed children: POSIX only; those tests are no-ops on Windows
template <class F> int runInChild(F f) {
    pid_t pid = fork();
    if (pid == 0) {
        f();
        _exit(0);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFSIGNALED(st) ? -WTERMSIG(st) : WEXITSTATUS(st);
}
#endif

// Slot i's kind, and the value it carries.
u8 kindFor(u32 i) {
    static const u8 k[4] = {PK_Int, PK_Float, PK_Char, PK_Boxed};
    return k[i % 4];
}
i64 intVal(u32 i) { return static_cast<i64>(i) * 7 + 1; }
double floatVal(u32 i) { return static_cast<double>(i) + 0.5; }
u16 charVal(u32 i) { return static_cast<u16>(65 + i % 1000); }

// Raw slot bits for kind k (the boxed case is allocated by the caller).
uint64_t rawFor(u32 i, u8 k) {
    switch (k) {
        case PK_Int: return static_cast<uint64_t>(intVal(i));
        case PK_Float: { double f = floatVal(i); uint64_t r; std::memcpy(&r, &f, 8); return r; }
        case PK_Char: return charVal(i);
        default: return 0;
    }
}

// What the caller delivers for slot i: usually the slot's own kind, but some
// Int slots arrive boxed (un-box conversion) and some boxed slots arrive as a
// raw Int (box conversion), exercising convertArgToSlotKind.
u8 callerKindFor(u32 i) {
    const u8 k = kindFor(i);
    if (k == PK_Int && i % 8 == 1) return PK_Boxed;
    if (k == PK_Boxed && i % 8 == 3) return PK_Int;
    return k;
}

i64 boxedInt(uint64_t bits) {
    HPointer hp;
    std::memcpy(&hp, &bits, sizeof(hp));
    void* o = Allocator::instance().resolve(hp);
    if (!o || getHeader(o)->tag != Tag_Int) return INT64_MIN;
    return static_cast<ElmInt*>(o)->value;
}

u32 g_expectMax = 0;
bool g_ok = false;
u32 g_calls = 0;

bool slotOk(u32 i, uint64_t raw) {
    switch (kindFor(i)) {
        case PK_Int: return static_cast<i64>(raw) == intVal(i);
        case PK_Float: { double f; std::memcpy(&f, &raw, 8); return f == floatVal(i); }
        case PK_Char: return (raw & 0xFFFF) == charVal(i);
        default: return boxedInt(raw) == intVal(i);
    }
}

// The generic (args-array) evaluator of a "compiled" closure: checks every slot.
void* evalCheck(void** args) {
    ++g_calls;
    bool ok = true;
    for (u32 i = 0; i < g_expectMax; ++i)
        ok = ok && slotOk(i, reinterpret_cast<uint64_t>(args[i]));
    g_ok = ok;
    return reinterpret_cast<void*>(eco_alloc_int(ok ? 1 : 0).toBits());
}

// A closure as the papCreate lowering builds it: kinds of every param, the
// first 20 inline, the rest in the K tail words (writes the fresh object; no
// allocation in between).
uint64_t makeCompiledClosure(u32 max) {
    HPointer c = alloc::allocClosureK(evalCheck, max, PK_Boxed);
    Closure* cl = static_cast<Closure*>(Allocator::instance().resolve(c));
    u64 hdr = 0;
    for (u32 i = 0; i < std::min(max, CLOSURE_HDR_SLOTS); ++i) hdr |= u64(kindFor(i)) << (2 * i);
    cl->unboxed = hdr;
    const u32 K = extWords(max, CLOSURE_HDR_SLOTS);
    u64* ext = reinterpret_cast<u64*>(&cl->values[max]);
    for (u32 j = 0; j < K; ++j) {
        u64 w = 0;
        for (u32 b = 0; b < SLOTS_PER_EXT_WORD; ++b) {
            const u32 s = CLOSURE_HDR_SLOTS + j * SLOTS_PER_EXT_WORD + b;
            if (s < max) w |= u64(kindFor(s)) << (2 * b);
        }
        ext[j] = w;
    }
    uint64_t bits;
    std::memcpy(&bits, &c, sizeof(bits));
    return bits;
}

Closure* closureOf(uint64_t bits) {
    HPointer hp;
    std::memcpy(&hp, &bits, sizeof(hp));
    return static_cast<Closure*>(Allocator::instance().resolve(hp));
}

// Every slot's kind as declared, plus the physical-size rule. Exit codes name
// the failing check.
void checkClosure(uint64_t bits, u32 n, u32 max) {
    Closure* cl = closureOf(bits);
    if (cl->n_values != n || cl->max_values != max) _exit(10);
    if (cl->header.size != n + extWords(max, CLOSURE_HDR_SLOTS) &&
        cl->header.size != max + extWords(max, CLOSURE_HDR_SLOTS)) _exit(11);
    if (!closureWellFormed(cl)) _exit(12);
    ClosureKinds ks;
    snapshotClosureKinds(cl, ks);
    for (u32 i = 0; i < max; ++i) {
        if (closureSlotKind(cl, i) != kindFor(i)) _exit(13);
        if (closureKindAt(ks, i) != kindFor(i)) _exit(14);
    }
    for (u32 i = 0; i < n; ++i)
        if (!slotOk(i, static_cast<uint64_t>(cl->values[i].i))) _exit(15);
}

// Grows a closure of stage arity `max` by `step` args at a time, GCs between
// the extends, and saturates the last chunk into evalCheck.
[[maybe_unused]] void runChain(u32 max, u32 step) {
    uint64_t clo = makeCompiledClosure(max);
    StackRootGuard guard(reinterpret_cast<HPointer*>(&clo));
    checkClosure(clo, 0, max);
    const u32 chunks = (max + step - 1) / step;
    const u32 gcEvery = std::max<u32>(1, chunks / 8);
    u32 n = 0, chunk = 0;
    g_expectMax = max;
    g_ok = false;
    const u32 callsBefore = g_calls;
    while (n < max) {
        const u32 take = std::min(step, max - n);
        std::vector<uint64_t> args(take, 0);
        std::vector<unsigned char> lbuf(4 + take, 0);
        auto* layout = reinterpret_cast<EvalParamLayout*>(lbuf.data());
        layout->num_params = static_cast<unsigned short>(take);
        for (u32 j = 0; j < take; ++j) layout->kinds[j] = callerKindFor(n + j);
        // Root the args by caller kind before filling (boxing may GC).
        const size_t saved = eco_gc_stack_range_point();
        pushRootsByKinds(args.data(), take, [&](uint32_t j) { return layout->kinds[j]; });
        for (u32 j = 0; j < take; ++j) {
            const u32 s = n + j;
            const u8 ck = layout->kinds[j];
            if (ck == PK_Boxed) args[j] = eco_alloc_int(intVal(s)).toBits();
            else if (kindFor(s) == PK_Boxed) args[j] = static_cast<uint64_t>(intVal(s));  // box conversion
            else args[j] = rawFor(s, ck);
        }
        if (n + take == max) {
            HPtr r = eco_closure_call_saturated(HPtr::fromBits(clo), args.data(), take, layout);
            eco_gc_restore_stack_range_point(saved);
            if (g_calls != callsBefore + 1) _exit(20);
            if (!g_ok) _exit(21);
            if (boxedInt(r.toBits()) != 1) _exit(22);
        } else {
            HPtr e = eco_pap_extend_l(HPtr::fromBits(clo), args.data(), take, layout);
            eco_gc_restore_stack_range_point(saved);
            clo = e.toBits();
            if (clo == 0) _exit(23);
            checkClosure(clo, n + take, max);
            if (++chunk % gcEvery == 0) {
                if ((chunk / gcEvery) % 2) Allocator::instance().minorGC();
                else Allocator::instance().majorGC();
                checkClosure(clo, n + take, max);
            }
        }
        n += take;
    }
}

void runArity(u32 max, const HeapConfig* cfg) {
#if defined(_WIN32)
    (void)max;
    (void)cfg;
#else
    int r = runInChild([&] {
        if (cfg) initAllocator(*cfg);
        else initAllocator(pressureHeapConfig());
        for (u32 step : {1u, 7u, 20u, 63u}) runChain(max, step);
    });
    TEST_ASSERT(r == 0);
#endif
}

void test_wide_closure_20() { runArity(20, nullptr); }
void test_wide_closure_21() { runArity(21, nullptr); }
void test_wide_closure_52() { runArity(52, nullptr); }
void test_wide_closure_53() { runArity(53, nullptr); }
void test_wide_closure_300() { runArity(300, nullptr); }
void test_wide_closure_2047() { runArity(2047, nullptr); }

// Arity 1100 (an 8.8 KiB object) with the large-pointer nursery cap at 0: every
// large closure is placed in the YLOS (HEAP_062).
void test_wide_closure_1100_ylos() {
    HeapConfig cfg;
    cfg.alloc_buffer_size = 32 * 1024;
    cfg.nursery_block_count = 4;
    cfg.nursery_max_block_count = 4;
    cfg.initial_old_gen_size = 256 * 1024;
    cfg.max_heap_size = 512ULL * 1024 * 1024;
    cfg.large_object_threshold = 8 * 1024;
    cfg.large_ptr_nursery_divisor = 0;
    cfg.decommit_on_oldgen_release = false;
    cfg.gc_thread_mode = 0;
    cfg.validate();
    runArity(1100, &cfg);
}

// eco_alloc_closure_k / allocClosureK write all K ext words, zeros included.
void test_alloc_writes_zero_ext_words() {
#if !defined(_WIN32)
    int r = runInChild([] {
        initAllocator();
        for (u32 max : {0u, 19u, 20u, 21u, 52u, 53u, 2047u}) {
            HPtr c = eco_alloc_closure_fn(reinterpret_cast<void*>(&evalCheck), max, 0);
            Closure* cl = closureOf(c.toBits());
            const u32 K = extWords(max, CLOSURE_HDR_SLOTS);
            if (cl->header.size != max + K) _exit(2);
            if (!closureWellFormed(cl)) _exit(3);
            const u64* ext = closureExtWords(cl);
            for (u32 j = 0; j < K; ++j) if (ext[j] != 0) _exit(4);
            if (cl->evaluator->stage_arity != max) _exit(5);
        }
        // Over the limit: release abort.
        int rr = runInChild([] { (void)eco_alloc_closure_fn(reinterpret_cast<void*>(&evalCheck), 2048, 0); });
        if (rr != -SIGABRT) _exit(6);
    });
    TEST_ASSERT(r == 0);
#endif
}

// HEAP_077: kernel closure slots >= 20 are boxed; a typed capture at idx 20 aborts.
void test_closure_capture_typed_at_20_aborts() {
#if !defined(_WIN32)
    int r = runInChild([] {
        initAllocator();
        HPointer c = alloc::allocClosureK(evalCheck, 30, PK_Boxed);
        for (int i = 0; i < 20; ++i) {
            Unboxable u;
            u.p = alloc::allocInt(i);
            alloc::closureCapture(Allocator::instance().resolve(c), u, PK_Boxed);
        }
        Unboxable v;
        v.i = 7;
        alloc::closureCapture(Allocator::instance().resolve(c), v, PK_Int);
    });
    TEST_ASSERT(r == -SIGABRT);
#endif
}

// 2.6.8: a kernel descriptor above SAT_MAX_ARITY has no sat slots.
u32 g_sumArity = 0;
i64 g_sum = 0;
[[maybe_unused]] void* evalSumBoxed(void** args) {
    i64 s = 0;
    for (u32 i = 0; i < g_sumArity; ++i) s += boxedInt(reinterpret_cast<uint64_t>(args[i]));
    g_sum = s;
    return reinterpret_cast<void*>(eco_alloc_int(s).toBits());
}

void test_kernel_desc_above_sat_max() {
#if !defined(_WIN32)
    int r = runInChild([] {
        initAllocator();
        const EvaluatorDesc* d20 = ecoDescForKernelEvaluator(evalSumBoxed, 20, 0);
        const EvaluatorDesc* d21 = ecoDescForKernelEvaluator(evalSumBoxed, 21, 0);
        if (d20 == d21) _exit(2);
        if (d20->stage_arity != 20 || d21->stage_arity != 21) _exit(3);
        if (d20->sat[20] != nullptr) _exit(4);   // sat[0..20] exists and is null
        for (u32 arity : {20u, 21u}) {
            g_sumArity = arity;
            HPointer c = alloc::allocClosureK(evalSumBoxed, arity, PK_Boxed);
            Closure* cl = static_cast<Closure*>(Allocator::instance().resolve(c));
            if (cl->evaluator != (arity == 20 ? d20 : d21)) _exit(5);
            std::vector<uint64_t> args(arity, 0);
            const size_t saved = eco_gc_stack_range_point();
            pushRootsByKinds(args.data(), arity, [](uint32_t) { return 0u; });
            StackRootGuard g(&c);
            i64 expect = 0;
            for (u32 i = 0; i < arity; ++i) {
                args[i] = eco_alloc_int(intVal(i)).toBits();
                expect += intVal(i);
            }
            uint64_t cbits;
            std::memcpy(&cbits, &c, sizeof(cbits));
            HPtr res = eco_apply_closure(HPtr::fromBits(cbits), args.data(), arity);
            eco_gc_restore_stack_range_point(saved);
            if (boxedInt(res.toBits()) != expect || g_sum != expect) _exit(6);
        }
    });
    TEST_ASSERT(r == 0);
#endif
}

// B19: getAllBoxedLayout no longer clamps n to 63.
void test_all_boxed_layout_100() {
    for (uint8_t K = 0; K < 4; ++K) {
        const EvalParamLayout* l = getAllBoxedLayout(100, K);
        TEST_ASSERT(l != nullptr);
        TEST_ASSERT(l->num_params == 100);
        TEST_ASSERT(l->result_kind == K);
        for (u32 i = 0; i < 100; ++i) TEST_ASSERT(l->kinds[i] == 0);
        TEST_ASSERT(getAllBoxedLayout(100, K) == l);   // interned
    }
    const EvalParamLayout* l64 = getAllBoxedLayout(64, 2);
    TEST_ASSERT(l64->num_params == 64 && l64->result_kind == 2);
    const EvalParamLayout* l2047 = getAllBoxedLayout(CLOSURE_MAX_ARITY, 0);
    TEST_ASSERT(l2047->num_params == CLOSURE_MAX_ARITY);
}

// makeEvalParamLayout is layout-compatible with EvalParamLayout.
void test_make_eval_param_layout() {
    static constexpr auto l = makeEvalParamLayout<3>(2, {1, 0, 3});
    const EvalParamLayout* p = asLayout(&l);
    TEST_ASSERT(p->num_params == 3);
    TEST_ASSERT(p->result_kind == 2);
    TEST_ASSERT(p->kinds[0] == 1 && p->kinds[1] == 0 && p->kinds[2] == 3);
}

} // namespace

void registerWideClosureTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase("WideClosure: arity 20 extend chains + GC + saturate", test_wide_closure_20));
    suite.add(Testing::TestCase("WideClosure: arity 21 extend chains + GC + saturate", test_wide_closure_21));
    suite.add(Testing::TestCase("WideClosure: arity 52 extend chains + GC + saturate", test_wide_closure_52));
    suite.add(Testing::TestCase("WideClosure: arity 53 extend chains + GC + saturate", test_wide_closure_53));
    suite.add(Testing::TestCase("WideClosure: arity 300 extend chains + GC + saturate", test_wide_closure_300));
    suite.add(Testing::TestCase("WideClosure: arity 1100 in the YLOS (divisor 0)", test_wide_closure_1100_ylos));
    suite.add(Testing::TestCase("WideClosure: arity 2047 extend chains + GC + saturate", test_wide_closure_2047));
    suite.add(Testing::TestCase("WideClosure: allocation writes zero ext words; 2048 aborts",
                                test_alloc_writes_zero_ext_words));
    suite.add(Testing::TestCase("WideClosure: closureCapture of a typed kind at idx 20 aborts",
                                test_closure_capture_typed_at_20_aborts));
    suite.add(Testing::TestCase("WideClosure: kernel descriptor above SAT_MAX_ARITY has no sat slots",
                                test_kernel_desc_above_sat_max));
    suite.add(Testing::TestCase("WideClosure: getAllBoxedLayout(100, K) has num_params 100",
                                test_all_boxed_layout_100));
    suite.add(Testing::TestCase("WideClosure: makeEvalParamLayout matches EvalParamLayout",
                                test_make_eval_param_layout));
}
