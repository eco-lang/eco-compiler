/**
 * Elm Kernel JsArray Module - Runtime Heap Integration
 *
 * This module provides array operations using the GC-managed ElmArray type.
 * Operations maintain immutable semantics by creating new arrays.
 */

#include "JsArray.hpp"
#include "allocator/Allocator.hpp"

namespace Elm::Kernel::JsArray {

// ============================================================================
// Construction
// ============================================================================

HPointer empty() {
    return alloc::allocArray(0);
}

HPointer singleton(HPointer value) {
    Elm::StackRootGuard guard(&value);
    HPointer arr = alloc::allocArray(1);
    void* arrObj = Allocator::instance().resolve(arr);
    alloc::arrayPush(arrObj, alloc::boxed(value), true);
    return arr;
}

// ============================================================================
// Length
// ============================================================================

u32 length(void* array) {
    return alloc::arrayLength(array);
}

// ============================================================================
// Initialization
// ============================================================================

HPointer initialize(u32 size, u32 offset, InitFunc func) {
    HPointer arr = alloc::allocArray(size);
    // Root arr across func calls (func may allocate and trigger GC)
    Elm::StackRootGuard guard(&arr);

    for (u32 i = 0; i < size; ++i) {
        HPointer value = func(offset + i);
        void* arrObj = Allocator::instance().resolve(arr);
        alloc::arrayPush(arrObj, alloc::boxed(value), true);
    }

    return arr;
}

HPointer initializeFromList(u32 max, HPointer list) {
    auto& allocator = Allocator::instance();

    HPointer arr = alloc::allocArray(max);

    u32 count = 0;
    HPointer current = list;

    while (count < max && !alloc::isNil(current)) {
        void* cell = allocator.resolve(current);
        if (!cell) break;

        Cons* c = static_cast<Cons*>(cell);
        Header* hdr = static_cast<Header*>(cell);

        // Check if head is unboxed
        bool isBoxed = !(hdr->unboxed & 1);
        void* arrObj = allocator.resolve(arr);

        if (isBoxed) {
            alloc::arrayPush(arrObj, alloc::boxed(c->head.p), true);
        } else {
            // For unboxed values, we can store them directly
            alloc::arrayPush(arrObj, c->head, false);
        }

        current = c->tail;
        ++count;
    }

    // Return Tuple2(array, remaining_list)
    return alloc::tuple2(alloc::boxed(arr), alloc::boxed(current), 0);
}

// ============================================================================
// Element Access
// ============================================================================

Unboxable unsafeGet(u32 index, void* array) {
    return alloc::arrayGet(array, index);
}

HPointer unsafeSet(u32 index, HPointer value, void* array) {
    ElmArray* src = static_cast<ElmArray*>(array);
    u32 len = src->length;
    bool srcUnboxed = alloc::arrayIsUnboxed(array);

    // Copy elements before allocation (void* array can move during GC)
    std::vector<Unboxable> elems(src->elements, src->elements + len);

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRootPoint();
    rs.pushStackRoot(&value);
    if (!srcUnboxed) {
        for (auto& e : elems) rs.pushStackRoot(&e.p);
    }

    HPointer newArr = alloc::allocArray(len);
    auto& allocator = Allocator::instance();

    for (u32 i = 0; i < len; ++i) {
        void* dstObj = allocator.resolve(newArr);
        if (i == index) {
            alloc::arrayPush(dstObj, alloc::boxed(value), true);
        } else {
            alloc::arrayPush(dstObj, elems[i], !srcUnboxed);
        }
    }

    rs.restoreStackRootPoint(saved);
    return newArr;
}

// ============================================================================
// Modification
// ============================================================================

HPointer push(HPointer value, void* array) {
    ElmArray* src = static_cast<ElmArray*>(array);
    u32 len = src->length;
    bool srcUnboxed = alloc::arrayIsUnboxed(array);

    // Copy elements before allocation (void* array can move during GC)
    std::vector<Unboxable> elems(src->elements, src->elements + len);

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRootPoint();
    rs.pushStackRoot(&value);
    if (!srcUnboxed) {
        for (auto& e : elems) rs.pushStackRoot(&e.p);
    }

    HPointer newArr = alloc::allocArray(len + 1);
    auto& allocator = Allocator::instance();

    for (u32 i = 0; i < len; ++i) {
        void* dstObj = allocator.resolve(newArr);
        alloc::arrayPush(dstObj, elems[i], !srcUnboxed);
    }
    void* dstObj = allocator.resolve(newArr);
    alloc::arrayPush(dstObj, alloc::boxed(value), true);

    rs.restoreStackRootPoint(saved);
    return newArr;
}

// ============================================================================
// Folding
// ============================================================================

HPointer foldl(FoldFunc func, HPointer acc, void* array) {
    ElmArray* arr = static_cast<ElmArray*>(array);
    u32 len = arr->length;
    bool srcUnboxed = alloc::arrayIsUnboxed(array);

    // Copy elements before any allocation (void* array can move during GC)
    std::vector<Unboxable> elems(arr->elements, arr->elements + len);

    auto& allocator = Allocator::instance();
    auto& rs = allocator.getRootSet();
    size_t saved = rs.stackRootPoint();
    if (!srcUnboxed) {
        for (auto& e : elems) rs.pushStackRoot(&e.p);
    }

    HPointer result = acc;

    for (u32 i = 0; i < len; ++i) {
        void* elem;
        if (srcUnboxed) {
            HPointer boxed = alloc::allocInt(elems[i].i);
            elem = allocator.resolve(boxed);
        } else {
            elem = allocator.resolve(elems[i].p);
        }

        void* accObj = allocator.resolve(result);
        result = func(elem, accObj);
    }

    rs.restoreStackRootPoint(saved);
    return result;
}

HPointer foldr(FoldFunc func, HPointer acc, void* array) {
    ElmArray* arr = static_cast<ElmArray*>(array);
    u32 len = arr->length;
    bool srcUnboxed = alloc::arrayIsUnboxed(array);

    // Copy elements before any allocation (void* array can move during GC)
    std::vector<Unboxable> elems(arr->elements, arr->elements + len);

    auto& allocator = Allocator::instance();
    auto& rs = allocator.getRootSet();
    size_t saved = rs.stackRootPoint();
    if (!srcUnboxed) {
        for (auto& e : elems) rs.pushStackRoot(&e.p);
    }

    HPointer result = acc;

    for (u32 i = len; i > 0; --i) {
        u32 idx = i - 1;

        void* elem;
        if (srcUnboxed) {
            HPointer boxed = alloc::allocInt(elems[idx].i);
            elem = allocator.resolve(boxed);
        } else {
            elem = allocator.resolve(elems[idx].p);
        }

        void* accObj = allocator.resolve(result);
        result = func(elem, accObj);
    }

    rs.restoreStackRootPoint(saved);
    return result;
}

// ============================================================================
// Mapping
// ============================================================================

HPointer map(MapFunc func, void* array) {
    auto& allocator = Allocator::instance();
    ElmArray* arr = static_cast<ElmArray*>(array);
    u32 len = arr->length;
    bool srcUnboxed = alloc::arrayIsUnboxed(array);

    // Copy elements before any allocation (void* array can move during GC)
    std::vector<Unboxable> elems(arr->elements, arr->elements + len);

    auto& rs = allocator.getRootSet();
    size_t saved = rs.stackRootPoint();
    if (!srcUnboxed) {
        for (auto& e : elems) rs.pushStackRoot(&e.p);
    }

    HPointer newArr = alloc::allocArray(len);
    rs.pushStackRoot(&newArr);

    for (u32 i = 0; i < len; ++i) {
        void* elem;
        if (srcUnboxed) {
            HPointer boxed = alloc::allocInt(elems[i].i);
            elem = allocator.resolve(boxed);
        } else {
            elem = allocator.resolve(elems[i].p);
        }

        HPointer result = func(elem);
        void* dstObj = allocator.resolve(newArr);
        alloc::arrayPush(dstObj, alloc::boxed(result), true);
    }

    rs.restoreStackRootPoint(saved);
    return newArr;
}

HPointer indexedMap(IndexedMapFunc func, u32 offset, void* array) {
    auto& allocator = Allocator::instance();
    ElmArray* arr = static_cast<ElmArray*>(array);
    u32 len = arr->length;
    bool srcUnboxed = alloc::arrayIsUnboxed(array);

    // Copy elements before any allocation (void* array can move during GC)
    std::vector<Unboxable> elems(arr->elements, arr->elements + len);

    auto& rs = allocator.getRootSet();
    size_t saved = rs.stackRootPoint();
    if (!srcUnboxed) {
        for (auto& e : elems) rs.pushStackRoot(&e.p);
    }

    HPointer newArr = alloc::allocArray(len);
    rs.pushStackRoot(&newArr);

    for (u32 i = 0; i < len; ++i) {
        void* elem;
        if (srcUnboxed) {
            HPointer boxed = alloc::allocInt(elems[i].i);
            elem = allocator.resolve(boxed);
        } else {
            elem = allocator.resolve(elems[i].p);
        }

        HPointer result = func(offset + i, elem);
        void* dstObj = allocator.resolve(newArr);
        alloc::arrayPush(dstObj, alloc::boxed(result), true);
    }

    rs.restoreStackRootPoint(saved);
    return newArr;
}

// ============================================================================
// Slicing
// ============================================================================

HPointer slice(i64 start, i64 end, void* array) {
    ElmArray* arr = static_cast<ElmArray*>(array);
    i64 len = static_cast<i64>(arr->length);

    // Handle negative indices
    if (start < 0) start = std::max(i64(0), len + start);
    if (end < 0) end = std::max(i64(0), len + end);

    // Clamp to valid range
    start = std::min(start, len);
    end = std::min(end, len);

    if (start >= end) {
        return alloc::allocArray(0);
    }

    u32 newLen = static_cast<u32>(end - start);
    bool srcUnboxed = alloc::arrayIsUnboxed(array);

    // Copy elements before allocation (void* array can move during GC)
    std::vector<Unboxable> elems(arr->elements + start, arr->elements + end);

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRootPoint();
    if (!srcUnboxed) {
        for (auto& e : elems) rs.pushStackRoot(&e.p);
    }

    HPointer newArr = alloc::allocArray(newLen);
    auto& allocator = Allocator::instance();

    for (u32 i = 0; i < newLen; ++i) {
        void* dstObj = allocator.resolve(newArr);
        alloc::arrayPush(dstObj, elems[i], !srcUnboxed);
    }

    rs.restoreStackRootPoint(saved);
    return newArr;
}

HPointer appendN(u32 n, void* dest, void* source) {
    ElmArray* dstArr = static_cast<ElmArray*>(dest);
    ElmArray* srcArr = static_cast<ElmArray*>(source);

    u32 destLen = dstArr->length;
    u32 srcLen = srcArr->length;

    u32 itemsToCopy = (n > destLen) ? n - destLen : 0;
    if (itemsToCopy > srcLen) {
        itemsToCopy = srcLen;
    }

    u32 totalLen = destLen + itemsToCopy;
    bool destUnboxed = alloc::arrayIsUnboxed(dest);
    bool srcUnboxed = alloc::arrayIsUnboxed(source);

    // Copy elements before allocation (void* ptrs can move during GC)
    std::vector<Unboxable> destElems(dstArr->elements, dstArr->elements + destLen);
    std::vector<Unboxable> srcElems(srcArr->elements, srcArr->elements + itemsToCopy);

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRootPoint();
    if (!destUnboxed) {
        for (auto& e : destElems) rs.pushStackRoot(&e.p);
    }
    if (!srcUnboxed) {
        for (auto& e : srcElems) rs.pushStackRoot(&e.p);
    }

    HPointer newArr = alloc::allocArray(totalLen);
    auto& allocator = Allocator::instance();

    for (u32 i = 0; i < destLen; ++i) {
        void* resultObj = allocator.resolve(newArr);
        alloc::arrayPush(resultObj, destElems[i], !destUnboxed);
    }
    for (u32 i = 0; i < itemsToCopy; ++i) {
        void* resultObj = allocator.resolve(newArr);
        alloc::arrayPush(resultObj, srcElems[i], !srcUnboxed);
    }

    rs.restoreStackRootPoint(saved);
    return newArr;
}

} // namespace Elm::Kernel::JsArray
