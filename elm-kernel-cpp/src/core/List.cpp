/**
 * Elm Kernel List Module - Runtime Heap Integration
 *
 * This module delegates to ListOps helpers from the runtime allocator.
 * All list operations work with GC-managed Cons cells on the heap.
 */

#include "List.hpp"
#include "allocator/ListOps.hpp"
#include "allocator/Allocator.hpp"

namespace Elm::Kernel::List {

// ============================================================================
// Construction
// ============================================================================

HPointer Nil() {
    return alloc::listNil();
}

HPointer Cons(Unboxable head, HPointer tail, bool headIsBoxed) {
    return alloc::cons(head, tail, headIsBoxed);
}

HPointer ConsBoxed(HPointer head, HPointer tail) {
    return alloc::cons(alloc::boxed(head), tail, true);
}

HPointer fromArray(const std::vector<HPointer>& array) {
    return alloc::listFromPointers(array);
}

std::vector<HPointer> toArray(HPointer list) {
    // ListOps::toVector returns vector<pair<Unboxable, bool>>
    // We need to convert to vector<HPointer>, boxing unboxed values
    auto pairs = ListOps::toVector(list);
    std::vector<HPointer> result;
    result.reserve(pairs.size());

    for (const auto& [val, is_boxed] : pairs) {
        if (is_boxed) {
            result.push_back(val.p);
        } else {
            // Box the unboxed value
            result.push_back(alloc::allocInt(val.i));
        }
    }

    return result;
}

// ============================================================================
// Basic Operations
// ============================================================================

bool isEmpty(HPointer list) {
    return ListOps::isEmpty(list);
}

i64 length(HPointer list) {
    return ListOps::length(list);
}

HPointer head(HPointer list) {
    return ListOps::head(list);
}

HPointer tail(HPointer list) {
    return ListOps::tail(list);
}

// ============================================================================
// Map Operations (multiple lists)
// ============================================================================

HPointer map2(HPointer xs, HPointer ys) {
    return ListOps::map2(xs, ys);
}

HPointer map3(HPointer xs, HPointer ys, HPointer zs) {
    return ListOps::map3(xs, ys, zs);
}

// ============================================================================
// Transformation
// ============================================================================

HPointer reverse(HPointer list) {
    return ListOps::reverse(list);
}

HPointer append(HPointer xs, HPointer ys) {
    return ListOps::append(xs, ys);
}

HPointer concat(HPointer listOfLists) {
    return ListOps::concat(listOfLists);
}

HPointer take(i64 n, HPointer list) {
    return ListOps::take(n, list);
}

HPointer drop(i64 n, HPointer list) {
    return ListOps::drop(n, list);
}

// ============================================================================
// Sorting
// ============================================================================

HPointer sort(HPointer list) {
    return ListOps::sort(list);
}

HPointer sortBy(KeyFunc keyFunc, HPointer list) {
    // Wrap the KeyFunc to match ListOps::KeyExtractor signature
    // KeyExtractor: (Unboxable, bool) -> i64
    // KeyFunc: (void*) -> HPointer
    auto& allocator = Allocator::instance();

    ListOps::KeyExtractor extractor = [&allocator, keyFunc](Unboxable val, bool is_boxed) -> i64 {
        void* elem;
        if (is_boxed) {
            elem = allocator.resolve(val.p);
        } else {
            // Box for the callback
            HPointer boxed = alloc::allocInt(val.i);
            elem = allocator.resolve(boxed);
        }

        HPointer keyResult = keyFunc(elem);
        // Assume key is an int for sorting
        void* keyObj = allocator.resolve(keyResult);
        if (keyObj) {
            ElmInt* intVal = static_cast<ElmInt*>(keyObj);
            return intVal->value;
        }
        return 0;
    };

    return ListOps::sortBy(extractor, list);
}

HPointer sortWith(CmpFunc cmpFunc, HPointer list) {
    // Wrap the CmpFunc to match ListOps::Comparator signature
    // Comparator: (Unboxable, bool, Unboxable, bool) -> int
    // CmpFunc: (void*, void*) -> i64
    auto& allocator = Allocator::instance();

    ListOps::Comparator comparator = [&allocator, cmpFunc](Unboxable a, bool a_boxed, Unboxable b, bool b_boxed) -> int {
        void* elemA;
        void* elemB;

        if (a_boxed) {
            elemA = allocator.resolve(a.p);
        } else {
            HPointer boxed = alloc::allocInt(a.i);
            elemA = allocator.resolve(boxed);
        }

        if (b_boxed) {
            elemB = allocator.resolve(b.p);
        } else {
            HPointer boxed = alloc::allocInt(b.i);
            elemB = allocator.resolve(boxed);
        }

        return static_cast<int>(cmpFunc(elemA, elemB));
    };

    return ListOps::sortWith(comparator, list);
}

// ============================================================================
// Folding
// ============================================================================

i64 sum(HPointer list) {
    return ListOps::sum(list);
}

i64 product(HPointer list) {
    return ListOps::product(list);
}

HPointer maximum(HPointer list) {
    return ListOps::maximum(list);
}

HPointer minimum(HPointer list) {
    return ListOps::minimum(list);
}

// ============================================================================
// Membership
// ============================================================================

bool member(HPointer element, HPointer list) {
    // member takes (Unboxable, bool, HPointer)
    // Element is a boxed HPointer
    return ListOps::member(alloc::boxed(element), true, list);
}

// ============================================================================
// Range
// ============================================================================

HPointer range(i64 low, i64 high) {
    return ListOps::range(low, high);
}

HPointer repeat(i64 n, HPointer value) {
    // repeat takes (n, Unboxable, bool)
    return ListOps::repeat(n, alloc::boxed(value), true);
}

} // namespace Elm::Kernel::List
