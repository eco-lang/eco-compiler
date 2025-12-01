#pragma once

#include <cstring>
#include <iostream>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include "Allocator.hpp"
#include "Heap.hpp"

using namespace Elm;

/**
 * Captures a snapshot of heap object values before GC for validation afterward.
 *
 * Used in property-based tests to verify that GC preserves all reachable object
 * values. Stores primitive values and object structure for comparison.
 */
struct HeapSnapshot {
    /** Represents a single object in the snapshot. */
    struct SnapshotNode {
        Tag tag;
        std::vector<size_t> children; // Indices into snapshot nodes array.
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

    std::vector<SnapshotNode> nodes;       // All captured object snapshots.
    std::vector<size_t> root_indices;      // Indices of root objects in nodes.
    std::unordered_set<void *> captured_addrs;  // Original addresses of captured objects.

    // Captures the current state of objects reachable from roots.
    // Only objects that are transitively reachable from roots are included in the snapshot.
    void capture(const std::vector<void *> &objects, const std::vector<HPointer *> &roots) {
        nodes.clear();
        root_indices.clear();
        captured_addrs.clear();

        // Build set of all allocated objects for quick lookup.
        std::unordered_set<void *> allocated_set(objects.begin(), objects.end());
        allocated_set.erase(nullptr);

        // First, compute which objects are reachable from roots.
        std::unordered_set<void *> reachable;
        std::vector<void *> worklist;

        for (HPointer *root : roots) {
            if (root->constant != 0) continue;
            void *obj = AllocatorTestAccess::fromPointer(*root);
            if (obj && allocated_set.count(obj) && reachable.insert(obj).second) {
                worklist.push_back(obj);
            }
        }

        // BFS to find all reachable objects.
        while (!worklist.empty()) {
            void *obj = worklist.back();
            worklist.pop_back();

            Header *hdr = getHeader(obj);
            switch (hdr->tag) {
                case Tag_Tuple2: {
                    Tuple2 *t = static_cast<Tuple2 *>(obj);
                    if (!(hdr->unboxed & 1) && t->a.p.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(t->a.p);
                        if (child && allocated_set.count(child) && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    if (!(hdr->unboxed & 2) && t->b.p.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(t->b.p);
                        if (child && allocated_set.count(child) && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    break;
                }
                case Tag_Tuple3: {
                    Tuple3 *t = static_cast<Tuple3 *>(obj);
                    if (!(hdr->unboxed & 1) && t->a.p.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(t->a.p);
                        if (child && allocated_set.count(child) && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    if (!(hdr->unboxed & 2) && t->b.p.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(t->b.p);
                        if (child && allocated_set.count(child) && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    if (!(hdr->unboxed & 4) && t->c.p.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(t->c.p);
                        if (child && allocated_set.count(child) && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    break;
                }
                case Tag_Cons: {
                    Cons *cons = static_cast<Cons *>(obj);
                    if (!(hdr->unboxed & 1) && cons->head.p.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(cons->head.p);
                        if (child && allocated_set.count(child) && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    if (cons->tail.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(cons->tail);
                        if (child && allocated_set.count(child) && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    break;
                }
                case Tag_Custom: {
                    Custom *custom = static_cast<Custom *>(obj);
                    for (size_t i = 0; i < hdr->size && i < 48; i++) {
                        if (!(custom->unboxed & (1ULL << i)) && custom->values[i].p.constant == 0) {
                            void *child = AllocatorTestAccess::fromPointer(custom->values[i].p);
                            if (child && allocated_set.count(child) && reachable.insert(child).second) {
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
                            void *child = AllocatorTestAccess::fromPointer(record->values[i].p);
                            if (child && allocated_set.count(child) && reachable.insert(child).second) {
                                worklist.push_back(child);
                            }
                        }
                    }
                    break;
                }
                case Tag_DynRecord: {
                    DynRecord *dynrec = static_cast<DynRecord *>(obj);
                    if (dynrec->fieldgroup.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(dynrec->fieldgroup);
                        if (child && allocated_set.count(child) && reachable.insert(child).second) {
                            worklist.push_back(child);
                        }
                    }
                    for (size_t i = 0; i < hdr->size; i++) {
                        if (dynrec->values[i].constant == 0) {
                            void *child = AllocatorTestAccess::fromPointer(dynrec->values[i]);
                            if (child && allocated_set.count(child) && reachable.insert(child).second) {
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
                            void *child = AllocatorTestAccess::fromPointer(closure->values[i].p);
                            if (child && allocated_set.count(child) && reachable.insert(child).second) {
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

        std::unordered_map<void *, size_t> obj_to_idx;

        // Store reachable addresses for verification later.
        captured_addrs = reachable;

        // Now create snapshot nodes only for reachable objects.
        for (void *obj : reachable) {
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
                // For other types, we just verify the tag and structure.
                default:
                    break;
            }

            nodes.push_back(node);
        }

        // Second pass: resolve pointer children (only for reachable objects).
        for (void *obj : reachable) {
            if (!obj || !obj_to_idx.count(obj))
                continue;

            Header *hdr = getHeader(obj);
            size_t node_idx = obj_to_idx[obj];

            switch (hdr->tag) {
                case Tag_Tuple2: {
                    Tuple2 *t = static_cast<Tuple2 *>(obj);
                    if (!(hdr->unboxed & 1) && t->a.p.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(t->a.p);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    if (!(hdr->unboxed & 2) && t->b.p.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(t->b.p);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    break;
                }
                case Tag_Tuple3: {
                    Tuple3 *t = static_cast<Tuple3 *>(obj);
                    if (!(hdr->unboxed & 1) && t->a.p.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(t->a.p);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    if (!(hdr->unboxed & 2) && t->b.p.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(t->b.p);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    if (!(hdr->unboxed & 4) && t->c.p.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(t->c.p);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    break;
                }
                case Tag_Cons: {
                    Cons *cons = static_cast<Cons *>(obj);
                    // Track head if boxed.
                    if (!(hdr->unboxed & 1) && cons->head.p.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(cons->head.p);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    // Track tail (always a pointer, may be Nil).
                    if (cons->tail.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(cons->tail);
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
                            void *child = AllocatorTestAccess::fromPointer(custom->values[i].p);
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
                            void *child = AllocatorTestAccess::fromPointer(record->values[i].p);
                            if (child && obj_to_idx.count(child)) {
                                nodes[node_idx].children.push_back(obj_to_idx[child]);
                            }
                        }
                    }
                    break;
                }
                case Tag_DynRecord: {
                    DynRecord *dynrec = static_cast<DynRecord *>(obj);
                    // Track fieldgroup.
                    if (dynrec->fieldgroup.constant == 0) {
                        void *child = AllocatorTestAccess::fromPointer(dynrec->fieldgroup);
                        if (child && obj_to_idx.count(child)) {
                            nodes[node_idx].children.push_back(obj_to_idx[child]);
                        }
                    }
                    // Track all values (all HPointers).
                    for (size_t i = 0; i < hdr->size; i++) {
                        if (dynrec->values[i].constant == 0) {
                            void *child = AllocatorTestAccess::fromPointer(dynrec->values[i]);
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
                            void *child = AllocatorTestAccess::fromPointer(closure->values[i].p);
                            if (child && obj_to_idx.count(child)) {
                                nodes[node_idx].children.push_back(obj_to_idx[child]);
                            }
                        }
                    }
                    break;
                }
                // String and FieldGroup have no heap pointers.
                default:
                    break;
            }
        }

        // Record root indices.
        for (HPointer *root: roots) {
            if (root->constant != 0)
                continue;
            void *obj = AllocatorTestAccess::fromPointer(*root);
            if (obj && obj_to_idx.count(obj)) {
                root_indices.push_back(obj_to_idx[obj]);
            }
        }
    }

    // Verifies that root objects have values matching the snapshot.
    // Does NOT follow pointer fields (which may be dangling after GC of unreachable objects).
    bool verify(const std::vector<HPointer *> &roots) const {
        // Verify each root object directly (through readBarrier for forwarding).
        for (HPointer *root : roots) {
            if (root->constant != 0) {
                continue;  // Constants are always valid.
            }

            void *obj = readBarrier(*root);
            if (!obj) {
                std::cerr << "ERROR: Root pointer became null after GC" << std::endl;
                return false;
            }

            Header *hdr = getHeader(obj);

            // Safety check: tag should be valid.
            if (hdr->tag >= Tag_Forward) {
                std::cerr << "ERROR: Invalid tag " << hdr->tag << " found in root object" << std::endl;
                return false;
            }

            // Verify values match snapshot for primitive types.
            switch (hdr->tag) {
                case Tag_Int: {
                    ElmInt *obj_int = static_cast<ElmInt *>(obj);
                    bool found = false;
                    for (const auto &node : nodes) {
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
                    for (const auto &node : nodes) {
                        // Use memcmp for exact binary comparison (avoids NaN issues and precision issues).
                        if (node.tag == Tag_Float &&
                            std::memcmp(&node.data.float_val, &obj_float->value, sizeof(f64)) == 0) {
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
                    for (const auto &node : nodes) {
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
                    // For complex types (Tuple, Record, etc.), just verify the tag is valid.
                    // We can't follow pointers because they may lead to unreachable objects
                    // that were collected by GC.
                    break;
            }
        }

        return true;
    }
};
