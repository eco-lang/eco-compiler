# LLVM and MLIR Optimization Ideas for Ecoc

This document describes optimization passes that can be added to the ecoc lowering pipeline to improve generated code performance. Each optimization is explained with its mechanism and expected benefits for Elm/functional code patterns.

## Table of Contents

1. [Current Pipeline Overview](#current-pipeline-overview)
2. [LLVM Optimizations](#llvm-optimizations)
3. [MLIR Standard Optimizations](#mlir-standard-optimizations)
4. [SCF Dialect Optimizations](#scf-dialect-optimizations)
5. [Custom Eco Dialect Optimizations](#custom-eco-dialect-optimizations)
6. [Implementation Priority](#implementation-priority)

---

## Current Pipeline Overview

The ecoc compiler currently implements this pipeline:

```
Monomorphized Elm IR
        │
        ▼
┌───────────────────────────────────────┐
│  Stage 1: Eco → Eco Transforms        │
│  - RCElimination (implemented)        │
│  - ConstructLowering (TODO)           │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  Stage 2: Eco → Standard MLIR         │
│  - Canonicalizer                      │
│  - ControlFlowLowering (TODO)         │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  Stage 3: Eco → LLVM Dialect          │
│  - EcoToLLVM                          │
│  - FuncToLLVM, CFToLLVM, ArithToLLVM  │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│  Stage 4: LLVM IR → Native            │
│  - makeOptimizingTransformer(O3)      │
└───────────────────────────────────────┘
        │
        ▼
    Native Code
```

---

## LLVM Optimizations

These optimizations operate on LLVM IR after the MLIR-to-LLVM translation.

### 1. Tail Call Elimination (TCE)

**What it does:**
Tail Call Elimination transforms recursive function calls in tail position into jumps, converting recursion into iteration. A call is in "tail position" when it's the last operation before returning.

**How it speeds up Elm code:**
Elm relies heavily on recursion for iteration. Functions like `List.map`, `List.foldl`, and user-defined recursive functions all use tail recursion. Without TCE:

```elm
-- Elm source
sum : List Int -> Int -> Int
sum list acc =
    case list of
        [] -> acc
        x :: xs -> sum xs (acc + x)
```

```llvm
; Without TCE - stack grows with each call
define i64 @sum(ptr %list, i64 %acc) {
  ; ... pattern match ...
  %result = call i64 @sum(ptr %xs, i64 %new_acc)  ; Stack frame allocated
  ret i64 %result
}

; With TCE - constant stack space
define i64 @sum(ptr %list, i64 %acc) {
entry:
  br label %tailrecurse
tailrecurse:
  %list.tr = phi ptr [ %list, %entry ], [ %xs, %recurse ]
  %acc.tr = phi i64 [ %acc, %entry ], [ %new_acc, %recurse ]
  ; ... pattern match ...
recurse:
  br label %tailrecurse  ; Jump instead of call
}
```

**Performance impact:**
- Eliminates stack frame allocation/deallocation per recursive call
- Prevents stack overflow on deep recursion
- Enables further loop optimizations (vectorization, unrolling)
- **Expected speedup: 2-10x for recursive functions**

**Implementation:**
```cpp
// The eco.call op already supports musttail attribute
pm.addPass(createTailCallEliminationPass());
```

---

### 2. Aggressive Dead Code Elimination (ADCE)

**What it does:**
ADCE removes instructions whose results are never used, working backwards from program outputs. Unlike simple DCE, it can eliminate entire control flow paths that don't contribute to outputs.

**How it speeds up Elm code:**
Elm's pattern matching generates many intermediate values. After inlining and specialization, some branches become unreachable:

```elm
-- After monomorphization, we might know x is always Just
case x of
    Nothing -> defaultValue
    Just v -> processValue v
```

```llvm
; Before ADCE
define i64 @process(ptr %x) {
  %tag = call i64 @eco_get_tag(ptr %x)
  %is_nothing = icmp eq i64 %tag, 0
  br i1 %is_nothing, label %nothing, label %just

nothing:                          ; Dead if x is always Just
  %default = call i64 @getDefault()
  br label %merge

just:
  %v = call ptr @eco_project(ptr %x, i64 0)
  %result = call i64 @processValue(ptr %v)
  br label %merge

merge:
  %phi = phi i64 [ %default, %nothing ], [ %result, %just ]
  ret i64 %phi
}

; After ADCE (if analysis proves x is always Just)
define i64 @process(ptr %x) {
  %v = call ptr @eco_project(ptr %x, i64 0)
  %result = call i64 @processValue(ptr %v)
  ret i64 %result
}
```

**Performance impact:**
- Reduces code size
- Eliminates unnecessary branches
- Removes dead allocations
- **Expected speedup: 5-20% code size reduction, variable runtime improvement**

**Implementation:**
```cpp
pm.addPass(createAggressiveDCEPass());
```

---

### 3. Global Value Numbering (GVN)

**What it does:**
GVN identifies computations that produce the same value and eliminates redundant calculations. It builds a value numbering that assigns the same number to expressions that compute identical results.

**How it speeds up Elm code:**
Pattern matching expansion often generates redundant field accesses:

```elm
case point of
    Point x y ->
        if x > 0 then
            x + y  -- x accessed again
        else
            x - y  -- x accessed again
```

```llvm
; Before GVN
define i64 @process(ptr %point) {
  %x1 = call i64 @eco_project(ptr %point, i64 0)  ; First access
  %cmp = icmp sgt i64 %x1, 0
  br i1 %cmp, label %then, label %else

then:
  %x2 = call i64 @eco_project(ptr %point, i64 0)  ; Redundant!
  %y1 = call i64 @eco_project(ptr %point, i64 1)
  %sum = add i64 %x2, %y1
  br label %merge

else:
  %x3 = call i64 @eco_project(ptr %point, i64 0)  ; Redundant!
  %y2 = call i64 @eco_project(ptr %point, i64 1)  ; Also redundant!
  %diff = sub i64 %x3, %y2
  br label %merge

merge:
  ; ...
}

; After GVN
define i64 @process(ptr %point) {
  %x = call i64 @eco_project(ptr %point, i64 0)   ; Single access
  %y = call i64 @eco_project(ptr %point, i64 1)   ; Single access
  %cmp = icmp sgt i64 %x, 0
  br i1 %cmp, label %then, label %else

then:
  %sum = add i64 %x, %y   ; Reuses %x, %y
  br label %merge

else:
  %diff = sub i64 %x, %y  ; Reuses %x, %y
  br label %merge

merge:
  ; ...
}
```

**Performance impact:**
- Eliminates redundant memory loads
- Reduces instruction count
- Improves cache utilization
- **Expected speedup: 10-30% for pattern-heavy code**

**Implementation:**
```cpp
pm.addPass(createGVNPass());
```

---

### 4. Scalar Replacement of Aggregates (SROA)

**What it does:**
SROA breaks up aggregate allocations (structs, arrays) into individual scalar values when possible. This enables the values to live in registers instead of memory.

**How it speeds up Elm code:**
Elm tuples and small records can often be completely scalarized:

```elm
-- Small tuple that could live in registers
swap : (Int, Int) -> (Int, Int)
swap (a, b) = (b, a)
```

```llvm
; Before SROA - tuple allocated on stack/heap
define ptr @swap(ptr %tuple) {
  %a = call i64 @eco_project(ptr %tuple, i64 0)
  %b = call i64 @eco_project(ptr %tuple, i64 1)
  %new_tuple = call ptr @eco_alloc_tuple2()
  call void @eco_store_field(ptr %new_tuple, i64 0, i64 %b)
  call void @eco_store_field(ptr %new_tuple, i64 1, i64 %a)
  ret ptr %new_tuple
}

; After SROA + inlining (conceptually)
; The tuple is replaced by two i64 values passed in registers
define {i64, i64} @swap(i64 %a, i64 %b) {
  %result = insertvalue {i64, i64} undef, i64 %b, 0
  %result2 = insertvalue {i64, i64} %result, i64 %a, 1
  ret {i64, i64} %result2
}
```

**Performance impact:**
- Eliminates heap allocations for small aggregates
- Values live in registers instead of memory
- Enables further optimizations (constant propagation, etc.)
- **Expected speedup: 2-5x for tuple/record-heavy code**

**Implementation:**
```cpp
pm.addPass(createSROAPass());
```

---

### 5. Loop Invariant Code Motion (LICM)

**What it does:**
LICM moves computations that produce the same result on every loop iteration outside the loop. It "hoists" invariant code to the loop preheader.

**How it speeds up Elm code:**
After tail recursion is converted to loops, many computations may be loop-invariant:

```elm
-- The length computation is invariant
processAll : List Int -> Int -> List Int
processAll items multiplier =
    List.map (\x -> x * multiplier) items
```

```llvm
; Before LICM
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %item = ; ... get items[i] ...
  %mult = load i64, ptr %multiplier_ptr  ; Invariant - loaded every iteration!
  %result = mul i64 %item, %mult
  ; ... store result ...
  %i.next = add i64 %i, 1
  %done = icmp eq i64 %i.next, %len
  br i1 %done, label %exit, label %loop

; After LICM
entry:
  %mult = load i64, ptr %multiplier_ptr  ; Hoisted out of loop
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %item = ; ... get items[i] ...
  %result = mul i64 %item, %mult          ; Uses hoisted value
  ; ... store result ...
  %i.next = add i64 %i, 1
  %done = icmp eq i64 %i.next, %len
  br i1 %done, label %exit, label %loop
```

**Performance impact:**
- Reduces redundant computations
- Decreases loop body size (better instruction cache)
- Enables further loop optimizations
- **Expected speedup: 10-50% for loops with invariant computations**

**Implementation:**
```cpp
pm.addPass(createLICMPass());
```

---

### 6. Loop Unrolling

**What it does:**
Loop unrolling replicates the loop body multiple times, reducing the number of iterations and branch instructions. It can be full (completely unroll) or partial (unroll by a factor).

**How it speeds up Elm code:**
Small, fixed-size list operations benefit greatly:

```elm
-- Processing a 3-element tuple
processTuple3 : (Int, Int, Int) -> Int
processTuple3 (a, b, c) = a + b + c
```

```llvm
; Before unrolling (if compiled as a loop)
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %acc = phi i64 [ 0, %entry ], [ %acc.next, %loop ]
  %elem = call i64 @eco_project(ptr %tuple, i64 %i)
  %acc.next = add i64 %acc, %elem
  %i.next = add i64 %i, 1
  %done = icmp eq i64 %i.next, 3
  br i1 %done, label %exit, label %loop

; After full unrolling
entry:
  %a = call i64 @eco_project(ptr %tuple, i64 0)
  %b = call i64 @eco_project(ptr %tuple, i64 1)
  %c = call i64 @eco_project(ptr %tuple, i64 2)
  %sum1 = add i64 %a, %b
  %sum2 = add i64 %sum1, %c
  ret i64 %sum2
```

**Performance impact:**
- Eliminates loop overhead (counter increment, branch)
- Enables instruction-level parallelism
- Better instruction scheduling
- **Expected speedup: 20-100% for small, hot loops**

**Implementation:**
```cpp
pm.addPass(createLoopUnrollPass());
```

---

### 7. Loop Vectorization

**What it does:**
Loop vectorization transforms scalar operations into SIMD (Single Instruction, Multiple Data) operations, processing multiple elements per instruction using vector registers (SSE, AVX, NEON).

**How it speeds up Elm code:**
List operations on numeric data can be vectorized:

```elm
-- Can process 4 floats at once with AVX
doubleAll : List Float -> List Float
doubleAll = List.map (\x -> x * 2.0)
```

```llvm
; Before vectorization
loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %x = load double, ptr %src_i
  %doubled = fmul double %x, 2.0
  store double %doubled, ptr %dst_i
  ; ... increment and branch ...

; After vectorization (AVX - 4 doubles at once)
vector_loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %vector_loop ]
  %vec = load <4 x double>, ptr %src_i        ; Load 4 doubles
  %doubled = fmul <4 x double> %vec, <2.0, 2.0, 2.0, 2.0>  ; Multiply all 4
  store <4 x double> %doubled, ptr %dst_i      ; Store 4 doubles
  %i.next = add i64 %i, 4                      ; Increment by 4
  ; ...
```

**Performance impact:**
- Process 2-8x more elements per instruction (depending on data type and CPU)
- Better memory bandwidth utilization
- **Expected speedup: 2-8x for numeric list operations**

**Implementation:**
```cpp
pm.addPass(createLoopVectorizePass());
```

---

### 8. Function Inlining

**What it does:**
Inlining replaces function calls with the function body, eliminating call overhead and enabling cross-function optimizations.

**How it speeds up Elm code:**
Elm code has many small functions due to functional style:

```elm
-- Many small functions
add1 : Int -> Int
add1 x = x + 1

double : Int -> Int
double x = x * 2

-- Composed
transform : Int -> Int
transform x = double (add1 x)
```

```llvm
; Before inlining
define i64 @transform(i64 %x) {
  %temp = call i64 @add1(i64 %x)    ; Call overhead
  %result = call i64 @double(i64 %temp)  ; Call overhead
  ret i64 %result
}

; After inlining
define i64 @transform(i64 %x) {
  %temp = add i64 %x, 1             ; Inlined add1
  %result = mul i64 %temp, 2        ; Inlined double
  ret i64 %result
}

; After further optimization
define i64 @transform(i64 %x) {
  %temp = add i64 %x, 1
  %result = shl i64 %temp, 1        ; Strength reduction: x*2 -> x<<1
  ret i64 %result
}
```

**Performance impact:**
- Eliminates function call overhead (save/restore registers, stack manipulation)
- Enables cross-function optimizations
- Improves instruction cache locality for small functions
- **Expected speedup: 10-100% for heavily composed code**

**Implementation:**
```cpp
pm.addPass(createFunctionInliningPass());
// For always-inline functions (constructors, accessors):
pm.addPass(createAlwaysInlinerLegacyPass());
```

---

### 9. Memory Copy Optimization (MemCpyOpt)

**What it does:**
MemCpyOpt transforms sequences of memory operations into optimized memcpy/memset calls, and eliminates redundant copies.

**How it speeds up Elm code:**
Record updates create copies that can be optimized:

```elm
-- Record update creates a copy
updateName : Person -> String -> Person
updateName person newName =
    { person | name = newName }
```

```llvm
; Before MemCpyOpt - field-by-field copy
define ptr @updateName(ptr %person, ptr %newName) {
  %new = call ptr @eco_alloc_record(i64 3)
  %f0 = call ptr @eco_project(ptr %person, i64 0)
  call void @eco_store_field(ptr %new, i64 0, ptr %f0)
  %f1 = call ptr @eco_project(ptr %person, i64 1)
  call void @eco_store_field(ptr %new, i64 1, ptr %f1)
  call void @eco_store_field(ptr %new, i64 2, ptr %newName)  ; Changed field
  ret ptr %new
}

; After MemCpyOpt - bulk copy + single update
define ptr @updateName(ptr %person, ptr %newName) {
  %new = call ptr @eco_alloc_record(i64 3)
  call void @llvm.memcpy(ptr %new, ptr %person, i64 24, i1 false)  ; Bulk copy
  call void @eco_store_field(ptr %new, i64 2, ptr %newName)  ; Overwrite changed field
  ret ptr %new
}
```

**Performance impact:**
- Bulk memory operations are highly optimized by hardware
- Reduces instruction count
- Better cache line utilization
- **Expected speedup: 20-50% for record-heavy code**

**Implementation:**
```cpp
pm.addPass(createMemCpyOptPass());
```

---

### 10. Dead Store Elimination (DSE)

**What it does:**
DSE removes store instructions whose stored values are never read or are overwritten before being read.

**How it speeds up Elm code:**
Constructor field initialization may have redundant stores:

```elm
-- Some fields might be immediately overwritten
makeDefault : () -> Config
makeDefault () =
    { setting1 = defaultSetting1
    , setting2 = defaultSetting2
    }
```

```llvm
; Before DSE
define ptr @makeConfig(i64 %custom) {
  %config = call ptr @eco_alloc_record(i64 2)
  ; Default initialization (might be generated by lowering)
  call void @eco_store_field(ptr %config, i64 0, i64 0)  ; Dead store
  call void @eco_store_field(ptr %config, i64 1, i64 0)  ; Dead store
  ; Actual initialization
  call void @eco_store_field(ptr %config, i64 0, i64 %custom)  ; Overwrites
  call void @eco_store_field(ptr %config, i64 1, i64 42)       ; Overwrites
  ret ptr %config
}

; After DSE
define ptr @makeConfig(i64 %custom) {
  %config = call ptr @eco_alloc_record(i64 2)
  call void @eco_store_field(ptr %config, i64 0, i64 %custom)
  call void @eco_store_field(ptr %config, i64 1, i64 42)
  ret ptr %config
}
```

**Performance impact:**
- Eliminates unnecessary memory writes
- Reduces memory bandwidth usage
- Fewer instructions in hot paths
- **Expected speedup: 5-15% for allocation-heavy code**

**Implementation:**
```cpp
pm.addPass(createDeadStoreEliminationPass());
```

---

## MLIR Standard Optimizations

These optimizations operate at the MLIR level, before lowering to LLVM.

### 11. Common Subexpression Elimination (CSE)

**What it does:**
CSE identifies identical computations within a function and eliminates redundant ones, keeping only the first occurrence and reusing its result.

**How it speeds up Elm code:**
Pattern matching often generates duplicate projections:

```elm
case record of
    { x, y } ->
        if x > y then x else y
```

```mlir
// Before CSE
func.func @maxField(%record: !eco.value) -> i64 {
  %x1 = eco.project %record[0] : !eco.value -> i64
  %y1 = eco.project %record[1] : !eco.value -> i64
  %cmp = arith.cmpi sgt, %x1, %y1 : i64
  cf.cond_br %cmp, ^then, ^else
^then:
  %x2 = eco.project %record[0] : !eco.value -> i64  // Duplicate!
  return %x2 : i64
^else:
  %y2 = eco.project %record[1] : !eco.value -> i64  // Duplicate!
  return %y2 : i64
}

// After CSE
func.func @maxField(%record: !eco.value) -> i64 {
  %x = eco.project %record[0] : !eco.value -> i64
  %y = eco.project %record[1] : !eco.value -> i64
  %cmp = arith.cmpi sgt, %x, %y : i64
  cf.cond_br %cmp, ^then, ^else
^then:
  return %x : i64  // Reuses %x
^else:
  return %y : i64  // Reuses %y
}
```

**Performance impact:**
- Eliminates redundant operations before LLVM lowering
- Reduces MLIR size, speeding up subsequent passes
- **Expected speedup: 10-20% compilation time, 5-15% runtime**

**Implementation:**
```cpp
pm.addNestedPass<func::FuncOp>(createCSEPass());
```

---

### 12. Canonicalization

**What it does:**
Canonicalization applies algebraic simplifications and normalizes operations to canonical forms, enabling pattern matching in subsequent optimization passes.

**How it speeds up Elm code:**
Simplifies arithmetic and normalizes control flow:

```mlir
// Before canonicalization
%c0 = arith.constant 0 : i64
%sum = arith.addi %x, %c0 : i64        // x + 0
%neg = arith.muli %y, -1 : i64         // y * -1
%double = arith.addi %z, %z : i64      // z + z

// After canonicalization
// %sum removed, uses of %sum replaced with %x
%neg = arith.negi %y : i64             // Canonical negation
%double = arith.shli %z, 1 : i64       // z << 1 (strength reduction)
```

**Performance impact:**
- Simplifies expressions, reducing operation count
- Enables other optimizations to match patterns
- Strength reduction (multiply → shift, etc.)
- **Expected speedup: 5-10% across the board**

**Implementation:**
```cpp
pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());
```

---

### 13. MLIR Inliner

**What it does:**
The MLIR inliner performs function inlining at the MLIR level, before lowering to LLVM. This enables MLIR-level optimizations across function boundaries.

**How it speeds up Elm code:**
Enables eco-specific optimizations across function boundaries:

```mlir
// Before inlining
func.func @add1(%x: i64) -> i64 {
  %c1 = arith.constant 1 : i64
  %result = arith.addi %x, %c1 : i64
  return %result : i64
}

func.func @caller(%v: i64) -> i64 {
  %r1 = call @add1(%v) : (i64) -> i64
  %r2 = call @add1(%r1) : (i64) -> i64
  return %r2 : i64
}

// After inlining + canonicalization
func.func @caller(%v: i64) -> i64 {
  %c2 = arith.constant 2 : i64
  %result = arith.addi %v, %c2 : i64  // add1(add1(x)) -> x + 2
  return %result : i64
}
```

**Performance impact:**
- Enables eco-level optimizations across functions
- Earlier optimization than LLVM inlining
- **Expected speedup: 15-30% for heavily composed code**

**Implementation:**
```cpp
pm.addPass(createInlinerPass());
```

---

### 14. Sparse Conditional Constant Propagation (SCCP)

**What it does:**
SCCP propagates constants through the program, including through conditional branches. It can determine that certain branches are never taken based on constant values.

**How it speeds up Elm code:**
After monomorphization, many values become known constants:

```mlir
// Before SCCP
func.func @process(%mode: i64) -> i64 {
  %c1 = arith.constant 1 : i64
  %is_fast = arith.cmpi eq, %mode, %c1 : i64
  cf.cond_br %is_fast, ^fast, ^slow
^fast:
  %r1 = arith.constant 100 : i64
  return %r1 : i64
^slow:
  %r2 = call @slowPath() : () -> i64
  return %r2 : i64
}

// If called with constant mode=1:
func.func @process() -> i64 {
  %r = arith.constant 100 : i64  // Entire function simplified
  return %r : i64
}
```

**Performance impact:**
- Eliminates dead branches
- Replaces computations with constants
- Enables further dead code elimination
- **Expected speedup: 10-30% for code with many compile-time-known values**

**Implementation:**
```cpp
pm.addPass(createSCCPPass());
```

---

### 15. Symbol Dead Code Elimination (SymbolDCE)

**What it does:**
SymbolDCE removes unused functions, globals, and other symbols from the module.

**How it speeds up Elm code:**
After inlining and specialization, many functions become unused:

```mlir
// Before SymbolDCE
func.func private @helper1() { ... }  // Used
func.func private @helper2() { ... }  // Inlined, now unused
func.func private @helper3() { ... }  // Never called

func.func @main() {
  call @helper1()
  // helper2 was inlined here
  return
}

// After SymbolDCE
func.func private @helper1() { ... }  // Kept
// helper2 and helper3 removed

func.func @main() {
  call @helper1()
  return
}
```

**Performance impact:**
- Reduces binary size
- Faster linking
- Better instruction cache behavior
- **Expected speedup: Minimal runtime, but significant code size reduction**

**Implementation:**
```cpp
pm.addPass(createSymbolDCEPass());
```

---

### 16. Control Flow Sink

**What it does:**
Control Flow Sink moves operations from dominating blocks into the blocks where they're actually used, reducing work on paths that don't need the computation.

**How it speeds up Elm code:**
Pattern matching may compute values only needed in some branches:

```mlir
// Before sinking
func.func @process(%maybe: !eco.value) -> i64 {
  %expensive = call @computeExpensive() : () -> i64  // Always computed
  %tag = eco.project %maybe[tag] : !eco.value -> i64
  %is_just = arith.cmpi eq, %tag, 1 : i64
  cf.cond_br %is_just, ^just, ^nothing
^just:
  %val = eco.project %maybe[0] : !eco.value -> i64
  %result = arith.addi %val, %expensive : i64  // Only used here
  return %result : i64
^nothing:
  %zero = arith.constant 0 : i64
  return %zero : i64
}

// After sinking
func.func @process(%maybe: !eco.value) -> i64 {
  %tag = eco.project %maybe[tag] : !eco.value -> i64
  %is_just = arith.cmpi eq, %tag, 1 : i64
  cf.cond_br %is_just, ^just, ^nothing
^just:
  %expensive = call @computeExpensive() : () -> i64  // Sunk here
  %val = eco.project %maybe[0] : !eco.value -> i64
  %result = arith.addi %val, %expensive : i64
  return %result : i64
^nothing:
  %zero = arith.constant 0 : i64
  return %zero : i64
}
```

**Performance impact:**
- Reduces work on fast paths
- Better for branch-heavy code
- **Expected speedup: 5-20% for code with expensive computations in optional branches**

**Implementation:**
```cpp
pm.addNestedPass<func::FuncOp>(createControlFlowSinkPass());
```

---

## SCF Dialect Optimizations

If `eco.case` and `eco.joinpoint` are lowered through SCF (Structured Control Flow) instead of directly to `cf`, these optimizations become available:

### 17. Loop Canonicalization

**What it does:**
Normalizes loop structures to canonical forms (e.g., loop starting at 0, stepping by 1), enabling other optimizations.

**Implementation:**
```cpp
pm.addNestedPass<func::FuncOp>(scf::createForLoopCanonicalizationPass());
```

### 18. Loop Peeling

**What it does:**
Peels iterations from the beginning or end of loops to handle boundary conditions separately, enabling vectorization of the main loop body.

**Implementation:**
```cpp
pm.addNestedPass<func::FuncOp>(scf::createForLoopPeelingPass());
```

### 19. Loop Specialization

**What it does:**
Creates specialized versions of loops for different runtime conditions (e.g., known trip counts).

**Implementation:**
```cpp
pm.addNestedPass<func::FuncOp>(scf::createForLoopSpecializationPass());
```

---

## Custom Eco Dialect Optimizations

These are new passes specific to the eco dialect that should be implemented.

### 20. Eco Constant Folding

**What it does:**
Folds eco arithmetic operations with constant operands at compile time.

**How it speeds up Elm code:**

```mlir
// Before constant folding
%a = arith.constant 10 : i64
%b = arith.constant 20 : i64
%sum = eco.int.add %a, %b : i64

// After constant folding
%sum = arith.constant 30 : i64
```

**Implementation priority:** Medium

### 21. Box/Unbox Elimination

**What it does:**
Eliminates redundant boxing followed by unboxing (or vice versa).

**How it speeds up Elm code:**

```mlir
// Before
%boxed = eco.box %int_val : i64 -> !eco.value
%unboxed = eco.unbox %boxed : !eco.value -> i64

// After
// Uses %int_val directly, both ops eliminated
```

**Performance impact:**
- Eliminates heap allocations
- Removes pointer indirection
- **Expected speedup: 50-90% for functions with excessive boxing**

**Implementation priority:** High

### 22. Construct Fusion

**What it does:**
Fuses `eco.project` followed by `eco.construct` when updating a single field, potentially enabling in-place updates.

**How it speeds up Elm code:**

```mlir
// Record update pattern
%f0 = eco.project %record[0] : !eco.value -> !eco.value
%f1 = eco.project %record[1] : !eco.value -> !eco.value
%new = eco.construct(%f0, %new_f1) {tag = 0, size = 2} : ...

// Could potentially become copy + single field update
```

**Implementation priority:** Medium

### 23. Case Simplification

**What it does:**
Simplifies `eco.case` operations when the scrutinee's constructor is known.

**How it speeds up Elm code:**

```mlir
// Before - case on known constructor
%just = eco.construct(%val) {tag = 1, size = 1} : ...
eco.case %just [0, 1] {
  // Nothing case
}, {
  // Just case - always taken
}

// After
// Just branch directly executed, case eliminated
```

**Implementation priority:** Medium

### 24. Closure Devirtualization

**What it does:**
Replaces indirect closure calls with direct calls when the closure's target function is known.

**How it speeds up Elm code:**

```mlir
// Before
%closure = eco.papCreate @add(%five) {arity = 2, num_captured = 1}
%result = eco.papExtend %closure(%ten) {remaining_arity = 1}

// After
%result = call @add(%five, %ten) : (i64, i64) -> i64
```

**Performance impact:**
- Eliminates closure allocation
- Enables direct call
- Enables inlining
- **Expected speedup: 2-5x for closure-heavy code**

**Implementation priority:** High

---

## Implementation Priority

### Phase 1: Quick Wins (Low effort, high impact)

| Pass | Location | Effort |
|------|----------|--------|
| CSE | MLIR standard | Just add to pipeline |
| Canonicalizer (aggressive) | MLIR standard | Just add to pipeline |
| SymbolDCE | MLIR standard | Just add to pipeline |
| SCCP | MLIR standard | Just add to pipeline |

### Phase 2: Eco-Specific (Medium effort, high impact)

| Pass | Location | Effort |
|------|----------|--------|
| Box/Unbox Elimination | New eco pass | ~100 LOC |
| Closure Devirtualization | New eco pass | ~200 LOC |
| Eco Constant Folding | New eco pass | ~150 LOC |

### Phase 3: Advanced (Higher effort)

| Pass | Location | Effort |
|------|----------|--------|
| Construct Fusion | New eco pass | ~300 LOC |
| Case Simplification | New eco pass | ~200 LOC |
| Escape Analysis (stack allocation) | New eco pass | ~500 LOC |

---

## Recommended Pipeline Configuration

```cpp
static int runPipeline(ModuleOp module, bool lowerToLLVM) {
    PassManager pm(module->getName());

    if (failed(applyPassManagerCLOptions(pm)))
        return 1;

    // ========== Stage 1: Eco → Eco ==========
    pm.addPass(eco::createRCEliminationPass());
    // TODO: pm.addPass(eco::createBoxUnboxEliminationPass());
    // TODO: pm.addPass(eco::createClosureDevirtualizationPass());
    // TODO: pm.addPass(eco::createEcoConstantFoldingPass());
    pm.addNestedPass<func::FuncOp>(createCSEPass());
    pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());

    if (lowerToLLVM) {
        // ========== Stage 2: High-Level Optimizations ==========
        pm.addPass(createInlinerPass());
        pm.addPass(createSCCPPass());
        pm.addNestedPass<func::FuncOp>(createCSEPass());
        pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());
        pm.addPass(createSymbolDCEPass());

        // ========== Stage 3: Eco → LLVM ==========
        pm.addPass(eco::createEcoToLLVMPass());
        pm.addPass(createConvertSCFToControlFlowPass());
        pm.addPass(createConvertFuncToLLVMPass());
        pm.addPass(createConvertControlFlowToLLVMPass());
        pm.addPass(createArithToLLVMConversionPass());

        // ========== Stage 4: LLVM Dialect Cleanup ==========
        pm.addNestedPass<LLVM::LLVMFuncOp>(createCanonicalizerPass());
    }

    if (failed(pm.run(module)))
        return 1;

    return 0;
}
```

The LLVM backend optimizations (GVN, LICM, vectorization, etc.) are already included in the `-O3` pipeline via `makeOptimizingTransformer(3, 0, nullptr)`.

---

## Expected Overall Impact

With all optimizations implemented:

| Code Pattern | Expected Speedup |
|--------------|------------------|
| Recursive functions | 2-10x (TCE) |
| Numeric list operations | 2-8x (vectorization) |
| Pattern matching | 10-30% (GVN, CSE) |
| Record operations | 20-50% (SROA, MemCpyOpt) |
| Composed functions | 10-100% (inlining) |
| Closure-heavy code | 2-5x (devirtualization) |
| **Overall typical Elm program** | **30-100%** |
