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
    u8 head_kind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
        bool is_boxed = (head_kind == 0);

    return alloc::justKind(c->head, head_kind);
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
            u8 head_kind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
        bool is_boxed = (head_kind == 0);
            return alloc::justKind(c->head, head_kind);
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
    u8 lastKind = 0;

    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = getHeader(cell);

        lastVal = c->head;
        lastKind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
        current = c->tail;
    }

    return alloc::justKind(lastVal, lastKind);
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
        u8 head_kind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
        bool is_boxed = (head_kind == 0);

        // Save head and tail BEFORE mapper callback which can trigger GC.
        Unboxable head = c->head;
        HPointer next = c->tail;

        mapped.push_back(mapper(head, is_boxed));
        current = next;
    }

    return alloc::listFromUnboxables(mapped);
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
        u8 head_kind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
        bool is_boxed = (head_kind == 0);

        // Save head and tail BEFORE mapper callback which can trigger GC.
        Unboxable head = c->head;
        HPointer next = c->tail;

        mapped.push_back(mapper(index, head, is_boxed));
        ++index;
        current = next;
    }

    return alloc::listFromUnboxables(mapped);
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
        u8 head_kind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
        bool is_boxed = (head_kind == 0);

        // Save head and tail BEFORE pred callback which can trigger GC.
        Unboxable head = c->head;
        HPointer next = c->tail;

        if (pred(head, is_boxed)) {
            passing.emplace_back(head, is_boxed);
        }
        current = next;
    }

    return alloc::listFromUnboxables(passing);
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
        u8 head_kind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
        bool is_boxed = (head_kind == 0);

        // Save head and tail BEFORE mapper callback which can trigger GC.
        Unboxable head = c->head;
        HPointer next = c->tail;

        HPointer maybeResult = mapper(head, is_boxed);

        // Check if it's Just (not Nothing)
        if (!alloc::isConstant(maybeResult)) {
            void* justCell = allocator.resolve(maybeResult);
            if (justCell) {
                Custom* just = static_cast<Custom*>(justCell);
                if (just->header.tag == Tag_Custom && just->ctor == 0) {
                    // It's Just - extract the value; slot 0 kind 0 means boxed.
                    bool val_boxed = fieldKind(just->unboxed, 0) == 0;
                    results.emplace_back(just->values[0], val_boxed);
                }
            }
        }

        current = next;
    }

    return alloc::listFromUnboxables(results);
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
        u8 head_kind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
        bool is_boxed = (head_kind == 0);

        elements.emplace_back(c->head, is_boxed);
        current = c->tail;
    }

    return alloc::listFromUnboxables(elements, b);
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
            u8 head_kind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
        bool is_boxed = (head_kind == 0);

            allElements.emplace_back(innerCons->head, is_boxed);
            innerList = innerCons->tail;
        }

        outer = outerCons->tail;
    }

    return alloc::listFromUnboxables(allElements);
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
        u8 head_kind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
        bool is_boxed = (head_kind == 0);

        elements.emplace_back(c->head, is_boxed);
        current = c->tail;
    }

    if (elements.size() <= 1) {
        return list;  // Nothing to intersperse
    }

    // Expand with separators interleaved
    std::vector<std::pair<Unboxable, bool>> expanded;
    expanded.reserve(elements.size() * 2 - 1);
    for (size_t i = 0; i < elements.size(); ++i) {
        if (i > 0) expanded.emplace_back(sep, sep_is_boxed);
        expanded.push_back(elements[i]);
    }

    return alloc::listFromUnboxables(expanded);
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
        u8 head_kind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
        bool is_boxed = (head_kind == 0);

        elements.emplace_back(c->head, is_boxed);
        ++count;
        current = c->tail;
    }

    return alloc::listFromUnboxables(elements);
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
        u8 head_kind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
        bool is_boxed = (head_kind == 0);

        // Save head and tail BEFORE pred callback which can trigger GC.
        Unboxable head = c->head;
        HPointer next = c->tail;

        if (pred(head, is_boxed)) {
            passing.emplace_back(head, is_boxed);
        } else {
            failing.emplace_back(head, is_boxed);
        }
        current = next;
    }

    HPointer passingList = alloc::listFromUnboxables(passing);
    HPointer failingList;
    {
        Elm::StackRootGuard guard(&passingList);
        failingList = alloc::listFromUnboxables(failing);
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
        u8 head_kind = static_cast<u8>(tupleFieldKind(hdr->unboxed, 0));
        bool is_boxed = (head_kind == 0);

        // Save head and tail BEFORE fold callback which can trigger GC.
        Unboxable head = c->head;
        HPointer next = c->tail;

        result = fold(head, is_boxed, result);
        current = next;
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

    auto elements = toVector(list);
    return alloc::listFromUnboxables(elements, alloc::listNil(), true);
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

    return alloc::listFromUnboxables(elements);
}

HPointer sortWith(Comparator cmp, HPointer list) {
    if (alloc::isNil(list)) return alloc::listNil();

    auto elements = toVector(list);

    // Sort with custom comparator
    std::sort(elements.begin(), elements.end(),
              [&cmp](const auto& a, const auto& b) {
                  return cmp(a.first, a.second, b.first, b.second) < 0;
              });

    return alloc::listFromUnboxables(elements);
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

    // Phase 1: collect raw values (no allocation)
    struct RawPair { Unboxable a; bool a_boxed; Unboxable b; bool b_boxed; };
    std::vector<RawPair> raw;
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

        raw.push_back({cA->head, !(hdrA->unboxed & 1),
                        cB->head, !(hdrB->unboxed & 1)});
        currA = cA->tail;
        currB = cB->tail;
    }

    if (raw.empty()) return alloc::listNil();

    // Phase 2: build tuples and list with rooting
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& r : raw) {
        if (r.a_boxed) rs.pushStackRootRange(&r.a.p, 1, 1);
        if (r.b_boxed) rs.pushStackRootRange(&r.b.p, 1, 1);
    }
    HPointer result = alloc::listNil();
    rs.pushStackRootRange(&result, 1, 1);

    for (auto it = raw.rbegin(); it != raw.rend(); ++it) {
        u32 mask = 0;
        if (!it->a_boxed) mask |= 1;
        if (!it->b_boxed) mask |= 2;
        HPointer tuple = alloc::tuple2(it->a, it->b, mask);
        result = alloc::cons(alloc::boxed(tuple), result, true);
    }

    rs.restoreStackRangePoint(saved);
    return result;
}

HPointer map3(HPointer listA, HPointer listB, HPointer listC) {
    if (alloc::isNil(listA) || alloc::isNil(listB) || alloc::isNil(listC)) {
        return alloc::listNil();
    }

    auto& allocator = Allocator::instance();

    // Phase 1: collect raw values (no allocation)
    struct RawTriple {
        Unboxable a; bool a_boxed;
        Unboxable b; bool b_boxed;
        Unboxable c; bool c_boxed;
    };
    std::vector<RawTriple> raw;
    HPointer currA = listA;
    HPointer currB = listB;
    HPointer currC = listC;

    while (!alloc::isNil(currA) && !alloc::isNil(currB) && !alloc::isNil(currC)) {
        void* cellA = allocator.resolve(currA);
        void* cellB = allocator.resolve(currB);
        void* cellC = allocator.resolve(currC);
        if (!cellA || !cellB || !cellC) break;

        Cons* cA = static_cast<Cons*>(cellA);
        Cons* cB = static_cast<Cons*>(cellB);
        Cons* cC = static_cast<Cons*>(cellC);
        Header* hdrA = getHeader(cellA);
        Header* hdrB = getHeader(cellB);
        Header* hdrC = getHeader(cellC);

        raw.push_back({cA->head, !(hdrA->unboxed & 1),
                        cB->head, !(hdrB->unboxed & 1),
                        cC->head, !(hdrC->unboxed & 1)});
        currA = cA->tail;
        currB = cB->tail;
        currC = cC->tail;
    }

    if (raw.empty()) return alloc::listNil();

    // Phase 2: build tuples and list with rooting
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& r : raw) {
        if (r.a_boxed) rs.pushStackRootRange(&r.a.p, 1, 1);
        if (r.b_boxed) rs.pushStackRootRange(&r.b.p, 1, 1);
        if (r.c_boxed) rs.pushStackRootRange(&r.c.p, 1, 1);
    }
    HPointer result = alloc::listNil();
    rs.pushStackRootRange(&result, 1, 1);

    for (auto it = raw.rbegin(); it != raw.rend(); ++it) {
        u32 mask = 0;
        if (!it->a_boxed) mask |= 1;
        if (!it->b_boxed) mask |= 2;
        if (!it->c_boxed) mask |= 4;
        HPointer tuple = alloc::tuple3(it->a, it->b, it->c, mask);
        result = alloc::cons(alloc::boxed(tuple), result, true);
    }

    rs.restoreStackRangePoint(saved);
    return result;
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

            bool aBoxed = tupleFieldKind(hdr->unboxed, 0) == 0;
            bool bBoxed = tupleFieldKind(hdr->unboxed, 1) == 0;

            firsts.emplace_back(tuple->a, aBoxed);
            seconds.emplace_back(tuple->b, bBoxed);
        }

        current = c->tail;
    }

    HPointer firstList = alloc::listFromUnboxables(firsts);
    HPointer secondList;
    {
        Elm::StackRootGuard guard(&firstList);
        secondList = alloc::listFromUnboxables(seconds);
    }

    return alloc::tuple2(alloc::boxed(firstList), alloc::boxed(secondList), 0);
}

} // namespace ListOps
} // namespace Elm
