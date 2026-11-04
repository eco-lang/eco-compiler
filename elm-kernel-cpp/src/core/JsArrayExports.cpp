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

//===----------------------------------------------------------------------===//
// Closure-calling helpers.
//
// A kernel cannot tell how many arguments a closure it is given takes at a time: the closure may take
// them all at once, or be curried, or be partially applied. Every call therefore goes through
// `eco_apply_closure_eval`, which reads the closure at run time and applies the arguments whatever its
// arity.
//===----------------------------------------------------------------------===//

// Each call passes an `EvalParamLayout` giving the slot kind of each argument, so a raw Int index is
// passed without being boxed. Each call also asks for the result in the closure's own result kind, so a
// closure that returns an Int, Float or Char hands back the raw value and nothing is boxed.

// Returns the slot kind (0 boxed, 1 Int, 2 Float, 3 Char) in which the closure `closureHP` names returns
// its result. `closureHP` must name a heap closure.
static uint8_t readClosureResultKind(HPointer closureHP) {
    auto* cl = static_cast<Elm::Closure*>(
        Elm::Allocator::instance().resolve(closureHP));
    return static_cast<uint8_t>(cl->result_kind);
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

// Applies the closure `closureHP` names to the raw Int `index`, writes the result to `*slot`, and returns
// the result's kind, which says which member of `*slot` holds it. The call may collect, and `closureHP`
// is a copy, so a caller that uses the closure afterwards must keep its own HPointer rooted.
static uint8_t callUnaryInitClosureTyped(HPointer closureHP,
                                          int64_t index,
                                          ResultSlot* slot) {
    uint8_t resultKind = readClosureResultKind(closureHP);
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
                                              ResultSlot* slot) {
    uint8_t resultKind = readClosureResultKind(closureHP);
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
    auto& allocator = Allocator::instance();

    // Root srcHP and valHP across alloc::allocArray below: by-value HPtrs
    // would otherwise be stale across the GC that the alloc may trigger.
    HPointer srcHP = Export::decode(array.toBits());
    HPointer valHP = Export::decode(value.toBits());
    StackRootGuard guard(&srcHP, &valHP);

    ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    uint32_t len = src->length;
    bool srcUnboxed = src->header.unboxed != 0;
    int64_t unboxedNew = srcUnboxed ? unboxInt(value) : 0;

    HPointer result = alloc::allocArray(len);
    src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    ElmArray* dst = static_cast<ElmArray*>(allocator.resolve(result));

    for (uint32_t i = 0; i < len; i++) {
        dst->elements[i] = src->elements[i];
    }
    dst->length = len;

    if (static_cast<uint32_t>(idx) < len) {
        if (srcUnboxed) {
            dst->elements[idx].i = unboxedNew;
        } else {
            dst->elements[idx].p = valHP;
        }
    }
    dst->header.unboxed = srcUnboxed ? 1 : 0;

#if ECO_HEAP_VALIDATE
    if (!srcUnboxed) {
        for (uint32_t i = 0; i < len; i++)
            alloc::validateNurseryHPtr(dst->elements[i].p);
    }
#endif

    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_JsArray_push(HPtr value, HPtr array) {
    auto& allocator = Allocator::instance();

    HPointer srcHP = Export::decode(array.toBits());
    HPointer valHP = Export::decode(value.toBits());
    StackRootGuard guard(&srcHP, &valHP);

    ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    uint32_t len = src->length;
    bool srcUnboxed = src->header.unboxed != 0;
    // For an unboxed source, the new element is the 64 bits after the header of the object `valHP`
    // names, or the word itself when `valHP` is an embedded constant or the null word. They are read
    // before the allocation, so `value` is not resolved again after it.
    int64_t unboxedPrim = 0;
    if (srcUnboxed) {
        void* valPtr = (valHP.ptr_ind == 0 && valHP.ptr != 0)
                           ? allocator.resolve(valHP) : nullptr;
        if (valPtr) {
            unboxedPrim = *reinterpret_cast<int64_t*>(
                static_cast<char*>(valPtr) + sizeof(Header));
        } else {
            unboxedPrim = static_cast<int64_t>(value.toBits());
        }
    }

    HPointer result = alloc::allocArray(len + 1);
    src = static_cast<ElmArray*>(allocator.resolve(srcHP));
    ElmArray* dst = static_cast<ElmArray*>(allocator.resolve(result));

    for (uint32_t i = 0; i < len; i++) {
        dst->elements[i] = src->elements[i];
    }
    dst->length = len + 1;

    if (srcUnboxed) {
        dst->elements[len].i = unboxedPrim;
        dst->header.unboxed = 1;
    } else {
        dst->elements[len].p = valHP;
        dst->header.unboxed = 0;
    }

#if ECO_HEAP_VALIDATE
    if (!srcUnboxed) {
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

HPtr Elm_Kernel_JsArray_initialize(HPtr size_val, HPtr offset_val, HPtr closure) {
    int64_t size = unboxInt(size_val);
    int64_t offset = unboxInt(offset_val);

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
        uint8_t rk = callUnaryInitClosureTyped(closureHP, offset + i, &slot);
        void* arrObj = allocator.resolve(arr);
        pushTypedResult(arrObj, slot, rk);
    }
    builderGuard.clear();
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
        // The result is a builder while the loop writes it across closure calls.
        arr = alloc::allocArrayBuilder(len);
    }

    // Root source, destination, and closure across every iteration. The
    // closure may move between calls; without rooting it here, the next call
    // would see a stale HPointer pointing at a Tag_Forward (or freed) cell.
    StackRootGuard loopRoots(&srcHP, &arr, &closureHP);
    alloc::BuilderGuard builderGuard(&arr);
    ResultSlot slot{};
    for (uint32_t i = 0; i < len; i++) {
        ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
        uint64_t elem;
        if (srcKind != 0) {
            elem = Export::encode(alloc::boxElement(src->elements[i], srcKind));
        } else {
            elem = Export::encode(src->elements[i].p);
        }
        // The element is passed boxed; the result comes back in the closure's own kind.
        uint8_t resultKind = readClosureResultKind(closureHP);
        const auto lb = Elm::makeEvalParamLayout<1>(resultKind, {0});
        const auto* layout = Elm::asLayout(&lb);
        uint64_t args[1] = { elem };
        Elm::HPtr cl =
            Elm::HPtr::fromBits(Elm::Kernel::Export::encode(closureHP));
        eco_apply_closure_eval(cl, reinterpret_cast<int64_t*>(args),
                               1, layout, &slot, resultKind);

        void* arrObj = allocator.resolve(arr);
        pushTypedResult(arrObj, slot, resultKind);
    }
    builderGuard.clear();
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
        // The result is a builder while the loop writes it across closure calls.
        arr = alloc::allocArrayBuilder(len);
    }

    StackRootGuard loopRoots(&srcHP, &arr, &closureHP);
    alloc::BuilderGuard builderGuard(&arr);
    ResultSlot slot{};
    for (uint32_t i = 0; i < len; i++) {
        ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
        uint64_t elem;
        if (srcKind != 0) {
            elem = Export::encode(alloc::boxElement(src->elements[i], srcKind));
        } else {
            elem = Export::encode(src->elements[i].p);
        }
        uint8_t rk = callBinaryIndexMapClosureTyped(closureHP, offset + i,
                                                    elem, &slot);
        void* arrObj = allocator.resolve(arr);
        pushTypedResult(arrObj, slot, rk);
    }
    builderGuard.clear();
    return HPtr::fromBits(Export::encode(arr));
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

namespace {

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

HPtr elm_array_push_char(uint64_t v_raw, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyAndExtendForPush(array, len, kind);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);
    dst->elements[len] = alloc::unboxedChar(static_cast<u32>(v_raw & 0xFFFFFFFFu));
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

// unsafeGet: same logic as the boxed root but takes a typed int64_t index.
HPtr Elm_Kernel_JsArray_unsafeGet_Int(int64_t idx, HPtr array) {
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

namespace {

// Returns a copy of `array`, with the same length and kind, and stores that length and kind in `outLen`
// and `outKind`. The caller may then overwrite one element. A GC point.
inline HPointer copyForUnsafeSet(HPtr array, uint32_t &outLen, uint32_t &outKind) {
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

} // namespace

HPtr Elm_Kernel_JsArray_unsafeSet_Int(int64_t idx, int64_t value, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyForUnsafeSet(array, len, kind);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);
    if (static_cast<uint32_t>(idx) < len) dst->elements[idx].i = value;
    dst->header.unboxed = 1;
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_JsArray_unsafeSet_Float(int64_t idx, double value, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyForUnsafeSet(array, len, kind);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);
    if (static_cast<uint32_t>(idx) < len) dst->elements[idx].f = value;
    dst->header.unboxed = 2;
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_JsArray_unsafeSet_Char(int64_t idx, uint64_t value_raw, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyForUnsafeSet(array, len, kind);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);
    if (static_cast<uint32_t>(idx) < len)
        dst->elements[idx] = alloc::unboxedChar(static_cast<u32>(value_raw & 0xFFFFFFFFu));
    dst->header.unboxed = 3;
    return HPtr::fromBits(Export::encode(result));
}

// initialize: same loop as the boxed root with typed Int parameters.
HPtr Elm_Kernel_JsArray_initialize_Int(int64_t size, int64_t offset, HPtr closure) {
    // The `closure` argument is not rooted, so it is decoded into a rooted local before
    // `allocArrayBuilder` can move the closure.
    HPointer closureHP = Export::decode(closure.toBits());
    HPointer arr = alloc::listNil();
    StackRootGuard loopRoots(&arr, &closureHP);

    // The result is a builder while the loop writes it across closure calls.
    arr = alloc::allocArrayBuilder(static_cast<size_t>(size));
    auto& allocator = Allocator::instance();

    alloc::BuilderGuard builderGuard(&arr);
    ResultSlot slot{};
    for (int64_t i = 0; i < size; i++) {
        uint8_t rk = callUnaryInitClosureTyped(closureHP, offset + i, &slot);
        void* arrObj = allocator.resolve(arr);
        pushTypedResult(arrObj, slot, rk);
    }
    builderGuard.clear();
    return HPtr::fromBits(Export::encode(arr));
}

// initializeFromList: typed Int max parameter.
HPtr Elm_Kernel_JsArray_initializeFromList_Int(int64_t max, HPtr list) {
    HPointer result = JsArray::initializeFromList(static_cast<uint32_t>(max),
                                                  Export::decode(list.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

// indexedMap: same loop as the boxed root with typed Int offset.
HPtr Elm_Kernel_JsArray_indexedMap_Int(HPtr closure, int64_t offset, HPtr array) {
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

    StackRootGuard loopRoots(&srcHP, &arr, &closureHP);
    alloc::BuilderGuard builderGuard(&arr);
    ResultSlot slot{};
    for (uint32_t i = 0; i < len; i++) {
        ElmArray* src = static_cast<ElmArray*>(allocator.resolve(srcHP));
        uint64_t elem;
        if (srcKind != 0) {
            elem = Export::encode(alloc::boxElement(src->elements[i], srcKind));
        } else {
            elem = Export::encode(src->elements[i].p);
        }
        uint8_t rk = callBinaryIndexMapClosureTyped(closureHP, offset + i,
                                                    elem, &slot);

        void* arrObj = allocator.resolve(arr);
        pushTypedResult(arrObj, slot, rk);
    }
    builderGuard.clear();
    return HPtr::fromBits(Export::encode(arr));
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
