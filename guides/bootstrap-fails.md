# Bootstrap Failures

## Failure #1: Stage 7 — GC Tag_Forward assertion (FIXED)

**Stage:** 7 (native self-compile)  
**Symptom:** `Assertion 'hdr->tag <= Tag_Forward' failed`, tag=29  
**Root cause:** Safepoint markers placed at top of matchAndRewrite latched onto intermediate
`eco_resolve_hptr` calls instead of the actual GC-triggering evaluator calls.
`findTargetCall` in StatepointConversion found the wrong target.  
**Fix:** Moved safepoint marker emission to immediately before each final GC-triggering call
in closure dispatch helpers. Threaded `liveRoots` through emitFastClosureCall, emitClosureCall,
emitInlineClosureCall, emitDispatchedClosureCall, lowerSegmentationUnknown, lowerGenericApply.
Also added markers before boxing calls (eco_alloc_int/float/char) in those paths.  
**Status:** FIXED  
**Attempts:** 1

## Failure #2: Stage 7 — eco_pap_extend new_n_values exceeds max_values

**Stage:** 7 (native self-compile)  
**Symptom:** `eco_pap_extend: new_n_values (34) exceeds max_values (1)` followed by
`Assertion 'obj < heap_end' failed` when resolving HPointer `0x2d002d002d002d`  
**Backtrace:** `eco_apply_segmentation_unknown → eco_apply_closure → eco_closure_call_saturated
→ wrapper → Bytes_Decode_loopHelp → eco_apply_segmentation_unknown (corrupt closure)`

### Evidence
1. HPointer raw=`0x2d002d002d002d` = UTF-16 dashes — string data interpreted as closure
2. The crash occurs INSIDE the C++ runtime chain, not in LLVM-compiled code
3. Statepoints correctly wrap calls FROM LLVM code INTO the C++ runtime
4. The corruption arises because:
   - LLVM-compiled code creates a stack-allocated `args` array (via alloca) containing HPointers
   - The statepoint tracks individual SSA roots in the LLVM frame, but NOT the contents of the args array
   - When GC runs inside the C++ runtime chain (via evaluator → allocation), it relocates heap objects
   - The HPointers stored in the args array are NOT relocated because they're not GC roots
   - When `eco_apply_closure` over-saturated path chains at line 879 with `args + remaining`, those args may be stale

### Hypothesis
Stack-allocated `args` arrays in PapExtend/GenericApply lowering hold HPointers that are not
GC-tracked. The statepoint system only tracks SSA-level roots, not heap pointers stored in
stack-allocated buffers. This is a **pre-existing architectural limitation** — the same pattern
exists before our changes. Our statepoint changes correctly protect LLVM-frame roots but cannot
protect the contents of alloca'd arrays passed to C++ runtime functions.

### Fix options
1. **Pin allocations during C++ runtime calls** — prevent GC from moving objects while runtime
   functions hold raw HPointers (simplest but limits GC performance)
2. **Use a shadow stack** — register stack-allocated arrays as GC root ranges
3. **Refactor C++ runtime** to not hold HPointers across GC-triggering calls
4. **Change args arrays to use GC-safe storage** (e.g., registered root buffers)

### Attempts

**Attempt 1 (GC suppress):** Added `GCSuppressGuard` RAII class to suppress proactive GC
during C++ runtime functions (eco_apply_closure, eco_apply_segmentation_unknown,
eco_closure_call_saturated). With full suppression: nursery overflows (OOM). With safety
valve (allow GC at 95%): same crash at lower n_values (4 vs 34). Fundamentally, can't
suppress GC for long enough without OOM, and any GC during suppression causes the same
staleness problem.

**Root cause confirmed:** The HPointer args arrays are allocated on the LLVM stack (via alloca)
and passed by pointer to C++ runtime functions. These arrays contain GC-managed HPointers,
but the array CONTENTS are not tracked by the statepoint system. The statepoint tracks
individual SSA values in the LLVM frame. When GC runs (even via statepoints that correctly
protect LLVM-frame roots), the values inside the alloca'd arrays are not relocated.

**Proper fix requires:** Refactoring the LLVM lowering to not use alloca'd arrays for passing
HPointers to C++ runtime functions. Options:
1. Inline the C++ runtime dispatch into LLVM IR so all values are SSA roots
2. Use a GC-safe buffer (registered with the GC root scanner)
3. Change the runtime ABI to take individual args instead of arrays

**Status:** SKIPPED — requires architectural change beyond the current bootstrap-fix loop.
Needs user guidance on which fix approach to take.
**Attempts:** 1

## Failure #3: Stage 7 — Stale nursery pointer after RS4GC migration (OPEN)

**Stage:** 7 (native self-compile)
**Symptom:** `Assertion 'ok' failed` in `debugAssertValidNurseryPointer` — stale pointer
`0x7f...bf8` in nursery to-space free region, `in_minor_gc=0` (mutator phase).

**Backtrace:**
```
eco_resolve_hptr
Terminal_Main_lambda_5658
__closure_wrapper_Terminal_Main_lambda_5658
eco_closure_call_saturated
eco_apply_closure
List_foldl_$_7257
Dict_fromList_$_7250
__closure_wrapper_Dict_fromList_$_7250
eco_apply_segmentation_unknown
```

**How far it got:** Very early — before any "Compiling" output. 7 GC cycles
completed successfully. Crash occurs during 8th allocation cycle in mutator code
(not during GC). The compiler was initializing `Dict.fromList` on startup data.

### Evidence

1. **Stackmaps are functional.** 221,989 records with 2,169,945 locations:
   - 1,503,978 Indirect (processed correctly as GC roots)
   - 665,967 Constant (gc.statepoint header fields — ID/flags/etc. — correctly skipped)
   - 0 Register, 0 Direct, 0 ConstIndex
   The initial report of "numLocs=0" was a debug-logging bug (reading `record.locations.size()`
   after `std::move`).

2. **The Constant(0) locations are harmless.** Every stackmap record begins with 3
   Constant(0) locations — these are the gc.statepoint metadata fields (statepoint ID,
   number of deopt args, callee info). They are not GC roots and correctly skipped.
   Actual GC roots follow as Indirect base/derived pairs.

3. **The stale pointer is in old to-space (free region).** After the 7th GC swapped
   spaces, an HPointer still references the old to-space block 14 which is now free.
   This means the HPointer was NOT relocated during the GC.

4. **Scan parent at crash:** `tag=3 (Custom), size=4`. Field data includes `0x006c0073006c0067`
   which is UTF-16 text ("g", "l", "s", "l"). Likely part of a string in a data structure.

5. **The crashing function `Terminal_Main_lambda_5658`** takes 2 `ptr addrspace(1)` args,
   resolves arg0 via `eco_resolve_hptr`, loads two fields, and calls `Dict_insert`.
   RS4GC correctly wraps `Dict_insert` in a statepoint with gc-live for all 3 GC pointers.
   The function itself has correct root tracking.

6. **The caller `Dict_fromList_$_7250`** allocates a closure wrapping
   `Terminal_Main_lambda_5658` with 2 captures, but only stores the unboxed bitmap (128).
   **No capture values are written to the closure.** The captures array contains uninitialized/
   stale memory from a previous allocation. When the wrapper reads these captures and passes
   them to `Terminal_Main_lambda_5658`, they contain stale HPointers.

7. **141,618 `ptrtoint ptr addrspace(1) → i64` conversions** in the full IR. These hide
   GC pointers from RS4GC but are necessary for the args-array calling convention.
   The `eco_gc_push_stack_range` mechanism protects these arrays during GC.

### Hypothesis

The closure allocated in `Dict_fromList_$_7250` has 2 captures that are never written.
The closure wrapper reads uninitialized capture slots, which contain stale HPointers from
a previous allocation at the same memory address. This is either:
(a) A pre-existing codegen bug where `papCreate` / closure construction doesn't emit
    capture stores for this specific closure pattern, OR
(b) An LLVM optimization pass (running after RS4GC) is eliminating the capture stores
    as "dead" because it doesn't understand the side-effect of eco_store_field.

### Investigation progress

1. **Stackmaps are fully functional.** The initial "numLocs=0" report was a logging bug.
   221,989 records, 1.5M Indirect + 666K Constant locations. Constant(0) are the 3
   gc.statepoint header fields per record — correctly skipped by the runtime.

2. **The closure captures are NOT missing.** `Dict_fromList_$_7250` creates a 0-capture,
   2-arity closure (the `eco_alloc_closure(wrapper, 2)` allocates slots for the function
   args, not captures). The args are passed at call time via `eco_apply_closure` →
   `eco_closure_call_saturated` → wrapper.

3. **combined_args validation passes.** All HPointers in the `combined_args` array are
   valid at the moment before `closure->evaluator(combined_args)` is called. The stale
   pointer appears AFTER the evaluator returns — meaning a GC cycle during the evaluator
   call failed to relocate a root.

4. **The 7th GC cycle misses a root.** 7 GC cycles complete successfully. The stale
   pointer points into old to-space block 14 (free after space swap). The unrelocated
   HPointer is used by `Terminal_Main_lambda_5658` (or its caller chain) after GC.

5. **Pre-RS4GC IR confirms this is NOT an optimization artifact.** The pre-RS4GC IR has
   the same structure as the post-RS4GC IR minus statepoints. The MLIR codegen output
   is correct.

### Revised hypothesis

The root cause is a **missing gc.relocate** in the statepoint chain. Specifically, when
`Terminal_Main_lambda_5658` calls `Dict_insert_$_7255` via statepoint, and `Dict_insert`
triggers a deep call chain (red-black tree rebalancing) that eventually triggers GC, all
roots back to the top of the chain must be tracked in the stackmap. If any intermediate
frame's statepoint gc-live bundle is missing a root, the GC won't relocate it.

The most likely candidate is a function in the Dict insertion/rebalancing path that has a
statepoint with an incomplete gc-live set — either because RS4GC's liveness analysis
determined the value was dead (when it's actually live via a phi or loop), or because a
`ptrtoint ptr addrspace(1) → i64` conversion hid the value from RS4GC.

### Further investigation

6. **O0 build crashes identically** — the bug is NOT caused by LLVM optimization passes
   eliminating stores or reordering code. It's purely an RS4GC root tracking issue.

7. **Crash is fully deterministic** — always 7 GC cycles, always the same backtrace, always
   `Dict_fromList → List_foldl → eco_apply_closure → eco_closure_call_saturated →
   wrapper → Terminal_Main_lambda_5658 → eco_resolve_hptr`.

8. **combined_args validation passes** — all HPointers in the C++ `combined_args` array are
   valid at the moment BEFORE the wrapper function is called. The stale pointer appears
   AFTER the wrapper/function call chain returns. This means GC ran during the call and
   failed to relocate a root.

9. **The IR for all functions in the crash chain looks correct** — `Terminal_Main_lambda_5658`,
   `Dict_insert_$_7255`, `Dict_insertHelp_$_7259` all have proper statepoints with complete
   gc-live bundles. RS4GC's liveness analysis appears correct for the functions I checked.

10. **Stack root counts are reasonable** — 184-552 stackmap roots + 126-379 stack ranges per
    GC cycle. The stackmap scanning is functional and finding records.

### Remaining hypotheses

1. **Stack range + stackmap double-relocation conflict** — The same HPointer is tracked as
   both a stackmap Indirect root AND a stack range entry. If Phase 1b and 1e both try to
   evacuate it, and the memory layout causes the second evacuation to produce a different
   result, the HPointer could become inconsistent. Need to verify this doesn't happen.

2. **Wrapper function return type issue** — The wrapper returns `ptr` (addrspace 0), not
   `ptr addrspace(1)`. The `ptrtoint + inttoptr` round-trip at the boundary might confuse
   RS4GC's liveness analysis in the caller.

3. **Missing statepoint in a deeply-nested function** — A function called from Dict_insert's
   rebalancing chain (moveRedLeft, moveRedRight, balance, etc.) might have a missing root
   in its gc-live bundle. Need to check these functions' IR.

### Critical finding

11. **Post-GC validation shows NO unrelocated roots.** After every GC cycle (Phases 1-2),
    all stack roots (both stackmap Indirect and stack ranges) point to valid locations.
    None are left in from-space. This means the GC root scanner is finding and relocating
    all tracked roots correctly.

12. **The stale pointer is NOT in any tracked root at GC time.** It must be in a location
    that is neither a stackmap Indirect slot nor a stack range entry. Candidates:
    - A value ptrtoint'd to i64 and stored in a location not covered by stack ranges
    - A C++ local variable in a runtime function that holds a raw `Closure*` or HPointer bits

13. **All alloc functions protect their HPointer parameters.** `eco_alloc_cons`, 
    `eco_alloc_tuple2`, etc. all use `eco_gc_push_stack_range` to root their parameters
    across the internal `Allocator::allocate()` call that may trigger GC.

14. **O0 build crashes identically.** Confirmed this is NOT an LLVM optimization artifact.

15. **All 69,051 `eco_alloc_*` calls are statepoint-wrapped.** RS4GC processed every
    allocation call in the module.

### Refined hypothesis

The stale pointer is likely in a **closure's capture values** stored in a heap object.
When GC runs, it evacuates the closure object itself (and forwards it). The captures
are HPointers stored as raw i64 words in the closure's values[] array. The GC's
`scanObject` for `Tag_Closure` should process these. But if the closure's `unboxed`
bitmap incorrectly marks a boxed capture as unboxed, `scanObject` would skip it
(via `evacuateUnboxable`), leaving the HPointer unrelocated.

Alternatively: the `eco_store_field` call that writes a capture into a closure might
be storing into a location that's ALREADY been forwarded. If the store happens after
GC evacuated the closure but before the caller uses the relocated HPointer, the store
writes to the old (forwarded) copy, not the new copy.

**Fix plan:**
1. Add tracing to `scanObject` for Tag_Closure to log bitmap vs actual values
2. Check if any `eco_store_field` writes to a forwarded object
3. Check all functions in the Dict rebalancing chain for ptrtoint conversions that
   hide live GC pointers from stack range protection

### Investigation plan

The failure mode is isolated: an HPointer that has been `ptrtoint`'d to `i64` escapes
all root-tracking mechanisms (stackmap gc-live bundles and stack ranges). The remaining
work is to (a) find the specific escape, then (b) either forbid this class of escape
or explicitly track it.

#### Step 1 — Fingerprint the failing HPointer value

In `eco_resolve_hptr`, on stale-pointer detection:
- Log the raw HPointer value (i64 hex), GC cycle count, generation/space ranges.
- Scan the entire heap for that exact 64-bit pattern and log all addresses where it
  occurs (if it appears in a heap object field, that identifies the object type and
  layout to focus on; if it only appears in registers/stack, it never hit the heap).
- During GC, add a "debug pattern" check: once the failing value is known from one run,
  rerun with a heap scan after each collection that asserts if that value is still present.
  This reveals *which* GC cycle the value first goes stale.

#### Step 2 — Instrument ptrtoint sites with site IDs

There are 141k+ `ptrtoint ptr addrspace(1) → i64` sites. To find the one producing the
stale value:
1. Write a simple LLVM pass that assigns each `ptrtoint ptr addrspace(1) → i64` a static
   site ID (incrementing counter baked as a constant).
2. After each `ptrtoint`, insert a call to a runtime hook:
   ```llvm
   call void @eco_debug_hptr_to_int(i64 %result, i32 <site_id>)
   ```
3. `eco_debug_hptr_to_int` maintains a ring buffer of recent `(value, site_id)` pairs.
4. On stale-pointer detection, look up the value in the ring buffer to find which site
   last produced it — directly answering whether it came from a closure capture store,
   Dict node construction, or some other encoding path.

Because the failure is deterministic and early (7 GC cycles), the ring buffer only needs
modest capacity.

#### Step 3 — Audit suspected escape paths

**3.1 Closure captures via raw GEP+store:**
Look for IR that allocates/initializes a closure, then writes an `i64` (from `ptrtoint
ptr addrspace(1)`) via raw `getelementptr` + `store`, NOT via `eco_store_field`.
In the post-RS4GC IR (`/tmp/rs4gc-compiler.ll`):
```bash
# Find closure capture stores (raw GEP into closure struct after eco_resolve_hptr)
grep -B5 'store i64.*ptr.*align' /tmp/rs4gc-compiler.ll | grep -A1 'getelementptr i8.*ptr.*i64 [0-9]'
```
Prioritize closures used in `Dict` operations and `Terminal_Main_lambda_5658`.

**3.2 Dict node fields stored as i64:**
Check the `Dict_insertHelp`, `Dict_balance`, `Dict_moveRedLeft`, `Dict_moveRedRight`
functions for `ptrtoint ptr addrspace(1) → i64` followed by store into a Dict node
(Custom tag=3 object) via raw GEP+store. If a Dict node field containing an HPointer
is stored as i64 and then the node is evacuated by GC, the GC scans it with the
`unboxed` bitmap — if that bitmap incorrectly marks the field as unboxed, the GC skips
the field and the HPointer becomes stale.

#### Step 4 — If i64 handles in heap are intentional: add heap scanning

If the design requires storing HPointers as `i64` in heap objects, the GC must know:
1. Type-based descriptor listing which words may contain HPointers.
2. During `scanObject`, reinterpret those words as HPointers and evacuate them.
3. Short-term: in the post-GC heap validator, walk all heap objects and for every word
   that looks like a valid HPointer, assert it points to to-space, not from-space.

#### Step 5 — Exploit determinism

The crash is fully deterministic (7 GC cycles, same backtrace). Use this:
1. Temporarily forbid `ptrtoint` for the `Dict` module and `Terminal_Main` module
   in the code generator. If the crash disappears, that isolates the escaping module.
2. Add a hard assertion at GC cycle 7: dump all Dict nodes and closure objects, search
   for the failing HPointer value.

#### Step 6 — Trace i64 HPointers leaving stack range protection

Find functions where an `i64` parameter representing a handle:
- Is NOT covered by a stack range wrapper.
- Is stored to heap, or kept across a statepoint without being registered.
At IR level: treat any `i64` reaching `eco_resolve_hptr` as a "handle-int". Walk
backwards from parameters to uses; flag any store to heap or unregistered alloca.

### Session 2 investigation (2026-04-18)

16. **Post-GC heap walk: NO stale children in heap objects.** After every GC cycle,
    walked all surviving objects in to-space (Cons, Tuple, Custom, Record, Closure,
    DynRecord). Every boxed child pointer is valid — none point to from-space.
    **The stale pointer is NOT in any heap object.**

17. **Post-evaluator combined_args check: stale entry detected.** Adding validation
    of `combined_args` entries AFTER `closure->evaluator(combined_args)` returns
    catches the stale pointer. The stack range SHOULD have protected combined_args
    during the evaluator call.

18. **combined_args entries DO get relocated during GC.** Log of [closure-post] CHANGED
    entries shows many successful relocations (before=0x4xxxxx → after=0x6xxxxx).
    The stack range mechanism works for most entries.

19. **15,706 closure captures stored as `ptrtoint ptr addrspace(1) → i64`** via raw
    GEP+store into closure body. All boxed (unboxed bitmap = 0 for the relevant bits).
    The GC's scanObject for Tag_Closure correctly scans them using `cl->unboxed`.

20. **GDB stack inspection** shows combined_args on eco_closure_call_saturated's stack
    with a mix of from-space (0x4xxxxx) and to-space (0x6xxxxx) HPointer values.
    One entry appears unrelocated while others were updated — suggesting the stack
    range processing missed one specific entry.

### Root cause narrowed

The stale pointer is NOT in any heap object (finding 16) and NOT in any permanently
tracked root. It IS in `combined_args` after the evaluator returns (finding 17),
meaning it was NOT relocated by Phase 1e stack range processing. But the stack range
WAS registered (finding 18 shows other entries ARE relocated). This points to either:

(a) A specific entry in combined_args that was NOT covered by the hpointer_mask, OR
(b) The evacuate for this specific entry failed for some reason (object was in old-gen
    or had unusual tag), OR
(c) The entry was overwritten AFTER GC by something in the evaluator call chain.

The most likely candidate is (c): during the evaluator call, the wrapper's statepoint
spills values to stack slots. If a spill slot physically OVERLAPS with combined_args
(unlikely but possible with aggressive stack layout), GC would update the spill slot
AND combined_args independently, but the wrapper's gc.relocate would later read from
the spill slot and the ORIGINAL un-relocated value could be written back to
combined_args by the wrapper's epilog.

### Session 2 continued — HPointer value identified

21. **Stale HPointer value is `0x403997f`.** Physical address `0x7f...bf8`, heap_base at
    `0x7f...17000`. The value resolves to from-space (LOW blocks) after GC7 swaps spaces.

22. **The value `0x403997f` WAS in stack ranges during GC7.** Found at three range entries:
    - range[163] base=0x...f8f0 idx=0 (evacuated: 0x403997f → 0x6000000)
    - range[165] base=0x...f8f0 idx=0 (same base, already updated by range[163])
    - range[167] base=0x...f730 idx=0 (evacuated: 0x403997f → 0x6000000)
    ALL three were updated to `0x6000000` during GC7.

23. **Despite all tracked copies being updated, the stale value `0x403997f` is STILL used
    after GC7.** This means there is a FOURTH copy of this value somewhere that is NOT
    tracked by any root mechanism:
    - NOT in any stack range (all three were updated)
    - NOT in any stackmap Indirect slot (post-GC validation was clean)
    - NOT in any heap object child pointer (post-GC heap walk was clean)

24. **The fourth copy is most likely in an LLVM-compiled function's register or spill slot
    that RS4GC did NOT include in its gc-live bundle.** This would happen if the `ptr
    addrspace(1)` value was `ptrtoint`'d to `i64` and RS4GC's liveness analysis determined
    the `i64` value doesn't need tracking (because it's no longer a GC pointer type).

25. **Closures store captures as `ptrtoint ptr addrspace(1) → i64`** via raw GEP+store
    (15,706 sites). When a function LOADS a capture from a closure body (via
    `eco_resolve_hptr` + GEP + `load i64` + `inttoptr i64 → ptr addrspace(1)`), the
    resulting `ptr addrspace(1)` IS visible to RS4GC. But the INTERMEDIATE `i64` value
    is NOT. If RS4GC determines the `ptr addrspace(1)` is dead (e.g., it was only used
    to derive the `i64` which was stored elsewhere), it may not include it in gc-live.

**Status:** OPEN
**Attempts:** 0
