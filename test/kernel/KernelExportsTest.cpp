// Kernel extern-"C" ABI tests (plan: string-bytes-testing-gap.md, Phase K).
//
// Exercises the compiler-facing kernel ABI in elm-kernel-cpp/.../BytesExports.cpp
// and StringExports.cpp directly, without going through the compiler: the encoder
// serializer, the decoder read_* functions, the closure-driven string ops, and
// the ElmBytesRuntime accessors. See ElmBytesRuntime.h / KernelExports.h.

#include "KernelExportsTest.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/BytesOps.hpp"
#include "../../runtime/src/allocator/StringOps.hpp"
#include "../../runtime/src/allocator/CaseMap.hpp"
#include "../../elm-kernel-cpp/src/core/Utils.hpp"
#include "../../runtime/src/allocator/ElmBytesRuntime.h"
#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../../elm-kernel-cpp/src/ExportHelpers.hpp"
#include "../allocator/TestHelpers.hpp"
#include "../TestSuite.hpp"
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <iostream>

using namespace Elm;
namespace Ex = Elm::Kernel::Export;

namespace {

// ---- helpers --------------------------------------------------------------

static HPtr bbFromVec(const std::vector<u8>& v) {
    return HPtr::fromHPointer(BytesOps::fromVector(v));
}
static HPtr strFromU16(const std::u16string& s) {
    return HPtr::fromHPointer(
        alloc::allocString(reinterpret_cast<const u16*>(s.data()), s.size()));
}
static int64_t decodeBoxedInt(HPtr h) {
    void* p = Allocator::instance().resolve(h.toHPointer());
    return static_cast<ElmInt*>(p)->value;
}
// A raw read_* result is a bare Tuple2 on success, or the Nothing constant on
// overrun. Nothing is an embedded constant (HPointer.constant != 0).
static bool isNothing(HPtr r) { return r.toHPointer().constant != 0; }
static Tuple2* asTuple(HPtr r) {
    return static_cast<Tuple2*>(Allocator::instance().resolve(r.toHPointer()));
}

// foldl evaluator: (Char, accInt) -> accInt + 1  (counts closure invocations).
// args[0] = boxed Char, args[1] = boxed acc Int. Returns a boxed Int.
static void* countFoldEvaluator(void* args[]) {
    HPtr accH = HPtr::fromBits(reinterpret_cast<uint64_t>(args[1]));
    ElmInt* acc = static_cast<ElmInt*>(Allocator::instance().resolve(accH.toHPointer()));
    return reinterpret_cast<void*>(eco_alloc_int(acc->value + 1).toBits());
}

// ---- K1..K5 : encoder serialization --------------------------------------

// K1: elm_encoder_size agrees with elm_encoder_write_into for leaf encoders.
static void test_encoder_size_matches_write() {
    initAllocator();
    // LE endianness is nullary ctor 0 — an embedded null-cons constant
    // (HEAP_044), never a heap object.
    HPtr le = HPtr::fromBits(nullConsWordFor(0));
    struct Case { HPtr enc; u32 size; };
    Case cases[] = {
        {Elm_Kernel_Bytes_write_u8(65), 1},
        {Elm_Kernel_Bytes_write_u16(le, 0x1234), 2},
        {Elm_Kernel_Bytes_write_bytes(bbFromVec({1, 2, 3, 4, 5})), 5},
        {Elm_Kernel_Bytes_write_string(strFromU16(u"hi")), 2},
    };
    for (auto& c : cases) {
        u32 sz = elm_encoder_size(c.enc);
        TEST_ASSERT(sz == c.size);
        std::vector<u8> buf(sz + 8, 0);
        TEST_ASSERT(elm_encoder_write_into(c.enc, buf.data()) == sz);
    }
}

// K2: encoder honours endianness (BE vs LE) in the emitted bytes.
static void test_encoder_endianness_bytes() {
    initAllocator();
    // Endianness is a nullary-ctor union: LE = ctor 0, BE = ctor 1 — embedded
    // null-cons constants (HEAP_044), never heap objects.
    HPtr be = HPtr::fromBits(nullConsWordFor(1));  // BE
    HPtr le = HPtr::fromBits(nullConsWordFor(0));  // LE
    HPtr encBE = Elm_Kernel_Bytes_encode(Elm_Kernel_Bytes_write_u16(be, 0x1234));
    TEST_ASSERT(elm_bytebuffer_len(encBE) == 2);
    u8* p = elm_bytebuffer_data(encBE);
    TEST_ASSERT(p[0] == 0x12 && p[1] == 0x34);
    HPtr encLE = Elm_Kernel_Bytes_encode(Elm_Kernel_Bytes_write_u16(le, 0x1234));
    p = elm_bytebuffer_data(encLE);
    TEST_ASSERT(p[0] == 0x34 && p[1] == 0x12);
    HPtr enc32 = Elm_Kernel_Bytes_encode(Elm_Kernel_Bytes_write_u32(be, 0x01020304));
    TEST_ASSERT(elm_bytebuffer_len(enc32) == 4);
    p = elm_bytebuffer_data(enc32);
    TEST_ASSERT(p[0] == 0x01 && p[1] == 0x02 && p[2] == 0x03 && p[3] == 0x04);
}

// K3: encoder emits a 4-byte UTF-8 sequence for an astral (surrogate-pair) char.
static void test_encoder_utf8_astral() {
    initAllocator();
    std::u16string s;
    s.push_back(u'a');
    s.push_back(0xD83D);  // high surrogate of U+1F600
    s.push_back(0xDE00);  // low surrogate
    s.push_back(u'b');
    HPtr enc = Elm_Kernel_Bytes_encode(Elm_Kernel_Bytes_write_string(strFromU16(s)));
    TEST_ASSERT(elm_bytebuffer_len(enc) == 6);
    u8* p = elm_bytebuffer_data(enc);
    const u8 want[6] = {0x61, 0xF0, 0x9F, 0x98, 0x80, 0x62};
    for (int i = 0; i < 6; ++i) TEST_ASSERT(p[i] == want[i]);
}

// K4: ENC_BYTES embeds a slice-form buffer correctly (via byteBufferView).
static void test_encoder_embeds_slice() {
    auto& alloc = initAllocator();
    std::vector<u8> data(64);
    for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<u8>(i);
    HPointer bufHP = BytesOps::fromVector(data);
    HPointer sliceHP = BytesOps::slice(alloc.resolve(bufHP), 10, 50);  // 40-byte slice
    HPtr enc = Elm_Kernel_Bytes_encode(
        Elm_Kernel_Bytes_write_bytes(HPtr::fromHPointer(sliceHP)));
    TEST_ASSERT(elm_bytebuffer_len(enc) == 40);
    u8* p = elm_bytebuffer_data(enc);
    for (int i = 0; i < 40; ++i) TEST_ASSERT(p[i] == 10 + i);
}

// K5: encoding a payload >= 8 KiB routes to a Tag_LargeByteHeader.
static void test_encode_large_routes_large_header() {
    auto& alloc = initAllocator();
    HPtr big = bbFromVec(std::vector<u8>(10000, 0x5A));
    HPtr enc = Elm_Kernel_Bytes_encode(Elm_Kernel_Bytes_write_bytes(big));
    TEST_ASSERT(elm_bytebuffer_len(enc) == 10000);
    TEST_ASSERT(alloc::getTag(alloc.resolve(enc.toHPointer())) == Tag_LargeByteHeader);
}

// ---- K6..K8 : decoders ----------------------------------------------------

// A failing read does not return: it throws Elm::BytesDecodeFailure, which
// only Elm_Kernel_Bytes_decode catches (plans/bytes-decode-failure-unwind.md).
// Direct calls in these tests stand in for that catch.
template <typename F>
static bool readThrowsDecodeFailure(F&& read) {
    try {
        (void)read();
    } catch (const Elm::BytesDecodeFailure&) {
        return true;
    }
    return false;
}

// K6: read_* primitives return (newOffset, value); overrun fails (throws).
static void test_decoder_read_primitives() {
    initAllocator();
    HPtr trueLE = HPtr::fromBits(Ex::encodeBoxedBool(true));
    HPtr bb = bbFromVec({0x34, 0x12, 0xFF, 0x00, 0x11});
    HPtr r16 = Elm_Kernel_Bytes_read_u16(trueLE, bb, 0);
    TEST_ASSERT(!isNothing(r16));
    Tuple2* t16 = asTuple(r16);
    TEST_ASSERT(t16->a.i == 2 && t16->b.i == 0x1234);
    HPtr r8 = Elm_Kernel_Bytes_read_u8(bb, 2);
    TEST_ASSERT(!isNothing(r8));
    Tuple2* t8 = asTuple(r8);
    TEST_ASSERT(t8->a.i == 3 && t8->b.i == 0xFF);
    // 2 bytes requested at offset 4, only 1 available -> decode failure.
    TEST_ASSERT(readThrowsDecodeFailure([&] { return Elm_Kernel_Bytes_read_u16(trueLE, bb, 4); }));
    TEST_ASSERT(readThrowsDecodeFailure([&] { return Elm_Kernel_Bytes_read_u8(bb, 5); }));
    TEST_ASSERT(readThrowsDecodeFailure([&] { return Elm_Kernel_Bytes_decodeFailure(); }));
}

// K7: read_bytes yields a Tag_ByteBufferSlice with correct content.
static void test_decoder_read_bytes_slice() {
    auto& alloc = initAllocator();
    std::vector<u8> data(50);
    for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<u8>(i);
    HPtr bb = bbFromVec(data);
    HPtr r = Elm_Kernel_Bytes_read_bytes(40, bb, 0);
    TEST_ASSERT(!isNothing(r));
    Tuple2* t = asTuple(r);
    TEST_ASSERT(t->a.i == 40);
    void* sliceObj = alloc.resolve(t->b.p);
    TEST_ASSERT(alloc::getTag(sliceObj) == Tag_ByteBufferSlice);
    TEST_ASSERT(BytesOps::getAt(sliceObj, 0) == 0 && BytesOps::getAt(sliceObj, 39) == 39);
}

// K8: read_string decodes multi-byte UTF-8, emitting surrogate pairs (astral ->
// 2 code units), so "a😀b" (6 UTF-8 bytes) is length 4.
static void test_decoder_read_string_utf8() {
    auto& alloc = initAllocator();
    HPtr bb = bbFromVec({0x61, 0xF0, 0x9F, 0x98, 0x80, 0x62});
    HPtr r = Elm_Kernel_Bytes_read_string(6, bb, 0);
    TEST_ASSERT(!isNothing(r));
    Tuple2* t = asTuple(r);
    TEST_ASSERT(t->a.i == 6);
    void* strObj = alloc.resolve(t->b.p);
    TEST_ASSERT(StringOps::length(strObj) == 4);
}

// ---- K9..K12 : string ABI + runtime accessors -----------------------------

// K9: Elm_Kernel_String_length is correct for empty/flat/slice/rope.
static void test_string_length_all_forms() {
    auto& alloc = initAllocator();
    TEST_ASSERT(Elm_Kernel_String_length(HPtr::fromHPointer(alloc::emptyString())) == 0);
    TEST_ASSERT(Elm_Kernel_String_length(strFromU16(u"hello")) == 5);
    HPointer base = alloc::allocString(std::u16string(500, u'a'));
    HPointer sliceHP = StringOps::slice(alloc.resolve(base), 100, 300);  // 200 chars
    TEST_ASSERT(alloc::getTag(alloc.resolve(sliceHP)) == Tag_StringSlice);
    TEST_ASSERT(Elm_Kernel_String_length(HPtr::fromHPointer(sliceHP)) == 200);
    HPointer l = alloc::allocString(std::u16string(u"foo"));
    HPointer rgt = alloc::allocString(std::u16string(u"bar"));
    alloc.getRootSet().addRoot(&l);
    alloc.getRootSet().addRoot(&rgt);
    HPointer rope = StringOps::makeRope(l, rgt);
    TEST_ASSERT(Elm_Kernel_String_length(HPtr::fromHPointer(rope)) == 6);
    alloc.getRootSet().removeRoot(&rgt);
    alloc.getRootSet().removeRoot(&l);
}

// K10: foldl/foldr invoke the closure once per code point (Char is an i32 code
// point, per REP_ABI_001/CGEN_015). Over "a😀b" the astral char is one Char, so
// the closure is invoked 3 times, as in elm/core's JS.
static void test_string_foldl_astral_count() {
    initAllocator();
    HPtr closure = eco_alloc_closure_fn(reinterpret_cast<void*>(&countFoldEvaluator), 2, /*result_kind=*/0);
    HPtr acc0 = eco_alloc_int(0);
    std::u16string s;
    s.push_back(u'a');
    s.push_back(0xD83D);
    s.push_back(0xDE00);
    s.push_back(u'b');
    HPtr result = Elm_Kernel_String_foldl(closure, acc0, strFromU16(s));
    TEST_ASSERT(decodeBoxedInt(result) == 3);
    HPtr resultR = Elm_Kernel_String_foldr(closure, eco_alloc_int(0), strFromU16(s));
    TEST_ASSERT(decodeBoxedInt(resultR) == 3);
    // A lone surrogate is a Char of its own: [0xD83D, 0x61] folds twice.
    std::u16string lone;
    lone.push_back(0xD83D);
    lone.push_back(u'a');
    TEST_ASSERT(decodeBoxedInt(Elm_Kernel_String_foldl(closure, eco_alloc_int(0), strFromU16(lone))) == 2);
    TEST_ASSERT(decodeBoxedInt(Elm_Kernel_String_foldr(closure, eco_alloc_int(0), strFromU16(lone))) == 2);
}

static std::u16string unitsOf(HPtr str) {
    void* p = Allocator::instance().resolve(str.toHPointer());
    if (!p) return {};
    return StringOps::toStdU16String(p);
}

// K16: Char is a 32-bit code point at the kernel boundary (plan Part 1).
static void test_char_code_point_kernels() {
    initAllocator();
    // Char.fromCode: out of 0..0x10FFFF -> U+FFFD; surrogates pass through.
    TEST_ASSERT(Elm_Kernel_Char_fromCode(-1) == 0xFFFDu);
    TEST_ASSERT(Elm_Kernel_Char_fromCode(0x110000) == 0xFFFDu);
    TEST_ASSERT(Elm_Kernel_Char_fromCode(0x1F600) == 0x1F600u);
    TEST_ASSERT(Elm_Kernel_Char_fromCode(0x10FFFF) == 0x10FFFFu);
    TEST_ASSERT(Elm_Kernel_Char_fromCode(0xD800) == 0xD800u);
    // Char.toCode reads the full code point and masks garbage above bit 31.
    TEST_ASSERT(Elm_Kernel_Char_toCode((0xABCDull << 32) | 0x1F600u) == 0x1F600);
    // Chars compare by code point.
    TEST_ASSERT(Ex::decodeBoxedBool(Elm_Kernel_Utils_lt_Char(0xFFFFu, 0x10000u).toBits()));
    TEST_ASSERT(Ex::decodeBoxedBool(Elm_Kernel_Utils_equal_Char((1ull << 40) | 0x1F600u, 0x1F600u).toBits()));

    std::u16string emojiB;
    emojiB.push_back(0xD83D);
    emojiB.push_back(0xDE00);
    emojiB.push_back(u'b');

    // String.cons encodes an astral Char as its surrogate pair.
    HPtr consd = Elm_Kernel_String_cons(0x1F600u, strFromU16(u"b"));
    TEST_ASSERT(unitsOf(consd) == emojiB);

    // String.uncons yields the whole code point; rest drops both units.
    HPtr unc = Elm_Kernel_String_uncons(strFromU16(emojiB));
    Custom* just = static_cast<Custom*>(Allocator::instance().resolve(unc.toHPointer()));
    TEST_ASSERT(just != nullptr);
    Tuple2* t = static_cast<Tuple2*>(Allocator::instance().resolve(just->values[0].p));
    TEST_ASSERT(t->a.c == 0x1F600u);
    TEST_ASSERT(static_cast<u64>(t->a.i) == 0x1F600u);  // high bits clean (unboxedChar)
    TEST_ASSERT(StringOps::length(Allocator::instance().resolve(t->b.p)) == 1);

    // String.reverse keeps surrogate pairs in order: "a😀b" -> "b😀a".
    std::u16string aEmojiB;
    aEmojiB.push_back(u'a');
    aEmojiB += emojiB;
    std::u16string bEmojiA;
    bEmojiA.push_back(u'b');
    bEmojiA.push_back(0xD83D);
    bEmojiA.push_back(0xDE00);
    bEmojiA.push_back(u'a');
    TEST_ASSERT(unitsOf(Elm_Kernel_String_reverse(strFromU16(aEmojiB))) == bEmojiA);

    // List.cons_Char stores the code point zero-extended in the head slot.
    HPtr cell = Elm_Kernel_List_cons_Char((0xABCDull << 32) | 0x1F600u,
                                          HPtr::fromHPointer(alloc::listNil()));
    Cons* c = static_cast<Cons*>(Allocator::instance().resolve(cell.toHPointer()));
    TEST_ASSERT(static_cast<u64>(c->head.i) == 0x1F600u);

    // String.fromList re-encodes: fromList [ 'a', '😀', 'b' ] == "a😀b".
    HPointer l = alloc::listNil();
    Allocator::instance().getRootSet().addRoot(&l);
    l = alloc::cons(alloc::unboxedChar(u'b'), l, static_cast<u8>(3));
    l = alloc::cons(alloc::unboxedChar(0x1F600u), l, static_cast<u8>(3));
    l = alloc::cons(alloc::unboxedChar(u'a'), l, static_cast<u8>(3));
    TEST_ASSERT(unitsOf(Elm_Kernel_String_fromList(HPtr::fromHPointer(l))) == aEmojiB);
    Allocator::instance().getRootSet().removeRoot(&l);
}

// K17: encoded case-mapping Char values (KERN_008, plans/char-case-mapping-elm-exact.md Step 2)
// at the kernel boundary: ordering, and the String writers that expand them. Synthetic values
// (0x53 | (rank+1) << 21) and table values (CaseMap::upper) are fed directly. Skipped in a build
// with ECO_CHAR_CASE_EXPANSION off, where no value is encoded.
static void test_char_encoded_kernels() {
    if constexpr (Elm::CharValue::kExpansions) {
        initAllocator();
        const uint32_t R = 0x52, S = 0x53, T = 0x54, e0 = 0x53u | (1u << 21), e1 = 0x53u | (2u << 21);
        auto lt = [](uint32_t a, uint32_t b) { return Ex::decodeBoxedBool(Elm_Kernel_Utils_lt_Char(a, b).toBits()); };
        auto ge = [](uint32_t a, uint32_t b) { return Ex::decodeBoxedBool(Elm_Kernel_Utils_ge_Char(a, b).toBits()); };
        auto ord = [](uint64_t enc) { return enc == Kernel::Utils::getOrderLT() ? -1 : enc == Kernel::Utils::getOrderGT() ? 1 : 0; };
        const uint32_t order[] = {R, S, e0, e1, T, 0xE000u, 0x1F600u};
        for (size_t i = 0; i + 1 < sizeof order / sizeof order[0]; i++) {
            TEST_ASSERT(lt(order[i], order[i + 1]) && !lt(order[i + 1], order[i]));
            TEST_ASSERT(ge(order[i + 1], order[i]) && !ge(order[i], order[i + 1]));
            TEST_ASSERT(ord(Elm_Kernel_Utils_compare_Char(order[i], order[i + 1]).toBits()) == -1);
            TEST_ASSERT(ord(Elm_Kernel_Utils_compare_Char(order[i + 1], order[i]).toBits()) == 1);
        }
        TEST_ASSERT(ord(Elm_Kernel_Utils_compare_Char((1ull << 40) | e0, e0).toBits()) == 0);
        // Utils::compare on boxed Chars (cmp's Tag_Char arm).
        {
            HPointer a = eco_alloc_char(e0).toHPointer();
            Allocator::instance().getRootSet().addRoot(&a);
            HPointer b = eco_alloc_char(T).toHPointer();
            Allocator::instance().getRootSet().addRoot(&b);
            auto& A = Allocator::instance();
            TEST_ASSERT(ord(Elm_Kernel_Utils_compare(HPtr::fromHPointer(a), HPtr::fromHPointer(b)).toBits()) == -1);
            HPointer c = eco_alloc_char(S).toHPointer();
            TEST_ASSERT(ord(Elm_Kernel_Utils_compare(HPtr::fromHPointer(a), HPtr::fromHPointer(c)).toBits()) == 1);
            (void)A;
            A.getRootSet().removeRoot(&b);
            A.getRootSet().removeRoot(&a);
        }
        // ... and on two lists of unboxed Chars (compareUnboxableSlot kind 3): [S, e0] < [S, T].
        {
            HPointer l1 = alloc::listNil(), l2 = alloc::listNil();
            auto& rs = Allocator::instance().getRootSet();
            rs.addRoot(&l1);
            rs.addRoot(&l2);
            l1 = alloc::cons(alloc::unboxedChar(e0), l1, static_cast<u8>(3));
            l1 = alloc::cons(alloc::unboxedChar(S), l1, static_cast<u8>(3));
            l2 = alloc::cons(alloc::unboxedChar(T), l2, static_cast<u8>(3));
            l2 = alloc::cons(alloc::unboxedChar(S), l2, static_cast<u8>(3));
            TEST_ASSERT(ord(Elm_Kernel_Utils_compare(HPtr::fromHPointer(l1), HPtr::fromHPointer(l2)).toBits()) == -1);
            TEST_ASSERT(ord(Elm_Kernel_Utils_compare(HPtr::fromHPointer(l2), HPtr::fromHPointer(l1)).toBits()) == 1);
            rs.removeRoot(&l2);
            rs.removeRoot(&l1);
        }
        // String writers expand: cons, fromChar, fromList (pre-count + write).
        const uint32_t ss = CaseMap::upper(0xDF), iota = CaseMap::upper(0x390);
        TEST_ASSERT(unitsOf(Elm_Kernel_String_cons(ss, strFromU16(u"x"))) == u"SSx");
        TEST_ASSERT(unitsOf(HPtr::fromHPointer(StringOps::fromChar(ss))) == u"SS");
        {
            HPointer l = alloc::listNil();
            Allocator::instance().getRootSet().addRoot(&l);
            l = alloc::cons(alloc::unboxedChar(iota), l, static_cast<u8>(3));
            l = alloc::cons(alloc::unboxedChar(u'x'), l, static_cast<u8>(3));
            l = alloc::cons(alloc::unboxedChar(ss), l, static_cast<u8>(3));
            std::u16string want = u"SSxΪ́";
            HPtr got = Elm_Kernel_String_fromList(HPtr::fromHPointer(l));
            TEST_ASSERT(unitsOf(got) == want);
            TEST_ASSERT(StringOps::length(Allocator::instance().resolve(got.toHPointer())) == 6);
            Allocator::instance().getRootSet().removeRoot(&l);
        }
        // Debug.toString prints the expansion: 'SS' (the Debug printer's capture path).
        TEST_ASSERT(unitsOf(Elm_Kernel_Debug_toString(eco_alloc_char(ss))) == u"'SS'");
        // A value in the never-produced 0x110000..0x1FFFFF range writes U+FFFD.
        u16 buf[CharValue::kMaxCharUnits];
        TEST_ASSERT(StringOps::encodeCodePoint(0x150000u, buf) == 1 && buf[0] == 0xFFFDu);
    }
}

// K18: Char and String case mapping (plans/char-case-mapping-elm-exact.md Step 3): full Unicode,
// expansions as encoded Char values (KERN_008), Final_Sigma in String.toLower. Skipped in a build
// with ECO_CHAR_CASE_EXPANSION off.
static void test_case_mapping_kernels() {
    if constexpr (Elm::CharValue::kExpansions) {
        initAllocator();
        const uint32_t ss = Elm_Kernel_Char_toUpper(0xDF);
        TEST_ASSERT(Elm::CharValue::isEncoded(ss));
        TEST_ASSERT(Elm_Kernel_Char_toCode(ss) == 83);
        TEST_ASSERT(unitsOf(HPtr::fromHPointer(StringOps::fromChar(Elm_Kernel_Char_toLower(ss)))) == u"ss");
        TEST_ASSERT(Elm_Kernel_Char_toLocaleUpper(0xDF) == ss);
        TEST_ASSERT(Elm_Kernel_Char_toUpper(0xE9) == 0xC9 && Elm_Kernel_Char_toLower(0x416) == 0x436);
        TEST_ASSERT(Elm_Kernel_Char_toUpper((0xABCDull << 32) | 'a') == 'A');

        // String.toUpper "straße" == "STRASSE", as an all-ASCII (UTF-8) string when enabled.
        HPtr up = Elm_Kernel_String_toUpper(strFromU16(u"straße"));
        TEST_ASSERT(unitsOf(up) == u"STRASSE");
        if (Allocator::instance().getConfig().utf8_strings_enabled) {
            TEST_ASSERT(StringOps::isUtf8(Allocator::instance().resolve(up.toHPointer())));
        }
        // Final_Sigma: word-final capital sigma lowers to U+03C2.
        TEST_ASSERT(unitsOf(Elm_Kernel_String_toLower(strFromU16(u"ΟΔΟΣ ΟΔΟΣ")))
                    == u"οδος οδος");
        TEST_ASSERT(unitsOf(Elm_Kernel_String_toLower(strFromU16(u"Σ"))) == u"σ");
        // A slice input whose last unit is the sigma: the rule sees the slice, not its base.
        std::u16string longText(300, u'Α');
        longText[150] = u'Σ';
        HPtr slice = Elm_Kernel_String_slice(0, 151, strFromU16(longText));
        std::u16string lowered = unitsOf(Elm_Kernel_String_toLower(slice));
        TEST_ASSERT(lowered.size() == 151 && lowered[150] == u'ς' && lowered[0] == u'α');
        // Expansion inside a longer string, and an astral letter.
        TEST_ASSERT(unitsOf(Elm_Kernel_String_toUpper(strFromU16(u"ﬁx\U00010428"))) == u"FIX\U00010400");
    }
}

// K12: elm_bytebuffer_len / _data / _with_data are correct for flat + large
// forms (slice is exercised by the crasher K11).
static void test_elm_bytebuffer_runtime_flat_large() {
    initAllocator();
    HPtr flat = bbFromVec({10, 20, 30});
    TEST_ASSERT(elm_bytebuffer_len(flat) == 3);
    u8* d = elm_bytebuffer_data(flat);
    TEST_ASSERT(d[0] == 10 && d[2] == 30);
    HPtr large = bbFromVec(std::vector<u8>(10000, 0x7E));
    TEST_ASSERT(elm_bytebuffer_len(large) == 10000);
    TEST_ASSERT(elm_bytebuffer_data(large)[0] == 0x7E);
    struct Ctx { u32 len; u8 first; };
    Ctx c{0, 0};
    elm_bytebuffer_with_data(flat, [](const u8* p, u32 n, void* v) {
        Ctx* cc = static_cast<Ctx*>(v);
        cc->len = n;
        cc->first = n ? p[0] : 0;
    }, &c);
    TEST_ASSERT(c.len == 3 && c.first == 10);
}

// ---- crashers: K11, K13 (F3) ---------------------------------------------

static HPtr makeByteSlice() {
    auto& alloc = initAllocator();
    std::vector<u8> data(64);
    for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<u8>(i);
    HPointer bufHP = BytesOps::fromVector(data);
    HPointer sliceHP = BytesOps::slice(alloc.resolve(bufHP), 10, 50);  // 40-byte slice
    return HPtr::fromHPointer(sliceHP);
}

// K11 (fail-now, F3): elm_bytebuffer_len on a slice -> resolveByteBufferBody
// assert -> abort (assert builds).
static void test_elm_bytebuffer_len_on_slice() {
    HPtr slice = makeByteSlice();
    TEST_ASSERT(elm_bytebuffer_len(slice) == 40);
}

// K13 (fail-now, F3): Elm_Kernel_Bytes_width on a slice (same root).
static void test_bytes_width_on_slice() {
    HPtr slice = makeByteSlice();
    int64_t w = static_cast<int64_t>(Elm_Kernel_Bytes_width(slice).toBits());
    TEST_ASSERT(w == 40);
}

// ---- W0.2: Bytes.Decode.string behavior goldens ---------------------------
//
// Pins the observable behavior of Elm_Kernel_Bytes_read_string on ASCII,
// non-ASCII and INVALID UTF-8. Target semantics (shared with the fused decoder's
// elm_utf8_decode, which K8c checks directly): `string n` succeeds only when the
// n bytes are complete, valid UTF-8, and NO byte outside [offset, offset+n) is
// ever read. Every invalid / truncated row is therefore Nothing.
//
// Each row runs in three source shapes:
//   padded   - prefix + 4 trailing zero bytes (the original W0 harness)
//   unpadded - the buffer ends exactly at the prefix, so an over-read leaves
//              the buffer (reads whatever the heap holds next)
//   slice    - a real Tag_ByteBufferSlice (>= 32 bytes) whose PARENT continues
//              with valid continuation bytes 0x80 0x80 0x80, so an over-read
//              past the slice would silently "complete" a truncated sequence
struct DecodeGolden {
    const char* name;
    std::vector<u8> prefix;   // the bytes to decode (length = prefix.size())
    bool nothing;             // expected: decode returned Nothing
    std::vector<u16> units;   // expected: decoded UTF-16 code units (if !nothing)
};

enum class GoldenShape { Padded, Unpadded, Slice };

static const char* goldenShapeName(GoldenShape s) {
    switch (s) {
        case GoldenShape::Padded: return "padded";
        case GoldenShape::Unpadded: return "unpadded";
        case GoldenShape::Slice: return "slice";
    }
    return "?";
}

// Filler placed in front of the prefix in the Slice shape, so the slice is
// long enough (>= MAKE_BYTEBUFFER_SLICE_MIN_LEN) to stay a real slice view.
static constexpr size_t kSliceFiller = 32;

// Decode `prefix` in the given source shape; return the resulting code units
// (Slice shape: the filler's 'A's are stripped), or false for Nothing.
static bool decodeGoldenUnits(const std::vector<u8>& prefix, GoldenShape shape,
                              std::vector<u16>& outUnits) {
    HPtr src;
    int64_t len = static_cast<int64_t>(prefix.size());
    size_t skip = 0;
    if (shape == GoldenShape::Padded) {
        std::vector<u8> padded = prefix;
        padded.insert(padded.end(), {0, 0, 0, 0});
        src = bbFromVec(padded);
    } else if (shape == GoldenShape::Unpadded) {
        src = bbFromVec(prefix);
    } else {
        std::vector<u8> parent(kSliceFiller, 'A');
        parent.insert(parent.end(), prefix.begin(), prefix.end());
        parent.insert(parent.end(), {0x80, 0x80, 0x80});
        HPointer parentHp = BytesOps::fromVector(parent);
        HPointer sliceHp = alloc::makeByteBufferSlice(
            parentHp, 0, static_cast<u32>(kSliceFiller + prefix.size()));
        TEST_ASSERT(alloc::getTag(Allocator::instance().resolve(sliceHp)) ==
                    Tag_ByteBufferSlice);
        src = HPtr::fromHPointer(sliceHp);
        len += static_cast<int64_t>(kSliceFiller);
        skip = kSliceFiller;
    }
    HPtr r;
    try {
        r = Elm_Kernel_Bytes_read_string(len, src, 0);
    } catch (const Elm::BytesDecodeFailure&) {
        return false;  // decode failure (Nothing at the Bytes.Decode.decode level)
    }
    TEST_ASSERT(!isNothing(r));  // failures throw; a returned Nothing is the old protocol
    Tuple2* t = asTuple(r);
    TEST_ASSERT(t->a.i == len);  // advances exactly n
    void* strObj = Allocator::instance().resolve(t->b.p);
    size_t n = StringOps::length(strObj);
    outUnits.clear();
    for (size_t i = skip; i < n; ++i) outUnits.push_back(StringOps::charAt(strObj, i));
    return true;
}

static std::vector<DecodeGolden> decodeGoldenBattery() {
    return {
        // --- valid ASCII (W1 DIVERTS these to UTF-8 forms; value must hold) ---
        {"ascii_1",   {'x'}, false, {'x'}},
        {"ascii_5",   {'h','e','l','l','o'}, false, {'h','e','l','l','o'}},
        {"ascii_31",  std::vector<u8>(31, 'a'), false, std::vector<u16>(31, u'a')},
        {"ascii_32",  std::vector<u8>(32, 'b'), false, std::vector<u16>(32, u'b')},
        {"ascii_33",  std::vector<u8>(33, 'c'), false, std::vector<u16>(33, u'c')},
        // --- valid non-ASCII ---
        {"u0080",     {0xC2, 0x80}, false, {0x0080}},
        {"u07FF",     {0xDF, 0xBF}, false, {0x07FF}},
        {"u0800",     {0xE0, 0xA0, 0x80}, false, {0x0800}},
        {"uFFFF",     {0xEF, 0xBF, 0xBF}, false, {0xFFFF}},
        {"u10000",    {0xF0, 0x90, 0x80, 0x80}, false, {0xD800, 0xDC00}},
        {"u10FFFF",   {0xF4, 0x8F, 0xBF, 0xBF}, false, {0xDBFF, 0xDFFF}},
        {"mixed_astral", {'A', 0xF0, 0x9F, 0x98, 0x80, 'B'}, false,
                         {u'A', 0xD83D, 0xDE00, u'B'}},
        // --- invalid: all Nothing (strict, same as elm_utf8_decode) ---
        {"bare_cont",     {0x80}, true, {}},
        {"bare_cont_bf",  {0xBF}, true, {}},
        {"lead_f8",       {0xF8}, true, {}},
        {"lead_ff",       {0xFF}, true, {}},
        {"cont_then_abc", {0x80, 'A', 'B', 'C'}, true, {}},
        {"trunc_2",       {0xC2}, true, {}},
        {"trunc_3",       {0xE2, 0x82}, true, {}},
        {"trunc_3_lead",  {0xE2}, true, {}},
        {"trunc_4",       {0xF0, 0x9F, 0x98}, true, {}},
        {"trunc_4_lead",  {0xF0}, true, {}},
        {"trunc_4_two",   {0xF0, 0x9F}, true, {}},
        {"ascii_trunc_2", {'A', 0xC3}, true, {}},
        {"ascii_trunc_4", {'A', 0xF0, 0x9F, 0x98}, true, {}},
        {"overlong_2",    {0xC0, 0x80}, true, {}},
        {"overlong_3",    {0xE0, 0x80, 0x80}, true, {}},
        {"overlong_4",    {0xF0, 0x80, 0x80, 0x80}, true, {}},
        {"surrogate",     {0xED, 0xA0, 0x80}, true, {}},
        {"gt_10FFFF",     {0xF4, 0x90, 0x80, 0x80}, true, {}},
        {"bad_cont",      {0xC2, 0x00}, true, {}},
        {"bad_cont_mid",  {0xC3, 'A'}, true, {}},
    };
}

static void test_decoder_read_string_goldens() {
    initAllocator();
    std::vector<DecodeGolden> battery = decodeGoldenBattery();

    bool CAPTURE = std::getenv("W0_CAPTURE_GOLDENS") != nullptr;
    std::string failures;
    for (GoldenShape shape : {GoldenShape::Padded, GoldenShape::Unpadded, GoldenShape::Slice}) {
        for (auto& g : battery) {
            std::vector<u16> units;
            bool ok = decodeGoldenUnits(g.prefix, shape, units);
            if (CAPTURE) {
                std::cout << "WGOLDEN|" << goldenShapeName(shape) << "|" << g.name << "|"
                          << (ok ? "SOME" : "NOTHING") << "|len=" << units.size()
                          << "|";
                for (u16 u : units) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "%04X ", u);
                    std::cout << buf;
                }
                std::cout << std::endl;
                continue;
            }
            // Collect every divergence (shape + golden + what) and fail once, so
            // a run reports the whole battery rather than the first bad row.
            auto fail = [&](const char* what, size_t i, unsigned got, unsigned want) {
                char buf[200];
                std::snprintf(buf, sizeof buf, "\n  [%s] golden %s: %s at %zu: got %04X, want %04X",
                              goldenShapeName(shape), g.name, what, i, got, want);
                failures += buf;
            };
            if (ok != !g.nothing) {
                fail("Just/Nothing", 0, ok, !g.nothing);
                continue;
            }
            if (ok) {
                if (units.size() != g.units.size()) {
                    fail("length", 0, static_cast<unsigned>(units.size()),
                         static_cast<unsigned>(g.units.size()));
                    continue;
                }
                for (size_t i = 0; i < units.size(); ++i) {
                    if (units[i] != g.units[i]) fail("code unit", i, units[i], g.units[i]);
                }
            }
        }
    }
    if (!failures.empty()) TEST_FAIL(("read_string goldens diverged:" + failures).c_str());
}

// ---- K8d: kernel read_string agrees with the fused decoder ------------------
//
// The fused Bytes.Decode path calls elm_utf8_decode(buffer, offset, len) after
// its own bounds check; the non-fused fallback calls Elm_Kernel_Bytes_read_string.
// Whatever the compiler decides to fuse, a program must see the same result:
// same Just/Nothing, same code units, for every row of the battery.
static void test_decoder_read_string_agrees_with_fused() {
    initAllocator();
    std::string failures;
    for (auto& g : decodeGoldenBattery()) {
        // The bytes at offset 1 of a buffer whose first byte is junk.
        HPtr buf = elm_alloc_bytebuffer(static_cast<u32>(g.prefix.size() + 1));
        u8* data = elm_bytebuffer_data(buf);
        data[0] = 0xFF;
        if (!g.prefix.empty()) std::memcpy(data + 1, g.prefix.data(), g.prefix.size());
        HPtr fused = elm_utf8_decode(buf, 1, static_cast<u32>(g.prefix.size()));
        bool fusedOk = fused.toBits() != 0;
        std::vector<u16> fusedUnits;
        if (fusedOk) {
            void* s = Allocator::instance().resolve(fused.toHPointer());
            size_t n = StringOps::length(s);
            for (size_t i = 0; i < n; ++i) fusedUnits.push_back(StringOps::charAt(s, i));
        }
        std::vector<u16> kernelUnits;
        bool kernelOk = decodeGoldenUnits(g.prefix, GoldenShape::Unpadded, kernelUnits);
        if (fusedOk != kernelOk) {
            failures += std::string("\n  ") + g.name + ": fused " +
                        (fusedOk ? "Just" : "Nothing") + ", kernel " +
                        (kernelOk ? "Just" : "Nothing");
        } else if (fusedOk && fusedUnits != kernelUnits) {
            failures += std::string("\n  ") + g.name + ": code units differ";
        }
    }
    if (!failures.empty())
        TEST_FAIL(("kernel read_string disagrees with fused elm_utf8_decode:" + failures).c_str());
}

// ---- W1: Bytes.Decode.string representation matrix ------------------------
//
// Asserts the FORM produced by the wired UTF-8 fast path as a function of
// (ascii-ness, length, source shape). Value-equality is covered by the K8b
// goldens + E2E; here we pin the representation. See W1.
static void expectDecodeTag(const std::vector<u8>& bytesVec, int64_t length,
                            HPtr srcBuf, int64_t offset, Tag expectTag,
                            const std::string& expectContent) {
    HPtr r = Elm_Kernel_Bytes_read_string(length, srcBuf, offset);
    TEST_ASSERT(!isNothing(r));
    Tuple2* t = asTuple(r);
    void* strObj = Allocator::instance().resolve(t->b.p);
    TEST_ASSERT(alloc::getTag(strObj) == expectTag);
    TEST_ASSERT(StringOps::toStdString(strObj) == expectContent);
    (void)bytesVec;
}

static void test_decoder_read_string_representation() {
    auto& alloc = initAllocator();

    // ASCII >= utf8_view_min_len (32) -> zero-copy view.
    {
        std::vector<u8> v(40, 'a');
        HPtr bb = bbFromVec(v);
        expectDecodeTag(v, 40, bb, 0, Tag_StringUtf8View, std::string(40, 'a'));
    }
    // ASCII < 32 -> inline leaf.
    {
        std::vector<u8> v = {'h','e','l','l','o'};
        HPtr bb = bbFromVec(v);
        expectDecodeTag(v, 5, bb, 0, Tag_StringUtf8Leaf, "hello");
    }
    // ASCII exactly at the boundary: 31 -> leaf, 32 -> view.
    {
        std::vector<u8> v31(31, 'x'); HPtr b31 = bbFromVec(v31);
        expectDecodeTag(v31, 31, b31, 0, Tag_StringUtf8Leaf, std::string(31, 'x'));
        std::vector<u8> v32(32, 'y'); HPtr b32 = bbFromVec(v32);
        expectDecodeTag(v32, 32, b32, 0, Tag_StringUtf8View, std::string(32, 'y'));
    }
    // Non-ASCII (2-byte char embedded in an otherwise-long payload) -> legacy
    // UTF-16 Tag_String, regardless of length.
    {
        std::vector<u8> v(40, 'a');
        v[10] = 0xC3; v[11] = 0xA9;  // 'é' U+00E9; makes it non-ASCII
        HPtr bb = bbFromVec(v);
        // length 40 bytes -> 39 UTF-16 units (the 2-byte é collapses to 1).
        HPtr r = Elm_Kernel_Bytes_read_string(40, bb, 0);
        TEST_ASSERT(!isNothing(r));
        void* s = alloc.resolve(asTuple(r)->b.p);
        TEST_ASSERT(alloc::getTag(s) == Tag_String);
        TEST_ASSERT(StringOps::length(s) == 39);
    }
    // Source is a Tag_ByteBufferSlice: decode collapses onto the underlying
    // buffer; content must be correct and the form a UTF-8 view.
    {
        std::vector<u8> v(100, 'a');
        for (size_t i = 0; i < 100; ++i) v[i] = static_cast<u8>('A' + (i % 26));
        HPtr bb = bbFromVec(v);
        HPointer sliceHP = alloc::makeByteBufferSlice(bb.toHPointer(), 10, 60);
        TEST_ASSERT(alloc::getTag(alloc.resolve(sliceHP)) == Tag_ByteBufferSlice);
        std::string expect((const char*)v.data() + 10, 50);
        expectDecodeTag(v, 50, HPtr::fromHPointer(sliceHP), 0,
                        Tag_StringUtf8View, expect);
    }
    // Source is a >= LOT ByteBuffer (Tag_LargeByteHeader): view still correct.
    {
        std::vector<u8> v(9000, 0);
        for (size_t i = 0; i < v.size(); ++i) v[i] = static_cast<u8>('a' + (i % 26));
        HPtr bb = bbFromVec(v);
        TEST_ASSERT(alloc::getTag(alloc.resolve(bb.toHPointer())) == Tag_LargeByteHeader);
        std::string expect((const char*)v.data(), 100);
        expectDecodeTag(v, 100, bb, 0, Tag_StringUtf8View, expect);
    }
    // Kill switch off -> always UTF-16, even for long ASCII.
    {
        HeapConfig cfg;
        cfg.utf8_strings_enabled = false;
        auto& a2 = initAllocator(cfg);
        std::vector<u8> v(40, 'a');
        HPtr bb = bbFromVec(v);
        HPtr r = Elm_Kernel_Bytes_read_string(40, bb, 0);
        void* s = a2.resolve(asTuple(r)->b.p);
        TEST_ASSERT(alloc::getTag(s) == Tag_String);
        TEST_ASSERT(StringOps::toStdString(s) == std::string(40, 'a'));
    }
}

}  // namespace

// ---- K14/K15 : integer division and shift-count semantics -----------------
//
// The kernel C++ path must agree with the inline lowering (EcoToLLVMArith.cpp):
// CGEN_084 (division total, wrapping) and CGEN_085 (shift count mod 64). The
// operands are volatile so the compiler cannot fold the calls; without the
// guards MIN_INT / -1 and x % 0 raise SIGFPE here.

static void test_kernel_int_division_total() {
    volatile int64_t minInt = INT64_MIN, neg1 = -1, zero = 0, seven = 7;
    TEST_ASSERT(Elm_Kernel_Basics_idiv(minInt, neg1) == INT64_MIN);
    TEST_ASSERT(Elm_Kernel_Basics_idiv(seven, neg1) == -7);
    TEST_ASSERT(Elm_Kernel_Basics_idiv(seven, zero) == 0);
    TEST_ASSERT(Elm_Kernel_Basics_idiv(-seven, 2) == -3);
    TEST_ASSERT(Elm_Kernel_Basics_remainderBy(neg1, minInt) == 0);
    TEST_ASSERT(Elm_Kernel_Basics_remainderBy(zero, seven) == 0);
    TEST_ASSERT(Elm_Kernel_Basics_remainderBy(4, -seven) == -3);
    TEST_ASSERT(Elm_Kernel_Basics_modBy(neg1, minInt) == 0);
    TEST_ASSERT(Elm_Kernel_Basics_modBy(4, -seven) == 1);
}

static void test_kernel_shift_count_mod_64() {
    volatile int64_t c64 = 64, c65 = 65, c100 = 100, cm1 = -1, one = 1, neg1 = -1;
    TEST_ASSERT(Elm_Kernel_Bitwise_shiftLeftBy(c64, one) == 1);
    TEST_ASSERT(Elm_Kernel_Bitwise_shiftLeftBy(c65, one) == 2);
    TEST_ASSERT(Elm_Kernel_Bitwise_shiftLeftBy(c100, one) == (int64_t{1} << 36));
    TEST_ASSERT(Elm_Kernel_Bitwise_shiftLeftBy(cm1, one) == INT64_MIN);
    TEST_ASSERT(Elm_Kernel_Bitwise_shiftRightBy(c64, neg1) == -1);
    TEST_ASSERT(Elm_Kernel_Bitwise_shiftRightBy(c65, neg1) == -1);
    TEST_ASSERT(Elm_Kernel_Bitwise_shiftRightZfBy(c64, neg1) == UINT64_MAX);
    TEST_ASSERT(Elm_Kernel_Bitwise_shiftRightZfBy(c65, neg1) == static_cast<uint64_t>(INT64_MAX));
}

void registerKernelExportsTests(Testing::TestSuite& suite) {
    suite.add(Testing::UnitTest("K14 kernel integer division is total (CGEN_084)", test_kernel_int_division_total));
    suite.add(Testing::UnitTest("K15 kernel shift count mod 64 (CGEN_085)", test_kernel_shift_count_mod_64));
    suite.add(Testing::UnitTest("K17 encoded case-mapping Chars at the kernel boundary (KERN_008)", test_char_encoded_kernels));
    suite.add(Testing::UnitTest("K18 Char and String case mapping (full Unicode, Final_Sigma)", test_case_mapping_kernels));
    suite.add(Testing::UnitTest("K1 encoder size matches write", test_encoder_size_matches_write));
    suite.add(Testing::UnitTest("K2 encoder endianness bytes", test_encoder_endianness_bytes));
    suite.add(Testing::UnitTest("K3 encoder utf8 astral", test_encoder_utf8_astral));
    suite.add(Testing::UnitTest("K4 encoder embeds slice", test_encoder_embeds_slice));
    suite.add(Testing::UnitTest("K5 encode large routes large header", test_encode_large_routes_large_header));
    suite.add(Testing::UnitTest("K6 decoder read primitives", test_decoder_read_primitives));
    suite.add(Testing::UnitTest("K7 decoder read_bytes -> slice", test_decoder_read_bytes_slice));
    suite.add(Testing::UnitTest("K8 decoder read_string utf8", test_decoder_read_string_utf8));
    suite.add(Testing::UnitTest("K8b decoder read_string goldens", test_decoder_read_string_goldens));
    suite.add(Testing::UnitTest("K8d decoder read_string agrees with fused", test_decoder_read_string_agrees_with_fused));
    suite.add(Testing::UnitTest("K8c decoder read_string representation", test_decoder_read_string_representation));
    suite.add(Testing::UnitTest("K9 string length all forms", test_string_length_all_forms));
    suite.add(Testing::UnitTest("K10 string foldl/foldr astral code-point count", test_string_foldl_astral_count));
    suite.add(Testing::UnitTest("K16 Char is a 32-bit code point at the kernel ABI", test_char_code_point_kernels));
    suite.add(Testing::UnitTest("K12 elm_bytebuffer runtime flat+large", test_elm_bytebuffer_runtime_flat_large));
}

void registerKernelExportsCrasherTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
    suite.add(Testing::TestCase("K11 elm_bytebuffer_len on slice [fail-now F3]", test_elm_bytebuffer_len_on_slice));
    suite.add(Testing::TestCase("K13 Bytes.width on slice [fail-now F3]", test_bytes_width_on_slice));
}
