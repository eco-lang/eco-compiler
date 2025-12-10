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
    std::vector<HPointer> result;
    result.reserve(pairs.size());

    for (const auto& [val, is_boxed] : pairs) {
        if (is_boxed) {
            result.push_back(val.p);
        } else {
            result.push_back(alloc::allocInt(val.i));
        }
    }

    return result;
}

// ============================================================================
// Map Operations (multiple lists)
// ============================================================================

HPointer map2(Map2Func func, HPointer xs, HPointer ys) {
    if (alloc::isNil(xs) || alloc::isNil(ys)) return alloc::listNil();

    auto& allocator = Allocator::instance();
    std::vector<HPointer> results;

    HPointer currX = xs;
    HPointer currY = ys;

    while (!alloc::isNil(currX) && !alloc::isNil(currY)) {
        void* cellX = allocator.resolve(currX);
        void* cellY = allocator.resolve(currY);
        if (!cellX || !cellY) break;

        Cons* cX = static_cast<Cons*>(cellX);
        Cons* cY = static_cast<Cons*>(cellY);
        Header* hdrX = static_cast<Header*>(cellX);
        Header* hdrY = static_cast<Header*>(cellY);

        // Resolve elements, boxing unboxed values.
        void* elemX;
        void* elemY;

        if (!(hdrX->unboxed & 1)) {
            elemX = allocator.resolve(cX->head.p);
        } else {
            HPointer boxed = alloc::allocInt(cX->head.i);
            elemX = allocator.resolve(boxed);
        }

        if (!(hdrY->unboxed & 1)) {
            elemY = allocator.resolve(cY->head.p);
        } else {
            HPointer boxed = alloc::allocInt(cY->head.i);
            elemY = allocator.resolve(boxed);
        }

        HPointer result = func(elemX, elemY);
        results.push_back(result);

        currX = cX->tail;
        currY = cY->tail;
    }

    return alloc::listFromPointers(results);
}

HPointer map3(Map3Func func, HPointer xs, HPointer ys, HPointer zs) {
    if (alloc::isNil(xs) || alloc::isNil(ys) || alloc::isNil(zs)) {
        return alloc::listNil();
    }

    auto& allocator = Allocator::instance();
    std::vector<HPointer> results;

    HPointer currX = xs;
    HPointer currY = ys;
    HPointer currZ = zs;

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

        // Resolve elements, boxing unboxed values.
        void* elemX = (!(hdrX->unboxed & 1)) ? allocator.resolve(cX->head.p)
                     : allocator.resolve(alloc::allocInt(cX->head.i));
        void* elemY = (!(hdrY->unboxed & 1)) ? allocator.resolve(cY->head.p)
                     : allocator.resolve(alloc::allocInt(cY->head.i));
        void* elemZ = (!(hdrZ->unboxed & 1)) ? allocator.resolve(cZ->head.p)
                     : allocator.resolve(alloc::allocInt(cZ->head.i));

        HPointer result = func(elemX, elemY, elemZ);
        results.push_back(result);

        currX = cX->tail;
        currY = cY->tail;
        currZ = cZ->tail;
    }

    return alloc::listFromPointers(results);
}

HPointer map4(Map4Func func, HPointer ws, HPointer xs, HPointer ys, HPointer zs) {
    if (alloc::isNil(ws) || alloc::isNil(xs) || alloc::isNil(ys) || alloc::isNil(zs)) {
        return alloc::listNil();
    }

    auto& allocator = Allocator::instance();
    std::vector<HPointer> results;

    HPointer currW = ws;
    HPointer currX = xs;
    HPointer currY = ys;
    HPointer currZ = zs;

    while (!alloc::isNil(currW) && !alloc::isNil(currX) && !alloc::isNil(currY) && !alloc::isNil(currZ)) {
        void* cellW = allocator.resolve(currW);
        void* cellX = allocator.resolve(currX);
        void* cellY = allocator.resolve(currY);
        void* cellZ = allocator.resolve(currZ);
        if (!cellW || !cellX || !cellY || !cellZ) break;

        Cons* cW = static_cast<Cons*>(cellW);
        Cons* cX = static_cast<Cons*>(cellX);
        Cons* cY = static_cast<Cons*>(cellY);
        Cons* cZ = static_cast<Cons*>(cellZ);
        Header* hdrW = static_cast<Header*>(cellW);
        Header* hdrX = static_cast<Header*>(cellX);
        Header* hdrY = static_cast<Header*>(cellY);
        Header* hdrZ = static_cast<Header*>(cellZ);

        void* elemW = (!(hdrW->unboxed & 1)) ? allocator.resolve(cW->head.p)
                     : allocator.resolve(alloc::allocInt(cW->head.i));
        void* elemX = (!(hdrX->unboxed & 1)) ? allocator.resolve(cX->head.p)
                     : allocator.resolve(alloc::allocInt(cX->head.i));
        void* elemY = (!(hdrY->unboxed & 1)) ? allocator.resolve(cY->head.p)
                     : allocator.resolve(alloc::allocInt(cY->head.i));
        void* elemZ = (!(hdrZ->unboxed & 1)) ? allocator.resolve(cZ->head.p)
                     : allocator.resolve(alloc::allocInt(cZ->head.i));

        HPointer result = func(elemW, elemX, elemY, elemZ);
        results.push_back(result);

        currW = cW->tail;
        currX = cX->tail;
        currY = cY->tail;
        currZ = cZ->tail;
    }

    return alloc::listFromPointers(results);
}

HPointer map5(Map5Func func, HPointer vs, HPointer ws, HPointer xs, HPointer ys, HPointer zs) {
    if (alloc::isNil(vs) || alloc::isNil(ws) || alloc::isNil(xs) || alloc::isNil(ys) || alloc::isNil(zs)) {
        return alloc::listNil();
    }

    auto& allocator = Allocator::instance();
    std::vector<HPointer> results;

    HPointer currV = vs;
    HPointer currW = ws;
    HPointer currX = xs;
    HPointer currY = ys;
    HPointer currZ = zs;

    while (!alloc::isNil(currV) && !alloc::isNil(currW) && !alloc::isNil(currX) &&
           !alloc::isNil(currY) && !alloc::isNil(currZ)) {
        void* cellV = allocator.resolve(currV);
        void* cellW = allocator.resolve(currW);
        void* cellX = allocator.resolve(currX);
        void* cellY = allocator.resolve(currY);
        void* cellZ = allocator.resolve(currZ);
        if (!cellV || !cellW || !cellX || !cellY || !cellZ) break;

        Cons* cV = static_cast<Cons*>(cellV);
        Cons* cW = static_cast<Cons*>(cellW);
        Cons* cX = static_cast<Cons*>(cellX);
        Cons* cY = static_cast<Cons*>(cellY);
        Cons* cZ = static_cast<Cons*>(cellZ);
        Header* hdrV = static_cast<Header*>(cellV);
        Header* hdrW = static_cast<Header*>(cellW);
        Header* hdrX = static_cast<Header*>(cellX);
        Header* hdrY = static_cast<Header*>(cellY);
        Header* hdrZ = static_cast<Header*>(cellZ);

        void* elemV = (!(hdrV->unboxed & 1)) ? allocator.resolve(cV->head.p)
                     : allocator.resolve(alloc::allocInt(cV->head.i));
        void* elemW = (!(hdrW->unboxed & 1)) ? allocator.resolve(cW->head.p)
                     : allocator.resolve(alloc::allocInt(cW->head.i));
        void* elemX = (!(hdrX->unboxed & 1)) ? allocator.resolve(cX->head.p)
                     : allocator.resolve(alloc::allocInt(cX->head.i));
        void* elemY = (!(hdrY->unboxed & 1)) ? allocator.resolve(cY->head.p)
                     : allocator.resolve(alloc::allocInt(cY->head.i));
        void* elemZ = (!(hdrZ->unboxed & 1)) ? allocator.resolve(cZ->head.p)
                     : allocator.resolve(alloc::allocInt(cZ->head.i));

        HPointer result = func(elemV, elemW, elemX, elemY, elemZ);
        results.push_back(result);

        currV = cV->tail;
        currW = cW->tail;
        currX = cX->tail;
        currY = cY->tail;
        currZ = cZ->tail;
    }

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
