/**
 * Tests for CaseMap.hpp / CaseMapTables.hpp / CharValue.hpp: the generated case-mapping tables
 * and the Char value encoding (KERN_008, plans/char-case-mapping-elm-exact.md Step 1).
 *
 * The structure checks run in every build. The checks that need encoded values sit under
 * `if constexpr (CharValue::kExpansions)`, so a build with ECO_CHAR_CASE_EXPANSION=OFF compiles
 * this file and skips them.
 */

#include "CaseMapTest.hpp"
#include "../../runtime/src/allocator/CaseMap.hpp"
#include "TestHelpers.hpp"

#include <string>
#include <vector>

using namespace Elm;

namespace {

// The UTF-16 units of a Char value's String.
std::vector<uint16_t> unitsOf(uint32_t v) {
    uint16_t buf[CharValue::kMaxCharUnits];
    uint32_t n = CaseMap::writeUnits(v, buf);
    TEST_ASSERT(n == CaseMap::units(v));
    return std::vector<uint16_t>(buf, buf + n);
}

bool validValue(uint32_t v) {
    if ((v & CharValue::kReservedMask) != 0) return false;
    if (!CharValue::hasRankBits(v)) return v <= 0x10FFFF;
    uint32_t r = CharValue::rank(v);
    // Raw bits, not firstCodePoint (the identity when ECO_CHAR_CASE_EXPANSION is off): the tables
    // are the same in both builds.
    return r < CaseMap::kEntryCount && CaseMap::kEntries[r].units[0] == (v & CharValue::kFirstMask);
}

bool lessUnits(const CaseMap::Entry& a, const CaseMap::Entry& b) {
    for (uint32_t i = 0; i < a.len && i < b.len; i++) {
        if (a.units[i] != b.units[i]) return a.units[i] < b.units[i];
    }
    return a.len < b.len;
}

void test_constants() {
    TEST_ASSERT(CharValue::kRankMask == 0x1FE00000u);
    TEST_ASSERT(CharValue::kReservedMask == 0xE0000000u);
    TEST_ASSERT(CaseMap::kEntryCount <= 255);
    TEST_ASSERT(CaseMap::kMaxExpansionUnits == 3);
}

void test_pair_tables_sorted() {
    for (const auto& [table, count] : {std::pair{CaseMap::kUpper, CaseMap::kUpperCount},
                                       std::pair{CaseMap::kLower, CaseMap::kLowerCount}}) {
        for (uint32_t i = 0; i < count; i++) {
            TEST_ASSERT(table[i].from >= 0x80);
            TEST_ASSERT(!(table[i].from >= 0xD800 && table[i].from <= 0xDFFF));
            TEST_ASSERT(table[i].from != table[i].to);
            TEST_ASSERT(validValue(table[i].to));
            if (i > 0) TEST_ASSERT(table[i - 1].from < table[i].from);
        }
    }
}

void test_entries_sorted_and_valid() {
    for (uint32_t i = 0; i < CaseMap::kEntryCount; i++) {
        const auto& e = CaseMap::kEntries[i];
        TEST_ASSERT(e.len == 2 || e.len == 3);
        for (uint32_t k = 0; k < e.len; k++) TEST_ASSERT(e.units[k] < 0xD800);
        TEST_ASSERT(validValue(e.upper));
        TEST_ASSERT(validValue(e.lower));
        if (i > 0) TEST_ASSERT(lessUnits(CaseMap::kEntries[i - 1], e));
    }
}

void test_ranges_sorted_disjoint() {
    for (const auto& [table, count] : {std::pair{CaseMap::kCased, CaseMap::kCasedCount},
                                       std::pair{CaseMap::kCaseIgnorable, CaseMap::kCaseIgnorableCount}}) {
        for (uint32_t i = 0; i < count; i++) {
            TEST_ASSERT(table[i].lo <= table[i].hi);
            if (i > 0) TEST_ASSERT(table[i - 1].hi + 1 < table[i].lo);
        }
    }
    TEST_ASSERT(CaseMap::isCased('A') && CaseMap::isCased(0x3B1) && !CaseMap::isCased('1'));
    TEST_ASSERT(CaseMap::isCaseIgnorable('\'') && CaseMap::isCaseIgnorable(0x301));
    TEST_ASSERT(CaseMap::isCased(0x2B0) && CaseMap::isCaseIgnorable(0x2B0));
}

void test_single_mappings() {
    TEST_ASSERT(CaseMap::upper('a') == 'A' && CaseMap::lower('A') == 'a');
    TEST_ASSERT(CaseMap::upper('1') == '1');
    TEST_ASSERT(CaseMap::upper(0xE9) == 0xC9 && CaseMap::lower(0xC9) == 0xE9);
    TEST_ASSERT(CaseMap::upper(0x10428) == 0x10400 && CaseMap::lower(0x10400) == 0x10428);
    TEST_ASSERT(CaseMap::upper(0xB5) == 0x39C);
    TEST_ASSERT(CaseMap::lower(0x3A3) == 0x3C3);
    TEST_ASSERT(CaseMap::upper(0x1C5) == 0x1C4 && CaseMap::lower(0x1C5) == 0x1C6);
    TEST_ASSERT(CaseMap::upper(0xD800) == 0xD800 && CaseMap::upper(0x4E2D) == 0x4E2D);
    TEST_ASSERT(unitsOf(0x1F600) == (std::vector<uint16_t>{0xD83D, 0xDE00}));
    TEST_ASSERT(unitsOf(0x150000) == std::vector<uint16_t>{0xFFFD});
}

void test_expansions() {
    if constexpr (CharValue::kExpansions) {
        uint32_t ss = CaseMap::upper(0xDF);
        TEST_ASSERT(CharValue::isEncoded(ss) && CharValue::firstCodePoint(ss) == 0x53);
        TEST_ASSERT(unitsOf(ss) == (std::vector<uint16_t>{0x53, 0x53}));
        TEST_ASSERT(unitsOf(CaseMap::lower(ss)) == (std::vector<uint16_t>{0x73, 0x73}));
        TEST_ASSERT(CaseMap::upper(0x1FB3) == CaseMap::upper(0x1FBC));
        uint32_t idot = CaseMap::lower(0x130);
        TEST_ASSERT(unitsOf(idot) == (std::vector<uint16_t>{0x69, 0x307}));
        TEST_ASSERT(unitsOf(CaseMap::upper(idot)) == (std::vector<uint16_t>{0x49, 0x307}));
        TEST_ASSERT(unitsOf(CaseMap::upper(0x390)) == (std::vector<uint16_t>{0x399, 0x308, 0x301}));
        // The closure is total and its mappings are fixed points.
        for (uint32_t i = 0; i < CaseMap::kEntryCount; i++) {
            const auto& e = CaseMap::kEntries[i];
            if (CharValue::isEncoded(e.upper)) TEST_ASSERT(CaseMap::upper(e.upper) == e.upper);
            if (CharValue::isEncoded(e.lower)) TEST_ASSERT(CaseMap::lower(e.lower) == e.lower);
        }
    } else {
        TEST_ASSERT(CaseMap::upper(0xDF) == 0xDF && CaseMap::lower(0x130) == 0x130);
    }
}

void test_sort_key() {
    if constexpr (CharValue::kExpansions) {
        const uint32_t R = 0x52, S = 0x53, e0 = 0x53 | (1u << 21), e1 = 0x53 | (2u << 21), T = 0x54;
        const uint32_t order[] = {R, S, e0, e1, T, 0xE000, 0x1F600};
        for (size_t i = 0; i + 1 < sizeof order / sizeof order[0]; i++) {
            TEST_ASSERT(CharValue::compare(order[i], order[i + 1]) < 0);
            TEST_ASSERT(CharValue::compare(order[i + 1], order[i]) > 0);
        }
        TEST_ASSERT(CharValue::compare(0x10FFFF, e1) > 0);
        TEST_ASSERT(CharValue::compare(e0, e0) == 0);
        for (uint32_t i = 1; i < CaseMap::kEntryCount; i++) {
            uint32_t a = CaseMap::kEntries[i - 1].units[0] | (i << 21);
            uint32_t b = CaseMap::kEntries[i].units[0] | ((i + 1) << 21);
            TEST_ASSERT(CharValue::sortKey(a) < CharValue::sortKey(b));
        }
    }
}

bool sigmaAt(const std::u16string& s) {
    size_t at = s.find(u'Σ');
    return CaseMap::finalSigmaAt(reinterpret_cast<const uint16_t*>(s.data()), s.size(), at, at + 1);
}

void test_final_sigma() {
    TEST_ASSERT(sigmaAt(u"ΑΣ"));
    TEST_ASSERT(!sigmaAt(u"Σ"));
    TEST_ASSERT(!sigmaAt(u"ΑΣΑ"));
    TEST_ASSERT(!sigmaAt(u"ΑΣ.Α"));
    TEST_ASSERT(!sigmaAt(u"ʰΣ"));
    TEST_ASSERT(sigmaAt(u"ΑΣʰ"));
    TEST_ASSERT(sigmaAt(u"Α.Σ"));
    TEST_ASSERT(sigmaAt(u"\U00010400Σ"));   // astral Cased letter before it
}

}  // namespace

void registerCaseMapTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase("CaseMap constants", test_constants));
    suite.add(Testing::TestCase("CaseMap kUpper/kLower sorted and valid", test_pair_tables_sorted));
    suite.add(Testing::TestCase("CaseMap kEntries sorted and valid", test_entries_sorted_and_valid));
    suite.add(Testing::TestCase("CaseMap ranges sorted and disjoint", test_ranges_sorted_disjoint));
    suite.add(Testing::TestCase("CaseMap single-code-point mappings", test_single_mappings));
    suite.add(Testing::TestCase("CaseMap expansions and closure", test_expansions));
    suite.add(Testing::TestCase("CharValue sort key order", test_sort_key));
    suite.add(Testing::TestCase("CaseMap Final_Sigma", test_final_sigma));
}
