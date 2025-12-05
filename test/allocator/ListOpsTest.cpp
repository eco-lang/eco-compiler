/**
 * Property-based tests for ListOps.hpp.
 */

#include "ListOpsTest.hpp"
#include "../../runtime/src/allocator/ListOps.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "TestHelpers.hpp"
#include <rapidcheck.h>
#include <algorithm>
#include <numeric>

using namespace Elm;

// ============================================================================
// isEmpty Tests
// ============================================================================

static void test_isEmpty_nil() {
    rc::check("isEmpty returns true for nil", []() {
        initAllocator();

        HPointer nil = alloc::listNil();
        RC_ASSERT(ListOps::isEmpty(nil) == true);
    });
}

static void test_isEmpty_cons() {
    rc::check("isEmpty returns false for cons", []() {
        initAllocator();

        i64 n = *rc::gen::arbitrary<i64>();
        HPointer list = alloc::cons(alloc::unboxedInt(n), alloc::listNil(), false);

        RC_ASSERT(ListOps::isEmpty(list) == false);
    });
}

// ============================================================================
// Length Tests
// ============================================================================

static void test_length_empty() {
    rc::check("length of empty list is 0", []() {
        initAllocator();

        HPointer nil = alloc::listNil();
        RC_ASSERT(ListOps::length(nil) == 0);
    });
}

static void test_length_matches_input() {
    rc::check("length matches number of elements", []() {
        initAllocator();

        std::vector<i64> nums = *rc::gen::container<std::vector<i64>>(
            rc::gen::inRange<i64>(-1000, 1000)
        );

        HPointer list = alloc::listFromInts(nums);

        RC_ASSERT(ListOps::length(list) == static_cast<i64>(nums.size()));
    });
}

// ============================================================================
// Range Tests
// ============================================================================

static void test_range_creates_sequence() {
    rc::check("range creates ascending sequence", []() {
        initAllocator();

        i64 low = *rc::gen::inRange<i64>(-100, 100);
        i64 high = *rc::gen::inRange<i64>(low, low + 50);

        HPointer list = ListOps::range(low, high);
        std::vector<i64> vec = ListOps::toIntVector(list);

        RC_ASSERT(vec.size() == static_cast<size_t>(high - low + 1));

        for (size_t i = 0; i < vec.size(); ++i) {
            RC_ASSERT(vec[i] == low + static_cast<i64>(i));
        }
    });
}

static void test_range_empty_when_low_greater() {
    rc::check("range is empty when low > high", []() {
        initAllocator();

        i64 low = *rc::gen::inRange<i64>(1, 100);
        i64 high = low - 1;

        HPointer list = ListOps::range(low, high);
        RC_ASSERT(ListOps::isEmpty(list));
    });
}

// ============================================================================
// Sum Tests
// ============================================================================

static void test_sum_empty() {
    rc::check("sum of empty list is 0", []() {
        initAllocator();

        HPointer nil = alloc::listNil();
        RC_ASSERT(ListOps::sum(nil) == 0);
    });
}

static void test_sum_matches_std() {
    rc::check("sum matches std::accumulate", []() {
        initAllocator();

        std::vector<i64> nums = *rc::gen::container<std::vector<i64>>(
            rc::gen::inRange<i64>(-1000, 1000)
        );

        HPointer list = alloc::listFromInts(nums);
        i64 actual = ListOps::sum(list);
        i64 expected = std::accumulate(nums.begin(), nums.end(), i64(0));

        RC_ASSERT(actual == expected);
    });
}

// ============================================================================
// Reverse Tests
// ============================================================================

static void test_reverse_empty() {
    rc::check("reverse of empty is empty", []() {
        initAllocator();

        HPointer nil = alloc::listNil();
        HPointer rev = ListOps::reverse(nil);
        RC_ASSERT(ListOps::isEmpty(rev));
    });
}

static void test_reverse_twice_is_identity() {
    rc::check("reverse(reverse(list)) == list", []() {
        initAllocator();

        std::vector<i64> nums = *rc::gen::container<std::vector<i64>>(
            rc::gen::inRange<i64>(-1000, 1000)
        );

        HPointer list = alloc::listFromInts(nums);
        HPointer rev1 = ListOps::reverse(list);
        HPointer rev2 = ListOps::reverse(rev1);

        std::vector<i64> doubled = ListOps::toIntVector(rev2);

        RC_ASSERT(nums == doubled);
    });
}

static void test_reverse_reverses_order() {
    rc::check("reverse reverses element order", []() {
        initAllocator();

        std::vector<i64> nums = *rc::gen::container<std::vector<i64>>(
            rc::gen::inRange<i64>(-1000, 1000)
        );

        HPointer list = alloc::listFromInts(nums);
        HPointer rev = ListOps::reverse(list);

        std::vector<i64> reversed = ListOps::toIntVector(rev);
        std::vector<i64> expected = nums;
        std::reverse(expected.begin(), expected.end());

        RC_ASSERT(reversed == expected);
    });
}

// ============================================================================
// Append Tests
// ============================================================================

static void test_append_empty_left() {
    rc::check("append with empty left returns right", []() {
        initAllocator();

        std::vector<i64> nums = *rc::gen::container<std::vector<i64>>(
            rc::gen::inRange<i64>(-1000, 1000)
        );

        HPointer nil = alloc::listNil();
        HPointer list = alloc::listFromInts(nums);
        HPointer result = ListOps::append(nil, list);

        RC_ASSERT(ListOps::toIntVector(result) == nums);
    });
}

static void test_append_concatenates() {
    rc::check("append concatenates lists", []() {
        initAllocator();

        std::vector<i64> a = *rc::gen::container<std::vector<i64>>(
            rc::gen::inRange<i64>(-1000, 1000)
        );
        std::vector<i64> b = *rc::gen::container<std::vector<i64>>(
            rc::gen::inRange<i64>(-1000, 1000)
        );

        HPointer listA = alloc::listFromInts(a);
        HPointer listB = alloc::listFromInts(b);
        HPointer result = ListOps::append(listA, listB);

        std::vector<i64> expected = a;
        expected.insert(expected.end(), b.begin(), b.end());

        RC_ASSERT(ListOps::toIntVector(result) == expected);
    });
}

// ============================================================================
// Take/Drop Tests
// ============================================================================

static void test_take_zero() {
    rc::check("take 0 gives empty list", []() {
        initAllocator();

        std::vector<i64> nums = *rc::gen::container<std::vector<i64>>(
            rc::gen::inRange<i64>(-1000, 1000)
        );

        HPointer list = alloc::listFromInts(nums);
        HPointer result = ListOps::take(0, list);

        RC_ASSERT(ListOps::isEmpty(result));
    });
}

static void test_take_partial() {
    rc::check("take n gives first n elements", []() {
        initAllocator();

        std::vector<i64> nums = *rc::gen::container<std::vector<i64>>(
            rc::gen::inRange<i64>(-1000, 1000)
        );
        if (nums.empty()) return;

        size_t n = *rc::gen::inRange<size_t>(0, nums.size() + 1);

        HPointer list = alloc::listFromInts(nums);
        HPointer result = ListOps::take(static_cast<i64>(n), list);

        std::vector<i64> expected(nums.begin(), nums.begin() + std::min(n, nums.size()));
        RC_ASSERT(ListOps::toIntVector(result) == expected);
    });
}

// ============================================================================
// Filter Tests
// ============================================================================

static void test_filter_positive() {
    rc::check("filter positive numbers", []() {
        initAllocator();

        std::vector<i64> nums = *rc::gen::container<std::vector<i64>>(
            rc::gen::inRange<i64>(-1000, 1000)
        );

        HPointer list = alloc::listFromInts(nums);
        auto isPositive = [](Unboxable val, bool) { return val.i > 0; };
        HPointer result = ListOps::filter(isPositive, list);

        std::vector<i64> expected;
        std::copy_if(nums.begin(), nums.end(), std::back_inserter(expected),
                     [](i64 n) { return n > 0; });

        RC_ASSERT(ListOps::toIntVector(result) == expected);
    });
}

// ============================================================================
// Sort Tests
// ============================================================================

static void test_sort_empty() {
    rc::check("sort of empty is empty", []() {
        initAllocator();

        HPointer nil = alloc::listNil();
        HPointer result = ListOps::sort(nil);

        RC_ASSERT(ListOps::isEmpty(result));
    });
}

static void test_sort_orders_elements() {
    rc::check("sort orders elements ascending", []() {
        initAllocator();

        std::vector<i64> nums = *rc::gen::container<std::vector<i64>>(
            rc::gen::inRange<i64>(-1000, 1000)
        );

        HPointer list = alloc::listFromInts(nums);
        HPointer result = ListOps::sort(list);

        std::vector<i64> expected = nums;
        std::sort(expected.begin(), expected.end());

        RC_ASSERT(ListOps::toIntVector(result) == expected);
    });
}

// ============================================================================
// GC Survival Tests
// ============================================================================

static void test_list_survives_gc() {
    rc::check("list survives GC", []() {
        auto& alloc = initAllocator();

        std::vector<i64> nums = *rc::gen::container<std::vector<i64>>(
            rc::gen::inRange<i64>(-1000, 1000)
        );

        HPointer list = alloc::listFromInts(nums);

        alloc.getRootSet().addRoot(&list);

        alloc.minorGC();

        RC_ASSERT(ListOps::toIntVector(list) == nums);

        alloc.getRootSet().removeRoot(&list);
    });
}

static void test_appended_list_survives_gc() {
    rc::check("appended list survives GC", []() {
        auto& alloc = initAllocator();

        std::vector<i64> a = *rc::gen::container<std::vector<i64>>(
            rc::gen::inRange<i64>(-1000, 1000)
        );
        std::vector<i64> b = *rc::gen::container<std::vector<i64>>(
            rc::gen::inRange<i64>(-1000, 1000)
        );

        HPointer listA = alloc::listFromInts(a);
        HPointer listB = alloc::listFromInts(b);
        HPointer combined = ListOps::append(listA, listB);

        alloc.getRootSet().addRoot(&combined);

        alloc.minorGC();

        std::vector<i64> expected = a;
        expected.insert(expected.end(), b.begin(), b.end());

        RC_ASSERT(ListOps::toIntVector(combined) == expected);

        alloc.getRootSet().removeRoot(&combined);
    });
}

// ============================================================================
// Test Registration
// ============================================================================

void registerListOpsTests(Testing::TestSuite& suite) {
    // isEmpty tests
    suite.add(Testing::TestCase("ListOps::isEmpty for nil", test_isEmpty_nil));
    suite.add(Testing::TestCase("ListOps::isEmpty for cons", test_isEmpty_cons));

    // Length tests
    suite.add(Testing::TestCase("ListOps::length of empty", test_length_empty));
    suite.add(Testing::TestCase("ListOps::length matches input", test_length_matches_input));

    // Range tests
    suite.add(Testing::TestCase("ListOps::range creates sequence", test_range_creates_sequence));
    suite.add(Testing::TestCase("ListOps::range empty when low > high", test_range_empty_when_low_greater));

    // Sum tests
    suite.add(Testing::TestCase("ListOps::sum of empty", test_sum_empty));
    suite.add(Testing::TestCase("ListOps::sum matches std", test_sum_matches_std));

    // Reverse tests
    suite.add(Testing::TestCase("ListOps::reverse of empty", test_reverse_empty));
    suite.add(Testing::TestCase("ListOps::reverse twice is identity", test_reverse_twice_is_identity));
    suite.add(Testing::TestCase("ListOps::reverse reverses order", test_reverse_reverses_order));

    // Append tests
    suite.add(Testing::TestCase("ListOps::append with empty left", test_append_empty_left));
    suite.add(Testing::TestCase("ListOps::append concatenates", test_append_concatenates));

    // Take/Drop tests
    suite.add(Testing::TestCase("ListOps::take zero", test_take_zero));
    suite.add(Testing::TestCase("ListOps::take partial", test_take_partial));

    // Filter tests
    suite.add(Testing::TestCase("ListOps::filter positive", test_filter_positive));

    // Sort tests
    suite.add(Testing::TestCase("ListOps::sort of empty", test_sort_empty));
    suite.add(Testing::TestCase("ListOps::sort orders elements", test_sort_orders_elements));

    // GC tests
    suite.add(Testing::TestCase("ListOps: list survives GC", test_list_survives_gc));
    suite.add(Testing::TestCase("ListOps: appended list survives GC", test_appended_list_survives_gc));
}
