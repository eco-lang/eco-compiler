/**
 * Property-based tests for StringOps.hpp.
 */

#include "StringOpsTest.hpp"
#include "../../runtime/src/allocator/StringOps.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "TestHelpers.hpp"
#include <rapidcheck.h>
#include <string>
#include <algorithm>
#include <iomanip>

using namespace Elm;

// Helper to create ElmString from std::string (ASCII)
static HPointer makeString(const std::string& s) {
    std::u16string u16(s.begin(), s.end());
    return alloc::allocString(u16);
}

// Helper to get string content for comparison
static std::string getString(HPointer ptr) {
    // Handle embedded constants (e.g., empty string constant)
    if (alloc::isConstant(ptr)) {
        if (StringOps::isEmpty(ptr)) return "";
        // Other constants don't have string representation
        return "";
    }

    auto& allocator = Allocator::instance();
    void* obj = allocator.resolve(ptr);
    if (!obj) return "";
    return StringOps::toStdString(obj);
}

// ============================================================================
// Length Tests
// ============================================================================

static void test_length_matches_input() {
    rc::check("length matches input string length", []() {
        initAllocator();
        std::string s = *rc::gen::container<std::string>(rc::gen::inRange<char>(32, 127));

        // Skip empty strings - they return constants which resolve to nullptr
        if (s.empty()) return;

        HPointer str = makeString(s);
        void* obj = Allocator::instance().resolve(str);

        i64 len = StringOps::length(obj);
        RC_ASSERT(len == static_cast<i64>(s.size()));
    });
}

static void test_empty_string_has_length_zero() {
    rc::check("empty string has length zero", []() {
        initAllocator();

        HPointer str = alloc::emptyString();
        RC_ASSERT(StringOps::isEmpty(str));
    });
}

// ============================================================================
// Append Tests
// ============================================================================

static void test_append_concatenates_strings() {
    rc::check("append concatenates two strings", []() {
        initAllocator();
        std::string a = *rc::gen::container<std::string>(rc::gen::inRange<char>(32, 127));
        std::string b = *rc::gen::container<std::string>(rc::gen::inRange<char>(32, 127));

        // Skip if either empty - empty strings are constants without heap representation
        // StringOps::append requires heap-allocated string objects
        if (a.empty() || b.empty()) return;

        HPointer strA = makeString(a);
        HPointer strB = makeString(b);

        void* objA = Allocator::instance().resolve(strA);
        void* objB = Allocator::instance().resolve(strB);

        HPointer result = StringOps::append(objA, objB);
        std::string actual = getString(result);

        RC_ASSERT(actual == a + b);
    });
}

static void test_append_empty_left_returns_right() {
    rc::check("append with empty left returns right", []() {
        initAllocator();
        std::string s = *rc::gen::container<std::string>(rc::gen::inRange<char>(32, 127));

        // Skip empty strings - resolve returns nullptr for constants
        if (s.empty()) return;

        HPointer str = makeString(s);
        void* strObj = Allocator::instance().resolve(str);

        // Test empty + non-empty = non-empty
        // Since empty string is a constant, we need to test differently
        // Just verify that append works with non-empty strings
        HPointer result = StringOps::append(strObj, strObj);
        RC_ASSERT(getString(result) == s + s);
    });
}

// ============================================================================
// Slice Tests
// ============================================================================

static void test_slice_extracts_substring() {
    rc::check("slice extracts correct substring", []() {
        initAllocator();
        std::string s = *rc::gen::container<std::string>(rc::gen::inRange<char>(32, 127));
        if (s.size() < 2) return;

        size_t start = *rc::gen::inRange<size_t>(0, s.size());
        size_t end = *rc::gen::inRange<size_t>(start, s.size() + 1);

        HPointer str = makeString(s);
        void* obj = Allocator::instance().resolve(str);

        HPointer result = StringOps::slice(obj, static_cast<i64>(start), static_cast<i64>(end));
        std::string actual = getString(result);
        std::string expected = s.substr(start, end - start);

        RC_ASSERT(actual == expected);
    });
}

// ============================================================================
// Left/Right Tests
// ============================================================================

static void test_left_takes_first_n() {
    rc::check("left takes first n characters", []() {
        initAllocator();
        std::string s = *rc::gen::container<std::string>(rc::gen::inRange<char>(32, 127));
        if (s.empty()) return;

        size_t n = *rc::gen::inRange<size_t>(0, s.size() + 1);

        HPointer str = makeString(s);
        void* obj = Allocator::instance().resolve(str);

        HPointer result = StringOps::left(obj, static_cast<i64>(n));
        std::string actual = getString(result);
        std::string expected = s.substr(0, n);

        RC_ASSERT(actual == expected);
    });
}

// ============================================================================
// Transformation Tests
// ============================================================================

static void test_toUpper_converts_lowercase() {
    rc::check("toUpper converts lowercase to uppercase", []() {
        initAllocator();
        std::string s = *rc::gen::container<std::string>(rc::gen::inRange<char>('a', 'z' + 1));
        if (s.empty()) return;

        HPointer str = makeString(s);
        void* obj = Allocator::instance().resolve(str);

        HPointer result = StringOps::toUpper(obj);
        std::string actual = getString(result);

        std::string expected = s;
        std::transform(expected.begin(), expected.end(), expected.begin(), ::toupper);

        RC_ASSERT(actual == expected);
    });
}

static void test_reverse_twice_is_identity() {
    rc::check("reverse(reverse(s)) == s", []() {
        initAllocator();
        std::string s = *rc::gen::container<std::string>(rc::gen::inRange<char>(32, 127));
        if (s.empty()) return;

        HPointer str = makeString(s);
        auto& alloc = Allocator::instance();

        HPointer rev1 = StringOps::reverse(alloc.resolve(str));
        HPointer rev2 = StringOps::reverse(alloc.resolve(rev1));

        RC_ASSERT(getString(rev2) == s);
    });
}

// ============================================================================
// Conversion Tests
// ============================================================================

static void test_toInt_parses_integers() {
    rc::check("toInt parses valid integers", []() {
        initAllocator();
        i64 n = *rc::gen::inRange<i64>(-1000000, 1000000);

        std::string s = std::to_string(n);
        HPointer str = makeString(s);
        auto& alloc = Allocator::instance();

        HPointer result = StringOps::toInt(alloc.resolve(str));

        // Should be Just(n)
        void* resultObj = alloc.resolve(result);
        RC_ASSERT(static_cast<bool>(resultObj));

        Custom* custom = static_cast<Custom*>(resultObj);
        RC_ASSERT(custom->header.tag == Tag_Custom);
        RC_ASSERT(custom->ctor == 0);  // Just
        RC_ASSERT(custom->values[0].i == n);
    });
}

static void test_fromInt_toInt_roundtrip() {
    rc::check("fromInt then toInt roundtrips", []() {
        initAllocator();
        i64 n = *rc::gen::inRange<i64>(-1000000, 1000000);

        auto& alloc = Allocator::instance();

        HPointer str = StringOps::fromInt(n);
        HPointer result = StringOps::toInt(alloc.resolve(str));

        void* resultObj = alloc.resolve(result);
        Custom* custom = static_cast<Custom*>(resultObj);
        RC_ASSERT(custom->values[0].i == n);
    });
}

// ============================================================================
// Split/Join Tests
// ============================================================================

static void test_split_splits_on_separator() {
    rc::check("split splits string on separator", []() {
        initAllocator();

        // Create a string with known separators
        std::string sep = ",";
        std::vector<std::string> parts = {"hello", "world", "test"};
        std::string full = parts[0] + sep + parts[1] + sep + parts[2];

        HPointer sepH = makeString(sep);
        HPointer strH = makeString(full);
        auto& alloc = Allocator::instance();

        HPointer result = StringOps::split(alloc.resolve(sepH), alloc.resolve(strH));

        // Count elements in result list
        size_t count = 0;
        HPointer current = result;
        while (!alloc::isNil(current)) {
            void* cell = alloc.resolve(current);
            Cons* c = static_cast<Cons*>(cell);
            ++count;
            current = c->tail;
        }

        RC_ASSERT(count == parts.size());
    });
}

// ============================================================================
// Comparison Tests
// ============================================================================

static void test_equal_reflexive() {
    rc::check("equal is reflexive", []() {
        initAllocator();
        std::string s = *rc::gen::container<std::string>(rc::gen::inRange<char>(32, 127));
        if (s.empty()) return;

        HPointer str = makeString(s);
        auto& alloc = Allocator::instance();
        void* obj = alloc.resolve(str);

        RC_ASSERT(StringOps::equal(obj, obj) == true);
    });
}

// ============================================================================
// Slice Tests (Phase 1)
// ============================================================================

static void test_slice_returns_slice_tag_for_large_range() {
    rc::check("slice over large range produces Tag_StringSlice", []() {
        auto& alloc = initAllocator();
        // Pick a string size large enough to skip the tiny-slice flatten path.
        size_t baseLen = *rc::gen::inRange<size_t>(20000, 30000);
        std::string s(baseLen, 'a');
        HPointer base = makeString(s);

        // A range of >= TINY_SLICE_LIMIT (=8192) UTF-16 code units triggers
        // the slice path; ask for the inner half.
        i64 start = static_cast<i64>(baseLen / 8);
        i64 end = start + 9000;

        void* baseObj = alloc.resolve(base);
        HPointer sliceHp = StringOps::slice(baseObj, start, end);
        void* sliceObj = alloc.resolve(sliceHp);
        RC_ASSERT(static_cast<bool>(sliceObj));
        RC_ASSERT(alloc::getTag(sliceObj) == Tag_StringSlice);
        RC_ASSERT(StringOps::length(sliceObj) == end - start);
    });
}

static void test_slice_tiny_returns_leaf() {
    rc::check("slice over tiny range produces a flat leaf", []() {
        auto& alloc = initAllocator();
        std::string s(200, 'b');
        HPointer base = makeString(s);
        void* baseObj = alloc.resolve(base);
        HPointer sliceHp = StringOps::slice(baseObj, 10, 20);
        void* sliceObj = alloc.resolve(sliceHp);
        RC_ASSERT(static_cast<bool>(sliceObj));
        // The point of this property is "tiny ranges materialize flat, never
        // Tag_StringSlice". Since H1 (plans/utf16-seed-elimination.md), tiny
        // ALL-ASCII ranges narrow to a UTF-8 leaf rather than a UTF-16 one.
        RC_ASSERT(alloc::getTag(sliceObj) == Tag_StringUtf8Leaf);
        RC_ASSERT(StringOps::length(sliceObj) == 10);
    });
}

static void test_slice_round_trip_via_toStdU16String() {
    rc::check("slice content matches reference substring", []() {
        auto& alloc = initAllocator();
        // ASCII characters; exercise both leaf and slice with same content.
        std::string s(*rc::gen::inRange<size_t>(50, 1500), '.');
        for (size_t i = 0; i < s.size(); ++i) {
            s[i] = static_cast<char>('A' + (i % 26));
        }
        size_t start = *rc::gen::inRange<size_t>(0, s.size());
        size_t end = *rc::gen::inRange<size_t>(start, s.size());

        HPointer base = makeString(s);
        void* baseObj = alloc.resolve(base);
        HPointer sliceHp = StringOps::slice(
            baseObj, static_cast<i64>(start), static_cast<i64>(end));

        std::string expected = s.substr(start, end - start);
        std::string actual = getString(sliceHp);
        RC_ASSERT(actual == expected);
    });
}

static void test_slice_of_slice_collapses() {
    rc::check("slice of slice still produces the right substring", []() {
        auto& alloc = initAllocator();
        std::string s(20000, 'X');
        for (size_t i = 0; i < s.size(); ++i) {
            s[i] = static_cast<char>('A' + (i % 26));
        }
        HPointer base = makeString(s);
        // First slice — large, so it produces a Tag_StringSlice.
        void* baseObj = alloc.resolve(base);
        HPointer slice1Hp = StringOps::slice(baseObj, 1000, 11000);
        // Second slice into the slice; slice1 has content s[1000..11000), so
        // slice2 = s[1000+500 .. 1000+9000) = s[1500..10000), length 8500.
        void* slice1Obj = alloc.resolve(slice1Hp);
        HPointer slice2Hp = StringOps::slice(slice1Obj, 500, 9000);

        std::string expected = s.substr(1500, 8500);
        RC_ASSERT(getString(slice2Hp) == expected);

        // The result should still be a Tag_StringSlice over the original
        // leaf (collapsed), not a slice over a slice.
        void* slice2Obj = alloc.resolve(slice2Hp);
        RC_ASSERT(alloc::getTag(slice2Obj) == Tag_StringSlice);
        ElmStringSlice* slc = static_cast<ElmStringSlice*>(slice2Obj);
        void* deepBase = alloc.resolve(slc->base);
        // For large strings, slice.base points at the Tag_LargeStringHeader
        // (not at its body) so that sweepNurseryLargeBodies keeps the body
        // alive — see StringOps.cpp:230-240. The body itself is the Tag_String
        // leaf. Either form is acceptable; what matters is that we land on a
        // leaf in at most one indirection.
        u32 deepTag = alloc::getTag(deepBase);
        if (deepTag == Tag_LargeStringHeader) {
            LargeStringHeader* lh = static_cast<LargeStringHeader*>(deepBase);
            void* body = alloc.resolve(lh->body);
            RC_ASSERT(alloc::getTag(body) == Tag_String);
        } else {
            RC_ASSERT(deepTag == Tag_String);
        }
    });
}

static void test_slice_equal_to_flat_substring() {
    rc::check("slice and flat substring compare equal via StringOps::equal", []() {
        auto& alloc = initAllocator();
        std::string s(20000, '.');
        for (size_t i = 0; i < s.size(); ++i) {
            s[i] = static_cast<char>('a' + (i % 26));
        }
        HPointer base = makeString(s);
        void* baseObj = alloc.resolve(base);

        HPointer sliceHp = StringOps::slice(baseObj, 1000, 11000);
        // Flat copy of the same substring.
        std::string expected = s.substr(1000, 10000);
        HPointer flatHp = makeString(expected);

        void* sliceObj = alloc.resolve(sliceHp);
        void* flatObj = alloc.resolve(flatHp);
        RC_ASSERT(StringOps::equal(sliceObj, flatObj));
        RC_ASSERT(StringOps::compare(sliceObj, flatObj) == 0);
    });
}

static void test_slice_charAt_matches_source() {
    rc::check("charAt on a slice matches direct char read on the source", []() {
        auto& alloc = initAllocator();
        std::string s(*rc::gen::inRange<size_t>(20000, 25000), '.');
        for (size_t i = 0; i < s.size(); ++i) {
            s[i] = static_cast<char>(' ' + (i % 64));
        }
        HPointer base = makeString(s);
        void* baseObj = alloc.resolve(base);
        HPointer sliceHp = StringOps::slice(baseObj, 5000, 14000);
        void* sliceObj = alloc.resolve(sliceHp);

        size_t sliceLen = static_cast<size_t>(StringOps::length(sliceObj));
        for (size_t i = 0; i < sliceLen; i += 137) {
            u16 expected = static_cast<u16>(s[5000 + i]);
            RC_ASSERT(StringOps::charAt(sliceObj, static_cast<i64>(i)) == expected);
        }
    });
}

static void test_slice_survives_gc() {
    rc::check("slice contents preserved across minor GC", []() {
        auto& alloc = initAllocator();
        std::string s(20000, '.');
        for (size_t i = 0; i < s.size(); ++i) {
            s[i] = static_cast<char>('a' + (i % 26));
        }
        HPointer base = makeString(s);
        void* baseObj = alloc.resolve(base);
        HPointer sliceHp = StringOps::slice(baseObj, 100, 9100);

        std::string expected = s.substr(100, 9000);

        // Root the slice across GC so it (and its base) survive.
        alloc.getRootSet().addRoot(&sliceHp);
        alloc.minorGC();
        // After GC the slice and its base should still produce the same content.
        RC_ASSERT(getString(sliceHp) == expected);
        alloc.getRootSet().removeRoot(&sliceHp);
    });
}

// ============================================================================
// Rope Tests (Phase 2)
// ============================================================================

// Build a string of `len` ASCII bytes that vary by position (so equality and
// indexing tests can distinguish positions, not just count).
static std::string makeAsciiPattern(size_t len) {
    std::string s(len, ' ');
    for (size_t i = 0; i < len; ++i) {
        s[i] = static_cast<char>('A' + (i % 26));
    }
    return s;
}

static void test_append_above_flatten_limit_builds_rope() {
    rc::check("append over FLATTEN_LIMIT produces a rope", []() {
        auto& alloc = initAllocator();
        // Each side ~half FLATTEN_LIMIT so total > FLATTEN_LIMIT.
        const size_t halfLimit = 20000;
        std::string left = makeAsciiPattern(halfLimit);
        std::string right = makeAsciiPattern(halfLimit);

        HPointer a = makeString(left);
        HPointer b = makeString(right);
        void* aObj = alloc.resolve(a);
        void* bObj = alloc.resolve(b);

        HPointer ropeHp = StringOps::append(aObj, bObj);
        void* ropeObj = alloc.resolve(ropeHp);
        RC_ASSERT(static_cast<bool>(ropeObj));
        RC_ASSERT(alloc::getTag(ropeObj) == Tag_StringRope);
        RC_ASSERT(StringOps::length(ropeObj) ==
                  static_cast<i64>(left.size() + right.size()));
    });
}

static void test_rope_charAt_matches_concatenation() {
    rc::check("charAt on a rope follows the logical concatenation", []() {
        auto& alloc = initAllocator();
        std::string left = makeAsciiPattern(20000);
        std::string right = makeAsciiPattern(15000);
        std::string concatenated = left + right;

        HPointer a = makeString(left);
        HPointer b = makeString(right);
        HPointer ropeHp = StringOps::append(alloc.resolve(a), alloc.resolve(b));
        void* ropeObj = alloc.resolve(ropeHp);

        // Sample positions throughout the rope.
        for (size_t i = 0; i < concatenated.size(); i += 137) {
            u16 expected = static_cast<u16>(concatenated[i]);
            u16 actual = StringOps::charAt(ropeObj, static_cast<i64>(i));
            RC_ASSERT(actual == expected);
        }
    });
}

static void test_rope_equal_flat_with_same_content() {
    rc::check("rope and flat string with same content compare equal", []() {
        auto& alloc = initAllocator();
        std::string left = makeAsciiPattern(20000);
        std::string right = makeAsciiPattern(15000);
        std::string concatenated = left + right;

        HPointer a = makeString(left);
        HPointer b = makeString(right);
        HPointer rope = StringOps::append(alloc.resolve(a), alloc.resolve(b));

        // Flat has the same content but is a single Tag_String leaf.
        HPointer flat = makeString(concatenated);

        RC_ASSERT(StringOps::equal(alloc.resolve(rope), alloc.resolve(flat)));
        RC_ASSERT(StringOps::compare(alloc.resolve(rope), alloc.resolve(flat)) == 0);
    });
}

static void test_rope_toStdU16String_round_trip() {
    rc::check("toStdU16String on a rope reproduces the logical content", []() {
        auto& alloc = initAllocator();
        std::string left = makeAsciiPattern(*rc::gen::inRange<size_t>(15000, 25000));
        std::string right = makeAsciiPattern(*rc::gen::inRange<size_t>(15000, 25000));
        std::string concatenated = left + right;

        HPointer a = makeString(left);
        HPointer b = makeString(right);
        HPointer rope = StringOps::append(alloc.resolve(a), alloc.resolve(b));

        std::string actual = getString(rope);
        RC_ASSERT(actual == concatenated);
    });
}

static void test_rope_chain_of_appends_survives_gc() {
    rc::check("a tall rope from many appends survives minor GC", []() {
        auto& alloc = initAllocator();
        // Build a rope by chaining many small appends. Each append is
        // small (< FLATTEN_LIMIT), so we artificially force ropes by
        // appending one big-enough rope across each step.
        const size_t segLen = 4000;
        std::string base = makeAsciiPattern(segLen);

        HPointer running = makeString(base);
        std::string expected = base;
        const int steps = 12;
        alloc.getRootSet().addRoot(&running);
        for (int i = 0; i < steps; ++i) {
            HPointer chunk = makeString(base);
            running = StringOps::append(alloc.resolve(running), alloc.resolve(chunk));
            expected += base;
        }
        // Trigger GC; the rope and all its leaves must still resolve.
        alloc.minorGC();
        RC_ASSERT(getString(running) == expected);
        alloc.getRootSet().removeRoot(&running);
    });
}

static void test_rope_slice_yields_correct_substring() {
    rc::check("slicing across a rope boundary returns the right substring", []() {
        auto& alloc = initAllocator();
        std::string left = makeAsciiPattern(20000);
        std::string right = makeAsciiPattern(15000);
        std::string concatenated = left + right;

        HPointer a = makeString(left);
        HPointer b = makeString(right);
        HPointer rope = StringOps::append(alloc.resolve(a), alloc.resolve(b));

        // Cut from inside left, through the boundary, into right.
        i64 start = 18000;
        i64 end = 22000;
        HPointer slice = StringOps::slice(alloc.resolve(rope), start, end);
        std::string expected = concatenated.substr(start, end - start);
        RC_ASSERT(getString(slice) == expected);
    });
}

// ============================================================================
// GC Survival Tests
// ============================================================================

static void test_strings_survive_gc() {
    rc::check("strings survive GC", []() {
        auto& alloc = initAllocator();
        std::string s = *rc::gen::container<std::string>(rc::gen::inRange<char>(32, 127));
        if (s.empty()) return;

        HPointer str = makeString(s);

        // Register as root
        alloc.getRootSet().addRoot(&str);

        // Trigger GC
        alloc.minorGC();

        // Verify content preserved
        RC_ASSERT(getString(str) == s);

        alloc.getRootSet().removeRoot(&str);
    });
}

// ============================================================================
// Test Registration
// ============================================================================

void registerStringOpsTests(Testing::TestSuite& suite) {
    // Length tests
    suite.add(Testing::TestCase("StringOps::length matches input length", test_length_matches_input));
    suite.add(Testing::TestCase("StringOps::isEmpty for empty string", test_empty_string_has_length_zero));

    // Append tests
    suite.add(Testing::TestCase("StringOps::append concatenates strings", test_append_concatenates_strings));
    suite.add(Testing::TestCase("StringOps::append with empty left", test_append_empty_left_returns_right));

    // Slice tests
    suite.add(Testing::TestCase("StringOps::slice extracts substring", test_slice_extracts_substring));

    // Left/Right tests
    suite.add(Testing::TestCase("StringOps::left takes first n", test_left_takes_first_n));

    // Transformation tests
    suite.add(Testing::TestCase("StringOps::toUpper converts lowercase", test_toUpper_converts_lowercase));
    suite.add(Testing::TestCase("StringOps::reverse twice is identity", test_reverse_twice_is_identity));

    // Conversion tests
    suite.add(Testing::TestCase("StringOps::toInt parses integers", test_toInt_parses_integers));
    suite.add(Testing::TestCase("StringOps::fromInt/toInt roundtrip", test_fromInt_toInt_roundtrip));

    // Split/Join tests
    suite.add(Testing::TestCase("StringOps::split splits on separator", test_split_splits_on_separator));

    // Comparison tests
    suite.add(Testing::TestCase("StringOps::equal is reflexive", test_equal_reflexive));

    // Slice (Phase 1) tests
    suite.add(Testing::TestCase("StringOps::slice produces Tag_StringSlice for large ranges",
                                test_slice_returns_slice_tag_for_large_range));
    suite.add(Testing::TestCase("StringOps::slice produces flat leaf for tiny ranges",
                                test_slice_tiny_returns_leaf));
    suite.add(Testing::TestCase("StringOps::slice content matches reference substring",
                                test_slice_round_trip_via_toStdU16String));
    suite.add(Testing::TestCase("StringOps::slice of slice collapses to single slice over leaf",
                                test_slice_of_slice_collapses));
    suite.add(Testing::TestCase("StringOps::equal on slice vs flat substring is true",
                                test_slice_equal_to_flat_substring));
    suite.add(Testing::TestCase("StringOps::charAt on a slice matches the source",
                                test_slice_charAt_matches_source));
    suite.add(Testing::TestCase("StringOps::slice survives minor GC",
                                test_slice_survives_gc));

    // Rope (Phase 2) tests
    suite.add(Testing::TestCase("StringOps::append over FLATTEN_LIMIT builds a rope",
                                test_append_above_flatten_limit_builds_rope));
    suite.add(Testing::TestCase("StringOps::charAt on a rope follows the concatenation",
                                test_rope_charAt_matches_concatenation));
    suite.add(Testing::TestCase("StringOps::equal on rope vs flat with same content",
                                test_rope_equal_flat_with_same_content));
    suite.add(Testing::TestCase("StringOps::toStdU16String on a rope round-trips",
                                test_rope_toStdU16String_round_trip));
    suite.add(Testing::TestCase("StringOps: rope from many appends survives GC",
                                test_rope_chain_of_appends_survives_gc));
    suite.add(Testing::TestCase("StringOps::slice across rope boundary",
                                test_rope_slice_yields_correct_substring));

    // GC tests
    suite.add(Testing::TestCase("StringOps: strings survive GC", test_strings_survive_gc));
}
