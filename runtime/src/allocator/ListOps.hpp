/**
 * List Operations for Elm Runtime.
 *
 * This file provides list manipulation utilities that work with the
 * GC-managed heap. Functions operate on Cons cell linked lists and
 * return new lists (Elm lists are immutable).
 *
 * List representation:
 *   - Empty list: Nil constant (embedded in HPointer)
 *   - Non-empty: Cons cell with head (Unboxable) and tail (HPointer)
 *   - Head can be unboxed (primitive) or boxed (heap pointer)
 *
 * Key operations:
 *   - Construction: singleton, range, repeat
 *   - Access: head, tail, isEmpty, length
 *   - Transform: map, indexedMap, filter, filterMap
 *   - Combine: append, concat, intersperse
 *   - Sub-lists: take, drop, partition, unzip
 *   - Fold: foldl, foldr, reduce
 *   - Special: reverse, sort, sortBy, sortWith
 */

#ifndef ECO_LIST_OPS_H
#define ECO_LIST_OPS_H

#include "Allocator.hpp"
#include "HeapHelpers.hpp"
#include <vector>
#include <functional>

namespace Elm {
namespace ListOps {

// ============================================================================
// Construction
// ============================================================================

/**
 * Creates a singleton list containing one element.
 */
inline HPointer singleton(Unboxable value, bool is_boxed) {
    return alloc::cons(value, alloc::listNil(), is_boxed);
}

/**
 * Creates a list of integers from low to high (inclusive).
 */
inline HPointer range(i64 low, i64 high) {
    if (low > high) return alloc::listNil();

    HPointer result = alloc::listNil();
    for (i64 i = high; i >= low; --i) {
        result = alloc::cons(alloc::unboxedInt(i), result, false);
    }
    return result;
}

/**
 * Creates a list with n copies of a value.
 */
inline HPointer repeat(i64 n, Unboxable value, bool is_boxed) {
    if (n <= 0) return alloc::listNil();

    HPointer result = alloc::listNil();
    for (i64 i = 0; i < n; ++i) {
        result = alloc::cons(value, result, is_boxed);
    }
    return result;
}

// ============================================================================
// Access
// ============================================================================

/**
 * Checks if a list is empty.
 */
inline bool isEmpty(HPointer list) {
    return alloc::isNil(list);
}

/**
 * Returns the length of a list.
 */
inline i64 length(HPointer list) {
    auto& allocator = Allocator::instance();
    i64 count = 0;
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        ++count;
        current = c->tail;
    }

    return count;
}

/**
 * Returns the head of a list, or Nothing if empty.
 * The head is wrapped in a Maybe (Just head | Nothing).
 */
HPointer head(HPointer list);

/**
 * Returns the tail of a list, or Nothing if empty.
 * The tail is wrapped in a Maybe (Just tail | Nothing).
 */
HPointer tail(HPointer list);

/**
 * Returns the element at index n (0-based).
 * Returns Nothing if index is out of bounds.
 */
HPointer getAt(i64 index, HPointer list);

/**
 * Returns the last element of a list, or Nothing if empty.
 */
HPointer last(HPointer list);

// ============================================================================
// Transform
// ============================================================================

/**
 * Function type for mapping operations.
 * Takes an Unboxable value and its boxed status, returns a transformed value.
 */
using Mapper = std::function<Unboxable(Unboxable, bool)>;
using MapperWithBoxed = std::function<std::pair<Unboxable, bool>(Unboxable, bool)>;

/**
 * Maps a function over a list, producing a new list.
 * The mapper returns (value, is_boxed) pairs.
 */
HPointer map(MapperWithBoxed mapper, HPointer list);

/**
 * Maps a function over a list with index.
 * The mapper receives (index, value, is_boxed) and returns (value, is_boxed).
 */
using IndexedMapper = std::function<std::pair<Unboxable, bool>(i64, Unboxable, bool)>;

HPointer indexedMap(IndexedMapper mapper, HPointer list);

/**
 * Filters a list based on a predicate.
 */
using Predicate = std::function<bool(Unboxable, bool)>;

HPointer filter(Predicate pred, HPointer list);

/**
 * Maps and filters in one pass. If mapper returns Nothing, element is dropped.
 */
using FilterMapper = std::function<HPointer(Unboxable, bool)>;

HPointer filterMap(FilterMapper mapper, HPointer list);

// ============================================================================
// Combine
// ============================================================================

/**
 * Appends two lists: a ++ b
 */
HPointer append(HPointer a, HPointer b);

/**
 * Concatenates a list of lists.
 */
HPointer concat(HPointer listOfLists);

/**
 * Intersperses a separator between list elements.
 */
HPointer intersperse(Unboxable sep, bool sep_is_boxed, HPointer list);

/**
 * Zips two lists together into a list of pairs.
 */
HPointer map2(HPointer listA, HPointer listB);

/**
 * Zips three lists together.
 */
HPointer map3(HPointer listA, HPointer listB, HPointer listC);

// ============================================================================
// Sub-lists
// ============================================================================

/**
 * Takes the first n elements of a list.
 */
HPointer take(i64 n, HPointer list);

/**
 * Drops the first n elements of a list.
 */
HPointer drop(i64 n, HPointer list);

/**
 * Partitions a list based on a predicate.
 * Returns a tuple (passing, failing).
 */
HPointer partition(Predicate pred, HPointer list);

/**
 * Unzips a list of pairs into a pair of lists.
 */
HPointer unzip(HPointer listOfPairs);

// ============================================================================
// Fold
// ============================================================================

/**
 * Folder function type: (element, accumulator) -> accumulator
 */
using Folder = std::function<Unboxable(Unboxable, bool, Unboxable)>;

/**
 * Left fold: processes elements from head to tail.
 */
Unboxable foldl(Folder fold, Unboxable acc, HPointer list);

/**
 * Right fold: processes elements from tail to head.
 */
Unboxable foldr(Folder fold, Unboxable acc, HPointer list);

/**
 * Computes the sum of a list of integers.
 */
inline i64 sum(HPointer list) {
    auto& allocator = Allocator::instance();
    i64 total = 0;
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);

        // If unboxed (primitive), get the int value directly
        if (hdr->unboxed & 1) {
            total += c->head.i;
        }
        current = c->tail;
    }

    return total;
}

/**
 * Computes the product of a list of integers.
 */
inline i64 product(HPointer list) {
    auto& allocator = Allocator::instance();
    i64 total = 1;
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);

        if (hdr->unboxed & 1) {
            total *= c->head.i;
        }
        current = c->tail;
    }

    return total;
}

/**
 * Returns the maximum element of a list of comparable values.
 * Returns Nothing if list is empty.
 */
HPointer maximum(HPointer list);

/**
 * Returns the minimum element of a list of comparable values.
 * Returns Nothing if list is empty.
 */
HPointer minimum(HPointer list);

// ============================================================================
// Membership
// ============================================================================

/**
 * Checks if all elements satisfy a predicate.
 */
inline bool all(Predicate pred, HPointer list) {
    auto& allocator = Allocator::instance();
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);
        bool is_boxed = !(hdr->unboxed & 1);

        if (!pred(c->head, is_boxed)) return false;
        current = c->tail;
    }

    return true;
}

/**
 * Checks if any element satisfies a predicate.
 */
inline bool any(Predicate pred, HPointer list) {
    auto& allocator = Allocator::instance();
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);
        bool is_boxed = !(hdr->unboxed & 1);

        if (pred(c->head, is_boxed)) return true;
        current = c->tail;
    }

    return false;
}

/**
 * Checks if an element is a member of a list (using equality).
 */
bool member(Unboxable value, bool is_boxed, HPointer list);

// ============================================================================
// Sorting
// ============================================================================

/**
 * Reverses a list.
 */
HPointer reverse(HPointer list);

/**
 * Sorts a list of comparable values (integers or strings).
 */
HPointer sort(HPointer list);

/**
 * Sorts a list by a key function.
 * The key function extracts a comparable value from each element.
 */
using KeyExtractor = std::function<i64(Unboxable, bool)>;

HPointer sortBy(KeyExtractor keyFn, HPointer list);

/**
 * Sorts a list using a custom comparison function.
 * The comparator returns Order (LT < 0, EQ = 0, GT > 0).
 */
using Comparator = std::function<int(Unboxable, bool, Unboxable, bool)>;

HPointer sortWith(Comparator cmp, HPointer list);

// ============================================================================
// Utilities
// ============================================================================

/**
 * Converts a list to a std::vector of Unboxables.
 * Useful for interop and debugging.
 */
inline std::vector<std::pair<Unboxable, bool>> toVector(HPointer list) {
    auto& allocator = Allocator::instance();
    std::vector<std::pair<Unboxable, bool>> result;
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);
        bool is_boxed = !(hdr->unboxed & 1);

        result.emplace_back(c->head, is_boxed);
        current = c->tail;
    }

    return result;
}

/**
 * Collects list elements into a std::vector of integers (assumes all unboxed).
 */
inline std::vector<i64> toIntVector(HPointer list) {
    auto& allocator = Allocator::instance();
    std::vector<i64> result;
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        result.push_back(c->head.i);
        current = c->tail;
    }

    return result;
}

/**
 * Creates a list from a std::vector with a mapper that provides boxing info.
 */
template<typename T>
HPointer fromVector(const std::vector<T>& vec,
                    std::function<std::pair<Unboxable, bool>(const T&)> converter) {
    HPointer result = alloc::listNil();
    for (auto it = vec.rbegin(); it != vec.rend(); ++it) {
        auto [val, is_boxed] = converter(*it);
        result = alloc::cons(val, result, is_boxed);
    }
    return result;
}

} // namespace ListOps
} // namespace Elm

#endif // ECO_LIST_OPS_H
