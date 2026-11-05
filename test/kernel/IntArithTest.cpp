// Unit tests of the Int arithmetic kernel exports (elm-kernel-cpp/src/core/Basics) and the runtime helper
// `eco_int_pow`.
//
// Wrapping and pow (BASICS-01, BASICS-02, BASICS-NEW-1): the defect (signed-overflow UB in Int add/sub/mul/pow)
// is exposed at compile time by test/static-asserts/IntArith.cpp. The cases here call the real `extern "C"`
// symbols, `Elm_Kernel_Basics_add_Int`/`sub_Int`/`mul_Int`/`pow_Int` and `eco_int_pow`, with the same operands.
// They passed before the fix too, because the generated code wraps and the final square of `pow` is
// discarded, and are kept as regressions (and, for `eco_int_pow`, as a pin that it still delegates to
// `Elm::ecoIntPow`).
//
// modBy 0 (ABI-01): `Elm_Kernel_Basics_modBy(0, x)` threw std::runtime_error out of an `extern "C"` export
// (Basics::modBy), which would end a native program in std::terminate. Fixed by decision D1: the kernel returns
// 0, like the inline lowering (CGEN_084). The E2E witness is test/eco-divergence/src/ModByZeroKernelPathTest.elm.

#include "IntArithTest.hpp"

#include "../ForkedChild.hpp"
#include "../allocator/TestHelpers.hpp"

#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../../runtime/src/allocator/RuntimeExports.h"

#include <cstdint>
#include <cstdio>
#include <limits>
#include <string>

#if !defined(_WIN32)
#include <sys/wait.h>
#endif

namespace {

constexpr int64_t kMax = std::numeric_limits<int64_t>::max();
constexpr int64_t kMin = std::numeric_limits<int64_t>::min();

// The operands go through volatiles so that the calls are not folded at compile time.
int64_t opaque(int64_t v) {
    volatile int64_t x = v;
    return x;
}

// BASICS-01: Int + - * wrap modulo 2^64 (decision D31).
void testIntWrapRegression() {
    TEST_ASSERT(Elm_Kernel_Basics_add_Int(opaque(kMax), opaque(1)) == kMin);
    TEST_ASSERT(Elm_Kernel_Basics_sub_Int(opaque(kMin), opaque(1)) == kMax);
    TEST_ASSERT(Elm_Kernel_Basics_mul_Int(opaque(kMax), opaque(2)) == -2);
    TEST_ASSERT(Elm_Kernel_Basics_mul_Int(opaque(kMin), opaque(-1)) == kMin);
}

// BASICS-02: pow_Int gives the exact result whenever it fits.
void testPowIntRegression() {
    TEST_ASSERT(Elm_Kernel_Basics_pow_Int(opaque(2), opaque(62)) == 4611686018427387904LL);
    TEST_ASSERT(Elm_Kernel_Basics_pow_Int(opaque(3), opaque(39)) == 4052555153018976267LL);
    TEST_ASSERT(Elm_Kernel_Basics_pow_Int(opaque(-2), opaque(63)) == kMin);
    TEST_ASSERT(Elm_Kernel_Basics_pow_Int(opaque(5), opaque(-1)) == 0);
    TEST_ASSERT(Elm_Kernel_Basics_pow_Int(opaque(0), opaque(0)) == 1);
}

// BASICS-NEW-1: the runtime helper `eco.int.pow` lowers to, the same values.
void testEcoIntPowRegression() {
    TEST_ASSERT(eco_int_pow(opaque(2), opaque(62)) == 4611686018427387904LL);
    TEST_ASSERT(eco_int_pow(opaque(3), opaque(39)) == 4052555153018976267LL);
    TEST_ASSERT(eco_int_pow(opaque(7), opaque(22)) == 3909821048582988049LL);
    TEST_ASSERT(eco_int_pow(opaque(-2), opaque(63)) == kMin);
    TEST_ASSERT(eco_int_pow(opaque(5), opaque(-1)) == 0);
    TEST_ASSERT(eco_int_pow(opaque(0), opaque(0)) == 1);
}

#if !defined(_WIN32)

std::string describeStatus(int status) {
    if (WIFEXITED(status)) return "exit " + std::to_string(WEXITSTATUS(status));
    if (WIFSIGNALED(status)) return "signal " + std::to_string(WTERMSIG(status));
    return "status " + std::to_string(status);
}

// ---- ABI-01: kernel modBy 0 ---------------------------------------------------------------------

// `Elm_Kernel_Basics_modBy(0, 7)` returns 0 (D1) and the child exits 0. Before the fix
// Basics::modBy threw std::runtime_error("Elm.Kernel.Basics.modBy: modulus was zero"); in this
// C++ caller it unwound to runInChild's catch (exit 99, "exception: ..."); called from compiled
// Elm it would have reached std::terminate (SIGABRT).
void testModByZeroKernelExport() {
    ForkedChild::ChildResult r = ForkedChild::runInChild([] {
        volatile int64_t zero = 0;   // keep the call from being folded
        const int64_t got = Elm_Kernel_Basics_modBy(zero, 7);
        const int64_t gotNeg = Elm_Kernel_Basics_modBy(zero, -3);
        std::fprintf(stderr, "modBy 0 7 = %lld, modBy 0 -3 = %lld\n",
                     static_cast<long long>(got), static_cast<long long>(gotNeg));
        return (got == 0 && gotNeg == 0) ? 0 : 1;
    });
    const bool ok = WIFEXITED(r.status) && WEXITSTATUS(r.status) == 0;
    if (!ok) {
        TEST_FAIL("ABI-01: Elm_Kernel_Basics_modBy(0, x): " + describeStatus(r.status) + ", stderr: " +
                  r.stderrText);
    }
}

#endif  // !_WIN32

}  // namespace

void registerIntArithTests(Testing::TestSuite& suite) {
    suite.add(Testing::UnitTest("int-arith/add-sub-mul-wrap", testIntWrapRegression));
    suite.add(Testing::UnitTest("int-arith/pow-int-exact-when-it-fits", testPowIntRegression));
    suite.add(Testing::UnitTest("int-arith/eco-int-pow-exact-when-it-fits", testEcoIntPowRegression));
}

void registerIntArithIsolatedTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
#if !defined(_WIN32)
    suite.add(Testing::TestCase("int-arith/mod-by-zero-returns-zero", testModByZeroKernelExport));
#else
    (void)suite;
#endif
}
