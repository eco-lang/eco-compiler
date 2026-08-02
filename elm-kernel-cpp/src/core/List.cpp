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

std::vector<HPointer> toArray(HPointer list) {
    // Convert list to vector, boxing any unboxed values using head-kind from each cell.
    auto& allocator = Allocator::instance();
    std::vector<std::pair<Unboxable, u8>> rawElems;
    for (alloc::ListCursor c(list); !c.done(); c.next()) {
        rawElems.push_back({c.current(), c.currentKind()});
    }

    std::vector<HPointer> result(rawElems.size(), alloc::listNil());
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& hp : result) rs.pushStackRootRange(&hp, 1, 1);
    for (auto& r : rawElems) if (r.second == 0) rs.pushStackRootRange(&r.first.p, 1, 1);

    for (size_t i = 0; i < rawElems.size(); ++i) {
        result[i] = alloc::boxElement(rawElems[i].first, rawElems[i].second);
    }

    rs.restoreStackRangePoint(saved);
    return result;
}

// ============================================================================
// Map Operations (multiple lists)
// ============================================================================

HPointer map2(Map2Func func, HPointer xs, HPointer ys) {
    if (alloc::isNil(xs) || alloc::isNil(ys)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    // Phase 1: collect raw values (no allocation)
    struct RawPair { Unboxable x; u8 x_kind; Unboxable y; u8 y_kind; };
    std::vector<RawPair> raw;
    {
        alloc::ListCursor cx(xs);
        alloc::ListCursor cy(ys);
        while (!cx.done() && !cy.done()) {
            raw.push_back({cx.current(), cx.currentKind(),
                           cy.current(), cy.currentKind()});
            cx.next();
            cy.next();
        }
    }
    if (raw.empty()) return alloc::listNil();

    // Phase 2: build with rooting
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& r : raw) {
        if (r.x_kind == 0) rs.pushStackRootRange(&r.x.p, 1, 1);
        if (r.y_kind == 0) rs.pushStackRootRange(&r.y.p, 1, 1);
    }
    std::vector<HPointer> results(raw.size(), alloc::listNil());
    for (auto& hp : results) rs.pushStackRootRange(&hp, 1, 1);
    HPointer tempX = alloc::listNil(), tempY = alloc::listNil();
    rs.pushStackRootRange(&tempX, 1, 1);
    rs.pushStackRootRange(&tempY, 1, 1);

    for (size_t i = 0; i < raw.size(); ++i) {
        tempX = alloc::boxElement(raw[i].x, raw[i].x_kind);
        tempY = alloc::boxElement(raw[i].y, raw[i].y_kind);
        results[i] = func(allocator.resolve(tempX), allocator.resolve(tempY));
    }

    rs.restoreStackRangePoint(saved);
    return alloc::listFromPointers(results);
}

HPointer map3(Map3Func func, HPointer xs, HPointer ys, HPointer zs) {
    if (alloc::isNil(xs) || alloc::isNil(ys) || alloc::isNil(zs)) {
        return alloc::listNil();
    }

    auto& allocator = Allocator::instance();
    struct Raw3 { Unboxable x; u8 xk; Unboxable y; u8 yk; Unboxable z; u8 zk; };
    std::vector<Raw3> raw;
    {
        alloc::ListCursor cx(xs);
        alloc::ListCursor cy(ys);
        alloc::ListCursor cz(zs);
        while (!cx.done() && !cy.done() && !cz.done()) {
            raw.push_back({cx.current(), cx.currentKind(),
                           cy.current(), cy.currentKind(),
                           cz.current(), cz.currentKind()});
            cx.next(); cy.next(); cz.next();
        }
    }
    if (raw.empty()) return alloc::listNil();

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& r : raw) {
        if (r.xk == 0) rs.pushStackRootRange(&r.x.p, 1, 1);
        if (r.yk == 0) rs.pushStackRootRange(&r.y.p, 1, 1);
        if (r.zk == 0) rs.pushStackRootRange(&r.z.p, 1, 1);
    }
    std::vector<HPointer> results(raw.size(), alloc::listNil());
    for (auto& hp : results) rs.pushStackRootRange(&hp, 1, 1);
    HPointer tX = alloc::listNil(), tY = alloc::listNil(), tZ = alloc::listNil();
    rs.pushStackRootRange(&tX, 1, 1); rs.pushStackRootRange(&tY, 1, 1); rs.pushStackRootRange(&tZ, 1, 1);

    for (size_t i = 0; i < raw.size(); ++i) {
        tX = alloc::boxElement(raw[i].x, raw[i].xk);
        tY = alloc::boxElement(raw[i].y, raw[i].yk);
        tZ = alloc::boxElement(raw[i].z, raw[i].zk);
        results[i] = func(allocator.resolve(tX), allocator.resolve(tY), allocator.resolve(tZ));
    }

    rs.restoreStackRangePoint(saved);
    return alloc::listFromPointers(results);
}

HPointer map4(Map4Func func, HPointer ws, HPointer xs, HPointer ys, HPointer zs) {
    if (alloc::isNil(ws) || alloc::isNil(xs) || alloc::isNil(ys) || alloc::isNil(zs)) {
        return alloc::listNil();
    }

    auto& allocator = Allocator::instance();
    struct Raw4 { Unboxable w; u8 wk; Unboxable x; u8 xk; Unboxable y; u8 yk; Unboxable z; u8 zk; };
    std::vector<Raw4> raw;
    {
        alloc::ListCursor cw(ws);
        alloc::ListCursor cx(xs);
        alloc::ListCursor cy(ys);
        alloc::ListCursor cz(zs);
        while (!cw.done() && !cx.done() && !cy.done() && !cz.done()) {
            raw.push_back({cw.current(), cw.currentKind(),
                           cx.current(), cx.currentKind(),
                           cy.current(), cy.currentKind(),
                           cz.current(), cz.currentKind()});
            cw.next(); cx.next(); cy.next(); cz.next();
        }
    }
    if (raw.empty()) return alloc::listNil();

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& r : raw) {
        if (r.wk == 0) rs.pushStackRootRange(&r.w.p, 1, 1);
        if (r.xk == 0) rs.pushStackRootRange(&r.x.p, 1, 1);
        if (r.yk == 0) rs.pushStackRootRange(&r.y.p, 1, 1);
        if (r.zk == 0) rs.pushStackRootRange(&r.z.p, 1, 1);
    }
    std::vector<HPointer> results(raw.size(), alloc::listNil());
    for (auto& hp : results) rs.pushStackRootRange(&hp, 1, 1);
    HPointer tW = alloc::listNil(), tX = alloc::listNil(), tY = alloc::listNil(), tZ = alloc::listNil();
    rs.pushStackRootRange(&tW, 1, 1); rs.pushStackRootRange(&tX, 1, 1); rs.pushStackRootRange(&tY, 1, 1); rs.pushStackRootRange(&tZ, 1, 1);

    for (size_t i = 0; i < raw.size(); ++i) {
        tW = alloc::boxElement(raw[i].w, raw[i].wk);
        tX = alloc::boxElement(raw[i].x, raw[i].xk);
        tY = alloc::boxElement(raw[i].y, raw[i].yk);
        tZ = alloc::boxElement(raw[i].z, raw[i].zk);
        results[i] = func(allocator.resolve(tW), allocator.resolve(tX),
                          allocator.resolve(tY), allocator.resolve(tZ));
    }
    rs.restoreStackRangePoint(saved);
    return alloc::listFromPointers(results);
}

HPointer map5(Map5Func func, HPointer vs, HPointer ws, HPointer xs, HPointer ys, HPointer zs) {
    if (alloc::isNil(vs) || alloc::isNil(ws) || alloc::isNil(xs) || alloc::isNil(ys) || alloc::isNil(zs)) {
        return alloc::listNil();
    }

    auto& allocator = Allocator::instance();
    struct Raw5 { Unboxable v; u8 vk; Unboxable w; u8 wk; Unboxable x; u8 xk; Unboxable y; u8 yk; Unboxable z; u8 zk; };
    std::vector<Raw5> raw;
    {
        alloc::ListCursor cv(vs);
        alloc::ListCursor cw(ws);
        alloc::ListCursor cx(xs);
        alloc::ListCursor cy(ys);
        alloc::ListCursor cz(zs);
        while (!cv.done() && !cw.done() && !cx.done() && !cy.done() &&
               !cz.done()) {
            raw.push_back({cv.current(), cv.currentKind(),
                           cw.current(), cw.currentKind(),
                           cx.current(), cx.currentKind(),
                           cy.current(), cy.currentKind(),
                           cz.current(), cz.currentKind()});
            cv.next(); cw.next(); cx.next(); cy.next(); cz.next();
        }
    }
    if (raw.empty()) return alloc::listNil();

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (auto& r : raw) {
        if (r.vk == 0) rs.pushStackRootRange(&r.v.p, 1, 1);
        if (r.wk == 0) rs.pushStackRootRange(&r.w.p, 1, 1);
        if (r.xk == 0) rs.pushStackRootRange(&r.x.p, 1, 1);
        if (r.yk == 0) rs.pushStackRootRange(&r.y.p, 1, 1);
        if (r.zk == 0) rs.pushStackRootRange(&r.z.p, 1, 1);
    }
    std::vector<HPointer> results(raw.size(), alloc::listNil());
    for (auto& hp : results) rs.pushStackRootRange(&hp, 1, 1);
    HPointer tV = alloc::listNil(), tW = alloc::listNil(), tX = alloc::listNil();
    HPointer tY = alloc::listNil(), tZ = alloc::listNil();
    rs.pushStackRootRange(&tV, 1, 1); rs.pushStackRootRange(&tW, 1, 1); rs.pushStackRootRange(&tX, 1, 1);
    rs.pushStackRootRange(&tY, 1, 1); rs.pushStackRootRange(&tZ, 1, 1);

    for (size_t i = 0; i < raw.size(); ++i) {
        tV = alloc::boxElement(raw[i].v, raw[i].vk);
        tW = alloc::boxElement(raw[i].w, raw[i].wk);
        tX = alloc::boxElement(raw[i].x, raw[i].xk);
        tY = alloc::boxElement(raw[i].y, raw[i].yk);
        tZ = alloc::boxElement(raw[i].z, raw[i].zk);
        results[i] = func(allocator.resolve(tV), allocator.resolve(tW), allocator.resolve(tX),
                          allocator.resolve(tY), allocator.resolve(tZ));
    }
    rs.restoreStackRangePoint(saved);
    return alloc::listFromPointers(results);
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
