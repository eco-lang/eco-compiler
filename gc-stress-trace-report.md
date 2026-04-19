# GC Stress Test Trace Report (2026-04-18)

## Overview

31 stress tests in `test/stress-elm/`, 28 fail. Investigation found TWO distinct root causes:

1. **Alloca-in-loop stack exhaustion** (FIXED) — `LLVM::AllocaOp` emitted inside loop bodies accumulates stack space, causing SIGSEGV after ~900K iterations.
2. **GC heap corruption** (OPEN) — cons cell data corrupted after multiple GC cycles; exact mechanism still under investigation.

## Category 1: Alloca-in-Loop Stack Exhaustion

### Discovery

Created minimal reproducer `MinGcTest.elm`: tail-recursive loop calling a closure callback 900K times. Crashes with SIGSEGV and 0 GC cycles — proving the crash is NOT GC-related.

### Trace Evidence

LLVM IR from `MinGcTest_loop_$_1` (BEFORE fix):
```llvm
4:                                          ; loop header
  ...
14:                                         ; loop body (executed each iteration)
  %16 = alloca i64, i64 1, align 8          ; <--- ALLOCA INSIDE LOOP
  call void @llvm.memset.p0.i64(ptr %16, ...)
  call void @eco_gc_push_stack_range(ptr %16, ...)
  %statepoint_token = call ... @eco_alloc_int(...)
  store i64 %22, ptr %19
  call ... @eco_apply_closure(...)
  call void @eco_gc_restore_stack_range_point(...)
  br label %28                               ; back to loop
```

Each iteration executes `alloca`, pushing 8 bytes onto the stack. After 900K iterations: 900,000 x 8 = 7.2MB, exceeding the 8MB stack limit.

Source: `emitRootedBoxedArgsArray` in `EcoToLLVMClosures.cpp:106` emits `LLVM::AllocaOp` at the current insertion point (which is inside the loop body for `papExtend` ops in while-loop bodies).

### Fix Applied

Hoist all args-array allocas to the function entry block:
```cpp
Value argsArray;
{
    OpBuilder::InsertionGuard allocaGuard(rewriter);
    auto parentFunc = safeOp->getParentOfType<LLVM::LLVMFuncOp>();
    if (parentFunc)
        rewriter.setInsertionPointToStart(&parentFunc.getBody().front());
    auto sizeConst = rewriter.create<LLVM::ConstantOp>(...);
    argsArray = rewriter.create<LLVM::AllocaOp>(...);
}
```

Applied to 4 sites in `EcoToLLVMClosures.cpp`:
1. `emitRootedBoxedArgsArray` (line ~106)
2. `emitInlineClosureCall` (line ~966)
3. `lowerSegmentationUnknown` (line ~1140)
4. PapExtendOp partial-app path (line ~1335)

### Verification

LLVM IR AFTER fix:
```llvm
define i64 @"MinGcTest_loop_$_1"(...) {
  %1 = alloca i64, i64 1, align 8    ; <--- HOISTED TO ENTRY BLOCK
  br label %4

4:                                     ; loop header
  ...
14:                                    ; loop body
  call void @llvm.memset.p0.i64(ptr %1, ...)  ; reuses entry-block alloca
  ...
```

Result: MinGcTest with 1M iterations, 16 GC cycles → PASSED.

### stacksave/stackrestore DOES NOT WORK

Initially attempted `llvm.stacksave`/`llvm.stackrestore` around the alloca-to-restore region. This CAUSED a new crash:

```
#4 Elm::Allocator::resolve(Elm::HPointer)
#5 Elm::ThreadLocalHeap::collectStackRootsFromStackMap()
#6 Elm::ThreadLocalHeap::minorGC()
```

Reason: `stackrestore` deallocates the alloca'd memory, but RS4GC may have spilled gc-live values to that same stack region. When GC fires in a subsequent iteration, the stackmap references the now-deallocated stack slot. **Entry-block hoisting is the only safe approach.**

### Impact on stress tests

The alloca hoisting fixed stack exhaustion but did NOT fix GC corruption. The 28 failing stress tests still fail with slightly different failure modes (some shifted from "wrong result" to SIGSEGV/SIGABRT).

E2E test suite: 1018/1019 passed (zero regressions from alloca hoisting).

---

## Category 2: GC Heap Corruption

### Discovery

`ListReverseStressTest.elm` reverses a 1000-element list 1000 times (even count, should get original back). `start == finished` returns `False`.

### Trace Evidence

#### Test 1: List structure intact, elements correct individually
```
start-len: 100    (List.length start)
fin-len: 100      (List.length finished)
```
Both lists have correct length.

#### Test 2: Pairwise comparison fails
```
LENGTH MISMATCH: 0
mismatches: 10000
```
Pattern match `(x :: xs, y :: ys)` fails at index 0 — one list's first cons cell appears as `[]` (Nil) to pattern matching. This proves the list STRUCTURE is corrupted, not just element values.

#### Test 3: Threshold depends on GC pressure
| Iterations | GC cycles | Result |
|---|---|---|
| 10 elements, 10 reverses | 0 | PASS |
| 1000 elements, 60 reverses | 1 | PASS |
| 1000 elements, 100 reverses | 3 | FAIL |
| 1000 elements, 1000 reverses | 30 | FAIL |

Corruption requires 2+ GC cycles.

#### Test 4: GC roots are correctly tracked
With instrumented GC (unconditional post-GC validation):
```
[gc-stackmap-diag] GC#1: records=7 totalLocs=39 indirect=18 skipped=21 pushed=18
[gc-stackmap-diag] GC#2: records=7 totalLocs=41 indirect=20 skipped=21 pushed=20
```
- All stackmap roots correctly discovered (18-20 indirect locations)
- Zero roots point to from-space after GC (validated unconditionally)
- The 21 "skipped" locations are kind=4 (Constant), correctly ignored

#### Test 5: ECO_GC_DEBUG=ON reveals corruption
```
Assertion `hdr->tag < Tag_Forward && "Invalid tag after forward resolution"' failed.
Stack: Allocator::resolve → ThreadLocalHeap::collectStackRootsFromStackMap → minorGC
```
A forwarding chain leads to an object with invalid tag, confirming heap data corruption.

### LLVM IR Analysis (List_foldl)

The critical function `List_foldl_$_10` (which `List.reverse` calls internally):

```llvm
; Load cons tail from heap (gc-leaf, no GC during load)
%16 = call ptr @eco_resolve_hptr(ptr addrspace(1) %6)
%17 = getelementptr i8, ptr %16, i64 16        ; tail field at offset 16
%18 = load i64, ptr %17                         ; load tail as raw i64
%19 = inttoptr i64 %18 to ptr addrspace(1)      ; convert to ptr<1>

; Box the head element (GC CAN fire here)
%statepoint = call ... @eco_alloc_int(i64 %15)
  [ "gc-live"(ptr addrspace(1) %19, ptr addrspace(1) %.0, ...) ]
; %19 (tail) IS in gc-live — RS4GC will track it

; Store into args array, call eco_apply_closure
%22 = ptrtoint ptr addrspace(1) %20 to i64      ; boxed head → i64
store i64 %22, ptr %19                           ; args[0]
%29 = ptrtoint ptr addrspace(1) %26 to i64      ; acc → i64
store i64 %29, ptr %28                           ; args[1]
%statepoint2 = call ... @eco_apply_closure(...)
  [ "gc-live"(ptr addrspace(1) %24, ptr addrspace(1) %25) ]
```

All gc-live bundles look correct. The tail pointer `%19` is tracked across the first statepoint. The accumulator is tracked across the second.

### What was ruled out

1. Stackmap root discovery: correct (18-20 indirect roots found per cycle)
2. Stack root range evacuation: all correctly relocated post-GC
3. EcoPtrIntVerify: zero violations
4. gc-leaf marking of Elm_Kernel_Utils_equal: no effect (bug is in data, not comparison)
5. Hybrid DFS list copying: disabling doesn't help
6. alloca-in-loop: separate bug (now fixed)

### Remaining hypothesis

The corruption may be in the C++ runtime's `eco_apply_closure` / `eco_closure_call_saturated` functions, which double-root the args array (once from compiled code via `eco_gc_push_stack_range`, once from the C++ runtime function itself). While both rootings individually produce correct results, the interaction of two simultaneous evacuations of the same memory location across different GC phases may produce subtle corruption.

Alternatively, the bug may be in how RS4GC handles `inttoptr i64 → ptr<1>` from a heap load (line `%19 = inttoptr i64 %18 to ptr addrspace(1)`). Although `%19` is in the gc-live bundle, RS4GC may not correctly identify the base pointer for relocation when the value was loaded from heap memory rather than being an SSA-defined allocation result.

### Status

OPEN — requires further investigation with byte-level heap dump comparison before and after GC to identify exactly which heap object field is corrupted and when.
