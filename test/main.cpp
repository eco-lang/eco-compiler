#include <iostream>
#include <rapidcheck.h>
#include <unordered_set>
#include <vector>
#include "allocator.hpp"
#include "generators.hpp"
#include "heap.hpp"

using namespace Elm;

// Helper to create a deep copy snapshot of heap structure for validation
struct HeapSnapshot {
    struct SnapshotNode {
        Tag tag;
        std::vector<size_t> children; // Indices into snapshot array
        union {
            i64 int_val;
            f64 float_val;
            u16 char_val;
            struct {
                Unboxable a, b;
                u32 unboxed;
            } tuple2;
            struct {
                Unboxable a, b, c;
                u32 unboxed;
            } tuple3;
        } data;
    };

    std::vector<SnapshotNode> nodes;
    std::vector<size_t> root_indices;

    // Capture the current state of objects
    void capture(const std::vector<void *> &objects, const std::vector<HPointer *> &roots) {
        nodes.clear();
        root_indices.clear();

        std::unordered_map<void *, size_t> obj_to_idx;

        // First pass: create snapshot nodes
        for (size_t i = 0; i < objects.size(); i++) {
            void *obj = objects[i];
            if (!obj)
                continue;

            obj_to_idx[obj] = nodes.size();
            SnapshotNode node;
            Header *hdr = getHeader(obj);
            node.tag = static_cast<Tag>(hdr->tag);

            switch (node.tag) {
                case Tag_Int:
                    node.data.int_val = static_cast<ElmInt *>(obj)->value;
                    break;
                case Tag_Float:
                    node.data.float_val = static_cast<ElmFloat *>(obj)->value;
                    break;
                case Tag_Char:
                    node.data.char_val = static_cast<ElmChar *>(obj)->value;
                    break;
                case Tag_Tuple2: {
                    Tuple2 *t = static_cast<Tuple2 *>(obj);
                    node.data.tuple2.a = t->a;
                    node.data.tuple2.b = t->b;
                    node.data.tuple2.unboxed = hdr->unboxed;
                    break;
                }
                case Tag_Tuple3: {
                    Tuple3 *t = static_cast<Tuple3 *>(obj);
                    node.data.tuple3.a = t->a;
                    node.data.tuple3.b = t->b;
                    node.data.tuple3.c = t->c;
                    node.data.tuple3.unboxed = hdr->unboxed;
                    break;
                }
                // For other types, we just verify the tag and structure
                default:
                    break;
            }

            nodes.push_back(node);
        }

        // Second pass: resolve pointer children
        for (size_t i = 0; i < objects.size(); i++) {
            void *obj = objects[i];
            if (!obj)
                continue;

            Header *hdr = getHeader(obj);
            size_t node_idx = obj_to_idx[obj];

            switch (hdr->tag) {
                case Tag_Tuple2: {
                    Tuple2 *t = static_cast<Tuple2 *>(obj);
                    if (!(hdr->unboxed & 1) && t->a.p.constant == 0) {
                        void *child = fromPointer(t->a.p);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    if (!(hdr->unboxed & 2) && t->b.p.constant == 0) {
                        void *child = fromPointer(t->b.p);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    break;
                }
                case Tag_Tuple3: {
                    Tuple3 *t = static_cast<Tuple3 *>(obj);
                    if (!(hdr->unboxed & 1) && t->a.p.constant == 0) {
                        void *child = fromPointer(t->a.p);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    if (!(hdr->unboxed & 2) && t->b.p.constant == 0) {
                        void *child = fromPointer(t->b.p);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    if (!(hdr->unboxed & 4) && t->c.p.constant == 0) {
                        void *child = fromPointer(t->c.p);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    break;
                }
                case Tag_Cons: {
                    Cons *cons = static_cast<Cons *>(obj);
                    // Track head if boxed
                    if (!(hdr->unboxed & 1) && cons->head.p.constant == 0) {
                        void *child = fromPointer(cons->head.p);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    // Track tail (always a pointer, may be Nil)
                    if (cons->tail.constant == 0) {
                        void *child = fromPointer(cons->tail);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    break;
                }
                case Tag_Custom: {
                    Custom *custom = static_cast<Custom *>(obj);
                    for (size_t i = 0; i < hdr->size && i < 48; i++) {
                        if (!(custom->unboxed & (1ULL << i)) && custom->values[i].p.constant == 0) {
                            void *child = fromPointer(custom->values[i].p);
                            if (child && obj_to_idx.count(child)) {
                                nodes[node_idx].children.push_back(obj_to_idx[child]);
                            }
                        }
                    }
                    break;
                }
                case Tag_Record: {
                    Record *record = static_cast<Record *>(obj);
                    for (size_t i = 0; i < hdr->size && i < 64; i++) {
                        if (!(record->unboxed & (1ULL << i)) && record->values[i].p.constant == 0) {
                            void *child = fromPointer(record->values[i].p);
                            if (child && obj_to_idx.count(child)) {
                                nodes[node_idx].children.push_back(obj_to_idx[child]);
                            }
                        }
                    }
                    break;
                }
                case Tag_DynRecord: {
                    DynRecord *dynrec = static_cast<DynRecord *>(obj);
                    // Track fieldgroup
                    if (dynrec->fieldgroup.constant == 0) {
                        void *child = fromPointer(dynrec->fieldgroup);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    // Track all values (all HPointers)
                    for (size_t i = 0; i < hdr->size; i++) {
                        if (dynrec->values[i].constant == 0) {
                            void *child = fromPointer(dynrec->values[i]);
                            if (child && obj_to_idx.count(child)) {
                                nodes[node_idx].children.push_back(obj_to_idx[child]);
                            }
                        }
                    }
                    break;
                }
                case Tag_Closure: {
                    Closure *closure = static_cast<Closure *>(obj);
                    for (size_t i = 0; i < closure->n_values && i < 52; i++) {
                        if (!(closure->unboxed & (1ULL << i)) && closure->values[i].p.constant == 0) {
                            void *child = fromPointer(closure->values[i].p);
                            if (child && obj_to_idx.count(child)) {
                                nodes[node_idx].children.push_back(obj_to_idx[child]);
                            }
                        }
                    }
                    break;
                }
                // String and FieldGroup have no heap pointers
                default:
                    break;
            }
        }

        // Record root indices
        for (HPointer *root: roots) {
            if (root->constant != 0)
                continue;
            void *obj = fromPointer(*root);
            if (obj && obj_to_idx.count(obj)) {
                root_indices.push_back(obj_to_idx[obj]);
            }
        }
    }

    // Verify that the current heap matches the snapshot (after GC)
    bool verify(const std::vector<HPointer *> &roots) const {
        std::unordered_set<void *> reachable;
        std::unordered_map<void *, size_t> obj_to_snapshot_idx;

        // Build reachable set from roots
        std::vector<void *> worklist;
        for (HPointer *root: roots) {
            if (root->constant != 0) {
                continue;
            }
            void *obj = fromPointer(*root);
            if (obj) {
                worklist.push_back(obj);
                reachable.insert(obj);
            }
        }

        while (!worklist.empty()) {
            void *obj = worklist.back();
            worklist.pop_back();

            Header *hdr = getHeader(obj);

            // Safety check: tag should be valid
            if (hdr->tag >= Tag_Forward) {
                std::cerr << "ERROR: Invalid tag " << hdr->tag << " found in reachable object at " << obj << std::endl;
                return false;
            }

            switch (hdr->tag) {
                case Tag_Tuple2: {
                    Tuple2 *t = static_cast<Tuple2 *>(obj);
                    if (!(hdr->unboxed & 1) && t->a.p.constant == 0) {
                        void *child = fromPointer(t->a.p);
                        if (child && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    if (!(hdr->unboxed & 2) && t->b.p.constant == 0) {
                        void *child = fromPointer(t->b.p);
                        if (child && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    break;
                }
                case Tag_Tuple3: {
                    Tuple3 *t = static_cast<Tuple3 *>(obj);
                    if (!(hdr->unboxed & 1) && t->a.p.constant == 0) {
                        void *child = fromPointer(t->a.p);
                        if (child && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    if (!(hdr->unboxed & 2) && t->b.p.constant == 0) {
                        void *child = fromPointer(t->b.p);
                        if (child && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    if (!(hdr->unboxed & 4) && t->c.p.constant == 0) {
                        void *child = fromPointer(t->c.p);
                        if (child && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    break;
                }
                case Tag_Cons: {
                    Cons *cons = static_cast<Cons *>(obj);
                    if (!(hdr->unboxed & 1) && cons->head.p.constant == 0) {
                        void *child = fromPointer(cons->head.p);
                        if (child && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    if (cons->tail.constant == 0) {
                        void *child = fromPointer(cons->tail);
                        if (child && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    break;
                }
                case Tag_Custom: {
                    Custom *custom = static_cast<Custom *>(obj);
                    for (size_t i = 0; i < hdr->size && i < 48; i++) {
                        if (!(custom->unboxed & (1ULL << i)) && custom->values[i].p.constant == 0) {
                            void *child = fromPointer(custom->values[i].p);
                            if (child && reachable.insert(child).second) {
                                worklist.push_back(child);
                            }
                        }
                    }
                    break;
                }
                case Tag_Record: {
                    Record *record = static_cast<Record *>(obj);
                    for (size_t i = 0; i < hdr->size && i < 64; i++) {
                        if (!(record->unboxed & (1ULL << i)) && record->values[i].p.constant == 0) {
                            void *child = fromPointer(record->values[i].p);
                            if (child && reachable.insert(child).second) {
                                worklist.push_back(child);
                            }
                        }
                    }
                    break;
                }
                case Tag_DynRecord: {
                    DynRecord *dynrec = static_cast<DynRecord *>(obj);
                    if (dynrec->fieldgroup.constant == 0) {
                        void *child = fromPointer(dynrec->fieldgroup);
                        if (child && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    for (size_t i = 0; i < hdr->size; i++) {
                        if (dynrec->values[i].constant == 0) {
                            void *child = fromPointer(dynrec->values[i]);
                            if (child && reachable.insert(child).second) {
                                worklist.push_back(child);
                            }
                        }
                    }
                    break;
                }
                case Tag_Closure: {
                    Closure *closure = static_cast<Closure *>(obj);
                    for (size_t i = 0; i < closure->n_values && i < 52; i++) {
                        if (!(closure->unboxed & (1ULL << i)) && closure->values[i].p.constant == 0) {
                            void *child = fromPointer(closure->values[i].p);
                            if (child && reachable.insert(child).second) {
                                worklist.push_back(child);
                            }
                        }
                    }
                    break;
                }
                default:
                    break;
            }
        }

        // Verify we have at least as many objects as root indices
        if (reachable.size() < root_indices.size()) {
            std::cerr << "ERROR: Lost objects during GC! Expected at least " << root_indices.size() << " but found "
                      << reachable.size() << std::endl;
            return false;
        }

        // Verify structure and values of reachable objects
        std::vector<void *> reachable_vec(reachable.begin(), reachable.end());

        for (void *obj: reachable_vec) {
            Header *hdr = getHeader(obj);

            // Verify tag is valid
            if (hdr->tag >= Tag_Forward) {
                std::cerr << "ERROR: Invalid tag " << hdr->tag << " found in reachable object" << std::endl;
                return false;
            }

            // Verify values match snapshot for primitive types
            switch (hdr->tag) {
                case Tag_Int: {
                    ElmInt *obj_int = static_cast<ElmInt *>(obj);
                    bool found = false;
                    for (const auto &node: nodes) {
                        if (node.tag == Tag_Int && node.data.int_val == obj_int->value) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        std::cerr << "ERROR: Int value " << obj_int->value << " not found in snapshot" << std::endl;
                        return false;
                    }
                    break;
                }
                case Tag_Float: {
                    ElmFloat *obj_float = static_cast<ElmFloat *>(obj);
                    bool found = false;
                    for (const auto &node: nodes) {
                        if (node.tag == Tag_Float && node.data.float_val == obj_float->value) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        std::cerr << "ERROR: Float value " << obj_float->value << " not found in snapshot" << std::endl;
                        return false;
                    }
                    break;
                }
                case Tag_Char: {
                    ElmChar *obj_char = static_cast<ElmChar *>(obj);
                    bool found = false;
                    for (const auto &node: nodes) {
                        if (node.tag == Tag_Char && node.data.char_val == obj_char->value) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        std::cerr << "ERROR: Char value " << obj_char->value << " not found in snapshot" << std::endl;
                        return false;
                    }
                    break;
                }
                default:
                    // For complex types, we've already verified structure
                    break;
            }
        }

        return true;
    }
};


// Property test: GC preserves reachable objects
void test_gc_preserves_roots() {
    rc::check("GC preserves all reachable objects from roots", [](const HeapGraphDesc &graph) {
        // Initialize GC for this thread
        auto &gc = GarbageCollector::instance();
        gc.initThread();

        // Phase 1: Allocate heap from description (RapidCheck can shrink this!)
        std::vector<void *> allocated_objects = allocateHeapGraph(graph.nodes);
        RC_ASSERT(!allocated_objects.empty());

        // Phase 2: Set up roots from graph description
        std::vector<HPointer> root_storage;
        std::vector<HPointer *> root_ptrs;

        for (size_t idx: graph.root_indices) {
            if (idx < allocated_objects.size()) {
                root_storage.push_back(toPointer(allocated_objects[idx]));
            }
        }

        for (auto &root: root_storage) {
            root_ptrs.push_back(&root);
            gc.getRootSet().addRoot(&root);
        }

        RC_ASSERT(!root_ptrs.empty());

        // Phase 3: Take snapshot before GC
        HeapSnapshot snapshot;
        snapshot.capture(allocated_objects, root_ptrs);

        // Phase 4: Perform minor GC
        gc.minorGC();

        // Phase 5: Verify all roots still intact and valid
        bool valid = snapshot.verify(root_ptrs);

        // Cleanup roots
        for (auto *root: root_ptrs) {
            gc.getRootSet().removeRoot(root);
        }

        RC_ASSERT(valid);
    });
}

// Property test: Unreachable objects are collected
void test_gc_collects_garbage() {
    rc::check("GC collects unreachable objects", [](const std::vector<HeapObjectDesc> &objects) {
        auto &gc = GarbageCollector::instance();
        gc.initThread();
        auto *nursery = gc.getNursery();

        // Need at least some objects to test collection
        RC_PRE(!objects.empty() && objects.size() >= 10);

        // Allocate objects without adding to roots
        size_t initial_used = nursery->bytesAllocated();

        std::vector<void *> allocated = allocateHeapGraph(objects);

        size_t used_before_gc = nursery->bytesAllocated();
        RC_ASSERT(used_before_gc > initial_used);

        // GC should collect everything (no roots)
        gc.minorGC();

        size_t used_after_gc = nursery->bytesAllocated();

        // After GC with no roots, nursery should be mostly empty
        RC_ASSERT(used_after_gc < used_before_gc / 2);
    });
}

// Property test: Multiple GC cycles preserve roots
void test_multiple_gc_cycles() {
    rc::check("Multiple GC cycles preserve roots correctly", []() {
        // Generate proper test parameters directly using custom generator
        auto testGen = rc::gen::tuple(rc::gen::arbitrary<i64>(), // int_value
                                      rc::gen::inRange(3, 11), // num_cycles (3-10 inclusive)
                                      rc::gen::container<std::vector<std::vector<HeapObjectDesc>>>(
                                          10, // Generate exactly 10 garbage vectors (covers max cycles)
                                          rc::gen::arbitrary<std::vector<HeapObjectDesc>>()));

        auto params = *testGen;
        auto [int_value, num_cycles, garbage_per_cycle] = params;

        auto &gc = GarbageCollector::instance();
        gc.initThread();

        // Create a long-lived Int object as root
        void *root_obj = gc.allocate(sizeof(ElmInt), Tag_Int);
        ElmInt *elm_int = static_cast<ElmInt *>(root_obj);
        elm_int->value = int_value;

        HPointer root_ptr = toPointer(root_obj);
        gc.getRootSet().addRoot(&root_ptr);

        i64 original_value = elm_int->value;

        // Run multiple GC cycles
        for (int i = 0; i < num_cycles; i++) {
            // Check value before GC
            void *current_obj = fromPointer(root_ptr);
            i64 before_value = static_cast<ElmInt *>(current_obj)->value;

            // Allocate garbage between cycles from generated descriptions
            if (i < static_cast<int>(garbage_per_cycle.size())) {
                allocateHeapGraph(garbage_per_cycle[i]);
            }

            gc.minorGC();

            // Check value after GC
            void *after_obj = fromPointer(root_ptr);
            i64 after_value = static_cast<ElmInt *>(after_obj)->value;

            RC_ASSERT(before_value == after_value);
        }

        // Verify root still exists and has same value
        void *final_obj = fromPointer(root_ptr);
        RC_ASSERT(reinterpret_cast<uintptr_t>(final_obj) != 0);

        Header *hdr = getHeader(final_obj);
        RC_ASSERT(hdr->tag == Tag_Int);

        i64 final_value = static_cast<ElmInt *>(final_obj)->value;
        RC_ASSERT(original_value == final_value);

        gc.getRootSet().removeRoot(&root_ptr);
    });
}

int main() {
    std::cout << "=== Eco Runtime GC Property-Based Tests ===" << std::endl;
    std::cout << std::endl;

    test_gc_preserves_roots();
    test_gc_collects_garbage();
    test_multiple_gc_cycles();

    return 0;
}
