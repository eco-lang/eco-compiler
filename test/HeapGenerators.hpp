#pragma once

#include <rapidcheck.h>
#include <unordered_set>
#include <vector>
#include "Heap.hpp"

namespace Elm {

// ============================================================================
// Data Structures - Describe heap objects without side effects.
// ============================================================================

/** Unboxed value types (primitives and embedded constants). */
enum Unboxed {
    UnboxedInt,
    UnboxedFloat,
    UnboxedChar,
    UnboxedUnit,
    UnboxedEmptyRec,
    UnboxedTrue,
    UnboxedFalse,
    UnboxedNil,
    UnboxedNothing,
    UnboxedEmptyString
};

/** Describes a Cons cell head for list generation. */
struct ConsHeadDesc {
    bool head_boxed;
    size_t child_index;  // Index for boxed head.
    Unboxed unboxed;     // Type of unboxed value when !head_boxed.
    i64 int_val;
    f64 float_val;
    u16 char_val;
};

/** Describes a linked list (allocated as Cons cells terminated by Nil). */
struct ListDesc {
    std::vector<ConsHeadDesc> elements;  // RapidCheck can shrink this.
};

/** Describes a single heap object before allocation. */
struct HeapObjectDesc {
    enum Type { Int, Float, Char, String, Tuple2, Tuple3, Custom, Record, DynRecord, FieldGroup, Closure };

    Type type;
    Unboxed unboxed;  // Type of unboxed value (for fields marked !boxed).

    // Primitive values.
    i64 int_val;
    f64 float_val;
    u16 char_val;

    // For Tuple2/Tuple3: indices into the allocated objects array.
    size_t child_a;
    size_t child_b;
    size_t child_c;

    // Boxing flags for Tuple2/Tuple3.
    bool a_boxed;
    bool b_boxed;
    bool c_boxed;

    // For String.
    std::vector<u16> string_chars;

    // For Custom.
    u16 ctor;
    std::vector<bool> custom_values_boxed;
    std::vector<size_t> custom_child_values;

    // For Record.
    std::vector<bool> record_values_boxed;
    std::vector<size_t> record_child_values;

    // For DynRecord.
    size_t dynrec_child_fieldgroup;
    std::vector<size_t> dynrec_child_values;

    // For FieldGroup.
    std::vector<u32> fieldgroup_ids;

    // For Closure.
    u64 closure_evaluator_dummy;
    std::vector<bool> closure_values_boxed;
    std::vector<size_t> closure_child_values;
};

/** Describes a complete heap graph with designated roots. */
struct HeapGraphDesc {
    std::vector<HeapObjectDesc> nodes;   // All objects in the graph.
    std::vector<size_t> root_indices;    // Indices of root objects.
};

// ============================================================================
// Allocation - Convert descriptions to actual heap objects.
// ============================================================================

// Allocates heap objects from the given descriptions.
std::vector<void *> allocateHeapGraph(const std::vector<HeapObjectDesc> &nodes);

// Allocates a linked list from the description.
HPointer allocateList(const ListDesc& list_desc,
                      const std::vector<void*>& allocated);

} // namespace Elm

// ============================================================================
// RapidCheck Generators for property-based testing.
// ============================================================================

namespace rc {

// Size-scaled range generator with minimum floor.
// At size=0, generates in range [min_val, base_max)
// At larger sizes, upper bound grows: [min_val, base_max + size * scale_factor)
template<typename T>
Gen<T> sizedRange(T min_val, T base_max, double scale_factor = 0.1) {
    return gen::withSize([=](int size) {
        T max_val = static_cast<T>(base_max + size * scale_factor);
        max_val = std::max(max_val, min_val + 1);  // Ensure valid range.
        return gen::inRange<T>(min_val, max_val);
    });
}

template<>
struct Arbitrary<Elm::ConsHeadDesc> {
    static Gen<Elm::ConsHeadDesc> arbitrary() {
        return gen::build<Elm::ConsHeadDesc>(
            gen::set(&Elm::ConsHeadDesc::head_boxed, gen::arbitrary<bool>()),
            gen::set(&Elm::ConsHeadDesc::child_index, gen::arbitrary<size_t>()),
            gen::set(&Elm::ConsHeadDesc::unboxed,
                     gen::element(Elm::UnboxedInt,
                                  Elm::UnboxedFloat,
                                  Elm::UnboxedChar,
                                  Elm::UnboxedUnit,
                                  Elm::UnboxedEmptyRec,
                                  Elm::UnboxedTrue,
                                  Elm::UnboxedFalse,
                                  Elm::UnboxedNil,
                                  Elm::UnboxedNothing,
                                  Elm::UnboxedEmptyString)),
            gen::set(&Elm::ConsHeadDesc::int_val, gen::arbitrary<Elm::i64>()),
            gen::set(&Elm::ConsHeadDesc::float_val, gen::arbitrary<Elm::f64>()),
            gen::set(&Elm::ConsHeadDesc::char_val, gen::inRange<Elm::u16>(0, 0xFFFF))
        );
    }
};

template<>
struct Arbitrary<Elm::ListDesc> {
    static Gen<Elm::ListDesc> arbitrary() {
        // Generate lists with geometric-like distribution.
        // RapidCheck will automatically shrink by removing elements.
        return gen::build<Elm::ListDesc>(
            gen::set(&Elm::ListDesc::elements,
                     gen::scale(0.75, gen::arbitrary<std::vector<Elm::ConsHeadDesc>>()))
        );
    }
};

template<>
struct Arbitrary<Elm::HeapObjectDesc> {
    static Gen<Elm::HeapObjectDesc> arbitrary() {
        return gen::build<Elm::HeapObjectDesc>(
            gen::set(&Elm::HeapObjectDesc::type,
                     gen::element(Elm::HeapObjectDesc::Int,
                                  Elm::HeapObjectDesc::Float,
                                  Elm::HeapObjectDesc::Char,
                                  Elm::HeapObjectDesc::String,
                                  Elm::HeapObjectDesc::Tuple2,
                                  Elm::HeapObjectDesc::Tuple3,
                                  Elm::HeapObjectDesc::Custom,
                                  Elm::HeapObjectDesc::Record,
                                  Elm::HeapObjectDesc::DynRecord,
                                  Elm::HeapObjectDesc::FieldGroup,
                                  Elm::HeapObjectDesc::Closure)),
            gen::set(&Elm::HeapObjectDesc::unboxed,
                     gen::element(Elm::UnboxedInt,
                                  Elm::UnboxedFloat,
                                  Elm::UnboxedChar,
                                  Elm::UnboxedUnit,
                                  Elm::UnboxedEmptyRec,
                                  Elm::UnboxedTrue,
                                  Elm::UnboxedFalse,
                                  Elm::UnboxedNil,
                                  Elm::UnboxedNothing,
                                  Elm::UnboxedEmptyString)),
            gen::set(&Elm::HeapObjectDesc::int_val, gen::arbitrary<Elm::i64>()),
            gen::set(&Elm::HeapObjectDesc::float_val, gen::arbitrary<Elm::f64>()),
            gen::set(&Elm::HeapObjectDesc::char_val, gen::inRange<Elm::u16>(0, 0xFFFF)),
            // Child indices for Tuple2/Tuple3.
            gen::set(&Elm::HeapObjectDesc::child_a, gen::arbitrary<size_t>()),
            gen::set(&Elm::HeapObjectDesc::child_b, gen::arbitrary<size_t>()),
            gen::set(&Elm::HeapObjectDesc::child_c, gen::arbitrary<size_t>()),
            // Boxing flags for Tuple2/Tuple3.
            gen::set(&Elm::HeapObjectDesc::a_boxed, gen::arbitrary<bool>()),
            gen::set(&Elm::HeapObjectDesc::b_boxed, gen::arbitrary<bool>()),
            gen::set(&Elm::HeapObjectDesc::c_boxed, gen::arbitrary<bool>()),
            // String fields - ensure non-empty to avoid 8-byte objects that can't hold 16-byte forward pointers.
            gen::set(&Elm::HeapObjectDesc::string_chars,
                     gen::resize(100, gen::nonEmpty(gen::arbitrary<std::vector<Elm::u16>>()))),
            // Custom fields.
            gen::set(&Elm::HeapObjectDesc::ctor, gen::arbitrary<Elm::u16>()),
            gen::set(&Elm::HeapObjectDesc::custom_values_boxed,
                     gen::resize(20, gen::arbitrary<std::vector<bool>>())),
            gen::set(&Elm::HeapObjectDesc::custom_child_values,
                     gen::arbitrary<std::vector<size_t>>()),
            // Record fields.
            gen::set(&Elm::HeapObjectDesc::record_values_boxed,
                     gen::resize(20, gen::arbitrary<std::vector<bool>>())),
            gen::set(&Elm::HeapObjectDesc::record_child_values,
                     gen::arbitrary<std::vector<size_t>>()),
            // DynRecord fields.
            gen::set(&Elm::HeapObjectDesc::dynrec_child_fieldgroup, gen::arbitrary<size_t>()),
            gen::set(&Elm::HeapObjectDesc::dynrec_child_values,
                     gen::arbitrary<std::vector<size_t>>()),
            // FieldGroup fields.
            gen::set(&Elm::HeapObjectDesc::fieldgroup_ids,
                     gen::resize(20, gen::arbitrary<std::vector<Elm::u32>>())),
            // Closure fields.
            gen::set(&Elm::HeapObjectDesc::closure_evaluator_dummy, gen::arbitrary<Elm::u64>()),
            gen::set(&Elm::HeapObjectDesc::closure_values_boxed,
                     gen::resize(20, gen::arbitrary<std::vector<bool>>())),
            gen::set(&Elm::HeapObjectDesc::closure_child_values,
                     gen::arbitrary<std::vector<size_t>>())
        );
    }
};

template<>
struct Arbitrary<Elm::HeapGraphDesc> {
    static Gen<Elm::HeapGraphDesc> arbitrary() {
        // Use gen::scale to allow size-sensitive growth while keeping it manageable.
        // With scale(0.1), max-size 1 gives ~1 node, max-size 1000 gives ~100 nodes.
        auto rawGen = gen::build<Elm::HeapGraphDesc>(
            gen::set(&Elm::HeapGraphDesc::nodes,
                     gen::scale(0.1, gen::nonEmpty(gen::arbitrary<std::vector<Elm::HeapObjectDesc>>()))),
            gen::set(&Elm::HeapGraphDesc::root_indices, gen::arbitrary<std::vector<size_t>>()));

        return gen::map(rawGen, [](Elm::HeapGraphDesc graph) {
            // Clamp root indices to valid range and ensure we have at least one root.
            if (graph.nodes.empty()) {
                graph.root_indices.clear();
                return graph;
            }

            // Ensure at least one root, up to 50% of nodes.
            if (graph.root_indices.empty()) {
                graph.root_indices.push_back(0);
            }

            size_t max_roots = graph.nodes.size() / 2 + 1;
            if (graph.root_indices.size() > max_roots) {
                graph.root_indices.resize(max_roots);
            }

            // Clamp all indices and remove duplicates.
            std::unordered_set<size_t> unique_roots;
            for (size_t &idx: graph.root_indices) {
                idx = idx % graph.nodes.size();
                unique_roots.insert(idx);
            }
            graph.root_indices.assign(unique_roots.begin(), unique_roots.end());

            return graph;
        });
    }
};

} // namespace rc
