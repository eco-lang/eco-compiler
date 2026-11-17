//===- JsArray2Exports.cpp - C-linkage exports for eco/containers' JsArray2 -===//
//
// `JsArray2` is elm/core's `JsArray` with two more operations, `unsafeInsert` and `removeIndex`, which
// SeqDict needs. It is the same heap object (`Tag_Array`, an `ElmArray`), so most entry points forward to
// the elm/core `JsArray` kernel.
//
// The compiler passes a `JsArray2` kernel's Int parameters raw (`int64_t`) and every other parameter boxed,
// since `JsArray2` is not one of the kernels it picks typed variants for. So each entry point forwards to
// the elm/core variant that takes its Int parameters raw (`_Int`) and its elements boxed. `unsafeSet` has no
// such variant in elm/core, so it is written here, with `unsafeInsert` and `removeIndex`.
//
// An allocation is a GC point and may move any heap object, so the arguments used after one are copied
// into rooted locals first, and raw pointers are resolved again after it.
//
//===----------------------------------------------------------------------===//

#include "KernelExports.h"
#include "ExportHelpers.hpp"
#include "core/JsArray.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

using namespace Elm;
using namespace Elm::Kernel;

namespace {

// Returns the slot that holds the boxed value `val` in an array of kind `kind`: the value itself in a boxed
// array (kind 0), or the raw value in an Int, Float or Char array (kind 1 to 3).
Unboxable slotFor(HPointer val, uint32_t kind) {
    return kind == 0 ? alloc::boxed(val) : JsArray::unboxByKind(val, kind);
}

// Returns a new array, the copy of `array` with its slot `skip` left out (when `skip` is an index of it)
// and `extra` free slots added at the end, and puts the source length in `outLen` and its kind in
// `outKind`. The copy's `length` is the number of slots copied; the caller fills the extra ones. A GC
// point, so the caller roots whatever it uses afterwards.
HPointer copyArray(HPtr array, int64_t skip, uint32_t extra, uint32_t& outLen, uint32_t& outKind) {
    auto& allocator = Allocator::instance();
    HPointer srcHP = Export::decode(array.toBits());
    StackRootGuard guard(&srcHP);

    ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    uint32_t len = src->length;
    uint32_t kind = src->header.unboxed & 0x3;
    bool skipping = skip >= 0 && static_cast<uint64_t>(skip) < len;

    HPointer result = alloc::allocArray(len - (skipping ? 1 : 0) + extra);
    src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    ElmArray* dst = static_cast<ElmArray*>(allocator.resolve(result));

    uint32_t j = 0;
    for (uint32_t i = 0; i < len; i++) {
        if (skipping && i == skip) continue;
        dst->elements[j++] = src->elements[i];
    }
    dst->length = j;
    dst->header.unboxed = kind;
    outLen = len;
    outKind = kind;
    return result;
}

} // namespace

extern "C" {

HPtr Elm_Kernel_JsArray2_empty() { return Elm_Kernel_JsArray_empty(); }

HPtr Elm_Kernel_JsArray2_singleton(HPtr value) { return Elm_Kernel_JsArray_singleton(value); }

int64_t Elm_Kernel_JsArray2_length(HPtr array) { return Elm_Kernel_JsArray_length(array); }

HPtr Elm_Kernel_JsArray2_initialize(int64_t size, int64_t offset, HPtr closure) {
    return Elm_Kernel_JsArray_initialize_Int(size, offset, closure);
}

HPtr Elm_Kernel_JsArray2_initializeFromList(int64_t max, HPtr list) {
    return Elm_Kernel_JsArray_initializeFromList_Int(max, list);
}

HPtr Elm_Kernel_JsArray2_unsafeGet(int64_t index, HPtr array) {
    return Elm_Kernel_JsArray_unsafeGet_Int(index, array);
}

HPtr Elm_Kernel_JsArray2_unsafeSet(int64_t index, HPtr value, HPtr array) {
    auto& allocator = Allocator::instance();
    HPointer valHP = Export::decode(value.toBits());
    StackRootGuard guard(&valHP);

    uint32_t len, kind;
    HPointer result = copyArray(array, -1, 0, len, kind);
    ElmArray* dst = static_cast<ElmArray*>(allocator.resolve(result));
    if (index >= 0 && static_cast<uint64_t>(index) < len) {
        dst->elements[index] = slotFor(valHP, kind);
    }
    return HPtr::fromBits(Export::encode(result));
}

// Inserts `value` before slot `index`, shifting the rest up by one. An index past the end appends.
HPtr Elm_Kernel_JsArray2_unsafeInsert(int64_t index, HPtr value, HPtr array) {
    auto& allocator = Allocator::instance();
    HPointer valHP = Export::decode(value.toBits());
    StackRootGuard guard(&valHP);

    uint32_t len, kind;
    HPointer result = copyArray(array, -1, 1, len, kind);
    ElmArray* dst = static_cast<ElmArray*>(allocator.resolve(result));
    uint32_t at = index < 0 ? 0 : (static_cast<uint64_t>(index) > len ? len : static_cast<uint32_t>(index));
    for (uint32_t i = len; i > at; i--) {
        dst->elements[i] = dst->elements[i - 1];
    }
    // An empty array has no kind yet: a boxed value makes it a boxed array.
    dst->elements[at] = slotFor(valHP, len == 0 ? 0 : kind);
    if (len == 0) dst->header.unboxed = 0;
    dst->length = len + 1;
    return HPtr::fromBits(Export::encode(result));
}

// Returns the array without slot `index`, or a copy of it when `index` is out of range.
HPtr Elm_Kernel_JsArray2_removeIndex(int64_t index, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyArray(array, index, 0, len, kind);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_JsArray2_push(HPtr value, HPtr array) { return Elm_Kernel_JsArray_push(value, array); }

HPtr Elm_Kernel_JsArray2_foldl(HPtr closure, HPtr acc, HPtr array) {
    return Elm_Kernel_JsArray_foldl(closure, acc, array);
}

HPtr Elm_Kernel_JsArray2_foldr(HPtr closure, HPtr acc, HPtr array) {
    return Elm_Kernel_JsArray_foldr(closure, acc, array);
}

HPtr Elm_Kernel_JsArray2_map(HPtr closure, HPtr array) { return Elm_Kernel_JsArray_map(closure, array); }

HPtr Elm_Kernel_JsArray2_indexedMap(HPtr closure, int64_t offset, HPtr array) {
    return Elm_Kernel_JsArray_indexedMap_Int(closure, offset, array);
}

HPtr Elm_Kernel_JsArray2_slice(int64_t from, int64_t to, HPtr array) {
    return Elm_Kernel_JsArray_slice_Int(from, to, array);
}

HPtr Elm_Kernel_JsArray2_appendN(int64_t n, HPtr dest, HPtr source) {
    return Elm_Kernel_JsArray_appendN_Int(n, dest, source);
}

} // extern "C"
