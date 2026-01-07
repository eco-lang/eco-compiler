//===- ListExports.cpp - C-linkage exports for List module -----------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "List.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <vector>
#include <algorithm>
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

namespace {

// Helper to call a closure with given arguments (as raw pointers).
inline uint64_t callClosure(void* closure_ptr, void** args, uint32_t num_args) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    // Build combined argument array: captured values + new args.
    void* combined[16];
    for (uint32_t i = 0; i < n_values; i++) {
        combined[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    for (uint32_t i = 0; i < num_args; i++) {
        combined[n_values + i] = args[i];
    }

    void* result = closure->evaluator(combined);
    return reinterpret_cast<uint64_t>(result);
}

// Convert list to vector of raw pointers.
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

// Convert vector of raw pointers to list.
HPointer vectorToList(const std::vector<void*>& vec) {
    HPointer result = alloc::listNil();
    for (auto it = vec.rbegin(); it != vec.rend(); ++it) {
        Unboxable head;
        head.i = reinterpret_cast<int64_t>(*it);
        result = List::cons(head, result, true);
    }
    return result;
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

    HPointer result = alloc::listNil();
    for (u32 i = len; i > 0; i--) {
        Unboxable head = elmArr->elements[i - 1];
        result = List::cons(head, result, true);
    }

    return Export::encode(result);
}

uint64_t Elm_Kernel_List_toArray(uint64_t list) {
    std::vector<void*> vec = listToVector(Export::decode(list));

    HPointer arr = alloc::allocArray(static_cast<u32>(vec.size()));
    void* arr_ptr = Allocator::instance().resolve(arr);
    ElmArray* elmArr = static_cast<ElmArray*>(arr_ptr);

    for (size_t i = 0; i < vec.size(); i++) {
        elmArr->elements[i].i = reinterpret_cast<int64_t>(vec[i]);
    }
    elmArr->length = static_cast<u32>(vec.size());

    return Export::encode(arr);
}

//===----------------------------------------------------------------------===//
// Higher-order List functions (closure-based) - stubs
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_List_map2(uint64_t closure, uint64_t xs, uint64_t ys) {
    (void)closure; (void)xs; (void)ys;
    assert(false && "Elm_Kernel_List_map2 not implemented");
    return 0;
}

uint64_t Elm_Kernel_List_map3(uint64_t closure, uint64_t xs, uint64_t ys, uint64_t zs) {
    (void)closure; (void)xs; (void)ys; (void)zs;
    assert(false && "Elm_Kernel_List_map3 not implemented");
    return 0;
}

uint64_t Elm_Kernel_List_map4(uint64_t closure, uint64_t ws, uint64_t xs, uint64_t ys, uint64_t zs) {
    (void)closure; (void)ws; (void)xs; (void)ys; (void)zs;
    assert(false && "Elm_Kernel_List_map4 not implemented");
    return 0;
}

uint64_t Elm_Kernel_List_map5(uint64_t closure, uint64_t vs, uint64_t ws, uint64_t xs, uint64_t ys, uint64_t zs) {
    (void)closure; (void)vs; (void)ws; (void)xs; (void)ys; (void)zs;
    assert(false && "Elm_Kernel_List_map5 not implemented");
    return 0;
}

uint64_t Elm_Kernel_List_sortBy(uint64_t closure, uint64_t list) {
    (void)closure; (void)list;
    assert(false && "Elm_Kernel_List_sortBy not implemented");
    return 0;
}

uint64_t Elm_Kernel_List_sortWith(uint64_t closure, uint64_t list) {
    (void)closure; (void)list;
    assert(false && "Elm_Kernel_List_sortWith not implemented");
    return 0;
}

} // extern "C"
