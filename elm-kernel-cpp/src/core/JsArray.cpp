/**
 * Elm Kernel JsArray Module - Runtime Heap Integration
 *
 * This module provides array operations using the GC-managed ElmArray type.
 * Operations maintain immutable semantics by creating new arrays.
 */

#include "JsArray.hpp"
#include "allocator/Allocator.hpp"

namespace Elm::Kernel::JsArray {

// Helper to push a boxed HPointer value
static void pushBoxed(HPointer arr, HPointer value) {
    auto& allocator = Allocator::instance();
    void* arrObj = allocator.resolve(arr);
    alloc::arrayPush(arrObj, alloc::boxed(value), true);
}

// ============================================================================
// Construction
// ============================================================================

HPointer empty() {
    return alloc::allocArray(0);
}

HPointer singleton(HPointer value) {
    HPointer arr = alloc::allocArray(1);
    pushBoxed(arr, value);
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

    for (u32 i = 0; i < size; ++i) {
        HPointer value = func(offset + i);
        pushBoxed(arr, value);
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
    // Create a copy with the modified element
    ElmArray* src = static_cast<ElmArray*>(array);
    u32 len = src->length;

    HPointer newArr = alloc::allocArray(len);
    auto& allocator = Allocator::instance();
    bool srcUnboxed = alloc::arrayIsUnboxed(array);

    // Copy elements
    for (u32 i = 0; i < len; ++i) {
        void* dstObj = allocator.resolve(newArr);

        if (i == index) {
            alloc::arrayPush(dstObj, alloc::boxed(value), true);
        } else {
            Unboxable elem = src->elements[i];
            alloc::arrayPush(dstObj, elem, !srcUnboxed);
        }
    }

    return newArr;
}

// ============================================================================
// Modification
// ============================================================================

HPointer push(HPointer value, void* array) {
    ElmArray* src = static_cast<ElmArray*>(array);
    u32 len = src->length;

    // Create a new array with copy + new element
    HPointer newArr = alloc::allocArray(len + 1);
    auto& allocator = Allocator::instance();
    bool srcUnboxed = alloc::arrayIsUnboxed(array);

    // Copy existing elements
    for (u32 i = 0; i < len; ++i) {
        void* dstObj = allocator.resolve(newArr);
        Unboxable elem = src->elements[i];
        alloc::arrayPush(dstObj, elem, !srcUnboxed);
    }

    // Add new element
    void* dstObj = allocator.resolve(newArr);
    alloc::arrayPush(dstObj, alloc::boxed(value), true);

    return newArr;
}

// ============================================================================
// Folding
// ============================================================================

HPointer foldl(FoldFunc func, HPointer acc, void* array) {
    auto& allocator = Allocator::instance();
    ElmArray* arr = static_cast<ElmArray*>(array);
    u32 len = arr->length;
    bool srcUnboxed = alloc::arrayIsUnboxed(array);

    HPointer result = acc;

    for (u32 i = 0; i < len; ++i) {
        // Get element and resolve if pointer
        void* elem;
        if (srcUnboxed) {
            // Box the value for the callback
            HPointer boxed = alloc::allocInt(arr->elements[i].i);
            elem = allocator.resolve(boxed);
        } else {
            elem = allocator.resolve(arr->elements[i].p);
        }

        void* accObj = allocator.resolve(result);
        result = func(elem, accObj);
    }

    return result;
}

HPointer foldr(FoldFunc func, HPointer acc, void* array) {
    auto& allocator = Allocator::instance();
    ElmArray* arr = static_cast<ElmArray*>(array);
    u32 len = arr->length;
    bool srcUnboxed = alloc::arrayIsUnboxed(array);

    HPointer result = acc;

    for (u32 i = len; i > 0; --i) {
        u32 idx = i - 1;

        // Get element and resolve if pointer
        void* elem;
        if (srcUnboxed) {
            // Box the value for the callback
            HPointer boxed = alloc::allocInt(arr->elements[idx].i);
            elem = allocator.resolve(boxed);
        } else {
            elem = allocator.resolve(arr->elements[idx].p);
        }

        void* accObj = allocator.resolve(result);
        result = func(elem, accObj);
    }

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

    HPointer newArr = alloc::allocArray(len);

    for (u32 i = 0; i < len; ++i) {
        // Get element and resolve if pointer
        void* elem;
        if (srcUnboxed) {
            // Box the value for the callback
            HPointer boxed = alloc::allocInt(arr->elements[i].i);
            elem = allocator.resolve(boxed);
        } else {
            elem = allocator.resolve(arr->elements[i].p);
        }

        HPointer result = func(elem);
        void* dstObj = allocator.resolve(newArr);
        alloc::arrayPush(dstObj, alloc::boxed(result), true);
    }

    return newArr;
}

HPointer indexedMap(IndexedMapFunc func, u32 offset, void* array) {
    auto& allocator = Allocator::instance();
    ElmArray* arr = static_cast<ElmArray*>(array);
    u32 len = arr->length;
    bool srcUnboxed = alloc::arrayIsUnboxed(array);

    HPointer newArr = alloc::allocArray(len);

    for (u32 i = 0; i < len; ++i) {
        // Get element and resolve if pointer
        void* elem;
        if (srcUnboxed) {
            // Box the value for the callback
            HPointer boxed = alloc::allocInt(arr->elements[i].i);
            elem = allocator.resolve(boxed);
        } else {
            elem = allocator.resolve(arr->elements[i].p);
        }

        HPointer result = func(offset + i, elem);
        void* dstObj = allocator.resolve(newArr);
        alloc::arrayPush(dstObj, alloc::boxed(result), true);
    }

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
    HPointer newArr = alloc::allocArray(newLen);
    auto& allocator = Allocator::instance();
    bool srcUnboxed = alloc::arrayIsUnboxed(array);

    for (i64 i = start; i < end; ++i) {
        u32 idx = static_cast<u32>(i);
        Unboxable elem = arr->elements[idx];

        void* dstObj = allocator.resolve(newArr);
        alloc::arrayPush(dstObj, elem, !srcUnboxed);
    }

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
    HPointer newArr = alloc::allocArray(totalLen);
    auto& allocator = Allocator::instance();
    bool destUnboxed = alloc::arrayIsUnboxed(dest);
    bool srcUnboxed = alloc::arrayIsUnboxed(source);

    // Copy all from dest
    for (u32 i = 0; i < destLen; ++i) {
        Unboxable elem = dstArr->elements[i];

        void* resultObj = allocator.resolve(newArr);
        alloc::arrayPush(resultObj, elem, !destUnboxed);
    }

    // Copy itemsToCopy from source
    for (u32 i = 0; i < itemsToCopy; ++i) {
        Unboxable elem = srcArr->elements[i];

        void* resultObj = allocator.resolve(newArr);
        alloc::arrayPush(resultObj, elem, !srcUnboxed);
    }

    return newArr;
}

} // namespace Elm::Kernel::JsArray
