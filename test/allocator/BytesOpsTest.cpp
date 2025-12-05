/**
 * Property-based tests for BytesOps.hpp.
 */

#include "BytesOpsTest.hpp"
#include "../../runtime/src/allocator/BytesOps.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "TestHelpers.hpp"
#include <rapidcheck.h>
#include <cstring>
#include <algorithm>
#include <cmath>

using namespace Elm;

// ============================================================================
// Empty Tests
// ============================================================================

static void test_empty_has_zero_length() {
    rc::check("empty ByteBuffer has zero length", []() {
        initAllocator();

        HPointer buf = BytesOps::empty();
        void* obj = Allocator::instance().resolve(buf);

        RC_ASSERT(BytesOps::length(obj) == 0);
    });
}

// ============================================================================
// fromData/toVector Tests
// ============================================================================

static void test_fromData_preserves_bytes() {
    rc::check("fromData preserves all bytes", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        HPointer buf = BytesOps::fromData(data.data(), data.size());
        void* obj = Allocator::instance().resolve(buf);

        std::vector<u8> result = BytesOps::toVector(obj);

        RC_ASSERT(result == data);
    });
}

static void test_fromVector_preserves_bytes() {
    rc::check("fromVector preserves all bytes", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        HPointer buf = BytesOps::fromVector(data);
        void* obj = Allocator::instance().resolve(buf);

        std::vector<u8> result = BytesOps::toVector(obj);

        RC_ASSERT(result == data);
    });
}

// ============================================================================
// Length Tests
// ============================================================================

static void test_length_matches_input() {
    rc::check("length matches input size", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        HPointer buf = BytesOps::fromVector(data);
        void* obj = Allocator::instance().resolve(buf);

        RC_ASSERT(BytesOps::length(obj) == static_cast<i64>(data.size()));
    });
}

// ============================================================================
// getAt Tests
// ============================================================================

static void test_getAt_returns_correct_byte() {
    rc::check("getAt returns correct byte", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );
        if (data.empty()) return;

        size_t idx = *rc::gen::inRange<size_t>(0, data.size());

        HPointer buf = BytesOps::fromVector(data);
        void* obj = Allocator::instance().resolve(buf);

        i64 result = BytesOps::getAt(obj, static_cast<i64>(idx));

        RC_ASSERT(result == static_cast<i64>(data[idx]));
    });
}

static void test_getAt_out_of_bounds_returns_minus_one() {
    rc::check("getAt out of bounds returns -1", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        HPointer buf = BytesOps::fromVector(data);
        void* obj = Allocator::instance().resolve(buf);

        // Test past end
        RC_ASSERT(BytesOps::getAt(obj, static_cast<i64>(data.size())) == -1);
        RC_ASSERT(BytesOps::getAt(obj, static_cast<i64>(data.size()) + 100) == -1);
        // Test negative
        RC_ASSERT(BytesOps::getAt(obj, -1) == -1);
    });
}

// ============================================================================
// Slice Tests
// ============================================================================

static void test_slice_extracts_subbuffer() {
    rc::check("slice extracts correct subbuffer", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );
        if (data.size() < 2) return;

        size_t start = *rc::gen::inRange<size_t>(0, data.size());
        size_t end = *rc::gen::inRange<size_t>(start, data.size() + 1);

        HPointer buf = BytesOps::fromVector(data);
        void* obj = Allocator::instance().resolve(buf);

        HPointer result = BytesOps::slice(obj, static_cast<i64>(start), static_cast<i64>(end));
        void* resultObj = Allocator::instance().resolve(result);

        std::vector<u8> actual = BytesOps::toVector(resultObj);
        std::vector<u8> expected(data.begin() + start, data.begin() + end);

        RC_ASSERT(actual == expected);
    });
}

static void test_slice_clamps_to_bounds() {
    rc::check("slice clamps to bounds", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        HPointer buf = BytesOps::fromVector(data);
        void* obj = Allocator::instance().resolve(buf);

        // Slice with out-of-bounds indices should clamp
        HPointer result = BytesOps::slice(obj, 0, 10000);
        void* resultObj = Allocator::instance().resolve(result);

        RC_ASSERT(BytesOps::toVector(resultObj) == data);
    });
}

// ============================================================================
// Integer Encoding/Decoding Tests
// ============================================================================

static void test_encode_decode_unsigned_int_8() {
    rc::check("encode/decode unsigned 8-bit roundtrips", []() {
        initAllocator();

        u64 val = *rc::gen::inRange<u64>(0, 256);

        for (auto endian : {BytesOps::Endianness::LE, BytesOps::Endianness::BE}) {
            HPointer encoded = BytesOps::encodeUnsignedInt(val, BytesOps::Width::W8, endian);
            void* encObj = Allocator::instance().resolve(encoded);

            HPointer decoded = BytesOps::decodeUnsignedInt(encObj, 0, BytesOps::Width::W8, endian);
            void* decObj = Allocator::instance().resolve(decoded);

            // Should be Just(val)
            Custom* custom = static_cast<Custom*>(decObj);
            RC_ASSERT(custom->ctor == 0);  // Just
            RC_ASSERT(custom->values[0].i == static_cast<i64>(val));
        }
    });
}

static void test_encode_decode_unsigned_int_16() {
    rc::check("encode/decode unsigned 16-bit roundtrips", []() {
        initAllocator();

        u64 val = *rc::gen::inRange<u64>(0, 65536);

        for (auto endian : {BytesOps::Endianness::LE, BytesOps::Endianness::BE}) {
            HPointer encoded = BytesOps::encodeUnsignedInt(val, BytesOps::Width::W16, endian);
            void* encObj = Allocator::instance().resolve(encoded);

            HPointer decoded = BytesOps::decodeUnsignedInt(encObj, 0, BytesOps::Width::W16, endian);
            void* decObj = Allocator::instance().resolve(decoded);

            Custom* custom = static_cast<Custom*>(decObj);
            RC_ASSERT(custom->ctor == 0);
            RC_ASSERT(custom->values[0].i == static_cast<i64>(val));
        }
    });
}

static void test_encode_decode_unsigned_int_32() {
    rc::check("encode/decode unsigned 32-bit roundtrips", []() {
        initAllocator();

        u64 val = *rc::gen::inRange<u64>(0, 0xFFFFFFFFULL);

        for (auto endian : {BytesOps::Endianness::LE, BytesOps::Endianness::BE}) {
            HPointer encoded = BytesOps::encodeUnsignedInt(val, BytesOps::Width::W32, endian);
            void* encObj = Allocator::instance().resolve(encoded);

            HPointer decoded = BytesOps::decodeUnsignedInt(encObj, 0, BytesOps::Width::W32, endian);
            void* decObj = Allocator::instance().resolve(decoded);

            Custom* custom = static_cast<Custom*>(decObj);
            RC_ASSERT(custom->ctor == 0);
            RC_ASSERT(custom->values[0].i == static_cast<i64>(val));
        }
    });
}

static void test_encode_decode_signed_int_8() {
    rc::check("encode/decode signed 8-bit roundtrips", []() {
        initAllocator();

        i64 val = *rc::gen::inRange<i64>(-128, 128);

        for (auto endian : {BytesOps::Endianness::LE, BytesOps::Endianness::BE}) {
            HPointer encoded = BytesOps::encodeSignedInt(val, BytesOps::Width::W8, endian);
            void* encObj = Allocator::instance().resolve(encoded);

            HPointer decoded = BytesOps::decodeSignedInt(encObj, 0, BytesOps::Width::W8, endian);
            void* decObj = Allocator::instance().resolve(decoded);

            Custom* custom = static_cast<Custom*>(decObj);
            RC_ASSERT(custom->ctor == 0);
            RC_ASSERT(custom->values[0].i == val);
        }
    });
}

static void test_encode_decode_signed_int_16() {
    rc::check("encode/decode signed 16-bit roundtrips", []() {
        initAllocator();

        i64 val = *rc::gen::inRange<i64>(-32768, 32768);

        for (auto endian : {BytesOps::Endianness::LE, BytesOps::Endianness::BE}) {
            HPointer encoded = BytesOps::encodeSignedInt(val, BytesOps::Width::W16, endian);
            void* encObj = Allocator::instance().resolve(encoded);

            HPointer decoded = BytesOps::decodeSignedInt(encObj, 0, BytesOps::Width::W16, endian);
            void* decObj = Allocator::instance().resolve(decoded);

            Custom* custom = static_cast<Custom*>(decObj);
            RC_ASSERT(custom->ctor == 0);
            RC_ASSERT(custom->values[0].i == val);
        }
    });
}

// ============================================================================
// Float Encoding/Decoding Tests
// ============================================================================

static void test_encode_decode_float32() {
    rc::check("encode/decode float32 roundtrips", []() {
        initAllocator();

        // Generate an integer and convert to float to avoid RapidCheck double issues
        i64 val_int = *rc::gen::inRange<i64>(-1000, 1000);
        f64 val = static_cast<f64>(val_int) + 0.5;

        for (auto endian : {BytesOps::Endianness::LE, BytesOps::Endianness::BE}) {
            HPointer encoded = BytesOps::encodeFloat32(val, endian);
            void* encObj = Allocator::instance().resolve(encoded);

            HPointer decoded = BytesOps::decodeFloat32(encObj, 0, endian);
            void* decObj = Allocator::instance().resolve(decoded);

            Custom* custom = static_cast<Custom*>(decObj);
            RC_ASSERT(custom->ctor == 0);  // Just
            // Float32 has less precision, so allow tolerance
            RC_ASSERT(std::abs(custom->values[0].f - static_cast<float>(val)) < 1e-3);
        }
    });
}

static void test_encode_decode_float64() {
    rc::check("encode/decode float64 roundtrips", []() {
        initAllocator();

        // Generate an integer and convert to double
        i64 val_int = *rc::gen::inRange<i64>(-1000000, 1000000);
        f64 val = static_cast<f64>(val_int) + 0.123456;

        for (auto endian : {BytesOps::Endianness::LE, BytesOps::Endianness::BE}) {
            HPointer encoded = BytesOps::encodeFloat64(val, endian);
            void* encObj = Allocator::instance().resolve(encoded);

            HPointer decoded = BytesOps::decodeFloat64(encObj, 0, endian);
            void* decObj = Allocator::instance().resolve(decoded);

            Custom* custom = static_cast<Custom*>(decObj);
            RC_ASSERT(custom->ctor == 0);
            RC_ASSERT(custom->values[0].f == val);
        }
    });
}

// ============================================================================
// Append Tests
// ============================================================================

static void test_append_concatenates() {
    rc::check("append concatenates two buffers", []() {
        initAllocator();

        std::vector<u8> a = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );
        std::vector<u8> b = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        HPointer bufA = BytesOps::fromVector(a);
        HPointer bufB = BytesOps::fromVector(b);

        auto& alloc = Allocator::instance();
        HPointer result = BytesOps::append(alloc.resolve(bufA), alloc.resolve(bufB));

        std::vector<u8> expected = a;
        expected.insert(expected.end(), b.begin(), b.end());

        RC_ASSERT(BytesOps::toVector(alloc.resolve(result)) == expected);
    });
}

static void test_append_empty_left() {
    rc::check("append with empty left returns right", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        HPointer empty = BytesOps::empty();
        HPointer buf = BytesOps::fromVector(data);

        auto& alloc = Allocator::instance();
        HPointer result = BytesOps::append(alloc.resolve(empty), alloc.resolve(buf));

        RC_ASSERT(BytesOps::toVector(alloc.resolve(result)) == data);
    });
}

static void test_append_empty_right() {
    rc::check("append with empty right returns left", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        HPointer buf = BytesOps::fromVector(data);
        HPointer empty = BytesOps::empty();

        auto& alloc = Allocator::instance();
        HPointer result = BytesOps::append(alloc.resolve(buf), alloc.resolve(empty));

        RC_ASSERT(BytesOps::toVector(alloc.resolve(result)) == data);
    });
}

// ============================================================================
// Equal Tests
// ============================================================================

static void test_equal_reflexive() {
    rc::check("equal is reflexive", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        HPointer buf = BytesOps::fromVector(data);
        void* obj = Allocator::instance().resolve(buf);

        RC_ASSERT(BytesOps::equal(obj, obj) == true);
    });
}

static void test_equal_symmetric() {
    rc::check("equal is symmetric", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        HPointer buf1 = BytesOps::fromVector(data);
        HPointer buf2 = BytesOps::fromVector(data);

        auto& alloc = Allocator::instance();
        bool eq1 = BytesOps::equal(alloc.resolve(buf1), alloc.resolve(buf2));
        bool eq2 = BytesOps::equal(alloc.resolve(buf2), alloc.resolve(buf1));

        RC_ASSERT(eq1 == eq2);
    });
}

static void test_equal_detects_different() {
    rc::check("equal detects different buffers", []() {
        initAllocator();

        std::vector<u8> a = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );
        if (a.empty()) return;

        // Create a different buffer
        std::vector<u8> b = a;
        b[0] = ~b[0];  // Flip bits in first byte

        HPointer bufA = BytesOps::fromVector(a);
        HPointer bufB = BytesOps::fromVector(b);

        auto& alloc = Allocator::instance();
        RC_ASSERT(BytesOps::equal(alloc.resolve(bufA), alloc.resolve(bufB)) == false);
    });
}

// ============================================================================
// Hash Tests
// ============================================================================

static void test_hash_consistent() {
    rc::check("hash is consistent for same data", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        HPointer buf1 = BytesOps::fromVector(data);
        HPointer buf2 = BytesOps::fromVector(data);

        auto& alloc = Allocator::instance();
        u32 h1 = BytesOps::hash(alloc.resolve(buf1));
        u32 h2 = BytesOps::hash(alloc.resolve(buf2));

        RC_ASSERT(h1 == h2);
    });
}

// ============================================================================
// Base64 Tests
// ============================================================================

static void test_base64_roundtrip() {
    rc::check("toBase64/fromBase64 roundtrips", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        // Skip empty - empty ByteBuffer returns empty string constant
        if (data.empty()) return;

        HPointer buf = BytesOps::fromVector(data);
        auto& alloc = Allocator::instance();

        HPointer b64 = BytesOps::toBase64(alloc.resolve(buf));
        HPointer decoded = BytesOps::fromBase64(alloc.resolve(b64));

        // fromBase64 returns Just(bytes)
        void* decodedObj = alloc.resolve(decoded);
        Custom* custom = static_cast<Custom*>(decodedObj);
        RC_ASSERT(custom->ctor == 0);  // Just

        void* innerBuf = alloc.resolve(custom->values[0].p);
        RC_ASSERT(BytesOps::toVector(innerBuf) == data);
    });
}

static void test_base64_empty() {
    rc::check("toBase64 of empty is empty string", []() {
        initAllocator();

        HPointer buf = BytesOps::empty();
        auto& alloc = Allocator::instance();

        HPointer b64 = BytesOps::toBase64(alloc.resolve(buf));

        // Should be empty string constant
        RC_ASSERT(alloc::isConstant(b64));
        RC_ASSERT(b64.constant == Const_EmptyString + 1);
    });
}

static void test_base64_invalid_returns_nothing() {
    rc::check("fromBase64 with invalid input returns Nothing", []() {
        initAllocator();

        // Invalid base64: wrong length
        std::u16string invalid = u"abc";  // Not multiple of 4
        HPointer str = alloc::allocString(invalid);

        auto& alloc = Allocator::instance();
        HPointer result = BytesOps::fromBase64(alloc.resolve(str));

        // Should be Nothing
        RC_ASSERT(alloc::isConstant(result));
        RC_ASSERT(result.constant == Const_Nothing + 1);
    });
}

// ============================================================================
// Hex Tests
// ============================================================================

static void test_hex_roundtrip() {
    rc::check("toHex/fromHex roundtrips", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        // Skip empty - returns empty string constant
        if (data.empty()) return;

        HPointer buf = BytesOps::fromVector(data);
        auto& alloc = Allocator::instance();

        HPointer hex = BytesOps::toHex(alloc.resolve(buf));
        HPointer decoded = BytesOps::fromHex(alloc.resolve(hex));

        // fromHex returns Just(bytes)
        void* decodedObj = alloc.resolve(decoded);
        Custom* custom = static_cast<Custom*>(decodedObj);
        RC_ASSERT(custom->ctor == 0);  // Just

        void* innerBuf = alloc.resolve(custom->values[0].p);
        RC_ASSERT(BytesOps::toVector(innerBuf) == data);
    });
}

static void test_hex_empty() {
    rc::check("toHex of empty is empty string", []() {
        initAllocator();

        HPointer buf = BytesOps::empty();
        auto& alloc = Allocator::instance();

        HPointer hex = BytesOps::toHex(alloc.resolve(buf));

        // Should be empty string constant
        RC_ASSERT(alloc::isConstant(hex));
        RC_ASSERT(hex.constant == Const_EmptyString + 1);
    });
}

static void test_hex_length_is_double() {
    rc::check("toHex length is double input length", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        // Skip empty - returns empty string constant
        if (data.empty()) return;

        HPointer buf = BytesOps::fromVector(data);
        auto& alloc = Allocator::instance();

        HPointer hex = BytesOps::toHex(alloc.resolve(buf));
        ElmString* str = static_cast<ElmString*>(alloc.resolve(hex));

        RC_ASSERT(str->header.size == data.size() * 2);
    });
}

static void test_hex_invalid_returns_nothing() {
    rc::check("fromHex with invalid input returns Nothing", []() {
        initAllocator();

        // Invalid hex: contains 'g'
        std::u16string invalid = u"abcg";
        HPointer str = alloc::allocString(invalid);

        auto& alloc = Allocator::instance();
        HPointer result = BytesOps::fromHex(alloc.resolve(str));

        // Should be Nothing
        RC_ASSERT(alloc::isConstant(result));
        RC_ASSERT(result.constant == Const_Nothing + 1);
    });
}

static void test_hex_odd_length_returns_nothing() {
    rc::check("fromHex with odd length returns Nothing", []() {
        initAllocator();

        std::u16string invalid = u"abc";  // Odd length
        HPointer str = alloc::allocString(invalid);

        auto& alloc = Allocator::instance();
        HPointer result = BytesOps::fromHex(alloc.resolve(str));

        RC_ASSERT(alloc::isConstant(result));
        RC_ASSERT(result.constant == Const_Nothing + 1);
    });
}

// ============================================================================
// toList/fromList Tests
// ============================================================================

static void test_toList_fromList_roundtrip() {
    rc::check("toList/fromList roundtrips", []() {
        initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        HPointer buf = BytesOps::fromVector(data);
        auto& alloc = Allocator::instance();

        HPointer list = BytesOps::toList(alloc.resolve(buf));
        HPointer buf2 = BytesOps::fromList(list);

        RC_ASSERT(BytesOps::toVector(alloc.resolve(buf2)) == data);
    });
}

static void test_toList_empty() {
    rc::check("toList of empty is empty list", []() {
        initAllocator();

        HPointer buf = BytesOps::empty();
        auto& alloc = Allocator::instance();

        HPointer list = BytesOps::toList(alloc.resolve(buf));

        RC_ASSERT(alloc::isNil(list));
    });
}

// ============================================================================
// UTF-8 Encoding/Decoding Tests
// ============================================================================

static void test_utf8_roundtrip_ascii() {
    rc::check("encodeUtf8/decodeUtf8 roundtrips ASCII", []() {
        initAllocator();

        // Generate ASCII string
        std::string ascii = *rc::gen::container<std::string>(
            rc::gen::inRange<char>(32, 127)
        );

        // Skip empty strings
        if (ascii.empty()) return;

        std::u16string u16(ascii.begin(), ascii.end());
        HPointer str = alloc::allocString(u16);
        auto& alloc = Allocator::instance();

        HPointer utf8 = BytesOps::encodeUtf8(alloc.resolve(str));
        HPointer decoded = BytesOps::decodeUtf8(alloc.resolve(utf8));

        // decodeUtf8 returns Just(string)
        void* decodedObj = alloc.resolve(decoded);
        Custom* custom = static_cast<Custom*>(decodedObj);
        RC_ASSERT(custom->ctor == 0);  // Just

        ElmString* result = static_cast<ElmString*>(alloc.resolve(custom->values[0].p));
        std::u16string resultStr(reinterpret_cast<const char16_t*>(result->chars), result->header.size);

        RC_ASSERT(resultStr == u16);
    });
}

// ============================================================================
// GC Survival Tests
// ============================================================================

static void test_bytebuffer_survives_gc() {
    rc::check("ByteBuffer survives GC", []() {
        auto& alloc = initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        HPointer buf = BytesOps::fromVector(data);

        alloc.getRootSet().addRoot(&buf);

        alloc.minorGC();

        RC_ASSERT(BytesOps::toVector(alloc.resolve(buf)) == data);

        alloc.getRootSet().removeRoot(&buf);
    });
}

static void test_appended_buffer_survives_gc() {
    rc::check("appended ByteBuffer survives GC", []() {
        auto& alloc = initAllocator();

        std::vector<u8> a = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );
        std::vector<u8> b = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        HPointer bufA = BytesOps::fromVector(a);
        HPointer bufB = BytesOps::fromVector(b);

        HPointer combined = BytesOps::append(alloc.resolve(bufA), alloc.resolve(bufB));

        alloc.getRootSet().addRoot(&combined);

        alloc.minorGC();

        std::vector<u8> expected = a;
        expected.insert(expected.end(), b.begin(), b.end());

        RC_ASSERT(BytesOps::toVector(alloc.resolve(combined)) == expected);

        alloc.getRootSet().removeRoot(&combined);
    });
}

static void test_encoded_buffer_survives_gc() {
    rc::check("encoded ByteBuffer survives GC", []() {
        auto& alloc = initAllocator();

        std::vector<u8> data = *rc::gen::container<std::vector<u8>>(
            rc::gen::arbitrary<u8>()
        );

        // Skip empty - toHex returns empty string constant
        if (data.empty()) return;

        HPointer buf = BytesOps::fromVector(data);

        HPointer hex = BytesOps::toHex(alloc.resolve(buf));

        alloc.getRootSet().addRoot(&hex);

        alloc.minorGC();

        // Verify hex string is still valid
        HPointer decoded = BytesOps::fromHex(alloc.resolve(hex));
        void* decodedObj = alloc.resolve(decoded);
        Custom* custom = static_cast<Custom*>(decodedObj);
        RC_ASSERT(custom->ctor == 0);

        void* innerBuf = alloc.resolve(custom->values[0].p);
        RC_ASSERT(BytesOps::toVector(innerBuf) == data);

        alloc.getRootSet().removeRoot(&hex);
    });
}

// ============================================================================
// Test Registration
// ============================================================================

void registerBytesOpsTests(Testing::TestSuite& suite) {
    // Empty tests
    suite.add(Testing::TestCase("BytesOps::empty has zero length", test_empty_has_zero_length));

    // fromData/toVector tests
    suite.add(Testing::TestCase("BytesOps::fromData preserves bytes", test_fromData_preserves_bytes));
    suite.add(Testing::TestCase("BytesOps::fromVector preserves bytes", test_fromVector_preserves_bytes));

    // Length tests
    suite.add(Testing::TestCase("BytesOps::length matches input", test_length_matches_input));

    // getAt tests
    suite.add(Testing::TestCase("BytesOps::getAt returns correct byte", test_getAt_returns_correct_byte));
    suite.add(Testing::TestCase("BytesOps::getAt out of bounds", test_getAt_out_of_bounds_returns_minus_one));

    // Slice tests
    suite.add(Testing::TestCase("BytesOps::slice extracts subbuffer", test_slice_extracts_subbuffer));
    suite.add(Testing::TestCase("BytesOps::slice clamps to bounds", test_slice_clamps_to_bounds));

    // Integer encoding tests
    suite.add(Testing::TestCase("BytesOps: encode/decode unsigned 8-bit", test_encode_decode_unsigned_int_8));
    suite.add(Testing::TestCase("BytesOps: encode/decode unsigned 16-bit", test_encode_decode_unsigned_int_16));
    suite.add(Testing::TestCase("BytesOps: encode/decode unsigned 32-bit", test_encode_decode_unsigned_int_32));
    suite.add(Testing::TestCase("BytesOps: encode/decode signed 8-bit", test_encode_decode_signed_int_8));
    suite.add(Testing::TestCase("BytesOps: encode/decode signed 16-bit", test_encode_decode_signed_int_16));

    // Float encoding tests
    suite.add(Testing::TestCase("BytesOps: encode/decode float32", test_encode_decode_float32));
    suite.add(Testing::TestCase("BytesOps: encode/decode float64", test_encode_decode_float64));

    // Append tests
    suite.add(Testing::TestCase("BytesOps::append concatenates", test_append_concatenates));
    suite.add(Testing::TestCase("BytesOps::append with empty left", test_append_empty_left));
    suite.add(Testing::TestCase("BytesOps::append with empty right", test_append_empty_right));

    // Equal tests
    suite.add(Testing::TestCase("BytesOps::equal is reflexive", test_equal_reflexive));
    suite.add(Testing::TestCase("BytesOps::equal is symmetric", test_equal_symmetric));
    suite.add(Testing::TestCase("BytesOps::equal detects different", test_equal_detects_different));

    // Hash tests
    suite.add(Testing::TestCase("BytesOps::hash is consistent", test_hash_consistent));

    // Base64 tests
    suite.add(Testing::TestCase("BytesOps: Base64 roundtrip", test_base64_roundtrip));
    suite.add(Testing::TestCase("BytesOps: Base64 empty", test_base64_empty));
    suite.add(Testing::TestCase("BytesOps: Base64 invalid returns Nothing", test_base64_invalid_returns_nothing));

    // Hex tests
    suite.add(Testing::TestCase("BytesOps: hex roundtrip", test_hex_roundtrip));
    suite.add(Testing::TestCase("BytesOps: hex empty", test_hex_empty));
    suite.add(Testing::TestCase("BytesOps: hex length is double", test_hex_length_is_double));
    suite.add(Testing::TestCase("BytesOps: hex invalid returns Nothing", test_hex_invalid_returns_nothing));
    suite.add(Testing::TestCase("BytesOps: hex odd length returns Nothing", test_hex_odd_length_returns_nothing));

    // toList/fromList tests
    suite.add(Testing::TestCase("BytesOps: toList/fromList roundtrip", test_toList_fromList_roundtrip));
    suite.add(Testing::TestCase("BytesOps: toList empty", test_toList_empty));

    // UTF-8 tests
    suite.add(Testing::TestCase("BytesOps: UTF-8 roundtrip ASCII", test_utf8_roundtrip_ascii));

    // GC tests
    suite.add(Testing::TestCase("BytesOps: ByteBuffer survives GC", test_bytebuffer_survives_gc));
    suite.add(Testing::TestCase("BytesOps: appended buffer survives GC", test_appended_buffer_survives_gc));
    suite.add(Testing::TestCase("BytesOps: encoded buffer survives GC", test_encoded_buffer_survives_gc));
}
