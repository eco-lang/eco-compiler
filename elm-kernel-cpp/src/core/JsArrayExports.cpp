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
// Closure-calling helpers.
//
// Higher-order kernels can't statically tell whether the user closure has
// been monomorphised flat or as a multi-stage curry — both shapes are
// valid. So we route through `eco_apply_closure{,_eval}`, which read the
// closure header at runtime and dispatch under-saturated / saturated /
// over-saturated correctly. Strict-arity entries are an unsafe API for
// user-facing kernels (see closure-callback audit).
//===----------------------------------------------------------------------===//

// Layout descriptors for the closure invocations below: each declares the
// per-arg ParamKind so the runtime can pass unboxed Int arguments straight
// through to wrappers that accept them, instead of forcing an `eco_alloc_int`
// per call here. Layout bytes match `EvalParamLayout`:
//   { num_params, result_kind, kinds... }
//
// The result_kind byte is patched per-call from `closure->result_kind` so
// we can route through `eco_apply_closure_eval` and skip the dispatch-side
// box on PK_Int/Float/Char-returning mappers (REP_ABI_001).
static constexpr unsigned char kLayoutInt1[3]      = { 1, 0, 1 };       // (Int)
static constexpr unsigned char kLayoutIntBoxed[4]  = { 2, 0, 1, 0 };    // (Int, a)

// Read the closure's `result_kind` field once. Used by the typed-result
// helpers below to set both the EvalParamLayout's result_kind byte and the
// `desired_kind` argument to `eco_apply_closure_eval`.
static uint8_t readClosureResultKind(HPointer closureHP) {
    auto* cl = static_cast<Elm::Closure*>(
        Elm::Allocator::instance().resolve(closureHP));
    return static_cast<uint8_t>(cl->result_kind);
}

// Per-iteration scratch slot receiving the closure's typed primitive
// return (or boxed HPtr). Caller passes its address as `result_slot`.
union ResultSlot {
    int64_t  i;
    double   f;
    uint16_t c;
    Elm::HPtr p;
    uint64_t bits;
};

// Call a closure with one Int argument and a primitive-aware result.
// `closureHP` must already be rooted by the caller. Returns the
// closure's `result_kind` so the caller can interpret `slot` correctly:
// 0 → slot.p (HPtr), 1 → slot.i, 2 → slot.f, 3 → slot.c.
static uint8_t callUnaryInitClosureTyped(HPointer closureHP,
                                          int64_t index,
                                          ResultSlot* slot) {
    uint8_t resultKind = readClosureResultKind(closureHP);
    unsigned char layoutBuf[3] = { 1, resultKind, 1 };
    const auto* layout =
        reinterpret_cast<const Elm::EvalParamLayout*>(layoutBuf);
    uint64_t args[1] = { static_cast<uint64_t>(index) };
    Elm::HPtr cl = Elm::HPtr::fromBits(Elm::Kernel::Export::encode(closureHP));
    eco_apply_closure_eval(cl, reinterpret_cast<int64_t*>(args), 1, layout, slot, resultKind);
    return resultKind;
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

// Push the typed primitive (or HPtr) result of a closure call onto an
// array, tagging the array's slot kind so subsequent reads decode the
// element correctly without re-resolving via header tag.
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
            u.c = slot.c;
            alloc::arrayPushKind(arrObj, u, 3);
            return;
    }
}

// Typed-result variant for indexedMap: routes through
// `eco_apply_closure_eval` (PAP-aware) so primitive returns avoid the
// dispatch-side box. `closureHP` must be rooted by the caller.
static uint8_t callBinaryIndexMapClosureTyped(HPointer closureHP,
                                              int64_t index, uint64_t elem,
                                              ResultSlot* slot) {
    uint8_t resultKind = readClosureResultKind(closureHP);
    unsigned char layoutBuf[4] = { 2, resultKind, 1, 0 };
    const auto* layout =
        reinterpret_cast<const Elm::EvalParamLayout*>(layoutBuf);
    uint64_t args[2] = { static_cast<uint64_t>(index), elem };
    Elm::HPtr cl = Elm::HPtr::fromBits(Elm::Kernel::Export::encode(closureHP));
    eco_apply_closure_eval(cl, reinterpret_cast<int64_t*>(args), 2, layout, slot, resultKind);
    return resultKind;
}

// Typed-result fold helper: the kernel passes
// `acc` in its current convention (HPtr or raw primitive bits as
// indicated by `accKind`), and the closure's `result_kind` selects the
// receive ABI for `slot`. This lets foldl/foldr carry a primitive
// accumulator across iterations without a per-step box→unbox cycle.
//
// `closureHP` must be rooted by the caller; `slot` is filled with the
// closure's typed return whose interpretation matches the function's
// returned `result_kind`.
static uint8_t callBinaryFoldClosureTyped(HPointer closureHP,
                                          uint64_t elem,
                                          uint64_t acc, uint8_t accKind,
                                          ResultSlot* slot) {
    uint8_t resultKind = readClosureResultKind(closureHP);
    unsigned char layoutBuf[4] = { 2, resultKind, /*elem*/0, accKind };
    const auto* layout =
        reinterpret_cast<const Elm::EvalParamLayout*>(layoutBuf);
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
    // Pre-read the unboxed primitive (if any) before the alloc — `valHP`
    // stays rooted, but reading from a Tag_Int/Float/Char body before the
    // alloc means we don't have to re-resolve `value` afterwards.
    int64_t unboxedPrim = 0;
    if (srcUnboxed) {
        void* valPtr = (valHP.constant == 0 && valHP.ptr != 0)
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

    // Root `closureHP` BEFORE `allocArrayBuilder` — that allocation is a GC
    // point, and the by-value `closure` parameter is unrooted on the
    // caller's stack, so the closure HPointer becomes stale across
    // allocArrayBuilder. Decoding into a stack-rooted local before the
    // alloc, and re-encoding inside the loop, picks up the post-GC
    // location.
    HPointer closureHP = Export::decode(closure.toBits());
    HPointer arr = alloc::listNil();  // placeholder until alloc below
    StackRootGuard loopRoots(&arr, &closureHP);

    // allocArrayBuilder + BuilderGuard pin the result array to nursery for
    // the duration of the loop (HEAP_BUILDER_001/003). Without this, a
    // minor GC fired by a user closure could promote a half-built array
    // and the next slot write would plant a nursery HPointer into an
    // old-gen parent.
    arr = alloc::allocArrayBuilder(static_cast<size_t>(size));
    alloc::BuilderGuard builderGuard(&arr);
    auto& allocator = Allocator::instance();

    ResultSlot slot{};
    for (int64_t i = 0; i < size; i++) {
        // Typed-result entry: skip the dispatch-side box on PK_Int/Float/
        // Char-returning mappers (see _Int sibling for rationale).
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
        // Pin the result array to nursery while the loop mutates it
        // across closure calls (HEAP_BUILDER_001/003).
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
        // Typed-result entry: deliver the (possibly boxed) element to the
        // closure and write its primitive return straight into `slot`.
        // Use `eco_apply_closure_eval` (PAP-aware) so curried/partially-
        // applied user mappers don't trip the strict-arity assertion.
        uint8_t resultKind = readClosureResultKind(closureHP);
        unsigned char layoutBuf[3] = { 1, resultKind, 0 };
        const auto* layout =
            reinterpret_cast<const Elm::EvalParamLayout*>(layoutBuf);
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
        // Pin the result array to nursery (HEAP_BUILDER_001/003).
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
        // Typed-result entry: skip the dispatch-side box.
        uint8_t rk = callBinaryIndexMapClosureTyped(closureHP, offset + i,
                                                    elem, &slot);
        void* arrObj = allocator.resolve(arr);
        pushTypedResult(arrObj, slot, rk);
    }
    builderGuard.clear();
    return HPtr::fromBits(Export::encode(arr));
}

// Shared driver for foldl/foldr. `forward=true` walks 0..len-1 (foldl);
// false walks len-1..0 (foldr).
//
// Carries `acc` across iterations in its closure-natural representation:
// the first iteration receives `acc` as an HPtr (caller-provided boxed
// value). Each closure call writes the new acc into a typed slot
// (`accKind == closure->result_kind`); subsequent iterations pass that
// slot's bits directly with a layout-kind hint, so primitive accumulators
// (Int/Float/Char foldl over Int/Float/Char arrays) avoid both the
// dispatch-side box AND the splice-side unbox per step.
//
// Element delivery is left at the original "always boxed HPtr" convention:
// promoting unboxed cons heads to primitive args would mostly help the
// kernel-helper splice case which is already at zero in our trace.
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

        // Adopt the closure's natural result representation as the next
        // iteration's acc. For boxed results, also re-pin accHP via the
        // dedicated root range so the next iteration's allocations see
        // the post-GC location.
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

    // Hand the final accumulator back as HPtr. Box once if it ended up
    // primitive; the caller sees the legacy `HPtr` return type.
    if (accKind == 0) {
        return HPtr::fromBits(accBits);
    }
    Unboxable u;
    switch (accKind) {
        case 1: u.i = static_cast<int64_t>(accBits); break;
        case 2: std::memcpy(&u.f, &accBits, sizeof(double)); break;
        default: u.c = static_cast<u16>(accBits); break;
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
// Phase C per-instance JsArray kernel variants.
//
// Element-axis variants (singleton, push, unsafeSet) take a typed primitive
// element. Int-axis variants (unsafeGet, slice, appendN, initialize,
// initializeFromList, indexedMap) take typed int64_t for their Int
// parameters. Most simply delegate to existing helpers (the eco.array.*
// intrinsic trampolines already cover singleton/push/slice/appendN); the
// rest replicate the matching boxed-root behaviour with the unboxing step
// elided.
//===----------------------------------------------------------------------===//

// singleton: delegate to the existing typed trampolines.
HPtr Elm_Kernel_JsArray_singleton_Int  (int64_t  v) { return elm_array_singleton_int(v); }
HPtr Elm_Kernel_JsArray_singleton_Float(double   v) { return elm_array_singleton_float(v); }
HPtr Elm_Kernel_JsArray_singleton_Char (uint16_t v) { return elm_array_singleton_char(v); }

// push: delegate to the existing typed trampolines.
HPtr Elm_Kernel_JsArray_push_Int  (int64_t  v, HPtr array) { return elm_array_push_int(v, array); }
HPtr Elm_Kernel_JsArray_push_Float(double   v, HPtr array) { return elm_array_push_float(v, array); }
HPtr Elm_Kernel_JsArray_push_Char (uint16_t v, HPtr array) { return elm_array_push_char(v, array); }

// slice: delegate to the existing typed trampoline.
HPtr Elm_Kernel_JsArray_slice_Int(int64_t start, int64_t end, HPtr array) {
    return elm_array_slice(start, end, array);
}

// appendN: delegate to the existing typed trampoline.
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

// Copy `src` into a new array of the same length. Used by the unsafeSet
// variants below; returns the new array's HPointer plus its length and kind.
// Caller must overwrite elements[idx] with the new typed value before the
// returned HPointer escapes.
inline HPointer copyForUnsafeSet(HPtr array, uint32_t &outLen, uint32_t &outKind) {
    uint64_t array_bits = array.toBits();
    void* srcPtr = Export::toPtr(array_bits);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    uint32_t kind = src->header.unboxed & 0x3;

    HPointer result = alloc::allocArray(len);
    srcPtr = Export::toPtr(array_bits);
    src = static_cast<ElmArray*>(srcPtr);
    void* dstPtr = Allocator::instance().resolve(result);
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

HPtr Elm_Kernel_JsArray_unsafeSet_Char(int64_t idx, uint16_t value, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyForUnsafeSet(array, len, kind);
    void* dstPtr = Allocator::instance().resolve(result);
    ElmArray* dst = static_cast<ElmArray*>(dstPtr);
    if (static_cast<uint32_t>(idx) < len) dst->elements[idx].c = value;
    dst->header.unboxed = 3;
    return HPtr::fromBits(Export::encode(result));
}

// initialize: same loop as the boxed root with typed Int parameters.
HPtr Elm_Kernel_JsArray_initialize_Int(int64_t size, int64_t offset, HPtr closure) {
    // Pin the result array to nursery (HEAP_BUILDER_001/003).
    HPointer arr = alloc::allocArrayBuilder(static_cast<size_t>(size));
    HPointer closureHP = Export::decode(closure.toBits());
    auto& allocator = Allocator::instance();

    StackRootGuard loopRoots(&arr, &closureHP);
    alloc::BuilderGuard builderGuard(&arr);
    ResultSlot slot{};
    for (int64_t i = 0; i < size; i++) {
        // Typed-result entry: when the user mapper returns an Int/Float/
        // Char the wrapper writes the primitive directly into `slot`,
        // so this path no longer pays an `eco_alloc_int` per call.
        // `pushTypedResult` then stores the primitive unboxed in the
        // result array, mirroring what the boxed path produced via
        // `pushUnboxedResult` but without the box→unbox round-trip.
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
        // Pin the result array to nursery (HEAP_BUILDER_001/003) — without
        // this, a minor GC inside callBinaryIndexMapClosureTyped could
        // promote the half-built array and the next slot write would plant
        // a nursery HPointer in an old-gen parent.
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
        // Typed-result entry: skip the dispatch-side box on PK_Int/Float/
        // Char-returning mappers. `pushTypedResult` stores the primitive
        // unboxed in the result array directly.
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
