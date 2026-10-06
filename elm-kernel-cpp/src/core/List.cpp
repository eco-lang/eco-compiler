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

HPointer cons(Unboxable head, HPointer tail, bool headIsBoxed) {
    return alloc::cons(head, tail, headIsBoxed);
}

HPointer fromArray(const std::vector<HPointer>& array) {
    return alloc::listFromPointers(array);
}

// ============================================================================
// Sorting
// ============================================================================

HPointer sortBy(KeyFunc keyFunc, HPointer list) {
    // Wrap KeyFunc (void* -> HPointer) to the kind-aware ListOps::KeyExtractor.
    auto& allocator = Allocator::instance();

    ListOps::KeyExtractor extractor = [&allocator, keyFunc](Unboxable val, bool is_boxed) -> i64 {
        void* elem;
        if (is_boxed) {
            elem = allocator.resolve(val.p);
        } else {
            // Cannot distinguish Int/Float/Char here; fall back to heuristic via allocInt.
            // Kind-aware sortByKind should be used instead.
            HPointer boxed = alloc::allocInt(val.i);
            elem = allocator.resolve(boxed);
        }

        HPointer keyResult = keyFunc(elem);
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
    auto& allocator = Allocator::instance();

    // Fish out the element kind from the first Cons cell so the callback can
    // re-box unboxed Int/Float/Char heads correctly.
    u8 element_kind = 0;
    if (!alloc::isNil(list)) {
        void* cell = allocator.resolve(list);
        if (cell) {
            Header* hdr = static_cast<Header*>(cell);
            element_kind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
        }
    }

    ListOps::Comparator comparator = [&allocator, cmpFunc, element_kind](Unboxable a, bool a_boxed, Unboxable b, bool b_boxed) -> int {
        void* elemA;
        void* elemB;

        if (a_boxed) {
            elemA = allocator.resolve(a.p);
        } else {
            HPointer boxed = alloc::boxElement(a, element_kind);
            elemA = allocator.resolve(boxed);
        }

        if (b_boxed) {
            elemB = allocator.resolve(b.p);
        } else {
            HPointer boxed = alloc::boxElement(b, element_kind);
            elemB = allocator.resolve(boxed);
        }

        return static_cast<int>(cmpFunc(elemA, elemB));
    };

    return ListOps::sortWith(comparator, list);
}

} // namespace Elm::Kernel::List
