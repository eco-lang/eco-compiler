# CallGenericApply — Current State & Enablement Analysis

## Summary

The generic apply infrastructure is fully implemented across all layers (runtime,
dialect, EcoToLLVM, GlobalOpt, MLIR codegen) but is **never activated**.
`CallGenericApply` is never assigned because `computeCallInfo` conservatively
uses `CallDirectKnownSegmentation` for all StageCurried calls. This document
analyzes why, what's missing, and how to enable it.

---

## 1. AbiCloning is a complete no-op

`AbiCloning.abiCloningPass` (`compiler/src/Compiler/GlobalOpt/AbiCloning.elm:37-40`)
is completely stubbed — it returns the graph unchanged:

```elm
abiCloningPass : Mono.MonoGraph -> Mono.MonoGraph
abiCloningPass graph =
    graph
```

It has some collection helpers (`computeCaptureAbi`, `collectFromExpr`,
`recordCallAbis`) but no analysis or transformation logic. The "ANALYSIS PHASE"
section at line 210 is empty.

---

## 2. closureKind and captureAbi are always Nothing

Every `CallInfo` and `ClosureInfo` record in the entire codebase sets:

- `closureKind = Nothing`
- `captureAbi = Nothing`

Files that construct these records (all with `Nothing`):

| File | Lines |
|------|-------|
| `Monomorphize/Specialize.elm` | 622 |
| `MonoDirect/Specialize.elm` | 1067, 1634, 1686, 1756 |
| `GlobalOpt/MonoGlobalOptimize.elm` | 441, 497, 539, 675, 1785, 1862 |
| `GlobalOpt/MonoInlineSimplify.elm` | 1475 |
| `GlobalOpt/Staging/Rewriter.elm` | 593, 660 |
| `AST/Monomorphized.elm` (defaultCallInfo) | 1076 |

---

## 3. MLIR attributes are never emitted

Because `closureKind` is always `Nothing`:

- **`eco.papCreate`** never gets `_closure_kind` attribute. The codegen at
  `Expr.elm:1022-1029` checks for `Just (Known _)` but always sees `Nothing`.

- **`eco.papExtend`** never gets `_dispatch_mode`, `_closure_kind`, or
  `_fast_evaluator` attributes. The `applyByStages` function (`Expr.elm:1421-1426`)
  builds attrs with only `_operand_types`, `remaining_arity`, and
  `newargs_unboxed_bitmap`.

---

## 4. C++ backend dispatch is always legacy

In `EcoToLLVMClosures.cpp:932-948`, when a typed-mode saturated papExtend is lowered:

```cpp
auto fastEval = op->getAttrOfType<SymbolRefAttr>("_fast_evaluator");
auto captureAbi = op->getAttrOfType<ArrayAttr>("_capture_abi");
auto closureKind = op->getAttr("_closure_kind");

if (fastEval && captureAbi) {
    result = emitFastClosureCall(...);      // Never reached
} else if (closureKind) {
    result = emitClosureCall(...);          // Never reached
} else {
    result = emitInlineClosureCall(...);    // ALWAYS takes this path
}
```

Every saturated papExtend goes through `emitInlineClosureCall` — the legacy
args-array boxing path. The fast clone (`$cap`) and generic clone (`$clo`)
dispatch paths in EcoToLLVM are dead code.

---

## 5. Why the initial CallGenericApply attempt failed

The first attempt set `callKind = CallGenericApply` when
`closureBodyStageArities == Nothing` (i.e., the callee's body isn't directly
traceable — function parameters, local variables, etc.).

This caused 48 test crashes with:
```
eco_closure_call_saturated: argument count mismatch
(n_values + num_newargs != max_values)
```

### Root cause: multi-stage calls

The crashes happen for multi-stage callees. Consider `List.map`:

- `List.map` has staging `[1, 1]` — stage 1 takes the function arg, stage 2
  takes the list arg.
- When called as `List.map f xs`, the typed path (`applyByStages`) correctly
  sends 1 arg per stage via two papExtend ops, each with the right
  `remaining_arity`.
- When switched to `generateGenericApply`, ALL args are sent in a single
  papExtend. The runtime's `eco_apply_closure` then gets a closure with
  `max_values=1` (stage 1 arity) but `num_args=2` (both args at once).
  `eco_apply_closure` handles this as over-saturated: it passes 1 arg to
  saturate stage 1, gets back the stage-2 closure, then applies the remaining
  arg. **This should work.**

### The actual issue: arg encoding

The crash comes from `eco_closure_call_saturated`'s assertion, not from
`eco_apply_closure`'s over-saturated path. This means the chaining logic in
`eco_apply_closure` is calling `eco_closure_call_saturated` with wrong arg
counts.

Looking at the over-saturated path:
```cpp
uint64_t intermediate = eco_closure_call_saturated(closure_hptr, args, remaining);
return eco_apply_closure(intermediate, args + remaining, num_args - remaining);
```

The `args` pointer is the raw `uint64_t*` array from the MLIR-generated stack
alloca. The pointer arithmetic `args + remaining` advances by `remaining`
elements. This should be correct.

**However**, the intermediate result from `eco_closure_call_saturated` might not
be a valid closure. If stage 1's evaluator returns a raw value (not an HPointer
to a closure), then `eco_apply_closure` will try to dereference it as a Closure
struct, causing the assertion failure.

**Key insight**: The MLIR-generated papExtend in generic mode boxes all args to
`!eco.value` via `boxArgsForClosureBoundary True`. After LLVM type conversion,
these become `i64` values. But there's a subtlety: the evaluator wrapper
(`getOrCreateWrapper`) expects args in `void**` format where captured values may
need boxing via `eco_alloc_int`, while new args are "already HPointer-encoded".
When generic apply sends ALL args as new args (not captured), they flow through
correctly. But the evaluator returns its result as an HPointer (`uint64_t`), and
that HPointer IS the next-stage closure — so `eco_apply_closure` should be able
to chain.

**The actual bug is likely not in the runtime chaining but in how args get
encoded.** Need to trace through a specific failing test to identify the exact
mismatch.

---

## 6. Two paths to enabling CallGenericApply

### Path A: Enable for function parameters without ABI cloning

The simplest approach: use generic apply only for calls where the callee is a
**function parameter** (not a local variable bound to a known closure or a
global). These are the cases where staging is truly unknown.

**Signal**: The staging solver's `dynamicSlots` already identifies slots with no
producer segmentation information. Function parameters that appear as slots
without any producer in their equivalence class should be in `dynamicSlots`.

**Steps:**

1. **Verify `dynamicSlots` correctness.** Check whether function parameters
   actually end up in `dynamicSlots` by adding debug logging to the solver. The
   current `identifyDynamicSlots` marks slots in classes with no producer
   segmentation — this should include function parameters that are never
   directly assigned a closure value.

2. **Thread `dynamicSlots` into `computeCallInfo`.** Already done — `CallEnv`
   carries `dynamicSlots`. But the lookup key needs to match. Currently
   `dynamicSlots` uses `slotIdToKey` strings from the staging graph; we need to
   match callee expressions to their slot keys.

3. **Debug one failing test.** Pick a simple higher-order test like
   `AnonymousFunctionTest.elm`. Compile it with generic apply enabled. Dump the
   MLIR. Trace through the EcoToLLVM lowering and runtime execution to find the
   exact point of failure.

4. **Fix the arg encoding issue.** The most likely fix is ensuring that
   `lowerGenericApply` in EcoToLLVMClosures.cpp correctly encodes args as the
   runtime expects. Specifically:
   - All args must be `uint64_t` values that are either HPointers (for boxed
     values) or raw i64 bits (for already-boxed primitives).
   - The `eco_apply_closure` path passes `unboxed_bitmap=0` when extending,
     meaning all values are treated as HPointers by the GC. This is correct
     only if all args ARE valid HPointers.

5. **Add targeted E2E tests** that exercise function parameters as callees:
   ```elm
   -- Simple: apply a function parameter
   apply f x = f x

   -- Multi-stage: pass closure through HOF
   applyTwo f x y = f x y
   ```

### Path B: Full closure kind analysis + ABI cloning

This is the complete typed closure calling design from
`typed_closure_calling_theory.md`. Required for fast dispatch via `$cap` clones.

**Steps:**

1. **Implement ABI cloning** (`AbiCloning.elm`):
   - Assign each closure a `ClosureKindId` based on its `LambdaId` + capture ABI
   - Walk all call sites; for each closure-typed parameter, collect which
     `ClosureKindId` values flow into it
   - If all callers agree on one kind: mark parameter as `Known id`
   - If callers disagree: mark as `Heterogeneous`
   - Clone functions when a parameter receives multiple distinct capture ABIs

2. **Propagate closure kinds** through the AST:
   - Set `closureKind` on `ClosureInfo` during ABI cloning
   - Propagate through let-bindings, case branches, if-else (with lattice merge:
     `Known a + Known a = Known a`, `Known a + Known b = Heterogeneous`,
     `anything + Nothing = Nothing`)

3. **Populate CallInfo closure fields** in `annotateCallStaging`:
   - Look up the callee's closure kind from the propagated analysis
   - Set `closureKind` and `captureAbi` on CallInfo

4. **Emit MLIR attributes** in `Expr.elm`:
   - On papCreate: `_closure_kind` (integer ID) — already coded, just needs
     non-Nothing input
   - On papCreate: `_fast_evaluator` — already coded for closures with captures
   - On papExtend: `_dispatch_mode` ("fast" / "closure" / "unknown")
   - On papExtend: `_closure_kind` (propagated from source closure)
   - On papExtend: `_fast_evaluator` (for fast dispatch)
   - On papExtend: `_capture_abi` (array of capture types for fast clone)

5. **Drive `callKind` from closure kind**:
   - `Known id` with `captureAbi` → `CallDirectKnownSegmentation` (fast path)
   - `Heterogeneous` → `CallGenericApply`
   - `Nothing` (unknown) → `CallGenericApply` (conservative)

6. **C++ backend**: The `emitFastClosureCall`, `emitClosureCall`, and
   `emitDispatchedClosureCall` code paths in EcoToLLVMClosures.cpp are already
   implemented and waiting for these attributes.

---

## 7. Recommended approach

**Start with Path A** — enable generic apply for a narrow set of calls where the
callee is genuinely unknown. This validates the runtime infrastructure
(`eco_apply_closure` chaining, arg encoding, GC safety) with real programs
before building the full closure kind analysis.

**Concrete next step:** Pick one simple failing test (e.g., a test that passes a
lambda to a HOF), enable `CallGenericApply` for just that call pattern, trace
through the failure, and fix whatever arg encoding or dispatch issue surfaces.
Once one test works end-to-end through the generic apply path, the remaining
work is systematic.

Path B (full ABI cloning + closure kind propagation) is the long-term goal and
enables the performance win of fast clone dispatch, but it's a larger body of
work that can proceed incrementally on top of a working generic apply foundation.

---

## 8. File inventory

### Infrastructure already implemented (this PR)

| Layer | File | What |
|-------|------|------|
| Runtime | `RuntimeExports.cpp:537` | `eco_apply_closure` over-saturated chaining |
| Runtime | `RuntimeExports.h:157` | Updated doc comments |
| Runtime | `Heap.hpp:215` | Closure struct doc comments |
| Dialect | `Ops.td:894` | `remaining_arity` now optional on papExtend |
| Dialect | `EcoOps.cpp:373` | Two-mode verifier (typed/generic) |
| EcoToLLVM | `EcoToLLVMClosures.cpp:827` | `lowerGenericApply` method |
| EcoToLLVM | `EcoToLLVMRuntime.cpp:210` | `getOrCreateApplyClosure` helper |
| EcoToLLVM | `EcoPAPSimplify.cpp:59,140` | Skip generic-mode ops |
| GlobalOpt | `Monomorphized.elm:1028` | `CallKind` type + field on CallInfo |
| GlobalOpt | `Staging/Types.elm:176` | `dynamicSlots` on StagingSolution |
| GlobalOpt | `Staging/Solver.elm:36` | `identifyDynamicSlots` |
| GlobalOpt | `MonoGlobalOptimize.elm:99` | Threads dynamicSlots through pipeline |
| Codegen | `Expr.elm:1220` | `generateGenericApply` function |
| Codegen | `Expr.elm:1193` | `generateCall` dispatches on `callKind` |
| Invariants | `invariants.csv` | CGEN_058, CGEN_059, RUNTIME_CLOSURE_004, GOPT_016 |

### Not yet implemented (needed to activate)

| Layer | File | What |
|-------|------|------|
| GlobalOpt | `AbiCloning.elm` | Closure kind analysis (stubbed) |
| GlobalOpt | `MonoGlobalOptimize.elm` | `callKind` logic (conservative) |
| Codegen | `Expr.elm` | papExtend `_dispatch_mode` / `_closure_kind` / `_capture_abi` attrs |
| Codegen | `Expr.elm` | papCreate `_closure_kind` population (coded but always gets Nothing) |
