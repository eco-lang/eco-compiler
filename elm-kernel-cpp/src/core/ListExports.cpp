//===- ListExports.cpp - C-linkage exports for List module -----------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "List.hpp"
#include "Utils.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include <vector>
#include <algorithm>
#include <numeric>
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

namespace {

//===----------------------------------------------------------------------===//
// Closure-calling helpers (INV_2: delegate to runtime via eco_closure_call_saturated)
//===----------------------------------------------------------------------===//

inline uint64_t callUnaryClosure(HPtr closure_hptr, uint64_t arg) {
    uint64_t args[1] = { arg };
    return eco_closure_call_saturated(closure_hptr, args, 1, /*layout=*/nullptr).toBits();
}

inline uint64_t callBinaryClosure(HPtr closure_hptr, uint64_t arg1, uint64_t arg2) {
    uint64_t args[2] = { arg1, arg2 };
    return eco_closure_call_saturated(closure_hptr, args, 2, /*layout=*/nullptr).toBits();
}

//===----------------------------------------------------------------------===//
// List conversion helpers
//===----------------------------------------------------------------------===//

// Convert list to vector of uint64_t (all HPointer-encoded).
// For unboxed ints, boxes via allocInt so values are HPointer-encoded.
std::vector<uint64_t> listToVectorU64(HPointer list) {
    std::vector<uint64_t> result;
    Allocator& allocator = Allocator::instance();

    HPointer current = list;
    while (!alloc::isNil(current)) {
        void* ptr = allocator.resolve(current);
        if (!ptr) break;

        Header* hdr = static_cast<Header*>(ptr);
        if (hdr->tag != Tag_Cons) break;

        Cons* cons = static_cast<Cons*>(ptr);
        uint32_t kind = Elm::tupleFieldKind(hdr->unboxed, 0);
        if (kind != 0) {
            result.push_back(Export::encode(alloc::boxElement(cons->head, kind)));
        } else {
            result.push_back(Export::encode(cons->head.p));
        }
        current = cons->tail;
    }

    return result;
}

// Convert vector of uint64_t back to list.
// The headIsBoxed parameter determines whether values are stored as
// boxed HPointers (true) or unboxed i64 (false).
HPointer vectorU64ToList(const std::vector<uint64_t>& vec, bool headIsBoxed) {
    HPointer result = alloc::listNil();
    for (auto it = vec.rbegin(); it != vec.rend(); ++it) {
        Unboxable head;
        if (headIsBoxed) {
            head.p = Export::decode(*it);
        } else {
            head.i = static_cast<int64_t>(*it);
        }
        result = List::cons(head, result, headIsBoxed);
    }
    return result;
}

// Legacy helper - convert list to vector of raw pointers
std::vector<void*> listToVector(HPointer list) {
    std::vector<void*> result;
    Allocator& allocator = Allocator::instance();

    HPointer current = list;
    while (!alloc::isNil(current)) {
        void* ptr = allocator.resolve(current);
        if (!ptr) break;

        Header* hdr = static_cast<Header*>(ptr);
        if (hdr->tag != Tag_Cons) break;

        Cons* cons = static_cast<Cons*>(ptr);
        result.push_back(reinterpret_cast<void*>(cons->head.i));
        current = cons->tail;
    }

    return result;
}


// Get element from Cons as uint64_t, always HPointer-encoded.
// For unboxed ints, boxes via allocInt so the wrapper can unbox.
// For boxed values, returns encoded HPointer directly.
inline uint64_t getConsHead(Cons* cons, Header* hdr) {
    uint32_t kind = Elm::tupleFieldKind(hdr->unboxed, 0);
    if (kind != 0) {
        return Export::encode(alloc::boxElement(cons->head, kind));
    } else {
        return Export::encode(cons->head.p);
    }
}

// Snapshot of a Cons cell — extracted with raw access while no allocation
// occurs, so subsequent boxing/closure calls cannot invalidate the bits.
struct ConsBits {
    Unboxable head;
    HPointer  tail;
    uint8_t   kind;  // 0 = boxed HPointer, otherwise primitive kind code
};

inline ConsBits readCons(HPointer listHP) {
    Cons* c = static_cast<Cons*>(Elm::Allocator::instance().resolve(listHP));
    ConsBits cb;
    cb.head = c->head;
    cb.tail = c->tail;
    cb.kind = static_cast<uint8_t>(Elm::tupleFieldKind(c->header.unboxed, 0));
    return cb;
}

//===----------------------------------------------------------------------===//
// Primitive-flow closure invocation (REP_ABI_001)
//
// `Elm_Kernel_List_map2/3/4/5` historically pre-boxed every cons head and
// invoked the user mapper closure via the boxed-result entry point. That
// forced two boxing allocations per Int/Float/Char element: one to hand the
// arg in, one to receive the result. Both are pure overhead when the
// closure itself was monomorphised to take/return primitives — the recent
// `_result_kind` propagation work means virtually every primitive-return
// mapper now publishes its real ABI on the closure header.
//
// The helpers below let the kernel deliver each cons head in its natural
// representation (raw bits for unboxed primitives, HPointer for boxed
// values), build a small `EvalParamLayout` describing that delivery, and
// route through `eco_closure_call_saturated_eval` so the wrapper writes
// the result directly into a typed slot. When the slot kind matches the
// closure's expected kind the splice path skips boxing/unboxing entirely.
//===----------------------------------------------------------------------===//

// Closure metadata snapshot. Read once per iteration *after* every
// potentially-allocating call to avoid stale fields after GC moves the
// closure object.
struct ClosureMeta {
    uint64_t unboxed;     // 2-bit-per-slot ParamKind bitmap (covers all params)
    uint8_t  result_kind; // ParamKind: closure evaluator's return ABI
    uint32_t max_values;  // total stage arity (captures + remaining params)
    uint32_t n_values;    // applied/captured count
};

inline ClosureMeta readClosureMeta(HPointer closureHP) {
    auto* cl = static_cast<Closure*>(
        Elm::Allocator::instance().resolve(closureHP));
    ClosureMeta m;
    m.unboxed     = cl->unboxed;
    m.result_kind = static_cast<uint8_t>(cl->result_kind);
    m.max_values  = static_cast<uint32_t>(cl->max_values);
    m.n_values    = static_cast<uint32_t>(cl->n_values);
    return m;
}

// Kind of the i-th *new* arg slot the closure expects (skipping captures).
// `meta.unboxed` is indexed by absolute slot, so add `meta.n_values`.
inline uint8_t closureNewArgKind(const ClosureMeta& meta, uint32_t i) {
    uint32_t slot = meta.n_values + i;
    return static_cast<uint8_t>((meta.unboxed >> (2 * slot)) & 0x3ULL);
}

// Append one closure result onto the rolling per-iteration result vector.
// Stores the bits in their natural representation per `result_kind` so the
// caller can build a uniform-kind result list at the end without re-boxing.
inline void appendClosureResult(std::vector<Unboxable>& out,
                                const void* result_storage,
                                uint8_t result_kind) {
    Unboxable v;
    switch (result_kind) {
        case 0: {
            HPtr hp;
            std::memcpy(&hp, result_storage, sizeof(HPtr));
            v.p = Elm::Kernel::Export::decode(hp.toBits());
            break;
        }
        case 1: std::memcpy(&v.i, result_storage, sizeof(int64_t)); break;
        case 2: std::memcpy(&v.f, result_storage, sizeof(double));  break;
        default: {
            uint16_t c;
            std::memcpy(&c, result_storage, sizeof(uint16_t));
            v.c = c;
            break;
        }
    }
    out.push_back(v);
}

// Build a list (in source order) from a vector of Unboxables whose kind is
// uniform across all cells. `result_kind` is the 2-bit slot kind to embed
// in each Cons header (0=HPointer head, 1=Int, 2=Float, 3=Char). Calls the
// `u8 head_kind` overload of `cons` directly so Float/Char result lists
// are stored unboxed; the boolean overload would mis-tag them as Int.
inline HPointer unboxableVectorToList(const std::vector<Unboxable>& vec,
                                       uint8_t result_kind) {
    HPointer result = alloc::listNil();
    for (auto it = vec.rbegin(); it != vec.rend(); ++it) {
        result = alloc::cons(*it, result, static_cast<u8>(result_kind & 0x3));
    }
    return result;
}

} // anonymous namespace

extern "C" {

// Simple cons that treats head as boxed pointer.
// For unboxed primitives, a different signature would be needed.
HPtr Elm_Kernel_List_cons(HPtr head, HPtr tail) {
    uint64_t head_bits = head.toBits();
    uint64_t tail_bits = tail.toBits();
    Unboxable headVal;
    headVal.p = Export::decode(head_bits);
    HPointer result = List::cons(headVal, Export::decode(tail_bits), true);
    return HPtr::fromBits(Export::encode(result));
}

// Phase C per-instance variants. Each takes a typed primitive head and
// stores it unboxed in the Cons cell. The 2-bit head_kind in the Cons
// header (1=Int, 2=Float, 3=Char) marks the slot for GC scanning.
HPtr Elm_Kernel_List_cons_Int(int64_t head, HPtr tail) {
    HPointer result = alloc::cons(alloc::unboxedInt(head), Export::decode(tail.toBits()),
                                  /*head_kind=*/static_cast<uint8_t>(1));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_cons_Float(double head, HPtr tail) {
    HPointer result = alloc::cons(alloc::unboxedFloat(head), Export::decode(tail.toBits()),
                                  /*head_kind=*/static_cast<uint8_t>(2));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_cons_Char(uint16_t head, HPtr tail) {
    HPointer result = alloc::cons(alloc::unboxedChar(head), Export::decode(tail.toBits()),
                                  /*head_kind=*/static_cast<uint8_t>(3));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_fromArray(HPtr array) {
    uint64_t array_bits = array.toBits();
    // Check for embedded constants first (e.g., Nil).
    HPointer hp = Export::decode(array_bits);
    if (hp.constant != 0) {
        // Already a constant (Nil, etc.) — pass through unchanged.
        return array;
    }

    void* arr_ptr = Export::toPtr(array_bits);
    if (!arr_ptr) {
        return HPtr::fromBits(Export::encode(alloc::listNil()));
    }

    Header* hdr = static_cast<Header*>(arr_ptr);

    // If already a Cons list, pass through unchanged. This happens when
    // C++ kernel functions (e.g., Elm_Kernel_String_split) return proper
    // Cons lists, but the Elm source wraps with Elm.Kernel.List.fromArray
    // (which in JS converts a JS Array to a Cons list).
    if (hdr->tag == Tag_Cons) {
        return array;
    }

    if (hdr->tag != Tag_Array) {
        return HPtr::fromBits(Export::encode(alloc::listNil()));
    }

    ElmArray* elmArr = static_cast<ElmArray*>(arr_ptr);
    u32 len = elmArr->length;
    bool isUnboxed = elmArr->header.unboxed != 0;

    HPointer result = alloc::listNil();
    for (u32 i = len; i > 0; i--) {
        Unboxable head = elmArr->elements[i - 1];
        result = List::cons(head, result, !isUnboxed);
    }

    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_toArray(HPtr list) {
    uint64_t list_bits = list.toBits();
    // In the C++ backend, kernel functions already work with Cons lists.
    // The Elm source wraps some kernel calls with toArray (because the JS
    // kernel expects JS Arrays), but in C++ this conversion is unnecessary.
    // Pass through Cons lists and Nil unchanged.
    HPointer hp = Export::decode(list_bits);
    if (hp.constant != 0) {
        // Embedded constant (e.g., Nil) — pass through.
        return list;
    }
    void* ptr = Export::toPtr(list_bits);
    if (ptr) {
        Header* hdr = static_cast<Header*>(ptr);
        if (hdr->tag == Tag_Cons) {
            // Already a Cons list — pass through unchanged.
            return list;
        }
    }

    // Genuine Array-to-List conversion (fallback for other callers).
    // listToVectorU64 may allocate (via boxElement on unboxed cons heads), so
    // its output uint64_t HPointer-encoded values must be range-rooted while
    // we then call alloc::allocArray.
    std::vector<uint64_t> vec = listToVectorU64(Export::decode(list_bits));

    // Re-pack the encoded values into HPointers so we can root them as a
    // contiguous range across the array allocation.
    std::vector<HPointer> rooted;
    rooted.reserve(vec.size());
    for (uint64_t e : vec) rooted.push_back(Export::decode(e));

    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    if (!rooted.empty()) {
        rs.pushStackRootRange(rooted.data(), rooted.size(),
                              /*hpointer_mask=*/~uint64_t(0));
    }

    HPointer arr = alloc::allocArray(static_cast<u32>(rooted.size()));
    void* arr_ptr = Allocator::instance().resolve(arr);
    ElmArray* elmArr = static_cast<ElmArray*>(arr_ptr);

    for (size_t i = 0; i < rooted.size(); i++) {
        elmArr->elements[i].p = rooted[i];
    }
    elmArr->length = static_cast<u32>(rooted.size());
    elmArr->header.unboxed = 0;  // Elements are boxed

#if ECO_HEAP_VALIDATE
    for (size_t i = 0; i < rooted.size(); i++)
        Elm::alloc::validateNurseryHPtr(elmArr->elements[i].p);
#endif

    rs.restoreStackRangePoint(saved);
    return HPtr::fromBits(Export::encode(arr));
}

//===----------------------------------------------------------------------===//
// Higher-order List functions (implemented with closure calling)
//===----------------------------------------------------------------------===//

// Shared driver for `Elm_Kernel_List_mapN` (N=2..5). Implements the
// primitive-aware closure-call loop on `n_args` parallel input lists,
// returning a list whose head representation matches the closure's
// `result_kind`. Loop terminates when any input list is exhausted (Elm
// semantics).
//
// Inputs:
//   * `lists[n_args]` — input lists, rooted by the caller across the
//     entire call (we re-pin them per iteration).
//   * `closureHP` — the user's mapper closure, also caller-rooted.
//
// The `n_args == max_values - n_values` check assumes the closure was
// constructed for exactly the arity expected by the kernel; mismatches
// indicate a frontend bug and the splice helper will assert at runtime.
HPointer kernelListMapN(int n_args, HPointer* lists, HPointer& closureHP) {
    static_assert(true, "n_args ∈ {2,3,4,5}");
    constexpr int kMaxArgs = 5;

    auto& allocator = Allocator::instance();
    auto& rs = allocator.getRootSet();

    // Snapshot the closure's per-newarg kinds + result_kind once. The
    // closure object may move under GC, but the kinds it publishes don't
    // change — we re-resolve the pointer each iteration only as needed,
    // not the metadata.
    ClosureMeta meta = readClosureMeta(closureHP);
    uint8_t closureSlotKinds[kMaxArgs] = {0};
    for (int i = 0; i < n_args; ++i) {
        closureSlotKinds[i] = closureNewArgKind(meta, static_cast<uint32_t>(i));
    }
    const uint8_t resultKind = meta.result_kind;

    std::vector<Unboxable> results;

    size_t outerSaved = rs.stackRangePoint();
    rs.pushStackRootRange(lists, n_args, /*hpointer_mask=*/~uint64_t(0));
    rs.pushStackRootRange(&closureHP, 1, 1);

    union ResultSlot {
        int64_t  i;
        double   f;
        uint16_t c;
        HPtr     p;
        uint64_t bits;
    } resultSlot{};

    auto allListsNonempty = [&]() -> bool {
        for (int i = 0; i < n_args; ++i) {
            if (alloc::isNil(lists[i])) return false;
        }
        return true;
    };

    while (allListsNonempty()) {
        ConsBits cb[kMaxArgs];
        for (int i = 0; i < n_args; ++i) cb[i] = readCons(lists[i]);

        // Phase 1: pre-box any cons heads that the closure wants in boxed
        // form. A rolling-prefix root range keeps already-boxed slots
        // alive across later boxing GCs.
        HPointer prebox[kMaxArgs] = {};
        uint8_t  deliveryKinds[kMaxArgs] = {0};
        for (int i = 0; i < n_args; ++i) {
            uint8_t closureKind = closureSlotKinds[i];
            if (cb[i].kind == closureKind && cb[i].kind != 0) {
                deliveryKinds[i] = cb[i].kind;
            } else if (cb[i].kind == 0) {
                deliveryKinds[i] = 0;
                prebox[i] = cb[i].head.p;
            } else if (closureKind == 0) {
                rs.restoreStackRangePoint(outerSaved);
                rs.pushStackRootRange(lists, n_args, /*hpointer_mask=*/~uint64_t(0));
                rs.pushStackRootRange(&closureHP, 1, 1);
                if (i > 0) {
                    rs.pushStackRootRange(prebox, i,
                                          /*hpointer_mask=*/~uint64_t(0));
                }
                if (resultKind == 0 && !results.empty()) {
                    rs.pushStackRootRange(
                        reinterpret_cast<HPointer*>(results.data()),
                        results.size(), /*hpointer_mask=*/~uint64_t(0));
                }
                prebox[i] = Elm::alloc::boxElement(cb[i].head, cb[i].kind);
                deliveryKinds[i] = 0;
            } else {
                deliveryKinds[i] = cb[i].kind;
            }
        }

        // Phase 2: assemble typed args buffer matching deliveryKinds[].
        uint64_t typedArgs[kMaxArgs];
        for (int i = 0; i < n_args; ++i) {
            if (deliveryKinds[i] == 0) {
                typedArgs[i] = static_cast<uint64_t>(Export::encode(prebox[i]));
            } else if (deliveryKinds[i] == 1) {
                typedArgs[i] = static_cast<uint64_t>(cb[i].head.i);
            } else if (deliveryKinds[i] == 2) {
                double f = cb[i].head.f;
                std::memcpy(&typedArgs[i], &f, sizeof(uint64_t));
            } else {
                typedArgs[i] = static_cast<uint64_t>(cb[i].head.c);
            }
        }

        // Layout descriptor: { num=n_args, result_kind, kinds[0..n-1] }.
        // Stack-allocate just enough bytes for this arity.
        unsigned char layoutBuf[2 + kMaxArgs];
        layoutBuf[0] = static_cast<unsigned char>(n_args);
        layoutBuf[1] = resultKind;
        for (int i = 0; i < n_args; ++i) layoutBuf[2 + i] = deliveryKinds[i];

        rs.restoreStackRangePoint(outerSaved);
        rs.pushStackRootRange(lists, n_args, /*hpointer_mask=*/~uint64_t(0));
        rs.pushStackRootRange(&closureHP, 1, 1);
        if (resultKind == 0 && !results.empty()) {
            rs.pushStackRootRange(reinterpret_cast<HPointer*>(results.data()),
                                  results.size(),
                                  /*hpointer_mask=*/~uint64_t(0));
        }

        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        const auto* layout =
            reinterpret_cast<const Elm::EvalParamLayout*>(layoutBuf);
        eco_closure_call_saturated_eval(cl, typedArgs,
                                        static_cast<uint32_t>(n_args),
                                        layout, &resultSlot, resultKind);
        appendClosureResult(results, &resultSlot, resultKind);

        for (int i = 0; i < n_args; ++i) lists[i] = cb[i].tail;
    }

    rs.restoreStackRangePoint(outerSaved);
    if (resultKind == 0 && !results.empty()) {
        rs.pushStackRootRange(reinterpret_cast<HPointer*>(results.data()),
                              results.size(),
                              /*hpointer_mask=*/~uint64_t(0));
    }
    HPointer listResult = unboxableVectorToList(results, resultKind);
    rs.restoreStackRangePoint(outerSaved);
    return listResult;
}

HPtr Elm_Kernel_List_map2(HPtr closure, HPtr xs, HPtr ys) {
    HPointer lists[2] = {
        Export::decode(xs.toBits()),
        Export::decode(ys.toBits()),
    };
    HPointer closureHP = Export::decode(closure.toBits());
    HPointer result = kernelListMapN(2, lists, closureHP);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_map3(HPtr closure, HPtr xs, HPtr ys, HPtr zs) {
    HPointer lists[3] = {
        Export::decode(xs.toBits()),
        Export::decode(ys.toBits()),
        Export::decode(zs.toBits()),
    };
    HPointer closureHP = Export::decode(closure.toBits());
    HPointer result = kernelListMapN(3, lists, closureHP);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_map4(HPtr closure, HPtr ws, HPtr xs, HPtr ys, HPtr zs) {
    HPointer lists[4] = {
        Export::decode(ws.toBits()),
        Export::decode(xs.toBits()),
        Export::decode(ys.toBits()),
        Export::decode(zs.toBits()),
    };
    HPointer closureHP = Export::decode(closure.toBits());
    HPointer result = kernelListMapN(4, lists, closureHP);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_map5(HPtr closure, HPtr vs, HPtr ws,
                           HPtr xs, HPtr ys, HPtr zs) {
    HPointer lists[5] = {
        Export::decode(vs.toBits()),
        Export::decode(ws.toBits()),
        Export::decode(xs.toBits()),
        Export::decode(ys.toBits()),
        Export::decode(zs.toBits()),
    };
    HPointer closureHP = Export::decode(closure.toBits());
    HPointer result = kernelListMapN(5, lists, closureHP);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_sortBy(HPtr closure, HPtr list) {
    auto& allocator = Allocator::instance();

    // Materialise input list once. listToVectorU64 may allocate (boxElement).
    std::vector<uint64_t> elemEnc = listToVectorU64(Export::decode(list.toBits()));
    if (elemEnc.empty()) {
        return HPtr::fromBits(Export::encode(alloc::listNil()));
    }

    // Move HPointer-encoded values into a contiguous HPointer buffer that we
    // can range-root for the duration of the closure-driven key extraction.
    std::vector<HPointer> elements;
    elements.reserve(elemEnc.size());
    for (uint64_t e : elemEnc) elements.push_back(Export::decode(e));

    HPointer closureHP = Export::decode(closure.toBits());

    auto& rs = allocator.getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(elements.data(), elements.size(),
                          /*hpointer_mask=*/~uint64_t(0));
    rs.pushStackRootRange(&closureHP, 1, 1);

    // Extract keys via closure, range-rooting elements, keys, and closure.
    std::vector<HPointer> keys;
    keys.reserve(elements.size());
    for (size_t i = 0; i < elements.size(); ++i) {
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t k = callUnaryClosure(cl, Export::encode(elements[i]));
        keys.push_back(Export::decode(k));

        // Re-pin: keys may have grown its buffer, and the closure call may
        // have invalidated the old base addresses.
        rs.restoreStackRangePoint(saved);
        rs.pushStackRootRange(elements.data(), elements.size(),
                              /*hpointer_mask=*/~uint64_t(0));
        rs.pushStackRootRange(&closureHP, 1, 1);
        rs.pushStackRootRange(keys.data(), keys.size(),
                              /*hpointer_mask=*/~uint64_t(0));
    }

    // Sort indices by keys. `Utils::compare` may allocate (Order Custom);
    // both elements and keys are still range-rooted from above.
    std::vector<size_t> indices(elements.size());
    std::iota(indices.begin(), indices.end(), 0);
    std::stable_sort(indices.begin(), indices.end(), [&](size_t a, size_t b) {
        // Resolve raw pointers strictly for the call to Utils::compare; do
        // not retain them across the call.
        void* keyA = allocator.resolve(keys[a]);
        void* keyB = allocator.resolve(keys[b]);
        HPointer orderHP = Utils::compare(keyA, keyB);
        Custom* order = static_cast<Custom*>(allocator.resolve(orderHP));
        return order->ctor == 0;  // LT
    });

    // Reorder elements; build the result list while keeping the sorted
    // buffer rooted (vectorU64ToList allocates).
    std::vector<HPointer> sorted;
    sorted.reserve(elements.size());
    for (size_t idx : indices) sorted.push_back(elements[idx]);
    rs.restoreStackRangePoint(saved);
    rs.pushStackRootRange(sorted.data(), sorted.size(),
                          /*hpointer_mask=*/~uint64_t(0));

    std::vector<uint64_t> encoded;
    encoded.reserve(sorted.size());
    for (auto& hp : sorted) encoded.push_back(Export::encode(hp));

    HPointer result = vectorU64ToList(encoded, true);
    rs.restoreStackRangePoint(saved);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_List_sortWith(HPtr closure, HPtr list) {
    auto& allocator = Allocator::instance();

    std::vector<uint64_t> elemEnc = listToVectorU64(Export::decode(list.toBits()));
    if (elemEnc.empty()) {
        return HPtr::fromBits(Export::encode(alloc::listNil()));
    }

    std::vector<HPointer> elements;
    elements.reserve(elemEnc.size());
    for (uint64_t e : elemEnc) elements.push_back(Export::decode(e));

    HPointer closureHP = Export::decode(closure.toBits());

    auto& rs = allocator.getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(elements.data(), elements.size(),
                          /*hpointer_mask=*/~uint64_t(0));
    rs.pushStackRootRange(&closureHP, 1, 1);

    std::stable_sort(elements.begin(), elements.end(),
                     [&](HPointer a, HPointer b) {
        // a, b are by-value HPointer copies. They originate from `elements`
        // (range-rooted) but the comparator's local copies need their own
        // root: callBinaryClosure may GC and move both.
        HPointer aRoot = a;
        HPointer bRoot = b;
        size_t innerSaved = rs.stackRangePoint();
        rs.pushStackRootRange(&aRoot, 1, 1);
        rs.pushStackRootRange(&bRoot, 1, 1);

        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t order = callBinaryClosure(cl, Export::encode(aRoot), Export::encode(bRoot));
        HPointer orderHP = Export::decode(order);
        Custom* orderVal = static_cast<Custom*>(allocator.resolve(orderHP));
        bool lt = orderVal->ctor == 0;  // LT means a < b
        rs.restoreStackRangePoint(innerSaved);
        return lt;
    });

    std::vector<uint64_t> encoded;
    encoded.reserve(elements.size());
    for (auto& hp : elements) encoded.push_back(Export::encode(hp));

    HPointer result = vectorU64ToList(encoded, true);
    rs.restoreStackRangePoint(saved);
    return HPtr::fromBits(Export::encode(result));
}

} // extern "C"
