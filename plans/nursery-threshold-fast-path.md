# Nursery Threshold Fast-Path — eliminate the 72 % `wouldExceedThreshold` cost

## Motivation

A 300-second `perf record` of `eco-compiler` (Stage 7 self-compile, dwarf
call-graph at 999 Hz, 4.7 GB perf data, flat self-time saved at
`/tmp/perf-flat-300.txt`) shows:

| % self | symbol |
|---:|---|
| **72.22 %** | `Elm::NurserySpace::wouldExceedThreshold` |
| 2.06 % | `Elm::Allocator::resolve` |
| 1.32 % | `Elm::ThreadLocalHeap::allocate` |
| 1.09 % | `Elm::Allocator::instance` |
| 0.59 % | `Elm::NurserySpace::allocate` |
| 0.33 % | `Elm::Allocator::allocate` |

The 10-second profile from earlier in the session showed the same function at
48 % — it grows with the nursery, because

```cpp
// runtime/src/allocator/NurserySpace.cpp:288-303
size_t NurserySpace::bytesAllocated() const {
    const std::vector<char*>& from_blocks = ...;
    size_t bytes = 0;
    for (size_t i = 0; i < current_from_idx_ && i < from_blocks.size(); i++) {
        bytes += block_size_;
    }
    if (current_from_idx_ < from_blocks.size())
        bytes += (alloc_ptr_ - from_blocks[current_from_idx_]);
    return bytes;
}

// NurserySpace.cpp:306-313
bool NurserySpace::wouldExceedThreshold(size_t size, float threshold) const {
    ...
    size_t total_capacity = from_blocks.size() * block_size_;
    size_t usage_after = bytesAllocated() + (size + 7) & ~7;
    return usage_after >= (size_t)(total_capacity * threshold);
}
```

is called from `ThreadLocalHeap::allocate` (NurserySpace.cpp:147) on **every**
nursery allocation. With `nursery_block_count=64` (default; grows to ~128
during this run) the per-allocation cost climbs linearly with
`current_from_idx_`.

The compiler hot path generates almost exclusively legacy single-path
allocators (`eco_alloc_cons`, `eco_alloc_tuple2`, `eco_alloc_custom`,
`eco_alloc_closure`, `eco_alloc_int/float/char`, `eco_alloc_string`,
`eco_alloc_tuple3`, `eco_alloc_record`) which all funnel into
`Allocator::instance().allocate(size, tag)` →
`ThreadLocalHeap::allocate` → `wouldExceedThreshold`. The
`eco_alloc_*_fast` / `eco_alloc_*_slow` C ABI entry points exist
(`runtime/src/allocator/RuntimeExports.cpp:394-689`) and the codegen has
matching `getOrCreateAlloc*Fast` / `getOrCreateAlloc*Slow` helpers
(`runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:174-258`), but a grep of
`runtime/src/codegen/Passes/*.cpp` shows zero call sites — only the
region-coalesced allocator (used by `EcoGCPrepare` groups) actually emits
the fast/slow pattern (EcoToLLVMHeap.cpp:1565, 1596). Plain non-coalesced
allocations still fall through `emitAllocWithSafepoint`, which emits a
single direct call to the legacy entry point.

This plan addresses three layered fixes from least to most invasive.

---

## Item 1 — Make `bytesAllocated()` / `wouldExceedThreshold()` O(1)

The minimal, lowest-risk change. Independent of the fast-path/codegen work.

### File

`runtime/src/allocator/NurserySpace.cpp` (and `.hpp` if a cached field is
added).

### Change

Replace the loop:

```cpp
size_t NurserySpace::bytesAllocated() const {
    const std::vector<char*>& from_blocks = from_is_low_ ? low_blocks_ : high_blocks_;
    size_t bytes = current_from_idx_ * block_size_;
    if (current_from_idx_ < from_blocks.size())
        bytes += (alloc_ptr_ - from_blocks[current_from_idx_]);
    return bytes;
}
```

Optionally cache `total_from_capacity_bytes_` and a precomputed
`threshold_total_bytes_ = total_from_capacity_bytes_ * config_->nursery_gc_threshold`
on the nursery so `wouldExceedThreshold` becomes:

```cpp
bool NurserySpace::wouldExceedThreshold(size_t size, float /*ignored*/) const {
    return bytesAllocated() + ((size + 7) & ~7) >= threshold_total_bytes_;
}
```

`threshold_total_bytes_` only needs to be recomputed when blocks are added —
i.e. inside the same code paths that `push_back` to `low_blocks_` /
`high_blocks_` (initialize x3, `checkAndGrow`). The `nursery_gc_threshold`
config field is already cached on the nursery via `growth_threshold_` (a
mirror exists for `nursery_growth_threshold`); add a sibling
`gc_threshold_` field with the same lifetime.

### Expected win

Per-allocation cost drops from O(`current_from_idx_`) to two loads + one
add + one compare. On the workload measured (300 s, 72 % in this function),
this single change should recover ~70 % of CPU — roughly 3× steady-state
throughput.

### Risk

Very low. The function's contract doesn't change; only the implementation.
No callers depend on the loop-shaped cost. Existing GC tests cover the path.

---

## Item 2 — Fold threshold into `alloc_end_` so the fast path elides the
check entirely

After Item 1 the threshold check is O(1) but still costs a function call
plus a load + compare per allocation. Item 2 removes the call from the fast
path.

### Idea

`alloc_ptr_` and `alloc_end_` already gate the fast path:

```cpp
// NurserySpace.cpp:246-249
if (alloc_ptr_ + size <= alloc_end_) {
    result = alloc_ptr_;
    alloc_ptr_ += size;
    GC_STATS_MINOR_RECORD_ALLOC(stats, size);
}
```

If `alloc_end_` is set to `min(block_end, threshold_break_offset_in_block)`
whenever a block becomes the current-from block, the same comparison
trips both block-end and threshold-end. The slow path (`allocateSlow`) then
distinguishes:

- `alloc_ptr_ < block_end` → threshold tripped → invoke `minorGC()`.
- `alloc_ptr_ == block_end` → block exhausted → advance `current_from_idx_`.

`ThreadLocalHeap::allocate` no longer calls `wouldExceedThreshold` at all.
The fast path inside `NurserySpace::allocate` is unchanged in shape but now
covers both conditions.

### Where `alloc_end_` is set

All four sites:

- `initialize` paths — three copies at NurserySpace.cpp:109-110, 151-152,
  195-196.
- `allocateSlow` block advance — NurserySpace.cpp:271-272.
- `minorGC` post-swap — NurserySpace.cpp:842-846.

Each becomes:

```cpp
char* block_start = ...;
char* block_end   = block_start + block_size_;
char* threshold_in_block = computeThresholdEnd(block_start);
alloc_end_ = std::min(block_end, threshold_in_block);
```

with `computeThresholdEnd` defined as:

```cpp
char* NurserySpace::computeThresholdEnd(char* block_start) const {
    size_t already_full = current_from_idx_ * block_size_;
    if (already_full >= threshold_total_bytes_) return block_start;
    size_t remaining_to_threshold = threshold_total_bytes_ - already_full;
    if (remaining_to_threshold >= block_size_)
        return block_start + block_size_;  // block ends before threshold
    return block_start + remaining_to_threshold;
}
```

### Slow-path disambiguation

`allocateSlow` (NurserySpace.cpp:265) is called when the fast comparison
fails. Today it always tries to advance to the next block. Under this
change it must:

1. If `alloc_ptr_ < block_end_for_current_block`, return nullptr (threshold
   tripped — caller will GC).
2. Otherwise advance to the next block as today.

`ThreadLocalHeap::allocate` (line 135-162) becomes:

```cpp
void* obj = nursery_.allocate(size);          // covers both cases
if (LIKELY(obj != nullptr)) {
    initHeaderForTag(getHeader(obj), tag, size);
    return obj;
}
minorGC();
obj = nursery_.allocate(size);
... // header init or assert
```

The proactive `wouldExceedThreshold` call goes away.

### Expected win

Removes the residual cost from Item 1: no function call, no extra branch on
the fast path. The existing fast path is already a load-load-compare-add
sequence; the threshold becomes free.

### Risk

Slightly higher than Item 1 — the contract for `alloc_end_` changes
("block end" → "earlier of block end or threshold end"). Need to audit:

- Any code outside `NurserySpace::allocate` that reads `alloc_end_`. A
  grep shows only the four sites listed above plus the field declaration —
  the field is `private` to `NurserySpace` and not exposed via the test
  helper. Safe.
- The `_FAST` C entry points (`eco_alloc_cons_fast` etc.) also call
  `Allocator::instance().allocateFast` → `ThreadLocalHeap::allocateFast` →
  `nursery_.allocate`. They currently bypass the threshold deliberately;
  with this change, they would honour it via the bumped `alloc_end_`. That
  is **the desired semantics** — the existing `_fast` paths return null on
  threshold trip, which their `_slow` siblings already handle. Confirm
  with the call graph from the EcoToLLVMHeap region path (1565, 1596).

### Test plan

- E2E: `cmake --build build --target full` should be fully green.
- A targeted unit test that allocates exactly to threshold, then one more
  byte, and asserts that the slow path triggers `minorGC` not block
  advance. `tests/runtime/AllocatorTests.cpp` already has nursery
  fixtures.
- Re-run `perf record` on the same Stage-7 workload and confirm
  `wouldExceedThreshold` is gone from the top-30 self-time list.

---

## Item 3 — Switch codegen to `*_fast` / `*_slow` split per allocation op

Independent of Items 1 and 2; they win back the per-allocation cost,
this wins back the per-allocation **stack-rooting** cost embedded in
the legacy `eco_alloc_cons`, `eco_alloc_tuple2`, `eco_alloc_custom`
entry points (each one calls `eco_gc_stack_range_point` +
`eco_gc_push_stack_range` + `eco_gc_restore_stack_range_point`
around `Allocator::instance().allocate(...)`; these together account
for ~2 % of CPU at 300 s).

### Existing infrastructure to leverage

- C ABI fast/slow exports already live in `RuntimeExports.cpp`:
  `eco_alloc_int_fast/slow`, `_float_fast/slow`, `_char_fast/slow`,
  `_cons_fast/slow`, `_tuple2_fast/slow`, `_tuple3_fast/slow`,
  `_record_fast/slow`, `_custom_fast/slow`, `_string_fast/slow`,
  `_closure_fast/slow`. Each `_fast` returns `nullptr` on bump-pointer
  failure with no GC; each `_slow` may GC.
- LLVM helpers already exist: `getOrCreateAlloc*Fast` and
  `getOrCreateAlloc*Slow` (`EcoToLLVMRuntime.cpp:174-258`).
- `EcoGCPrepare`-coalesced groups already use the fast/slow region
  pattern (`EcoToLLVMHeap.cpp:1560-1608`). That is the template to
  follow for individual ops.

### What changes

Replace the body of `eco::detail::emitAllocWithSafepoint`
(`runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:692-706`) — currently
just one direct call — with a fast/slow lowering pattern:

```text
%fast = call <Fast>(... args ...)
%isNull = icmp eq %fast, null
cond_br %isNull -> slowBlock, fastBlock
fastBlock:
  br merge(%fast)
slowBlock:
  %slow = call <Slow>(... args ...)
  br merge(%slow)
merge(%result):
  ...
```

The function signature already takes both `allocFunc` and `liveRoots`;
extend the runtime helper to take a paired `allocFuncFast`/`allocFuncSlow`
or thread a small struct through. RS4GC already handles statepoint
insertion around the slow call (the comment at line 702 confirms this);
no manual `__eco_safepoint_marker` is needed.

### Per-op call sites to update

`grep -n emitAllocWithSafepoint runtime/src/codegen/Passes/*.cpp`:

- `EcoToLLVMHeap.cpp` lines 98, 104, 110 (BoxOp: int / float / char)
- `EcoToLLVMHeap.cpp` lines 207, 242, 273 (allocate_string / allocate_ctor / list construct)
- `EcoToLLVMHeap.cpp` lines 319 (tuple2)
- `EcoToLLVMHeap.cpp` lines 478, 513 (record / tuple3 — confirm)
- `EcoToLLVMHeap.cpp` lines 650, 767 (allocate_ctor with EcoGCPrepare-split fields)
- `EcoToLLVMClosures.cpp` line 249 (closure alloc)

Each call site already passes the legacy `getOrCreateAllocXxx` helper. The
change is to also pass the matching `getOrCreateAllocXxxFast` /
`getOrCreateAllocXxxSlow` so `emitAllocWithSafepoint` can build the
fast/slow pattern.

### Header init: fast vs slow

`eco_alloc_*_fast` does the header init inline (NurserySpace.cpp shows the
fast variant calls `allocateFast` then writes `Header*` directly).
`eco_alloc_*_slow` mirrors that. Both return a fully-initialised HPointer.
Confirm parity for every (fast, slow) pair before relying on this.

### Skipped helpers

Three of the legacy helpers do work *beyond* allocation that the fast
variants do not (they push roots around the inner `allocate`):

- `eco_alloc_cons` (RuntimeExports.cpp:188)
- `eco_alloc_tuple2` (RuntimeExports.cpp:222)
- `eco_alloc_tuple3`, `eco_alloc_record`, `eco_alloc_custom`, ... — to verify

Switching to `_fast` removes that rooting. RS4GC inserts statepoint roots
around the `_slow` call automatically; the rooting in the fast path is
unnecessary because there is no allocation that can move things.

### Expected win

~2 % CPU on top of Items 1 and 2 (the rooting-overhead). Cumulative effect
of all three items: ~70 + ~1 + ~2 = ~73 % CPU recovered.

### Risk

Moderate — touches every alloc site in codegen and changes the IR shape
(one call → two calls + branch + phi). RS4GC must remain happy with the
new pattern. The region-coalesced path already does exactly this, so the
infrastructure is proven.

### Test plan

- `cmake --build build --target full` (E2E + ecor tests).
- MLIR FileCheck tests for the new lowering pattern (mirror the region
  group tests in `tests/runtime/MlirFileCheck/`).
- Re-run `perf record` on Stage-7 — confirm
  `eco_gc_push_stack_range`/`eco_gc_restore_stack_range_point` self-time
  drops.
- Stress test (`stress-test`) target — coverage for the slow path
  (forced GC under load).

---

## Sequencing

| # | Change | Risk | Win |
|---|---|---|---|
| 1 + 2 (bundled) | O(1) `bytesAllocated()` + cached `threshold_total_bytes_` + fold threshold into `alloc_end_` so `wouldExceedThreshold` drops out of the hot path | low–moderate | ~71 % CPU |
| 3 | Switch codegen to `*_fast`/`*_slow` per op (all eleven entry points; convert the two `JsonExports.cpp` callers too) | moderate | ~2 % beyond #1+2 |

Items 1 and 2 ship together as a single bundled change. Re-profile after
that lands, then ship Item 3.

---

## Resolved decisions

1. **Bundle Items 1 + 2** as one change — confirmed.
2. **Item 3 scope: all eleven legacy entry points** (`eco_alloc_int`,
   `_float`, `_char`, `_string`, `_cons`, `_tuple2`, `_tuple3`, `_record`,
   `_custom`, `_closure`, plus the generic `eco_allocate`). All have
   `_fast`/`_slow` siblings (or get them added in this item if missing —
   audit during implementation).
3. **Keep `nursery_gc_threshold`** as a tunable config knob. The value
   is consumed once per block transition to derive
   `alloc_end_`, not on the hot path. Removing the
   `wouldExceedThreshold` method itself is fine; the *config field* and
   its semantics are preserved. See the "Does folding into alloc_end_
   lose tunability?" note below.
4. **`nursery_growth_threshold` confirmed out of scope** — it's an
   end-of-GC sizing knob, untouched by all three items.
5. **`elm-kernel-cpp/src/json/JsonExports.cpp` callers (2 sites): convert
   to `_fast`/`_slow`** as part of Item 3. They're hand-written C++ but
   the fast/slow branching pattern is straightforward at the C++ level
   (mirror the codegen IR pattern in plain C++).
6. **Future perf runs**: use `-F 199` (or `-F 99`) and
   `--call-graph dwarf,8192`; pass `--percent-limit 1 --no-children` to
   `perf report` to stay under ~2 GB RSS on a 16 GB host.

---

## Does folding the threshold into `alloc_end_` lose tunability of
`nursery_gc_threshold`?

**No.** The threshold value remains a fully tunable config knob; only the
*site at which it is consumed* moves. Two ways to think about it:

### What changes

Today: every nursery allocation reads `config_->nursery_gc_threshold`,
multiplies it by total nursery capacity, and compares against
`bytesAllocated()`. The threshold is consumed **per allocation**.

After Item 2: when the nursery enters a new block (initialize,
`allocateSlow` advance, `minorGC` post-swap, or `checkAndGrow` adds new
blocks), it computes:

```cpp
threshold_total_bytes_ = total_from_capacity_bytes_ * nursery_gc_threshold;
already_full           = current_from_idx_ * block_size_;
remaining_to_threshold = max(0, threshold_total_bytes_ - already_full);
alloc_end_             = block_start + min(block_size_, remaining_to_threshold);
```

The threshold is now consumed **once per block transition** (~64–128
times per minor-GC cycle, vs. millions of times per cycle today). The
value semantic is identical — at threshold, the next allocation falls off
the fast path and triggers `minorGC` — but the per-allocation cost
disappears.

### What you can still tune at runtime

- `nursery_gc_threshold = 0.5` → `alloc_end_` lands at 50 % nursery
  occupancy on the block where 50 % falls. Minor GC fires there.
- `nursery_gc_threshold = 0.9` → identical behaviour, just at 90 %.
- `nursery_gc_threshold = 1.0` → `alloc_end_` is always `block_end`;
  GC fires only when the entire nursery is full. Same as removing the
  threshold.

### Granularity caveat

The trip point is granular at the byte level *within* a block (we set
`alloc_end_` exactly at `block_start + remaining_to_threshold` for the
block where the threshold falls), so precision is preserved. There's no
rounding to block boundaries.

### What you'd need to add for live re-tuning

If we want `nursery_gc_threshold` to be *changeable mid-run* (today it
isn't — it's read at startup and treated as immutable), Item 2 needs a
`setGcThreshold(float)` method that recomputes
`threshold_total_bytes_` and re-derives the current
block's `alloc_end_`. The existing implementation also assumes immutable
config; this is a non-regression. Heap-config sweep tooling
(`heap-profile.py`) restarts the binary per variant rather than mutating
config, so this is a no-op for current consumers.

### Summary

Folding into `alloc_end_` is a *mechanical* change: the same arithmetic
runs, just in a colder location. Every value the user can tune today
remains tunable; only the per-allocation overhead of computing it is
removed.
