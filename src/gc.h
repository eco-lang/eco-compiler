#ifndef ECO_GC_H
#define ECO_GC_H

#include "heap.hpp"
#include <atomic>
#include <vector>
#include <thread>
#include <mutex>
#include <unordered_map>

namespace Elm {

// GC Color states for tri-color marking
enum class Color : u32 {
  White = 0,  // Not marked (garbage)
  Grey = 1,   // Marked but children not scanned
  Black = 2   // Marked and children scanned
};

// Maximum age before promotion to old gen
constexpr u32 PROMOTION_AGE = 4;

// Nursery size per thread (e.g., 4MB)
constexpr size_t NURSERY_SIZE = 4 * 1024 * 1024;

// Forward declarations
class OldGenSpace;
class RootSet;

// Thread-local nursery space with semi-space copying collector
class NurserySpace {
public:
  NurserySpace();
  ~NurserySpace();

  // Allocate in nursery (bump allocation)
  void* allocate(size_t size);

  // Run minor GC (semi-space copy)
  void minorGC(RootSet& roots, OldGenSpace& oldgen);

  // Check if pointer is in nursery
  bool contains(void* ptr) const;

  // Get current allocation stats
  size_t bytesAllocated() const { return alloc_ptr - from_space; }
  size_t bytesRemaining() const { return from_space + (NURSERY_SIZE / 2) - alloc_ptr; }

private:
  char* memory;           // Total nursery memory (both semi-spaces)
  char* from_space;       // Current allocation space
  char* to_space;         // Copy target during GC
  char* alloc_ptr;        // Bump allocation pointer
  char* scan_ptr;         // Scan pointer for Cheney's algorithm

  void* copy(void* obj, OldGenSpace& oldgen);
  void* forward(void* obj);
  void evacuate(HPointer& ptr, OldGenSpace& oldgen);
  void evacuateUnboxable(Unboxable& val, bool is_boxed, OldGenSpace& oldgen);
  void flipSpaces();
};

// Old generation space with concurrent mark-and-sweep
class OldGenSpace {
public:
  OldGenSpace();
  ~OldGenSpace();

  // Allocate in old gen (free list allocation)
  void* allocate(size_t size);

  // Start concurrent marking phase
  void startConcurrentMark(RootSet& roots);

  // Perform incremental marking work
  bool incrementalMark(size_t work_units);

  // Complete marking and sweep
  void finishMarkAndSweep();

  // Check if pointer is in old gen
  bool contains(void* ptr) const;

  std::mutex& getMutex() { return alloc_mutex; }

private:
  struct FreeBlock {
    size_t size;
    FreeBlock* next;
  };

  std::vector<char*> chunks;           // Memory chunks
  FreeBlock* free_list;                // Free list for allocation
  std::mutex alloc_mutex;              // Mutex for allocation

  std::vector<void*> mark_stack;       // Stack for marking
  std::mutex mark_mutex;               // Mutex for marking operations

  std::atomic<u32> current_epoch;      // Current GC epoch
  std::atomic<bool> marking_active;    // Is marking in progress?

  void mark(void* obj);
  void markChildren(void* obj);
  void markHPointer(HPointer& ptr);
  void markUnboxable(Unboxable& val, bool is_boxed);
  void sweep();
  void addChunk(size_t size);

  friend class NurserySpace;
};

// Root set management
class RootSet {
public:
  void addRoot(HPointer* root);
  void removeRoot(HPointer* root);
  void addStackRoot(void* stack_ptr, size_t size);
  void clearStackRoots();

  const std::vector<HPointer*>& getRoots() const { return roots; }
  const std::vector<std::pair<void*, size_t>>& getStackRoots() const { return stack_roots; }

private:
  std::vector<HPointer*> roots;
  std::vector<std::pair<void*, size_t>> stack_roots;
  std::mutex mutex;
};

// Main GC controller
class GarbageCollector {
public:
  static GarbageCollector& instance();

  // Initialize GC for a thread
  void initThread();

  // Allocate object (tries nursery first, then old gen)
  void* allocate(size_t size, Tag tag);

  // Trigger minor GC
  void minorGC();

  // Trigger major GC (concurrent mark-and-sweep)
  void majorGC();

  // Root set management
  RootSet& getRootSet() { return root_set; }

  // Get thread-local nursery
  NurserySpace* getNursery();

  // Get old gen space
  OldGenSpace& getOldGen() { return old_gen; }

private:
  GarbageCollector();
  ~GarbageCollector();

  OldGenSpace old_gen;
  RootSet root_set;

  // Thread-local nursery spaces
  std::mutex nursery_mutex;
  std::unordered_map<std::thread::id, std::unique_ptr<NurserySpace>> nurseries;
};

// Helper functions for heap operations
inline Header* getHeader(void* obj) {
  return static_cast<Header*>(obj);
}

inline void* fromPointer(HPointer ptr) {
  if (ptr.constant != 0) {
    return nullptr;  // It's a constant, not a heap pointer
  }
  return reinterpret_cast<void*>(static_cast<uintptr_t>(ptr.ptr));
}

inline HPointer toPointer(void* obj) {
  HPointer ptr;
  ptr.ptr = reinterpret_cast<uintptr_t>(obj);
  ptr.constant = 0;
  ptr.padding = 0;
  return ptr;
}

inline size_t getObjectSize(void* obj) {
  Header* hdr = getHeader(obj);

  switch (hdr->tag) {
    case Tag_Int: return sizeof(ElmInt);
    case Tag_Float: return sizeof(ElmFloat);
    case Tag_Char: return sizeof(ElmChar);
    case Tag_String: return sizeof(ElmString) + hdr->size * sizeof(u16);
    case Tag_Tuple2: return sizeof(Tuple2);
    case Tag_Tuple3: return sizeof(Tuple3);
    case Tag_Cons: return sizeof(Cons);
    case Tag_Custom: {
      Custom* c = static_cast<Custom*>(obj);
      return sizeof(Custom) + hdr->size * sizeof(Unboxable);
    }
    case Tag_Record: {
      return sizeof(Record) + hdr->size * sizeof(Unboxable);
    }
    case Tag_DynRecord: {
      return sizeof(DynRecord) + hdr->size * sizeof(HPointer);
    }
    case Tag_FieldGroup: {
      return sizeof(FieldGroup) + hdr->size * sizeof(u32);
    }
    case Tag_Closure: {
      Closure* cl = static_cast<Closure*>(obj);
      return sizeof(Closure) + cl->n_values * sizeof(Unboxable);
    }
    case Tag_Process: return sizeof(Process);
    case Tag_Task: return sizeof(Task);
    case Tag_Forward: return sizeof(Forward);
    default: return sizeof(Header);
  }
}

} // namespace Elm

#endif // ECO_GC_H