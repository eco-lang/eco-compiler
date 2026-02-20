//===- ListExports.cpp - C-linkage exports for List module -----------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "List.hpp"
#include "Utils.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <vector>
#include <algorithm>
#include <numeric>
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

namespace {

//===----------------------------------------------------------------------===//
// Closure-calling helpers
//===----------------------------------------------------------------------===//

// Call a closure with 1 argument
inline uint64_t callUnaryClosure(void* closure_ptr, uint64_t arg) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    void* args[16];
    for (uint32_t i = 0; i < n_values; i++) {
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    args[n_values] = reinterpret_cast<void*>(arg);

    return reinterpret_cast<uint64_t>(closure->evaluator(args));
}

// Call a closure with 2 arguments
inline uint64_t callBinaryClosure(void* closure_ptr, uint64_t arg1, uint64_t arg2) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    void* args[16];
    for (uint32_t i = 0; i < n_values; i++) {
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    args[n_values] = reinterpret_cast<void*>(arg1);
    args[n_values + 1] = reinterpret_cast<void*>(arg2);

    return reinterpret_cast<uint64_t>(closure->evaluator(args));
}

// Call a closure with 3 arguments
inline uint64_t callTernaryClosure(void* closure_ptr, uint64_t arg1, uint64_t arg2, uint64_t arg3) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    void* args[16];
    for (uint32_t i = 0; i < n_values; i++) {
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    args[n_values] = reinterpret_cast<void*>(arg1);
    args[n_values + 1] = reinterpret_cast<void*>(arg2);
    args[n_values + 2] = reinterpret_cast<void*>(arg3);

    return reinterpret_cast<uint64_t>(closure->evaluator(args));
}

// Call a closure with 4 arguments
inline uint64_t callQuaternaryClosure(void* closure_ptr, uint64_t arg1, uint64_t arg2,
                                       uint64_t arg3, uint64_t arg4) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    void* args[16];
    for (uint32_t i = 0; i < n_values; i++) {
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    args[n_values] = reinterpret_cast<void*>(arg1);
    args[n_values + 1] = reinterpret_cast<void*>(arg2);
    args[n_values + 2] = reinterpret_cast<void*>(arg3);
    args[n_values + 3] = reinterpret_cast<void*>(arg4);

    return reinterpret_cast<uint64_t>(closure->evaluator(args));
}

// Call a closure with 5 arguments
inline uint64_t callQuinaryClosure(void* closure_ptr, uint64_t arg1, uint64_t arg2,
                                    uint64_t arg3, uint64_t arg4, uint64_t arg5) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    void* args[16];
    for (uint32_t i = 0; i < n_values; i++) {
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    args[n_values] = reinterpret_cast<void*>(arg1);
    args[n_values + 1] = reinterpret_cast<void*>(arg2);
    args[n_values + 2] = reinterpret_cast<void*>(arg3);
    args[n_values + 3] = reinterpret_cast<void*>(arg4);
    args[n_values + 4] = reinterpret_cast<void*>(arg5);

    return reinterpret_cast<uint64_t>(closure->evaluator(args));
}

//===----------------------------------------------------------------------===//
// List conversion helpers
//===----------------------------------------------------------------------===//

// Convert list to vector of uint64_t (encoded values).
// Properly handles unboxed Cons heads.
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
        // Check unboxed flag in header to determine how to interpret head
        if (hdr->unboxed & 1) {
            // Head is unboxed primitive - pass raw i64
            result.push_back(static_cast<uint64_t>(cons->head.i));
        } else {
            // Head is boxed HPointer - encode it
            result.push_back(Export::encode(cons->head.p));
        }
        current = cons->tail;
    }

    return result;
}

// Convert vector of uint64_t back to list (all boxed).
HPointer vectorU64ToList(const std::vector<uint64_t>& vec) {
    HPointer result = alloc::listNil();
    for (auto it = vec.rbegin(); it != vec.rend(); ++it) {
        Unboxable head;
        head.p = Export::decode(*it);
        result = List::cons(head, result, true);  // All results are boxed
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

// Legacy helper - convert vector of raw pointers to list
HPointer vectorToList(const std::vector<void*>& vec) {
    HPointer result = alloc::listNil();
    for (auto it = vec.rbegin(); it != vec.rend(); ++it) {
        Unboxable head;
        head.i = reinterpret_cast<int64_t>(*it);
        result = List::cons(head, result, true);
    }
    return result;
}

// Get element from Cons as uint64_t (handles unboxed flag)
inline uint64_t getConsHead(Cons* cons, Header* hdr) {
    if (hdr->unboxed & 1) {
        return static_cast<uint64_t>(cons->head.i);
    } else {
        return Export::encode(cons->head.p);
    }
}

} // anonymous namespace

extern "C" {

// Simple cons that treats head as boxed pointer.
// For unboxed primitives, a different signature would be needed.
uint64_t Elm_Kernel_List_cons(uint64_t head, uint64_t tail) {
    Unboxable headVal;
    headVal.p = Export::decode(head);
    HPointer result = List::cons(headVal, Export::decode(tail), true);
    return Export::encode(result);
}

uint64_t Elm_Kernel_List_fromArray(uint64_t array) {
    void* arr_ptr = Export::toPtr(array);
    if (!arr_ptr) {
        return Export::encode(alloc::listNil());
    }

    Header* hdr = static_cast<Header*>(arr_ptr);
    if (hdr->tag != Tag_Array) {
        return Export::encode(alloc::listNil());
    }

    ElmArray* elmArr = static_cast<ElmArray*>(arr_ptr);
    u32 len = elmArr->length;
    bool isUnboxed = elmArr->unboxed != 0;

    HPointer result = alloc::listNil();
    for (u32 i = len; i > 0; i--) {
        Unboxable head = elmArr->elements[i - 1];
        result = List::cons(head, result, !isUnboxed);
    }

    return Export::encode(result);
}

uint64_t Elm_Kernel_List_toArray(uint64_t list) {
    std::vector<uint64_t> vec = listToVectorU64(Export::decode(list));

    HPointer arr = alloc::allocArray(static_cast<u32>(vec.size()));
    void* arr_ptr = Allocator::instance().resolve(arr);
    ElmArray* elmArr = static_cast<ElmArray*>(arr_ptr);

    for (size_t i = 0; i < vec.size(); i++) {
        elmArr->elements[i].p = Export::decode(vec[i]);
    }
    elmArr->length = static_cast<u32>(vec.size());
    elmArr->unboxed = 0;  // Elements are boxed

    return Export::encode(arr);
}

//===----------------------------------------------------------------------===//
// Higher-order List functions (implemented with closure calling)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_List_map2(uint64_t closure, uint64_t xs, uint64_t ys) {
    void* closure_ptr = Export::toPtr(closure);
    HPointer xList = Export::decode(xs);
    HPointer yList = Export::decode(ys);
    auto& allocator = Allocator::instance();

    std::vector<uint64_t> results;

    while (!alloc::isNil(xList) && !alloc::isNil(yList)) {
        Cons* xCons = static_cast<Cons*>(allocator.resolve(xList));
        Cons* yCons = static_cast<Cons*>(allocator.resolve(yList));
        Header* xHdr = &xCons->header;
        Header* yHdr = &yCons->header;

        uint64_t x = getConsHead(xCons, xHdr);
        uint64_t y = getConsHead(yCons, yHdr);

        uint64_t result = callBinaryClosure(closure_ptr, x, y);
        results.push_back(result);

        xList = xCons->tail;
        yList = yCons->tail;
    }

    return Export::encode(vectorU64ToList(results));
}

uint64_t Elm_Kernel_List_map3(uint64_t closure, uint64_t xs, uint64_t ys, uint64_t zs) {
    void* closure_ptr = Export::toPtr(closure);
    HPointer xList = Export::decode(xs);
    HPointer yList = Export::decode(ys);
    HPointer zList = Export::decode(zs);
    auto& allocator = Allocator::instance();

    std::vector<uint64_t> results;

    while (!alloc::isNil(xList) && !alloc::isNil(yList) && !alloc::isNil(zList)) {
        Cons* xCons = static_cast<Cons*>(allocator.resolve(xList));
        Cons* yCons = static_cast<Cons*>(allocator.resolve(yList));
        Cons* zCons = static_cast<Cons*>(allocator.resolve(zList));
        Header* xHdr = &xCons->header;
        Header* yHdr = &yCons->header;
        Header* zHdr = &zCons->header;

        uint64_t x = getConsHead(xCons, xHdr);
        uint64_t y = getConsHead(yCons, yHdr);
        uint64_t z = getConsHead(zCons, zHdr);

        uint64_t result = callTernaryClosure(closure_ptr, x, y, z);
        results.push_back(result);

        xList = xCons->tail;
        yList = yCons->tail;
        zList = zCons->tail;
    }

    return Export::encode(vectorU64ToList(results));
}

uint64_t Elm_Kernel_List_map4(uint64_t closure, uint64_t ws, uint64_t xs, uint64_t ys, uint64_t zs) {
    void* closure_ptr = Export::toPtr(closure);
    HPointer wList = Export::decode(ws);
    HPointer xList = Export::decode(xs);
    HPointer yList = Export::decode(ys);
    HPointer zList = Export::decode(zs);
    auto& allocator = Allocator::instance();

    std::vector<uint64_t> results;

    while (!alloc::isNil(wList) && !alloc::isNil(xList) &&
           !alloc::isNil(yList) && !alloc::isNil(zList)) {
        Cons* wCons = static_cast<Cons*>(allocator.resolve(wList));
        Cons* xCons = static_cast<Cons*>(allocator.resolve(xList));
        Cons* yCons = static_cast<Cons*>(allocator.resolve(yList));
        Cons* zCons = static_cast<Cons*>(allocator.resolve(zList));
        Header* wHdr = &wCons->header;
        Header* xHdr = &xCons->header;
        Header* yHdr = &yCons->header;
        Header* zHdr = &zCons->header;

        uint64_t w = getConsHead(wCons, wHdr);
        uint64_t x = getConsHead(xCons, xHdr);
        uint64_t y = getConsHead(yCons, yHdr);
        uint64_t z = getConsHead(zCons, zHdr);

        uint64_t result = callQuaternaryClosure(closure_ptr, w, x, y, z);
        results.push_back(result);

        wList = wCons->tail;
        xList = xCons->tail;
        yList = yCons->tail;
        zList = zCons->tail;
    }

    return Export::encode(vectorU64ToList(results));
}

uint64_t Elm_Kernel_List_map5(uint64_t closure, uint64_t vs, uint64_t ws,
                               uint64_t xs, uint64_t ys, uint64_t zs) {
    void* closure_ptr = Export::toPtr(closure);
    HPointer vList = Export::decode(vs);
    HPointer wList = Export::decode(ws);
    HPointer xList = Export::decode(xs);
    HPointer yList = Export::decode(ys);
    HPointer zList = Export::decode(zs);
    auto& allocator = Allocator::instance();

    std::vector<uint64_t> results;

    while (!alloc::isNil(vList) && !alloc::isNil(wList) && !alloc::isNil(xList) &&
           !alloc::isNil(yList) && !alloc::isNil(zList)) {
        Cons* vCons = static_cast<Cons*>(allocator.resolve(vList));
        Cons* wCons = static_cast<Cons*>(allocator.resolve(wList));
        Cons* xCons = static_cast<Cons*>(allocator.resolve(xList));
        Cons* yCons = static_cast<Cons*>(allocator.resolve(yList));
        Cons* zCons = static_cast<Cons*>(allocator.resolve(zList));
        Header* vHdr = &vCons->header;
        Header* wHdr = &wCons->header;
        Header* xHdr = &xCons->header;
        Header* yHdr = &yCons->header;
        Header* zHdr = &zCons->header;

        uint64_t v = getConsHead(vCons, vHdr);
        uint64_t w = getConsHead(wCons, wHdr);
        uint64_t x = getConsHead(xCons, xHdr);
        uint64_t y = getConsHead(yCons, yHdr);
        uint64_t z = getConsHead(zCons, zHdr);

        uint64_t result = callQuinaryClosure(closure_ptr, v, w, x, y, z);
        results.push_back(result);

        vList = vCons->tail;
        wList = wCons->tail;
        xList = xCons->tail;
        yList = yCons->tail;
        zList = zCons->tail;
    }

    return Export::encode(vectorU64ToList(results));
}

uint64_t Elm_Kernel_List_sortBy(uint64_t closure, uint64_t list) {
    void* closure_ptr = Export::toPtr(closure);
    std::vector<uint64_t> elements = listToVectorU64(Export::decode(list));
    auto& allocator = Allocator::instance();

    if (elements.empty()) {
        return Export::encode(alloc::listNil());
    }

    // Build key cache: extract key for each element via closure
    std::vector<uint64_t> keys;
    keys.reserve(elements.size());
    for (uint64_t elem : elements) {
        uint64_t key = callUnaryClosure(closure_ptr, elem);
        keys.push_back(key);
    }

    // Create index array and sort by keys using Utils::compare
    std::vector<size_t> indices(elements.size());
    std::iota(indices.begin(), indices.end(), 0);

    std::stable_sort(indices.begin(), indices.end(), [&](size_t a, size_t b) {
        // Utils::compare returns Order (heap Custom with ctor 0=LT, 1=EQ, 2=GT)
        void* keyA = Export::toPtr(keys[a]);
        void* keyB = Export::toPtr(keys[b]);
        HPointer orderHP = Utils::compare(keyA, keyB);
        Custom* order = static_cast<Custom*>(allocator.resolve(orderHP));
        return order->ctor == 0;  // LT
    });

    // Reorder elements according to sorted indices
    std::vector<uint64_t> sorted;
    sorted.reserve(elements.size());
    for (size_t idx : indices) {
        sorted.push_back(elements[idx]);
    }

    return Export::encode(vectorU64ToList(sorted));
}

uint64_t Elm_Kernel_List_sortWith(uint64_t closure, uint64_t list) {
    void* closure_ptr = Export::toPtr(closure);
    std::vector<uint64_t> elements = listToVectorU64(Export::decode(list));
    auto& allocator = Allocator::instance();

    if (elements.empty()) {
        return Export::encode(alloc::listNil());
    }

    std::stable_sort(elements.begin(), elements.end(), [&](uint64_t a, uint64_t b) {
        uint64_t order = callBinaryClosure(closure_ptr, a, b);
        // Order is heap-allocated Custom: ctor 0=LT, 1=EQ, 2=GT
        HPointer orderHP = Export::decode(order);
        Custom* orderVal = static_cast<Custom*>(allocator.resolve(orderHP));
        return orderVal->ctor == 0;  // LT means a < b
    });

    return Export::encode(vectorU64ToList(elements));
}

} // extern "C"
