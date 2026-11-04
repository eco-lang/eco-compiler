//===- JsArrayExports.cpp - C-linkage exports for JsArray module -----------===//
//
// The `JsArray` kernel entry points, and the `elm_array_*` functions that serve the `eco.array.*`
// operations.
//
// An unsuffixed entry point takes every argument as an `HPtr` word, Int arguments (an index, a length, a
// count) included: those arrive as boxed `ElmInt`s and are unboxed here. The `_Int`, `_Float` and `_Char`
// variants and the `elm_array_*` functions take those arguments raw instead. `length` returns a raw
// `int64_t`.
//
// An allocation is a GC point and may move any heap object, so an argument that is used after one is
// first copied into a rooted local, and raw pointers are resolved again after it. The higher-order
// operations (`initialize`, `map`, `indexedMap`, `foldl`, `foldr`) call an Elm closure per element, and
// any such call may collect. The array that `initialize`, `map` and `indexedMap` fill is made a builder
// for the loop, which keeps it young while it is written into; the runtime's `alloc::BuilderGuard` states the rule.
//
// Every element of an array has the array's one slot kind, and code compiled for an `Array Int`, `Array
// Float` or `Array Char` reads and writes the elements raw (kind 1, 2 or 3). So `map`, `initialize`,
// `indexedMap` and `initializeFromList` have variants that store every element in the kind of the call
// site's element type, which the compiler selects by the result's element type: `map_Int`, `map_Float`,
// `map_Char`, and `initialize_Int_Int` and so on, whose first `_Int` names the raw Int parameters and the
// second the element. They ask each closure call for its result in that kind, so the result of a closure
// that returns its value boxed (a kernel such as `Debug.log "x"` used as a function value) is unboxed.
// The other forms store each closure result in the closure's own result kind; the compiler uses them
// where the element type is boxed or not known.
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

// Returns the value of the boxed Int that `val` names, which must be a heap `ElmInt`. Nothing checks the
// object's tag, and the assertion catches only a null result from `Export::toPtr`.
static int64_t unboxInt(HPtr val) {
    void* ptr = Export::toPtr(val.toBits());
    assert(ptr && "unboxInt: expected ElmInt HPointer, got embedded constant");
    ElmInt* obj = static_cast<ElmInt*>(ptr);
    return obj->value;
}

// Returns whether `idx` is an index of an array of length `len`. The whole 64-bit index is compared, so
// an index such as 2^32 + 1 is out of range, not taken for 1.
static inline bool inRange(int64_t idx, uint32_t len) {
    return idx >= 0 && static_cast<uint64_t>(idx) < len;
}

//===----------------------------------------------------------------------===//
// Closure-calling helpers.
//
// A kernel cannot tell how many arguments a closure it is given takes at a time: the closure may take
// them all at once, or be curried, or be partially applied. Every call therefore goes through
// `eco_apply_closure_eval`, which reads the closure at run time and applies the arguments whatever its
// arity.
//===----------------------------------------------------------------------===//

// Each call passes an `EvalParamLayout` giving the slot kind of each argument, so a raw Int index is
// passed without being boxed. Each call also asks for the result in a slot kind, `wantedKind`: the kind
// of the element type the caller stores the results as (1 Int, 2 Float, 3 Char), or
// `JsArray::kKeepElementKind` for the closure's own result kind, so that a closure that returns an Int,
// Float or Char hands back the raw value and nothing is boxed. The runtime unboxes a boxed result into a
// wanted primitive kind.

// Returns the slot kind (0 boxed, 1 Int, 2 Float, 3 Char) in which the closure `closureHP` names returns
// its result. `closureHP` must name a heap closure.
static uint8_t readClosureResultKind(HPointer closureHP) {
    auto* cl = static_cast<Elm::Closure*>(
        Elm::Allocator::instance().resolve(closureHP));
    return static_cast<uint8_t>(cl->result_kind);
}

// Returns the slot kind to ask the closure `closureHP` names for its result in: `wantedKind` itself when
// it is a kind, and the closure's own result kind for `JsArray::kKeepElementKind`.
static uint8_t callResultKind(HPointer closureHP, int wantedKind) {
    return wantedKind == JsArray::kKeepElementKind ? readClosureResultKind(closureHP)
                                                   : static_cast<uint8_t>(wantedKind);
}

// A closure's result as `eco_apply_closure_eval` writes it, read through the member that matches the
// result kind: `p` for 0, `i` for 1, `f` for 2, `c` for 3.
union ResultSlot {
    int64_t  i;
    double   f;
    uint32_t c;   // Char: a code point (the eval buffer's Char slot is 32-bit)
    Elm::HPtr p;
    uint64_t bits;
};

// Applies the closure `closureHP` names to the raw Int `index`, writes the result, asked for as
// `callResultKind` gives, to `*slot`, and returns the result's kind, which says which member of `*slot`
// holds it. The call may collect, and `closureHP` is a copy, so a caller that uses the closure afterwards
// must keep its own HPointer rooted.
static uint8_t callUnaryInitClosureTyped(HPointer closureHP,
                                          int64_t index,
                                          ResultSlot* slot,
                                          int wantedKind) {
    uint8_t resultKind = callResultKind(closureHP, wantedKind);
    const auto lb = Elm::makeEvalParamLayout<1>(resultKind, {1});   // (Int)
    const auto* layout = Elm::asLayout(&lb);
    uint64_t args[1] = { static_cast<uint64_t>(index) };
    Elm::HPtr cl = Elm::HPtr::fromBits(Elm::Kernel::Export::encode(closureHP));
    eco_apply_closure_eval(cl, reinterpret_cast<int64_t*>(args), 1, layout, slot, resultKind);
    return resultKind;
}

// Appends the value the encoded word `result` names to the array object `arrObj`, as a raw slot of kind
// Int, Float or Char when it is a boxed Int, Float or Char, and as a boxed slot otherwise. Nothing calls
// it.
static void pushUnboxedResult(void* arrObj, uint64_t result) {
    auto& allocator = Allocator::instance();
    HPointer hp = Export::decode(result);
    void* elemPtr = alloc::resolveOrNull(hp);
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
            Unboxable u = alloc::unboxedChar(static_cast<ElmChar*>(elemPtr)->value);
            alloc::arrayPushKind(arrObj, u, 3);
            return;
        }
    }
    Unboxable u; u.p = hp;
    alloc::arrayPush(arrObj, u, true);  // boxed
}

// Appends the closure result in `slot`, of kind `result_kind`, to the array object `arrObj` as a slot of
// that kind. Any kind above 2 is taken as Char. The first push sets the array's kind, and later pushes are
// assumed to agree, unchecked. The array must have room: a push into a full array is ignored. Does not
// allocate.
static void pushTypedResult(void* arrObj, const ResultSlot& slot,
                            uint8_t result_kind) {
    Unboxable u;
    switch (result_kind) {
        case 0:
            u.p = Elm::Kernel::Export::decode(slot.p.toBits());
            alloc::arrayPush(arrObj, u, /*boxed=*/true);
            return;
        case 1:
            u.i = slot.i;
            alloc::arrayPushKind(arrObj, u, 1);
            return;
        case 2:
            u.f = slot.f;
            alloc::arrayPushKind(arrObj, u, 2);
            return;
        default:
            u = alloc::unboxedChar(slot.c);
            alloc::arrayPushKind(arrObj, u, 3);
            return;
    }
}

// Applies the closure `closureHP` names to the raw Int `index` and the encoded boxed element `elem`, and
// writes and returns the result as `callUnaryInitClosureTyped` does.
static uint8_t callBinaryIndexMapClosureTyped(HPointer closureHP,
                                              int64_t index, uint64_t elem,
                                              ResultSlot* slot,
                                              int wantedKind) {
    uint8_t resultKind = callResultKind(closureHP, wantedKind);
    const auto lb = Elm::makeEvalParamLayout<2>(resultKind, {1, 0});   // (Int, a)
    const auto* layout = Elm::asLayout(&lb);
    uint64_t args[2] = { static_cast<uint64_t>(index), elem };
    Elm::HPtr cl = Elm::HPtr::fromBits(Elm::Kernel::Export::encode(closureHP));
    eco_apply_closure_eval(cl, reinterpret_cast<int64_t*>(args), 2, layout, slot, resultKind);
    return resultKind;
}

// Applies the closure `closureHP` names to the encoded boxed element `elem` and the accumulator `acc`,
// and writes and returns the result as `callUnaryInitClosureTyped` does. `accKind` is the slot kind `acc`
// is held in: 0 for an encoded HPointer, 1 to 3 for the raw bits of an Int, Float or Char. The runtime
// boxes or unboxes `acc` if the closure expects it in another kind.
static uint8_t callBinaryFoldClosureTyped(HPointer closureHP,
                                          uint64_t elem,
                                          uint64_t acc, uint8_t accKind,
                                          ResultSlot* slot) {
    uint8_t resultKind = readClosureResultKind(closureHP);
    const auto lb = Elm::makeEvalParamLayout<2>(resultKind, {/*elem*/0, accKind});
    const auto* layout = Elm::asLayout(&lb);
    uint64_t args[2] = { elem, acc };
    Elm::HPtr cl = Elm::HPtr::fromBits(Elm::Kernel::Export::encode(closureHP));
    eco_apply_closure_eval(cl, reinterpret_cast<int64_t*>(args), 2, layout, slot, resultKind);
    return resultKind;
}

// Applies the closure `closureHP` names to the encoded boxed element `elem`, and writes and returns the
// result as `callUnaryInitClosureTyped` does.
static uint8_t callUnaryMapClosureTyped(HPointer closureHP, uint64_t elem,
                                        ResultSlot* slot, int wantedKind) {
    uint8_t resultKind = callResultKind(closureHP, wantedKind);
    const auto lb = Elm::makeEvalParamLayout<1>(resultKind, {0});   // (a)
    const auto* layout = Elm::asLayout(&lb);
    uint64_t args[1] = { elem };
    Elm::HPtr cl = Elm::HPtr::fromBits(Elm::Kernel::Export::encode(closureHP));
    eco_apply_closure_eval(cl, reinterpret_cast<int64_t*>(args), 1, layout, slot, resultKind);
    return resultKind;
}

//===----------------------------------------------------------------------===//
// The loops of initialize, map and indexedMap, shared by their forms. `wantedKind` is the slot kind every
// result is stored in, or `JsArray::kKeepElementKind` for each closure result's own kind (see the
// closure-calling helpers above).
//===----------------------------------------------------------------------===//

// The array [f(offset), f(offset + 1), ..., f(offset + size - 1)], where `closure` is f.
static HPtr initializeImpl(int64_t size, int64_t offset, HPtr closure, int wantedKind) {
    // The `closure` argument is not rooted, so it is decoded into a rooted local before
    // `allocArrayBuilder` can move the closure, and encoded again from that local at each call.
    HPointer closureHP = Export::decode(closure.toBits());
    HPointer arr = alloc::listNil();
    StackRootGuard loopRoots(&arr, &closureHP);

    // The result is a builder until `clear`. Otherwise a collection inside a closure call could promote
    // the half-built array, and the next write would store a young HPointer in an old object.
    arr = alloc::allocArrayBuilder(static_cast<size_t>(size));
    alloc::BuilderGuard builderGuard(&arr);
    auto& allocator = Allocator::instance();

    ResultSlot slot{};
    for (int64_t i = 0; i < size; i++) {
        uint8_t rk = callUnaryInitClosureTyped(closureHP, offset + i, &slot, wantedKind);
        void* arrObj = allocator.resolve(arr);
        pushTypedResult(arrObj, slot, rk);
    }
    builderGuard.clear();
    return HPtr::fromBits(Export::encode(arr));
}

// The array of the results of `closure` applied to each element of `array`, in order. With `indexed`, the
// closure is also given the element's index plus `offset` as its first argument (indexedMap).
static HPtr mapImpl(HPtr closure, HPtr array, bool indexed, int64_t offset, int wantedKind) {
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
        // The result is a builder until `clear`. Otherwise a collection inside a closure call could
        // promote the half-built array, and the next write would store a young HPointer in an old object.
        arr = alloc::allocArrayBuilder(len);
    }

    // Root source, destination, and closure across every iteration. The closure may move between calls;
    // without rooting it here, the next call would see a stale HPointer pointing at a Tag_Forward (or
    // freed) cell.
    StackRootGuard loopRoots(&srcHP, &arr, &closureHP);
    alloc::BuilderGuard builderGuard(&arr);
    ResultSlot slot{};
    for (uint32_t i = 0; i < len; i++) {
        ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
        // The element is passed boxed.
        uint64_t elem;
        if (srcKind != 0) {
            elem = Export::encode(alloc::boxElement(src->elements[i], srcKind));
        } else {
            elem = Export::encode(src->elements[i].p);
        }
        uint8_t rk = indexed
                         ? callBinaryIndexMapClosureTyped(closureHP, offset + i, elem, &slot, wantedKind)
                         : callUnaryMapClosureTyped(closureHP, elem, &slot, wantedKind);
        void* arrObj = allocator.resolve(arr);
        pushTypedResult(arrObj, slot, rk);
    }
    builderGuard.clear();
    return HPtr::fromBits(Export::encode(arr));
}

// Returns a copy of `array` with room for one more element, with its length already counting that
// element and with the source's kind. Stores the source's length and kind in `outSrcLen` and
// `outSrcKind`. The last slot is not written: the caller must write it, at index `outSrcLen`, before the
// next allocation. A GC point.
static HPointer copyAndExtendForPush(HPtr array, uint32_t &outSrcLen,
                                     uint32_t &outSrcKind) {
    auto& allocator = Allocator::instance();
    HPointer srcHP = Export::decode(array.toBits());
    StackRootGuard guard(&srcHP);

    ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    uint32_t len = src->length;
    uint32_t srcKind = src->header.unboxed & 0x3;

    HPointer result = alloc::allocArray(len + 1);
    src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    ElmArray* dst = static_cast<ElmArray*>(allocator.resolve(result));

    for (uint32_t i = 0; i < len; i++) {
        dst->elements[i] = src->elements[i];
    }
    dst->length = len + 1;
    dst->header.unboxed = srcKind;
    outSrcLen = len;
    outSrcKind = srcKind;

#if ECO_HEAP_VALIDATE
    if (srcKind == 0) {
        for (uint32_t i = 0; i < len; i++)
            alloc::validateNurseryHPtr(dst->elements[i].p);
    }
#endif

    return result;
}

// Returns a copy of `array`, with the same length and kind, and stores that length and kind in `outLen`
// and `outKind`. The caller may then overwrite one element. A GC point.
static HPointer copyForUnsafeSet(HPtr array, uint32_t &outLen, uint32_t &outKind) {
    auto& allocator = Allocator::instance();
    // The `array` word is not rooted, so it is decoded into a rooted local before `allocArray` can move
    // the array.
    HPointer srcHP = Export::decode(array.toBits());
    StackRootGuard guard(&srcHP);

    ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    uint32_t len = src->length;
    uint32_t kind = src->header.unboxed & 0x3;

    HPointer result = alloc::allocArray(len);
    src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    void* dstPtr = allocator.resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);

    for (uint32_t i = 0; i < len; i++) {
        dst->elements[i] = src->elements[i];
    }
    dst->length = len;
    dst->header.unboxed = kind;
    outLen = len;
    outKind = kind;
    return result;
}

// Makes the copy `dst`, whose first `len` slots were copied from an array of kind `kind`, an array of the
// primitive kind `wanted` (1 Int, 2 Float, 3 Char), before a raw `wanted` value is written into it:
//   - an empty source has no kind yet, so `wanted` binds it;
//   - a boxed (kind 0) source holds boxed values of the wanted type (an array built from boxed closure
//     results), which are unboxed in place;
//   - any other kind would be a type error, which is asserted.
// Does not allocate, so a caller may run it between the copy and its own last write.
static void bindPrimitiveKind(ElmArray* dst, uint32_t len, uint32_t kind, uint32_t wanted) {
    if (kind == wanted) return;
    if (len != 0) {
        assert(kind == 0 && "JsArray: a primitive written into an array of another primitive kind");
        for (uint32_t i = 0; i < len; i++)
            dst->elements[i] = JsArray::unboxByKind(dst->elements[i].p, wanted);
    }
    dst->header.unboxed = wanted;
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

int64_t Elm_Kernel_JsArray_length(HPtr array) {
    uint64_t array_bits = array.toBits();
    void* ptr = Export::toPtr(array_bits);
    return static_cast<int64_t>(alloc::arrayLength(ptr));
}

HPtr Elm_Kernel_JsArray_unsafeGet(HPtr index_val, HPtr array) {
    return Elm_Kernel_JsArray_unsafeGet_Int(unboxInt(index_val), array);
}

// The boxed root takes the index and the value boxed. The value is stored in the array's kind: unboxed
// into a primitive array, as the pointer itself into a boxed one. An index outside the array leaves the
// copy as it was.
HPtr Elm_Kernel_JsArray_unsafeSet(HPtr index_val, HPtr value, HPtr array) {
    int64_t idx = unboxInt(index_val);
    auto& allocator = Allocator::instance();

    // `valHP` is rooted across the allocation in `copyForUnsafeSet`: a by-value HPtr would be stale
    // after the GC the allocation may trigger.
    HPointer valHP = Export::decode(value.toBits());
    StackRootGuard guard(&valHP);

    uint32_t len, kind;
    HPointer result = copyForUnsafeSet(array, len, kind);
    ElmArray* dst = static_cast<ElmArray*>(allocator.resolve(result));
    if (inRange(idx, len)) {
        dst->elements[idx] = (kind == 0) ? alloc::boxed(valHP) : JsArray::unboxByKind(valHP, kind);
    }

#if ECO_HEAP_VALIDATE
    if (kind == 0) {
        for (uint32_t i = 0; i < len; i++)
            alloc::validateNurseryHPtr(dst->elements[i].p);
    }
#endif

    return HPtr::fromBits(Export::encode(result));
}

// The boxed root takes the value boxed. Into a primitive (kind 1 to 3) array the value is unboxed in the
// array's kind; into a boxed array, or an empty one (whose kind is not bound yet), it is stored boxed.
HPtr Elm_Kernel_JsArray_push(HPtr value, HPtr array) {
    auto& allocator = Allocator::instance();

    // `valHP` is rooted across the allocation in `copyAndExtendForPush`.
    HPointer valHP = Export::decode(value.toBits());
    StackRootGuard guard(&valHP);

    uint32_t len, kind;
    HPointer result = copyAndExtendForPush(array, len, kind);
    ElmArray* dst = static_cast<ElmArray*>(allocator.resolve(result));
    if (len != 0 && kind != 0) {
        dst->elements[len] = JsArray::unboxByKind(valHP, kind);
    } else {
        dst->elements[len] = alloc::boxed(valHP);
        dst->header.unboxed = 0;
    }

#if ECO_HEAP_VALIDATE
    if ((dst->header.unboxed & 0x3) == 0) {
        for (uint32_t i = 0; i <= len; i++)
            alloc::validateNurseryHPtr(dst->elements[i].p);
    }
#endif

    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_JsArray_slice(HPtr start_val, HPtr end_val, HPtr array) {
    int64_t start = unboxInt(start_val);
    int64_t end = unboxInt(end_val);
    auto& allocator = Allocator::instance();

    HPointer srcHP = Export::decode(array.toBits());
    StackRootGuard guard(&srcHP);

    ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    int64_t len = static_cast<int64_t>(src->length);

    if (start < 0) start += len;
    if (end < 0) end += len;
    if (start < 0) start = 0;
    if (end > len) end = len;
    if (start > end) start = end;

    int64_t newLen = end - start;
    HPointer result = alloc::allocArray(static_cast<size_t>(newLen));
    src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    ElmArray* dst = static_cast<ElmArray*>(allocator.resolve(result));

    for (int64_t i = 0; i < newLen; i++) {
        dst->elements[i] = src->elements[start + i];
    }
    dst->length = static_cast<uint32_t>(newLen);
    dst->header.unboxed = src->header.unboxed;

#if ECO_HEAP_VALIDATE
    if ((dst->header.unboxed & 0x3) == 0) {
        for (int64_t i = 0; i < newLen; i++)
            alloc::validateNurseryHPtr(dst->elements[i].p);
    }
#endif

    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_JsArray_appendN(HPtr n_val, HPtr dest, HPtr source) {
    uint32_t n = static_cast<uint32_t>(unboxInt(n_val));
    auto& allocator = Allocator::instance();

    HPointer destHP = Export::decode(dest.toBits());
    HPointer srcHP  = Export::decode(source.toBits());
    StackRootGuard guard(&destHP, &srcHP);

    ElmArray* destArr = static_cast<ElmArray*>(allocator.resolve(destHP));
    ElmArray* srcArr  = static_cast<ElmArray*>(allocator.resolve(srcHP));

    uint32_t destLen = destArr->length;
    uint32_t srcLen = srcArr->length;
    // Elm semantics: appendN n dest source means cap total at n.
    // Copy min(n - destLen, srcLen) from source, or 0 if destLen >= n.
    uint32_t available = (destLen < n) ? (n - destLen) : 0u;
    uint32_t toCopy = (available < srcLen) ? available : srcLen;
    uint32_t newLen = destLen + toCopy;

    HPointer result = alloc::allocArray(newLen);
    destArr = static_cast<ElmArray*>(allocator.resolve(destHP));
    srcArr  = static_cast<ElmArray*>(allocator.resolve(srcHP));
    ElmArray* resultArr = static_cast<ElmArray*>(allocator.resolve(result));

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

#if ECO_HEAP_VALIDATE
    if (resultKind == 0) {
        for (uint32_t i = 0; i < newLen; i++)
            alloc::validateNurseryHPtr(resultArr->elements[i].p);
    }
#endif

    return HPtr::fromBits(Export::encode(result));
}

//===----------------------------------------------------------------------===//
// Higher-order functions (implemented with closure calling)
//===----------------------------------------------------------------------===//

// The boxed roots store each closure result in the closure's own result kind; the `_Int`, `_Float` and
// `_Char` element variants are below.
HPtr Elm_Kernel_JsArray_initialize(HPtr size_val, HPtr offset_val, HPtr closure) {
    return initializeImpl(unboxInt(size_val), unboxInt(offset_val), closure, JsArray::kKeepElementKind);
}

HPtr Elm_Kernel_JsArray_initializeFromList(HPtr max_val, HPtr list) {
    uint32_t max = static_cast<uint32_t>(unboxInt(max_val));
    HPointer result = JsArray::initializeFromList(max, Export::decode(list.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_JsArray_map(HPtr closure, HPtr array) {
    return mapImpl(closure, array, /*indexed=*/false, 0, JsArray::kKeepElementKind);
}

HPtr Elm_Kernel_JsArray_indexedMap(HPtr closure, HPtr offset_val, HPtr array) {
    return mapImpl(closure, array, /*indexed=*/true, unboxInt(offset_val), JsArray::kKeepElementKind);
}

// Folds `closure` over the elements of `array`, starting from the boxed accumulator `acc`, and returns
// the final accumulator boxed. With `forward` the elements are taken first to last (foldl), otherwise
// last to first (foldr). An empty array gives `acc` itself.
//
// Each element is passed boxed. The accumulator is passed to each call in the kind the previous call
// returned it in, so a closure that returns a raw Int, Float or Char has its accumulator boxed once, at
// the end, and not at every step.
static HPtr foldImpl(HPtr closure, HPtr acc, HPtr array, bool forward) {
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

    // accBits + accKind track the current accumulator's representation.
    // Starts boxed (HPtr from the caller); after the first call the
    // closure's `result_kind` may flip it to a primitive kind, in which
    // case `accHP` becomes irrelevant for subsequent iterations and the
    // raw primitive bits live in `accBits` instead.
    uint64_t accBits = Export::encode(accHP);
    uint8_t  accKind = 0;
    ResultSlot slot{};
    StackRootGuard loopRoots(&srcHP, &accHP, &closureHP);
    auto& rs = allocator.getRootSet();
    size_t accRoot = rs.stackRangePoint();

    for (uint32_t step = 0; step < len; ++step) {
        uint32_t idx = forward ? step : (len - 1 - step);
        ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
        uint64_t elem;
        if (srcKind != 0) {
            elem = Export::encode(alloc::boxElement(src->elements[idx], srcKind));
        } else {
            elem = Export::encode(src->elements[idx].p);
        }
        // Refresh accBits for the boxed-acc case: a GC inside boxElement
        // (above) may have moved the underlying ElmInt etc., and accHP
        // (rooted via `loopRoots`) holds the up-to-date HPointer.
        if (accKind == 0) accBits = Export::encode(accHP);

        uint8_t resultKind = callBinaryFoldClosureTyped(
            closureHP, elem, accBits, accKind, &slot);

        // Truncate this thread's root-range stack to the point taken just after `loopRoots`, discarding the
        // ranges pushed since. `accHP` stays rooted by `loopRoots`, so a boxed result stored in it is kept
        // current by later collections.
        rs.restoreStackRangePoint(accRoot);
        accKind = resultKind;
        switch (resultKind) {
            case 0:
                accHP = Export::decode(slot.p.toBits());
                accBits = Export::encode(accHP);
                break;
            case 1: accBits = static_cast<uint64_t>(slot.i); break;
            case 2: std::memcpy(&accBits, &slot.f, sizeof(uint64_t)); break;
            default: accBits = static_cast<uint64_t>(slot.c); break;
        }
    }

    // The result is an `HPtr` word, so an accumulator that ended raw is boxed here.
    if (accKind == 0) {
        return HPtr::fromBits(accBits);
    }
    Unboxable u;
    switch (accKind) {
        case 1: u.i = static_cast<int64_t>(accBits); break;
        case 2: std::memcpy(&u.f, &accBits, sizeof(double)); break;
        default: u = alloc::unboxedChar(static_cast<u32>(accBits)); break;
    }
    HPointer boxed = alloc::boxElement(u, accKind);
    return HPtr::fromBits(Export::encode(boxed));
}

HPtr Elm_Kernel_JsArray_foldl(HPtr closure, HPtr acc, HPtr array) {
    return foldImpl(closure, acc, array, /*forward=*/true);
}

HPtr Elm_Kernel_JsArray_foldr(HPtr closure, HPtr acc, HPtr array) {
    return foldImpl(closure, acc, array, /*forward=*/false);
}

//===----------------------------------------------------------------------===//
// The `eco.array.*` targets. These take Int, Float and Char arguments raw, so a caller holding a raw
// value does not box it only for it to be unboxed here.
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

// A Char argument arrives as `uint64_t` and is masked to its low 32 bits, because a statepointed call
// does not promise to zero-extend a narrow argument (`core/Char` owns this rule).
HPtr elm_array_singleton_char(uint64_t v_raw) {
    HPointer arr = alloc::allocArray(1);
    void* arrObj = Allocator::instance().resolve(arr);
    Unboxable u = alloc::unboxedChar(static_cast<u32>(v_raw & 0xFFFFFFFFu));
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

// The raw-element pushes bind the kind of an empty array, and convert a nonempty boxed one to their kind
// (`bindPrimitiveKind`); the fast path, a source of their own kind, is one compare.
HPtr elm_array_push_int(int64_t v, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyAndExtendForPush(array, len, kind);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);
    if (kind != 1 || len == 0) bindPrimitiveKind(dst, len, kind, 1);
    dst->elements[len].i = v;
    return HPtr::fromBits(Export::encode(result));
}

HPtr elm_array_push_float(double v, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyAndExtendForPush(array, len, kind);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);
    if (kind != 2 || len == 0) bindPrimitiveKind(dst, len, kind, 2);
    dst->elements[len].f = v;
    return HPtr::fromBits(Export::encode(result));
}

HPtr elm_array_push_char(uint64_t v_raw, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyAndExtendForPush(array, len, kind);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);
    if (kind != 3 || len == 0) bindPrimitiveKind(dst, len, kind, 3);
    dst->elements[len] = alloc::unboxedChar(static_cast<u32>(v_raw & 0xFFFFFFFFu));
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

#if ECO_HEAP_VALIDATE
    // Always boxed (kind=0). Validate the copied prefix and the new slot.
    for (uint32_t i = 0; i < len; i++)
        alloc::validateNurseryHPtr(dst->elements[i].p);
    alloc::validateNurseryHPtr(valHP);
#endif

    return HPtr::fromBits(Export::encode(result));
}

HPtr elm_array_slice(int64_t start, int64_t end, HPtr array) {
    auto& allocator = Allocator::instance();
    HPointer srcHP = Export::decode(array.toBits());
    StackRootGuard guard(&srcHP);

    ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    int64_t len = static_cast<int64_t>(src->length);

    if (start < 0) start += len;
    if (end < 0) end += len;
    if (start < 0) start = 0;
    if (end > len) end = len;
    if (start > end) start = end;

    int64_t newLen = end - start;
    HPointer result = alloc::allocArray(static_cast<size_t>(newLen));
    src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    ElmArray* dst = static_cast<ElmArray*>(allocator.resolve(result));

    for (int64_t i = 0; i < newLen; i++) {
        dst->elements[i] = src->elements[start + i];
    }
    dst->length = static_cast<uint32_t>(newLen);
    dst->header.unboxed = src->header.unboxed;

#if ECO_HEAP_VALIDATE
    if ((dst->header.unboxed & 0x3) == 0) {
        for (int64_t i = 0; i < newLen; i++)
            alloc::validateNurseryHPtr(dst->elements[i].p);
    }
#endif

    return HPtr::fromBits(Export::encode(result));
}

//===----------------------------------------------------------------------===//
// Kernel variants that take some arguments raw.
//
// The `singleton`, `push` and `unsafeSet` variants take the element as a raw Int, Float or Char. All of
// them take Int parameters (an index, a length, a count, an offset) as raw `int64_t`.
//===----------------------------------------------------------------------===//

// singleton: delegate to the typed trampolines.
HPtr Elm_Kernel_JsArray_singleton_Int  (int64_t  v) { return elm_array_singleton_int(v); }
HPtr Elm_Kernel_JsArray_singleton_Float(double   v) { return elm_array_singleton_float(v); }
HPtr Elm_Kernel_JsArray_singleton_Char (uint64_t v_raw) { return elm_array_singleton_char(v_raw); }

// push: delegate to the typed trampolines.
HPtr Elm_Kernel_JsArray_push_Int  (int64_t  v, HPtr array) { return elm_array_push_int(v, array); }
HPtr Elm_Kernel_JsArray_push_Float(double   v, HPtr array) { return elm_array_push_float(v, array); }
HPtr Elm_Kernel_JsArray_push_Char (uint64_t v_raw, HPtr array) { return elm_array_push_char(v_raw, array); }

// slice: delegate to the typed trampoline.
HPtr Elm_Kernel_JsArray_slice_Int(int64_t start, int64_t end, HPtr array) {
    return elm_array_slice(start, end, array);
}

// appendN: delegate to the typed trampoline.
HPtr Elm_Kernel_JsArray_appendN_Int(int64_t n, HPtr dest, HPtr source) {
    return elm_array_append_n(n, dest, source);
}

// unsafeGet, with a raw index; the boxed root delegates here. An index outside the array has no result,
// which is asserted. A primitive element is boxed.
HPtr Elm_Kernel_JsArray_unsafeGet_Int(int64_t idx, HPtr array) {
    uint64_t array_bits = array.toBits();
    void* ptr = Export::toPtr(array_bits);
    ElmArray* arr = static_cast<ElmArray*>(ptr);
    assert(inRange(idx, arr->length) && "JsArray.unsafeGet: index out of range");
    Unboxable val = alloc::arrayGet(ptr, static_cast<size_t>(idx));

    uint32_t kind = arr->header.unboxed & 0x3;
    if (kind != 0) {
        return HPtr::fromBits(Export::encode(alloc::boxElement(val, kind)));
    } else {
        return HPtr::fromBits(Export::encode(val.p));
    }
}

HPtr Elm_Kernel_JsArray_unsafeSet_Int(int64_t idx, int64_t value, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyForUnsafeSet(array, len, kind);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);
    bindPrimitiveKind(dst, len, kind, 1);
    if (inRange(idx, len)) dst->elements[idx].i = value;
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_JsArray_unsafeSet_Float(int64_t idx, double value, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyForUnsafeSet(array, len, kind);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);
    bindPrimitiveKind(dst, len, kind, 2);
    if (inRange(idx, len)) dst->elements[idx].f = value;
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_JsArray_unsafeSet_Char(int64_t idx, uint64_t value_raw, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyForUnsafeSet(array, len, kind);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);
    bindPrimitiveKind(dst, len, kind, 3);
    if (inRange(idx, len))
        dst->elements[idx] = alloc::unboxedChar(static_cast<u32>(value_raw & 0xFFFFFFFFu));
    return HPtr::fromBits(Export::encode(result));
}

// initialize, initializeFromList and indexedMap with raw Int parameters; each result is stored in the
// closure's own result kind, as by the boxed roots.
HPtr Elm_Kernel_JsArray_initialize_Int(int64_t size, int64_t offset, HPtr closure) {
    return initializeImpl(size, offset, closure, JsArray::kKeepElementKind);
}

HPtr Elm_Kernel_JsArray_initializeFromList_Int(int64_t max, HPtr list) {
    HPointer result = JsArray::initializeFromList(static_cast<uint32_t>(max),
                                                  Export::decode(list.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_JsArray_indexedMap_Int(HPtr closure, int64_t offset, HPtr array) {
    return mapImpl(closure, array, /*indexed=*/true, offset, JsArray::kKeepElementKind);
}

// The element variants: every element is stored in the kind their suffix names (1 Int, 2 Float, 3 Char),
// which is the kind of the call site's element type (see the file comment). Their Int parameters are raw.
HPtr Elm_Kernel_JsArray_map_Int  (HPtr closure, HPtr array) { return mapImpl(closure, array, false, 0, 1); }
HPtr Elm_Kernel_JsArray_map_Float(HPtr closure, HPtr array) { return mapImpl(closure, array, false, 0, 2); }
HPtr Elm_Kernel_JsArray_map_Char (HPtr closure, HPtr array) { return mapImpl(closure, array, false, 0, 3); }

HPtr Elm_Kernel_JsArray_indexedMap_Int_Int(HPtr closure, int64_t offset, HPtr array) {
    return mapImpl(closure, array, true, offset, 1);
}
HPtr Elm_Kernel_JsArray_indexedMap_Int_Float(HPtr closure, int64_t offset, HPtr array) {
    return mapImpl(closure, array, true, offset, 2);
}
HPtr Elm_Kernel_JsArray_indexedMap_Int_Char(HPtr closure, int64_t offset, HPtr array) {
    return mapImpl(closure, array, true, offset, 3);
}

HPtr Elm_Kernel_JsArray_initialize_Int_Int(int64_t size, int64_t offset, HPtr closure) {
    return initializeImpl(size, offset, closure, 1);
}
HPtr Elm_Kernel_JsArray_initialize_Int_Float(int64_t size, int64_t offset, HPtr closure) {
    return initializeImpl(size, offset, closure, 2);
}
HPtr Elm_Kernel_JsArray_initialize_Int_Char(int64_t size, int64_t offset, HPtr closure) {
    return initializeImpl(size, offset, closure, 3);
}

HPtr Elm_Kernel_JsArray_initializeFromList_Int_Int(int64_t max, HPtr list) {
    return HPtr::fromBits(Export::encode(
        JsArray::initializeFromList(static_cast<uint32_t>(max), Export::decode(list.toBits()), 1)));
}
HPtr Elm_Kernel_JsArray_initializeFromList_Int_Float(int64_t max, HPtr list) {
    return HPtr::fromBits(Export::encode(
        JsArray::initializeFromList(static_cast<uint32_t>(max), Export::decode(list.toBits()), 2)));
}
HPtr Elm_Kernel_JsArray_initializeFromList_Int_Char(int64_t max, HPtr list) {
    return HPtr::fromBits(Export::encode(
        JsArray::initializeFromList(static_cast<uint32_t>(max), Export::decode(list.toBits()), 3)));
}

HPtr elm_array_append_n(int64_t n_signed, HPtr dest, HPtr source) {
    uint32_t n = static_cast<uint32_t>(n_signed);
    auto& allocator = Allocator::instance();

    HPointer destHP = Export::decode(dest.toBits());
    HPointer srcHP  = Export::decode(source.toBits());
    StackRootGuard guard(&destHP, &srcHP);

    ElmArray* destArr = static_cast<ElmArray*>(allocator.resolve(destHP));
    ElmArray* srcArr  = static_cast<ElmArray*>(allocator.resolve(srcHP));

    uint32_t destLen = destArr->length;
    uint32_t srcLen = srcArr->length;
    uint32_t available = (destLen < n) ? (n - destLen) : 0u;
    uint32_t toCopy = (available < srcLen) ? available : srcLen;
    uint32_t newLen = destLen + toCopy;

    HPointer result = alloc::allocArray(newLen);
    destArr = static_cast<ElmArray*>(allocator.resolve(destHP));
    srcArr  = static_cast<ElmArray*>(allocator.resolve(srcHP));
    ElmArray* resultArr = static_cast<ElmArray*>(allocator.resolve(result));

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

#if ECO_HEAP_VALIDATE
    if (resultKind == 0) {
        for (uint32_t i = 0; i < newLen; i++)
            alloc::validateNurseryHPtr(resultArr->elements[i].p);
    }
#endif

    return HPtr::fromBits(Export::encode(result));
}

} // extern "C"
