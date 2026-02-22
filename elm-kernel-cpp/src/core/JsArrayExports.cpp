//===- JsArrayExports.cpp - C-linkage exports for JsArray module -----------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "JsArray.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

namespace {

//===----------------------------------------------------------------------===//
// Closure-calling helpers (StringExports pattern)
//===----------------------------------------------------------------------===//

// Call a closure with one argument (index for initialize)
static uint64_t callUnaryInitClosure(void* closure_ptr, uint32_t index) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    void* args[16];
    for (uint32_t i = 0; i < n_values; i++) {
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    // Index is passed as unboxed i64
    args[n_values] = reinterpret_cast<void*>(static_cast<uint64_t>(index));

    return reinterpret_cast<uint64_t>(closure->evaluator(args));
}

// Call a closure with one argument (element for map)
static uint64_t callUnaryMapClosure(void* closure_ptr, uint64_t elem) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    void* args[16];
    for (uint32_t i = 0; i < n_values; i++) {
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    args[n_values] = reinterpret_cast<void*>(elem);

    return reinterpret_cast<uint64_t>(closure->evaluator(args));
}

// Call a closure with two arguments (index, element for indexedMap)
static uint64_t callBinaryIndexMapClosure(void* closure_ptr, uint32_t index, uint64_t elem) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    void* args[16];
    for (uint32_t i = 0; i < n_values; i++) {
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    // Index is passed as unboxed i64
    args[n_values] = reinterpret_cast<void*>(static_cast<uint64_t>(index));
    args[n_values + 1] = reinterpret_cast<void*>(elem);

    return reinterpret_cast<uint64_t>(closure->evaluator(args));
}

// Call a closure with two arguments (element, acc for foldl/foldr)
static uint64_t callBinaryFoldClosure(void* closure_ptr, uint64_t elem, uint64_t acc) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    void* args[16];
    for (uint32_t i = 0; i < n_values; i++) {
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    args[n_values] = reinterpret_cast<void*>(elem);
    args[n_values + 1] = reinterpret_cast<void*>(acc);

    return reinterpret_cast<uint64_t>(closure->evaluator(args));
}

} // anonymous namespace

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
    ElmArray* arr = static_cast<ElmArray*>(ptr);
    Unboxable val = alloc::arrayGet(ptr, index);

    // Check uniform unboxed flag
    if (arr->header.unboxed) {
        // Return unboxed value directly
        return static_cast<uint64_t>(val.i);
    } else {
        // Return encoded pointer
        return Export::encode(val.p);
    }
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

    // Set the new value at index (always boxed when coming from export)
    if (index < len) {
        dst->elements[index].p = Export::decode(value);
    }
    // Result is boxed since we're setting a boxed value
    dst->header.unboxed = 0;

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
    // Add new element (boxed)
    dst->elements[len].p = Export::decode(value);
    dst->length = len + 1;
    // Result is boxed since we're pushing a boxed value
    dst->header.unboxed = 0;

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
    // Preserve unboxed flag from source
    dst->header.unboxed = src->header.unboxed;

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
    // Both arrays should have same unboxed status; use dest's
    resultArr->header.unboxed = destArr->header.unboxed;

    return Export::encode(result);
}

//===----------------------------------------------------------------------===//
// Higher-order functions (implemented with closure calling)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_JsArray_initialize(uint32_t size, uint32_t offset, uint64_t closure) {
    void* closure_ptr = Export::toPtr(closure);
    HPointer arr = alloc::allocArray(size);
    auto& allocator = Allocator::instance();

    for (uint32_t i = 0; i < size; i++) {
        uint64_t value = callUnaryInitClosure(closure_ptr, offset + i);
        void* arrObj = allocator.resolve(arr);
        // Results from closure are boxed HPointers
        Unboxable elem;
        elem.p = Export::decode(value);
        alloc::arrayPush(arrObj, elem, true);  // isBoxed=true
    }
    return Export::encode(arr);
}

uint64_t Elm_Kernel_JsArray_initializeFromList(uint32_t max, uint64_t list) {
    HPointer result = JsArray::initializeFromList(max, Export::decode(list));
    return Export::encode(result);
}

uint64_t Elm_Kernel_JsArray_map(uint64_t closure, uint64_t array) {
    void* closure_ptr = Export::toPtr(closure);
    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    bool srcUnboxed = src->header.unboxed != 0;

    HPointer arr = alloc::allocArray(len);
    auto& allocator = Allocator::instance();

    for (uint32_t i = 0; i < len; i++) {
        // Pass element directly as uint64_t (no boxing)
        uint64_t elem = srcUnboxed ? static_cast<uint64_t>(src->elements[i].i)
                                   : Export::encode(src->elements[i].p);
        uint64_t result = callUnaryMapClosure(closure_ptr, elem);

        void* arrObj = allocator.resolve(arr);
        Unboxable val;
        val.p = Export::decode(result);
        alloc::arrayPush(arrObj, val, true);  // results are boxed
    }
    return Export::encode(arr);
}

uint64_t Elm_Kernel_JsArray_indexedMap(uint64_t closure, uint32_t offset, uint64_t array) {
    void* closure_ptr = Export::toPtr(closure);
    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    bool srcUnboxed = src->header.unboxed != 0;

    HPointer arr = alloc::allocArray(len);
    auto& allocator = Allocator::instance();

    for (uint32_t i = 0; i < len; i++) {
        // Pass element directly as uint64_t (no boxing)
        uint64_t elem = srcUnboxed ? static_cast<uint64_t>(src->elements[i].i)
                                   : Export::encode(src->elements[i].p);
        uint64_t result = callBinaryIndexMapClosure(closure_ptr, offset + i, elem);

        void* arrObj = allocator.resolve(arr);
        Unboxable val;
        val.p = Export::decode(result);
        alloc::arrayPush(arrObj, val, true);  // results are boxed
    }
    return Export::encode(arr);
}

uint64_t Elm_Kernel_JsArray_foldl(uint64_t closure, uint64_t acc, uint64_t array) {
    void* closure_ptr = Export::toPtr(closure);
    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    bool srcUnboxed = src->header.unboxed != 0;

    uint64_t accumulator = acc;
    for (uint32_t i = 0; i < len; i++) {
        uint64_t elem = srcUnboxed ? static_cast<uint64_t>(src->elements[i].i)
                                   : Export::encode(src->elements[i].p);
        accumulator = callBinaryFoldClosure(closure_ptr, elem, accumulator);
    }
    return accumulator;
}

uint64_t Elm_Kernel_JsArray_foldr(uint64_t closure, uint64_t acc, uint64_t array) {
    void* closure_ptr = Export::toPtr(closure);
    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    bool srcUnboxed = src->header.unboxed != 0;

    uint64_t accumulator = acc;
    for (uint32_t i = len; i > 0; i--) {
        uint32_t idx = i - 1;
        uint64_t elem = srcUnboxed ? static_cast<uint64_t>(src->elements[idx].i)
                                   : Export::encode(src->elements[idx].p);
        accumulator = callBinaryFoldClosure(closure_ptr, elem, accumulator);
    }
    return accumulator;
}

} // extern "C"
