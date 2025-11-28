# Old Generation Collector Completion Plan

This document outlines the work required to complete the OldGenSpace implementation, making it a fully functional mark-sweep collector with lazy sweeping and incremental compaction.

## Current State

The implementation (`runtime/src/OldGenSpace.cpp`) currently has:
- Bump-pointer allocation via AllocBuffers
- Tri-color incremental marking (White/Grey/Black)
- Object graph traversal for all Elm types
- GC statistics integration (optional)

### Critical Gaps
1. **No memory reclamation** - sweep() only resets colors, doesn't free anything
2. **New objects during marking may be incorrectly collected** - allocated as White
3. **No free-list allocation** - only bump-pointer, so freed space cannot be reused

### Design Decisions
- **Large objects**: Ignored for now; separate LOS will be added in future work
- **Coalescing**: Not implemented; may revisit later
- **Buffer return policy**: Return empty buffers when heap utilization < 50% (after compaction)
- **Compaction**: Incremental, evacuating worst buffers first

---

## Phase 1: Correctness Fixes (P0)

### 1.1 Mark New Allocations as Live During Marking

**Problem**: `allocate()` sets `hdr->color = White`. If marking is active, these objects will be swept as garbage.

**Solution**: During an active marking phase, new objects must be marked Black (live for this cycle).

```cpp
void *OldGenSpace::allocate(size_t size) {
    // ... allocation logic ...

    Header* hdr = reinterpret_cast<Header*>(result);
    std::memset(hdr, 0, sizeof(Header));

    if (marking_active) {
        // New objects are automatically live for this cycle
        hdr->color = static_cast<u32>(Color::Black);
        hdr->epoch = current_epoch & 3;
    } else {
        hdr->color = static_cast<u32>(Color::White);
    }

    return result;
}
```

**Rationale**: In Elm's immutable model, new objects can only point to already-existing objects (which will be traced from roots). The new object itself is reachable from the current execution context (stack/registers), which are roots. Marking it Black ensures it survives this cycle.

---

## Phase 2: Free-List Allocation (P0)

### 2.1 Data Structures

Add segregated free lists organized by size class:

```cpp
// In OldGenSpace.hpp
static constexpr size_t NUM_SIZE_CLASSES = 32;
static constexpr size_t MAX_SMALL_SIZE = 256;  // Bytes

struct FreeCell {
    FreeCell* next;
    // Size is implicit from size class
};

class OldGenSpace {
    // ... existing members ...

    // Free lists for small objects (indexed by size class)
    FreeCell* free_lists_[NUM_SIZE_CLASSES];

    // Size class mapping
    static size_t sizeClass(size_t size);
    static size_t classToSize(size_t cls);
};
```

### 2.2 Size Class Mapping

```cpp
// 8-byte granularity for sizes up to MAX_SMALL_SIZE
size_t OldGenSpace::sizeClass(size_t size) {
    size = (size + 7) & ~7;  // Align to 8
    if (size <= MAX_SMALL_SIZE) {
        return (size / 8) - 1;  // Classes 0..31 for sizes 8..256
    }
    return NUM_SIZE_CLASSES;  // Large objects - bump allocate only
}

size_t OldGenSpace::classToSize(size_t cls) {
    return (cls + 1) * 8;
}
```

### 2.3 Modified Allocation

```cpp
void *OldGenSpace::allocate(size_t size) {
    size = (size + 7) & ~7;

    // Try free list first for small objects
    size_t cls = sizeClass(size);
    if (cls < NUM_SIZE_CLASSES && free_lists_[cls] != nullptr) {
        FreeCell* cell = free_lists_[cls];
        free_lists_[cls] = cell->next;

        void* result = static_cast<void*>(cell);
        Header* hdr = reinterpret_cast<Header*>(result);
        std::memset(hdr, 0, sizeof(Header));
        hdr->color = marking_active ?
            static_cast<u32>(Color::Black) : static_cast<u32>(Color::White);
        if (marking_active) hdr->epoch = current_epoch & 3;

        return result;
    }

    // Fall back to bump allocation (existing logic)
    // ... existing bump allocation code ...
}
```

---

## Phase 3: Lazy Sweeping (P1)

### 3.1 State Machine

Replace monolithic sweep with a state machine:

```cpp
enum class GCPhase {
    Idle,           // No collection in progress
    Marking,        // Incremental marking in progress
    Sweeping        // Lazy sweeping in progress
};

class OldGenSpace {
    // ... existing members ...

    GCPhase gc_phase_;
    size_t sweep_buffer_index_;   // Which buffer we're sweeping
    char* sweep_cursor_;          // Position within current buffer
};
```

### 3.2 Per-Buffer Metadata

Track per-buffer liveness for evacuation decisions:

```cpp
struct BufferMetadata {
    AllocBuffer* buffer;
    size_t live_bytes;         // Computed during sweep
    size_t garbage_bytes;      // Computed during sweep
    bool fully_swept;          // True when sweep complete

    float liveness() const {
        size_t total = buffer->alloc_ptr_ - buffer->start_;
        return total > 0 ? (float)live_bytes / total : 0.0f;
    }
};

std::vector<BufferMetadata> buffer_meta_;
```

### 3.3 End of Marking Phase

When marking completes, transition to sweeping:

```cpp
void OldGenSpace::transitionToSweeping() {
    gc_phase_ = GCPhase::Sweeping;
    sweep_buffer_index_ = 0;
    sweep_cursor_ = nullptr;

    // Reset per-buffer stats for this sweep
    for (auto& meta : buffer_meta_) {
        meta.live_bytes = 0;
        meta.garbage_bytes = 0;
        meta.fully_swept = false;
    }
}
```

### 3.4 Lazy Sweep on Allocation

```cpp
void *OldGenSpace::allocate(size_t size) {
    size = (size + 7) & ~7;
    size_t cls = sizeClass(size);

    // Try free list first
    if (cls < NUM_SIZE_CLASSES && free_lists_[cls] != nullptr) {
        return allocateFromFreeList(cls);
    }

    // If sweeping, do some sweep work to find free space
    if (gc_phase_ == GCPhase::Sweeping) {
        lazySweep(cls, SWEEP_WORK_BUDGET);

        // Try free list again
        if (cls < NUM_SIZE_CLASSES && free_lists_[cls] != nullptr) {
            return allocateFromFreeList(cls);
        }
    }

    // Bump allocate from current buffer
    return bumpAllocate(size);
}
```

### 3.5 Lazy Sweep Implementation

```cpp
// Tuning constant: bytes to sweep per allocation slow-path
static constexpr size_t SWEEP_WORK_BUDGET = 4096;

void OldGenSpace::lazySweep(size_t target_class, size_t work_budget) {
    size_t work_done = 0;

    while (work_done < work_budget && gc_phase_ == GCPhase::Sweeping) {
        // Get current sweep position
        if (sweep_cursor_ == nullptr ||
            sweep_cursor_ >= buffers_[sweep_buffer_index_]->alloc_ptr_) {
            // Mark current buffer as fully swept
            if (sweep_buffer_index_ < buffer_meta_.size()) {
                buffer_meta_[sweep_buffer_index_].fully_swept = true;
            }

            // Move to next buffer
            sweep_buffer_index_++;
            if (sweep_buffer_index_ >= buffers_.size()) {
                // All buffers swept - sweeping complete
                gc_phase_ = GCPhase::Idle;
                onSweepComplete();
                return;
            }
            sweep_cursor_ = buffers_[sweep_buffer_index_]->start_;
        }

        // Sweep one object
        Header* hdr = reinterpret_cast<Header*>(sweep_cursor_);
        size_t obj_size = getObjectSize(sweep_cursor_);
        BufferMetadata& meta = buffer_meta_[sweep_buffer_index_];

        if (hdr->color == static_cast<u32>(Color::Black)) {
            // Live object: reset to white for next cycle
            hdr->color = static_cast<u32>(Color::White);
            meta.live_bytes += obj_size;
        } else {
            // Dead object: add to free list
            meta.garbage_bytes += obj_size;
            size_t cls = sizeClass(obj_size);
            if (cls < NUM_SIZE_CLASSES) {
                FreeCell* cell = reinterpret_cast<FreeCell*>(sweep_cursor_);
                cell->next = free_lists_[cls];
                free_lists_[cls] = cell;
            }
            // Large objects (cls >= NUM_SIZE_CLASSES): left as holes for now
        }

        sweep_cursor_ += obj_size;
        work_done += obj_size;
    }
}
```

---

## Phase 4: Incremental Marking Integration (P1)

### 4.1 Allocation-Paced Marking

Do marking work during allocation to spread the work:

```cpp
// Tuning constant: mark N bytes for each byte allocated
static constexpr size_t MARK_WORK_RATIO = 2;

void *OldGenSpace::allocate(size_t size) {
    // If marking in progress, do some marking work
    if (gc_phase_ == GCPhase::Marking) {
        size_t mark_budget = size * MARK_WORK_RATIO;
        incrementalMark(mark_budget);

        if (mark_stack.empty()) {
            transitionToSweeping();
        }
    }

    // ... rest of allocation logic ...
}
```

### 4.2 Triggering Collection

Start a collection when old gen usage exceeds threshold:

```cpp
void OldGenSpace::maybeStartCollection(const std::unordered_set<HPointer*>& roots,
                                        Allocator& alloc) {
    if (gc_phase_ != GCPhase::Idle) return;

    size_t threshold = config_->old_gen_threshold;
    if (allocated_bytes > threshold) {
        startMark(roots, alloc);
        gc_phase_ = GCPhase::Marking;
    }
}
```

---

## Phase 5: Fragmentation Monitoring (P2)

### 5.1 Metrics to Track

```cpp
struct FragmentationStats {
    size_t total_free_bytes;        // Sum of all free cells
    size_t live_bytes;              // Bytes in live objects
    size_t heap_bytes;              // Total committed heap (sum of buffer sizes)

    float utilization() const {
        return heap_bytes > 0 ? (float)live_bytes / heap_bytes : 0.0f;
    }
};

FragmentationStats frag_stats_;
```

### 5.2 Compute Stats After Sweep

```cpp
void OldGenSpace::onSweepComplete() {
    frag_stats_.live_bytes = 0;
    frag_stats_.total_free_bytes = 0;
    frag_stats_.heap_bytes = 0;

    for (const auto& meta : buffer_meta_) {
        frag_stats_.live_bytes += meta.live_bytes;
        frag_stats_.total_free_bytes += meta.garbage_bytes;
        size_t buffer_size = meta.buffer->alloc_ptr_ - meta.buffer->start_;
        frag_stats_.heap_bytes += buffer_size;
    }

    // Check if compaction should be triggered
    if (shouldCompact()) {
        scheduleCompaction();
    }

    // Return surplus empty buffers if heap < 50% utilized
    maybeReturnEmptyBuffers();
}
```

---

## Phase 6: Incremental Compaction (P3)

### 6.1 Triggering Compaction

Compact when fragmentation is severe:

```cpp
bool OldGenSpace::shouldCompact() const {
    // Threshold values (tunable)
    constexpr float UTILIZATION_THRESHOLD = 0.70f;

    // Compact when we're using less than 70% of committed heap
    // This indicates significant fragmentation/garbage
    return frag_stats_.utilization() < UTILIZATION_THRESHOLD;
}
```

### 6.2 Buffer Selection (Worst First)

Select buffers with the most garbage for evacuation:

```cpp
struct EvacuationCandidate {
    size_t buffer_index;
    size_t garbage_bytes;
    size_t live_bytes;
};

std::vector<size_t> OldGenSpace::selectEvacuationSet(size_t max_live_to_move) {
    std::vector<EvacuationCandidate> candidates;

    // Build candidate list from fully-swept buffers
    for (size_t i = 0; i < buffer_meta_.size(); i++) {
        const auto& meta = buffer_meta_[i];
        if (!meta.fully_swept) continue;

        // Only consider buffers with significant garbage (>30% dead)
        float liveness = meta.liveness();
        if (liveness < 0.70f) {
            candidates.push_back({i, meta.garbage_bytes, meta.live_bytes});
        }
    }

    // Sort by garbage bytes descending (worst first)
    std::sort(candidates.begin(), candidates.end(),
        [](const auto& a, const auto& b) {
            return a.garbage_bytes > b.garbage_bytes;
        });

    // Take buffers up to our live-bytes movement budget
    std::vector<size_t> evacuation_set;
    size_t total_live = 0;

    for (const auto& c : candidates) {
        if (total_live + c.live_bytes > max_live_to_move) break;
        evacuation_set.push_back(c.buffer_index);
        total_live += c.live_bytes;
    }

    return evacuation_set;
}
```

### 6.3 Incremental Compaction Slice

Process one buffer at a time to keep pauses short:

```cpp
// Compaction state
enum class CompactionPhase {
    Idle,
    Evacuating,     // Moving live objects out of source buffers
    FixingRefs      // Updating pointers to forwarding addresses
};

CompactionPhase compact_phase_;
std::vector<size_t> evacuation_set_;
size_t current_evac_index_;

void OldGenSpace::incrementalCompactionSlice(size_t work_budget) {
    if (compact_phase_ == CompactionPhase::Idle) return;

    size_t work_done = 0;

    if (compact_phase_ == CompactionPhase::Evacuating) {
        work_done = evacuateSlice(work_budget);

        if (current_evac_index_ >= evacuation_set_.size()) {
            // All buffers evacuated, now fix references
            compact_phase_ = CompactionPhase::FixingRefs;
            prepareReferenceFixup();
        }
    }

    if (compact_phase_ == CompactionPhase::FixingRefs &&
        work_done < work_budget) {
        fixReferencesSlice(work_budget - work_done);
    }
}
```

### 6.4 Evacuation Implementation

```cpp
size_t OldGenSpace::evacuateSlice(size_t work_budget) {
    size_t work_done = 0;

    while (work_done < work_budget &&
           current_evac_index_ < evacuation_set_.size()) {

        size_t src_idx = evacuation_set_[current_evac_index_];
        AllocBuffer* src_buffer = buffers_[src_idx];

        // Walk objects in source buffer
        char* ptr = src_buffer->start_;
        char* end = src_buffer->alloc_ptr_;

        while (ptr < end && work_done < work_budget) {
            Header* hdr = reinterpret_cast<Header*>(ptr);
            size_t obj_size = getObjectSize(ptr);

            // Only move live objects (color should be White after sweep reset)
            // We check epoch to identify objects from current cycle
            if (isLiveObject(ptr)) {
                // Allocate in a non-evacuating buffer
                void* dest = allocateForEvacuation(obj_size);
                if (dest == nullptr) {
                    // Out of space - abort compaction
                    compact_phase_ = CompactionPhase::Idle;
                    return work_done;
                }

                // Copy object
                std::memcpy(dest, ptr, obj_size);

                // Install forwarding pointer in old location
                installForwardingPointer(ptr, dest);

                work_done += obj_size;
            }

            ptr += obj_size;
        }

        if (ptr >= end) {
            // Buffer fully evacuated
            current_evac_index_++;
        }
    }

    return work_done;
}

void OldGenSpace::installForwardingPointer(void* old_location, void* new_location) {
    // Use the header to store forwarding info
    // Set a special tag to indicate this is a forwarding pointer
    Header* hdr = reinterpret_cast<Header*>(old_location);
    hdr->tag = Tag_Forwarding;  // Special tag value

    // Store the new address in the object body
    void** fwd_ptr = reinterpret_cast<void**>(
        static_cast<char*>(old_location) + sizeof(Header));
    *fwd_ptr = new_location;
}

void* OldGenSpace::getForwardingAddress(void* obj) {
    Header* hdr = reinterpret_cast<Header*>(obj);
    if (hdr->tag == Tag_Forwarding) {
        void** fwd_ptr = reinterpret_cast<void**>(
            static_cast<char*>(obj) + sizeof(Header));
        return *fwd_ptr;
    }
    return nullptr;  // Not forwarded
}
```

### 6.5 Reference Fixup

After evacuation, update all pointers to evacuated objects:

```cpp
void OldGenSpace::fixReferencesSlice(size_t work_budget) {
    size_t work_done = 0;

    // Walk all non-evacuated buffers and fix pointers
    while (work_done < work_budget &&
           fixup_buffer_index_ < buffers_.size()) {

        // Skip buffers that were evacuated (they're empty now)
        if (isInEvacuationSet(fixup_buffer_index_)) {
            fixup_buffer_index_++;
            continue;
        }

        AllocBuffer* buffer = buffers_[fixup_buffer_index_];
        char* ptr = (fixup_cursor_ != nullptr) ?
                    fixup_cursor_ : buffer->start_;
        char* end = buffer->alloc_ptr_;

        while (ptr < end && work_done < work_budget) {
            Header* hdr = reinterpret_cast<Header*>(ptr);
            size_t obj_size = getObjectSize(ptr);

            if (hdr->tag != Tag_Forwarding) {
                // Fix pointers within this object
                fixPointersInObject(ptr);
            }

            ptr += obj_size;
            work_done += obj_size;
        }

        if (ptr >= end) {
            fixup_buffer_index_++;
            fixup_cursor_ = nullptr;
        } else {
            fixup_cursor_ = ptr;
        }
    }

    if (fixup_buffer_index_ >= buffers_.size()) {
        // Reference fixup complete
        freeEvacuatedBuffers();
        compact_phase_ = CompactionPhase::Idle;
    }
}

void OldGenSpace::fixPointersInObject(void* obj) {
    Header* hdr = getHeader(obj);

    // Similar to markChildren, but updates pointers instead of marking
    switch (hdr->tag) {
        case Tag_Cons: {
            Cons* c = static_cast<Cons*>(obj);
            fixHPointer(c->head, !(hdr->unboxed & 1));
            fixHPointer(c->tail);
            break;
        }
        // ... similar cases for all object types ...
    }
}

void OldGenSpace::fixHPointer(HPointer& ptr) {
    if (ptr.constant != 0) return;

    void* obj = Allocator::fromPointerRaw(ptr);
    if (obj == nullptr) return;

    void* fwd = getForwardingAddress(obj);
    if (fwd != nullptr) {
        // Update pointer to new location
        ptr = Allocator::toPointer(fwd);
    }
}
```

### 6.6 Buffer Return Policy

Return empty buffers when heap utilization drops below 50%:

```cpp
void OldGenSpace::maybeReturnEmptyBuffers() {
    float util = frag_stats_.utilization();
    if (util >= 0.50f) return;  // Don't shrink if >= 50% utilized

    // Find completely empty buffers (all objects were garbage)
    std::vector<size_t> empty_indices;
    for (size_t i = 0; i < buffer_meta_.size(); i++) {
        if (buffer_meta_[i].live_bytes == 0 &&
            buffers_[i] != current_buffer_) {
            empty_indices.push_back(i);
        }
    }

    // Return buffers until we're back above 50% utilization
    // or we've returned all empty ones
    for (size_t idx : empty_indices) {
        // Recalculate utilization
        size_t buffer_size = buffers_[idx]->end_ - buffers_[idx]->start_;
        float new_util = (float)frag_stats_.live_bytes /
                         (frag_stats_.heap_bytes - buffer_size);

        if (new_util > 0.50f) {
            // Return this buffer to the allocator
            allocator_->releaseAllocBuffer(buffers_[idx]);

            // Remove from our tracking
            buffers_.erase(buffers_.begin() + idx);
            buffer_meta_.erase(buffer_meta_.begin() + idx);

            // Update stats
            frag_stats_.heap_bytes -= buffer_size;
        }

        if (frag_stats_.utilization() >= 0.50f) break;
    }

    // Update region bounds
    updateRegionBounds();
}

void OldGenSpace::freeEvacuatedBuffers() {
    // After compaction, return evacuated buffers to allocator
    for (size_t idx : evacuation_set_) {
        allocator_->releaseAllocBuffer(buffers_[idx]);
    }

    // Remove from tracking (iterate in reverse to preserve indices)
    std::sort(evacuation_set_.rbegin(), evacuation_set_.rend());
    for (size_t idx : evacuation_set_) {
        buffers_.erase(buffers_.begin() + idx);
        buffer_meta_.erase(buffer_meta_.begin() + idx);
    }

    evacuation_set_.clear();
    updateRegionBounds();
}
```

---

## Implementation Order

| Phase | Description | Effort | Priority |
|-------|-------------|--------|----------|
| 1.1 | Mark new allocations as Black during marking | Small | P0 |
| 2.1-2.3 | Free-list data structures and allocation | Medium | P0 |
| 3.1-3.5 | Lazy sweeping state machine | Medium | P1 |
| 4.1-4.2 | Allocation-paced marking | Small | P1 |
| 5.1-5.2 | Fragmentation statistics | Small | P2 |
| 6.1-6.6 | Incremental compaction with buffer return | Large | P3 |

---

## Testing Strategy

1. **Unit tests**: Verify free-list allocation/deallocation cycles
2. **Property tests**: Existing RapidCheck tests should pass with new allocator
3. **Stress tests**: Long-running allocation/deallocation patterns
4. **Fragmentation tests**: Verify fragmentation metrics and compaction triggers
5. **Compaction tests**: Verify objects survive evacuation with correct values

---

## Property-Based Test Ideas (RapidCheck)

### Phase 1-2: Free-List Allocation

1. **FreeListRoundTrip**: Allocate objects, trigger GC to free them, allocate same sizes again. Verify new allocations come from free lists (addresses should be from previously freed objects).

2. **SizeClassCorrectness**: For random sizes 8-256, verify `sizeClass()` and `classToSize()` are consistent: `classToSize(sizeClass(size)) >= size`.

3. **FreeListNoCorruption**: Allocate many objects of same size class, free half via GC, allocate again. Verify no object overlaps another and all headers are valid.

4. **MixedSizeAllocation**: Allocate random mix of sizes, trigger multiple GCs. Verify all surviving objects have correct values.

5. **FreeListExhaustion**: Fill free lists, exhaust them via allocation, verify fallback to bump allocation works correctly.

### Phase 3: Lazy Sweeping

6. **LazySweepPreservesLive**: Create object graph, trigger marking, verify lazy sweep preserves all reachable objects regardless of sweep progress.

7. **LazySweepReclaimsGarbage**: Allocate objects, drop references to some, trigger GC. After full lazy sweep, verify garbage bytes in stats matches expected.

8. **PartialSweepConsistency**: Interrupt lazy sweep at random points (varying work budgets), verify heap state is consistent and allocation still works.

9. **SweepProgressMonotonicity**: Verify sweep cursor only moves forward, buffer index only increases, and `gc_phase_` transitions only Idle→Marking→Sweeping→Idle.

10. **AllocationDuringSweep**: Perform allocations while sweep is in progress. Verify new objects are correctly colored and survive the current cycle.

### Phase 4: Incremental Marking

11. **IncrementalMarkEquivalence**: Compare results of incremental marking (small work_units) vs full marking (large work_units). Both should mark exactly the same objects.

12. **MarkingWithAllocation**: Allocate new objects during marking phase. Verify all new objects (colored Black) survive, and pre-existing reachable objects also survive.

13. **MarkStackDraining**: Verify mark stack eventually empties for any valid object graph, regardless of graph shape (deep, wide, cyclic).

14. **AllocationPacedMarkingCompletion**: With allocation-paced marking, verify GC cycle completes before heap exhaustion for reasonable live/garbage ratios.

15. **ColorInvariantDuringMarking**: At any point during marking, verify: no Black object points to White object (tri-color invariant holds because of immutability).

### Phase 5: Fragmentation Statistics

16. **UtilizationCalculation**: After GC, verify `live_bytes + garbage_bytes == total_allocated` and utilization formula is correct.

17. **FragmentationGrowth**: Allocate/free patterns that should increase fragmentation, verify fragmentation metric increases appropriately.

18. **LiveBytesAccuracy**: Compare `frag_stats_.live_bytes` against manual traversal counting live bytes. Should match exactly.

### Phase 6: Incremental Compaction

19. **EvacuationPreservesValues**: Evacuate buffers, verify all object values (Int, Float, String contents, tuple elements, etc.) are identical before and after.

20. **ForwardingPointerCorrectness**: After evacuation, verify all forwarding pointers point to valid objects with matching tags and values.

21. **ReferenceFixupCompleteness**: After compaction, no pointer in the heap should point to an evacuated (forwarding) address.

22. **WorstFirstSelection**: Verify evacuation set selection actually chooses buffers with highest garbage ratios first.

23. **CompactionReducesBufferCount**: After compacting buffers with <70% liveness, verify total buffer count decreases or stays same (never increases).

24. **IncrementalCompactionEquivalence**: Compare incremental compaction (small slices) vs full compaction. Final heap state should be equivalent.

25. **BufferReturnPolicy**: When utilization < 50%, verify empty buffers are returned. When >= 50%, verify no buffers returned.

### Integration / Stress Tests

26. **MultipleCycleStability**: Run many GC cycles (mark→sweep→compact) with continuous allocation. Verify no memory leaks, corruption, or crashes.

27. **HighChurnSurvival**: Rapid allocation/deallocation cycles. Verify long-lived objects always survive, short-lived are collected.

28. **DeepGraphPreservation**: Create very deep object graphs (long lists, deep trees). Verify GC handles them without stack overflow and preserves all nodes.

29. **CyclicGraphHandling**: Create cyclic object graphs (mutual references). Verify cycles are correctly identified as reachable or garbage.

30. **PromotionAndOldGenGC**: Objects promoted from nursery, then old-gen GC runs. Verify promoted objects are correctly tracked and survive if reachable.

31. **AllObjectTypesRoundTrip**: For each object type (Tuple2, Tuple3, Cons, Custom, Record, DynRecord, Closure, Process, Task, String, Int, Float), create instances, run GC, verify values preserved.

32. **StressFragmentation**: Allocate objects of varying sizes to maximize fragmentation, trigger compaction, verify heap is defragmented (utilization increases).

33. **EmptyHeapBehavior**: GC on empty heap, GC when all objects are garbage, GC when all objects are live. Verify correct behavior in edge cases.

### Invariant Checks (can be combined with other tests)

34. **HeaderConsistency**: After any GC operation, all object headers have valid tags, colors, and sizes.

35. **BufferBoundsRespected**: No object spans buffer boundaries; all object addresses are within their containing buffer.

36. **FreeListIntegrity**: Free list traversal finds only valid free cells, no cycles, all cells within valid buffer ranges.

---

## Tuning Constants Summary

| Constant | Default | Description |
|----------|---------|-------------|
| `NUM_SIZE_CLASSES` | 32 | Number of segregated free lists |
| `MAX_SMALL_SIZE` | 256 | Max object size for free-list allocation |
| `SWEEP_WORK_BUDGET` | 4096 | Bytes to sweep per allocation slow-path |
| `MARK_WORK_RATIO` | 2 | Mark N bytes per byte allocated |
| `UTILIZATION_THRESHOLD` | 0.70 | Trigger compaction below this |
| `BUFFER_RETURN_THRESHOLD` | 0.50 | Return empty buffers below this |
| `EVAC_LIVENESS_THRESHOLD` | 0.70 | Evacuate buffers with liveness below this |

These are initial guesses and should be tuned based on workload profiling.
