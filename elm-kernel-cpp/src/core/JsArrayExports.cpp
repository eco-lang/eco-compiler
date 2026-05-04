//===- JsArrayExports.cpp - C-linkage exports for JsArray module -----------===//
//
// ABI convention: ALL kernel function params arrive as HPtr (HPointer-
// encoded).  Even integer params (index, length, etc.) are boxed as
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
// Helpers for unboxing primitive HPtr params
//===----------------------------------------------------------------------===//

// Unbox an Int from HPtr (HPointer to ElmInt on the heap).
static int64_t unboxInt(HPtr val) {
    void* ptr = Export::toPtr(val.toBits());
    assert(ptr && "unboxInt: expected ElmInt HPointer, got embedded constant");
    ElmInt* obj = static_cast<ElmInt*>(ptr);
    return obj->value;
}

//===----------------------------------------------------------------------===//
// Closure-calling helpers (INV_2: delegate to runtime via eco_closure_call_saturated)
//===----------------------------------------------------------------------===//

// Call a closure with one argument (index for initialize).
// index is boxed via eco_alloc_int so the wrapper can unbox it.
static uint64_t callUnaryInitClosure(HPtr closure_hptr, int64_t index) {
    uint64_t args[1] = { eco_alloc_int(index).toBits() };
    return eco_closure_call_saturated(closure_hptr, args, 1, /*layout=*/nullptr).toBits();
}

// Call a closure with one argument (element for map).
// Element is already HPointer-encoded (!eco.value).
static uint64_t callUnaryMapClosure(HPtr closure_hptr, uint64_t elem) {
    uint64_t args[1] = { elem };
    return eco_closure_call_saturated(closure_hptr, args, 1, /*layout=*/nullptr).toBits();
}

// Push the closure's return value into `arrObj`, unboxing primitive wrappers
// so the uniform-kind Int/Float/Char arrays match the representation
// Array.fromList / JsArray.initializeFromList would produce for the same
// element type. Shared helper used by initialize / map / indexedMap.
static void pushUnboxedResult(void* arrObj, uint64_t result) {
    auto& allocator = Allocator::instance();
    HPointer hp = Export::decode(result);
    void* elemPtr = alloc::isConstant(hp) ? nullptr : allocator.resolve(hp);
    if (elemPtr) {
        Header* hdr = static_cast<Header*>(elemPtr);
        if (hdr->tag == Tag_Int) {
            Unboxable u; u.i = static_cast<ElmInt*>(elemPtr)->value;
            alloc::arrayPushKind(arrObj, u, 1);
            return;
        }
        if (hdr->tag == Tag_Float) {
            Unboxable u; u.f = static_cast<ElmFloat*>(elemPtr)->value;
            alloc::arrayPushKind(arrObj, u, 2);
            return;
        }
        if (hdr->tag == Tag_Char) {
            Unboxable u; u.c = static_cast<ElmChar*>(elemPtr)->value;
            alloc::arrayPushKind(arrObj, u, 3);
            return;
        }
    }
    Unboxable u; u.p = hp;
    alloc::arrayPush(arrObj, u, true);  // boxed
}

// Call a closure with two arguments (index, element for indexedMap).
// index is boxed, element is HPointer-encoded.
static uint64_t callBinaryIndexMapClosure(HPtr closure_hptr, int64_t index, uint64_t elem) {
    uint64_t args[2] = { eco_alloc_int(index).toBits(), elem };
    return eco_closure_call_saturated(closure_hptr, args, 2, /*layout=*/nullptr).toBits();
}

// Call a closure with two arguments (element, acc for foldl/foldr).
// Both are HPointer-encoded (!eco.value).
static uint64_t callBinaryFoldClosure(HPtr closure_hptr, uint64_t elem, uint64_t acc) {
    uint64_t args[2] = { elem, acc };
    return eco_closure_call_saturated(closure_hptr, args, 2, /*layout=*/nullptr).toBits();
}

} // anonymous namespace

extern "C" {

HPtr Elm_Kernel_JsArray_empty() {
    HPointer arr = alloc::allocArray(0);
    return HPtr::fromBits(Export::encode(arr));
}

HPtr Elm_Kernel_JsArray_singleton(HPtr value) {
    uint64_t value_bits = value.toBits();
    std::vector<HPointer> vals = {Export::decode(value_bits)};
    HPointer arr = alloc::arrayFromPointers(vals);
    return HPtr::fromBits(Export::encode(arr));
}

HPtr Elm_Kernel_JsArray_length(HPtr array) {
    uint64_t array_bits = array.toBits();
    void* ptr = Export::toPtr(array_bits);
    int64_t len = static_cast<int64_t>(alloc::arrayLength(ptr));
    // Return boxed Int (HPtr to ElmInt)
    return eco_alloc_int(len);
}

HPtr Elm_Kernel_JsArray_unsafeGet(HPtr index_val, HPtr array) {
    int64_t idx = unboxInt(index_val);
    uint64_t array_bits = array.toBits();
    void* ptr = Export::toPtr(array_bits);
    ElmArray* arr = static_cast<ElmArray*>(ptr);
    Unboxable val = alloc::arrayGet(ptr, static_cast<uint32_t>(idx));

    uint32_t kind = arr->header.unboxed & 0x3;
    if (kind != 0) {
        return HPtr::fromBits(Export::encode(alloc::boxElement(val, kind)));
    } else {
        return HPtr::fromBits(Export::encode(val.p));
    }
}

HPtr Elm_Kernel_JsArray_unsafeSet(HPtr index_val, HPtr value, HPtr array) {
    int64_t idx = unboxInt(index_val);
    uint64_t value_bits = value.toBits();
    uint64_t array_bits = array.toBits();
    void* srcPtr = Export::toPtr(array_bits);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    bool srcUnboxed = src->header.unboxed != 0;

    HPointer result = alloc::allocArray(len);
    // Re-resolve in case allocation triggered GC
    srcPtr = Export::toPtr(array_bits);
    src = static_cast<ElmArray*>(srcPtr);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    for (uint32_t i = 0; i < len; i++) {
        dst->elements[i] = src->elements[i];
    }
    dst->length = len;

    if (static_cast<uint32_t>(idx) < len) {
        if (srcUnboxed) {
            // Unbox the new value from HPtr
            dst->elements[idx].i = unboxInt(value);
        } else {
            dst->elements[idx].p = Export::decode(value_bits);
        }
    }
    dst->header.unboxed = srcUnboxed ? 1 : 0;

    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_JsArray_push(HPtr value, HPtr array) {
    uint64_t value_bits = value.toBits();
    uint64_t array_bits = array.toBits();
    void* srcPtr = Export::toPtr(array_bits);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    bool srcUnboxed = src->header.unboxed != 0;

    HPointer result = alloc::allocArray(len + 1);
    // Re-resolve in case allocation triggered GC
    srcPtr = Export::toPtr(array_bits);
    src = static_cast<ElmArray*>(srcPtr);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    for (uint32_t i = 0; i < len; i++) {
        dst->elements[i] = src->elements[i];
    }
    dst->length = len + 1;

    if (srcUnboxed) {
        // Unbox the new value from HPtr (HPointer to ElmInt/ElmFloat)
        void* valPtr = Export::toPtr(value_bits);
        if (valPtr) {
            // Read raw 8 bytes after the header
            dst->elements[len].i = *reinterpret_cast<int64_t*>(
                static_cast<char*>(valPtr) + sizeof(Header));
        } else {
            dst->elements[len].i = static_cast<int64_t>(value_bits);
        }
        dst->header.unboxed = 1;
    } else {
        dst->elements[len].p = Export::decode(value_bits);
        dst->header.unboxed = 0;
    }

    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_JsArray_slice(HPtr start_val, HPtr end_val, HPtr array) {
    int64_t start = unboxInt(start_val);
    int64_t end = unboxInt(end_val);

    uint64_t array_bits = array.toBits();
    void* srcPtr = Export::toPtr(array_bits);
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
    srcPtr = Export::toPtr(array_bits);
    src = static_cast<ElmArray*>(srcPtr);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    for (int64_t i = 0; i < newLen; i++) {
        dst->elements[i] = src->elements[start + i];
    }
    dst->length = static_cast<uint32_t>(newLen);
    dst->header.unboxed = src->header.unboxed;

    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_JsArray_appendN(HPtr n_val, HPtr dest, HPtr source) {
    uint32_t n = static_cast<uint32_t>(unboxInt(n_val));

    uint64_t dest_bits = dest.toBits();
    uint64_t source_bits = source.toBits();
    void* destPtr = Export::toPtr(dest_bits);
    void* srcPtr = Export::toPtr(source_bits);
    ElmArray* destArr = static_cast<ElmArray*>(destPtr);
    ElmArray* srcArr = static_cast<ElmArray*>(srcPtr);

    uint32_t destLen = destArr->length;
    uint32_t srcLen = srcArr->length;
    // Elm semantics: appendN n dest source means cap total at n.
    // Copy min(n - destLen, srcLen) from source, or 0 if destLen >= n.
    uint32_t available = (destLen < n) ? (n - destLen) : 0u;
    uint32_t toCopy = (available < srcLen) ? available : srcLen;
    uint32_t newLen = destLen + toCopy;

    HPointer result = alloc::allocArray(newLen);
    // Re-resolve after allocation
    destPtr = Export::toPtr(dest_bits);
    srcPtr = Export::toPtr(source_bits);
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
    // Pick the result kind from whichever operand has elements. If dest is
    // empty, inherit src's kind (otherwise the copied elements silently
    // become the wrong kind — e.g. unboxed Ints copied into a kind-0 result).
    // Conversely, if src contributed zero elements keep dest's kind.
    uint32_t destKind = destArr->header.unboxed & 0x3;
    uint32_t srcKind = srcArr->header.unboxed & 0x3;
    uint32_t resultKind;
    if (destLen == 0) {
        resultKind = srcKind;
    } else if (toCopy == 0) {
        resultKind = destKind;
    } else {
        // Both contribute elements; they must agree on kind.
        assert(destKind == srcKind &&
               "JsArray.appendN: dest and src kinds disagree");
        resultKind = destKind;
    }
    resultArr->header.unboxed = resultKind;

    return HPtr::fromBits(Export::encode(result));
}

//===----------------------------------------------------------------------===//
// Higher-order functions (implemented with closure calling)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_JsArray_initialize(HPtr size_val, HPtr offset_val, HPtr closure) {
    int64_t size = unboxInt(size_val);
    int64_t offset = unboxInt(offset_val);

    HPointer arr = alloc::allocArray(static_cast<size_t>(size));
    HPointer closureHP = Export::decode(closure.toBits());
    auto& allocator = Allocator::instance();

    // Root `arr` AND the closure across every iteration: a minor GC inside
    // the closure call would otherwise leave the kernel's `closure` HPtr
    // pointing at the closure's old nursery cell.
    StackRootGuard loopRoots(&arr, &closureHP);
    for (int64_t i = 0; i < size; i++) {
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t value = callUnaryInitClosure(cl, offset + i);
        void* arrObj = allocator.resolve(arr);
        pushUnboxedResult(arrObj, value);
    }
    return HPtr::fromBits(Export::encode(arr));
}

HPtr Elm_Kernel_JsArray_initializeFromList(HPtr max_val, HPtr list) {
    uint32_t max = static_cast<uint32_t>(unboxInt(max_val));
    HPointer result = JsArray::initializeFromList(max, Export::decode(list.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_JsArray_map(HPtr closure, HPtr array) {
    auto& allocator = Allocator::instance();
    HPointer srcHP = Export::decode(array.toBits());
    HPointer closureHP = Export::decode(closure.toBits());

    uint32_t len;
    uint32_t srcKind;
    {
        ElmArray* src0 = static_cast<ElmArray*>(allocator.resolve(srcHP));
        len = src0->length;
        srcKind = src0->header.unboxed & 0x3;
    }

    HPointer arr;
    {
        StackRootGuard guard(&srcHP, &closureHP);
        arr = alloc::allocArray(len);
    }

    // Root source, destination, and closure across every iteration. The
    // closure may move between calls; without rooting it here, the next call
    // would see a stale HPointer pointing at a Tag_Forward (or freed) cell.
    StackRootGuard loopRoots(&srcHP, &arr, &closureHP);
    for (uint32_t i = 0; i < len; i++) {
        ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
        uint64_t elem;
        if (srcKind != 0) {
            elem = Export::encode(alloc::boxElement(src->elements[i], srcKind));
        } else {
            elem = Export::encode(src->elements[i].p);
        }
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t result = callUnaryMapClosure(cl, elem);

        void* arrObj = allocator.resolve(arr);
        pushUnboxedResult(arrObj, result);
    }
    return HPtr::fromBits(Export::encode(arr));
}

HPtr Elm_Kernel_JsArray_indexedMap(HPtr closure, HPtr offset_val, HPtr array) {
    int64_t offset = unboxInt(offset_val);

    auto& allocator = Allocator::instance();
    HPointer srcHP = Export::decode(array.toBits());
    HPointer closureHP = Export::decode(closure.toBits());

    uint32_t len;
    uint32_t srcKind;
    {
        ElmArray* src0 = static_cast<ElmArray*>(allocator.resolve(srcHP));
        len = src0->length;
        srcKind = src0->header.unboxed & 0x3;
    }

    HPointer arr;
    {
        StackRootGuard guard(&srcHP, &closureHP);
        arr = alloc::allocArray(len);
    }

    StackRootGuard loopRoots(&srcHP, &arr, &closureHP);
    for (uint32_t i = 0; i < len; i++) {
        ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
        uint64_t elem;
        if (srcKind != 0) {
            elem = Export::encode(alloc::boxElement(src->elements[i], srcKind));
        } else {
            elem = Export::encode(src->elements[i].p);
        }
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t result = callBinaryIndexMapClosure(cl, offset + i, elem);

        void* arrObj = allocator.resolve(arr);
        pushUnboxedResult(arrObj, result);
    }
    return HPtr::fromBits(Export::encode(arr));
}

HPtr Elm_Kernel_JsArray_foldl(HPtr closure, HPtr acc, HPtr array) {
    auto& allocator = Allocator::instance();
    HPointer srcHP = Export::decode(array.toBits());
    HPointer accHP = Export::decode(acc.toBits());
    HPointer closureHP = Export::decode(closure.toBits());

    uint32_t len;
    uint32_t srcKind;
    {
        ElmArray* src0 = static_cast<ElmArray*>(allocator.resolve(srcHP));
        len = src0->length;
        srcKind = src0->header.unboxed & 0x3;
    }

    StackRootGuard loopRoots(&srcHP, &accHP, &closureHP);
    for (uint32_t i = 0; i < len; i++) {
        ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
        uint64_t elem;
        if (srcKind != 0) {
            elem = Export::encode(alloc::boxElement(src->elements[i], srcKind));
        } else {
            elem = Export::encode(src->elements[i].p);
        }
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t newAcc = callBinaryFoldClosure(cl, elem, Export::encode(accHP));
        accHP = Export::decode(newAcc);
    }
    return HPtr::fromBits(Export::encode(accHP));
}

HPtr Elm_Kernel_JsArray_foldr(HPtr closure, HPtr acc, HPtr array) {
    auto& allocator = Allocator::instance();
    HPointer srcHP = Export::decode(array.toBits());
    HPointer accHP = Export::decode(acc.toBits());
    HPointer closureHP = Export::decode(closure.toBits());

    uint32_t len;
    uint32_t srcKind;
    {
        ElmArray* src0 = static_cast<ElmArray*>(allocator.resolve(srcHP));
        len = src0->length;
        srcKind = src0->header.unboxed & 0x3;
    }

    StackRootGuard loopRoots(&srcHP, &accHP, &closureHP);
    for (uint32_t i = len; i > 0; i--) {
        uint32_t idx = i - 1;
        ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
        uint64_t elem;
        if (srcKind != 0) {
            elem = Export::encode(alloc::boxElement(src->elements[idx], srcKind));
        } else {
            elem = Export::encode(src->elements[idx].p);
        }
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t newAcc = callBinaryFoldClosure(cl, elem, Export::encode(accHP));
        accHP = Export::decode(newAcc);
    }
    return HPtr::fromBits(Export::encode(accHP));
}

//===----------------------------------------------------------------------===//
// Unboxed-arg trampolines for the eco.array.* intrinsic lowering.
// These let the EcoToLLVMHeap lowering route Int/Float/Char/Boxed pushes
// directly without a redundant box→unbox round-trip via the kernel ABI.
//===----------------------------------------------------------------------===//

HPtr elm_array_empty() {
    HPointer arr = alloc::allocArray(0);
    return HPtr::fromBits(Export::encode(arr));
}

HPtr elm_array_singleton_int(int64_t v) {
    HPointer arr = alloc::allocArray(1);
    void* arrObj = Allocator::instance().resolve(arr);
    Unboxable u; u.i = v;
    alloc::arrayPushKind(arrObj, u, 1);
    return HPtr::fromBits(Export::encode(arr));
}

HPtr elm_array_singleton_float(double v) {
    HPointer arr = alloc::allocArray(1);
    void* arrObj = Allocator::instance().resolve(arr);
    Unboxable u; u.f = v;
    alloc::arrayPushKind(arrObj, u, 2);
    return HPtr::fromBits(Export::encode(arr));
}

HPtr elm_array_singleton_char(uint16_t v) {
    HPointer arr = alloc::allocArray(1);
    void* arrObj = Allocator::instance().resolve(arr);
    Unboxable u; u.c = v;
    alloc::arrayPushKind(arrObj, u, 3);
    return HPtr::fromBits(Export::encode(arr));
}

HPtr elm_array_singleton_box(HPtr value) {
    uint64_t value_bits = value.toBits();
    // Root the inbound HPointer across the allocate.
    HPointer hp = Export::decode(value_bits);
    StackRootGuard guard(&hp);
    HPointer arr = alloc::allocArray(1);
    void* arrObj = Allocator::instance().resolve(arr);
    Unboxable u; u.p = hp;
    alloc::arrayPush(arrObj, u, /*is_boxed=*/true);
    return HPtr::fromBits(Export::encode(arr));
}

namespace {

// Build a new array with `srcLen + 1` capacity, copy src elements, and
// fix up length/kind. Returns the new HPointer; caller writes the new
// element into elements[srcLen].
static HPointer copyAndExtendForPush(HPtr array, uint32_t &outSrcLen,
                                     uint32_t &outSrcKind) {
    uint64_t array_bits = array.toBits();
    void* srcPtr = Export::toPtr(array_bits);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    uint32_t srcKind = src->header.unboxed & 0x3;

    HPointer result = alloc::allocArray(len + 1);
    // Re-resolve after allocate (may have GC'd).
    srcPtr = Export::toPtr(array_bits);
    src = static_cast<ElmArray*>(srcPtr);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    for (uint32_t i = 0; i < len; i++) {
        dst->elements[i] = src->elements[i];
    }
    dst->length = len + 1;
    dst->header.unboxed = srcKind;
    outSrcLen = len;
    outSrcKind = srcKind;
    return result;
}

} // namespace

HPtr elm_array_push_int(int64_t v, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyAndExtendForPush(array, len, kind);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);
    dst->elements[len].i = v;
    if (len == 0) dst->header.unboxed = 1;  // bind kind on first write
    return HPtr::fromBits(Export::encode(result));
}

HPtr elm_array_push_float(double v, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyAndExtendForPush(array, len, kind);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);
    dst->elements[len].f = v;
    if (len == 0) dst->header.unboxed = 2;
    return HPtr::fromBits(Export::encode(result));
}

HPtr elm_array_push_char(uint16_t v, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyAndExtendForPush(array, len, kind);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);
    dst->elements[len].c = v;
    if (len == 0) dst->header.unboxed = 3;
    return HPtr::fromBits(Export::encode(result));
}

HPtr elm_array_push_box(HPtr value, HPtr array) {
    HPointer valHP = Export::decode(value.toBits());
    HPointer srcHP = Export::decode(array.toBits());
    auto& allocator = Allocator::instance();
    StackRootGuard guard(&srcHP, &valHP);

    uint32_t len = static_cast<ElmArray*>(allocator.resolve(srcHP))->length;
    HPointer result = alloc::allocArray(len + 1);
    ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    ElmArray* dst = static_cast<ElmArray*>(allocator.resolve(result));
    for (uint32_t i = 0; i < len; i++) dst->elements[i] = src->elements[i];
    dst->length = len + 1;
    dst->header.unboxed = 0;
    dst->elements[len].p = valHP;
    return HPtr::fromBits(Export::encode(result));
}

HPtr elm_array_slice(int64_t start, int64_t end, HPtr array) {
    uint64_t array_bits = array.toBits();
    void* srcPtr = Export::toPtr(array_bits);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    int64_t len = static_cast<int64_t>(src->length);

    if (start < 0) start += len;
    if (end < 0) end += len;
    if (start < 0) start = 0;
    if (end > len) end = len;
    if (start > end) start = end;

    int64_t newLen = end - start;
    HPointer result = alloc::allocArray(static_cast<size_t>(newLen));
    srcPtr = Export::toPtr(array_bits);
    src = static_cast<ElmArray*>(srcPtr);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    for (int64_t i = 0; i < newLen; i++) {
        dst->elements[i] = src->elements[start + i];
    }
    dst->length = static_cast<uint32_t>(newLen);
    dst->header.unboxed = src->header.unboxed;

    return HPtr::fromBits(Export::encode(result));
}

HPtr elm_array_append_n(int64_t n_signed, HPtr dest, HPtr source) {
    uint32_t n = static_cast<uint32_t>(n_signed);
    uint64_t dest_bits = dest.toBits();
    uint64_t source_bits = source.toBits();
    void* destPtr = Export::toPtr(dest_bits);
    void* srcPtr = Export::toPtr(source_bits);
    ElmArray* destArr = static_cast<ElmArray*>(destPtr);
    ElmArray* srcArr = static_cast<ElmArray*>(srcPtr);

    uint32_t destLen = destArr->length;
    uint32_t srcLen = srcArr->length;
    uint32_t available = (destLen < n) ? (n - destLen) : 0u;
    uint32_t toCopy = (available < srcLen) ? available : srcLen;
    uint32_t newLen = destLen + toCopy;

    HPointer result = alloc::allocArray(newLen);
    destPtr = Export::toPtr(dest_bits);
    srcPtr = Export::toPtr(source_bits);
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
    uint32_t destKind = destArr->header.unboxed & 0x3;
    uint32_t srcKind = srcArr->header.unboxed & 0x3;
    uint32_t resultKind;
    if (destLen == 0) {
        resultKind = srcKind;
    } else if (toCopy == 0) {
        resultKind = destKind;
    } else {
        assert(destKind == srcKind &&
               "elm_array_append_n: dest and src kinds disagree");
        resultKind = destKind;
    }
    resultArr->header.unboxed = resultKind;

    return HPtr::fromBits(Export::encode(result));
}

} // extern "C"
