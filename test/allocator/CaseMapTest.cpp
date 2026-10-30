/**
 * Tests for CaseMap.hpp / CaseMapTables.hpp: the generated Unicode simple case-mapping tables
 * (KERN_008, plans/char-simple-case-mapping.md). A Char is one code point, and case mapping takes
 * one code point to one code point.
 */

#include "CaseMapTest.hpp"
#include "../../runtime/src/allocator/CaseMap.hpp"
#include "TestHelpers.hpp"

#include <iterator>
#include <string>
#include <vector>

using namespace Elm;

namespace {

// The UTF-16 units `writeUnits` writes for `cp`, checked against `units`.
std::vector<uint16_t> unitsOf(uint32_t cp) {
    uint16_t buf[2];
    uint32_t n = CaseMap::writeUnits(cp, buf);
    TEST_ASSERT(n == CaseMap::units(cp));
    return std::vector<uint16_t>(buf, buf + n);
}

bool isSurrogate(uint32_t c) { return c >= 0xD800 && c <= 0xDFFF; }

void test_tables_sorted_and_valid() {
    TEST_ASSERT(std::size(CaseMap::kUpper) == 1505);
    TEST_ASSERT(std::size(CaseMap::kLower) == 1488);
    for (const auto& [table, count] : {std::pair{CaseMap::kUpper, std::size(CaseMap::kUpper)},
                                       std::pair{CaseMap::kLower, std::size(CaseMap::kLower)}}) {
        for (size_t i = 0; i < count; i++) {
            const auto& p = table[i];
            TEST_ASSERT(p.from != p.to);
            TEST_ASSERT(!isSurrogate(p.from) && !isSurrogate(p.to));
            TEST_ASSERT(p.from <= 0x10FFFF && p.to <= 0x10FFFF);
            TEST_ASSERT((p.from > 0xFFFF) == (p.to > 0xFFFF));
            if (i > 0) TEST_ASSERT(table[i - 1].from < p.from);
        }
    }
}

void test_spot_values() {
    TEST_ASSERT(CaseMap::upper('a') == 'A' && CaseMap::lower('A') == 'a' && CaseMap::upper('1') == '1');
    TEST_ASSERT(CaseMap::upper(0xDF) == 0xDF);
    TEST_ASSERT(CaseMap::upper(0x1F80) == 0x1F88);
    TEST_ASSERT(CaseMap::upper(0x1FB3) == 0x1FBC);
    TEST_ASSERT(CaseMap::lower(0x130) == 0x69);
    TEST_ASSERT(CaseMap::upper(0x10428) == 0x10400 && CaseMap::lower(0x10400) == 0x10428);
    TEST_ASSERT(CaseMap::upper(0xE9) == 0xC9 && CaseMap::lower(0xC9) == 0xE9);
    TEST_ASSERT(CaseMap::lower(0x3A3) == 0x3C3);
    TEST_ASSERT(CaseMap::upper(0x17F) == 0x53);
    TEST_ASSERT(CaseMap::lower(0x212A) == 0x6B);
    TEST_ASSERT(CaseMap::upper(0x1C5) == 0x1C4 && CaseMap::lower(0x1C5) == 0x1C6);
    TEST_ASSERT(CaseMap::upper(0xD800) == 0xD800 && CaseMap::upper(0x4E2D) == 0x4E2D);
    TEST_ASSERT(CaseMap::upper(0x110000) == 0x110000 && CaseMap::lower(0x110000) == 0x110000);
}

void test_write_units() {
    TEST_ASSERT(unitsOf('a') == std::vector<uint16_t>{'a'});
    TEST_ASSERT(unitsOf(0xD800) == std::vector<uint16_t>{0xD800});
    TEST_ASSERT(unitsOf(0x10400) == (std::vector<uint16_t>{0xD801, 0xDC00}));
    TEST_ASSERT(unitsOf(0x1F600) == (std::vector<uint16_t>{0xD83D, 0xDE00}));
    TEST_ASSERT(unitsOf(0x10FFFF) == (std::vector<uint16_t>{0xDBFF, 0xDFFF}));
    TEST_ASSERT(unitsOf(0x110000) == std::vector<uint16_t>{0xFFFD});
    TEST_ASSERT(CaseMap::units(0x110000) == 1);
}

}  // namespace

void registerCaseMapTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase("CaseMap kUpper/kLower sorted and valid", test_tables_sorted_and_valid));
    suite.add(Testing::TestCase("CaseMap spot values", test_spot_values));
    suite.add(Testing::TestCase("CaseMap writeUnits", test_write_units));
}
