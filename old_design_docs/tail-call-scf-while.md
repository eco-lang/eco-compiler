## Goal

Replace the current tail-recursion codegen strategy (joinpoints + `eco.jump`) with **direct `scf.while` emission** in the Elm MLIR generator, so **tail-recursive functions compile to loops even when the tail call is inside complex `case`/decision-tree control flow**.
This design keeps your existing “decision tree → `eco.case` with `eco.yield` in alternatives” model (per your dialect definition: `eco.yield` is variadic and is the only valid terminator inside `eco.case` alternatives) , but changes *what tail calls mean*: **tail calls no longer emit a terminator** (`eco.jump`). Instead they produce a loop-step “continue” state.
It also aligns with your existing SCF infrastructure in `Ops.elm` (`scf.while` and `scf.condition`) , and with the SCF lowering pass contract that `eco.case` is lowerable in “terminal position” when followed by `scf.yield` .
---
## Core idea: compile tail recursion as a loop-step machine

For a tail-recursive function:
```
f(p1, p2, ..., pn) = BODY
```

Generate:
- `scf.while` loop-carried state: `(p1..pn, doneFlag, result)`
- Loop continues while `doneFlag == false`
- Each iteration evaluates **one step** of `BODY` and yields:
  - **Continue**: updated `(p1..pn, done=false, result=<dummy>)`
  - **Done**: `(p1..pn, done=true, result=<final value>)`
### Why we need `(doneFlag, result)` in the loop state
`scf.while`’s before-region decides whether to continue. In complex tail recursion (decision trees), “continue vs stop” is not a single simple predicate (unlike `foldl` on list-nil); it’s the outcome of the decision tree. So we store that decision in state and use a trivial “continue while not done” condition.
---
# Part A — Compiler (Elm) code changes
## A0) Make sure you are on the “yield-based eco.case” generator variant

Your repo contains both styles in different snapshots:
- a joinpoint/`eco.return`-style “case as control-flow exit” implementation 
- a yield-based “case is value-producing, alternatives end with `eco.yield`” implementation

Your repo contains both styles in different snapshots:
- a joinpoint/`eco.return`-style “case as control-flow exit” implementation 
- a yield-based “case is value-producing, alternatives end with `eco.yield`” implementation
This design assumes the **yield-based** dialect semantics in Ops.td . If your `Expr.elm` is currently the older “`eco.case` is a terminator” version, you must first remove/finish that migration. Otherwise, you cannot use multi-result `eco.case` cleanly inside a loop.
---
## A1) Extend op builders to support multi-result yields (required)
### File: `compiler/src/Compiler/Generate/MLIR/Ops.elm`

Today:
- `ecoYield` is unary (one operand, one `_operand_types`) 
- `scfYield` is unary 
- but the dialect allows variadic yields (`Eco_YieldOp` takes `Variadic<Eco_AnyValue>`) 
- and `scf.while` state/yield must often be multi-value

Today:
- `ecoYield` is unary (one operand, one `_operand_types`) 
- `scfYield` is unary 
- but the dialect allows variadic yields (`Eco_YieldOp` takes `Variadic<Eco_AnyValue>`) 
- and `scf.while` state/yield must often be multi-value
#### Change A1.1 — Add variadic `ecoYieldMany`
Add:
```elm
ecoYieldMany : Ctx.Context -> List ( String, MlirType ) -> ( Ctx.Context, MlirOp )
ecoYieldMany ctx values =
    let
        vars = List.map Tuple.first values
        tys  = List.map Tuple.second values
        attrs =
            if List.isEmpty tys then
                Dict.empty
            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map TypeAttr tys))
    in
    mlirOp ctx "eco.yield"
        |> opBuilder.withOperands vars
        |> opBuilder.withAttrs attrs
        |> opBuilder.isTerminator True
        |> opBuilder.build
```

Keep existing `ecoYield` as a convenience wrapper calling `ecoYieldMany [ (operand, operandType) ]`.
#### Change A1.2 — Add variadic `scfYieldMany`
```elm
scfYieldMany : Ctx.Context -> List ( String, MlirType ) -> ( Ctx.Context, MlirOp )
scfYieldMany ctx values =
    let
        vars = List.map Tuple.first values
        tys  = List.map Tuple.second values
        attrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing (List.map TypeAttr tys))
    in
    mlirOp ctx "scf.yield"
        |> opBuilder.withOperands vars
        |> opBuilder.withAttrs attrs
        |> opBuilder.isTerminator True
        |> opBuilder.build
```

You will use this in the `scf.while` after-region to yield the full loop state.
> Note: `scfCondition` already supports multiple carried values (`List (String, MlirType)`) , so no change needed there.
---
## A2) Add a dedicated TailRec-to-SCF codegen module (recommended)
### Create file: `compiler/src/Compiler/Generate/MLIR/TailRec.elm` *(new)*

This module will generate the `scf.while` structure and compile one “step” of a tail-recursive body.
#### Data structures
```elm
type alias LoopSpec =
    { funcName : String
    , paramVars : List ( String, MlirType )   -- current SSA vars for params
    , retType : MlirType
    }

type alias StepResult =
    { ops : List MlirOp
    , nextParams : List ( String, MlirType )  -- SSA vars for params after this step
    , doneVar : String                        -- i1 SSA var
    , resultVar : String                      -- SSA var of retType
    , ctx : Ctx.Context
    }
```
---
## A3) Implement `compileTailFuncToWhile`
### File: `TailRec.elm` *(new)*

Signature (sketch):
```elm
compileTailFuncToWhile :
    Ctx.Context
    -> String
    -> List ( String, MlirType )     -- function arguments (ssa vars)
    -> Mono.MonoExpr                 -- body
    -> MlirType                      -- return type
    -> ( MlirRegion, Ctx.Context )   -- region for func.func
```
#### Steps

1) **Create loop-carried initial state**
- params = function args
- `done0 = false : i1`
- `res0 = dummy(retType)` (reuse `Expr.createDummyValue` which already exists and creates typed dummy values)

1) **Create loop-carried initial state**
- params = function args
- `done0 = false : i1`
- `res0 = dummy(retType)` (reuse `Expr.createDummyValue` which already exists and creates typed dummy values)
2) **Build scf.while op**
Use existing builder `Ops.scfWhile`  with loop vars:
```
[(p1_out, p1_in, ty1), ..., (pn_out, pn_in, tyn), (done_out, done0, I1), (res_out, res0, retTy)]
```

3) **Before region (condition):**
- block args are loop-carried state
- condition is `continue = not done`
- then `Ops.scfCondition continue args`

3) **Before region (condition):**
- block args are loop-carried state
- condition is `continue = not done`
- then `Ops.scfCondition continue args`
4) **After region (body):**
- block args are loop-carried state
- compile **one step** of the tail-recursive body into a `StepResult`
- end with `scf.yield` of `(nextParams..., doneVar, resultVar)` using `scfYieldMany`

5) **After the while:**
Return the final `res_out` via `eco.return`/`func.return` depending on your function lowering stage (your codebase currently uses eco.return in function bodies in multiple places; keep consistent).
4) **After region (body):**
- block args are loop-carried state
- compile **one step** of the tail-recursive body into a `StepResult`
- end with `scf.yield` of `(nextParams..., doneVar, resultVar)` using `scfYieldMany`

5) **After the while:**
Return the final `res_out` via `eco.return`/`func.return` depending on your function lowering stage (your codebase currently uses eco.return in function bodies in multiple places; keep consistent).
4) **After region (body):**
- block args are loop-carried state
- compile **one step** of the tail-recursive body into a `StepResult`
- end with `scf.yield` of `(nextParams..., doneVar, resultVar)` using `scfYieldMany`

5) **After the while:**
Return the final `res_out` via `eco.return`/`func.return` depending on your function lowering stage (your codebase currently uses eco.return in function bodies in multiple places; keep consistent).
---
## A4) Implement `compileStep` (the key for “complex ones”)
### File: `TailRec.elm` *(new)*

This must handle:
- tail calls (`Mono.MonoTailCall`) → “continue” state
- non-tail results → “done” state
- `MonoCase` / decision trees → produce state via `eco.case` returning multiple results
- `MonoIf` → either use `scf.if` (multi-result) or lower it to `eco.case` on `i1`

This must handle:
- tail calls (`Mono.MonoTailCall`) → “continue” state
- non-tail results → “done” state
- `MonoCase` / decision trees → produce state via `eco.case` returning multiple results
- `MonoIf` → either use `scf.if` (multi-result) or lower it to `eco.case` on `i1`
#### A4.1 Tail call: `Mono.MonoTailCall name args _`
Your current `Expr.generateTailCall` emits an `eco.jump` terminator and sets `resultVar = ""` (meaningless) . We must *not* do that anymore for self-tail recursion.
Instead:
- compile each argument expression via existing `Expr.generateExpr`
- coerce each argument to the *parameter ABI type* as needed (reuse `Expr.coerceResultToType` pattern)
- construct:
  - `doneVar = arith.constant false : i1`
  - `resultVar = dummy(retType)` (unreachable on continue, but must be well-typed)

Return `StepResult` with `nextParams` being the new argument SSA vars.
- compile each argument expression via existing `Expr.generateExpr`
- coerce each argument to the *parameter ABI type* as needed (reuse `Expr.coerceResultToType` pattern)
- construct:
  - `doneVar = arith.constant false : i1`
  - `resultVar = dummy(retType)` (unreachable on continue, but must be well-typed)

Return `StepResult` with `nextParams` being the new argument SSA vars.
#### A4.2 Base return: any other expression `e`
- compile `e` with `Expr.generateExpr`
- coerce to retType
- set `doneVar = true`
- keep params unchanged as `nextParams = currentParams`
#### A4.3 `MonoCase`: compile the decision tree to an `eco.case` that returns the *whole step tuple*
This is the mechanism that makes “complex ones” work without requiring you to directly emit nested `scf.if`/`scf.index_switch` in Elm codegen.
You want:
```
%done, %p1', ..., %pn', %res = eco.case %scrutinee ... -> (i1, ty1..tyn, retTy) { ... } {
  eco.yield <values-for-branch>
}, ...
```

Each alternative region ends with `eco.yield` and yields:
- continue branch: `(false, newParams..., dummyRes)`
- done branch: `(true, currentParams..., computedRes)`

Each alternative region ends with `eco.yield` and yields:
- continue branch: `(false, newParams..., dummyRes)`
- done branch: `(true, currentParams..., computedRes)`
This is valid because `eco.yield` is variadic and must match the parent `eco.case` result types .
**Implementation approach:**
- Copy your existing decision-tree walking structure (`generateDecider`, `generateFanOut`, `generateChain`, etc.) but parameterize the “leaf compilation” to return `StepResult` instead of `ExprResult`.
- When building regions, use `ecoYieldMany` with `(done, params..., res)`.
**Implementation approach:**
- Copy your existing decision-tree walking structure (`generateDecider`, `generateFanOut`, `generateChain`, etc.) but parameterize the “leaf compilation” to return `StepResult` instead of `ExprResult`.
- When building regions, use `ecoYieldMany` with `(done, params..., res)`.
This is the main chunk of work, but it’s all in Elm codegen and it reuses your existing `Patterns.generateDTPath` / tag comparisons that already exist in `Expr.elm` for cases .
---
## A5) Wire it into function generation
### File: `compiler/src/Compiler/Generate/MLIR/Functions.elm`

Right now, tail-recursive functions are implemented using `eco.joinpoint` and an initial `eco.jump` into joinpoint 0 , and for one special shape (if-then-else) it builds a multi-block joinpoint body .
#### Change A5.1 — For tail-recursive nodes, use `TailRec.compileTailFuncToWhile`
Where you currently do:
- `generateTailRecursiveBody`
- `ecoJoinpoint`
- initial `eco.jump`

Replace with:

- `TailRec.compileTailFuncToWhile` producing a single-block func body containing:
  - the `scf.while` op
  - a final return

This removes joinpoints from MLIR *generation* for tail recursion entirely.
- `generateTailRecursiveBody`
- `ecoJoinpoint`
- initial `eco.jump`

Replace with:

- `TailRec.compileTailFuncToWhile` producing a single-block func body containing:
  - the `scf.while` op
  - a final return

This removes joinpoints from MLIR *generation* for tail recursion entirely.
- `generateTailRecursiveBody`
- `ecoJoinpoint`
- initial `eco.jump`

Replace with:

- `TailRec.compileTailFuncToWhile` producing a single-block func body containing:
  - the `scf.while` op
  - a final return

This removes joinpoints from MLIR *generation* for tail recursion entirely.
- `generateTailRecursiveBody`
- `ecoJoinpoint`
- initial `eco.jump`

Replace with:

- `TailRec.compileTailFuncToWhile` producing a single-block func body containing:
  - the `scf.while` op
  - a final return

This removes joinpoints from MLIR *generation* for tail recursion entirely.
#### Change A5.2 — Keep joinpoint machinery for non-tail loops only
Do not delete joinpoint support; it’s still needed for:
- non-tail recursion patterns
- shared joinpoints created for pattern-match compilation (if you still do that elsewhere)
Do not delete joinpoint support; it’s still needed for:
- non-tail recursion patterns
- shared joinpoints created for pattern-match compilation (if you still do that elsewhere)
But tail recursion should stop emitting `eco.jump` as a terminator in expression codegen.
---
## A6) Update/remove `Expr.generateTailCall` usage in tail functions
### File: `compiler/src/Compiler/Generate/MLIR/Expr.elm`

`generateTailCall` currently always emits `eco.jump` and marks the result meaningless .
Under this design:
- `generateTailCall` remains valid for *joinpoint* tail-call lowering (if you still use joinpoints in some contexts).
- But **tail-recursive functions compiled by `TailRec` must never call `generateTailCall`**. They must instead compile tail calls as “continue state” in `compileStep`.
Under this design:
- `generateTailCall` remains valid for *joinpoint* tail-call lowering (if you still use joinpoints in some contexts).
- But **tail-recursive functions compiled by `TailRec` must never call `generateTailCall`**. They must instead compile tail calls as “continue state” in `compileStep`.
So:
- add a code comment + invariant: “tail-recursive functions compiled with TailRec must not reach Expr.generateTailCall”.
So:
- add a code comment + invariant: “tail-recursive functions compiled with TailRec must not reach Expr.generateTailCall”.
Optionally (recommended), add a defensive crash:
- If `TailRec` compilation is active and `generateExpr` sees `MonoTailCall`, crash (so you catch accidental use immediately).
Optionally (recommended), add a defensive crash:
- If `TailRec` compilation is active and `generateExpr` sees `MonoTailCall`, crash (so you catch accidental use immediately).
---
# Part B — Runtime pass/pipeline changes (required to make this work end-to-end)

You now generate `scf.while` directly in the compiler. That means your lowering pipeline must handle SCF correctly.
## B1) Ensure nested `eco.case` inside SCF is lowered to SCF, not CF

Your own SCF lowering theory states patterns match `eco.case` followed by `eco.return` **or `scf.yield`** . This is exactly the scenario we create: inside `scf.while` after-region, a step often ends in `scf.yield`, so any `eco.case` you used to compute the step tuple is followed by `scf.yield`.
### Action:
Verify `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp` really supports this (the doc says it should) , and if not, implement it (accept `scf.yield` as the “terminal position” continuation and replace it appropriately).
*(The exact C++ edits aren’t in the uploaded snippets; this portion is necessarily extrapolation, but it is explicitly required by the pass contract you’ve documented.)*
---
## B2) Add an SCF → CF lowering stage before any CFG-building Eco lowering

Your `Passes.h` shows Stage 2 has both:
- `createEcoControlFlowToSCFPass()`
- `createControlFlowLoweringPass()` (Eco control flow to `cf`)

Your `Passes.h` shows Stage 2 has both:
- `createEcoControlFlowToSCFPass()`
- `createControlFlowLoweringPass()` (Eco control flow to `cf`)
Once SCF exists (because codegen emits it, and EcoControlFlowToSCF emits more of it), any later pass that constructs CFG blocks (CF-style case lowering) must not run inside SCF regions.
So you must enforce ordering:
1) Eco → SCF lowering (`EcoControlFlowToSCF`)
2) **SCF → CF conversion** (standard MLIR conversion)
3) Eco control flow to CF (`createControlFlowLoweringPass`) 
4) Eco → LLVM lowering
So you must enforce ordering:
1) Eco → SCF lowering (`EcoControlFlowToSCF`)
2) **SCF → CF conversion** (standard MLIR conversion)
3) Eco control flow to CF (`createControlFlowLoweringPass`) 
4) Eco → LLVM lowering
If you don’t already do step (2), you need to add it either:
- as a standalone pass in your pipeline, or
- inside `EcoToLLVM` using MLIR’s SCF-to-CF conversion patterns (this was discussed in your internal plan notes; the snippets aren’t in the repo excerpts, so this is extrapolation).
If you don’t already do step (2), you need to add it either:
- as a standalone pass in your pipeline, or
- inside `EcoToLLVM` using MLIR’s SCF-to-CF conversion patterns (this was discussed in your internal plan notes; the snippets aren’t in the repo excerpts, so this is extrapolation).
---
# Part C — Tests you must add

1) **Tail recursion + list case**
- Compile `foldl`-style function and check generated MLIR contains `scf.while` and **no `eco.joinpoint`**.

1) **Tail recursion + list case**
- Compile `foldl`-style function and check generated MLIR contains `scf.while` and **no `eco.joinpoint`**.
2) **Complex decision tree tail recursion**
- Use a reduced version of your `be`-style “worklist rewriting” tail recursion (where every recursive call is in tail position).
- Verify:
  - no `eco.jump` terminators emitted from the function body for tail recursion
  - loop-carried values include `(doneFlag, result)` (or whatever shape you pick)
  - IR verifies after the full Stage 2 pipeline.

3) **Nested `eco.case` inside `scf.while` regions**
- Construct a test where the loop step is computed by an `eco.case` (multi-way), then ends with `scf.yield`.
- This catches regressions in “case lowering under SCF” (the issue you’ve been fighting).
2) **Complex decision tree tail recursion**
- Use a reduced version of your `be`-style “worklist rewriting” tail recursion (where every recursive call is in tail position).
- Verify:
  - no `eco.jump` terminators emitted from the function body for tail recursion
  - loop-carried values include `(doneFlag, result)` (or whatever shape you pick)
  - IR verifies after the full Stage 2 pipeline.

3) **Nested `eco.case` inside `scf.while` regions**
- Construct a test where the loop step is computed by an `eco.case` (multi-way), then ends with `scf.yield`.
- This catches regressions in “case lowering under SCF” (the issue you’ve been fighting).
2) **Complex decision tree tail recursion**
- Use a reduced version of your `be`-style “worklist rewriting” tail recursion (where every recursive call is in tail position).
- Verify:
  - no `eco.jump` terminators emitted from the function body for tail recursion
  - loop-carried values include `(doneFlag, result)` (or whatever shape you pick)
  - IR verifies after the full Stage 2 pipeline.

3) **Nested `eco.case` inside `scf.while` regions**
- Construct a test where the loop step is computed by an `eco.case` (multi-way), then ends with `scf.yield`.
- This catches regressions in “case lowering under SCF” (the issue you’ve been fighting).
2) **Complex decision tree tail recursion**
- Use a reduced version of your `be`-style “worklist rewriting” tail recursion (where every recursive call is in tail position).
- Verify:
  - no `eco.jump` terminators emitted from the function body for tail recursion
  - loop-carried values include `(doneFlag, result)` (or whatever shape you pick)
  - IR verifies after the full Stage 2 pipeline.

3) **Nested `eco.case` inside `scf.while` regions**
- Construct a test where the loop step is computed by an `eco.case` (multi-way), then ends with `scf.yield`.
- This catches regressions in “case lowering under SCF” (the issue you’ve been fighting).
---
# What this design does *not* do (scope boundary)

- It does **not** convert non-tail recursion (e.g. your `Union` case in `be` where one `be` call is evaluated before calling `better`) into a loop. Those require CPS/defunctionalization or explicit continuation stacks; they are not “tail recursive calls” in the strict sense.
- It assumes the monomorphizer marks true tail recursion using `MonoTailFunc`/`MonoTailCall` (which already exist and are used by the current tail-call codegen) .
---
## Implementation order (so an engineer can land it safely)

1) Add `ecoYieldMany` + `scfYieldMany` in `Ops.elm`  
2) Add `TailRec.elm` and implement `compileTailFuncToWhile` using `Ops.scfWhile`/`Ops.scfCondition` 
3) Wire `Functions.elm` tail-recursive path to TailRec, replacing joinpoint+initial-jump generation 
4) Implement `compileStep` (tail call → continue state; return → done state)
5) Implement `MonoCase` step compilation as multi-result `eco.case` returning the full loop-state tuple (this is the “complex ones” piece)
6) Ensure Stage 2 pipeline lowers `eco.case` under `scf.yield` (per your pass guarantee) 
7) Ensure SCF→CF happens before CF-style Eco lowering
8) Add regression tests
If you paste your current `Functions.elm` tail-function entry point (the function that receives `MonoTailFunc` / `MonoTailDef` and emits the `func.func` region), I can turn steps (2)–(5) into a concrete patch-style diff against your exact code structure.
