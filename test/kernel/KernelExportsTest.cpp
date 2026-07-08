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
#include "../../runtime/src/allocator/ElmBytesRuntime.h"
#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../../elm-kernel-cpp/src/ExportHelpers.hpp"
#include "../allocator/TestHelpers.hpp"
#include "../TestSuite.hpp"
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
    HPtr le = eco_alloc_custom_fast(0, 0, 0);  // LE endianness ctor 0
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
    HPtr be = eco_alloc_custom_fast(1, 0, 0);  // BE
    HPtr le = eco_alloc_custom_fast(0, 0, 0);  // LE
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

// K6: read_* primitives return (newOffset, value); overrun returns Nothing.
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
    // 2 bytes requested at offset 4, only 1 available -> Nothing.
    TEST_ASSERT(isNothing(Elm_Kernel_Bytes_read_u16(trueLE, bb, 4)));
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

// K10: foldl invokes the closure once per UTF-16 code unit in Eco (Char is i16,
// per REP_ABI_001/CGEN_015). Over "a😀b" the astral char is two surrogate halves,
// so the closure is invoked 4 times (Elm's code-point fold would invoke it 3).
static void test_string_foldl_astral_count() {
    initAllocator();
    HPtr closure = eco_alloc_closure(reinterpret_cast<void*>(&countFoldEvaluator), 2);
    HPtr acc0 = eco_alloc_int(0);
    std::u16string s;
    s.push_back(u'a');
    s.push_back(0xD83D);
    s.push_back(0xDE00);
    s.push_back(u'b');
    HPtr result = Elm_Kernel_String_foldl(closure, acc0, strFromU16(s));
    TEST_ASSERT(decodeBoxedInt(result) == 4);
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
// Pins the CURRENT (pre-W1) observable behavior of Elm_Kernel_Bytes_read_string
// on ASCII, non-ASCII, and INVALID UTF-8 input, so wiring the UTF-8 fast path
// (plans/utf8-string-pipeline-wiring.md W1) cannot change decoded values. The
// legacy decoder reads past `length` on truncated sequences (a known quirk);
// to keep the golden deterministic we place each invalid prefix inside a
// zero-padded buffer and decode only the prefix length, so any read-past lands
// on known 0x00 padding rather than unallocated heap.
struct DecodeGolden {
    const char* name;
    std::vector<u8> prefix;   // the bytes to decode (length = prefix.size())
    bool nothing;             // expected: decode returned Nothing
    std::vector<u16> units;   // expected: decoded UTF-16 code units (if !nothing)
};

// Decode `prefix` (padded with 4 zero bytes so any read-past is deterministic)
// and return the resulting code units, or {nothing=true}.
static bool decodeGoldenUnits(const std::vector<u8>& prefix,
                              std::vector<u16>& outUnits) {
    std::vector<u8> padded = prefix;
    padded.insert(padded.end(), {0, 0, 0, 0});
    HPtr bb = bbFromVec(padded);
    HPtr r = Elm_Kernel_Bytes_read_string(static_cast<int64_t>(prefix.size()), bb, 0);
    if (isNothing(r)) return false;
    Tuple2* t = asTuple(r);
    void* strObj = Allocator::instance().resolve(t->b.p);
    size_t n = StringOps::length(strObj);
    outUnits.clear();
    for (size_t i = 0; i < n; ++i) outUnits.push_back(StringOps::charAt(strObj, i));
    return true;
}

static void test_decoder_read_string_goldens() {
    initAllocator();
    // The battery. `units` filled from a capture run against the unmodified
    // export; asserted verbatim thereafter (bug-compatibility, not "correct").
    std::vector<DecodeGolden> battery = {
        // --- valid ASCII (W1 DIVERTS these to UTF-8 forms; value must hold) ---
        {"ascii_1",   {'x'}, false, {'x'}},
        {"ascii_5",   {'h','e','l','l','o'}, false, {'h','e','l','l','o'}},
        {"ascii_31",  std::vector<u8>(31, 'a'), false, std::vector<u16>(31, u'a')},
        {"ascii_32",  std::vector<u8>(32, 'b'), false, std::vector<u16>(32, u'b')},
        {"ascii_33",  std::vector<u8>(33, 'c'), false, std::vector<u16>(33, u'c')},
        // --- valid non-ASCII (legacy path; must stay byte-identical) ---
        {"u0080",     {0xC2, 0x80}, false, {0x0080}},
        {"u07FF",     {0xDF, 0xBF}, false, {0x07FF}},
        {"u0800",     {0xE0, 0xA0, 0x80}, false, {0x0800}},
        {"uFFFF",     {0xEF, 0xBF, 0xBF}, false, {0xFFFF}},
        {"u10000",    {0xF0, 0x90, 0x80, 0x80}, false, {0xD800, 0xDC00}},
        {"u10FFFF",   {0xF4, 0x8F, 0xBF, 0xBF}, false, {0xDBFF, 0xDFFF}},
        {"mixed_astral", {'A', 0xF0, 0x9F, 0x98, 0x80, 'B'}, false,
                         {u'A', 0xD83D, 0xDE00, u'B'}},
        // --- invalid (legacy lenient path; values captured from the
        //     UNMODIFIED export via W0_CAPTURE_GOLDENS — garbage-tolerant, not
        //     "correct"; the point is byte-for-byte stability across W1/W2) ---
        {"bare_cont",     {0x80}, false, {0x0000}},
        {"trunc_2",       {0xC2}, false, {0x0080}},
        {"trunc_3",       {0xE2, 0x82}, false, {0x2080}},
        {"trunc_4",       {0xF0, 0x9F, 0x98}, false, {0xD83D, 0xDE00}},
        {"overlong_2",    {0xC0, 0x80}, false, {0x0000}},
        {"overlong_3",    {0xE0, 0x80, 0x80}, false, {0x0000}},
        {"overlong_4",    {0xF0, 0x80, 0x80, 0x80}, false, {0x0000, 0x0000}},
        {"surrogate",     {0xED, 0xA0, 0x80}, false, {0xD800}},
        {"gt_10FFFF",     {0xF4, 0x90, 0x80, 0x80}, false, {0xDC00, 0xDC00}},
        {"bad_cont",      {0xC2, 0x00}, false, {0x0080}},
    };

    bool CAPTURE = std::getenv("W0_CAPTURE_GOLDENS") != nullptr;
    for (auto& g : battery) {
        std::vector<u16> units;
        bool ok = decodeGoldenUnits(g.prefix, units);
        if (CAPTURE) {
            std::cout << "WGOLDEN|" << g.name << "|"
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
        TEST_ASSERT(ok == !g.nothing);
        if (ok) {
            TEST_ASSERT(units.size() == g.units.size());
            for (size_t i = 0; i < units.size() && i < g.units.size(); ++i) {
                TEST_ASSERT(units[i] == g.units[i]);
            }
        }
    }
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

void registerKernelExportsTests(Testing::TestSuite& suite) {
    suite.add(Testing::UnitTest("K1 encoder size matches write", test_encoder_size_matches_write));
    suite.add(Testing::UnitTest("K2 encoder endianness bytes", test_encoder_endianness_bytes));
    suite.add(Testing::UnitTest("K3 encoder utf8 astral", test_encoder_utf8_astral));
    suite.add(Testing::UnitTest("K4 encoder embeds slice", test_encoder_embeds_slice));
    suite.add(Testing::UnitTest("K5 encode large routes large header", test_encode_large_routes_large_header));
    suite.add(Testing::UnitTest("K6 decoder read primitives", test_decoder_read_primitives));
    suite.add(Testing::UnitTest("K7 decoder read_bytes -> slice", test_decoder_read_bytes_slice));
    suite.add(Testing::UnitTest("K8 decoder read_string utf8", test_decoder_read_string_utf8));
    suite.add(Testing::UnitTest("K8b decoder read_string goldens", test_decoder_read_string_goldens));
    suite.add(Testing::UnitTest("K8c decoder read_string representation", test_decoder_read_string_representation));
    suite.add(Testing::UnitTest("K9 string length all forms", test_string_length_all_forms));
    suite.add(Testing::UnitTest("K10 string foldl astral code-unit count", test_string_foldl_astral_count));
    suite.add(Testing::UnitTest("K12 elm_bytebuffer runtime flat+large", test_elm_bytebuffer_runtime_flat_large));
}

void registerKernelExportsCrasherTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
    suite.add(Testing::TestCase("K11 elm_bytebuffer_len on slice [fail-now F3]", test_elm_bytebuffer_len_on_slice));
    suite.add(Testing::TestCase("K13 Bytes.width on slice [fail-now F3]", test_bytes_width_on_slice));
}
