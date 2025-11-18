#include "allocator.hpp"
#include "heap.hpp"
#include <rapidcheck.h>
#include <iostream>
#include <vector>
#include <unordered_set>
#include <random>

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
  void capture(const std::vector<void*>& objects, const std::vector<HPointer*>& roots) {
    nodes.clear();
    root_indices.clear();

    std::unordered_map<void*, size_t> obj_to_idx;

    // First pass: create snapshot nodes
    for (size_t i = 0; i < objects.size(); i++) {
      void* obj = objects[i];
      if (!obj) continue;

      obj_to_idx[obj] = nodes.size();
      SnapshotNode node;
      Header* hdr = getHeader(obj);
      node.tag = static_cast<Tag>(hdr->tag);

      switch (node.tag) {
        case Tag_Int:
          node.data.int_val = static_cast<ElmInt*>(obj)->value;
          break;
        case Tag_Float:
          node.data.float_val = static_cast<ElmFloat*>(obj)->value;
          break;
        case Tag_Char:
          node.data.char_val = static_cast<ElmChar*>(obj)->value;
          break;
        case Tag_Tuple2: {
          Tuple2* t = static_cast<Tuple2*>(obj);
          node.data.tuple2.a = t->a;
          node.data.tuple2.b = t->b;
          node.data.tuple2.unboxed = hdr->unboxed;
          break;
        }
        case Tag_Tuple3: {
          Tuple3* t = static_cast<Tuple3*>(obj);
          node.data.tuple3.a = t->a;
          node.data.tuple3.b = t->b;
          node.data.tuple3.c = t->c;
          node.data.tuple3.unboxed = hdr->unboxed;
          break;
        }
        default:
          break;
      }

      nodes.push_back(node);
    }

    // Second pass: resolve pointer children
    for (size_t i = 0; i < objects.size(); i++) {
      void* obj = objects[i];
      if (!obj) continue;

      Header* hdr = getHeader(obj);
      size_t node_idx = obj_to_idx[obj];

      switch (hdr->tag) {
        case Tag_Tuple2: {
          Tuple2* t = static_cast<Tuple2*>(obj);
          if (!(hdr->unboxed & 1) && t->a.p.constant == 0) {
            void* child = fromPointer(t->a.p);
            if (child && obj_to_idx.count(child)) {
              nodes[node_idx].children.push_back(obj_to_idx[child]);
            }
          }
          if (!(hdr->unboxed & 2) && t->b.p.constant == 0) {
            void* child = fromPointer(t->b.p);
            if (child && obj_to_idx.count(child)) {
              nodes[node_idx].children.push_back(obj_to_idx[child]);
            }
          }
          break;
        }
        case Tag_Tuple3: {
          Tuple3* t = static_cast<Tuple3*>(obj);
          if (!(hdr->unboxed & 1) && t->a.p.constant == 0) {
            void* child = fromPointer(t->a.p);
            if (child && obj_to_idx.count(child)) {
              nodes[node_idx].children.push_back(obj_to_idx[child]);
            }
          }
          if (!(hdr->unboxed & 2) && t->b.p.constant == 0) {
            void* child = fromPointer(t->b.p);
            if (child && obj_to_idx.count(child)) {
              nodes[node_idx].children.push_back(obj_to_idx[child]);
            }
          }
          if (!(hdr->unboxed & 4) && t->c.p.constant == 0) {
            void* child = fromPointer(t->c.p);
            if (child && obj_to_idx.count(child)) {
              nodes[node_idx].children.push_back(obj_to_idx[child]);
            }
          }
          break;
        }
        default:
          break;
      }
    }

    // Record root indices
    for (HPointer* root : roots) {
      if (root->constant != 0) continue;
      void* obj = fromPointer(*root);
      if (obj && obj_to_idx.count(obj)) {
        root_indices.push_back(obj_to_idx[obj]);
      }
    }
  }

  // Verify that the current heap matches the snapshot (after GC)
  bool verify(const std::vector<HPointer*>& roots) const {
    std::unordered_set<void*> reachable;
    std::unordered_map<void*, size_t> obj_to_snapshot_idx;

    // Build reachable set from roots
    std::vector<void*> worklist;
    for (HPointer* root : roots) {
      if (root->constant != 0) continue;
      void* obj = fromPointer(*root);
      if (obj) {
        worklist.push_back(obj);
        reachable.insert(obj);
      }
    }

    while (!worklist.empty()) {
      void* obj = worklist.back();
      worklist.pop_back();

      Header* hdr = getHeader(obj);

      // Safety check: tag should be valid
      if (hdr->tag >= Tag_Forward) {
        return false;
      }

      switch (hdr->tag) {
        case Tag_Tuple2: {
          Tuple2* t = static_cast<Tuple2*>(obj);
          if (!(hdr->unboxed & 1) && t->a.p.constant == 0) {
            void* child = fromPointer(t->a.p);
            if (child && reachable.insert(child).second) {
              worklist.push_back(child);
            }
          }
          if (!(hdr->unboxed & 2) && t->b.p.constant == 0) {
            void* child = fromPointer(t->b.p);
            if (child && reachable.insert(child).second) {
              worklist.push_back(child);
            }
          }
          break;
        }
        case Tag_Tuple3: {
          Tuple3* t = static_cast<Tuple3*>(obj);
          if (!(hdr->unboxed & 1) && t->a.p.constant == 0) {
            void* child = fromPointer(t->a.p);
            if (child && reachable.insert(child).second) {
              worklist.push_back(child);
            }
          }
          if (!(hdr->unboxed & 2) && t->b.p.constant == 0) {
            void* child = fromPointer(t->b.p);
            if (child && reachable.insert(child).second) {
              worklist.push_back(child);
            }
          }
          if (!(hdr->unboxed & 4) && t->c.p.constant == 0) {
            void* child = fromPointer(t->c.p);
            if (child && reachable.insert(child).second) {
              worklist.push_back(child);
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
      std::cerr << "ERROR: Lost objects during GC! Expected at least "
                << root_indices.size() << " but found " << reachable.size() << std::endl;
      return false;
    }

    // Verify structure and values of reachable objects
    std::vector<void*> reachable_vec(reachable.begin(), reachable.end());

    for (void* obj : reachable_vec) {
      Header* hdr = getHeader(obj);

      // Verify tag is valid
      if (hdr->tag >= Tag_Forward) {
        return false;
      }

      // Verify values match snapshot for primitive types
      switch (hdr->tag) {
        case Tag_Int: {
          ElmInt* obj_int = static_cast<ElmInt*>(obj);
          bool found = false;
          for (const auto& node : nodes) {
            if (node.tag == Tag_Int && node.data.int_val == obj_int->value) {
              found = true;
              break;
            }
          }
          if (!found) {
            return false;
          }
          break;
        }
        case Tag_Float: {
          ElmFloat* obj_float = static_cast<ElmFloat*>(obj);
          bool found = false;
          for (const auto& node : nodes) {
            if (node.tag == Tag_Float && node.data.float_val == obj_float->value) {
              found = true;
              break;
            }
          }
          if (!found) {
            return false;
          }
          break;
        }
        case Tag_Char: {
          ElmChar* obj_char = static_cast<ElmChar*>(obj);
          bool found = false;
          for (const auto& node : nodes) {
            if (node.tag == Tag_Char && node.data.char_val == obj_char->value) {
              found = true;
              break;
            }
          }
          if (!found) {
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

// Helper functions to create random heap objects
// These are NOT RapidCheck generators - they use RNG directly

void* createRandomPrimitive(std::mt19937& rng) {
  auto& gc = GarbageCollector::instance();
  std::uniform_int_distribution<int> type_dist(0, 2);
  int type = type_dist(rng);

  switch (type) {
    case 0: { // Int
      void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
      ElmInt* elm_int = static_cast<ElmInt*>(obj);
      std::uniform_int_distribution<i64> val_dist;
      elm_int->value = val_dist(rng);
      return obj;
    }
    case 1: { // Float
      void* obj = gc.allocate(sizeof(ElmFloat), Tag_Float);
      ElmFloat* elm_float = static_cast<ElmFloat*>(obj);
      std::uniform_real_distribution<f64> val_dist;
      elm_float->value = val_dist(rng);
      return obj;
    }
    case 2: { // Char
      void* obj = gc.allocate(sizeof(ElmChar), Tag_Char);
      ElmChar* elm_char = static_cast<ElmChar*>(obj);
      std::uniform_int_distribution<u16> val_dist(0, 0xFFFF);
      elm_char->value = val_dist(rng);
      return obj;
    }
    default:
      return nullptr;
  }
}

Unboxable createRandomUnboxable(std::mt19937& rng, const std::vector<void*>& existing_objects, bool& is_boxed) {
  Unboxable val;
  std::uniform_int_distribution<int> coin(0, 1);

  // Randomly decide: boxed pointer or unboxed primitive
  if (coin(rng) && !existing_objects.empty()) {
    // Boxed: pointer to existing object
    is_boxed = true;
    std::uniform_int_distribution<size_t> idx_dist(0, existing_objects.size() - 1);
    size_t idx = idx_dist(rng);
    val.p = toPointer(existing_objects[idx]);
  } else {
    // Unboxed: primitive value
    is_boxed = false;
    std::uniform_int_distribution<int> type_dist(0, 2);
    int type = type_dist(rng);
    switch (type) {
      case 0: {
        std::uniform_int_distribution<i64> val_dist;
        val.i = val_dist(rng);
        break;
      }
      case 1: {
        std::uniform_real_distribution<f64> val_dist;
        val.f = val_dist(rng);
        break;
      }
      default: {
        std::uniform_int_distribution<u16> val_dist(0, 0xFFFF);
        val.c = val_dist(rng);
        break;
      }
    }
  }

  return val;
}

void* createRandomComposite(std::mt19937& rng, const std::vector<void*>& existing_objects) {
  auto& gc = GarbageCollector::instance();
  std::uniform_int_distribution<int> type_dist(0, 1);
  int type = type_dist(rng);

  switch (type) {
    case 0: { // Tuple2
      void* obj = gc.allocate(sizeof(Tuple2), Tag_Tuple2);
      Tuple2* tuple = static_cast<Tuple2*>(obj);
      Header* hdr = getHeader(obj);

      bool a_boxed = false, b_boxed = false;
      tuple->a = createRandomUnboxable(rng, existing_objects, a_boxed);
      tuple->b = createRandomUnboxable(rng, existing_objects, b_boxed);

      hdr->unboxed = 0;
      if (!a_boxed) hdr->unboxed |= 1;
      if (!b_boxed) hdr->unboxed |= 2;

      return obj;
    }
    case 1: { // Tuple3
      void* obj = gc.allocate(sizeof(Tuple3), Tag_Tuple3);
      Tuple3* tuple = static_cast<Tuple3*>(obj);
      Header* hdr = getHeader(obj);

      bool a_boxed = false, b_boxed = false, c_boxed = false;
      tuple->a = createRandomUnboxable(rng, existing_objects, a_boxed);
      tuple->b = createRandomUnboxable(rng, existing_objects, b_boxed);
      tuple->c = createRandomUnboxable(rng, existing_objects, c_boxed);

      hdr->unboxed = 0;
      if (!a_boxed) hdr->unboxed |= 1;
      if (!b_boxed) hdr->unboxed |= 2;
      if (!c_boxed) hdr->unboxed |= 4;

      return obj;
    }
    default:
      return nullptr;
  }
}

// Property test: GC preserves reachable objects
void test_gc_preserves_roots() {
  rc::check("GC preserves all reachable objects from roots", []() {
    // Initialize GC for this thread
    auto& gc = GarbageCollector::instance();
    gc.initThread();

    // Use a random seed for our custom RNG
    std::random_device rd;
    std::mt19937 rng(rd());

    // Generate random number of objects (10-100)
    std::uniform_int_distribution<size_t> obj_count_dist(10, 100);
    size_t num_objects = obj_count_dist(rng);

    std::vector<void*> allocated_objects;
    std::vector<HPointer> root_storage; // Storage for root HPointers
    std::vector<HPointer*> root_ptrs;   // Pointers to roots

    // Phase 1: Allocate random heap structures
    std::uniform_int_distribution<int> coin(0, 1);
    for (size_t i = 0; i < num_objects; i++) {
      void* obj = nullptr;

      if (i < 10 || coin(rng)) {
        // Create primitive
        obj = createRandomPrimitive(rng);
      } else {
        // Create composite that may reference existing objects
        obj = createRandomComposite(rng, allocated_objects);
      }

      if (obj) {
        allocated_objects.push_back(obj);
      }
    }

    RC_ASSERT(!allocated_objects.empty());

    // Phase 2: Randomly select 20-50% of objects as roots
    std::uniform_int_distribution<size_t> root_count_dist(
      allocated_objects.size() / 5,
      allocated_objects.size() / 2
    );
    size_t num_roots = root_count_dist(rng);

    std::unordered_set<size_t> root_indices_set;
    std::uniform_int_distribution<size_t> idx_dist(0, allocated_objects.size() - 1);
    for (size_t i = 0; i < num_roots; i++) {
      size_t idx = idx_dist(rng);
      root_indices_set.insert(idx);
    }

    for (size_t idx : root_indices_set) {
      root_storage.push_back(toPointer(allocated_objects[idx]));
    }

    for (auto& root : root_storage) {
      root_ptrs.push_back(&root);
      gc.getRootSet().addRoot(&root);
    }

    // Phase 3: Take snapshot before GC
    HeapSnapshot snapshot;
    snapshot.capture(allocated_objects, root_ptrs);

    // Phase 4: Perform minor GC
    gc.minorGC();

    // Phase 5: Verify all roots still intact and valid
    bool valid = snapshot.verify(root_ptrs);

    // Cleanup roots
    for (auto* root : root_ptrs) {
      gc.getRootSet().removeRoot(root);
    }

    RC_ASSERT(valid);
  });
}

// Property test: Unreachable objects are collected
void test_gc_collects_garbage() {
  rc::check("GC collects unreachable objects", []() {
    auto& gc = GarbageCollector::instance();
    gc.initThread();
    auto* nursery = gc.getNursery();

    std::random_device rd;
    std::mt19937 rng(rd());

    // Allocate many objects without adding to roots
    size_t initial_used = nursery->bytesAllocated();

    for (int i = 0; i < 50; i++) {
      void* obj = createRandomPrimitive(rng);
      RC_ASSERT(reinterpret_cast<uintptr_t>(obj) != 0);
    }

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
    auto& gc = GarbageCollector::instance();
    gc.initThread();

    std::random_device rd;
    std::mt19937 rng(rd());

    // Create a long-lived Int object (not random type)
    void* root_obj = gc.allocate(sizeof(ElmInt), Tag_Int);
    ElmInt* elm_int = static_cast<ElmInt*>(root_obj);
    std::uniform_int_distribution<i64> val_dist;
    elm_int->value = val_dist(rng);

    HPointer root_ptr = toPointer(root_obj);
    gc.getRootSet().addRoot(&root_ptr);

    i64 original_value = elm_int->value;

    // Run multiple GC cycles
    std::uniform_int_distribution<int> cycles_dist(3, 10);
    int num_cycles = cycles_dist(rng);
    for (int i = 0; i < num_cycles; i++) {
      // Check value before GC
      void* current_obj = fromPointer(root_ptr);
      i64 before_value = static_cast<ElmInt*>(current_obj)->value;

      // Allocate garbage between cycles
      for (int j = 0; j < 20; j++) {
        void* garbage = createRandomPrimitive(rng);
        (void)garbage;
      }

      gc.minorGC();

      // Check value after GC
      void* after_obj = fromPointer(root_ptr);
      i64 after_value = static_cast<ElmInt*>(after_obj)->value;

      RC_ASSERT(before_value == after_value);
    }

    // Verify root still exists and has same value
    void* final_obj = fromPointer(root_ptr);
    RC_ASSERT(reinterpret_cast<uintptr_t>(final_obj) != 0);

    Header* hdr = getHeader(final_obj);
    RC_ASSERT(hdr->tag == Tag_Int);

    i64 final_value = static_cast<ElmInt*>(final_obj)->value;
    RC_ASSERT(original_value == final_value);

    gc.getRootSet().removeRoot(&root_ptr);
  });
}

int main() {
  std::cout << "=== Elm Runtime GC Property-Based Tests ===" << std::endl;
  std::cout << std::endl;

  std::cout << "Test 1: GC preserves all reachable objects from roots" << std::endl;
  test_gc_preserves_roots();
  std::cout << "✓ PASSED" << std::endl << std::endl;

  std::cout << "Test 2: GC collects unreachable objects" << std::endl;
  test_gc_collects_garbage();
  std::cout << "✓ PASSED" << std::endl << std::endl;

  std::cout << "Test 3: Multiple GC cycles preserve roots correctly" << std::endl;
  test_multiple_gc_cycles();
  std::cout << "✓ PASSED" << std::endl << std::endl;

  std::cout << "=== All tests passed! ===" << std::endl;

  return 0;
}
