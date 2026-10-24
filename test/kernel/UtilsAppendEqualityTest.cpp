// SD-17 / SD-26 kernel ABI tests (review-bug-list.md).
//
// SD-17: `Utils::append` (elm-kernel-cpp/src/core/Utils.cpp) falls back to
// "return the first argument" for a pair it does not recognise. These tests
// drive Elm_Kernel_Utils_append (the polymorphic `++`) and the typed
// eco_string_append / eco_list_append exports with every String form
// (UTF-16 leaf, UTF-8 leaf, UTF-8 view, slice, rope, large split header,
// permanent interned literal, Empty constant) and every List spine form
// (Cons, ConsChunk, Nil constant) on either side, and check the result is the
// concatenation. They are a regression guard: they pass today.
//
// SD-26 (LATENT): REP_CONSTANT_003 (no longer in invariants.csv) said the
// Empty constant equals a zero-length heap String. HEAP_071 now forbids
// building one and no producer does, so the tests below build one by hand
// (a one-unit slice / UTF-8 leaf whose header.size is then set to 0) and ask
// each equality / ordering path whether it equals "". The paths that compare
// the raw words (Utils_equal, notEqual, compare, cmp3, eco_string_cmp3, and
// field equality inside a Tuple) FAIL; Tuple field ordering (cmpUnboxableSlot
// canonicalisation) and Eco.Hash pass.

#include "UtilsAppendEqualityTest.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/StringOps.hpp"
#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../../elm-kernel-cpp/src/ExportHelpers.hpp"
#include "../allocator/TestHelpers.hpp"
#include "../TestSuite.hpp"
#include <cstring>
#include <string>
#include <vector>

// Eco.Hash kernel (EcoKernel_Hash, whole-archived into the test binary).
extern "C" int64_t Eco_Kernel_Hash_stringWithSeed(int64_t seed, Elm::HPtr str);

using namespace Elm;
using namespace Elm::TestHelpers;
namespace Ex = Elm::Kernel::Export;

namespace {

// ---- helpers --------------------------------------------------------------

struct Form {
    const char* name;
    HPtr value;
    std::string text;  // expected UTF-8 contents
};

static std::string textOf(HPtr h) {
    return StringOps::toStdString(Ex::toPtr(h.toBits()));
}

static Tag tagOf(HPtr h) {
    return alloc::getTag(Ex::toPtr(h.toBits()));
}

static const uint8_t kLiteralBytes[] = {'l', 'i', 't'};

// Builds one value of every String form. Allocates only small objects plus one
// large string; the default test nursery does not collect during this.
static std::vector<Form> stringForms() {
    std::vector<Form> forms;

    // Large split header (UTF-16 body > LOT). Allocated FIRST: it is the only
    // allocation that could run a collection (large-body trigger), and nothing
    // unrooted is held yet.
    std::u16string big(6000, u'z');
    big[0] = u'ç';
    HPointer large = alloc::allocString(reinterpret_cast<const u16*>(big.data()), big.size());

    // UTF-16 leaf (non-ASCII so it can never be a UTF-8 form).
    std::u16string w16 = u"éx";
    HPointer leaf = alloc::allocString(reinterpret_cast<const u16*>(w16.data()), w16.size());
    forms.push_back({"utf16-leaf", HPtr::fromHPointer(leaf), "\xc3\xa9x"});

    // UTF-8 inline leaf.
    const u8 ab[] = {'a', 'b'};
    forms.push_back({"utf8-leaf", HPtr::fromHPointer(StringOps::makeUtf8LeafFromBytes(ab, 2)), "ab"});

    // UTF-8 view over a ByteBuffer.
    const char* src = "0123456789abcdefghij";
    HPointer bb = alloc::allocByteBuffer(reinterpret_cast<const u8*>(src), std::strlen(src));
    forms.push_back({"utf8-view", HPtr::fromHPointer(StringOps::makeUtf8View(bb, 2, 5)), "23456"});

    // Slice over a UTF-16 leaf.
    std::u16string u16b = u"épqrs";
    HPointer base = alloc::allocString(reinterpret_cast<const u16*>(u16b.data()), u16b.size());
    forms.push_back({"slice", HPtr::fromHPointer(StringOps::makeSlice(base, 1, 3)), "pqr"});

    // Rope of a UTF-8 leaf and a UTF-16 leaf.
    const u8 cd[] = {'c', 'd'};
    HPointer l = StringOps::makeUtf8LeafFromBytes(cd, 2);
    std::u16string u16c = u"è";
    HPointer r = alloc::allocString(reinterpret_cast<const u16*>(u16c.data()), u16c.size());
    forms.push_back({"rope", HPtr::fromHPointer(StringOps::makeRope(l, r)), "cd\xc3\xa8"});

    forms.push_back({"large", HPtr::fromHPointer(large),
                     std::string("\xc3\xa7") + std::string(5999, 'z')});

    // Permanent interned literal (PermanentSpace, outside the heap range).
    forms.push_back({"literal", eco_alloc_string_literal_utf8(kLiteralBytes, 3), "lit"});

    // The merged Empty constant ("").
    forms.push_back({"empty-const", HPtr::fromHPointer(alloc::emptyString()), ""});
    return forms;
}

static void checkFormTags(const std::vector<Form>& f) {
    TEST_ASSERT(tagOf(f[0].value) == Tag_String);
    TEST_ASSERT(tagOf(f[1].value) == Tag_StringUtf8Leaf);
    TEST_ASSERT(tagOf(f[2].value) == Tag_StringUtf8View);
    TEST_ASSERT(tagOf(f[3].value) == Tag_StringSlice);
    TEST_ASSERT(tagOf(f[4].value) == Tag_StringRope);
    TEST_ASSERT(tagOf(f[5].value) == Tag_LargeStringHeader);
    TEST_ASSERT(Ex::toPtr(f[7].value.toBits()) == nullptr);
    for (const Form& x : f) TEST_ASSERT(textOf(x.value) == x.text);
}

using AppendFn = HPtr (*)(HPtr, HPtr);

static void checkStringAppendMatrix(AppendFn fn, const char* fnName) {
    initAllocator();
    std::vector<Form> forms = stringForms();
    checkFormTags(forms);
    // Root every input across the appends (each may allocate and so collect).
    std::vector<HPointer> roots;
    for (const Form& x : forms) roots.push_back(x.value.toHPointer());
    StackRootRangeGuard guard(roots.data(), roots.size(), ~0ULL);
    for (size_t i = 0; i < forms.size(); ++i) {
        for (size_t j = 0; j < forms.size(); ++j) {
            const Form& a = forms[i];
            const Form& b = forms[j];
            HPtr r = fn(HPtr::fromHPointer(roots[i]), HPtr::fromHPointer(roots[j]));
            std::string got = textOf(r);
            if (got != a.text + b.text) {
                TEST_FAIL(std::string("SD-17 ") + fnName + "(" + a.name + ", " + b.name +
                          ") is not the concatenation (got " + std::to_string(got.size()) +
                          " bytes, expected " + std::to_string(a.text.size() + b.text.size()) + ")");
            }
        }
    }
}

// SD-17: polymorphic `++` on every String form pair.
static void test_sd17_utils_append_string_forms() {
    checkStringAppendMatrix(&Elm_Kernel_Utils_append, "Elm_Kernel_Utils_append");
}

// SD-17: typed eco.string.append export on every String form pair.
static void test_sd17_eco_string_append_forms() {
    checkStringAppendMatrix(&eco_string_append, "eco_string_append");
}

static HPointer consInts(const std::vector<i64>& vals) {
    HPointer list = alloc::listNil();
    for (auto it = vals.rbegin(); it != vals.rend(); ++it)
        list = alloc::cons(alloc::unboxedInt(*it), list, static_cast<u8>(1));
    return list;
}

static HPointer chunkInts(const std::vector<i64>& vals) {
    HPointer backing = alloc::listBacking(static_cast<u32>(vals.size()), 1);
    ListBacking* lb = static_cast<ListBacking*>(Allocator::instance().resolve(backing));
    for (size_t i = 0; i < vals.size(); i++) lb->elems[i].i = vals[i];
    return alloc::consChunkView(backing, 0, static_cast<u32>(vals.size()), alloc::listNil(), 1);
}

static std::vector<i64> intsOf(HPtr h) {
    std::vector<i64> out;
    for (alloc::ListCursor c(h.toHPointer()); !c.done(); c.next()) {
        TEST_ASSERT(c.currentKind() == 1u);
        out.push_back(c.current().i);
    }
    return out;
}

static void checkListAppendMatrix(AppendFn fn, const char* fnName) {
    initAllocator();
    struct LForm { const char* name; HPtr value; std::vector<i64> elems; };
    std::vector<LForm> forms = {
        {"cons", HPtr::fromHPointer(consInts({1, 2})), {1, 2}},
        {"chunk", HPtr::fromHPointer(chunkInts({3, 4, 5})), {3, 4, 5}},
        {"nil", HPtr::fromHPointer(alloc::listNil()), {}},
    };
    TEST_ASSERT(tagOf(forms[0].value) == Tag_Cons);
    TEST_ASSERT(tagOf(forms[1].value) == Tag_ConsChunk);
    std::vector<HPointer> roots;
    for (const LForm& x : forms) roots.push_back(x.value.toHPointer());
    StackRootRangeGuard guard(roots.data(), roots.size(), ~0ULL);
    for (size_t i = 0; i < forms.size(); ++i) {
        for (size_t j = 0; j < forms.size(); ++j) {
            const LForm& a = forms[i];
            const LForm& b = forms[j];
            std::vector<i64> want = a.elems;
            want.insert(want.end(), b.elems.begin(), b.elems.end());
            if (intsOf(fn(HPtr::fromHPointer(roots[i]), HPtr::fromHPointer(roots[j]))) != want) {
                TEST_FAIL(std::string("SD-17 ") + fnName + "(" + a.name + ", " + b.name +
                          ") is not the concatenation");
            }
        }
    }
}

// SD-17: polymorphic `++` on every List spine pair.
static void test_sd17_utils_append_list_forms() {
    checkListAppendMatrix(&Elm_Kernel_Utils_append, "Elm_Kernel_Utils_append");
}

// SD-17: typed eco.list.append export on every List spine pair.
static void test_sd17_eco_list_append_forms() {
    checkListAppendMatrix(&eco_list_append, "eco_list_append");
}

// ---- SD-26 ----------------------------------------------------------------

static HPtr emptyConst() { return HPtr::fromHPointer(alloc::emptyString()); }

// A zero-length heap String in two forms. Built by shrinking a one-unit
// object's header.size to 0; both stay >= 16 B (HEAP_071 is about the
// allocation size, which these keep).
static HPtr zeroLengthSlice() {
    std::u16string s = u"éq";
    HPointer base = alloc::allocString(reinterpret_cast<const u16*>(s.data()), s.size());
    HPointer slc = StringOps::makeSlice(base, 0, 1);
    static_cast<Header*>(Allocator::instance().resolve(slc))->size = 0;
    return HPtr::fromHPointer(slc);
}

static HPtr zeroLengthUtf8Leaf() {
    const u8 a[] = {'a'};
    HPointer leaf = StringOps::makeUtf8LeafFromBytes(a, 1);
    static_cast<Header*>(Allocator::instance().resolve(leaf))->size = 0;
    return HPtr::fromHPointer(leaf);
}

static std::vector<HPtr> zeroLengthForms() {
    std::vector<HPtr> v = {zeroLengthSlice(), zeroLengthUtf8Leaf()};
    for (HPtr z : v) {
        void* p = Ex::toPtr(z.toBits());
        TEST_ASSERT(p != nullptr && alloc::isString(p));
        TEST_ASSERT(StringOps::length(p) == 0);
    }
    return v;
}

static bool isTrue(HPtr b) { return Ex::decodeBoxedBool(b.toBits()); }

// SD-26 path 1: Elm_Kernel_Utils_equal ("" == z). FAILS today.
static void test_sd26_utils_equal() {
    initAllocator();
    for (HPtr z : zeroLengthForms()) {
        if (!isTrue(Elm_Kernel_Utils_equal(emptyConst(), z)))
            TEST_FAIL("SD-26: Elm_Kernel_Utils_equal(\"\", zero-length heap String) is False");
        if (!isTrue(Elm_Kernel_Utils_equal(z, emptyConst())))
            TEST_FAIL("SD-26: Elm_Kernel_Utils_equal(zero-length heap String, \"\") is False");
    }
}

// SD-26 path 2: Elm_Kernel_Utils_notEqual. FAILS today.
static void test_sd26_utils_not_equal() {
    initAllocator();
    for (HPtr z : zeroLengthForms()) {
        if (isTrue(Elm_Kernel_Utils_notEqual(emptyConst(), z)))
            TEST_FAIL("SD-26: Elm_Kernel_Utils_notEqual(\"\", zero-length heap String) is True");
    }
}

// SD-26 path 3: Elm_Kernel_Utils_compare (also Dict keys). FAILS today (LT).
static void test_sd26_utils_compare() {
    initAllocator();
    uint64_t eq = Eco_Runtime_getOrderEQ().toBits();
    for (HPtr z : zeroLengthForms()) {
        if (Elm_Kernel_Utils_compare(emptyConst(), z).toBits() != eq)
            TEST_FAIL("SD-26: Elm_Kernel_Utils_compare(\"\", zero-length heap String) is not EQ");
        if (Elm_Kernel_Utils_compare(z, emptyConst()).toBits() != eq)
            TEST_FAIL("SD-26: Elm_Kernel_Utils_compare(zero-length heap String, \"\") is not EQ");
    }
}

// SD-26 path 4: Elm_Kernel_Utils_cmp3 (compare-case rewrite). FAILS today.
static void test_sd26_utils_cmp3() {
    initAllocator();
    for (HPtr z : zeroLengthForms()) {
        if (Elm_Kernel_Utils_cmp3(emptyConst(), z) != 0)
            TEST_FAIL("SD-26: Elm_Kernel_Utils_cmp3(\"\", zero-length heap String) != 0");
    }
}

// SD-26 path 5: eco_string_cmp3 (eco.string.cmp3 / cmp_order lowering). FAILS today.
static void test_sd26_eco_string_cmp3() {
    initAllocator();
    for (HPtr z : zeroLengthForms()) {
        if (eco_string_cmp3(emptyConst(), z) != 0)
            TEST_FAIL("SD-26: eco_string_cmp3(\"\", zero-length heap String) != 0");
        if (eco_string_cmp3(z, emptyConst()) != 0)
            TEST_FAIL("SD-26: eco_string_cmp3(zero-length heap String, \"\") != 0");
    }
}

static HPtr tupleStrInt(HPtr s, i64 n) {
    // slot 0 boxed (kind 0), slot 1 unboxed Int (kind 1 -> bits 2..3 = 01).
    return HPtr::fromHPointer(
        alloc::tuple2(alloc::boxed(s.toHPointer()), alloc::unboxedInt(n), 0x4));
}

// SD-26 path 6: structural equality of a field ( ("", 1) == (z, 1) ). FAILS today
// (resolveAndCompare compares the raw words when either side is a constant).
static void test_sd26_tuple_field_equal() {
    initAllocator();
    for (HPtr z : zeroLengthForms()) {
        HPtr a = tupleStrInt(emptyConst(), 1);
        HPtr b = tupleStrInt(z, 1);
        if (!isTrue(Elm_Kernel_Utils_equal(a, b)))
            TEST_FAIL("SD-26: (\"\", 1) == (zero-length heap String, 1) is False");
    }
}

// SD-26 path 7: ordering of a field (compare ("", 1) (z, 1)). The one path that
// canonicalises the Empty constant against a zero-length heap String; PASSES.
static void test_sd26_tuple_field_compare() {
    initAllocator();
    uint64_t eq = Eco_Runtime_getOrderEQ().toBits();
    for (HPtr z : zeroLengthForms()) {
        HPtr a = tupleStrInt(emptyConst(), 1);
        HPtr b = tupleStrInt(z, 1);
        TEST_ASSERT(Elm_Kernel_Utils_compare(a, b).toBits() == eq);
        TEST_ASSERT(Elm_Kernel_Utils_compare(b, a).toBits() == eq);
    }
}

// SD-26 path 8: Eco.Hash string hash. Constant and zero-length both hash to the
// seed; PASSES.
static void test_sd26_hash() {
    initAllocator();
    for (HPtr z : zeroLengthForms()) {
        TEST_ASSERT(Eco_Kernel_Hash_stringWithSeed(12345, emptyConst()) ==
                    Eco_Kernel_Hash_stringWithSeed(12345, z));
    }
}

}  // namespace

void registerUtilsAppendEqualityTests(Testing::TestSuite& suite) {
    suite.add(Testing::UnitTest("SD-17 Utils_append string forms", test_sd17_utils_append_string_forms));
    suite.add(Testing::UnitTest("SD-17 eco_string_append string forms", test_sd17_eco_string_append_forms));
    suite.add(Testing::UnitTest("SD-17 Utils_append list forms", test_sd17_utils_append_list_forms));
    suite.add(Testing::UnitTest("SD-17 eco_list_append list forms", test_sd17_eco_list_append_forms));
    suite.add(Testing::UnitTest("SD-26 [latent] Utils_equal empty vs zero-length heap", test_sd26_utils_equal));
    suite.add(Testing::UnitTest("SD-26 [latent] Utils_notEqual empty vs zero-length heap", test_sd26_utils_not_equal));
    suite.add(Testing::UnitTest("SD-26 [latent] Utils_compare empty vs zero-length heap", test_sd26_utils_compare));
    suite.add(Testing::UnitTest("SD-26 [latent] Utils_cmp3 empty vs zero-length heap", test_sd26_utils_cmp3));
    suite.add(Testing::UnitTest("SD-26 [latent] eco_string_cmp3 empty vs zero-length heap", test_sd26_eco_string_cmp3));
    suite.add(Testing::UnitTest("SD-26 [latent] tuple field equal empty vs zero-length heap", test_sd26_tuple_field_equal));
    suite.add(Testing::UnitTest("SD-26 tuple field compare empty vs zero-length heap", test_sd26_tuple_field_compare));
    suite.add(Testing::UnitTest("SD-26 Eco.Hash empty vs zero-length heap", test_sd26_hash));
}
