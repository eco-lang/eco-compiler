# TLAB Implementation Summary

## Executive Summary

The TLAB (Thread-Local Allocation Buffer) design provides **lock-free, thread-local allocation** for the old generation, eliminating the current mutex bottleneck during object promotion. Based on your Java ThreadLocalAllocator pattern but adapted for memory management and mark-and-sweep GC.

**Expected performance improvement**: 50-100x faster promotions in multi-threaded scenarios.

## Three Key Files Created

1. **TLAB_DESIGN.md** - Complete design specification
2. **tlab_implementation.hpp** - Header changes and TLAB class
3. **tlab_implementation_sketch.cpp** - Implementation details
4. **TLAB_DIAGRAMS.md** - Visual diagrams and performance analysis

## Core Design Principles

### 1. Two-Tier Memory Layout
```
[=== Free-List Region ===][=== TLAB Region ===]
     (mutex)                  (lock-free CAS)
```

- **Free-list region**: Legacy allocations, large objects (mutex-protected)
- **TLAB region**: Thread-local buffers (atomic bump pointer)

### 2. Three-Level Allocation Strategy

| Priority | Method | Synchronization | Use Case |
|----------|--------|-----------------|----------|
| 1st | TLAB bump pointer | None | Most promotions (99%+) |
| 2nd | New TLAB allocation | Atomic CAS | Every ~128KB |
| 3rd | Free-list allocation | Mutex | Large objects, fallback |

### 3. GC Integration

- **Mark phase**: Unchanged - marks objects in both regions
- **Sweep phase**: Extended to handle sealed TLABs + free-list region
- **No write barriers**: Still not needed (Elm immutability)

## Implementation Checklist

### Phase 1: Core Infrastructure
- [ ] Add `TLAB` class to `allocator.hpp` (see `tlab_implementation.hpp`)
- [ ] Add TLAB members to `OldGenSpace`:
  - [ ] `std::atomic<char*> tlab_bump_ptr`
  - [ ] `char* tlab_region_start/end`
  - [ ] `std::vector<TLAB*> sealed_tlabs`
  - [ ] `std::mutex sealed_tlabs_mutex`
- [ ] Add `promotion_tlab` to `NurserySpace`

### Phase 2: OldGenSpace Methods
- [ ] Implement `OldGenSpace::allocateTLAB()` (lock-free CAS)
- [ ] Implement `OldGenSpace::sealTLAB()`
- [ ] Modify `OldGenSpace::initialize()` to partition memory
- [ ] Modify `OldGenSpace::sweep()` to handle TLABs

### Phase 3: NurserySpace Integration
- [ ] Modify `NurserySpace::evacuate()` to use TLAB
- [ ] Add TLAB sealing to `NurserySpace::~NurserySpace()`
- [ ] Handle large object bypass (>128KB)

### Phase 4: Testing
- [ ] Test single-threaded promotion (should work identically)
- [ ] Test multi-threaded promotion (should be faster)
- [ ] Test TLAB exhaustion and fallback
- [ ] Test GC correctness with TLABs
- [ ] Stress test with property-based tests

### Phase 5: Tuning
- [ ] Experiment with TLAB size (64KB, 128KB, 256KB)
- [ ] Measure contention reduction
- [ ] Profile allocation patterns
- [ ] Consider TLAB recycling for future optimization

## Code Changes Summary

### allocator.hpp
```cpp
// Add TLAB class
class TLAB {
    char* start, *end, *alloc_ptr;
    void* allocate(size_t size);  // Bump pointer, no lock
};

// Extend OldGenSpace
class OldGenSpace {
    // NEW members:
    std::atomic<char*> tlab_bump_ptr;
    std::vector<TLAB*> sealed_tlabs;

    // NEW methods:
    TLAB* allocateTLAB(size_t size = 128KB);
    void sealTLAB(TLAB* tlab);
};

// Extend NurserySpace
class NurserySpace {
    TLAB* promotion_tlab;  // NEW: Thread-local TLAB
};
```

### allocator.cpp

**Key changes**:

1. **OldGenSpace::initialize()** - Partition memory 50/50
2. **OldGenSpace::allocateTLAB()** - CAS loop for lock-free allocation
3. **OldGenSpace::sealTLAB()** - Add to sealed_tlabs vector
4. **OldGenSpace::sweep()** - Two-part sweep (TLABs + free-list)
5. **NurserySpace::evacuate()** - Try TLAB first, fallback to free-list

See `tlab_implementation_sketch.cpp` for full details.

## Performance Expectations

### Before TLAB (Current)
```
10,000 small promotions × 1000 cycles (mutex) = 10M cycles
```

### After TLAB
```
10,000 × 15 cycles (TLAB) + 20 × 150 (new TLAB) = 153K cycles
Speedup: 65x
```

Real-world speedup depends on:
- Promotion rate (higher = more benefit)
- Thread count (more threads = more contention reduced)
- Object sizes (smaller objects = more allocations = more benefit)

## Memory Overhead

**Per thread**: ~128KB (active TLAB) + 32 bytes (metadata)
**Global**: <1KB
**Total**: ~0.024% of 512MB heap

## Compatibility

### Unchanged
- Mark phase logic
- Object scanning
- Root set management
- Forwarding pointers
- Immutability guarantees

### Changed
- Sweep phase (extended, not replaced)
- Promotion allocation path (new fast path added)
- Memory partitioning (static 50/50 split)

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Memory fragmentation | TLABs are sealed and swept normally; fragmentation handled by free-list |
| TLAB region exhaustion | Graceful fallback to free-list allocation |
| Sweep complexity | Clear separation: sealed TLABs vs free-list region |
| Thread exit leaks | Destructor seals active TLAB automatically |
| Large object waste | Large objects bypass TLAB entirely |

## Alternative Approaches Considered

### 1. Lock-free free-list
- **Pro**: Simpler change
- **Con**: CAS on free-list is complex, still has contention
- **Verdict**: TLAB is cleaner

### 2. Per-size-class TLABs
- **Pro**: Less fragmentation
- **Con**: More complex, multiple TLABs per thread
- **Verdict**: Overkill for now, could be future optimization

### 3. Dynamic TLAB sizing
- **Pro**: Adaptive to workload
- **Con**: Complexity, heuristics needed
- **Verdict**: Fixed 128KB is simpler, tune if needed

## Testing Strategy

### Unit Tests
1. TLAB allocation and sealing
2. Lock-free CAS correctness (concurrent allocateTLAB)
3. Sweep handling of sealed TLABs
4. Fallback to free-list

### Integration Tests
1. Minor GC with promotions
2. Major GC sweep phase
3. Multi-threaded minor GC
4. Thread creation/destruction

### Property-Based Tests
Already have RapidCheck tests - should pass with TLAB:
1. GC preserves reachable objects
2. GC collects unreachable objects
3. Multiple GC cycles maintain correctness

Run with more threads to stress-test:
```bash
./build/test/test -n 1000 --threads 8
```

### Performance Tests
```bash
# Measure promotion throughput
./build/test/test --filter promote --threads 1,2,4,8
# Compare mutex vs TLAB overhead
```

## Future Optimizations

### Short-term (if needed)
1. **TLAB recycling**: Reuse empty sealed TLABs instead of allocating new
2. **Tunable TLAB size**: Runtime flag for different workloads
3. **Lock-free sealed_tlabs**: Use lock-free queue instead of mutex

### Long-term (if needed)
1. **Segregated TLABs**: Separate TLABs for different size classes
2. **Dynamic partitioning**: Adjust free-list/TLAB ratio based on workload
3. **NUMA awareness**: Per-NUMA-node TLAB regions

## Migration Path

### Step 1: Implement (1-2 days)
- Add TLAB class and infrastructure
- Modify sweep phase
- Update evacuation logic

### Step 2: Test (1 day)
- Run existing property-based tests
- Add TLAB-specific unit tests
- Multi-threaded stress tests

### Step 3: Benchmark (1 day)
- Measure promotion throughput
- Compare contention (perf, mutex stats)
- Validate performance improvement

### Step 4: Tune (optional)
- Adjust TLAB size if needed
- Tweak partitioning ratio
- Profile and optimize

## Questions to Consider

1. **Partitioning ratio**: Start with 50/50, but could be 25/75 or 75/25 based on workload
2. **TLAB size**: 128KB is reasonable, but could test 64KB or 256KB
3. **Growth strategy**: Currently fixed partitions, could allow TLAB region to grow
4. **Recycling**: Should we recycle empty TLABs or always allocate new?

## Conclusion

The TLAB design is:
- ✅ **Proven**: Based on your Java ThreadLocalAllocator pattern
- ✅ **Compatible**: Works with existing mark-and-sweep GC
- ✅ **Fast**: Lock-free fast path for most allocations
- ✅ **Simple**: Minimal changes to existing code
- ✅ **Safe**: Graceful fallbacks, no memory leaks

**Recommendation**: Implement and test. Expected to significantly reduce contention in multi-threaded promotion scenarios with minimal complexity.

---

**Next Step**: Start with Phase 1 - add TLAB infrastructure to headers, then implement methods incrementally.
