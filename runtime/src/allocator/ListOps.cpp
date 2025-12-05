/**
 * List Operations Implementation.
 */

#include "ListOps.hpp"
#include <algorithm>

namespace Elm {
namespace ListOps {

HPointer head(HPointer list) {
    if (alloc::isNil(list)) {
        return alloc::nothing();
    }

    auto& allocator = Allocator::instance();
    void* cell = allocator.resolve(list);
    if (!cell) return alloc::nothing();

    Cons* c = static_cast<Cons*>(cell);
    Header* hdr = getHeader(cell);
    bool is_boxed = !(hdr->unboxed & 1);

    return alloc::just(c->head, is_boxed);
}

HPointer tail(HPointer list) {
    if (alloc::isNil(list)) {
        return alloc::nothing();
    }

    auto& allocator = Allocator::instance();
    void* cell = allocator.resolve(list);
    if (!cell) return alloc::nothing();

    Cons* c = static_cast<Cons*>(cell);
    return alloc::just(alloc::boxed(c->tail), true);
}

HPointer getAt(i64 index, HPointer list) {
    if (index < 0) return alloc::nothing();

    auto& allocator = Allocator::instance();
    HPointer current = list;
    i64 i = 0;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);

        if (i == index) {
            Header* hdr = getHeader(cell);
            bool is_boxed = !(hdr->unboxed & 1);
            return alloc::just(c->head, is_boxed);
        }

        ++i;
        current = c->tail;
    }

    return alloc::nothing();
}

HPointer last(HPointer list) {
    if (alloc::isNil(list)) {
        return alloc::nothing();
    }

    auto& allocator = Allocator::instance();
    HPointer current = list;
    Unboxable lastVal;
    bool lastBoxed = false;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);

        lastVal = c->head;
        lastBoxed = !(hdr->unboxed & 1);
        current = c->tail;
    }

    return alloc::just(lastVal, lastBoxed);
}

HPointer map(MapperWithBoxed mapper, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    // Collect mapped values
    std::vector<std::pair<Unboxable, bool>> mapped;
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);
        bool is_boxed = !(hdr->unboxed & 1);

        mapped.push_back(mapper(c->head, is_boxed));
        current = c->tail;
    }

    // Build result list in reverse
    HPointer result = alloc::listNil();
    for (auto it = mapped.rbegin(); it != mapped.rend(); ++it) {
        result = alloc::cons(it->first, result, it->second);
    }

    return result;
}

HPointer indexedMap(IndexedMapper mapper, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    // Collect mapped values
    std::vector<std::pair<Unboxable, bool>> mapped;
    HPointer current = list;
    i64 index = 0;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);
        bool is_boxed = !(hdr->unboxed & 1);

        mapped.push_back(mapper(index, c->head, is_boxed));
        ++index;
        current = c->tail;
    }

    // Build result list in reverse
    HPointer result = alloc::listNil();
    for (auto it = mapped.rbegin(); it != mapped.rend(); ++it) {
        result = alloc::cons(it->first, result, it->second);
    }

    return result;
}

HPointer filter(Predicate pred, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    // Collect passing elements
    std::vector<std::pair<Unboxable, bool>> passing;
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);
        bool is_boxed = !(hdr->unboxed & 1);

        if (pred(c->head, is_boxed)) {
            passing.emplace_back(c->head, is_boxed);
        }
        current = c->tail;
    }

    // Build result list in reverse
    HPointer result = alloc::listNil();
    for (auto it = passing.rbegin(); it != passing.rend(); ++it) {
        result = alloc::cons(it->first, result, it->second);
    }

    return result;
}

HPointer filterMap(FilterMapper mapper, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    // Collect non-Nothing results
    std::vector<std::pair<Unboxable, bool>> results;
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);
        bool is_boxed = !(hdr->unboxed & 1);

        HPointer maybeResult = mapper(c->head, is_boxed);

        // Check if it's Just (not Nothing)
        if (!alloc::isConstant(maybeResult)) {
            void* justCell = allocator.resolve(maybeResult);
            if (justCell) {
                Custom* just = static_cast<Custom*>(justCell);
                if (just->header.tag == Tag_Custom && just->ctor == 0) {
                    // It's Just - extract the value
                    bool val_boxed = !(just->unboxed & 1);
                    results.emplace_back(just->values[0], val_boxed);
                }
            }
        }

        current = c->tail;
    }

    // Build result list in reverse
    HPointer result = alloc::listNil();
    for (auto it = results.rbegin(); it != results.rend(); ++it) {
        result = alloc::cons(it->first, result, it->second);
    }

    return result;
}

HPointer append(HPointer a, HPointer b) {
    if (alloc::isNil(a)) return b;
    if (alloc::isNil(b)) return a;

    auto& allocator = Allocator::instance();

    // Collect elements from a
    std::vector<std::pair<Unboxable, bool>> elements;
    HPointer current = a;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);
        bool is_boxed = !(hdr->unboxed & 1);

        elements.emplace_back(c->head, is_boxed);
        current = c->tail;
    }

    // Build result by prepending a's elements to b
    HPointer result = b;
    for (auto it = elements.rbegin(); it != elements.rend(); ++it) {
        result = alloc::cons(it->first, result, it->second);
    }

    return result;
}

HPointer concat(HPointer listOfLists) {
    if (alloc::isNil(listOfLists)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    // Flatten all elements
    std::vector<std::pair<Unboxable, bool>> allElements;
    HPointer outer = listOfLists;

    while (!alloc::isNil(outer)) {
        void* outerCell = allocator.resolve(outer);
        if (!outerCell) break;

        Cons* outerCons = static_cast<Cons*>(outerCell);
        HPointer innerList = outerCons->head.p;

        // Traverse inner list
        while (!alloc::isNil(innerList)) {
            void* innerCell = allocator.resolve(innerList);
            if (!innerCell) break;

            Cons* innerCons = static_cast<Cons*>(innerCell);
            Header* hdr = getHeader(innerCell);
            bool is_boxed = !(hdr->unboxed & 1);

            allElements.emplace_back(innerCons->head, is_boxed);
            innerList = innerCons->tail;
        }

        outer = outerCons->tail;
    }

    // Build result list in reverse
    HPointer result = alloc::listNil();
    for (auto it = allElements.rbegin(); it != allElements.rend(); ++it) {
        result = alloc::cons(it->first, result, it->second);
    }

    return result;
}

HPointer intersperse(Unboxable sep, bool sep_is_boxed, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    // Collect elements
    std::vector<std::pair<Unboxable, bool>> elements;
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);
        bool is_boxed = !(hdr->unboxed & 1);

        elements.emplace_back(c->head, is_boxed);
        current = c->tail;
    }

    if (elements.size() <= 1) {
        return list;  // Nothing to intersperse
    }

    // Build result with separators in reverse
    HPointer result = alloc::listNil();
    for (size_t i = elements.size(); i > 0; --i) {
        result = alloc::cons(elements[i - 1].first, result, elements[i - 1].second);
        if (i > 1) {
            result = alloc::cons(sep, result, sep_is_boxed);
        }
    }

    return result;
}

HPointer take(i64 n, HPointer list) {
    if (n <= 0 || alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    // Collect first n elements
    std::vector<std::pair<Unboxable, bool>> elements;
    HPointer current = list;
    i64 count = 0;

    while (!alloc::isNil(current) && count < n) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);
        bool is_boxed = !(hdr->unboxed & 1);

        elements.emplace_back(c->head, is_boxed);
        ++count;
        current = c->tail;
    }

    // Build result list in reverse
    HPointer result = alloc::listNil();
    for (auto it = elements.rbegin(); it != elements.rend(); ++it) {
        result = alloc::cons(it->first, result, it->second);
    }

    return result;
}

HPointer drop(i64 n, HPointer list) {
    if (n <= 0) return list;
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();
    HPointer current = list;
    i64 count = 0;

    while (!alloc::isNil(current) && count < n) {
        void* cell = allocator.resolve(current);
        if (!cell) return alloc::listNil();

        Cons* c = static_cast<Cons*>(cell);
        ++count;
        current = c->tail;
    }

    return current;
}

HPointer partition(Predicate pred, HPointer list) {
    if (alloc::isNil(list)) {
        return alloc::tuple2(alloc::boxed(alloc::listNil()),
                             alloc::boxed(alloc::listNil()), 0);
    }

    auto& allocator = Allocator::instance();

    std::vector<std::pair<Unboxable, bool>> passing;
    std::vector<std::pair<Unboxable, bool>> failing;
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);
        bool is_boxed = !(hdr->unboxed & 1);

        if (pred(c->head, is_boxed)) {
            passing.emplace_back(c->head, is_boxed);
        } else {
            failing.emplace_back(c->head, is_boxed);
        }
        current = c->tail;
    }

    // Build passing list
    HPointer passingList = alloc::listNil();
    for (auto it = passing.rbegin(); it != passing.rend(); ++it) {
        passingList = alloc::cons(it->first, passingList, it->second);
    }

    // Build failing list
    HPointer failingList = alloc::listNil();
    for (auto it = failing.rbegin(); it != failing.rend(); ++it) {
        failingList = alloc::cons(it->first, failingList, it->second);
    }

    return alloc::tuple2(alloc::boxed(passingList), alloc::boxed(failingList), 0);
}

Unboxable foldl(Folder fold, Unboxable acc, HPointer list) {
    auto& allocator = Allocator::instance();
    Unboxable result = acc;
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);
        bool is_boxed = !(hdr->unboxed & 1);

        result = fold(c->head, is_boxed, result);
        current = c->tail;
    }

    return result;
}

Unboxable foldr(Folder fold, Unboxable acc, HPointer list) {
    // Collect elements first (need to process in reverse)
    auto elements = toVector(list);

    Unboxable result = acc;
    for (auto it = elements.rbegin(); it != elements.rend(); ++it) {
        result = fold(it->first, it->second, result);
    }

    return result;
}

HPointer reverse(HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto& allocator = Allocator::instance();
    HPointer result = alloc::listNil();
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);
        bool is_boxed = !(hdr->unboxed & 1);

        result = alloc::cons(c->head, result, is_boxed);
        current = c->tail;
    }

    return result;
}

bool member(Unboxable value, bool is_boxed, HPointer list) {
    auto& allocator = Allocator::instance();
    HPointer current = list;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);
        bool elem_is_boxed = !(hdr->unboxed & 1);

        // Simple equality check for unboxed primitives
        if (!is_boxed && !elem_is_boxed) {
            if (value.i == c->head.i) return true;
        } else if (is_boxed && elem_is_boxed) {
            // Pointer equality for boxed values
            if (value.p.ptr == c->head.p.ptr &&
                value.p.constant == c->head.p.constant) return true;
        }

        current = c->tail;
    }

    return false;
}

HPointer sort(HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    // Collect elements (assumes integers for now)
    auto elements = toIntVector(list);

    // Sort
    std::sort(elements.begin(), elements.end());

    // Build result list
    return alloc::listFromInts(elements);
}

HPointer sortBy(KeyExtractor keyFn, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto elements = toVector(list);

    // Sort by key
    std::sort(elements.begin(), elements.end(),
              [&keyFn](const auto& a, const auto& b) {
                  return keyFn(a.first, a.second) < keyFn(b.first, b.second);
              });

    // Build result list
    HPointer result = alloc::listNil();
    for (auto it = elements.rbegin(); it != elements.rend(); ++it) {
        result = alloc::cons(it->first, result, it->second);
    }

    return result;
}

HPointer sortWith(Comparator cmp, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto elements = toVector(list);

    // Sort with custom comparator
    std::sort(elements.begin(), elements.end(),
              [&cmp](const auto& a, const auto& b) {
                  return cmp(a.first, a.second, b.first, b.second) < 0;
              });

    // Build result list
    HPointer result = alloc::listNil();
    for (auto it = elements.rbegin(); it != elements.rend(); ++it) {
        result = alloc::cons(it->first, result, it->second);
    }

    return result;
}

HPointer maximum(HPointer list) {
    if (alloc::isNil(list)) return alloc::nothing();

    auto elements = toVector(list);
    if (elements.empty()) return alloc::nothing();

    auto maxIt = std::max_element(elements.begin(), elements.end(),
                                   [](const auto& a, const auto& b) {
                                       return a.first.i < b.first.i;
                                   });

    return alloc::just(maxIt->first, maxIt->second);
}

HPointer minimum(HPointer list) {
    if (alloc::isNil(list)) return alloc::nothing();

    auto elements = toVector(list);
    if (elements.empty()) return alloc::nothing();

    auto minIt = std::min_element(elements.begin(), elements.end(),
                                   [](const auto& a, const auto& b) {
                                       return a.first.i < b.first.i;
                                   });

    return alloc::just(minIt->first, minIt->second);
}

HPointer map2(HPointer listA, HPointer listB) {
    if (alloc::isNil(listA) || alloc::isNil(listB)) return alloc::listNil();

    auto& allocator = Allocator::instance();
    std::vector<HPointer> pairs;

    HPointer currA = listA;
    HPointer currB = listB;

    while (!alloc::isNil(currA) && !alloc::isNil(currB)) {
        void* cellA = allocator.resolve(currA);
        void* cellB = allocator.resolve(currB);
        if (!cellA || !cellB) break;

        Cons* cA = static_cast<Cons*>(cellA);
        Cons* cB = static_cast<Cons*>(cellB);
        Header* hdrA = getHeader(cellA);
        Header* hdrB = getHeader(cellB);
        bool boxedA = !(hdrA->unboxed & 1);
        bool boxedB = !(hdrB->unboxed & 1);

        // Create tuple (a, b)
        u32 unboxedMask = 0;
        if (!boxedA) unboxedMask |= 1;
        if (!boxedB) unboxedMask |= 2;

        HPointer tuple = alloc::tuple2(cA->head, cB->head, unboxedMask);
        pairs.push_back(tuple);

        currA = cA->tail;
        currB = cB->tail;
    }

    return alloc::listFromPointers(pairs);
}

HPointer unzip(HPointer listOfPairs) {
    if (alloc::isNil(listOfPairs)) {
        return alloc::tuple2(alloc::boxed(alloc::listNil()),
                             alloc::boxed(alloc::listNil()), 0);
    }

    auto& allocator = Allocator::instance();
    std::vector<std::pair<Unboxable, bool>> firsts;
    std::vector<std::pair<Unboxable, bool>> seconds;

    HPointer current = listOfPairs;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        void* tupleObj = allocator.resolve(c->head.p);
        if (tupleObj) {
            Tuple2* tuple = static_cast<Tuple2*>(tupleObj);
            Header* hdr = getHeader(tupleObj);

            bool aBoxed = !(hdr->unboxed & 1);
            bool bBoxed = !(hdr->unboxed & 2);

            firsts.emplace_back(tuple->a, aBoxed);
            seconds.emplace_back(tuple->b, bBoxed);
        }

        current = c->tail;
    }

    // Build first list
    HPointer firstList = alloc::listNil();
    for (auto it = firsts.rbegin(); it != firsts.rend(); ++it) {
        firstList = alloc::cons(it->first, firstList, it->second);
    }

    // Build second list
    HPointer secondList = alloc::listNil();
    for (auto it = seconds.rbegin(); it != seconds.rend(); ++it) {
        secondList = alloc::cons(it->first, secondList, it->second);
    }

    return alloc::tuple2(alloc::boxed(firstList), alloc::boxed(secondList), 0);
}

} // namespace ListOps
} // namespace Elm
