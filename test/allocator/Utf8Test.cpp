/**
 * Tests for Utf8.hpp — validation, unit counting, ASCII detection, widening.
 *
 * The scan must agree with elm_utf8_decode (ElmBytesRuntime.cpp): a byte range
 * scan accepts as valid+ascii is exactly the set the UTF-8 String forms may
 * hold, and the reported unit count must match the UTF-16 length the legacy
 * decoders would produce.
 */

#include "Utf8Test.hpp"
#include "../../runtime/src/allocator/Utf8.hpp"
#include "TestHelpers.hpp"
#include <rapidcheck.h>
#include <vector>
#include <cstdint>

using namespace Elm;

// ---------------------------------------------------------------------------
// Reference helpers (independent of the code under test)
// ---------------------------------------------------------------------------

// Encodes a single code point to UTF-8, appending to `out`. Assumes a valid
// scalar value (not a surrogate, <= 0x10FFFF).
static void encodeCp(uint32_t cp, std::vector<u8>& out) {
    if (cp < 0x80) {
        out.push_back(static_cast<u8>(cp));
    } else if (cp < 0x800) {
        out.push_back(static_cast<u8>(0xC0 | (cp >> 6)));
        out.push_back(static_cast<u8>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back(static_cast<u8>(0xE0 | (cp >> 12)));
        out.push_back(static_cast<u8>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<u8>(0x80 | (cp & 0x3F)));
    } else {
        out.push_back(static_cast<u8>(0xF0 | (cp >> 18)));
        out.push_back(static_cast<u8>(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back(static_cast<u8>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<u8>(0x80 | (cp & 0x3F)));
    }
}

// UTF-16 code units contributed by a scalar value.
static uint32_t unitsFor(uint32_t cp) { return cp >= 0x10000 ? 2u : 1u; }

static Utf8::ScanResult scanVec(const std::vector<u8>& v) {
    return Utf8::scan(v.data(), v.size());
}

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

// A sequence of valid scalar values, encoded, scans as valid with the exact
// UTF-16 unit count, and reports ascii iff every scalar is < 0x80.
static void test_valid_sequences_scan_valid() {
    rc::check("encoded scalar sequences scan valid with correct unit count", []() {
        auto cps = *rc::gen::container<std::vector<uint32_t>>(
            rc::gen::suchThat(
                rc::gen::inRange<uint32_t>(0, 0x110000),
                [](uint32_t cp) {
                    return cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF);
                }));

        std::vector<u8> bytes;
        uint32_t expectedUnits = 0;
        bool expectedAscii = true;
        for (uint32_t cp : cps) {
            encodeCp(cp, bytes);
            expectedUnits += unitsFor(cp);
            if (cp >= 0x80) expectedAscii = false;
        }

        Utf8::ScanResult r = scanVec(bytes);
        RC_ASSERT(r.valid);
        RC_ASSERT(r.utf16Units == expectedUnits);
        RC_ASSERT(r.ascii == expectedAscii);
        // ascii <=> unit count equals byte count.
        RC_ASSERT(r.ascii == (r.utf16Units == bytes.size()));
    });
}

// allAscii agrees with "every byte < 0x80" for arbitrary byte vectors, and for
// all-ASCII input scan is valid+ascii with units==len.
static void test_all_ascii_predicate() {
    rc::check("allAscii <=> every byte < 0x80", []() {
        auto bytes = *rc::gen::container<std::vector<u8>>(rc::gen::arbitrary<u8>());
        bool ref = true;
        for (u8 b : bytes) if (b & 0x80) { ref = false; break; }
        RC_ASSERT(Utf8::allAscii(bytes.data(), bytes.size()) == ref);

        if (ref) {
            Utf8::ScanResult r = scanVec(bytes);
            RC_ASSERT(r.valid);
            RC_ASSERT(r.ascii);
            RC_ASSERT(r.utf16Units == bytes.size());
        }
    });
}

// widenAscii zero-extends bytes to units.
static void test_widen_ascii() {
    rc::check("widenAscii zero-extends", []() {
        auto bytes = *rc::gen::container<std::vector<u8>>(
            rc::gen::inRange<u8>(0, 128));
        std::vector<u16> out(bytes.size());
        Utf8::widenAscii(bytes.data(), bytes.size(), out.data());
        for (size_t i = 0; i < bytes.size(); ++i) {
            RC_ASSERT(out[i] == static_cast<u16>(bytes[i]));
        }
    });
}

// ---------------------------------------------------------------------------
// Fixed vectors — invalid and boundary cases
// ---------------------------------------------------------------------------

static void test_empty_scans_valid_ascii() {
    Utf8::ScanResult r = Utf8::scan(nullptr, 0);
    TEST_ASSERT(r.valid);
    TEST_ASSERT(r.ascii);
    TEST_ASSERT(r.utf16Units == 0);
}

static void expectInvalid(std::initializer_list<u8> bytes) {
    std::vector<u8> v(bytes);
    Utf8::ScanResult r = scanVec(v);
    TEST_ASSERT(!r.valid);
    TEST_ASSERT(!r.ascii);
}

static void expectValidUnits(std::initializer_list<u8> bytes, uint32_t units,
                             bool ascii) {
    std::vector<u8> v(bytes);
    Utf8::ScanResult r = scanVec(v);
    TEST_ASSERT(r.valid);
    TEST_ASSERT(r.utf16Units == units);
    TEST_ASSERT(r.ascii == ascii);
}

static void test_invalid_vectors() {
    expectInvalid({0x80});                   // bare continuation byte
    expectInvalid({0xC2});                   // truncated 2-byte
    expectInvalid({0xE2, 0x82});             // truncated 3-byte
    expectInvalid({0xF0, 0x9F, 0x98});       // truncated 4-byte
    expectInvalid({0xC0, 0x80});             // overlong 2-byte (NUL)
    expectInvalid({0xE0, 0x80, 0x80});       // overlong 3-byte
    expectInvalid({0xF0, 0x80, 0x80, 0x80}); // overlong 4-byte
    expectInvalid({0xED, 0xA0, 0x80});       // encoded surrogate U+D800
    expectInvalid({0xF4, 0x90, 0x80, 0x80}); // > U+10FFFF
    expectInvalid({0xF8, 0x88, 0x80, 0x80, 0x80}); // 5-byte lead (illegal)
    expectInvalid({0xC2, 0x00});             // bad continuation
}

static void test_boundary_code_points() {
    // U+007F  — last ASCII
    expectValidUnits({0x7F}, 1, true);
    // U+0080  — first 2-byte
    expectValidUnits({0xC2, 0x80}, 1, false);
    // U+07FF  — last 2-byte
    expectValidUnits({0xDF, 0xBF}, 1, false);
    // U+0800  — first 3-byte
    expectValidUnits({0xE0, 0xA0, 0x80}, 1, false);
    // U+FFFF  — last BMP
    expectValidUnits({0xEF, 0xBF, 0xBF}, 1, false);
    // U+10000 — first astral (2 UTF-16 units)
    expectValidUnits({0xF0, 0x90, 0x80, 0x80}, 2, false);
    // U+10FFFF — last scalar (2 UTF-16 units)
    expectValidUnits({0xF4, 0x8F, 0xBF, 0xBF}, 2, false);
    // Mixed ASCII + astral: "A" + U+1F600 + "B" => 1 + 2 + 1 = 4 units.
    expectValidUnits({'A', 0xF0, 0x9F, 0x98, 0x80, 'B'}, 4, false);
}

void registerUtf8Tests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase("Utf8::scan valid sequences count units",
                                test_valid_sequences_scan_valid));
    suite.add(Testing::TestCase("Utf8::allAscii matches per-byte predicate",
                                test_all_ascii_predicate));
    suite.add(Testing::TestCase("Utf8::widenAscii zero-extends", test_widen_ascii));
    suite.add(Testing::TestCase("Utf8::scan empty is valid ascii",
                                test_empty_scans_valid_ascii));
    suite.add(Testing::TestCase("Utf8::scan rejects invalid sequences",
                                test_invalid_vectors));
    suite.add(Testing::TestCase("Utf8::scan boundary code points",
                                test_boundary_code_points));
}
