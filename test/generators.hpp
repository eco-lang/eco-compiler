#pragma once

#include <rapidcheck.h>
#include <unordered_set>
#include <vector>
#include "heap.hpp"

namespace Elm {

// ============================================================================
// Data Structures - Describe heap objects without side effects
// ============================================================================

// Describes a single heap object (before allocation)
struct HeapObjectDesc {
    enum Type { Int, Float, Char, Tuple2, Tuple3 };

    Type type;

    // Primitive values
    i64 int_val;
    f64 float_val;
    u16 char_val;

    // For composites: indices into the allocated objects array
    // These will be clamped to valid ranges during allocation
    size_t child_a;
    size_t child_b;
    size_t child_c;

    // Boxing flags for composite fields
    bool a_boxed;
    bool b_boxed;
    bool c_boxed;
};

// Describes a complete heap graph with roots
struct HeapGraphDesc {
    std::vector<HeapObjectDesc> nodes;
    std::vector<size_t> root_indices;
};

// ============================================================================
// Allocation - Convert descriptions to actual heap objects
// ============================================================================

// Allocate objects from descriptions
std::vector<void *> allocateHeapGraph(const std::vector<HeapObjectDesc> &nodes);

} // namespace Elm

// ============================================================================
// RapidCheck Generators
// ============================================================================

namespace rc {

template<>
struct Arbitrary<Elm::HeapObjectDesc> {
    static Gen<Elm::HeapObjectDesc> arbitrary() {
        return gen::build<Elm::HeapObjectDesc>(
            gen::set(&Elm::HeapObjectDesc::type,
                     gen::element(Elm::HeapObjectDesc::Int, Elm::HeapObjectDesc::Float, Elm::HeapObjectDesc::Char,
                                  Elm::HeapObjectDesc::Tuple2, Elm::HeapObjectDesc::Tuple3)),
            gen::set(&Elm::HeapObjectDesc::int_val, gen::arbitrary<Elm::i64>()),
            gen::set(&Elm::HeapObjectDesc::float_val, gen::arbitrary<Elm::f64>()),
            gen::set(&Elm::HeapObjectDesc::char_val, gen::inRange<Elm::u16>(0, 0xFFFF)),
            // Child indices - will be clamped during allocation
            gen::set(&Elm::HeapObjectDesc::child_a, gen::arbitrary<size_t>()),
            gen::set(&Elm::HeapObjectDesc::child_b, gen::arbitrary<size_t>()),
            gen::set(&Elm::HeapObjectDesc::child_c, gen::arbitrary<size_t>()),
            // Boxing flags
            gen::set(&Elm::HeapObjectDesc::a_boxed, gen::arbitrary<bool>()),
            gen::set(&Elm::HeapObjectDesc::b_boxed, gen::arbitrary<bool>()),
            gen::set(&Elm::HeapObjectDesc::c_boxed, gen::arbitrary<bool>()));
    }
};

template<>
struct Arbitrary<Elm::HeapGraphDesc> {
    static Gen<Elm::HeapGraphDesc> arbitrary() {
        auto rawGen = gen::build<Elm::HeapGraphDesc>(
            gen::set(&Elm::HeapGraphDesc::nodes,
                     gen::resize(100, gen::nonEmpty(gen::arbitrary<std::vector<Elm::HeapObjectDesc>>()))),
            gen::set(&Elm::HeapGraphDesc::root_indices, gen::arbitrary<std::vector<size_t>>()));

        return gen::map(rawGen, [](Elm::HeapGraphDesc graph) {
            // Clamp root indices to valid range and ensure we have at least one root
            if (graph.nodes.empty()) {
                graph.root_indices.clear();
                return graph;
            }

            // Ensure at least one root, up to 50% of nodes
            if (graph.root_indices.empty()) {
                graph.root_indices.push_back(0);
            }

            size_t max_roots = graph.nodes.size() / 2 + 1;
            if (graph.root_indices.size() > max_roots) {
                graph.root_indices.resize(max_roots);
            }

            // Clamp all indices and remove duplicates
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
