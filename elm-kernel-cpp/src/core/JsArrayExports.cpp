//===- JsArrayExports.cpp - C-linkage exports for JsArray module -----------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "JsArray.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

uint64_t Elm_Kernel_JsArray_empty() {
    HPointer arr = alloc::allocArray(0);
    return Export::encode(arr);
}

uint64_t Elm_Kernel_JsArray_singleton(uint64_t value) {
    std::vector<HPointer> vals = {Export::decode(value)};
    HPointer arr = alloc::arrayFromPointers(vals);
    return Export::encode(arr);
}

uint32_t Elm_Kernel_JsArray_length(uint64_t array) {
    void* ptr = Export::toPtr(array);
    return static_cast<uint32_t>(alloc::arrayLength(ptr));
}

uint64_t Elm_Kernel_JsArray_unsafeGet(uint32_t index, uint64_t array) {
    void* ptr = Export::toPtr(array);
    Unboxable val = alloc::arrayGet(ptr, index);
    // Assume boxed for safety
    return Export::encode(val.p);
}

uint64_t Elm_Kernel_JsArray_unsafeSet(uint32_t index, uint64_t value, uint64_t array) {
    // Array.set creates a new array (Elm arrays are immutable)
    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;

    HPointer result = alloc::allocArray(len);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    // Copy all elements
    for (uint32_t i = 0; i < len; i++) {
        dst->elements[i] = src->elements[i];
    }
    dst->length = len;
    dst->unboxed = src->unboxed;

    // Set the new value at index
    if (index < len) {
        dst->elements[index].p = Export::decode(value);
        // Mark as boxed
        if (index < 64) {
            dst->unboxed &= ~(1ULL << index);
        }
    }

    return Export::encode(result);
}

uint64_t Elm_Kernel_JsArray_push(uint64_t value, uint64_t array) {
    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;

    HPointer result = alloc::allocArray(len + 1);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    // Copy existing elements
    for (uint32_t i = 0; i < len; i++) {
        dst->elements[i] = src->elements[i];
    }
    // Add new element
    dst->elements[len].p = Export::decode(value);
    dst->length = len + 1;
    dst->unboxed = src->unboxed; // New element is boxed

    return Export::encode(result);
}

uint64_t Elm_Kernel_JsArray_slice(int64_t start, int64_t end, uint64_t array) {
    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    int64_t len = static_cast<int64_t>(src->length);

    // Handle negative indices
    if (start < 0) start += len;
    if (end < 0) end += len;

    // Clamp to bounds
    if (start < 0) start = 0;
    if (end > len) end = len;
    if (start > end) start = end;

    int64_t newLen = end - start;
    HPointer result = alloc::allocArray(static_cast<size_t>(newLen));
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    for (int64_t i = 0; i < newLen; i++) {
        dst->elements[i] = src->elements[start + i];
    }
    dst->length = static_cast<uint32_t>(newLen);
    // Copy relevant unboxed bits (simplified - just set all boxed)
    dst->unboxed = 0;

    return Export::encode(result);
}

uint64_t Elm_Kernel_JsArray_appendN(uint32_t n, uint64_t dest, uint64_t source) {
    void* destPtr = Export::toPtr(dest);
    void* srcPtr = Export::toPtr(source);
    ElmArray* destArr = static_cast<ElmArray*>(destPtr);
    ElmArray* srcArr = static_cast<ElmArray*>(srcPtr);

    uint32_t destLen = destArr->length;
    uint32_t srcLen = srcArr->length;
    uint32_t toCopy = (n < srcLen) ? n : srcLen;
    uint32_t newLen = destLen + toCopy;

    HPointer result = alloc::allocArray(newLen);
    void* resultPtr = Allocator::instance().resolve(result);
    ElmArray* resultArr = static_cast<ElmArray*>(resultPtr);

    // Copy from dest
    for (uint32_t i = 0; i < destLen; i++) {
        resultArr->elements[i] = destArr->elements[i];
    }
    // Copy from source
    for (uint32_t i = 0; i < toCopy; i++) {
        resultArr->elements[destLen + i] = srcArr->elements[i];
    }
    resultArr->length = newLen;
    resultArr->unboxed = 0;

    return Export::encode(result);
}

//===----------------------------------------------------------------------===//
// Higher-order functions (stubs - require closure support)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_JsArray_initialize(uint32_t size, uint32_t offset, uint64_t closure) {
    (void)size;
    (void)offset;
    (void)closure;
    assert(false && "Elm_Kernel_JsArray_initialize not implemented - requires closure calling");
    return 0;
}

uint64_t Elm_Kernel_JsArray_initializeFromList(uint32_t max, uint64_t list) {
    (void)max;
    (void)list;
    assert(false && "Elm_Kernel_JsArray_initializeFromList not implemented");
    return 0;
}

uint64_t Elm_Kernel_JsArray_map(uint64_t closure, uint64_t array) {
    (void)closure;
    (void)array;
    assert(false && "Elm_Kernel_JsArray_map not implemented - requires closure calling");
    return 0;
}

uint64_t Elm_Kernel_JsArray_indexedMap(uint64_t closure, uint32_t offset, uint64_t array) {
    (void)closure;
    (void)offset;
    (void)array;
    assert(false && "Elm_Kernel_JsArray_indexedMap not implemented - requires closure calling");
    return 0;
}

uint64_t Elm_Kernel_JsArray_foldl(uint64_t closure, uint64_t acc, uint64_t array) {
    (void)closure;
    (void)acc;
    (void)array;
    assert(false && "Elm_Kernel_JsArray_foldl not implemented - requires closure calling");
    return 0;
}

uint64_t Elm_Kernel_JsArray_foldr(uint64_t closure, uint64_t acc, uint64_t array) {
    (void)closure;
    (void)acc;
    (void)array;
    assert(false && "Elm_Kernel_JsArray_foldr not implemented - requires closure calling");
    return 0;
}

} // extern "C"
