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
    // Convert list to vector, boxing any unboxed values.
    auto pairs = ListOps::toVector(list);
    std::vector<HPointer> result(pairs.size(), alloc::listNil());

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRootPoint();
    for (auto& hp : result) rs.pushStackRoot(&hp);

    for (size_t i = 0; i < pairs.size(); ++i) {
        if (pairs[i].second) {
            result[i] = pairs[i].first.p;
        } else {
            result[i] = alloc::allocInt(pairs[i].first.i);
        }
    }

    rs.restoreStackRootPoint(saved);
    return result;
}

// ============================================================================
// Map Operations (multiple lists)
// ============================================================================

HPointer map2(Map2Func func, HPointer xs, HPointer ys) {
    if (alloc::isNil(xs) || alloc::isNil(ys)) return alloc::listNil();

    auto& allocator = Allocator::instance();

    // Phase 1: collect raw values (no allocation)
    struct RawPair { Unboxable x; bool x_boxed; Unboxable y; bool y_boxed; };
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
        raw.push_back({cX->head, !(hdrX->unboxed & 1), cY->head, !(hdrY->unboxed & 1)});
        currX = cX->tail;
        currY = cY->tail;
    }
    if (raw.empty()) return alloc::listNil();

    // Phase 2: build with rooting
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRootPoint();
    for (auto& r : raw) {
        if (r.x_boxed) rs.pushStackRoot(&r.x.p);
        if (r.y_boxed) rs.pushStackRoot(&r.y.p);
    }
    std::vector<HPointer> results(raw.size(), alloc::listNil());
    for (auto& hp : results) rs.pushStackRoot(&hp);
    HPointer tempX = alloc::listNil(), tempY = alloc::listNil();
    rs.pushStackRoot(&tempX);
    rs.pushStackRoot(&tempY);

    for (size_t i = 0; i < raw.size(); ++i) {
        tempX = raw[i].x_boxed ? raw[i].x.p : alloc::allocInt(raw[i].x.i);
        tempY = raw[i].y_boxed ? raw[i].y.p : alloc::allocInt(raw[i].y.i);
        results[i] = func(allocator.resolve(tempX), allocator.resolve(tempY));
    }

    rs.restoreStackRootPoint(saved);
    return alloc::listFromPointers(results);
}

HPointer map3(Map3Func func, HPointer xs, HPointer ys, HPointer zs) {
    if (alloc::isNil(xs) || alloc::isNil(ys) || alloc::isNil(zs)) {
        return alloc::listNil();
    }

    auto& allocator = Allocator::instance();
    struct Raw3 { Unboxable x; bool xb; Unboxable y; bool yb; Unboxable z; bool zb; };
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
        raw.push_back({cX->head, !(hdrX->unboxed & 1),
                        cY->head, !(hdrY->unboxed & 1),
                        cZ->head, !(hdrZ->unboxed & 1)});
        currX = cX->tail; currY = cY->tail; currZ = cZ->tail;
    }
    if (raw.empty()) return alloc::listNil();

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRootPoint();
    for (auto& r : raw) {
        if (r.xb) rs.pushStackRoot(&r.x.p);
        if (r.yb) rs.pushStackRoot(&r.y.p);
        if (r.zb) rs.pushStackRoot(&r.z.p);
    }
    std::vector<HPointer> results(raw.size(), alloc::listNil());
    for (auto& hp : results) rs.pushStackRoot(&hp);
    HPointer tX = alloc::listNil(), tY = alloc::listNil(), tZ = alloc::listNil();
    rs.pushStackRoot(&tX); rs.pushStackRoot(&tY); rs.pushStackRoot(&tZ);

    for (size_t i = 0; i < raw.size(); ++i) {
        tX = raw[i].xb ? raw[i].x.p : alloc::allocInt(raw[i].x.i);
        tY = raw[i].yb ? raw[i].y.p : alloc::allocInt(raw[i].y.i);
        tZ = raw[i].zb ? raw[i].z.p : alloc::allocInt(raw[i].z.i);
        results[i] = func(allocator.resolve(tX), allocator.resolve(tY), allocator.resolve(tZ));
    }

    rs.restoreStackRootPoint(saved);
    return alloc::listFromPointers(results);
}

HPointer map4(Map4Func func, HPointer ws, HPointer xs, HPointer ys, HPointer zs) {
    if (alloc::isNil(ws) || alloc::isNil(xs) || alloc::isNil(ys) || alloc::isNil(zs)) {
        return alloc::listNil();
    }

    auto& allocator = Allocator::instance();
    struct Raw4 { Unboxable w; bool wb; Unboxable x; bool xb; Unboxable y; bool yb; Unboxable z; bool zb; };
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
        raw.push_back({dW->head, !(hW->unboxed & 1), dX->head, !(hX->unboxed & 1),
                        dY->head, !(hY->unboxed & 1), dZ->head, !(hZ->unboxed & 1)});
        cW = dW->tail; cX = dX->tail; cY = dY->tail; cZ = dZ->tail;
    }
    if (raw.empty()) return alloc::listNil();

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRootPoint();
    for (auto& r : raw) {
        if (r.wb) rs.pushStackRoot(&r.w.p); if (r.xb) rs.pushStackRoot(&r.x.p);
        if (r.yb) rs.pushStackRoot(&r.y.p); if (r.zb) rs.pushStackRoot(&r.z.p);
    }
    std::vector<HPointer> results(raw.size(), alloc::listNil());
    for (auto& hp : results) rs.pushStackRoot(&hp);
    HPointer tW = alloc::listNil(), tX = alloc::listNil(), tY = alloc::listNil(), tZ = alloc::listNil();
    rs.pushStackRoot(&tW); rs.pushStackRoot(&tX); rs.pushStackRoot(&tY); rs.pushStackRoot(&tZ);

    for (size_t i = 0; i < raw.size(); ++i) {
        tW = raw[i].wb ? raw[i].w.p : alloc::allocInt(raw[i].w.i);
        tX = raw[i].xb ? raw[i].x.p : alloc::allocInt(raw[i].x.i);
        tY = raw[i].yb ? raw[i].y.p : alloc::allocInt(raw[i].y.i);
        tZ = raw[i].zb ? raw[i].z.p : alloc::allocInt(raw[i].z.i);
        results[i] = func(allocator.resolve(tW), allocator.resolve(tX),
                          allocator.resolve(tY), allocator.resolve(tZ));
    }
    rs.restoreStackRootPoint(saved);
    return alloc::listFromPointers(results);
}

HPointer map5(Map5Func func, HPointer vs, HPointer ws, HPointer xs, HPointer ys, HPointer zs) {
    if (alloc::isNil(vs) || alloc::isNil(ws) || alloc::isNil(xs) || alloc::isNil(ys) || alloc::isNil(zs)) {
        return alloc::listNil();
    }

    auto& allocator = Allocator::instance();
    struct Raw5 { Unboxable v; bool vb; Unboxable w; bool wb; Unboxable x; bool xb; Unboxable y; bool yb; Unboxable z; bool zb; };
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
        raw.push_back({dV->head, !(hV->unboxed & 1), dW->head, !(hW->unboxed & 1),
                        dX->head, !(hX->unboxed & 1), dY->head, !(hY->unboxed & 1),
                        dZ->head, !(hZ->unboxed & 1)});
        cV = dV->tail; cW = dW->tail; cX = dX->tail; cY = dY->tail; cZ = dZ->tail;
    }
    if (raw.empty()) return alloc::listNil();

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRootPoint();
    for (auto& r : raw) {
        if (r.vb) rs.pushStackRoot(&r.v.p); if (r.wb) rs.pushStackRoot(&r.w.p);
        if (r.xb) rs.pushStackRoot(&r.x.p); if (r.yb) rs.pushStackRoot(&r.y.p);
        if (r.zb) rs.pushStackRoot(&r.z.p);
    }
    std::vector<HPointer> results(raw.size(), alloc::listNil());
    for (auto& hp : results) rs.pushStackRoot(&hp);
    HPointer tV = alloc::listNil(), tW = alloc::listNil(), tX = alloc::listNil();
    HPointer tY = alloc::listNil(), tZ = alloc::listNil();
    rs.pushStackRoot(&tV); rs.pushStackRoot(&tW); rs.pushStackRoot(&tX);
    rs.pushStackRoot(&tY); rs.pushStackRoot(&tZ);

    for (size_t i = 0; i < raw.size(); ++i) {
        tV = raw[i].vb ? raw[i].v.p : alloc::allocInt(raw[i].v.i);
        tW = raw[i].wb ? raw[i].w.p : alloc::allocInt(raw[i].w.i);
        tX = raw[i].xb ? raw[i].x.p : alloc::allocInt(raw[i].x.i);
        tY = raw[i].yb ? raw[i].y.p : alloc::allocInt(raw[i].y.i);
        tZ = raw[i].zb ? raw[i].z.p : alloc::allocInt(raw[i].z.i);
        results[i] = func(allocator.resolve(tV), allocator.resolve(tW), allocator.resolve(tX),
                          allocator.resolve(tY), allocator.resolve(tZ));
    }
    rs.restoreStackRootPoint(saved);
    return alloc::listFromPointers(results);
}

// ============================================================================
// Sorting
// ============================================================================

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

} // namespace Elm::Kernel::List
