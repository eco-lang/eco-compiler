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
    // Adapts `keyFunc` to `ListOps::KeyExtractor`, which is given each element with only a boxed flag.
    auto& allocator = Allocator::instance();

    ListOps::KeyExtractor extractor = [&allocator, keyFunc](Unboxable val, bool is_boxed) -> i64 {
        void* elem;
        if (is_boxed) {
            elem = allocator.resolve(val.p);
        } else {
            // The extractor is not told the slot kind, so every unboxed element is boxed as an Int.
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

    // The comparator is told only whether an element is boxed, so unboxed elements are boxed at the
    // slot kind of the first node, which is right only when every element has that kind.
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
