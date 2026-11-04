// Unit tests of the Regex kernel's extern-"C" exports (elm-kernel-cpp/src/regex/).
//
//   error-path rooting (REGEX-03)  `Elm_Kernel_Regex_replaceAtMost` and `Elm_Kernel_Regex_splitAtMost` returned
//                                  the word their `str` argument was passed as from their `catch (...)` paths.
//                                  `str` was not rooted, so after a GC inside the loop (the replacer, or a part's
//                                  string allocation) that word named the pre-GC copy. The cases force a moving
//                                  minor GC (legacy semi-space nursery), then make the loop throw (srell runs out
//                                  of its backtracking budget on `(a+)+b`), and compare the returned word with the
//                                  rooted, forwarded `str`. Decision D7 narrowed the catch to srell's
//                                  `regex_error`, so a third case checks that an exception thrown by the replacer
//                                  propagates. The E2E twin is test/elm-regex/src/RegexCatchRootingTest.elm.
//   interning (REGEX-08)           `Elm_Kernel_Regex_fromStringWith` and `Elm_Kernel_Regex_never` `new`ed a
//                                  compiled pattern into a side table under a fresh id on every call and never
//                                  freed it, so compiling the same pattern twice gave two ids (and two leaked
//                                  engines). Equal patterns and flags are now interned to one id.

#include "RegexKernelTest.hpp"

#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"

#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../../elm-kernel-cpp/src/ExportHelpers.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/StringOps.hpp"

#include <cstdint>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

using namespace Elm;
using namespace Elm::TestHelpers;
namespace Export = Elm::Kernel::Export;

namespace {

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Returns the Elm record { caseInsensitive, multiline } (two boxed Bool slots, in that order).
HPointer regexOptions(bool caseInsensitive, bool multiline) {
    std::vector<Unboxable> fields(2);
    fields[0].p = Export::decode(Export::encodeBoxedBool(caseInsensitive));
    fields[1].p = Export::decode(Export::encodeBoxedBool(multiline));
    return alloc::record(fields, /*unboxed_mask=*/0);
}

// Returns the encoded Regex Custom inside the `Just` that `fromStringWith` returned, or 0 for
// Nothing / anything else.
uint64_t unwrapJustRegex(HPtr maybe) {
    void* p = Export::toPtr(maybe.toBits());
    if (!p) return 0;
    Custom* just = static_cast<Custom*>(p);
    if (just->header.tag != Tag_Custom) return 0;
    return Export::encode(just->values[0].p);
}

// Compiles `pattern` with the given flags; returns the encoded Regex or 0 when it did not compile.
uint64_t compileRegex(const std::string& pattern, bool caseInsensitive = false, bool multiline = false) {
    HPointer opts = regexOptions(caseInsensitive, multiline);
    StackRootGuard optsRoot(&opts);
    HPointer pat = alloc::allocStringFromUTF8(pattern);
    HPtr optsW = HPtr::fromBits(Export::encode(opts));
    HPtr patW = HPtr::fromBits(Export::encode(pat));
    return unwrapJustRegex(Elm_Kernel_Regex_fromStringWith(optsW, patW));
}

// Returns the side-table id (field 0) of an encoded Regex Custom, or -1.
int64_t regexId(uint64_t regexEnc) {
    void* p = Export::toPtr(regexEnc);
    if (!p) return -1;
    Custom* c = static_cast<Custom*>(p);
    if (c->ctor != 0xFF00) return -1;
    return c->values[0].i;
}

// Returns the UTF-8 text of an encoded Elm string ("" for the Empty constant / non-pointers).
std::string elmText(uint64_t enc) {
    HPointer hp = Export::decode(enc);
    if (alloc::isEmptyString(hp)) return "";
    void* p = Export::toPtr(enc);
    if (!p) return "";
    return StringOps::toStdString(p);
}

std::string hex(uint64_t w) {
    std::ostringstream o;
    o << "0x" << std::hex << w;
    return o.str();
}

// ---------------------------------------------------------------------------
// REGEX-03 (a): replaceAtMost's catch path returns the unrooted `str`
// ---------------------------------------------------------------------------

int g_replacerCalls = 0;

// The replacer, a 1-arity Match -> String closure evaluator. Call 1 runs a moving minor GC; every
// call returns "R".
void* replacerGcOnce(void* args[]) {
    (void)args;
    ++g_replacerCalls;
    if (g_replacerCalls == 1) {
        Allocator::instance().minorGC();
    }
    HPointer r = alloc::allocStringFromUTF8("R");
    return reinterpret_cast<void*>(Export::encode(r));
}

// A replacer that throws on its first call.
void* replacerThrows(void* args[]) {
    (void)args;
    ++g_replacerCalls;
    throw std::runtime_error("replacer throws");
}

void testReplaceCatchUnrooted() {
    initLegacyAllocator();  // the semi-space nursery always evacuates, so the GC moves `s`
    g_replacerCalls = 0;

    uint64_t reEnc = compileRegex(",|(a+)+b");
    TEST_ASSERT(reEnc != 0);
    HPointer reHP = Export::decode(reEnc);
    StackRootGuard reRoot(&reHP);

    // 50 "x," matches, each one a replacer call, then 30 'a's with no 'b': srell throws
    // error_complexity there, after the replacer's GC moved the subject.
    std::string subject;
    for (int i = 0; i < 50; ++i) subject += "x,";
    subject += std::string(30, 'a');

    HPointer sRoot = alloc::allocStringFromUTF8(subject);
    StackRootGuard sGuard(&sRoot);
    HPtr cl = eco_alloc_closure_fn(reinterpret_cast<void*>(&replacerGcOnce), 1, /*K=*/PK_Boxed);
    HPointer clHP = Export::decode(cl.toBits());
    StackRootGuard clGuard(&clHP);

    // No allocation from here to the call: these words are current.
    const uint64_t sBefore = Export::encode(sRoot);
    HPtr ret = Elm_Kernel_Regex_replaceAtMost(-1, HPtr::fromBits(Export::encode(reHP)),
                                              HPtr::fromBits(Export::encode(clHP)),
                                              HPtr::fromBits(sBefore));
    const uint64_t sAfter = Export::encode(sRoot);

    // Preconditions: the replacer ran (and collected) and the GC moved `s`.
    if (g_replacerCalls != 50) TEST_FAIL("replacer called " + std::to_string(g_replacerCalls) + " times, want 50");
    if (sAfter == sBefore) TEST_FAIL("the minor GC did not move the subject string; check is vacuous");
    TEST_ASSERT(elmText(sAfter) == subject);
    if (elmText(ret.toBits()) != subject && ret.toBits() != sBefore)
        TEST_FAIL("replaceAtMost did not take its error path (srell did not throw): got \"" +
                  elmText(ret.toBits()).substr(0, 20) + "...\"");

    if (ret.toBits() != sAfter)
        TEST_FAIL("replaceAtMost error path returned " + hex(ret.toBits()) + " (pre-GC word " + hex(sBefore) +
                  "), not the forwarded subject " + hex(sAfter));
}

// D7: only the regex engine's errors are caught; an exception from the replacer propagates.
void testReplacerExceptionPropagates() {
    initAllocator();
    g_replacerCalls = 0;

    uint64_t reEnc = compileRegex(",");
    TEST_ASSERT(reEnc != 0);
    HPointer reHP = Export::decode(reEnc);
    StackRootGuard reRoot(&reHP);
    HPointer sRoot = alloc::allocStringFromUTF8("a,b");
    StackRootGuard sGuard(&sRoot);
    HPtr cl = eco_alloc_closure_fn(reinterpret_cast<void*>(&replacerThrows), 1, /*K=*/PK_Boxed);
    HPointer clHP = Export::decode(cl.toBits());
    StackRootGuard clGuard(&clHP);

    bool propagated = false;
    try {
        (void)Elm_Kernel_Regex_replaceAtMost(-1, HPtr::fromBits(Export::encode(reHP)),
                                             HPtr::fromBits(Export::encode(clHP)),
                                             HPtr::fromBits(Export::encode(sRoot)));
    } catch (const std::runtime_error&) {
        propagated = true;
    }
    if (g_replacerCalls != 1) TEST_FAIL("replacer called " + std::to_string(g_replacerCalls) + " times, want 1");
    if (!propagated) TEST_FAIL("replaceAtMost swallowed the replacer's exception");
}

// ---------------------------------------------------------------------------
// REGEX-03 (b): splitAtMost's catch path returns the unrooted `str`
// ---------------------------------------------------------------------------

void testSplitCatchUnrooted() {
    // A small nursery, so that the parts' allocations run minor GCs inside the loop.
    HeapConfig cfg;
    cfg.nursery_block_count = 2;  // the minimum: one from-space and one to-space block
    initLegacyAllocator(cfg);

    uint64_t reEnc = compileRegex(",|(a+)+b");
    TEST_ASSERT(reEnc != 0);
    HPointer reHP = Export::decode(reEnc);
    StackRootGuard reRoot(&reHP);

    // 40,000 "x," parts (each one a string allocation, several MB in all), then 30 'a's with no
    // 'b': the alternative (a+)+b backtracks exponentially there and srell throws error_complexity.
    std::string subject;
    for (int i = 0; i < 40000; ++i) subject += "x,";
    subject += std::string(30, 'a');

    HPointer sRoot = alloc::allocStringFromUTF8(subject);
    StackRootGuard sGuard(&sRoot);

    const uint64_t sBefore = Export::encode(sRoot);
    HPtr ret = Elm_Kernel_Regex_splitAtMost(-1, HPtr::fromBits(Export::encode(reHP)), HPtr::fromBits(sBefore));
    const uint64_t sAfter = Export::encode(sRoot);

    // Preconditions: the result is the catch path's one-element list, and a GC moved `s`.
    void* lp = Export::toPtr(ret.toBits());
    if (!lp) TEST_FAIL("splitAtMost returned a non-pointer " + hex(ret.toBits()));
    Cons* cell = static_cast<Cons*>(lp);
    if (cell->header.tag != Tag_Cons) TEST_FAIL("splitAtMost result is not a cons cell");
    const uint64_t tailEnc = Export::encode(cell->tail);
    const bool singleton = Export::toPtr(tailEnc) == nullptr;
    if (!singleton) TEST_FAIL("splitAtMost did not take its catch path (more than one part): srell did not throw");
    if (sAfter == sBefore) TEST_FAIL("no GC moved the subject string inside splitAtMost; check is vacuous");
    TEST_ASSERT(elmText(sAfter) == subject);

    const uint64_t head = Export::encode(cell->head.p);
    if (head != sAfter)
        TEST_FAIL("splitAtMost error path's element is " + hex(head) + " (pre-GC word " + hex(sBefore) +
                  "), not the forwarded subject " + hex(sAfter));
}

// ---------------------------------------------------------------------------
// REGEX-08: equal pattern and flags compile to one interned side-table entry
// ---------------------------------------------------------------------------

void testRegexNotInterned() {
    initAllocator();

    const int64_t a1 = regexId(compileRegex("ab+"));
    const int64_t a2 = regexId(compileRegex("ab+"));
    const int64_t ci = regexId(compileRegex("ab+", /*caseInsensitive=*/true));
    const int64_t other = regexId(compileRegex("cd+"));
    const int64_t n1 = regexId(Elm_Kernel_Regex_never().toBits());
    const int64_t n2 = regexId(Elm_Kernel_Regex_never().toBits());

    TEST_ASSERT(a1 > 0 && a2 > 0 && ci > 0 && other > 0 && n1 > 0 && n2 > 0);
    // Controls: a different flag set or a different pattern is a different engine, interned or not.
    TEST_ASSERT(ci != a1);
    TEST_ASSERT(other != a1);
    TEST_ASSERT(other != ci);

    if (a1 != a2 || n1 != n2)
        TEST_FAIL("same pattern+flags compiled twice gave ids " + std::to_string(a1) + " and " +
                  std::to_string(a2) + "; never twice gave " + std::to_string(n1) + " and " +
                  std::to_string(n2) + " (one new leaked engine per call)");
}

}  // namespace

void registerRegexKernelTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
    // Each case initializes its own allocator (legacy nursery / small nursery), so it runs in a
    // fresh process.
    suite.add(Testing::TestCase("regex-kernel/replace-at-most-error-path-returns-rooted-subject", testReplaceCatchUnrooted));
    suite.add(Testing::TestCase("regex-kernel/replace-at-most-propagates-replacer-exception", testReplacerExceptionPropagates));
    suite.add(Testing::TestCase("regex-kernel/split-at-most-error-path-returns-rooted-subject", testSplitCatchUnrooted));
    suite.add(Testing::TestCase("regex-kernel/equal-pattern-and-flags-intern-to-one-id", testRegexNotInterned));
}
