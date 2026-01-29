# Variant A (recommended): **Mono IR Inliner + Simplifier** (Elm-side, before MLIR generation)
## Goal
Reduce/eliminate higher-order “pipeline plumbing” (like your `AdHoc` encoding) **before** it becomes ECO closures/PAPs. This is the easiest way to avoid generating `eco.papCreate`/`eco.papExtend` in the first place.
This pass runs **after monomorphization** (which is already the chosen strategy for performance ) and **before MLIR generation** (which otherwise hoists lambdas and emits ECO ops ).
## Placement in pipeline
Today MLIR generation is kicked off in `Compiler.Generate.MLIR.Backend.generateMlirModule`  (called by that backend’s `generate`). We will insert:
> `monoGraphOptimized = MonoInlineSimplify.optimize monoGraph`

…before building signatures / generating nodes.
> `monoGraphOptimized = MonoInlineSimplify.optimize monoGraph`

…before building signatures / generating nodes.
---
## A1. New module: Mono inliner/simplifier pass
### Change 1 — **Add new file**
**File:** `compiler/src/Compiler/Optimize/MonoInlineSimplify.elm` *(new)*  
**Purpose:** Implement a fixpoint optimizer over `Mono.MonoGraph` (or per-node expressions), supporting:
- small-function inlining (with recursion guard)
- beta-reduction of immediate lambdas
- let-sinking/let-elimination
- dead code elimination
- small case simplifications
**File:** `compiler/src/Compiler/Optimize/MonoInlineSimplify.elm` *(new)*  
**Purpose:** Implement a fixpoint optimizer over `Mono.MonoGraph` (or per-node expressions), supporting:
- small-function inlining (with recursion guard)
- beta-reduction of immediate lambdas
- let-sinking/let-elimination
- dead code elimination
- small case simplifications
**Implementation design (structured, implementable):**
#### Public API
- `optimize : Mode.Mode -> TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> Mono.MonoGraph`
  - `Mode.Mode` is already threaded in MLIR backend config ; you’ll likely want “more aggressive in prod”.
  - `TypeEnv` may be optional; include if you want name-based whitelisting (e.g. identify `AdHoc.wrap`), but you can do purely structural too.
#### Internal steps
1) **Build call graph of specializations**
   - Walk each `MonoNode` body, collect edges `callerSpecId -> calleeSpecId` for direct calls.
   - Compute SCCs (Tarjan/Kosaraju) and mark recursive specIds.
   - Extrapolation: you’ll use `Mono.MonoGraph { nodes : Dict SpecId MonoNode, ... }` as described in theory .

2) **Compute cost model for each callee**
   - `cost = nodeCount(expr)` (or weighted: calls=5, case=3, alloc=3, literals=1).
   - Add special casing: “AlwaysInline” for specific known small combinators (you can key on `Global` name), such as `AdHoc.impl/wrap/add/map/init`. (This is optional but very effective.)

3) **Rewrite each function body with a fixpoint loop**
   For each non-recursive function body:
   - repeat up to N iterations (e.g. 4) or until no changes:
     - `expr := rewrite(expr)`
     - `expr := dce(expr)`
     - `expr := simplifyLets(expr)`

4) **Key rewrite rules**
   - **Beta-reduction**: `( (\x -> body) arg )` becomes `let x = arg in body`
     - Must preserve strictness: evaluate `arg` once, bind to temp.
   - **Inline direct calls**: `call @specId(args)`:
     - If callee is inlineable and not recursive:
       - alpha-rename callee locals
       - bind parameters to argument temporaries
       - splice callee body
   - **Let simplification**:
     - `let x = v in body` where `x` not used → drop
     - `let x = y in body` (y is var/lit) → substitute
     - `let x = (pure-ish expr)` used once → substitute if below “triviality threshold”
   - **Case simplification**:
     - If scrutinee is known constructor/literal, choose branch.
     - If both branches equal, collapse.
   - **(Optional) “pipeline run” recognizer**:
     - If you see something structurally equivalent to `init (\raise rep -> raise rep)` patterns, you can force inlining regardless of thresholds.

5) **Safety checks**
   - Don’t inline across module boundaries if that breaks debug naming (optional).
   - Don’t inline if it would exceed per-function budget (avoid explosion).
---
## A2. Wire the Mono optimizer into the MLIR backend
### Change 2 — **Edit existing file**
**File:** `compiler/src/Compiler/Generate/MLIR/Backend.elm`  
**Where:** in `generateMlirModule`, just after destructuring the `Mono.MonoGraph`.
Currently it starts by building signatures from `nodes` . Modify to:
1) run the optimizer pass
2) then proceed with signatures / codegen on the optimized graph

**Write-up of change:**
- The backend currently generates MLIR from the monomorphized graph and then hoists lambdas `Lambdas.processLambdas` . By optimizing earlier, we reduce closure/PAP emission pressure and give the rest of codegen a simpler program.

**Pseudo-diff (English):**
- Add import:
  - `import Compiler.Optimize.MonoInlineSimplify as MonoInlineSimplify`
- In `generateMlirModule mode typeEnv monoGraph0`:
  - `let monoGraph = MonoInlineSimplify.optimize mode typeEnv monoGraph0`
  - then destructure nodes/main/registry/ctorLayouts from `monoGraph` (not `monoGraph0`)
1) run the optimizer pass
2) then proceed with signatures / codegen on the optimized graph

**Write-up of change:**
- The backend currently generates MLIR from the monomorphized graph and then hoists lambdas `Lambdas.processLambdas` . By optimizing earlier, we reduce closure/PAP emission pressure and give the rest of codegen a simpler program.

**Pseudo-diff (English):**
- Add import:
  - `import Compiler.Optimize.MonoInlineSimplify as MonoInlineSimplify`
- In `generateMlirModule mode typeEnv monoGraph0`:
  - `let monoGraph = MonoInlineSimplify.optimize mode typeEnv monoGraph0`
  - then destructure nodes/main/registry/ctorLayouts from `monoGraph` (not `monoGraph0`)
1) run the optimizer pass
2) then proceed with signatures / codegen on the optimized graph

**Write-up of change:**
- The backend currently generates MLIR from the monomorphized graph and then hoists lambdas `Lambdas.processLambdas` . By optimizing earlier, we reduce closure/PAP emission pressure and give the rest of codegen a simpler program.

**Pseudo-diff (English):**
- Add import:
  - `import Compiler.Optimize.MonoInlineSimplify as MonoInlineSimplify`
- In `generateMlirModule mode typeEnv monoGraph0`:
  - `let monoGraph = MonoInlineSimplify.optimize mode typeEnv monoGraph0`
  - then destructure nodes/main/registry/ctorLayouts from `monoGraph` (not `monoGraph0`)
1) run the optimizer pass
2) then proceed with signatures / codegen on the optimized graph

**Write-up of change:**
- The backend currently generates MLIR from the monomorphized graph and then hoists lambdas `Lambdas.processLambdas` . By optimizing earlier, we reduce closure/PAP emission pressure and give the rest of codegen a simpler program.

**Pseudo-diff (English):**
- Add import:
  - `import Compiler.Optimize.MonoInlineSimplify as MonoInlineSimplify`
- In `generateMlirModule mode typeEnv monoGraph0`:
  - `let monoGraph = MonoInlineSimplify.optimize mode typeEnv monoGraph0`
  - then destructure nodes/main/registry/ctorLayouts from `monoGraph` (not `monoGraph0`)
1) run the optimizer pass
2) then proceed with signatures / codegen on the optimized graph

**Write-up of change:**
- The backend currently generates MLIR from the monomorphized graph and then hoists lambdas `Lambdas.processLambdas` . By optimizing earlier, we reduce closure/PAP emission pressure and give the rest of codegen a simpler program.

**Pseudo-diff (English):**
- Add import:
  - `import Compiler.Optimize.MonoInlineSimplify as MonoInlineSimplify`
- In `generateMlirModule mode typeEnv monoGraph0`:
  - `let monoGraph = MonoInlineSimplify.optimize mode typeEnv monoGraph0`
  - then destructure nodes/main/registry/ctorLayouts from `monoGraph` (not `monoGraph0`)
---
## A3. Add regression tests for Variant A

You have an existing testing approach for ECO dialect and MLIR lowering and an E2E harness described in the plan . For this pass, you want tests at two levels:
### Change 3 — **Add Elm compiler test** *(recommended)*
**File:** `compiler/tests/.../MonoInlineSimplifyAdHocTest.elm` *(new; exact folder depends on your test layout)*  
**Purpose:** compile an Elm module containing a small `AdHoc`-style pipeline and assert:
- compilation succeeds
- (optional) dump MLIR and check that the number of `eco.papCreate` / `eco.papExtend` decreased
**File:** `compiler/tests/.../MonoInlineSimplifyAdHocTest.elm` *(new; exact folder depends on your test layout)*  
**Purpose:** compile an Elm module containing a small `AdHoc`-style pipeline and assert:
- compilation succeeds
- (optional) dump MLIR and check that the number of `eco.papCreate` / `eco.papExtend` decreased
If you already have invariant-based MLIR checks, integrate there (your invariant docs explicitly reason about PAP routing and closure machinery ).
### Change 4 — **Add an MLIR snapshot check** *(optional but powerful)*
If your test runner can capture emitted MLIR text, add a golden check:
- Before: contains `eco.papExtend`
- After: fewer or none for the `fifo` path
If your test runner can capture emitted MLIR text, add a golden check:
- Before: contains `eco.papExtend`
- After: fewer or none for the `fifo` path
---
## A4. Summary: ALL code changes for Variant A

1. **NEW:** `compiler/src/Compiler/Optimize/MonoInlineSimplify.elm`  
   - Implements call graph, SCC recursion detection, cost model, rewrite engine, DCE/let-simplify.
2. **EDIT:** `compiler/src/Compiler/Generate/MLIR/Backend.elm`  
   - Import optimizer
   - Run optimizer before signatures/codegen .

3. **NEW:** at least one regression test file (Elm-side), plus optional MLIR golden output check.
