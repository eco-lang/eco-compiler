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

inline uint64_t callTernaryClosure(HPtr closure_hptr, uint64_t arg1, uint64_t arg2, uint64_t arg3) {
    uint64_t args[3] = { arg1, arg2, arg3 };
    return eco_closure_call_saturated(closure_hptr, args, 3, /*layout=*/nullptr).toBits();
}

inline uint64_t callQuaternaryClosure(HPtr closure_hptr, uint64_t arg1, uint64_t arg2,
                                       uint64_t arg3, uint64_t arg4) {
    uint64_t args[4] = { arg1, arg2, arg3, arg4 };
    return eco_closure_call_saturated(closure_hptr, args, 4, /*layout=*/nullptr).toBits();
}

inline uint64_t callQuinaryClosure(HPtr closure_hptr, uint64_t arg1, uint64_t arg2,
                                    uint64_t arg3, uint64_t arg4, uint64_t arg5) {
    uint64_t args[5] = { arg1, arg2, arg3, arg4, arg5 };
    return eco_closure_call_saturated(closure_hptr, args, 5, /*layout=*/nullptr).toBits();
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
        if (hdr->unboxed & 1) {
            result.push_back(Export::encode(alloc::allocInt(static_cast<int64_t>(cons->head.i))));
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
    if (hdr->unboxed & 1) {
        return Export::encode(alloc::allocInt(static_cast<int64_t>(cons->head.i)));
    } else {
        return Export::encode(cons->head.p);
    }
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
    std::vector<uint64_t> vec = listToVectorU64(Export::decode(list_bits));

    HPointer arr = alloc::allocArray(static_cast<u32>(vec.size()));
    void* arr_ptr = Allocator::instance().resolve(arr);
    ElmArray* elmArr = static_cast<ElmArray*>(arr_ptr);

    for (size_t i = 0; i < vec.size(); i++) {
        elmArr->elements[i].p = Export::decode(vec[i]);
    }
    elmArr->length = static_cast<u32>(vec.size());
    elmArr->header.unboxed = 0;  // Elements are boxed

    return HPtr::fromBits(Export::encode(arr));
}

//===----------------------------------------------------------------------===//
// Higher-order List functions (implemented with closure calling)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_List_map2(HPtr closure, HPtr xs, HPtr ys) {
    uint64_t closure_bits = closure.toBits();
    HPointer xList = Export::decode(xs.toBits());
    HPointer yList = Export::decode(ys.toBits());
    auto& allocator = Allocator::instance();

    std::vector<uint64_t> results;

    while (!alloc::isNil(xList) && !alloc::isNil(yList)) {
        Cons* xCons = static_cast<Cons*>(allocator.resolve(xList));
        Cons* yCons = static_cast<Cons*>(allocator.resolve(yList));

        // Save stable values BEFORE closure call (which may trigger GC)
        HPointer xTail = xCons->tail;
        HPointer yTail = yCons->tail;

        // getConsHead returns HPointer-encoded values (boxes unboxed ints)
        uint64_t x = getConsHead(xCons, &xCons->header);
        uint64_t y = getConsHead(yCons, &yCons->header);

        // Closure result is always HPointer-encoded (wrapper boxes return)
        uint64_t result = callBinaryClosure(closure, x, y);
        results.push_back(result);

        xList = xTail;
        yList = yTail;
    }

    // Results are always HPointer-encoded (boxed)
    return HPtr::fromBits(Export::encode(vectorU64ToList(results, true)));
}

HPtr Elm_Kernel_List_map3(HPtr closure, HPtr xs, HPtr ys, HPtr zs) {
    HPointer xList = Export::decode(xs.toBits());
    HPointer yList = Export::decode(ys.toBits());
    HPointer zList = Export::decode(zs.toBits());
    auto& allocator = Allocator::instance();

    std::vector<uint64_t> results;

    while (!alloc::isNil(xList) && !alloc::isNil(yList) && !alloc::isNil(zList)) {
        Cons* xCons = static_cast<Cons*>(allocator.resolve(xList));
        Cons* yCons = static_cast<Cons*>(allocator.resolve(yList));
        Cons* zCons = static_cast<Cons*>(allocator.resolve(zList));

        HPointer xTail = xCons->tail, yTail = yCons->tail, zTail = zCons->tail;

        uint64_t x = getConsHead(xCons, &xCons->header);
        uint64_t y = getConsHead(yCons, &yCons->header);
        uint64_t z = getConsHead(zCons, &zCons->header);

        uint64_t result = callTernaryClosure(closure, x, y, z);
        results.push_back(result);

        xList = xTail; yList = yTail; zList = zTail;
    }

    return HPtr::fromBits(Export::encode(vectorU64ToList(results, true)));
}

HPtr Elm_Kernel_List_map4(HPtr closure, HPtr ws, HPtr xs, HPtr ys, HPtr zs) {
    HPointer wList = Export::decode(ws.toBits());
    HPointer xList = Export::decode(xs.toBits());
    HPointer yList = Export::decode(ys.toBits());
    HPointer zList = Export::decode(zs.toBits());
    auto& allocator = Allocator::instance();

    std::vector<uint64_t> results;

    while (!alloc::isNil(wList) && !alloc::isNil(xList) &&
           !alloc::isNil(yList) && !alloc::isNil(zList)) {
        Cons* wCons = static_cast<Cons*>(allocator.resolve(wList));
        Cons* xCons = static_cast<Cons*>(allocator.resolve(xList));
        Cons* yCons = static_cast<Cons*>(allocator.resolve(yList));
        Cons* zCons = static_cast<Cons*>(allocator.resolve(zList));

        HPointer wT = wCons->tail, xT = xCons->tail, yT = yCons->tail, zT = zCons->tail;

        uint64_t w = getConsHead(wCons, &wCons->header);
        uint64_t x = getConsHead(xCons, &xCons->header);
        uint64_t y = getConsHead(yCons, &yCons->header);
        uint64_t z = getConsHead(zCons, &zCons->header);

        uint64_t result = callQuaternaryClosure(closure, w, x, y, z);
        results.push_back(result);

        wList = wT; xList = xT; yList = yT; zList = zT;
    }

    return HPtr::fromBits(Export::encode(vectorU64ToList(results, true)));
}

HPtr Elm_Kernel_List_map5(HPtr closure, HPtr vs, HPtr ws,
                           HPtr xs, HPtr ys, HPtr zs) {
    HPointer vList = Export::decode(vs.toBits());
    HPointer wList = Export::decode(ws.toBits());
    HPointer xList = Export::decode(xs.toBits());
    HPointer yList = Export::decode(ys.toBits());
    HPointer zList = Export::decode(zs.toBits());
    auto& allocator = Allocator::instance();

    std::vector<uint64_t> results;

    while (!alloc::isNil(vList) && !alloc::isNil(wList) && !alloc::isNil(xList) &&
           !alloc::isNil(yList) && !alloc::isNil(zList)) {
        Cons* vCons = static_cast<Cons*>(allocator.resolve(vList));
        Cons* wCons = static_cast<Cons*>(allocator.resolve(wList));
        Cons* xCons = static_cast<Cons*>(allocator.resolve(xList));
        Cons* yCons = static_cast<Cons*>(allocator.resolve(yList));
        Cons* zCons = static_cast<Cons*>(allocator.resolve(zList));

        HPointer vT = vCons->tail, wT = wCons->tail, xT = xCons->tail;
        HPointer yT = yCons->tail, zT = zCons->tail;

        uint64_t v = getConsHead(vCons, &vCons->header);
        uint64_t w = getConsHead(wCons, &wCons->header);
        uint64_t x = getConsHead(xCons, &xCons->header);
        uint64_t y = getConsHead(yCons, &yCons->header);
        uint64_t z = getConsHead(zCons, &zCons->header);

        uint64_t result = callQuinaryClosure(closure, v, w, x, y, z);
        results.push_back(result);

        vList = vT; wList = wT; xList = xT; yList = yT; zList = zT;
    }

    return HPtr::fromBits(Export::encode(vectorU64ToList(results, true)));
}

HPtr Elm_Kernel_List_sortBy(HPtr closure, HPtr list) {
    uint64_t list_bits = list.toBits();
    std::vector<uint64_t> elements = listToVectorU64(Export::decode(list_bits));
    auto& allocator = Allocator::instance();

    if (elements.empty()) {
        return HPtr::fromBits(Export::encode(alloc::listNil()));
    }

    // Build key cache: extract key for each element via closure
    std::vector<uint64_t> keys;
    keys.reserve(elements.size());
    for (uint64_t elem : elements) {
        uint64_t key = callUnaryClosure(closure, elem);
        keys.push_back(key);
    }

    // Create index array and sort by keys using Utils::compare
    std::vector<size_t> indices(elements.size());
    std::iota(indices.begin(), indices.end(), 0);

    std::stable_sort(indices.begin(), indices.end(), [&](size_t a, size_t b) {
        // Utils::compare returns Order (heap Custom with ctor 0=LT, 1=EQ, 2=GT)
        // Re-resolve each time since compare may trigger GC
        void* keyA = Export::toPtr(keys[a]);
        void* keyB = Export::toPtr(keys[b]);
        HPointer orderHP = Utils::compare(keyA, keyB);
        void* orderObj = allocator.resolve(orderHP);
        Custom* order = static_cast<Custom*>(orderObj);
        return order->ctor == 0;  // LT
    });

    // Reorder elements according to sorted indices
    std::vector<uint64_t> sorted;
    sorted.reserve(elements.size());
    for (size_t idx : indices) {
        sorted.push_back(elements[idx]);
    }

    // Sort preserves element types - check if original was unboxed
    bool elemIsUnboxed = false;
    HPointer origList = Export::decode(list_bits);
    if (!alloc::isNil(origList)) {
        Header* h = static_cast<Header*>(allocator.resolve(origList));
        elemIsUnboxed = (h->unboxed & 1);
    }
    return HPtr::fromBits(Export::encode(vectorU64ToList(sorted, !elemIsUnboxed)));
}

HPtr Elm_Kernel_List_sortWith(HPtr closure, HPtr list) {
    uint64_t list_bits = list.toBits();
    std::vector<uint64_t> elements = listToVectorU64(Export::decode(list_bits));
    auto& allocator = Allocator::instance();

    if (elements.empty()) {
        return HPtr::fromBits(Export::encode(alloc::listNil()));
    }

    std::stable_sort(elements.begin(), elements.end(), [&](uint64_t a, uint64_t b) {
        uint64_t order = callBinaryClosure(closure, a, b);
        // Order is heap-allocated Custom: ctor 0=LT, 1=EQ, 2=GT
        HPointer orderHP = Export::decode(order);
        Custom* orderVal = static_cast<Custom*>(allocator.resolve(orderHP));
        return orderVal->ctor == 0;  // LT means a < b
    });

    // sortWith preserves element types - check if original was unboxed
    bool elemIsUnboxed = false;
    HPointer origList = Export::decode(list_bits);
    if (!alloc::isNil(origList)) {
        Header* h = static_cast<Header*>(allocator.resolve(origList));
        elemIsUnboxed = (h->unboxed & 1);
    }
    return HPtr::fromBits(Export::encode(vectorU64ToList(elements, !elemIsUnboxed)));
}

} // extern "C"
