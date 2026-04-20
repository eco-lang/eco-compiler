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
    HPointer current = list;
    while (!alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;
        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = static_cast<Header*>(cell);
        rawElems.push_back({c->head, static_cast<u8>(tupleFieldKind(hdr->unboxed, 0))});
        current = c->tail;
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
    HPointer currX = xs, currY = ys;
    while (!alloc::isNil(currX) && !alloc::isNil(currY)) {
        void* cellX = allocator.resolve(currX);
        void* cellY = allocator.resolve(currY);
        if (!cellX || !cellY) break;
        Cons* cX = static_cast<Cons*>(cellX);
        Cons* cY = static_cast<Cons*>(cellY);
        Header* hdrX = static_cast<Header*>(cellX);
        Header* hdrY = static_cast<Header*>(cellY);
        raw.push_back({cX->head, static_cast<u8>(tupleFieldKind(hdrX->unboxed, 0)),
                        cY->head, static_cast<u8>(tupleFieldKind(hdrY->unboxed, 0))});
        currX = cX->tail;
        currY = cY->tail;
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
    HPointer currX = xs, currY = ys, currZ = zs;
    while (!alloc::isNil(currX) && !alloc::isNil(currY) && !alloc::isNil(currZ)) {
        void* cellX = allocator.resolve(currX);
        void* cellY = allocator.resolve(currY);
        void* cellZ = allocator.resolve(currZ);
        if (!cellX || !cellY || !cellZ) break;
        Cons* cX = static_cast<Cons*>(cellX);
        Cons* cY = static_cast<Cons*>(cellY);
        Cons* cZ = static_cast<Cons*>(cellZ);
        Header* hdrX = static_cast<Header*>(cellX);
        Header* hdrY = static_cast<Header*>(cellY);
        Header* hdrZ = static_cast<Header*>(cellZ);
        raw.push_back({cX->head, static_cast<u8>(tupleFieldKind(hdrX->unboxed, 0)),
                        cY->head, static_cast<u8>(tupleFieldKind(hdrY->unboxed, 0)),
                        cZ->head, static_cast<u8>(tupleFieldKind(hdrZ->unboxed, 0))});
        currX = cX->tail; currY = cY->tail; currZ = cZ->tail;
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
    HPointer cW = ws, cX = xs, cY = ys, cZ = zs;
    while (!alloc::isNil(cW) && !alloc::isNil(cX) && !alloc::isNil(cY) && !alloc::isNil(cZ)) {
        void* cellW = allocator.resolve(cW); void* cellX = allocator.resolve(cX);
        void* cellY = allocator.resolve(cY); void* cellZ = allocator.resolve(cZ);
        if (!cellW || !cellX || !cellY || !cellZ) break;
        Cons* dW = static_cast<Cons*>(cellW); Cons* dX = static_cast<Cons*>(cellX);
        Cons* dY = static_cast<Cons*>(cellY); Cons* dZ = static_cast<Cons*>(cellZ);
        Header* hW = static_cast<Header*>(cellW); Header* hX = static_cast<Header*>(cellX);
        Header* hY = static_cast<Header*>(cellY); Header* hZ = static_cast<Header*>(cellZ);
        raw.push_back({dW->head, static_cast<u8>(tupleFieldKind(hW->unboxed, 0)),
                        dX->head, static_cast<u8>(tupleFieldKind(hX->unboxed, 0)),
                        dY->head, static_cast<u8>(tupleFieldKind(hY->unboxed, 0)),
                        dZ->head, static_cast<u8>(tupleFieldKind(hZ->unboxed, 0))});
        cW = dW->tail; cX = dX->tail; cY = dY->tail; cZ = dZ->tail;
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
    HPointer cV = vs, cW = ws, cX = xs, cY = ys, cZ = zs;
    while (!alloc::isNil(cV) && !alloc::isNil(cW) && !alloc::isNil(cX) &&
           !alloc::isNil(cY) && !alloc::isNil(cZ)) {
        void* cellV = allocator.resolve(cV); void* cellW = allocator.resolve(cW);
        void* cellX = allocator.resolve(cX); void* cellY = allocator.resolve(cY);
        void* cellZ = allocator.resolve(cZ);
        if (!cellV || !cellW || !cellX || !cellY || !cellZ) break;
        Cons* dV = static_cast<Cons*>(cellV); Cons* dW = static_cast<Cons*>(cellW);
        Cons* dX = static_cast<Cons*>(cellX); Cons* dY = static_cast<Cons*>(cellY);
        Cons* dZ = static_cast<Cons*>(cellZ);
        Header* hV = static_cast<Header*>(cellV); Header* hW = static_cast<Header*>(cellW);
        Header* hX = static_cast<Header*>(cellX); Header* hY = static_cast<Header*>(cellY);
        Header* hZ = static_cast<Header*>(cellZ);
        raw.push_back({dV->head, static_cast<u8>(tupleFieldKind(hV->unboxed, 0)),
                        dW->head, static_cast<u8>(tupleFieldKind(hW->unboxed, 0)),
                        dX->head, static_cast<u8>(tupleFieldKind(hX->unboxed, 0)),
                        dY->head, static_cast<u8>(tupleFieldKind(hY->unboxed, 0)),
                        dZ->head, static_cast<u8>(tupleFieldKind(hZ->unboxed, 0))});
        cV = dV->tail; cW = dW->tail; cX = dX->tail; cY = dY->tail; cZ = dZ->tail;
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
