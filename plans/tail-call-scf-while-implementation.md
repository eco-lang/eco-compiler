# Tail-Call SCF While Implementation Plan

## Overview

Replace the current tail-recursion codegen strategy (joinpoints + `eco.jump`) with direct `scf.while` emission, enabling tail-recursive functions to compile to loops even when the tail call is inside complex `case`/decision-tree control flow.

**Precondition:** The compiler must use the *yield-based* `eco.case` encoding (alternatives terminate with variadic `eco.yield`, and `eco.case` is value-producing). The current `eco.return`-based case generator must be migrated first, because TailRec compilation requires building a multi-result `eco.case` to compute the next loop state.

## Current State Analysis

### Existing Infrastructure
- `Ops.elm`: Has `scfWhile`, `scfCondition` (multi-value), but `ecoYield`/`scfYield` are single-value only
- `Functions.elm`: `generateTailFunc` uses `eco.joinpoint` + `eco.jump` pattern
- Current limitation: Only handles simple if-then-else tail recursion via `generateTailRecursiveBody`
- `EcoControlFlowToSCF.cpp`: Already converts `eco.case` with `eco.yield` terminators to SCF
- `Expr.generateCase` is currently implemented in an `eco.return`-based style (dummy result value + `eco.return` inside the decision tree regions); TailRec requires the yield-based style

### The Problem Being Solved
When a tail call is inside a case branch, `generateTailCall` emits `eco.jump` which is a terminator. But `mkCaseRegionFromDecider` only recognizes `eco.yield` as valid, leading to invalid MLIR generation (empty `eco.yield()` wrapping the jump).

---

## Phase 0: Migrate `eco.case` to Yield-Based Semantics (BLOCKING)

**Repo reality note:** The current `Expr.generateCase` is still the "control-flow exit" encoding ("eco.case is a control-flow exit… exits through eco.return inside alternatives"). TailRec requires the yield-based/value-producing encoding, so Phase 0 is not optional.

TailRec requires compiling `MonoCase` as a value-producing `eco.case` where each alternative ends with `eco.yield`. The current `Expr.generateCase` uses `eco.return` inside decision tree regions and must be migrated before Phase 2/3 can work.

**Acceptance test:** After the migration:
1. `MonoCase` codegen must not emit `eco.return` internally.
2. Each alternative region must end with `eco.yieldMany` and be represented as `MlirRegion { entry = ..., blocks = OrderedDict.empty }` (i.e. only the `entry` block is used; no extra blocks in `blocks`).
3. `eco.case` must be value-producing (SSA results), and users of the case consume its SSA results directly.
4. The case generator must not use `mkCaseRegionFromDecider`/"append dummy eco.return" logic. The current implementation appends dummy returns to satisfy a terminator requirement when the decider ends in a nested `eco.case`; in the yield-based encoding this must be replaced by "every alternative yields values".

**Rewrite requirement (mkCaseRegionFromDecider semantics change):**
Replace any helper that currently "forces a terminator" by appending `eco.return` after decider ops (including dummy unreachable returns) with a helper that constructs regions whose terminator is always `eco.yieldMany` for yield-based `eco.case`.

In yield-based mode:
- Valid alternative terminator set becomes `{ "eco.yield" }` only.
- "Nested case" is an expression producing SSA values; it does **not** require additional terminators appended afterward.

**Verifier/parse invariant:** Never emit `"scf.yield"` or `"eco.yield"` with operand count ≠ length of `_operand_types`. In particular, never emit `yield` with no operands while `_operand_types` lists one type (this is the exact failure mode seen in the tailrec/joinpoint bug: "expected 0 operand types but had 1").

**Additional Phase 0 requirement (structural decision trees):**
The `Mono.Decider` lowering used by `Expr.generateCase` must be rewritten to a *structural* form that does not introduce extra MLIR blocks inside an `eco.case` alternative region. Concretely: compile the decision tree as an **expression-producing** structure using nested `eco.case` ops inside the *single entry block* of the parent alternative region; each decision node returns SSA values (the case results), and the alternative region terminates with exactly one `eco.yieldMany` that yields those SSA values. Do not emit CFG-style branches/joins (`eco.br`, joinpoints, or multi-block regions) inside `eco.case` alternatives, because SCF lowering requires single-block regions.

(You can keep the existing EcoControlFlowToSCF lowering, but TailRec must be able to *construct* yield-based `eco.case` in the first place.)

**Additional Phase 0 requirement (disable shared joinpoints for cases in this milestone):**
The current case generator emits "shared joinpoints" (`generateSharedJoinpoints`) and may produce `eco.joinpoint` + `eco.return` regions for case branches. This introduces non-structural control flow and breaks the invariant "each `eco.case` alternative region is single-block and terminates with exactly one `eco.yieldMany`".

**Therefore, for the yield-based `eco.case` migration, temporarily disable branch sharing via joinpoints in `Expr.generateCase`:**
- Do not call `generateSharedJoinpoints` in the yield-based path.
- Inline branch bodies directly into the structural decision tree as nested `eco.case` expressions.

*Rationale:* SCF regions must be single-block, and joinpoint-based sharing reintroduces CFG structure that violates the plan's structural requirement.

---

## Implementation Plan

### Phase 1: Extend Op Builders (Ops.elm)

**Step 1.1: Add `ecoYieldMany`**
```elm
ecoYieldMany : Ctx.Context -> List ( String, MlirType ) -> ( Ctx.Context, MlirOp )
```
- Takes list of (varName, type) pairs
- Handles empty list case (no operands)
- Existing `ecoYield` becomes wrapper calling `ecoYieldMany`
- The builder must set `_operand_types` to match the provided `(var, MlirType)` list exactly (including primitives like `i64/f64/i16`), not assume `!eco.value`. This matters because failures like "expected 0 operand types but had 1" depend on this attribute for verification.
- `ecoYieldMany` must always set `_operand_types` to an array of `TypeAttr`s matching operands **exactly**, including emitting an empty array when yielding 0 values.
- `ecoYieldMany` must set `isTerminator = True` (like `scfYield/scfYieldMany`), and it must be stored in `MlirBlock.terminator` whenever it is the region terminator.

**Step 1.2: Add `scfYieldMany`**
```elm
scfYieldMany : Ctx.Context -> List ( String, MlirType ) -> ( Ctx.Context, MlirOp )
```
- Must construct `"scf.yield"` with:
  - `operands = List.map Tuple.first pairs`
  - `_operand_types = ArrayAttr [ TypeAttr ty1, ..., TypeAttr tyN ]` exactly matching the operand list
  - `isTerminator = True`
- Must handle the empty case:
  - `operands = []`
  - `_operand_types = []`
  - still emit `"scf.yield"` as terminator
- Existing `scfYield : Ctx.Context -> String -> MlirType -> ...` becomes a wrapper:
  - `scfYield ctx v ty = scfYieldMany ctx [ (v, ty) ]`

**Critical invariant:** The current unary `scfYield` always emits `_operand_types` with a singleton list. The many-variant must **always** match operand count exactly, including emitting an empty `_operand_types = []` when yielding 0 values. This prevents the exact verifier error that started this investigation ("expected 0 operand types but had 1").

**Recommended:** Implement a small internal helper:
```elm
buildYieldLike : Ctx.Context -> String -> List (String, MlirType) -> (Ctx.Context, MlirOp)
```
to ensure `_operand_types` and `operands` stay consistent for both eco/scf yields. This centralizes the invariant and reduces mistakes.

**Step 1.3: Add `ecoCaseMany` (or generalize `ecoCase`/`ecoCaseString`)**

**BLOCKER:** The current `ecoCase`/`ecoCaseString` builders produce **single-result** `eco.case` ops (e.g. `withResults [ ( resultVar, resultType ) ]`). TailRec step compilation requires **multi-result** `eco.case` to return the full loop-step tuple:
```mlir
%p1_next, ..., %pn_next, %done, %res = eco.case %scrutinee ... -> (ty1..tyn, i1, retTy)
```

**Solution:** Add multi-result variants:
```elm
ecoCaseMany :
    Ctx.Context
    -> String                           -- scrutinee
    -> List ( String, MlirType )        -- results (multiple SSA names + types)
    -> List MlirRegion                  -- alternative regions
    -> ( Ctx.Context, MlirOp )

ecoCaseStringMany :
    Ctx.Context
    -> String                           -- scrutinee
    -> List ( String, MlirType )        -- results
    -> List ( String, MlirRegion )      -- (pattern, region) pairs
    -> MlirRegion                       -- default region
    -> ( Ctx.Context, MlirOp )
```

- Use `opBuilder.withResults results` where `results : List (String, MlirType)`.
- Keep existing single-result `ecoCase`/`ecoCaseString` as wrappers:
  ```elm
  ecoCase ctx scrut resultVar resultType regions =
      ecoCaseMany ctx scrut [ ( resultVar, resultType ) ] regions
  ```

**Alternative (not recommended):** If multi-result `eco.case` is avoided, TailRec must pack loop state into a single `eco.tuple` / packed struct and destructure afterward. This materially changes the plan's data-flow model and adds boxing overhead.

---

### Phase 2: Create TailRec Module

**Step 2.1: Create `compiler/src/Compiler/Generate/MLIR/TailRec.elm`**

Define core types:
```elm
type alias LoopSpec =
    { funcName : String
    , paramVars : List ( String, MlirType )   -- current SSA vars for params (these are the scf.while region block-args, not the outer function args)
    , retType : MlirType
    }

type alias StepResult =
    { ops : List MlirOp
    , nextParams : List ( String, MlirType )  -- SSA vars for next iteration
    , doneVar : String                        -- i1: true = done, false = continue
    , resultVar : String                      -- result when done
    , ctx : Ctx.Context
    }
```

**Note:** `doneVar` is a compiler-internal control flag and is intentionally `i1`. It must never be boxed into `!eco.value` or escape to user-visible values.

**Step 2.2: Implement `compileTailFuncToWhile`**
```elm
compileTailFuncToWhile :
    Ctx.Context
    -> String                            -- func name
    -> List ( String, MlirType )         -- function args
    -> Mono.MonoExpr                     -- body
    -> MlirType                          -- return type
    -> ( List MlirOp, Ctx.Context )      -- returns ops in order: init-ops (doneInit/resInit) + scf.while + eco.return resFinal
```

Algorithm:
1. Define the loop-carried state types in a fixed order:
   - `stateTypes = (p1Ty..pnTy, doneTy=i1, resTy=retTy)`
2. Define the initial state SSA vars in the same order:
   - `initVars = (p1Init..pnInit, doneInit, resInit)`
   - Where:
     - `pKInit` are the function argument SSA vars already in scope
     - `doneInit` is `arith.constant false : i1`
     - `resInit` is a well-typed dummy of `retTy` (must be terminator-free)
3. Emit `initOps` first and define `ctxInit`:
   - Emit ops that define `doneInit` and `resInit` (and any boxes needed), producing `initOps` and `ctxInit`.
   - All subsequent fresh SSA names in this algorithm (`resultVars`, `beforeArgs`, `afterArgs`, `continueVar`, etc.) must be generated starting from `ctxInit`.
4. Allocate fresh SSA names for the `scf.while` *results* (also in the same order):
   - `resultVars = (p1Final..pnFinal, doneFinal, resFinal)`
   - Note: The `resultVars` passed to `Ops.scfWhile` are the SSA names that will be bound to the `scf.while` op results; they are not block args.
5. Define the `triples` (but do not emit `scf.while` yet):
   - `triples = zip3 resultVars initVars stateTypes`
   - i.e. `(resultVar, initVar, type)` for every carried value, including `done` and `res`.
6. Build the **before region** as a single-block `MlirRegion`:
   - `entry.args = beforeArgs : List (String, MlirType)` where `beforeArgs` matches `stateTypes`
   - `doneArg` is the element at index `n` of `beforeArgs` (0-based), and `resArg` is at index `n+1`, where `n = length(p1..pn)`.
   - Build `condOps` first, producing `(condOps, continueVar, ctxCond)` (ctx after all cond ops and name generation). `condOps` computes `%continue : i1` from `doneArg` using a pure arith op (e.g. `arith.xori doneArg, true` or `arith.cmpi eq doneArg, false`) so `condOps` remains terminator-free.
   - Then `( ctxAfterCond, condTerminator ) = Ops.scfCondition ctxCond continueVar (zip beforeArgs stateTypes)` where `beforeArgs` includes **all** loop-carried SSA block args in order `(p1..pn, doneArg, resArg)` (SCF requires the condition terminator to forward the next-iteration state values, even though the condition only depends on `doneArg`)
   - `entry.body = condOps`
   - `entry.terminator = condTerminator` and TailRec must continue with `ctxAfterCond`.
   - `condOps` must contain only non-terminator ops; the **only** terminator in the before block is the `Ops.scfCondition`.

**SSA naming rule:** `beforeArgs` and `afterArgs` must be generated using `Ctx.freshVar` (or an equivalent fresh-name generator) so their SSA names are unique across the whole function/module output. Do not reuse textual names between regions even if types match. This same rule applies to `resultVars` (the `scf.while` result SSA names) and to any intermediate names like `continueVar`: generate them via `Ctx.freshVar` and thread the updated `Ctx.Context`.

7. Build the **after region** as a single-block `MlirRegion`:
   - `entry.args = afterArgs` identical types/order to `beforeArgs`
   - Let `ctxStart = ctxAfterCond` (the ctx after building the before-region block and its `scf.condition` terminator).
   - Let `stepResult = compileStep ctxStart loopSpec bodyExpr` returning `{ ops, nextParams, doneVar, resultVar, ctx = ctxStep }` where `LoopSpec.paramVars = take n afterArgs` paired with `(p1Ty..pnTy)` (i.e. the parameter vars come from the **after-region block args**, not from any hard-coded names or outer function args)
   - Then `( ctxAfterYield, yieldTerminator ) = Ops.scfYieldMany ctxStep (nextParams..., doneVar, resultVar)` where each element is `(ssaName, MlirType)` and `_operand_types` is generated from those types
   - `entry.body = stepResult.ops`
   - `entry.terminator = yieldTerminator` (must be stored in the block's `terminator` field, not appended to `body`) and TailRec must continue with `ctxAfterYield`.

Define `ctxAfterRegions = ctxAfterYield` (i.e. the ctx after constructing both regions), and use `ctxAfterRegions` as the input ctx when emitting `Ops.scfWhile`.

8. Emit the `scf.while` op (now that regions exist) and thread ctx:
   - `( ctxAfterWhile, whileOp ) = Ops.scfWhile ctxAfterRegions triples beforeRegion afterRegion`
   - TailRec must continue with `ctxAfterWhile`.
9. After `scf.while`, return `resFinal`:
   - `( finalCtx, returnOp ) = Ops.ecoReturn ctxAfterWhile resFinal retTy` (or whatever your return builder is)
10. Return `( initOps ++ [ whileOp, returnOp ], finalCtx )` where:
   - `initOps` defines `doneInit` and `resInit`
   - `whileOp` is the result of `Ops.scfWhile`
   - `returnOp` returns `resFinal`
   - `finalCtx` is the ctx after emitting the return op (ctx is threaded through all builders above)

#### Region construction (matches `MlirRegion` / `MlirBlock` model)

TailRec must construct `scf.while` regions as **single-block regions** using the `entry` block only:
- A region is:
  - `MlirRegion { entry = block0, blocks = OrderedDict.empty }`
- A block is:
  - `args = [...]`
  - `body = [ ...non-terminator ops... ]`
  - `terminator = <exactly one terminator op>`

**Invariant:** `blocks` must remain empty for SCF regions; do not create extra blocks in `blocks` for `scf.while` before/after regions.

The `scf.condition` operands and the `scf.yield` operands must reference block-argument SSA names, not the outer function arguments.

#### Helper: construct a single-block region

Implement a small helper in `TailRec.elm`:
```elm
mkSingleBlockRegion :
    List ( String, MlirType )   -- block args
    -> List MlirOp              -- body ops (non-terminator)
    -> MlirOp                   -- terminator
    -> MlirRegion
```

Definition (conceptual):
```elm
mkSingleBlockRegion args body terminator =
    MlirRegion
        { entry = { args = args, body = body, terminator = terminator }
        , blocks = OrderedDict.empty
        }
```

This removes ambiguity about where terminators are stored.

---

### Phase 3: Implement Step Compilation

**Step 3.1: Implement `compileStep`**

Main dispatcher that handles:

| Expression | Action | Done? | Next Params |
|------------|--------|-------|-------------|
| `MonoTailCall` | Evaluate args, set `done=false` | false | new arg values |
| Any other expr | Evaluate via **TailRec-safe lowering** (must not emit `eco.return` / `eco.jump`) | true | unchanged |
| `MonoCase` | Recursive step compilation per branch | varies | varies |
| `MonoIf` | Treat as 2-way case | varies | varies |

**Hard rule:** `TailRec.compileStep` must not call the legacy `Expr.generateCase` implementation while it is still the control-flow-exit (`eco.return`-based) version. Until Phase 0 lands, TailRec must either:
- crash if it encounters `MonoCase`, or
- lower `MonoCase` itself using only yield-based/value-producing `eco.case`.

**Step 3.2: Handle `MonoTailCall` → Continue State**

If `MonoTailCall`'s `funcName` does **not** equal `LoopSpec.funcName`, treat it as a normal call (i.e., compile as "base return step" producing `done=true`) or fall back to joinpoint strategy. Do **not** convert it to a loop "continue".

```elm
compileTailCallStep : Ctx.Context -> LoopSpec -> List (Name, MonoExpr) -> StepResult
```
- Verify call target name equals `LoopSpec.funcName` (self-recursion check)
- Evaluate each argument expression
- Coerce each evaluated tail-call argument to the corresponding **loop-carried parameter MLIR type** from `stateTypes` (boxing/unboxing as needed so the yielded `nextParams` types exactly match the `scf.while` carried types)
- Set `doneVar = arith.constant false : i1`
- Set `resultVar = dummy(retType)`
- `nextParams` = new argument SSA vars

**Step 3.3: Handle Base Return → Done State**
```elm
compileBaseReturnStep : Ctx.Context -> LoopSpec -> MonoExpr -> StepResult
```
- Evaluate expression with `Expr.generateExpr` **in "TailRec-safe mode"**: it must not emit `eco.jump` or `eco.return`. Additionally, if it encounters `MonoTailCall`, crash (TailRec assumes `MonoTailCall` only appears in tail position). (Implementation detail: thread a `codegenMode` flag through `Ctx.Context` or pass an explicit parameter.)
- Coerce to return type
- Set `doneVar = arith.constant true : i1`
- `nextParams = loopSpec.paramVars` (the **after-region** block-arg SSA vars for parameters), unchanged.
- `resultVar` = evaluated result

**Step 3.4: Handle `MonoCase` → Multi-Result eco.case**

This is the key for "complex" tail recursion:
```mlir
%p1_next, ..., %pn_next, %done, %res = eco.case %scrutinee ... -> (ty1..tyn, i1, retTy) {
  eco.yield %p1_alt, ..., %pn_alt, %done_alt, %res_alt
}, ...
```

Each alternative:
- Recursively call `compileStep` on branch expression
- Use `ecoYieldMany` with `(nextParams..., done, result)` — same order as loop state
- The `eco.case` result types must be exactly `stateTypes = (p1Ty..pnTy, i1, retTy)`, and each `eco.yieldMany` must yield values in that same order so the after-region can immediately forward them to `scf.yieldMany`

---

### Phase 4: Wire Into Function Generation

**Step 4.1: Modify `Functions.generateTailFunc`**

Replace:
```elm
-- Current: eco.joinpoint + initial eco.jump
( jpBodyRegion, ctx1 ) = generateTailRecursiveBody ctxWithArgs expr retTy
...
ecoJoinpoint ...
eco.jump 0
```

With:
```elm
-- New: scf.while directly
( bodyOps, ctx1 ) = TailRec.compileTailFuncToWhile ctx funcName paramPairs expr retTy
```

(Then `Functions.generateTailFunc` uses `bodyOps` as the function body ops.)

**Step 4.2: Keep Joinpoint for Non-Tail Uses**
- Do NOT delete `eco.joinpoint` support
- Still needed for shared joinpoints in pattern-match compilation
- Only tail recursion uses `scf.while` now

**Step 4.3: Update `Expr.generateTailCall`**
- Add defensive check: if called during TailRec compilation, crash
- Document invariant: tail-recursive functions must not reach `generateTailCall`
- Add a second defensive check: if TailRec compilation mode is active and `Expr.generateExpr` attempts to lower `MonoCase` via the legacy `eco.return`-based path, crash with a message pointing to Phase 0 migration requirement

**Step 4.4: `MonoTailDef` Handling — DEFERRED**

For first milestone, `MonoTailDef` continues to use existing joinpoint-based codegen.

**Reason:** The monomorphic IR has no "escapes" metadata. Without escape analysis, we cannot safely determine if a local tail-recursive function can be lowered to `scf.while` (risk: creating uncallable "local loop" whose value escapes).

See "Escape Analysis Design for MonoTailDef" in Future Work section for implementation details when this is tackled.

---

### Phase 5: Runtime Pass Updates

**Step 5.1: Rewrite `EcoControlFlowToSCF.cpp` pass contract for yield-based `eco.case` (BLOCKER)**

**Reality check:** The current `EcoControlFlowToSCF.cpp` pass is designed around the "control-flow exit" encoding where `eco.case` alternatives exit via `eco.return`. The pass theory and implementation assume this contract. TailRec requires the **yield-based** encoding where alternatives terminate with `eco.yield` and `eco.case` is value-producing.

**This is a non-trivial pass rewrite, not just a verification step.** An engineer will be blocked if they underestimate this work.

**Decision: Option A (recommended)**
Update `EcoControlFlowToSCF.cpp` to lower **value-producing `eco.case` with `eco.yield` terminators**:
- Recognize `eco.yield` (variadic) as the alternative terminator instead of `eco.return`.
- Forward multi-result yields correctly when rewriting to `scf.if`/`scf.index_switch`.
- Handle `scf.yield` continuation (inside `scf.while` after-regions), not just `eco.return` continuation.

**Alternative: Option B (more compiler work, less pass work)**
Stop relying on `EcoControlFlowToSCF` for cases and have the Elm compiler directly emit `scf.if`/`scf.index_switch` for `MonoCase` in Phase 0. This shifts the complexity from C++ to Elm but avoids pass contract changes.

**For this plan, we commit to Option A.**

Check/implement:
```cpp
// Pattern: eco.case inside scf.while after-region, followed by scf.yield
// Must lower eco.case to scf.if/scf.index_switch with matching scf.yield
// Multi-result forwarding: all yielded values must propagate through SCF ops
```

- Ensure the compiler never constructs SCF regions with additional blocks in `MlirRegion.blocks`; otherwise `EcoControlFlowToSCF` (and MLIR verifier) will reject the IR.

**Step 5.2: Verify Pass Ordering**

Ensure the runtime lowering pipeline eliminates SCF **after** `EcoControlFlowToSCF` has created SCF, and ensure `eco.case` is not CFG-lowered while still nested under SCF regions. A proven approach is to have `EcoToLLVM` run a coupled dialect-conversion that includes:
- EcoControlFlowToSCF-style case lowering (eco.case → scf.if/scf.index_switch)
- SCF → CF structural lowering
- Remaining Eco CFG lowering

potentially in multiple conversion rounds until both SCF and eco.case are fully eliminated.

(If you truly have separate passes, keep them—but then you must guarantee "no CFG-style lowering runs under SCF".)

---

### Phase 6: Testing

**Test 6.1: Simple Tail Recursion**
- `foldl`-style function
- Verify: `scf.while` present, no `eco.joinpoint`

**Test 6.2: Complex Decision Tree Tail Recursion**
- Multiple case branches with tail calls
- Verify: no `eco.jump` terminators, loop-carried state includes `(done, result)`

**Test 6.3: Nested `eco.case` Inside `scf.while`**
- Step computed by multi-way case
- Verify: IR verifies, lowering succeeds

**Test 6.4: Existing Tests Pass**
- Run full E2E test suite
- Especially: ListFoldlTest, ListMapTest, etc.

---

## File Changes Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `Expr.elm` | **Modify (Phase 0)** | Migrate `generateCase` from `eco.return`-based to yield-based style |
| `Expr.elm` | **Modify (Phase 0)** | Disable/replace `generateSharedJoinpoints` usage for yield-based case generation (inline branches; no `eco.joinpoint` inside case lowering) |
| `Expr.elm` | **Modify (Phase 0)** | Replace `mkCaseRegionFromDecider`/dummy-return terminator enforcement with yield-based region construction (`eco.yieldMany` terminators only) |
| `Ops.elm` | **Modify (Phase 0)** | Add `ecoYieldMany`, `scfYieldMany`, `ecoCaseMany`, `ecoCaseStringMany` (multi-result builders) |
| `TailRec.elm` | **Create** | New module for scf.while-based tail recursion |
| `Functions.elm` | Modify | Wire `MonoTailFunc` to `TailRec.compileTailFuncToWhile`; keep joinpoint fallback |
| `Expr.elm` | Modify | Add defensive checks in `generateTailCall` and for legacy case path |
| `EcoControlFlowToSCF.cpp` | **Rewrite (Phase 5)** | Update pass contract from `eco.return`-based to yield-based `eco.case` (multi-result forwarding) |
| `eco_case_multi_result_under_scf_while.mlir` | **Create** | Regression test for C++ pass verification |

## Fallback Strategy

The implementation maintains backward compatibility with the joinpoint-based approach:

| Case | First Milestone | Future |
|------|-----------------|--------|
| Self tail-recursive `MonoTailFunc` | `scf.while` | `scf.while` |
| Self tail-recursive `MonoTailDef` (non-escaping) | `eco.joinpoint` (deferred) | `scf.while` (requires escape analysis) |
| Escaping `MonoTailDef` (used as closure) | `eco.joinpoint` | `eco.joinpoint` |
| Mutual tail recursion | `eco.joinpoint` | SCC trampoline |
| Non-tail shared joinpoints | `eco.joinpoint` (unchanged) | `eco.joinpoint` (unchanged) |

**Key Decision:** `MonoTailDef` → `scf.while` is deferred because no escape tracking exists in the IR.

---

## Implementation Order

### Phase 0: Prerequisite builders + migrate eco.case to Yield-Based Semantics (BLOCKING)
0.1 Implement `ecoYieldMany`, `scfYieldMany`, and `ecoCaseMany`/`ecoCaseStringMany` in `Ops.elm` (Phase 1, Step 1.1–1.3), because:
   - Phase 0's yield-based `eco.case` generator requires `ecoYieldMany` to terminate alternative regions correctly.
   - TailRec step compilation requires multi-result `eco.case` (Step 1.3).
0.2 Migrate `Expr.generateCase` from the current `eco.return`/dummy-return control-flow-exit style to yield-based value-producing style (details in Phase 0 section above).
   - Alternatives must terminate with `eco.yield`, not `eco.return`
   - `eco.case` becomes value-producing (returns SSA values)
   - **Acceptance test:** `MonoCase` codegen must not emit `eco.return` internally

### Phase A: Infrastructure (BLOCKING)
1. **Create MLIR regression test** `runtime/test/codegen/eco_case_multi_result_under_scf_while.mlir`
   - Multi-value `scf.while` with `eco.case` in after-region
   - Multi-operand `eco.yield` in alternatives
   - `scf.yield` continuation (not `eco.return`)
2. **Run test and verify** — if fails, rewrite `EcoControlFlowToSCF.cpp` (see Phase 5.1 and "C++ Pass Verification Protocol")
3. Create `TailRec.elm` skeleton with types

### Phase B: Core Self Tail-Recursion (MonoTailFunc)
4. Implement `compileTailFuncToWhile` basic structure
5. Implement `compileStep` for simple cases (tail call, base return)
6. Wire `Functions.elm` to use TailRec for `MonoTailFunc`
7. Keep joinpoint fallback path available
8. Test simple tail recursion (should work now)

### Phase C: Complex Control Flow
9. Implement `MonoCase` step compilation (multi-result eco.case)
10. Verify runtime pass ordering
11. Test complex decision-tree tail recursion

### Phase D: Local Tail-Recursive Functions (MonoTailDef) — DEFERRED
**Decision:** Postpone `MonoTailDef` → `scf.while` to a future milestone.

The monomorphic IR has no "escapes" flag, and closure capture analysis (`Closure.elm`) only tracks free variables, not escape behavior. Without escape analysis, we risk creating uncallable "local loops" whose values escape.

For first milestone:
- Keep `MonoTailDef` on existing joinpoint fallback
- Focus on `MonoTailFunc` (top-level) which is the primary use case

Future work (Phase D, when implemented):
12. Add escape analysis module (see "Escape Analysis Design" section below)
13. Wire `Expr.elm` to use TailRec for qualifying non-escaping `MonoTailDef`
14. Fall back to joinpoint for escaping/mutual cases
15. Test local tail-recursive let bindings

### Phase E: Validation
13. Full E2E testing
14. Run elm-core test suite to verify fixes

---

## Questions and Resolutions

### Resolved Questions

**Q1: Should `eco.joinpoint` be removed entirely for tail recursion?**
**Resolution:** Keep `eco.joinpoint` as a fallback mechanism. The primary path for self tail-recursive `MonoTailFunc` is `scf.while`. Joinpoint remains for:
- Non-tail uses (shared joinpoints in pattern-match compilation)
- Complex cases that don't fit the scf.while model
- Fallback when scf.while compilation encounters edge cases

**Q2: How should mutual tail recursion be handled?**
**Resolution:** Two-phase approach:
- **First milestone:** Fall back to `eco.joinpoint` for mutual tail recursion
- **Future work:** Implement SCC trampoline/dispatcher loop pattern that fuses mutually tail-recursive functions into a single `scf.while` with a discriminant

**Q3: What happens with `MonoTailDef` (local tail-recursive let bindings)?**
**Resolution:** **Deferred to future milestone.**

The monomorphic IR has no escape tracking. Without knowing if the local function escapes (is used as a value, passed as argument, captured in closure), we cannot safely lower to `scf.while`.

First milestone: Keep `MonoTailDef` on existing joinpoint fallback.
Future: Add escape analysis (see "Escape Analysis Design" section), then `scf.while` for non-escaping self-recursive cases.

**Q4: Multi-result eco.case lowering in EcoControlFlowToSCF.cpp**
**Resolution:** This is a **blocking dependency** that must be verified in Phase A before proceeding.

Verification protocol:
1. Create MLIR regression test (`eco_case_multi_result_under_scf_while.mlir`)
2. Test multi-value `scf.while` with `eco.case` in after-region, `scf.yield` continuation
3. If test fails, inspect C++ pass for single-result assumptions and `eco.return`-only continuation handling
4. Fix as needed (see "C++ Pass Verification Protocol" section for specific failure modes and fixes)

**Q5: Empty param list edge case**
**Resolution:** Implement it anyway. Even if Elm source-level functions are curried, backend-generated wrappers/thunks can be zero-arg. TailRec will support an empty `paramVars` list by still carrying `(done, result)` in the loop state.

---

### Assumptions

**A1: TailRec only handles self tail recursion**
`compileStep` treats `MonoTailCall` as a "continue" only when the call target name equals the enclosing `MonoTailFunc` name. Other tail calls (including mutual recursion) fall back to joinpoints for the first milestone.

**A2: EcoControlFlowToSCF handles scf.yield continuation**
The design doc states the pass should handle `eco.case` followed by `scf.yield` in "terminal position". This appears to be supported based on code inspection, but needs testing.

**A3: Parameter types are consistent across iterations**
The loop-carried parameter types must match between:
- Function parameters
- Arguments in tail calls
- scf.while block arguments

The monomorphizer should ensure this, but type coercion may be needed.

**A4: Dummy values are well-typed**
`Expr.createDummyValue` is used for the "unreachable" result value on continue iterations. This must produce valid typed values that won't cause lowering issues.

**A5: No nested tail-recursive functions**
A tail-recursive function's body doesn't contain another `MonoTailDef`. If it does, the inner one would need separate handling.

---

### Risks

**R1: Performance regression for simple cases**
The scf.while approach adds `(done, result)` to loop state even for simple foldl-style functions that could use a tighter loop. The overhead should be minimal but worth measuring.

**R2: Increased MLIR complexity**
Multi-result eco.case is more complex than single-result. Debugging generated MLIR will be harder.

**R3: Pass ordering sensitivity**
The pipeline must be carefully ordered. If eco.case lowering runs before scf.while is fully constructed, or if SCF→CF conversion is missing, the IR will fail verification.

**R4: C++ pass support uncertainty**
The multi-result eco.case + scf.yield pattern may not be fully supported in `EcoControlFlowToSCF.cpp`. This must be verified early (Phase A, Step 2) before building on it.

---

## Future Work (Out of Scope for First Milestone)

### Mutual Tail Recursion via SCC Trampoline
For mutually tail-recursive functions (e.g., `even`/`odd`), the long-term solution is to:
1. Detect strongly connected components (SCCs) of tail calls
2. Fuse the SCC into a single `scf.while` with a discriminant tag
3. Each original function becomes a "case" in the dispatcher loop

This is deferred to a future milestone. For now, mutual tail recursion falls back to `eco.joinpoint`.

---

### Escape Analysis Design for MonoTailDef (Future Phase D)

**Current State:** The monomorphic IR (`MonoTailDef Name (List (Name, MonoType)) MonoExpr`) has no "escapes" metadata. The closure/capture analysis (`Compiler.Generate.Monomorphize.Closure`) treats all let-bound names as **bound** (not captured), which is correct for free-variable analysis but doesn't track escape behavior.

#### Concrete "Escape" Definition

For a `MonoTailDef f ...` in a let-chain, mark `f` as **escaping** if ANY of these are true:
1. `f` is used as a value (`MonoVarLocal f _`) in any **non-callee position**:
   - Stored in a list/tuple/record
   - Passed as an argument to another call
   - Returned as the overall expression result
2. `f` is referenced inside the body of a `MonoClosure` (closure could outlive let-scope)
3. `f` is referenced in any context requiring a first-class function value

Mark `f` as **non-escaping** if every reference is one of:
- The callee of a `MonoCall` (i.e., `MonoCall _ (MonoVarLocal f _) args _`)
- A `MonoTailCall f ...` (tailcall form is name-based)

#### Implementation Options

**Option A (Best Long-Term): Monomorphization Pass with Rewrite**
- **New file:** `compiler/src/Compiler/Generate/Monomorphize/Escape.elm`
- Run after monomorphization produces `MonoGraph`, before MLIR generation
- If a `MonoTailDef` escapes, rewrite it into a `MonoDef` binding a `MonoClosure` (or lift to top-level)
- Reuse structural pattern from `findFreeLocals` which already traverses let-chains

**Option B (Smaller Change): Codegen-Time Decision**
- In MLIR codegen, when encountering `MonoLet` with `MonoTailDef`, run escape analysis locally
- Non-escaping → lower to `scf.while`
- Escaping → fall back to joinpoint/call path
- Less principled (escape is semantic, not codegen choice) but easier to land

**Recommendation:** Option A for correctness and future mutual recursion support.

---

### C++ Pass Verification Protocol

**Why Critical:** Current `Expr.generateCase` uses an `eco.return`-based lowering shape. Design C requires `eco.case` to be value-producing with variadic `eco.yield` terminators, and inside loops the continuation is `scf.yield` (not `eco.return`). If `EcoControlFlowToSCF.cpp` doesn't support this, Phase C will be blocked.

#### Step 1: Add MLIR Regression Test (Day 1 Priority)

Create: `runtime/test/codegen/eco_case_multi_result_under_scf_while.mlir`

The test should:
1. Build a `scf.while` with multi-value loop state
2. In the after-region, compute a multi-result `eco.case` (e.g., returns `(i1, !eco.value)`)
3. Terminate each alternative with multi-operand `eco.yield`
4. Terminate the after-region with `scf.yield`

Run the exact pass pipeline and verify with `mlir-opt`.

This validates:
- Multi-result propagation
- Recognition of `scf.yield` as continuation context (not only `eco.return`)

#### Step 2: Inspect EcoControlFlowToSCF.cpp for Failure Modes

Search for:
- **Single-result assumptions:** `caseOp.getResult(0)`, `getResultTypes()[0]`, etc.
- **Specific continuation checks:** "next op is `eco.return`" but NOT `scf.yield`
- **Block cloning issues:** Moving whole blocks into `scf.if` regions (SCF regions must stay single-block)

#### Step 3: Minimum C++ Changes If Test Fails

In `eco.case` → `scf.if` / `scf.index_switch` patterns:

1. **Multi-result types:**
   - Replace single-result plumbing with `caseOp->getResultTypes()` (vector)
   - Construct `scf::IfOp` / `scf::IndexSwitchOp` with all result types

2. **Variadic yields:**
   - When rewriting alternative terminator, forward ALL yielded operands into `scf.yield`

3. **Continuation rewriting for `scf.yield`:**
   - Extend pattern to rewire following `scf.yield` (not just `eco.return`)
   - This is exactly the tailrec-in-loop situation
