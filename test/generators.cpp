#include "generators.hpp"
#include "allocator.hpp"
#include <algorithm>

namespace Elm {

// ============================================================================
// Allocation Implementation
// ============================================================================

static Unboxable makeUnboxable(bool is_boxed, const HeapObjectDesc& desc,
                               const std::vector<void*>& allocated, size_t child_index) {
    Unboxable val;

    if (is_boxed && !allocated.empty()) {
        // Boxed: pointer to existing object
        // Clamp child_index to valid range
        size_t idx = child_index % allocated.size();
        val.p = toPointer(allocated[idx]);
    } else {
        // Unboxed: use primitive value from description
        // Choose which primitive based on type hint
        switch (desc.type) {
            case HeapObjectDesc::Int:
                val.i = desc.int_val;
                break;
            case HeapObjectDesc::Float:
                val.f = desc.float_val;
                break;
            case HeapObjectDesc::Char:
            default:
                val.c = desc.char_val;
                break;
        }
    }

    return val;
}

std::vector<void*> allocateHeapGraph(const std::vector<HeapObjectDesc>& nodes) {
    auto& gc = GarbageCollector::instance();
    std::vector<void*> allocated;
    allocated.reserve(nodes.size());

    // Allocate all objects
    for (const auto& desc : nodes) {
        void* obj = nullptr;

        switch (desc.type) {
            case HeapObjectDesc::Int: {
                obj = gc.allocate(sizeof(ElmInt), Tag_Int);
                ElmInt* elm_int = static_cast<ElmInt*>(obj);
                elm_int->value = desc.int_val;
                break;
            }

            case HeapObjectDesc::Float: {
                obj = gc.allocate(sizeof(ElmFloat), Tag_Float);
                ElmFloat* elm_float = static_cast<ElmFloat*>(obj);
                elm_float->value = desc.float_val;
                break;
            }

            case HeapObjectDesc::Char: {
                obj = gc.allocate(sizeof(ElmChar), Tag_Char);
                ElmChar* elm_char = static_cast<ElmChar*>(obj);
                elm_char->value = desc.char_val;
                break;
            }

            case HeapObjectDesc::Tuple2: {
                obj = gc.allocate(sizeof(Tuple2), Tag_Tuple2);
                Tuple2* tuple = static_cast<Tuple2*>(obj);
                Header* hdr = getHeader(obj);

                // Create fields (may reference previously allocated objects)
                tuple->a = makeUnboxable(desc.a_boxed, desc, allocated, desc.child_a);
                tuple->b = makeUnboxable(desc.b_boxed, desc, allocated, desc.child_b);

                // Set unboxed flags
                hdr->unboxed = 0;
                if (!desc.a_boxed) hdr->unboxed |= 1;
                if (!desc.b_boxed) hdr->unboxed |= 2;
                break;
            }

            case HeapObjectDesc::Tuple3: {
                obj = gc.allocate(sizeof(Tuple3), Tag_Tuple3);
                Tuple3* tuple = static_cast<Tuple3*>(obj);
                Header* hdr = getHeader(obj);

                // Create fields (may reference previously allocated objects)
                tuple->a = makeUnboxable(desc.a_boxed, desc, allocated, desc.child_a);
                tuple->b = makeUnboxable(desc.b_boxed, desc, allocated, desc.child_b);
                tuple->c = makeUnboxable(desc.c_boxed, desc, allocated, desc.child_c);

                // Set unboxed flags
                hdr->unboxed = 0;
                if (!desc.a_boxed) hdr->unboxed |= 1;
                if (!desc.b_boxed) hdr->unboxed |= 2;
                if (!desc.c_boxed) hdr->unboxed |= 4;
                break;
            }
        }

        if (obj) {
            allocated.push_back(obj);
        }
    }

    return allocated;
}

} // namespace Elm
