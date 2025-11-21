# TLAB Visual Diagrams

## Memory Layout

```
Old Gen Space (e.g., 512MB reserved)

┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  Free-List Region (256MB)      TLAB Region (256MB)             │
│  ┌──────────────────────────┐  ┌───────────────────────────┐   │
│  │                          │  │                           │   │
│  │  [Free blocks]           │  │  [TLAB 1][TLAB 2][TLAB 3] │   │
│  │  [Allocated objects]     │  │  [TLAB 4][TLAB 5]...      │   │
│  │  [Large objects]         │  │                           │   │
│  │                          │  │  ← tlab_bump_ptr (atomic) │   │
│  │                          │  │                           │   │
│  └──────────────────────────┘  └───────────────────────────┘   │
│  ^                          ^   ^                           ^   │
│  region_base           tlab_region_start            tlab_region_end
│                              (= region_base + max_size/2)       │
└─────────────────────────────────────────────────────────────────┘
```

## TLAB Structure (128KB each)

```
Single TLAB (Thread-Local Allocation Buffer)

┌──────────────────────────────────────────────────────────┐
│                                                          │
│  [Obj 1][Obj 2][Obj 3][Obj 4]...       [Free space]     │
│  ^                              ^                     ^  │
│  start                     alloc_ptr                 end │
│                            (bumps →)                     │
│  <─────────── Used ──────────>  <──── Remaining ────>   │
│                                                          │
└──────────────────────────────────────────────────────────┘
            128 KB total capacity
```

## Allocation Flow Diagram

```
Thread needs to promote object during Minor GC
                │
                ▼
        ┌───────────────────┐
        │ Try allocate from │
        │  promotion_tlab   │
        └─────────┬─────────┘
                  │
          ┌───────┴────────┐
          │                │
       Success?          Null?
          │                │
          ▼                ▼
      ┌─────┐      ┌──────────────┐
      │Done │      │ TLAB full or │
      │     │      │ doesn't exist│
      └─────┘      └──────┬───────┘
                          │
                          ▼
                  ┌──────────────────┐
                  │ Seal current TLAB│
                  │ (if exists)      │
                  └────────┬─────────┘
                           │
                           ▼
                  ┌──────────────────────┐
                  │ allocateTLAB()       │
                  │ (lock-free CAS)      │
                  └──────┬───────────────┘
                         │
                 ┌───────┴────────┐
                 │                │
              Success?          Null?
                 │                │
                 ▼                ▼
        ┌────────────────┐   ┌──────────────────┐
        │ Allocate from  │   │ TLAB region full │
        │ new TLAB       │   │ or object too    │
        └───────┬────────┘   │ large (>128KB)   │
                │            └────────┬─────────┘
                ▼                     │
            ┌─────┐                   ▼
            │Done │           ┌──────────────────┐
            └─────┘           │ oldgen.allocate()│
                              │ (free-list)      │
                              │ TAKES MUTEX      │
                              └────────┬─────────┘
                                       │
                                       ▼
                                   ┌─────┐
                                   │Done │
                                   └─────┘
```

## Thread Contention Comparison

### Before TLAB (Current)
```
Thread 1 promotes:          Thread 2 promotes:          Thread 3 promotes:
┌────────────────┐          ┌────────────────┐          ┌────────────────┐
│ Need oldgen    │          │ Need oldgen    │          │ Need oldgen    │
│ allocation     │          │ allocation     │          │ allocation     │
└───────┬────────┘          └───────┬────────┘          └───────┬────────┘
        │                           │                           │
        └───────────┬───────────────┴───────────────────────────┘
                    │
                    ▼
            ┌──────────────────┐
            │  MUTEX CONTENTION│ ← All threads compete!
            │  alloc_mutex     │
            └───────┬──────────┘
                    │
            ┌───────┴────────┬───────────────────────┐
            ▼                ▼                       ▼
        Thread 1         Thread 2              Thread 3
        gets lock       WAITING...            WAITING...
        allocates       WAITING...            WAITING...
        releases        gets lock             WAITING...
                        allocates             WAITING...
                        releases              gets lock
                                              allocates
                                              releases

Result: Serial execution, high contention
```

### After TLAB
```
Thread 1 promotes:          Thread 2 promotes:          Thread 3 promotes:
┌────────────────┐          ┌────────────────┐          ┌────────────────┐
│ Bump alloc_ptr │          │ Bump alloc_ptr │          │ Bump alloc_ptr │
│ in TLAB 1      │          │ in TLAB 2      │          │ in TLAB 3      │
│ NO LOCK!       │          │ NO LOCK!       │          │ NO LOCK!       │
└───────┬────────┘          └───────┬────────┘          └───────┬────────┘
        │                           │                           │
        ▼                           ▼                           ▼
    ┌─────┐                     ┌─────┐                     ┌─────┐
    │Done │                     │Done │                     │Done │
    └─────┘                     └─────┘                     └─────┘

                    NO CONTENTION!
                    PARALLEL EXECUTION!

Only when TLAB exhausted (every ~128KB):
┌────────────────┐          ┌────────────────┐
│ allocateTLAB() │          │ allocateTLAB() │
│ CAS bump ptr   │          │ CAS bump ptr   │
└───────┬────────┘          └───────┬────────┘
        │                           │
        └───────────┬───────────────┘
                    │
                    ▼
            ┌──────────────────┐
            │  CAS on atomic   │ ← Lock-free, retries if collision
            │  tlab_bump_ptr   │
            └───────┬──────────┘
                    │
            ┌───────┴────────┬───────┐
            ▼                ▼       ▼
        Thread 1         Thread 2   Thread 3
        CAS success      Retry      Retry
        gets TLAB        CAS success  CAS success
                         gets TLAB    gets TLAB

Result: Minimal contention, only on TLAB creation
```

## Sweep Phase Flow

```
Major GC Sweep Phase
        │
        ▼
┌──────────────────┐
│ Take alloc_mutex │
└────────┬─────────┘
         │
         ▼
┌────────────────────────────────┐
│ Part 1: Sweep Sealed TLABs     │
└────────┬───────────────────────┘
         │
         ▼
┌────────────────────────────────┐
│ For each sealed TLAB:          │
│   Walk [start ... alloc_ptr)   │
│   - White objects → free list  │
│   - Black objects → reset color│
│   Delete TLAB metadata         │
└────────┬───────────────────────┘
         │
         ▼
┌────────────────────────────────┐
│ Part 2: Sweep Free-list Region │
└────────┬───────────────────────┘
         │
         ▼
┌────────────────────────────────┐
│ Walk [region_base...           │
│       tlab_region_start):      │
│   - White objects → free list  │
│   - Black objects → reset color│
└────────┬───────────────────────┘
         │
         ▼
┌────────────────────────────────┐
│ Update free_list               │
└────────┬───────────────────────┘
         │
         ▼
┌──────────────────┐
│ Release mutex    │
└──────────────────┘
```

## Performance Characteristics

### Promotion Cost Breakdown

```
┌─────────────────────────────────────────────────────────┐
│                    Allocation Cost                      │
├──────────────────┬──────────────────────────────────────┤
│                  │  CPU Cycles   │  Frequency           │
├──────────────────┼───────────────┼──────────────────────┤
│ TLAB allocation  │  10-20        │  Most allocations    │
│ (fast path)      │               │  (99%+)              │
├──────────────────┼───────────────┼──────────────────────┤
│ TLAB creation    │  100-200      │  Every 128KB         │
│ (CAS)            │               │  (~0.1%)             │
├──────────────────┼───────────────┼──────────────────────┤
│ Free-list        │  500-2000     │  Large objects only  │
│ (mutex)          │               │  (<0.01%)            │
└──────────────────┴───────────────┴──────────────────────┘

Example workload:
  - 10,000 small object promotions (avg 256 bytes each)
  - Total: 2.5 MB promoted

Without TLAB:
  10,000 × 1000 cycles (mutex) = 10,000,000 cycles

With TLAB:
  10,000 × 15 cycles (TLAB) +     (most allocations)
  20 × 150 cycles (new TLAB) =    (2.5MB / 128KB = ~20 new TLABs)
  150,000 + 3,000 = 153,000 cycles

Speedup: 10,000,000 / 153,000 = 65x faster!
```

## Memory Overhead Analysis

```
┌─────────────────────────────────────────────────────────┐
│              Memory Overhead per Thread                 │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  TLAB metadata:                24 bytes                 │
│    - char* start                8 bytes                 │
│    - char* end                  8 bytes                 │
│    - char* alloc_ptr            8 bytes                 │
│                                                          │
│  NurserySpace::promotion_tlab:  8 bytes (pointer)       │
│                                                          │
│  Active TLAB allocation:        128 KB (shared)         │
│                                                          │
│  Total overhead:                ~128 KB + 32 bytes      │
│                                                          │
│  Overhead ratio:                0.024% of 512MB heap    │
│                                                          │
└──────────────────────────────────────────────────────────┘

Global overhead:
  - std::atomic<char*>:           8 bytes
  - sealed_tlabs vector:          ~24 bytes + 8 per sealed TLAB
  - Total global:                 <1 KB
```

## Edge Cases

### Large Object Promotion (>128KB)

```
Large object (e.g., 256KB string)
        │
        ▼
┌────────────────────┐
│ size > TLAB_SIZE?  │
│ YES                │
└────────┬───────────┘
         │
         ▼
┌────────────────────────┐
│ Skip TLAB entirely     │
│ Go direct to free-list │
│ oldgen.allocate()      │
└────────┬───────────────┘
         │
         ▼
┌────────────────────────┐
│ Allocated in free-list │
│ region, not TLAB region│
└────────────────────────┘

Rationale: Large objects don't benefit from TLAB
           and would fragment TLAB space
```

### Thread Exit with Active TLAB

```
Thread exits
        │
        ▼
┌────────────────────────┐
│ ~NurserySpace()        │
└────────┬───────────────┘
         │
         ▼
┌────────────────────────┐
│ promotion_tlab exists? │
│ YES                    │
└────────┬───────────────┘
         │
         ▼
┌────────────────────────┐
│ oldgen.sealTLAB(tlab)  │
│                        │
│ If empty: delete       │
│ If used: add to        │
│   sealed_tlabs for     │
│   next GC sweep        │
└────────────────────────┘

Result: No memory leak, objects preserved
        until next major GC
```

### TLAB Region Exhaustion

```
allocateTLAB() called
        │
        ▼
┌────────────────────────┐
│ CAS on tlab_bump_ptr   │
└────────┬───────────────┘
         │
         ▼
┌────────────────────────┐
│ new_ptr > region_end?  │
│ YES                    │
└────────┬───────────────┘
         │
         ▼
┌────────────────────────┐
│ Return nullptr         │
└────────┬───────────────┘
         │
         ▼
┌────────────────────────┐
│ Caller falls back to   │
│ free-list allocation   │
│ (mutex protected)      │
└────────────────────────┘

Result: Graceful degradation to free-list
        when TLAB region full

Future optimization: Grow TLAB region dynamically
                    or recycle sealed TLABs
```
