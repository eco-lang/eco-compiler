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

// Box a ConsBits head, returning an HPointer. Allocates iff the head is an
// unboxed primitive. Caller must root any other live HPointers across the
// call when kind != 0.
inline Elm::HPointer boxConsBitsHead(const ConsBits& cb) {
    if (cb.kind == 0) return cb.head.p;
    return Elm::alloc::boxElement(cb.head, cb.kind);
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

#if ECO_GC_DEBUG
    for (size_t i = 0; i < rooted.size(); i++)
        Elm::alloc::validateNurseryHPtr(elmArr->elements[i].p);
#endif

    rs.restoreStackRangePoint(saved);
    return HPtr::fromBits(Export::encode(arr));
}

//===----------------------------------------------------------------------===//
// Higher-order List functions (implemented with closure calling)
//===----------------------------------------------------------------------===//

// ----------------------------------------------------------------------------
// GC-rooting helpers shared by List_mapN.
//
// Box up to N cons heads (returning an HPointer per head) while keeping all
// previously-boxed heads alive. Each `boxElement` call may trigger a GC, so
// the rolling-frontier of already-boxed HPointers must remain rooted.
//
// `boxed` must point to an array of length n; on input each entry should
// equal the corresponding `bits[i].head.p` if `bits[i].kind == 0`. On output
// each entry holds the boxed HPointer.
// ----------------------------------------------------------------------------
inline void boxConsHeadsRooted(const ConsBits* bits, Elm::HPointer* boxed, size_t n) {
    auto& rs = Elm::Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    for (size_t i = 0; i < n; ++i) {
        // Re-pin the rolling prefix [0..i) of already-boxed HPointers.
        rs.restoreStackRangePoint(saved);
        if (i > 0) rs.pushStackRootRange(boxed, i, /*hpointer_mask=*/~uint64_t(0));
        boxed[i] = boxConsBitsHead(bits[i]);
    }
    rs.restoreStackRangePoint(saved);
}

// Push a rolling-pin set onto the root set covering: `lists` (n entries),
// `results` buffer, and any additional pointers in `extras`. Caller must
// `restoreStackRangePoint(saved)` before returning.
inline size_t pinMapRoots(Elm::HPointer* lists, size_t n,
                          Elm::HPointer* results, size_t resultCount,
                          std::initializer_list<Elm::HPointer*> extras) {
    auto& rs = Elm::Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(lists, n, /*hpointer_mask=*/~uint64_t(0));
    if (resultCount > 0) {
        rs.pushStackRootRange(results, resultCount, /*hpointer_mask=*/~uint64_t(0));
    }
    for (Elm::HPointer* p : extras) rs.pushStackRootRange(p, 1, 1);
    return saved;
}

HPtr Elm_Kernel_List_map2(HPtr closure, HPtr xs, HPtr ys) {
    auto& allocator = Allocator::instance();
    HPointer lists[2] = { Export::decode(xs.toBits()), Export::decode(ys.toBits()) };
    HPointer closureHP = Export::decode(closure.toBits());
    std::vector<HPointer> results;

    auto& rs = allocator.getRootSet();
    size_t outerSaved = rs.stackRangePoint();
    rs.pushStackRootRange(lists, 2, /*hpointer_mask=*/~uint64_t(0));
    rs.pushStackRootRange(&closureHP, 1, 1);

    while (!alloc::isNil(lists[0]) && !alloc::isNil(lists[1])) {
        ConsBits cb[2];
        cb[0] = readCons(lists[0]);
        cb[1] = readCons(lists[1]);

        HPointer boxed[2];
        boxConsHeadsRooted(cb, boxed, 2);

        // Root boxed heads + lists + closure + results across the closure call.
        rs.restoreStackRangePoint(outerSaved);
        rs.pushStackRootRange(lists, 2, /*hpointer_mask=*/~uint64_t(0));
        rs.pushStackRootRange(&closureHP, 1, 1);
        rs.pushStackRootRange(boxed, 2, /*hpointer_mask=*/~uint64_t(0));
        if (!results.empty()) {
            rs.pushStackRootRange(results.data(), results.size(),
                                  /*hpointer_mask=*/~uint64_t(0));
        }

        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t result = callBinaryClosure(cl,
            Export::encode(boxed[0]), Export::encode(boxed[1]));
        results.push_back(Export::decode(result));

        lists[0] = cb[0].tail;
        lists[1] = cb[1].tail;
        // Re-pin lists+closure+results for the next iteration.
        rs.restoreStackRangePoint(outerSaved);
        rs.pushStackRootRange(lists, 2, /*hpointer_mask=*/~uint64_t(0));
        rs.pushStackRootRange(&closureHP, 1, 1);
        if (!results.empty()) {
            rs.pushStackRootRange(results.data(), results.size(),
                                  /*hpointer_mask=*/~uint64_t(0));
        }
    }

    // Convert results (HPointer) back to encoded uint64_t for the existing
    // vectorU64ToList helper. Keep results pinned across the encode/listFrom.
    std::vector<uint64_t> encoded;
    encoded.reserve(results.size());
    for (auto& hp : results) encoded.push_back(Export::encode(hp));

    HPointer listResult = vectorU64ToList(encoded, true);
    rs.restoreStackRangePoint(outerSaved);
    return HPtr::fromBits(Export::encode(listResult));
}

HPtr Elm_Kernel_List_map3(HPtr closure, HPtr xs, HPtr ys, HPtr zs) {
    auto& allocator = Allocator::instance();
    HPointer lists[3] = {
        Export::decode(xs.toBits()),
        Export::decode(ys.toBits()),
        Export::decode(zs.toBits())
    };
    HPointer closureHP = Export::decode(closure.toBits());
    std::vector<HPointer> results;

    auto& rs = allocator.getRootSet();
    size_t outerSaved = rs.stackRangePoint();
    rs.pushStackRootRange(lists, 3, /*hpointer_mask=*/~uint64_t(0));
    rs.pushStackRootRange(&closureHP, 1, 1);

    while (!alloc::isNil(lists[0]) && !alloc::isNil(lists[1]) && !alloc::isNil(lists[2])) {
        ConsBits cb[3];
        for (int i = 0; i < 3; i++) cb[i] = readCons(lists[i]);

        HPointer boxed[3];
        boxConsHeadsRooted(cb, boxed, 3);

        rs.restoreStackRangePoint(outerSaved);
        rs.pushStackRootRange(lists, 3, /*hpointer_mask=*/~uint64_t(0));
        rs.pushStackRootRange(&closureHP, 1, 1);
        rs.pushStackRootRange(boxed, 3, /*hpointer_mask=*/~uint64_t(0));
        if (!results.empty()) {
            rs.pushStackRootRange(results.data(), results.size(),
                                  /*hpointer_mask=*/~uint64_t(0));
        }

        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t result = callTernaryClosure(cl,
            Export::encode(boxed[0]), Export::encode(boxed[1]), Export::encode(boxed[2]));
        results.push_back(Export::decode(result));

        for (int i = 0; i < 3; i++) lists[i] = cb[i].tail;
        rs.restoreStackRangePoint(outerSaved);
        rs.pushStackRootRange(lists, 3, /*hpointer_mask=*/~uint64_t(0));
        rs.pushStackRootRange(&closureHP, 1, 1);
        if (!results.empty()) {
            rs.pushStackRootRange(results.data(), results.size(),
                                  /*hpointer_mask=*/~uint64_t(0));
        }
    }

    std::vector<uint64_t> encoded;
    encoded.reserve(results.size());
    for (auto& hp : results) encoded.push_back(Export::encode(hp));

    HPointer listResult = vectorU64ToList(encoded, true);
    rs.restoreStackRangePoint(outerSaved);
    return HPtr::fromBits(Export::encode(listResult));
}

HPtr Elm_Kernel_List_map4(HPtr closure, HPtr ws, HPtr xs, HPtr ys, HPtr zs) {
    auto& allocator = Allocator::instance();
    HPointer lists[4] = {
        Export::decode(ws.toBits()),
        Export::decode(xs.toBits()),
        Export::decode(ys.toBits()),
        Export::decode(zs.toBits())
    };
    HPointer closureHP = Export::decode(closure.toBits());
    std::vector<HPointer> results;

    auto& rs = allocator.getRootSet();
    size_t outerSaved = rs.stackRangePoint();
    rs.pushStackRootRange(lists, 4, /*hpointer_mask=*/~uint64_t(0));
    rs.pushStackRootRange(&closureHP, 1, 1);

    while (!alloc::isNil(lists[0]) && !alloc::isNil(lists[1]) &&
           !alloc::isNil(lists[2]) && !alloc::isNil(lists[3])) {
        ConsBits cb[4];
        for (int i = 0; i < 4; i++) cb[i] = readCons(lists[i]);

        HPointer boxed[4];
        boxConsHeadsRooted(cb, boxed, 4);

        rs.restoreStackRangePoint(outerSaved);
        rs.pushStackRootRange(lists, 4, /*hpointer_mask=*/~uint64_t(0));
        rs.pushStackRootRange(&closureHP, 1, 1);
        rs.pushStackRootRange(boxed, 4, /*hpointer_mask=*/~uint64_t(0));
        if (!results.empty()) {
            rs.pushStackRootRange(results.data(), results.size(),
                                  /*hpointer_mask=*/~uint64_t(0));
        }

        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t result = callQuaternaryClosure(cl,
            Export::encode(boxed[0]), Export::encode(boxed[1]),
            Export::encode(boxed[2]), Export::encode(boxed[3]));
        results.push_back(Export::decode(result));

        for (int i = 0; i < 4; i++) lists[i] = cb[i].tail;
        rs.restoreStackRangePoint(outerSaved);
        rs.pushStackRootRange(lists, 4, /*hpointer_mask=*/~uint64_t(0));
        rs.pushStackRootRange(&closureHP, 1, 1);
        if (!results.empty()) {
            rs.pushStackRootRange(results.data(), results.size(),
                                  /*hpointer_mask=*/~uint64_t(0));
        }
    }

    std::vector<uint64_t> encoded;
    encoded.reserve(results.size());
    for (auto& hp : results) encoded.push_back(Export::encode(hp));

    HPointer listResult = vectorU64ToList(encoded, true);
    rs.restoreStackRangePoint(outerSaved);
    return HPtr::fromBits(Export::encode(listResult));
}

HPtr Elm_Kernel_List_map5(HPtr closure, HPtr vs, HPtr ws,
                           HPtr xs, HPtr ys, HPtr zs) {
    auto& allocator = Allocator::instance();
    HPointer lists[5] = {
        Export::decode(vs.toBits()),
        Export::decode(ws.toBits()),
        Export::decode(xs.toBits()),
        Export::decode(ys.toBits()),
        Export::decode(zs.toBits())
    };
    HPointer closureHP = Export::decode(closure.toBits());
    std::vector<HPointer> results;

    auto& rs = allocator.getRootSet();
    size_t outerSaved = rs.stackRangePoint();
    rs.pushStackRootRange(lists, 5, /*hpointer_mask=*/~uint64_t(0));
    rs.pushStackRootRange(&closureHP, 1, 1);

    while (!alloc::isNil(lists[0]) && !alloc::isNil(lists[1]) && !alloc::isNil(lists[2]) &&
           !alloc::isNil(lists[3]) && !alloc::isNil(lists[4])) {
        ConsBits cb[5];
        for (int i = 0; i < 5; i++) cb[i] = readCons(lists[i]);

        HPointer boxed[5];
        boxConsHeadsRooted(cb, boxed, 5);

        rs.restoreStackRangePoint(outerSaved);
        rs.pushStackRootRange(lists, 5, /*hpointer_mask=*/~uint64_t(0));
        rs.pushStackRootRange(&closureHP, 1, 1);
        rs.pushStackRootRange(boxed, 5, /*hpointer_mask=*/~uint64_t(0));
        if (!results.empty()) {
            rs.pushStackRootRange(results.data(), results.size(),
                                  /*hpointer_mask=*/~uint64_t(0));
        }

        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t result = callQuinaryClosure(cl,
            Export::encode(boxed[0]), Export::encode(boxed[1]),
            Export::encode(boxed[2]), Export::encode(boxed[3]), Export::encode(boxed[4]));
        results.push_back(Export::decode(result));

        for (int i = 0; i < 5; i++) lists[i] = cb[i].tail;
        rs.restoreStackRangePoint(outerSaved);
        rs.pushStackRootRange(lists, 5, /*hpointer_mask=*/~uint64_t(0));
        rs.pushStackRootRange(&closureHP, 1, 1);
        if (!results.empty()) {
            rs.pushStackRootRange(results.data(), results.size(),
                                  /*hpointer_mask=*/~uint64_t(0));
        }
    }

    std::vector<uint64_t> encoded;
    encoded.reserve(results.size());
    for (auto& hp : results) encoded.push_back(Export::encode(hp));

    HPointer listResult = vectorU64ToList(encoded, true);
    rs.restoreStackRangePoint(outerSaved);
    return HPtr::fromBits(Export::encode(listResult));
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
