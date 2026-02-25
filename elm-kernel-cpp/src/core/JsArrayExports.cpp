//===- JsArrayExports.cpp - C-linkage exports for JsArray module -----------===//
//
// ABI convention: ALL kernel function params arrive as !eco.value (HPointer-
// encoded i64).  Even integer params (index, length, etc.) are boxed as
// ElmInt on the heap; we must resolve and unbox them here.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "JsArray.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

namespace {

//===----------------------------------------------------------------------===//
// Helpers for unboxing primitive !eco.value params
//===----------------------------------------------------------------------===//

// Unbox an Int from !eco.value (HPointer to ElmInt on the heap).
static int64_t unboxInt(uint64_t val) {
    void* ptr = Export::toPtr(val);
    assert(ptr && "unboxInt: expected ElmInt HPointer, got embedded constant");
    ElmInt* obj = static_cast<ElmInt*>(ptr);
    return obj->value;
}

//===----------------------------------------------------------------------===//
// Closure-calling helpers (INV_2: delegate to runtime via eco_closure_call_saturated)
//===----------------------------------------------------------------------===//

// Call a closure with one argument (index for initialize).
// index is boxed via eco_alloc_int so the wrapper can unbox it.
static uint64_t callUnaryInitClosure(uint64_t closure_hptr, int64_t index) {
    uint64_t args[1] = { eco_alloc_int(index) };
    return eco_closure_call_saturated(closure_hptr, args, 1);
}

// Call a closure with one argument (element for map).
// Element is already HPointer-encoded (!eco.value).
static uint64_t callUnaryMapClosure(uint64_t closure_hptr, uint64_t elem) {
    uint64_t args[1] = { elem };
    return eco_closure_call_saturated(closure_hptr, args, 1);
}

// Call a closure with two arguments (index, element for indexedMap).
// index is boxed, element is HPointer-encoded.
static uint64_t callBinaryIndexMapClosure(uint64_t closure_hptr, int64_t index, uint64_t elem) {
    uint64_t args[2] = { eco_alloc_int(index), elem };
    return eco_closure_call_saturated(closure_hptr, args, 2);
}

// Call a closure with two arguments (element, acc for foldl/foldr).
// Both are HPointer-encoded (!eco.value).
static uint64_t callBinaryFoldClosure(uint64_t closure_hptr, uint64_t elem, uint64_t acc) {
    uint64_t args[2] = { elem, acc };
    return eco_closure_call_saturated(closure_hptr, args, 2);
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

uint64_t Elm_Kernel_JsArray_length(uint64_t array) {
    void* ptr = Export::toPtr(array);
    int64_t len = static_cast<int64_t>(alloc::arrayLength(ptr));
    // Return boxed Int (!eco.value = HPointer to ElmInt)
    return eco_alloc_int(len);
}

uint64_t Elm_Kernel_JsArray_unsafeGet(uint64_t index_val, uint64_t array) {
    int64_t idx = unboxInt(index_val);
    void* ptr = Export::toPtr(array);
    ElmArray* arr = static_cast<ElmArray*>(ptr);
    Unboxable val = alloc::arrayGet(ptr, static_cast<uint32_t>(idx));

    if (arr->header.unboxed) {
        // Unboxed element: box it back to !eco.value for the caller
        return eco_alloc_int(val.i);
    } else {
        return Export::encode(val.p);
    }
}

uint64_t Elm_Kernel_JsArray_unsafeSet(uint64_t index_val, uint64_t value, uint64_t array) {
    int64_t idx = unboxInt(index_val);
    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    bool srcUnboxed = src->header.unboxed != 0;

    HPointer result = alloc::allocArray(len);
    // Re-resolve in case allocation triggered GC
    srcPtr = Export::toPtr(array);
    src = static_cast<ElmArray*>(srcPtr);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    for (uint32_t i = 0; i < len; i++) {
        dst->elements[i] = src->elements[i];
    }
    dst->length = len;

    if (static_cast<uint32_t>(idx) < len) {
        if (srcUnboxed) {
            // Unbox the new value from !eco.value
            dst->elements[idx].i = unboxInt(value);
        } else {
            dst->elements[idx].p = Export::decode(value);
        }
    }
    dst->header.unboxed = srcUnboxed ? 1 : 0;

    return Export::encode(result);
}

uint64_t Elm_Kernel_JsArray_push(uint64_t value, uint64_t array) {
    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    bool srcUnboxed = src->header.unboxed != 0;

    HPointer result = alloc::allocArray(len + 1);
    // Re-resolve in case allocation triggered GC
    srcPtr = Export::toPtr(array);
    src = static_cast<ElmArray*>(srcPtr);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    for (uint32_t i = 0; i < len; i++) {
        dst->elements[i] = src->elements[i];
    }
    dst->length = len + 1;

    if (srcUnboxed) {
        // Unbox the new value from !eco.value (HPointer to ElmInt/ElmFloat)
        void* valPtr = Export::toPtr(value);
        if (valPtr) {
            // Read raw 8 bytes after the header
            dst->elements[len].i = *reinterpret_cast<int64_t*>(
                static_cast<char*>(valPtr) + sizeof(Header));
        } else {
            dst->elements[len].i = static_cast<int64_t>(value);
        }
        dst->header.unboxed = 1;
    } else {
        dst->elements[len].p = Export::decode(value);
        dst->header.unboxed = 0;
    }

    return Export::encode(result);
}

uint64_t Elm_Kernel_JsArray_slice(uint64_t start_val, uint64_t end_val, uint64_t array) {
    int64_t start = unboxInt(start_val);
    int64_t end = unboxInt(end_val);

    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    int64_t len = static_cast<int64_t>(src->length);

    if (start < 0) start += len;
    if (end < 0) end += len;
    if (start < 0) start = 0;
    if (end > len) end = len;
    if (start > end) start = end;

    int64_t newLen = end - start;
    HPointer result = alloc::allocArray(static_cast<size_t>(newLen));
    // Re-resolve after allocation
    srcPtr = Export::toPtr(array);
    src = static_cast<ElmArray*>(srcPtr);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    for (int64_t i = 0; i < newLen; i++) {
        dst->elements[i] = src->elements[start + i];
    }
    dst->length = static_cast<uint32_t>(newLen);
    dst->header.unboxed = src->header.unboxed;

    return Export::encode(result);
}

uint64_t Elm_Kernel_JsArray_appendN(uint64_t n_val, uint64_t dest, uint64_t source) {
    uint32_t n = static_cast<uint32_t>(unboxInt(n_val));

    void* destPtr = Export::toPtr(dest);
    void* srcPtr = Export::toPtr(source);
    ElmArray* destArr = static_cast<ElmArray*>(destPtr);
    ElmArray* srcArr = static_cast<ElmArray*>(srcPtr);

    uint32_t destLen = destArr->length;
    uint32_t srcLen = srcArr->length;
    uint32_t toCopy = (n < srcLen) ? n : srcLen;
    uint32_t newLen = destLen + toCopy;

    HPointer result = alloc::allocArray(newLen);
    // Re-resolve after allocation
    destPtr = Export::toPtr(dest);
    srcPtr = Export::toPtr(source);
    destArr = static_cast<ElmArray*>(destPtr);
    srcArr = static_cast<ElmArray*>(srcPtr);
    void* resultPtr = Allocator::instance().resolve(result);
    ElmArray* resultArr = static_cast<ElmArray*>(resultPtr);

    for (uint32_t i = 0; i < destLen; i++) {
        resultArr->elements[i] = destArr->elements[i];
    }
    for (uint32_t i = 0; i < toCopy; i++) {
        resultArr->elements[destLen + i] = srcArr->elements[i];
    }
    resultArr->length = newLen;
    resultArr->header.unboxed = destArr->header.unboxed;

    return Export::encode(result);
}

//===----------------------------------------------------------------------===//
// Higher-order functions (implemented with closure calling)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_JsArray_initialize(uint64_t size_val, uint64_t offset_val, uint64_t closure) {
    int64_t size = unboxInt(size_val);
    int64_t offset = unboxInt(offset_val);

    HPointer arr = alloc::allocArray(static_cast<size_t>(size));
    auto& allocator = Allocator::instance();

    for (int64_t i = 0; i < size; i++) {
        uint64_t value = callUnaryInitClosure(closure, offset + i);
        void* arrObj = allocator.resolve(arr);
        Unboxable elem;
        elem.p = Export::decode(value);
        alloc::arrayPush(arrObj, elem, true);  // isBoxed=true
    }
    return Export::encode(arr);
}

uint64_t Elm_Kernel_JsArray_initializeFromList(uint64_t max_val, uint64_t list) {
    uint32_t max = static_cast<uint32_t>(unboxInt(max_val));
    HPointer result = JsArray::initializeFromList(max, Export::decode(list));
    return Export::encode(result);
}

uint64_t Elm_Kernel_JsArray_map(uint64_t closure, uint64_t array) {
    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    bool srcUnboxed = src->header.unboxed != 0;

    HPointer arr = alloc::allocArray(len);
    auto& allocator = Allocator::instance();

    for (uint32_t i = 0; i < len; i++) {
        // Re-resolve source after potential GC from callback
        srcPtr = Export::toPtr(array);
        src = static_cast<ElmArray*>(srcPtr);
        // For unboxed arrays, box the element before passing to callback
        uint64_t elem;
        if (srcUnboxed) {
            elem = eco_alloc_int(src->elements[i].i);
        } else {
            elem = Export::encode(src->elements[i].p);
        }
        uint64_t result = callUnaryMapClosure(closure, elem);

        void* arrObj = allocator.resolve(arr);
        Unboxable val;
        val.p = Export::decode(result);
        alloc::arrayPush(arrObj, val, true);  // results are boxed
    }
    return Export::encode(arr);
}

uint64_t Elm_Kernel_JsArray_indexedMap(uint64_t closure, uint64_t offset_val, uint64_t array) {
    int64_t offset = unboxInt(offset_val);

    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    bool srcUnboxed = src->header.unboxed != 0;

    HPointer arr = alloc::allocArray(len);
    auto& allocator = Allocator::instance();

    for (uint32_t i = 0; i < len; i++) {
        // Re-resolve source after potential GC
        srcPtr = Export::toPtr(array);
        src = static_cast<ElmArray*>(srcPtr);
        uint64_t elem;
        if (srcUnboxed) {
            elem = eco_alloc_int(src->elements[i].i);
        } else {
            elem = Export::encode(src->elements[i].p);
        }
        uint64_t result = callBinaryIndexMapClosure(closure, offset + i, elem);

        void* arrObj = allocator.resolve(arr);
        Unboxable val;
        val.p = Export::decode(result);
        alloc::arrayPush(arrObj, val, true);  // results are boxed
    }
    return Export::encode(arr);
}

uint64_t Elm_Kernel_JsArray_foldl(uint64_t closure, uint64_t acc, uint64_t array) {
    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    bool srcUnboxed = src->header.unboxed != 0;

    uint64_t accumulator = acc;
    for (uint32_t i = 0; i < len; i++) {
        // Re-resolve source after potential GC from callback
        srcPtr = Export::toPtr(array);
        src = static_cast<ElmArray*>(srcPtr);
        uint64_t elem;
        if (srcUnboxed) {
            elem = eco_alloc_int(src->elements[i].i);
        } else {
            elem = Export::encode(src->elements[i].p);
        }
        accumulator = callBinaryFoldClosure(closure, elem, accumulator);
    }
    return accumulator;
}

uint64_t Elm_Kernel_JsArray_foldr(uint64_t closure, uint64_t acc, uint64_t array) {
    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    bool srcUnboxed = src->header.unboxed != 0;

    uint64_t accumulator = acc;
    for (uint32_t i = len; i > 0; i--) {
        uint32_t idx = i - 1;
        // Re-resolve source after potential GC from callback
        srcPtr = Export::toPtr(array);
        src = static_cast<ElmArray*>(srcPtr);
        uint64_t elem;
        if (srcUnboxed) {
            elem = eco_alloc_int(src->elements[idx].i);
        } else {
            elem = Export::encode(src->elements[idx].p);
        }
        accumulator = callBinaryFoldClosure(closure, elem, accumulator);
    }
    return accumulator;
}

} // extern "C"
