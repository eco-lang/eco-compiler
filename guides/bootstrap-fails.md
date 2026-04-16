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
