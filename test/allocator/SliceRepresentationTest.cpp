// Byte-buffer / String representation coverage (plan: string-bytes-testing-gap.md).
//
// Covers the non-flat representations that the existing BytesOps/StringOps
// suites under-test: Tag_ByteBufferSlice, Tag_LargeByteHeader, Tag_StringSlice,
// Tag_StringRope, Tag_LargeStringHeader. The clean tests fail via a thrown
// assertion (caught by the runner) or pass; the crasher tests drive a real GC
// over a byte slice and may abort the process under the getObjectSize (F1) bug.

#include "SliceRepresentationTest.hpp"
#include "../../runtime/src/allocator/AllocatorCommon.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/BytesOps.hpp"
#include "../../runtime/src/allocator/StringOps.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "TestHelpers.hpp"
#include "../TestSuite.hpp"
#include <string>
#include <vector>

using namespace Elm;

namespace {

// Compare two eco.value HPointers by raw bits (for Just/Nothing discrimination).
static bool sameHP(HPointer a, HPointer b) {
    return HPtr::fromHPointer(a).toBits() == HPtr::fromHPointer(b).toBits();
}

// ---------------------------------------------------------------------------
// G2 — byte buffer slice + large-header (U4, U5, U7, U9, U10, U11)
// ---------------------------------------------------------------------------

// U4: a slice of length >= 32 is a real Tag_ByteBufferSlice with correct length.
static void test_bytebuffer_slice_tag() {
    auto& alloc = initAllocator();
    std::vector<u8> data(64);
    for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<u8>(i);
    HPointer buf = BytesOps::fromVector(data);
    HPointer sliceHP = BytesOps::slice(alloc.resolve(buf), 10, 50);  // 40 bytes
    void* sliceObj = alloc.resolve(sliceHP);
    TEST_ASSERT(alloc::getTag(sliceObj) == Tag_ByteBufferSlice);
    TEST_ASSERT(BytesOps::length(sliceObj) == 40);
}

// U5: slice-of-slice collapses to a single slice over the underlying leaf,
// absorbing the offset.
static void test_bytebuffer_slice_of_slice_collapses() {
    auto& alloc = initAllocator();
    std::vector<u8> data(64);
    for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<u8>(i);
    HPointer buf = BytesOps::fromVector(data);
    HPointer sliceHP = BytesOps::slice(alloc.resolve(buf), 10, 50);   // [10,50)
    HPointer slice2HP = BytesOps::slice(alloc.resolve(sliceHP), 2, 38);  // [12,48), 36 bytes
    void* s2 = alloc.resolve(slice2HP);
    TEST_ASSERT(alloc::getTag(s2) == Tag_ByteBufferSlice);
    std::vector<u8> want;
    for (int i = 12; i < 48; ++i) want.push_back(static_cast<u8>(i));
    TEST_ASSERT(BytesOps::toVector(s2) == want);
    // Base must be the flat leaf (collapsed), not the intermediate slice.
    ElmByteBufferSlice* slc = static_cast<ElmByteBufferSlice*>(s2);
    TEST_ASSERT(alloc::getTag(alloc.resolve(slc->base)) == Tag_ByteBuffer);
    TEST_ASSERT(slc->offset == 12);
}

// U7: byteBufferView / getAt / toVector read through the slice offset.
static void test_bytebuffer_slice_reads_through_offset() {
    auto& alloc = initAllocator();
    std::vector<u8> data(64);
    for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<u8>(i);
    HPointer buf = BytesOps::fromVector(data);
    void* sliceObj = alloc.resolve(BytesOps::slice(alloc.resolve(buf), 10, 50));
    for (int i = 0; i < 40; ++i) {
        TEST_ASSERT(BytesOps::getAt(sliceObj, i) == 10 + i);
    }
    TEST_ASSERT(BytesOps::getAt(sliceObj, 40) == -1);   // out of bounds
    std::vector<u8> want;
    for (int i = 10; i < 50; ++i) want.push_back(static_cast<u8>(i));
    TEST_ASSERT(BytesOps::toVector(sliceObj) == want);
}

// U9: operations on a Tag_LargeByteHeader (>= 8 KiB) buffer.
static void test_large_bytebuffer_ops() {
    auto& alloc = initAllocator();
    std::vector<u8> data(10000);
    for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<u8>(i & 0xFF);
    HPointer buf = BytesOps::fromVector(data);
    void* bufObj = alloc.resolve(buf);
    TEST_ASSERT(alloc::getTag(bufObj) == Tag_LargeByteHeader);
    TEST_ASSERT(BytesOps::length(bufObj) == 10000);
    TEST_ASSERT(BytesOps::getAt(bufObj, 5000) == (5000 & 0xFF));
    TEST_ASSERT(BytesOps::toVector(bufObj) == data);
    TEST_ASSERT(BytesOps::equal(bufObj, bufObj));
    // A slice over a large header.
    HPointer sliceHP = BytesOps::slice(alloc.resolve(buf), 100, 5000);  // 4900 bytes
    void* sliceObj = alloc.resolve(sliceHP);
    TEST_ASSERT(alloc::getTag(sliceObj) == Tag_ByteBufferSlice);
    TEST_ASSERT(BytesOps::length(sliceObj) == 4900);
    TEST_ASSERT(BytesOps::getAt(sliceObj, 0) == (100 & 0xFF));
}

// U10: appending two large (>= 8 KiB) buffers.
static void test_large_bytebuffer_append() {
    auto& alloc = initAllocator();
    HPointer ha = BytesOps::fromVector(std::vector<u8>(9000, 0xAA));
    HPointer hb = BytesOps::fromVector(std::vector<u8>(9000, 0xBB));
    alloc.getRootSet().addRoot(&ha);
    alloc.getRootSet().addRoot(&hb);
    HPointer hr = BytesOps::append(alloc.resolve(ha), alloc.resolve(hb));
    void* r = alloc.resolve(hr);
    TEST_ASSERT(BytesOps::length(r) == 18000);
    TEST_ASSERT(BytesOps::getAt(r, 0) == 0xAA);
    TEST_ASSERT(BytesOps::getAt(r, 8999) == 0xAA);
    TEST_ASSERT(BytesOps::getAt(r, 9000) == 0xBB);
    TEST_ASSERT(BytesOps::getAt(r, 17999) == 0xBB);
    alloc.getRootSet().removeRoot(&hb);
    alloc.getRootSet().removeRoot(&ha);
}

// U11 (fail-now, F1): getObjectSize must report a slice as 24 bytes, not 8.
static void test_getObjectSize_bytebuffer_slice() {
    auto& alloc = initAllocator();
    HPointer buf = BytesOps::fromVector(std::vector<u8>(64, 7));
    void* sliceObj = alloc.resolve(BytesOps::slice(alloc.resolve(buf), 10, 50));
    TEST_ASSERT(alloc::getTag(sliceObj) == Tag_ByteBufferSlice);
    // ElmByteBufferSlice is 24 bytes (static_assert in Heap.hpp). getObjectSize
    // omits the Tag_ByteBufferSlice case and falls through to sizeof(Header)=8.
    TEST_ASSERT(getObjectSize(sliceObj) == sizeof(ElmByteBufferSlice));
}

// ---------------------------------------------------------------------------
// G4 — GC of non-flat forms, direct (U13, U14, U16). Byte-slice GC lives in
// the crasher suite below.
// ---------------------------------------------------------------------------

// U13: a Tag_StringRope survives minor + major GC with content intact.
static void test_string_rope_survives_gc() {
    auto& alloc = initAllocator();
    HPointer left = alloc::allocString(std::u16string(2000, u'a'));
    HPointer right = alloc::allocString(std::u16string(2000, u'b'));
    alloc.getRootSet().addRoot(&left);
    alloc.getRootSet().addRoot(&right);
    HPointer rope = StringOps::makeRope(left, right);
    alloc.getRootSet().addRoot(&rope);
    TEST_ASSERT(alloc::getTag(alloc.resolve(rope)) == Tag_StringRope);
    alloc.minorGC();
    runMarkAndSweep(alloc);
    void* r = alloc.resolve(rope);
    TEST_ASSERT(StringOps::length(r) == 4000);
    std::string s = StringOps::toStdString(r);
    TEST_ASSERT(s.size() == 4000 && s.front() == 'a' && s[1999] == 'a' &&
                s[2000] == 'b' && s.back() == 'b');
    alloc.getRootSet().removeRoot(&rope);
    alloc.getRootSet().removeRoot(&right);
    alloc.getRootSet().removeRoot(&left);
}

// U14: a Tag_StringSlice survives GC (string slices HAVE a getObjectSize case,
// unlike byte slices — this should pass, contrasting with U6).
static void test_string_slice_survives_gc() {
    auto& alloc = initAllocator();
    HPointer base = alloc::allocString(std::u16string(6000, u'z'));
    alloc.getRootSet().addRoot(&base);
    HPointer sliceHP = StringOps::slice(alloc.resolve(base), 1000, 4000);
    alloc.getRootSet().addRoot(&sliceHP);
    TEST_ASSERT(alloc::getTag(alloc.resolve(sliceHP)) == Tag_StringSlice);
    alloc.minorGC();
    runMarkAndSweep(alloc);
    void* sl = alloc.resolve(sliceHP);
    TEST_ASSERT(StringOps::length(sl) == 3000);
    std::string s = StringOps::toStdString(sl);
    TEST_ASSERT(s.size() == 3000 && s.front() == 'z' && s.back() == 'z');
    alloc.getRootSet().removeRoot(&sliceHP);
    alloc.getRootSet().removeRoot(&base);
}

// U16: large split-headers (string + byte) survive minor + major GC.
static void test_large_headers_survive_gc() {
    auto& alloc = initAllocator();
    HPointer bigStr = alloc::allocString(std::u16string(6000, u's'));
    HPointer bigBuf = BytesOps::fromVector(std::vector<u8>(10000, 0xCC));
    alloc.getRootSet().addRoot(&bigStr);
    alloc.getRootSet().addRoot(&bigBuf);
    TEST_ASSERT(alloc::getTag(alloc.resolve(bigStr)) == Tag_LargeStringHeader);
    TEST_ASSERT(alloc::getTag(alloc.resolve(bigBuf)) == Tag_LargeByteHeader);
    alloc.minorGC();
    runMarkAndSweep(alloc);
    TEST_ASSERT(StringOps::length(alloc.resolve(bigStr)) == 6000);
    TEST_ASSERT(StringOps::toStdString(alloc.resolve(bigStr)).size() == 6000);
    TEST_ASSERT(BytesOps::length(alloc.resolve(bigBuf)) == 10000);
    TEST_ASSERT(BytesOps::getAt(alloc.resolve(bigBuf), 9999) == 0xCC);
    alloc.getRootSet().removeRoot(&bigBuf);
    alloc.getRootSet().removeRoot(&bigStr);
}

// ---------------------------------------------------------------------------
// G5/G6 — content round-trips + encode/decode holes (U17, U18, U20, U21)
// ---------------------------------------------------------------------------

// U17: encodeUtf8 emits correct multi-byte UTF-8 for 2- and 3-byte code points.
static void test_encode_utf8_multibyte() {
    auto& alloc = initAllocator();
    std::u16string s16;
    s16.push_back(0x00E9);  // é -> C3 A9
    s16.push_back(0x20AC);  // € -> E2 82 AC
    HPointer str = alloc::allocString(s16);
    HPointer bb = BytesOps::encodeUtf8(alloc.resolve(str));
    std::vector<u8> got = BytesOps::toVector(alloc.resolve(bb));
    std::vector<u8> want = {0xC3, 0xA9, 0xE2, 0x82, 0xAC};
    TEST_ASSERT(got == want);
}

// U18: 32-bit encode, both endiannesses, plus a signed (two's complement) value.
static void test_encode_int32_endianness() {
    auto& alloc = initAllocator();
    using BytesOps::Width;
    using BytesOps::Endianness;
    HPointer be = BytesOps::encodeUnsignedInt(0x01020304u, Width::W32, Endianness::BE);
    TEST_ASSERT(BytesOps::toVector(alloc.resolve(be)) ==
                (std::vector<u8>{0x01, 0x02, 0x03, 0x04}));
    HPointer le = BytesOps::encodeUnsignedInt(0x01020304u, Width::W32, Endianness::LE);
    TEST_ASSERT(BytesOps::toVector(alloc.resolve(le)) ==
                (std::vector<u8>{0x04, 0x03, 0x02, 0x01}));
    HPointer sgn = BytesOps::encodeSignedInt(-2, Width::W32, Endianness::LE);  // 0xFFFFFFFE
    TEST_ASSERT(BytesOps::toVector(alloc.resolve(sgn)) ==
                (std::vector<u8>{0xFE, 0xFF, 0xFF, 0xFF}));
}

// U20: decode at a non-zero offset returns Just; past-end returns Nothing.
static void test_decode_nonzero_offset_and_bounds() {
    auto& alloc = initAllocator();
    using BytesOps::Width;
    using BytesOps::Endianness;
    HPointer buf = BytesOps::fromVector({10, 20, 30, 40, 50});
    void* b = alloc.resolve(buf);
    TEST_ASSERT(BytesOps::getAt(b, 2) == 30);
    HPointer nothing = alloc::nothing();
    // valid non-zero offset -> Just
    TEST_ASSERT(!sameHP(BytesOps::decodeUnsignedInt(b, 2, Width::W8, Endianness::BE), nothing));
    TEST_ASSERT(!sameHP(BytesOps::decodeUnsignedInt(b, 3, Width::W16, Endianness::BE), nothing));
    // past end -> Nothing
    TEST_ASSERT(sameHP(BytesOps::decodeUnsignedInt(b, 5, Width::W8, Endianness::BE), nothing));
    TEST_ASSERT(sameHP(BytesOps::decodeUnsignedInt(b, 4, Width::W16, Endianness::BE), nothing));
}

// U21: different buffers hash differently; same buffer hashes consistently.
static void test_hash_distinguishes_buffers() {
    auto& alloc = initAllocator();
    HPointer a = BytesOps::fromVector({1, 2, 3});
    HPointer b = BytesOps::fromVector({1, 2, 4});
    TEST_ASSERT(BytesOps::hash(alloc.resolve(a)) != BytesOps::hash(alloc.resolve(b)));
    TEST_ASSERT(BytesOps::hash(alloc.resolve(a)) == BytesOps::hash(alloc.resolve(a)));
}

// ---------------------------------------------------------------------------
// G6/G7 — string large-header ops, cross-representation compare, op matrix
// (U22, U23, U24)
// ---------------------------------------------------------------------------

// U22: a top-level Tag_LargeStringHeader answers length/charAt/slice/toStdString.
static void test_large_string_header_ops() {
    auto& alloc = initAllocator();
    HPointer str = alloc::allocString(std::u16string(5000, u'a'));
    void* s = alloc.resolve(str);
    TEST_ASSERT(alloc::getTag(s) == Tag_LargeStringHeader);
    TEST_ASSERT(StringOps::length(s) == 5000);
    TEST_ASSERT(StringOps::charAt(s, 0) == u'a');
    TEST_ASSERT(StringOps::charAt(s, 4999) == u'a');
    TEST_ASSERT(StringOps::toStdString(s).size() == 5000);
    void* sl = alloc.resolve(StringOps::slice(alloc.resolve(str), 1000, 4000));
    TEST_ASSERT(StringOps::length(sl) == 3000);
    TEST_ASSERT(StringOps::toStdString(sl).size() == 3000);
}

// U23: equal/compare are correct across flat vs slice representations, and
// ordering works (not just equality).
static void test_string_compare_across_representations() {
    auto& alloc = initAllocator();
    HPointer flat200 = alloc::allocString(std::u16string(200, u'a'));
    HPointer base = alloc::allocString(std::u16string(500, u'a'));
    std::u16string diffS(200, u'a');
    diffS[199] = u'b';
    HPointer flatDiff = alloc::allocString(diffS);
    HPointer slice200 = StringOps::slice(alloc.resolve(base), 100, 300);  // 200 'a's
    void* f = alloc.resolve(flat200);
    void* sl = alloc.resolve(slice200);
    void* d = alloc.resolve(flatDiff);
    TEST_ASSERT(alloc::getTag(sl) == Tag_StringSlice);
    TEST_ASSERT(StringOps::equal(f, sl) == true);
    TEST_ASSERT(StringOps::compare(f, sl) == 0);
    TEST_ASSERT(StringOps::compare(f, d) < 0);   // "...a" < "...b"
    TEST_ASSERT(StringOps::compare(d, f) > 0);
    TEST_ASSERT(StringOps::equal(f, d) == false);
}

// U24: run length/toStdString/charAt against flat, large, slice, and rope forms.
static void test_string_op_matrix() {
    auto& alloc = initAllocator();
    // flat leaf
    void* f = alloc.resolve(alloc::allocString(std::u16string(u"hello world")));
    TEST_ASSERT(alloc::getTag(f) == Tag_String);
    TEST_ASSERT(StringOps::length(f) == 11);
    TEST_ASSERT(StringOps::toStdString(f) == "hello world");
    TEST_ASSERT(StringOps::charAt(f, 0) == u'h');
    // large header
    HPointer large = alloc::allocString(std::u16string(5000, u'L'));
    void* l = alloc.resolve(large);
    TEST_ASSERT(alloc::getTag(l) == Tag_LargeStringHeader);
    TEST_ASSERT(StringOps::length(l) == 5000);
    TEST_ASSERT(StringOps::charAt(l, 4999) == u'L');
    // slice (over the large header)
    void* s = alloc.resolve(StringOps::slice(alloc.resolve(large), 100, 3100));
    TEST_ASSERT(alloc::getTag(s) == Tag_StringSlice);
    TEST_ASSERT(StringOps::length(s) == 3000);
    TEST_ASSERT(StringOps::charAt(s, 0) == u'L');
    // rope
    HPointer L2 = alloc::allocString(std::u16string(u"foo"));
    HPointer R2 = alloc::allocString(std::u16string(u"bar"));
    alloc.getRootSet().addRoot(&L2);
    alloc.getRootSet().addRoot(&R2);
    void* r = alloc.resolve(StringOps::makeRope(L2, R2));
    TEST_ASSERT(alloc::getTag(r) == Tag_StringRope);
    TEST_ASSERT(StringOps::length(r) == 6);
    TEST_ASSERT(StringOps::toStdString(r) == "foobar");
    TEST_ASSERT(StringOps::charAt(r, 3) == u'b');
    alloc.getRootSet().removeRoot(&R2);
    alloc.getRootSet().removeRoot(&L2);
}

// ---------------------------------------------------------------------------
// Crasher tests (U6, U15, U25) — byte-slice GC under F1. Registered LAST.
// Each checks the raw `offset` field (an int compare) BEFORE dereferencing the
// possibly-corrupted base, so it fails cleanly if the minor-GC scan itself does
// not abort first.
// ---------------------------------------------------------------------------

// U6 (fail-now, F1): a byte slice survives a minor GC.
static void test_bytebuffer_slice_survives_minor_gc() {
    auto& alloc = initAllocator();
    std::vector<u8> data(64);
    for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<u8>(i);
    HPointer buf = BytesOps::fromVector(data);
    alloc.getRootSet().addRoot(&buf);
    HPointer sliceHP = BytesOps::slice(alloc.resolve(buf), 10, 50);
    alloc.getRootSet().addRoot(&sliceHP);
    TEST_ASSERT(alloc::getTag(alloc.resolve(sliceHP)) == Tag_ByteBufferSlice);
    alloc.minorGC();
    void* s1 = alloc.resolve(sliceHP);
    TEST_ASSERT(alloc::getTag(s1) == Tag_ByteBufferSlice);
    ElmByteBufferSlice* slc = static_cast<ElmByteBufferSlice*>(s1);
    TEST_ASSERT(slc->offset == 10);  // F1: offset not evacuated -> garbage
    TEST_ASSERT(BytesOps::toVector(s1) ==
                std::vector<u8>(data.begin() + 10, data.begin() + 50));
    alloc.getRootSet().removeRoot(&sliceHP);
    alloc.getRootSet().removeRoot(&buf);
}

// U15 (fail-now, F1): byte slice with a live neighbour survives a minor GC
// (targets the Cheney scan stride, which mis-steps by 8 vs 24).
static void test_bytebuffer_slice_scan_stride() {
    auto& alloc = initAllocator();
    std::vector<u8> data(64);
    for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<u8>(i);
    HPointer buf = BytesOps::fromVector(data);
    alloc.getRootSet().addRoot(&buf);
    HPointer sliceHP = BytesOps::slice(alloc.resolve(buf), 10, 50);
    alloc.getRootSet().addRoot(&sliceHP);
    HPointer neighbour = BytesOps::fromVector(std::vector<u8>{0xDE, 0xAD, 0xBE, 0xEF});
    alloc.getRootSet().addRoot(&neighbour);
    alloc.minorGC();
    // Slice and neighbour both intact after the strided scan.
    ElmByteBufferSlice* slc = static_cast<ElmByteBufferSlice*>(alloc.resolve(sliceHP));
    TEST_ASSERT(slc->offset == 10);
    TEST_ASSERT(BytesOps::toVector(alloc.resolve(neighbour)) ==
                (std::vector<u8>{0xDE, 0xAD, 0xBE, 0xEF}));
    alloc.getRootSet().removeRoot(&neighbour);
    alloc.getRootSet().removeRoot(&sliceHP);
    alloc.getRootSet().removeRoot(&buf);
}

// U25 (fail-now, F1): a byte slice survives promotion to old gen + major GC.
static void test_bytebuffer_slice_survives_promotion() {
    auto& alloc = initAllocator();
    std::vector<u8> data(64);
    for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<u8>(i);
    HPointer buf = BytesOps::fromVector(data);
    alloc.getRootSet().addRoot(&buf);
    HPointer sliceHP = BytesOps::slice(alloc.resolve(buf), 10, 50);
    alloc.getRootSet().addRoot(&sliceHP);
    promoteToOldGen(alloc);
    runMarkAndSweep(alloc);
    void* s1 = alloc.resolve(sliceHP);
    TEST_ASSERT(alloc::getTag(s1) == Tag_ByteBufferSlice);
    ElmByteBufferSlice* slc = static_cast<ElmByteBufferSlice*>(s1);
    TEST_ASSERT(slc->offset == 10);
    TEST_ASSERT(BytesOps::toVector(s1) ==
                std::vector<u8>(data.begin() + 10, data.begin() + 50));
    alloc.getRootSet().removeRoot(&sliceHP);
    alloc.getRootSet().removeRoot(&buf);
}

}  // namespace

void registerSliceRepresentationTests(Testing::TestSuite& suite) {
    suite.add(Testing::UnitTest("U4 byte slice has Tag_ByteBufferSlice", test_bytebuffer_slice_tag));
    suite.add(Testing::UnitTest("U5 byte slice-of-slice collapses", test_bytebuffer_slice_of_slice_collapses));
    suite.add(Testing::UnitTest("U7 byte slice reads through offset", test_bytebuffer_slice_reads_through_offset));
    suite.add(Testing::UnitTest("U9 large byte buffer ops", test_large_bytebuffer_ops));
    suite.add(Testing::UnitTest("U10 large byte buffer append", test_large_bytebuffer_append));
    suite.add(Testing::UnitTest("U11 getObjectSize(byte slice)==24 [fail-now F1]", test_getObjectSize_bytebuffer_slice));
    suite.add(Testing::UnitTest("U13 string rope survives GC", test_string_rope_survives_gc));
    suite.add(Testing::UnitTest("U14 string slice survives GC", test_string_slice_survives_gc));
    suite.add(Testing::UnitTest("U16 large headers survive GC", test_large_headers_survive_gc));
    suite.add(Testing::UnitTest("U17 encodeUtf8 multibyte", test_encode_utf8_multibyte));
    suite.add(Testing::UnitTest("U18 encode int32 endianness", test_encode_int32_endianness));
    suite.add(Testing::UnitTest("U20 decode nonzero offset + bounds", test_decode_nonzero_offset_and_bounds));
    suite.add(Testing::UnitTest("U21 hash distinguishes buffers", test_hash_distinguishes_buffers));
    suite.add(Testing::UnitTest("U22 large string header ops", test_large_string_header_ops));
    suite.add(Testing::UnitTest("U23 string compare across representations", test_string_compare_across_representations));
    suite.add(Testing::UnitTest("U24 string op matrix", test_string_op_matrix));
}

void registerSliceCrasherTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
    suite.add(Testing::TestCase("U6 byte slice survives minor GC [fail-now F1]", test_bytebuffer_slice_survives_minor_gc));
    suite.add(Testing::TestCase("U15 byte slice scan stride [fail-now F1]", test_bytebuffer_slice_scan_stride));
    suite.add(Testing::TestCase("U25 byte slice survives promotion [fail-now F1]", test_bytebuffer_slice_survives_promotion));
}
