## USER
  Report: Why POST_005/POST_006 Don't Catch the MONO_018 Polymorphic Remnant Failures

  Test Results
  ┌──────────────────────────────────────┬────────┬────────┐
  │                 Test                 │ Passed │ Failed │
  ├──────────────────────────────────────┼────────┼────────┤
  │ PostSolveNonRegressionInvariantsTest │ 95     │ 0      │
  ├──────────────────────────────────────┼────────┼────────┤
  │ MonoCaseBranchResultTypeTest         │ 91     │ 4      │
  └──────────────────────────────────────┴────────┴────────┘
  MONO_018 Failures

  The 4 failing tests show polymorphic remnants in MonoType:

  Closure in case branch:
    resultType: MFunction [MInt] MInt
    inline type: MFunction [MInt] (MVar "a" CEcoValue)

  Case with list alias pattern:
    resultType: MList MInt
    inline type: MList (MVar "a" CEcoValue)

  Root Cause Analysis

  The Pipeline Flow:
  1. Solver produces nodeTypes (pre-PostSolve) with Can.Type
  2. PostSolve fixes up nodeTypes (post-PostSolve) with Can.Type
  3. TypedOptimized uses the fixed nodeTypes
  4. Monomorphization converts Can.Type to MonoType via canTypeToMonoType_preserveVars in KernelAbi.elm:212-216:
  Can.TVar name ->
      Mono.MVar name Mono.CEcoValue

  The Bug Class:
  Some Can.TVar placeholders are NOT being filled by PostSolve and pass through to monomorphization, where they become MVar _ CEcoValue.

  Why POST_005/POST_006 Don't Catch This

  POST_005/POST_006 exempt bare TVars because the design intent was:
  - PostSolve is ALLOWED to fill placeholder TVars
  - Only catch when PostSolve changes a structured type to a more polymorphic one

  The exemption logic in checkPost006:
  Can.TVar _ ->
      -- Pre-type is a bare TVar placeholder
      -- PostSolve is allowed to fill it with any type
      acc

  The Gap:
  POST_005/POST_006 catch issue A but not issue B:
  ┌───────┬──────────────────────────────────────────────────┬──────────────────────────────┬───────────────────────┐
  │ Issue │                   Description                    │           Example            │      Caught by        │
  │       │                                                  │                              │     POST_005/006?     │
  ├───────┼──────────────────────────────────────────────────┼──────────────────────────────┼───────────────────────┤
  │ A     │ PostSolve overwrites structured type with        │ List Int → List a            │ ✅ Yes                │
  │       │ polymorphic                                      │                              │                       │
  ├───────┼──────────────────────────────────────────────────┼──────────────────────────────┼───────────────────────┤
  │ B     │ Bare TVar remains unfilled when it should be     │ TVar "a" → TVar "a"          │ ❌ No                 │
  │       │ filled                                           │ (unchanged)                  │                       │
  └───────┴──────────────────────────────────────────────────┴──────────────────────────────┴───────────────────────┘
  The MONO_018 failures are Issue B: TVars that should have been resolved by PostSolve but weren't.

  Why Not Just Remove the Bare TVar Exemption?

  The original POST_005/POST_006 (before correction) attempted this and had 106 test failures because:
  - Accessors intentionally have polymorphic type { ext | field : a } -> a
  - Polymorphic function bodies legitimately contain TVars
  - Not all bare TVars are bugs

  Conclusion

  POST_005/POST_006 are correctly detecting the bug class they were designed for (Issue A: PostSolve overwriting structured types). The MONO_018 failures represent a different bug class (Issue B: unfilled TVar placeholders) that requires additional investigation into why PostSolve isn't filling these specific TVars.

===

Unsure whether PostSolveNonRegressionInvariantsTest should prevent MonoCaseBranchResultTypeTest failures.

Does PostSolveNonRegressionInvariantsTest need strengthening or is it the correct test to use ?

## ASSISTANT
PostSolveNonRegressionInvariantsTest is the *correct* test for what it’s currently asserting (POST_005/POST_006), but it is **not expected to prevent** the MONO_018 failures you’re seeing.

### Why it doesn’t (and shouldn’t) block MONO_018
MONO_018 is a **monomorphization-phase** invariant: for every `MonoCase ... resultType`, it checks that every branch expression’s `Mono.typeOf` equals `resultType` . If PostSolve leaves “placeholder” `Can.TVar`s in certain expression types, then later canonical→mono conversion can preserve them as `MVar _ CEcoValue` in some paths (e.g. kernel ABI conversion does exactly that: `Can.TVar name -> Mono.MVar name Mono.CEcoValue` ), which can create the type mismatch that MONO_018 detects.

But POST_005/POST_006 (as documented) intentionally *do not* assert “all bare TVars must be filled”:
- POST_005: if the *pre* type is **not** a bare `TVar`, then post must be alpha-equivalent (i.e. PostSolve must not rewrite already-structured solver types) .
- POST_006: post may not introduce **new free vars** vs pre (i.e. can’t make nodes *more polymorphic*) .

So if the solver produced `TVar a` and PostSolve leaves it as `TVar a`, **both POST_005 and POST_006 can still pass** by design, even if that was “supposed” to be filled for that expression category.

### What *should* catch “unfilled placeholder TVars”
If your issue is “a placeholder synthetic var survived PostSolve where it shouldn’t”, that maps much more directly to the *other* PostSolve invariants described in the docs:

- **POST_003: “No unconstrained synthetic variables remain after PostSolve”** — scan post-PostSolve NodeTypes for non-kernel expressions and assert no unconstrained synthetic vars remain (with explicit allowances only for kernel-related placeholders) .
- **POST_001: “Group B expressions get structural types”** — asserts that Group B nodes (list/tuple/record/lambda/etc) get their structural types computed post-solve rather than retaining solver placeholders , consistent with the PostSolve design described in the theory doc .

Those are the invariants that correspond to “this TVar should have been resolved”.

### Recommendation
- **Do not “strengthen” PostSolveNonRegressionInvariantsTest by removing the bare-TVar exemption**. That would conflate two different guarantees (non-regression vs completeness) and will likely reintroduce lots of expected polymorphism/placeholder cases (your earlier 100+ failures story).
- Instead, **add (or implement, if it’s only documented) a targeted PostSolve test for POST_003 and/or POST_001**:
  - POST_003 is the broad “no leftover synthetic placeholders in non-kernel node types” check .
  - POST_001 is narrower but may be easier to make precise: only assert this for Group B expression ids (where PostSolve is explicitly responsible for structural typing) .

That way:
- PostSolveNonRegressionInvariantsTest continues to ensure PostSolve never makes the solver’s structured results “more polymorphic” .
- A separate PostSolve completeness test ensures the specific “Issue B” placeholders don’t survive and later trip MONO_018 .

If you want, paste the exact failing MonoCaseBranchResultTypeTest diff (the branch `resultType` vs inline expr type), and I can suggest how to categorize the originating node ids so POST_001/POST_003 can catch *exactly* those cases without hitting legitimate polymorphism.

## USER
POST_003 is the broad “no leftover synthetic placeholders in non-kernel node types” check .
POST_001 is narrower but may be easier to make precise: only assert this for Group B expression ids (where PostSolve is explicitly responsible for structural typing) .

What test logic do we have for these invariants ?

## ASSISTANT
For **POST_001** and **POST_003**, the project currently has **documented test logic** (in `design_docs/invariant-test-logic.md`), but (unlike POST_005/POST_006) it does **not** list an existing concrete `compiler/tests/...` test file for them. The only PostSolve test file explicitly referenced there is `PostSolveNonRegressionInvariantsTest.elm`, and it’s referenced for POST_005/POST_006 .

## POST_001 — “Group B expressions get structural types”
**What we have (specified logic):**
- **Identify Group B expressions** (lists, tuples, records, units, lambdas) where the **pre-PostSolve** solver type includes “unconstrained synthetic variables”.
- After PostSolve:
  - **Assert those entries are replaced with concrete `Can.Type` structures**
  - **Reconstruct the type structurally from subexpression types** and compare it to PostSolve’s type 

**Inputs / oracle (as documented):**
- **inputs:** “TypedCanonical + pre-/post-PostSolve NodeTypes snapshots”
- **oracle:** “No Group B expression retains an unconstrained synthetic var; recomputed structural type matches PostSolve’s result.” 

So POST_001 is envisioned as a *precision* check: “for the subset of nodes PostSolve is responsible for (Group B), PostSolve must compute the structural type and it must match what you’d recompute from children.”

## POST_003 — “No unconstrained synthetic variables remain after PostSolve”
**What we have (specified logic):**
- Scan **post-PostSolve NodeTypes** for **non-kernel expressions**:
  - Assert all types contain **no unconstrained synthetic vars**
  - For placeholder kinds that remain “by design” (kernel-related), assert they’re **limited to kernel expressions** 

**Inputs / oracle (as documented):**
- **inputs:** “PostSolve NodeTypes maps from many modules”
- **oracle:** “NodeTypes is fully concrete for non-kernel expressions; any remaining synthetic variables are flagged as a violation.” 

So POST_003 is the *broad* “no leftover placeholders” sweep, but with an explicit carveout for kernel-related placeholders—*and it requires you to classify which expression IDs are “kernel expressions”*.

## What’s missing / implied (extrapolation)
The docs don’t define:
- the exact predicate for “unconstrained synthetic variable” in `Can.Type`, or
- the exact traversal/classification mechanism for “kernel expressions” (though POST_005/006 mention traversing the canonical module and classifying node ids as VarKernel/Accessor/other ).

So the invariants are specified, but implementing POST_001/POST_003 as tests will require you to codify:
- `containsUnconstrainedSyntheticVars : Can.Type -> Bool`
- `isKernelExprId : CanonicalModule -> NodeId -> Bool` (or a richer classification)

If you want, I can sketch a concrete implementation plan for each (data you already have in `Solve.runWithIds` + `PostSolve.postSolve`, plus a Canonical AST walk), but that part would be extrapolation beyond what’s explicitly written in the invariant doc.

## USER
We need better test logic for POST_001 and POST_003.

Write this up as a full design that an engineer could follow to implement it.

Make sure to provide ALL code changes needed, and for each one be clear about where in the code it needs to go as well as giving a brief write up explaining the change.

## ASSISTANT
Below is a concrete, “engineer-ready” design to implement **strong, targeted invariant tests for POST_001 and POST_003**, including **all required code changes**, where they go, and why.

This design is built around two facts in the current codebase:

1. **PostSolve’s spec** is explicitly: fill in “missing” types for **Group B** expressions and infer kernel types , and the invariants for POST_001/POST_003 are already described in `design_docs/invariant-test-logic.md` .
2. The typed constraint generator already distinguishes Group A vs Group B, and explicitly says Group B uses the “generic path that allocates a synthetic exprVar” . Today, we *throw away* that provenance by only returning `NodeVarMap` (ID → variable) .

The key improvement is therefore: **preserve “this ID’s solver variable was synthetic” metadata** so tests can precisely detect “unfilled placeholders” (Issue B).

---

## High-level goals

### POST_001 (improved)
Verify that for Group B expressions whose **solver output still contains a synthetic placeholder**, PostSolve replaces that placeholder with the **structural type implied by the AST + children’s types** (List, Tuple, Record, Lambda, Accessor, Let family, etc.) .

### POST_003 (improved)
Verify that after PostSolve, **no unresolved synthetic placeholders** remain in any **non-kernel expression type** anywhere in the type tree (not just top-level). This directly targets the MONO_018 “polymorphic remnant” class (Issue B).

---

# Part A — Minimal compiler plumbing to expose “synthetic placeholder” provenance

## Change A1 — Extend `NodeIds.NodeIdState` to record synthetic expr IDs

**File:** `compiler/src/Compiler/Type/Constrain/Typed/NodeIds.elm`

**Why:**
`NodeIdState` currently only tracks `{ mapping : NodeVarMap }` . We need to know which IDs were recorded via the Group B generic path (synthetic placeholder allocation) .

**What to change:**
1. Add a new field to `NodeIdState`:
   - `syntheticExprIds : Set Int` (or `Dict Int ()`; pick whichever is standard in your codebase)

2. Add a new recording function for Group B generic path:
   - `recordSyntheticExprVar : Int -> IO.Variable -> NodeIdState -> NodeIdState`

3. Keep `recordNodeVar` unchanged for all existing call sites (patterns, Group A, etc.)

**Sketch:**
```elm
module Compiler.Type.Constrain.Typed.NodeIds exposing
    ( NodeVarMap, NodeIdState
    , emptyNodeIdState
    , recordNodeVar
    , recordSyntheticExprVar
    )

import Data.Map as Dict exposing (Dict)
import Data.Set as Set exposing (Set)   -- or your Set module
import System.TypeCheck.IO as IO

type alias NodeVarMap =
    Dict Int Int IO.Variable

type alias NodeIdState =
    { mapping : NodeVarMap
    , syntheticExprIds : Set Int
    }

emptyNodeIdState : NodeIdState
emptyNodeIdState =
    { mapping = Dict.empty
    , syntheticExprIds = Set.empty
    }

recordNodeVar : Int -> IO.Variable -> NodeIdState -> NodeIdState
recordNodeVar id var state =
    if id >= 0 then
        { state | mapping = Dict.insert identity id var state.mapping }
    else
        state

recordSyntheticExprVar : Int -> IO.Variable -> NodeIdState -> NodeIdState
recordSyntheticExprVar id var state =
    if id >= 0 then
        { state
            | mapping = Dict.insert identity id var state.mapping
            , syntheticExprIds = Set.insert id state.syntheticExprIds
        }
    else
        state
```

**Impact:**
- No production pipeline behavior changes; just richer metadata.

---

## Change A2 — Mark Group B “generic” expression vars as synthetic during constraint generation

**File:** `compiler/src/Compiler/Type/Constrain/Typed/Expression.elm`

**Why:**
The generic Group B path is exactly where we allocate the synthetic placeholder variable . That’s the provenance we need.

**What to change:**
In `constrainGenericWithIdsProg`, replace the existing:

```elm
Prog.opModifyS (NodeIds.recordNodeVar info.id exprVar)
```

with:

```elm
Prog.opModifyS (NodeIds.recordSyntheticExprVar info.id exprVar)
```

This is the single most important code change.

**Reference:** the generic-with-IDs path allocates `exprVar` and records it .

---

## Change A3 — Add a “detailed” constraint-generation entry point that returns NodeIdState (not just mapping)

**File:** `compiler/src/Compiler/Type/Constrain/Typed/Module.elm`

**Why:**
The production compile pipeline expects `(Constraint, NodeVarMap)` and then calls `Solve.runWithIds` , which converts that `nodeVars` map using `Type.toCanType` .

We need a testing-only entry point that returns the full `NodeIdState` so tests can access `.syntheticExprIds`, while keeping the existing API stable.

**What to change:**
1. Keep existing:
```elm
constrainWithIds : Can.Module -> IO ( Constraint, NodeIds.NodeVarMap )
```

2. Add:
```elm
constrainWithIdsDetailed : Can.Module -> IO ( Constraint, NodeIds.NodeIdState )
```

3. Implement `constrainWithIds` as a projection of the detailed version:
```elm
constrainWithIds canonical =
    constrainWithIdsDetailed canonical
        |> IO.map (\( con, state ) -> ( con, state.mapping ))
```

**Reference:** Module currently returns `( con, state.mapping )` .

---

## Change A4 — Update documentation to point to new tests (optional but recommended)

**File:** `design_docs/invariant-test-logic.md`

**Why:**
Today, only POST_005/006 list a concrete test file. Add lines for POST_001 and POST_003 “tests:” entries so it’s discoverable .

**What to change:**
Under POST_001 and POST_003 blocks, add:

- `tests: compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`
- `tests: compiler/tests/Compiler/Type/PostSolve/PostSolveNoSyntheticHolesTest.elm`

---

# Part B — Implementing POST_001 test: “Group B expressions get structural types”

## New file B1 — `PostSolveGroupBStructuralTypesTest.elm`

**File:** `compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`

### Inputs
- A corpus of canonical modules (whatever the existing PostSolveNonRegression tests use), or a curated set of Elm snippets compiled to `Can.Module`.

### Pipeline to run inside the test
For each module:
1. `TypeTyped.constrainWithIdsDetailed canonical` → `(constraint, nodeState)`
2. `Solve.runWithIds constraint nodeState.mapping` → `Ok { annotations, nodeTypes = nodeTypesPre }` 
3. `PostSolve.postSolve annotations canonical nodeTypesPre` → `nodeTypesPost` 

### Identify *which* Group B expression IDs to check
Use `nodeState.syntheticExprIds` (from Change A1/A2), but filter to those that are actually **problematic** pre-PostSolve:

- For each `exprId ∈ syntheticExprIds`:
  - Let `preType = nodeTypesPre[exprId]`
  - If `preType` is `Can.TVar _`, that indicates the solver left a placeholder hole for that expression.
  - (Optionally also include cases where `preType` contains that same placeholder var nested; but the primary signal is top-level `TVar` for Group B holes.)

Now also ensure the exprId corresponds to a **Group B expression** by traversing the Canonical AST (Group B nodes are enumerated in the PostSolve theory and implementation: Str/Chr/Float/Unit/List/Tuple/Record/Lambda/Accessor/Let/LetRec/LetDestruct  ).

### Structural recomputation oracle
For each such Group B expression node, compute `expectedType` using only:
- the expression AST node, and
- `nodeTypesPost` of its subexpressions / patterns

The expected structural rules should match the documented behavior in PostSolve itself:

- **Str**: `Can.TType ModuleName.string Name.string []`   
- **Chr**: `Can.TType ModuleName.char Name.char []`   
- **Float**: `Can.TType ModuleName.basics Name.float []`   
- **Unit**: `Can.TUnit`   
- **List**:
  - if empty: element `Can.TVar "a"`
  - else: element = `nodeTypesPost[firstElemId]`
  - type = `Can.TType ModuleName.list Name.list [ elemType ]` 
- **Tuple**: `Can.TTuple aType bType csTypes` 
- **Record**: `Can.TRecord fieldTypes Nothing` where fieldTypes uses `Can.FieldType 0 tipe` 
- **Lambda**: `List.foldr Can.TLambda bodyType argTypes` 
- **Accessor**: `{ ext | field : a } -> a` (with `ext` and `a`) 
- **Let/LetRec/LetDestruct**: expression type must equal body type 

Then assert:

- `nodeTypesPost[exprId] == expectedType` (or alpha-equivalent if you want to be robust).

**Note:** You are *not* calling `PostSolve.postSolveList` etc; you’re rebuilding a type value in test code using the spec rules above. It will still look similar to PostSolve code, but it’s a separate implementation.

---

# Part C — Implementing POST_003 test: “No unconstrained synthetic variables remain after PostSolve”

## New file C1 — `PostSolveNoSyntheticHolesTest.elm`

**File:** `compiler/tests/Compiler/Type/PostSolve/PostSolveNoSyntheticHolesTest.elm`

### Pipeline
Same as POST_001:
1. constrainWithIdsDetailed → `(constraint, nodeState)`
2. Solve.runWithIds → `nodeTypesPre`
3. PostSolve.postSolve → `nodeTypesPost`

### Compute the set of “hole variable names” produced by the solver
We only want *synthetic holes*, not all TVars.

Define:

- `holeVarNames : Set String`
- For each `exprId ∈ nodeState.syntheticExprIds`:
  - `preType = nodeTypesPre[exprId]`
  - If `preType` is `Can.TVar name`, insert `name` into `holeVarNames`.

This “learns” which solver TVars were actually left unresolved specifically at the synthetic Group B sites.

### Classify which expression IDs are allowed to still mention hole vars
POST_003 explicitly allows kernel-related placeholders to remain only in kernel expressions .

So, traverse the Canonical AST and build:
- `kernelExprIds : Set Int` = IDs where the node is `Can.VarKernel _ _` (PostSolve’s `isKernelExpr` already matches exactly this ).

Optionally, if you discover kernel-specific exceptions later (e.g. “VarKernel with unknown type until inferred”), this set is where you add those exemptions.

### For each *expression* ID, assert no hole vars remain (unless kernel expr)
Now traverse all expression nodes in the canonical module. For each `exprId`:

- `postType = nodeTypesPost[exprId]` (must exist; TYPE_003 already asserts coverage for >=0 IDs)
- If `exprId ∉ kernelExprIds`:
  - Assert: `freeVars(postType) ∩ holeVarNames == ∅`

You can implement `freeVars` using the same traversal pattern already used elsewhere in the codebase, e.g. KernelAbi’s helper which walks `Can.Type` and collects TVars .

This is the check that will catch the MONO_018 “remnant TVar becomes MVar” pathway, because it flags a solver-hole var even if it appears nested inside a function return, list element, etc.

---

# Part D — Practical details engineers will need

## D1 — Canonical AST traversal utilities (shared test helper recommended)

Create a small internal test helper module, e.g.:

**File:** `compiler/tests/Compiler/Type/PostSolve/PostSolveInvariantHelpers.elm` (new)

Include:
- `walkExprs : Can.Module -> List Can.ExprInfo` (or `(id, node)` pairs)
- `walkDecls`, `walkDefs`, `walkPatterns` as needed
- `isGroupBExprNode : Can.Expr_ -> Bool` matching PostSolve’s Group B cases 
- `isVarKernel : Can.Expr_ -> Bool` matching PostSolve’s kernel check 
- `freeVars : Can.Type -> Set String` (based on KernelAbi’s traversal )

This makes both tests smaller and less error-prone.

## D2 — How to get test modules to run through solver + PostSolve
You already have a production function that runs typed typechecking and PostSolve:

- `Compile.typeCheckTyped` uses `TypeTyped.constrainWithIds`, then `Type.runWithIds`, then `PostSolve.postSolve` .

However, for these invariants you specifically need `constrainWithIdsDetailed` (new) to access `syntheticExprIds`. So the tests should call the lower-level pipeline directly (constraint gen → solve → PostSolve), rather than `Compile.typeCheckTyped`.

---

# Part E — Summary: Full code change checklist

### Compiler (production) code changes
1. **Modify** `compiler/src/Compiler/Type/Constrain/Typed/NodeIds.elm`
   - Add `syntheticExprIds` field to `NodeIdState`
   - Add `recordSyntheticExprVar`
   - Update `emptyNodeIdState` accordingly 

2. **Modify** `compiler/src/Compiler/Type/Constrain/Typed/Expression.elm`
   - In `constrainGenericWithIdsProg`, call `NodeIds.recordSyntheticExprVar` instead of `recordNodeVar` 

3. **Modify** `compiler/src/Compiler/Type/Constrain/Typed/Module.elm`
   - Add `constrainWithIdsDetailed : Can.Module -> IO (Constraint, NodeIdState)`
   - Keep `constrainWithIds` API stable by projecting `state.mapping` 

4. **(Recommended) Modify** `design_docs/invariant-test-logic.md`
   - Add `tests:` entries for POST_001 and POST_003 

### New test files
5. **New** `compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`
   - Implements POST_001 with structural recomputation 

6. **New** `compiler/tests/Compiler/Type/PostSolve/PostSolveNoSyntheticHolesTest.elm`
   - Implements POST_003 with “no hole vars in non-kernel expr types” 

7. **New (optional but recommended)** `compiler/tests/Compiler/Type/PostSolve/PostSolveInvariantHelpers.elm`
   - AST traversal + `freeVars` helper (based on KernelAbi traversal) 

---

## One known risk + mitigation (engineer note)
POST_003 uses “hole var names” extracted from `nodeTypesPre[exprId]` where it’s a `Can.TVar name`. If your solver’s `Type.toCanType` happens to name a synthetic hole `"a"` (colliding with PostSolve’s own `"a"` used in empty list/accessor logic ), you could get false positives.

**Mitigation if this occurs in practice:**
- Refine hole collection to include only names that match the solver’s “generated var naming convention” (if any exists), or
- Extend the solver conversion path to emit a reserved prefix for unconstrained vars coming from `syntheticExprIds` (bigger change; only do if needed).

If you want, paste a real `nodeTypesPre` dump for one failing module and we can decide whether collisions are plausible in your current naming scheme.

## USER
Ok the new tests for POST_001 and POST_003 passed.

Precise Test Descriptions

  POST_001: Group B Structural Types Test

  What is tested:

  For each expression ID that was recorded as a "synthetic" Group B expression during constraint generation (via recordSyntheticExprVar), where the solver's pre-PostSolve type was a bare TVar placeholder:

  1. The test retrieves the post-PostSolve type for that expression
  2. The test computes the expected structural type based on:
    - The expression's AST node type (Str, List, Tuple, Record, Let, etc.)
    - The post-PostSolve types of its child expressions
  3. The test asserts the post-PostSolve type is alpha-equivalent to the expected structural type

  Group B expressions covered: Str, Chr, Float, Unit, List, Tuple, Record, Lambda, Accessor, Let, LetRec, LetDestruct

  Skipped cases: Lambda and Accessor are skipped because their structural types are complex/polymorphic and harder to recompute precisely.

  ---
  POST_003: No Synthetic Holes Test

  What is tested:

  1. The test computes "hole variable names" by:
    - Taking all expression IDs recorded as synthetic during constraint generation
    - Filtering to those whose pre-PostSolve type is a bare TVar
    - Further filtering to only numeric TVar names (e.g., "0", "42") since solver-generated placeholders use numeric names while legitimate polymorphic TVars use alphabetic names
  2. For every expression in the module (excluding VarKernel expressions):
    - The test extracts all free type variable names from the post-PostSolve type
    - The test asserts that none of these free variables are in the "hole variable names" set

  What this catches: Any solver-generated placeholder TVar that was left unfilled by PostSolve, even when nested inside a larger type structure (e.g., List [TVar "42"]). This directly targets the MONO_018 "polymorphic remnant" bug class where unfilled TVars escape to monomorphization.

These all passed and did not catch any of the MONO_018 polymorphic remnants.

## ASSISTANT
The fact that your new **POST_001**/**POST_003** tests pass strongly suggests the MONO_018 “polymorphic remnant” failures are **not coming from the specific hole class you’re currently targeting** (“solver-generated numeric TVars on *synthetic Group B expr ids* that remain after PostSolve”).

Given the symptoms you reported earlier (remnant is specifically `MVar "a" CEcoValue`), there are three high-probability explanations.

## 1) Your POST_003 “hole name” classifier is probably excluding the real holes

You filtered hole var names to “numeric TVar names” under the assumption solver placeholders are numeric. But the repo clearly has infrastructure to generate **alphabetic** type var names (`a`, `b`, … with suffixes) via `fromTypeVariableScheme` . If `Solve.runWithIds` / `Type.toCanType` is using scheme-style names, then the exact “holes that leak” could be `"a"`, `"b"`, etc., and your hole set becomes empty — so POST_003 vacuously passes.

**Concrete next step (quick validation):**
- Print/log (in the test) the list of `(exprId, preType)` for syntheticExprIds where `preType` is `Can.TVar name`.
- If you see names like `"a"`/`"b"` instead of `"0"`/`"42"`, your POST_003 filter is definitely missing the holes.

**Fix direction:** remove the numeric-only filter and instead:
- treat *any* `Can.TVar name` that appears as the **entire preType** of a synthetic Group B expr as a “hole name” (this was already the core logic—just drop the numeric restriction).
- then add *targeted exemptions* for the known intentional PostSolve-introduced TVars (see point #2).

This aligns with the intent of POST_003 in the invariant doc (“use syntheticExprIds from constraint generation to identify which TVars were solver-allocated placeholders”) .

## 2) Some TVars are intentionally introduced by PostSolve (so your test may be “correct” to ignore them, but they can still trigger MONO_018 if monomorphization fails to instantiate them)

Two places in PostSolve explicitly synthesize `Can.TVar "a"`:

- **Accessor types**: `.field` is assigned `{ ext | field : a } -> a` via `Can.TVar "a"` and record ext `"ext"` .
- **Kernel arg propagation fallback**: extra arg slots get a default `Can.TVar "a"` .

Those are *not* “solver holes” and will not be in your synthetic-hole name set (because they aren’t coming from preType bare TVars on synthetic IDs). So POST_003 can pass even if `"a"` appears post-PostSolve.

However, MONO_018 failing because a branch’s type is `... (MVar "a" CEcoValue)` while the case result is concrete means:
- either that `"a"` is being used in a position that **should have been instantiated/specialized away** before/during monomorphization, or
- different parts of monomorphization are using **inconsistent type sources** (see #3).

So: POST_003 passing does **not** rule out PostSolve as the *origin* of a `"a"` TVar, because PostSolve intentionally introduces `"a"` in some nodes (especially accessors) .

## 3) The leak might not be in PostSolve’s `nodeTypes` at all — it could be a “type source mismatch” later

Your POST tests only examine the PostSolve `nodeTypes` map. But MONO_018 failures are about **types attached to monomorphized expressions** (`Mono.typeOf branchExpr == resultType` per invariant MONO_018 ).

So a very plausible failure mode is:

- PostSolve fixed `nodeTypes[exprId]` correctly, but
- some later phase (TypedCanonical → TypedOptimized or monomorphization) is *not* consistently using the fixed `exprTypes` and instead is using a cached/inline type that still contains a TVar.

This would neatly explain:
- why POST_001/POST_003 (nodeTypes-focused) pass, yet
- MONO_018 sees a polymorphic remnant “inline type”.

### What to do next (pinpointing step)
Pick one failing MONO_018 case and identify the *canonical expression id* of:
- the case expression (for `resultType`)
- the problematic branch expression or inline expression

Then check whether **PostSolve nodeTypesPost** for those ids contain the TVar `"a"` or not.

You’ll get a binary answer:

- **If nodeTypesPost already contains the offending `Can.TVar "a"`**: this is still a PostSolve/type-fixing gap (and your POST_003 is likely missing the hole naming, per #1, or the source is a skipped node class like Lambda/Accessor, per your POST_001 skips and Group B definition ).
- **If nodeTypesPost is concrete but Mono still has `MVar "a"`**: then you need a *new invariant* at the boundary where types are attached to later IR:
  - “the type stored on each typed/optimized node must equal `exprTypes[id]` from PostSolve”
  - and/or “monomorphization must only use PostSolve-fixed types as its input”.

## Two concrete improvements that are very likely to make the POST tests relevant to MONO_018

1) **Stop skipping Accessor in POST_001**  
Accessor is actually *easy* to check precisely because PostSolve always assigns the same shape `{ ext | field : a } -> a` . You can assert that exact structure (alpha-eq) for synthetic accessor ids whose preType was bare TVar. That closes a big hole you explicitly left open.

2) **Expand POST_003 to cover patterns (or track synthetic pattern ids too)**  
`NodeTypes` is described as mapping expression/**pattern** IDs to types , but your synthetic tracking is currently only for expressions. The “list alias pattern” MONO failure you mentioned earlier is a huge hint that the leaking TVar may originate from a **pattern id**, not an expression id. If pattern types remain polymorphic incorrectly, they can infect the types of locals bound by destructuring and then show up in case branches.

That would also explain why POST_001/POST_003 (expr-centric) didn’t catch it.

---

If you tell me (or paste) the *exact* `Can.ExprInfo.id` for one of the failing MONO_018 branch expressions + the case expression id, I can help you choose between “(A) strengthen POST_*” vs “(B) add a new TypedOptimized/Monomorphization boundary consistency invariant” with high confidence.

## USER
Skipped cases: Lambda and Accessor are skipped because their structural types are complex/polymorphic and harder to recompute precisely.

Yes, this. Lets extend the test case to cover these as well.

Write this up as a full design that an engineer could follow to implement it.

Make sure to provide ALL code changes needed, and for each one be clear about where in the code it needs to go as well as giving a brief write up explaining the change.

## ASSISTANT
Below is a concrete design to extend **POST_001 (Group B Structural Types Test)** so it also covers **Lambda** and **Accessor** (previously skipped because “complex/polymorphic”). The goal is to make these checks *precise* (low false positives) while still catching “PostSolve didn’t fill the placeholder TVar” bugs.

This design assumes you already have the POST_001 test implemented as described in your “Precise Test Descriptions”, using `syntheticExprIds` from constraint generation (`constrainWithIdsDetailed`)  and comparing post-PostSolve `nodeTypes` against recomputed expected structural types .

---

## Overview of what will change

1) **Stop skipping Lambda and Accessor** in `PostSolveGroupBStructuralTypesTest.elm`.

2) Add **precise expected-type recomputation** for:
- `Accessor field` → expected `{ ext | field : a } -> a` exactly matching PostSolve’s accessor type rule .
- `Lambda args body` → expected `arg1Type -> arg2Type -> ... -> bodyType`, using **pattern types** for args and expr type for body. This matches the intended “structural lambda type” computation described in PostSolve theory  (and is consistent with how typed optimization treats function types ).

3) Add (or tighten) helper utilities in the test to safely look up **pattern types** by pattern id (since lambda args are patterns). The compiler already treats negative IDs as synthetic and non-lookuppable ; for lambda parameters we should require non-negative IDs and fail loudly if we see otherwise.

4) Add (if needed) a small **test fixture module** that guarantees your corpus contains at least one “Group B lambda/accessor whose pre-PostSolve type was a bare TVar placeholder”, so coverage doesn’t depend on incidental code in other tests.

---

## Code changes (ALL required), file-by-file

### Change 1 — Extend POST_001 expected structural typing to include `Lambda` and `Accessor`

**File:** `compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`  
**Why:** POST_001 invariant explicitly includes lambdas (and your own Group B list includes accessors) but the current test skips them .

#### 1A) Remove the “skip Lambda/Accessor” filter

Find the part of the test that does something like:

- “if expr is Lambda/Accessor: skip”
- or “Group B covered: … minus Lambda/Accessor”

Delete that skip logic.

**Write-up:** This makes Lambda and Accessor participate in the same “preType is bare TVar placeholder → must be structurally filled post-PostSolve” rule as the rest of Group B.

#### 1B) Add expected-type recomputation for `Accessor`

Add a new case in your `expectedStructuralTypeForExpr` (or equivalent) function:

```elm
expectedStructuralTypeForExpr : Can.Expr -> NodeTypes -> Result String Can.Type
expectedStructuralTypeForExpr expr nodeTypesPost =
  case expr of
    A.At _ info ->
      case info.node of
        Can.Accessor fieldName ->
          Ok (expectedAccessorType fieldName)

        ...
```

Add helper:

```elm
expectedAccessorType : Name.Name -> Can.Type
expectedAccessorType fieldName =
    let
        fieldType = Can.TVar "a"
        recordType =
            Can.TRecord
                (Dict.singleton Basics.identity fieldName (Can.FieldType 0 fieldType))
                (Just "ext")
    in
    Can.TLambda recordType fieldType
```

This is intentionally aligned with the compiler’s actual PostSolve accessor logic, which constructs exactly this shape .

**Write-up:**  
Accessors *are* polymorphic by design, but they’re polymorphic in a *very specific, known* way: `{ ext | field : a } -> a` . That makes them one of the easiest “complex/polymorphic” cases to test precisely.

> Note: if you want the test to be resilient to renaming `"a"`/`"ext"`, keep using alpha-equivalence. If your current alpha-equivalence does **not** treat record extension vars as alpha-bindable, you should strengthen it (see Change 3).

#### 1C) Add expected-type recomputation for `Lambda`

Add a new case:

```elm
case info.node of
  Can.Lambda argPatterns bodyExpr ->
      expectedLambdaType argPatterns bodyExpr nodeTypesPost
```

Implement:

```elm
expectedLambdaType :
    List Can.Pattern
    -> Can.Expr
    -> NodeTypes
    -> Result String Can.Type
expectedLambdaType argPatterns body nodeTypesPost =
    let
        bodyTypeResult =
            lookupExprType "POST_001 lambda body" body nodeTypesPost

        argTypesResult =
            argPatterns
                |> traverseResult (\pat -> lookupPatternTypeStrict "POST_001 lambda arg" pat nodeTypesPost)
    in
    Result.map2 buildCurriedFunctionType argTypesResult bodyTypeResult
```

Then:

```elm
buildCurriedFunctionType : List Can.Type -> Can.Type -> Can.Type
buildCurriedFunctionType argTypes bodyType =
    List.foldr Can.TLambda bodyType argTypes
```

**How to look up arg pattern types:**

```elm
lookupPatternTypeStrict : String -> Can.Pattern -> NodeTypes -> Result String Can.Type
lookupPatternTypeStrict context (A.At _ patInfo) nodeTypesPost =
    if patInfo.id < 0 then
        Err (context ++ ": lambda parameter pattern has negative id, cannot lookup (unexpected)")

    else
        case Dict.get Basics.identity patInfo.id nodeTypesPost of
            Nothing ->
                Err (context ++ ": missing type for pattern id " ++ String.fromInt patInfo.id)

            Just tipe ->
                Ok tipe
```

This matches the compiler assumption that negative pattern IDs are synthetic and not in `exprTypes`/`nodeTypes` ; lambda parameters should not be such synthetic patterns.

**Write-up:**  
The lambda’s structural type is fully determined by the (post-PostSolve) types of its parameter patterns and its body expression, and should be a curried chain. This is exactly the kind of structural fill PostSolve is responsible for in Group B .

---

### Change 2 — Ensure the test only asserts Lambda/Accessor when they are actually “Group B synthetic placeholders”

**File:** `compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`  
**Why:** You do *not* want to assert every lambda/accessor in the module has the exact computed structural type unless it was specifically one of the recorded synthetic placeholders. The whole POST_001 design is scoped to the `recordSyntheticExprVar` / `syntheticExprIds` mechanism described in the invariants  and enabled by `constrainWithIdsDetailed` returning `syntheticExprIds` .

This is likely already what your test does:

- iterate `syntheticExprIds`
- filter to those where `preType == Can.TVar _` (bare placeholder)
- then assert `postType` matches expected structure

**No fundamental change is needed here**, but you must make sure:
- Lambda/Accessor expr IDs are included in the “Group B expression ids covered” set for POST_001 (they should be, by your own description).
- You do *not* add a new “skip if lambda/accessor is polymorphic” clause; polymorphism is allowed, but **must be the correct polymorphism**.

**Write-up:**  
This avoids the historical failure mode you mentioned where removing “bare TVar exemption” creates tons of failures from legitimate polymorphism. We are still only asserting types for expr IDs that *constraint generation itself recorded* as “synthetic Group B placeholder” nodes.

---

### Change 3 — (If needed) strengthen alpha-equivalence to treat record extension vars as alpha-bindable

**Files (choose one approach):**
- Preferably a shared test utility module if you have one, otherwise inside `PostSolveGroupBStructuralTypesTest.elm`.

**Why:** Accessor expected type has both:
- a TVar (`a`)
- and a record extension variable (`ext`) in `TRecord ... (Just "ext")` 

If your current alpha-equivalence only alpha-renames `TVar` names but compares record extension names literally, then accessor checks will be brittle and/or incorrect.

#### 3A) Implement `alphaEq : Can.Type -> Can.Type -> Bool` that also alpha-renames record extension vars

High-level rule:
- Treat record extension vars like type vars for alpha-equivalence purposes.

Pseudo-logic:
- Maintain a mapping `Dict String String` for type-var renames and another (or the same) mapping for record-ext renames.
- When comparing `TRecord fields maybeExt`:
  - compare fields pairwise
  - compare `maybeExt` by alpha mapping

**Write-up:**  
This makes the Accessor check stable even if PostSolve changes from `"ext"` to `"r"` etc, while still being strict about the structural shape.

> If you already have an alpha-equivalence helper used by POST_005/POST_006 style tests, consider reusing it here (those invariants are described as “alpha-equivalent” comparisons ).

---

### Change 4 — Add a dedicated fixture module to guarantee coverage (recommended)

If your existing module corpus doesn’t reliably produce synthetic placeholders for Lambda/Accessor, you can end up with “test passes but never exercised the new logic”.

**Add one small canonical Elm module** used only by the POST_001 tests.

**File (example):** `compiler/tests/fixtures/postsolve/Post001_LambdaAccessor.elm`  
(or wherever your test harness loads fixture modules)

Suggested contents (keep it tiny and deterministic):

```elm
module Post001_LambdaAccessor exposing (..)

type alias R = { x : Int }

-- Forces an accessor expression `.x` to exist as a value:
getX = .x

-- Forces a lambda expression to exist:
idInt = \x -> x

-- Ensures both are actually referenced:
use : R -> Int
use r =
    (getX r) + (idInt 1)
```

**Why this helps:**
- `.x` introduces a `Can.Accessor` expression whose type PostSolve sets to `{ ext | x : a } -> a` .
- `\x -> x` introduces a `Can.Lambda` whose type PostSolve should compute structurally from arg/body types .
- Referencing them avoids dead-code elimination removing them in pipelines that only typecheck reachable code (depends on your harness).

**Register the fixture in the test:**
- Wherever `PostSolveGroupBStructuralTypesTest` currently enumerates modules/programs to run, add this module to the list.

**Write-up:**  
This ensures the extended logic actually runs at least once, and failures are attributable to the lambda/accessor rules rather than test corpus variability.

---

## Expected behavior after these changes

- POST_001 will now precisely validate that, for recorded Group B synthetic placeholder IDs:
  - **Accessor** post-type is exactly the structural accessor function type (alpha-equivalent) .
  - **Lambda** post-type is a curried `TLambda` chain from param pattern types to body type .

This stays aligned with the original POST_001 intent documented in your invariant catalog  and avoids the “everything polymorphic is a bug” problem because it only applies to “recorded synthetic placeholder Group B nodes”.

---

If you paste your current `PostSolveGroupBStructuralTypesTest.elm` (or the part that computes expected structural types), I can turn the above into a patch-style diff with exact function names and insert points.

## USER
What on earth is this ? Change 4 — Add a dedicated fixture module to guarantee coverage (recommended)

That would be something we add to the test cases surely ?

## ASSISTANT
You’re right to call that out: that “fixture module” is not some production/compiler change. It’s **test input**.

What I meant by “Add a dedicated fixture module” is: add a *small Elm source program (or canonical AST)* that the POST_001 test compiles/typechecks specifically to ensure the new Lambda/Accessor assertions actually execute. That is absolutely “something we add to the test cases”.

There are two equivalent ways to do it, depending on how your test harness is set up.

---

## Option A (most common): add a new Elm source file under test fixtures, and compile it in the test

### What gets added
- A file like `compiler/tests/fixtures/postsolve/Post001_LambdaAccessor.elm` containing a tiny program that definitely contains a `.field` accessor expression and a `\x -> ...` lambda expression.
- Then, in `PostSolveGroupBStructuralTypesTest.elm`, add this fixture module to the list of modules the test runs through.

### Why this is a test-case addition
POST_001’s logic is explicitly “run constraint gen (tracking `syntheticExprIds`) → run solver → run PostSolve → assert structural types” 【】. A fixture module is just controlled input to exercise that path.

---

## Option B: don’t add any new file; construct a minimal Canonical AST directly inside the test

If your existing tests already build `Can.Module` values programmatically (rather than loading `.elm` files), then the “fixture” should just be a helper like:

- `mkLambdaAccessorModule : Can.Module`

and you add it to the list of modules the test iterates.

This is still “adding to the test cases”, just without introducing a new `.elm` file.

---

## When is Change 4 needed at all?

Only if your current test corpus doesn’t reliably produce “synthetic Group B placeholder IDs” for Lambdas/Accessors (the IDs that come from `recordSyntheticExprVar` / `syntheticExprIds`, which POST_001 is scoped to) 【】.

If your suite already includes plenty of lambdas/accessors that show up in `syntheticExprIds`, then you can skip Change 4 entirely and just implement the new assertions.

---

If you tell me which style your tests currently use (load `.elm` fixtures vs build `Can.Module` directly), I’ll rewrite the implementation plan for Change 4 to match *your* harness precisely.

## USER
  1. Consistent alpha-equivalence for Accessor:
    - Current alpha-eq allows { ext | x : a } -> b to match { ext | x : a } -> a (different return var)
    - For Accessor, field type and return type MUST be the same variable
    - Recommendation: Start with current alpha-eq. Add consistent tracking only if false negatives occur.
  2. Fixture module location:
    - Need to verify how StandardTestSuites discovers test modules (glob pattern or explicit list?)
    - This determines where to place LambdaAccessorFixture.elm
  3. Negative pattern IDs:
    - Implementation will skip (return Nothing) if a lambda parameter has negative ID
    - Assumption: Negative IDs are synthetic placeholders that shouldn't appear as lambda parameters in well-formed ASTs


## ASSISTANT
Got it. Let’s turn your three notes into an implementable design that is (a) precise for **Accessor**, (b) doesn’t guess about **fixture discovery**, and (c) handles **negative pattern IDs** in a way that doesn’t silently hide bugs.

Below I’m describing **only test-side changes**, and they’re all consistent with the POST_001 intent as documented (Group B structural types, including lambdas)  and with how PostSolve actually assigns accessor types .

---

## 1) Accessor: don’t rely on generic alpha-eq; add an Accessor-specific matcher

### Problem you observed
Your current alpha-equivalence is too permissive and can accept:

- expected: `{ ext | x : a } -> a`
- actual:   `{ ext | x : a } -> b`

That’s a **false positive** for the Accessor case: for accessors the field type and return type are not just “both vars”, they must be the **same var** (same type hole), because PostSolve constructs it as exactly:

```elm
fieldType = Can.TVar "a"
accessorType = Can.TLambda recordType fieldType
```



### Design
Keep your existing `alphaEq` for the general POST_001 structural cases, but for `Can.Accessor field` **do not use alphaEq at all**. Instead assert the post-type matches the exact Accessor shape and that the *same* type var occurs in both positions.

### Code changes

**File:** `compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`

#### Change 1A — Add a strict structural predicate for accessor types

Add:

```elm
isAccessorType : Name.Name -> Can.Type -> Bool
isAccessorType fieldName tipe =
    case tipe of
        Can.TLambda recordType retType ->
            case ( recordType, retType ) of
                ( Can.TRecord fields maybeExt, Can.TVar retVar ) ->
                    case Dict.get Basics.identity fieldName fields of
                        Just (Can.FieldType _ fieldTipe) ->
                            case fieldTipe of
                                Can.TVar fieldVar ->
                                    -- The critical invariant:
                                    fieldVar == retVar
                                        && maybeExt /= Nothing
                                _ ->
                                    False

                        Nothing ->
                            False

                _ ->
                    False

        _ ->
            False
```

Notes:
- We require `maybeExt /= Nothing` (i.e. `{ ext | ... }` not a closed record) because PostSolve constructs the accessor with an extension variable .
- We *don’t* hardcode `"a"` or `"ext"`, so this remains robust if PostSolve changes those concrete names later.
- We enforce `fieldVar == retVar`, which is the key thing your alpha-eq currently fails to enforce.

#### Change 1B — Switch the Accessor branch in POST_001 to use `isAccessorType`

Where you currently compute `expectedType` and then do `alphaEq expectedType actualType`, replace that for Accessor nodes:

```elm
case exprNode of
    Can.Accessor fieldName ->
        Expect.true "Accessor type must be { ext | field : a } -> a (same a)"
            (isAccessorType fieldName postType)

    _ ->
        Expect.true "Types must be alpha-equivalent"
            (alphaEq expectedType postType)
```

**Write-up:** This eliminates false positives for accessors immediately, without rewriting your general alpha-eq machinery.

---

## 2) Fixture module location: avoid guessing; use “coverage assertions” first

You’re right that fixture placement depends on how the test suite discovers modules.

But before adding any new fixture plumbing, note: your existing standard suites already claim to have both:
- “Field accessor functions (`accessorExpr .field`)”
- “Anonymous functions (lambdas) (`lambdaExpr`)”

in **StandardTestSuites** .

So: you likely already have inputs that generate accessor and lambda nodes—your *test* just wasn’t checking them.

### Design
Do **not** immediately add a new fixture module. Instead:
1. Extend POST_001 to check lambda/accessor types.
2. Add a **coverage assertion** at the end of the test run:
   - “We checked at least N accessors and at least M lambdas that met the precondition (synthetic expr id + preType was bare TVar).”

If this coverage assertion fails (e.g. 0 accessors found), *then* you go inspect `StandardTestSuites` discovery and add a dedicated fixture.

This approach makes the test self-verifying and avoids the “where do we put the fixture?” question until it’s actually necessary.

### Code changes

**File:** `compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`

#### Change 2A — Track counts during the POST_001 loop

Add counters in your fold/state:

```elm
type alias Coverage =
    { checkedAccessors : Int
    , checkedLambdas : Int
    }

emptyCoverage : Coverage
emptyCoverage =
    { checkedAccessors = 0
    , checkedLambdas = 0
    }
```

When you perform a successful check:
- increment `checkedAccessors` when node is `Can.Accessor _`
- increment `checkedLambdas` when node is `Can.Lambda _ _`

#### Change 2B — Assert coverage at the end (initially: >= 1 each)

At the end of the test, add:

```elm
Expect.atLeast 1 coverage.checkedAccessors
Expect.atLeast 1 coverage.checkedLambdas
```

If you want to be slightly less brittle, do `>= 1` for accessors and lambdas *combined*; but given StandardTestSuites claims to include both , requiring each independently is reasonable and helps prevent accidental regression in test input.

**Write-up:** This guarantees your newly-added logic is actually executed, without adding any fixture module or touching suite discovery.

---

## 3) Negative pattern IDs: do not “skip”; treat as a test failure (with good diagnostics)

You suggested: “Implementation will skip (return Nothing) if a lambda parameter has negative ID”.

I recommend the opposite: **fail loudly**.

Reason: negative IDs are explicitly “synthetic patterns that won’t have types” and crash if looked up . If a lambda parameter pattern ever has a negative ID, that’s either:
- an AST construction bug, or
- you’re analyzing the wrong node, or
- the compiler has started creating synthetic lambda parameter patterns (which would be a major change and should not go unnoticed).

Silently skipping means POST_001 could stop checking lambdas entirely and still pass.

### Design
When computing expected lambda type, require:
- every lambda parameter pattern id is >= 0
- and exists in `nodeTypesPost`

Otherwise produce a test failure message that includes:
- the lambda expr id being checked
- the offending pattern id

### Code changes

**File:** `compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`

#### Change 3A — Add strict pattern type lookup helper

```elm
lookupPatternTypeOrFail : Int -> String -> Can.Pattern -> NodeTypes -> Can.Type
lookupPatternTypeOrFail lambdaExprId context (A.At _ patInfo) nodeTypesPost =
    if patInfo.id < 0 then
        Debug.todo (context ++ ": lambda " ++ String.fromInt lambdaExprId ++ " has negative param pattern id " ++ String.fromInt patInfo.id)

    else
        case Dict.get Basics.identity patInfo.id nodeTypesPost of
            Just t ->
                t

            Nothing ->
                Debug.todo (context ++ ": missing type for lambda param pattern id " ++ String.fromInt patInfo.id)
```

(Use your project’s normal `Expect.fail`/`Utils.Crash.crash` style instead of `Debug.todo`; the key is: **don’t skip**.)

#### Change 3B — Lambda expected type recomputation uses pattern types

For lambdas, build `TLambda` chain from param pattern types to body expr type (as per the structural lambda typing described in your theory docs  and consistent with typed optimization’s function typing rules ).

---

## Summary of what gets implemented

1) **Accessor**: replace alpha-eq with a strict structural matcher enforcing “field var == return var” (fixes your known false-positive immediately) .

2) **Fixture location ambiguity**: avoid it by first adding **coverage assertions**; since StandardTestSuites already includes both accessors and lambdas , you should get coverage without any new fixture file.

3) **Negative pattern IDs**: treat as a failing invariant (not “skip”), aligning with the compiler’s own assumption that negative pattern IDs are synthetic and not lookuppable .

---

If you paste your current `PostSolveGroupBStructuralTypesTest.elm` (or just the parts that: (a) traverse exprs, (b) compute expected types, (c) do alpha-eq), I can give you an exact patch-style diff rather than schematic snippets.

## USER
  Implementation Report: POST_001 Lambda and Accessor Extension

  Summary

  Successfully extended POST_001 to cover Lambda and Accessor expressions with precise structural type checking.

  Test Results
  ┌───────────────────────────────────────────────┬───────┬───────────────┐
  │                  Test Suite                   │ Tests │    Status     │
  ├───────────────────────────────────────────────┼───────┼───────────────┤
  │ PostSolveGroupBStructuralTypesTest (POST_001) │ 95    │ ✅ All passed │
  ├───────────────────────────────────────────────┼───────┼───────────────┤
  │ All PostSolve Tests                           │ 297   │ ✅ All passed │
  ├───────────────────────────────────────────────┼───────┼───────────────┤
  │ All Invariant Tests                           │ 2594  │ ✅ All passed │
  └───────────────────────────────────────────────┴───────┴───────────────┘
  Changes Made

  File: compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm

  1. Added isAccessorType structural matcher (lines 315-354)
    - Enforces { ext | field : a } -> a shape
    - Requires extension variable present
    - Enforces fieldVar == retVar (same TVar in both positions)
  2. Added pattern type lookup with strict failure (lines 362-385)
    - PatternTypeLookup type with PatternTypeFound, PatternTypeNegativeId, PatternTypeMissing
    - lookupPatternType returns explicit errors instead of skipping
  3. Added lambda type helpers (lines 392-459)
    - LambdaTypeResult type with LambdaTypeOk and LambdaTypeError
    - expectedLambdaType builds curried function type from pattern and body types
    - collectPatternTypes fails loudly on negative IDs or missing types
    - buildCurriedFunctionType builds arg1 -> arg2 -> ... -> bodyType
  4. Updated checkSyntheticPlaceholder (lines 136-209)
    - Accessor: uses isAccessorType instead of generic alphaEq
    - Lambda: uses expectedLambdaType with explicit error handling
    - Other Group B: uses existing alphaEq-based check

  What POST_001 Now Validates

  For recorded Group B synthetic placeholder IDs:

  - Accessor: Post-type is exactly { ext | field : a } -> a with:
    - Same TVar in field type and return type
    - Extension variable present (not closed record)
  - Lambda: Post-type is curried TLambda chain matching arg1Type -> arg2Type -> ... -> bodyType with:
    - All pattern types successfully looked up
    - No negative pattern IDs (would indicate AST bug)
    - Body type present
  - Other Group B: Post-type matches expected structural type (alpha-equivalent)


## ASSISTANT
Your POST_001 extension sounds exactly like the “right kind of precise” for Lambda + Accessor, and it matches what PostSolve actually does:

- `postSolveAccessor` literally constructs `{ ext | field : a } -> a` by reusing the same `fieldType` var as the return type , so your `fieldVar == retVar` matcher is the correct invariant for accessors.
- `postSolveLambda` builds `arg1 -> arg2 -> … -> bodyType` by folding `Can.TLambda` over the arg pattern types it looks up by pattern IDs .

Given all that passes, two implications are worth calling out:

## 1) This result strongly suggests MONO_018 is not caused by “PostSolve failed to compute Lambda/Accessor structural types”
POST_001’s documented purpose is exactly “Group B expressions get structural types … lambdas included” , so if your test is now checking lambdas/accessors precisely and still passes across the suite, the remnant `MVar "a" CEcoValue` is likely introduced later (or comes from a different source class than “synthetic Group B placeholder IDs”).

## 2) The next most likely gap is at the **TypedOptimized boundary**, not PostSolve
Remember: PostSolve produces `nodeTypes : Dict id Can.Type` for expression *and pattern* IDs , and typed optimization is supposed to *preserve* those types onto every `TOpt.Expr` node.

There’s already an invariant specified for exactly this: **TOPT_004 “Typed optimization is type preserving”**—it says to derive expected types from the input TypedCanonical/NodeTypes and assert the stored type on `TOpt.Expr` matches (alpha-equivalent) .

If MONO_018 is seeing a polymorphic remnant “inline type”, it can happen even when PostSolve is correct if typed optimization (or later transformations) attaches the wrong `Can.Type` to some expressions or branch bodies.

### Concrete next step I’d recommend
Implement/strengthen TOPT_004 as a real checker (if it isn’t already), and focus it on the constructs implicated by MONO_018 failures:

- case branch bodies / decider inline expressions
- destructuring/pattern-bound locals (since pattern IDs and negative IDs/synthetic patterns are a known complication )

That will tell you whether the mismatch is:
- already present in TypedOptimized (type got corrupted or rebuilt incorrectly), or
- only appears during monomorphization/type substitution.

## 3) One more specific thing to watch: pattern IDs and “synthetic pattern” plumbing
Your new POST_001 lambda checking depends on “lambda parameter patterns have non-negative IDs and exist in nodeTypes”. PostSolve’s lambda implementation *does* do `Dict.get info.id nodeTypes2 |> Maybe.withDefault (Can.TVar "a")` for each arg pattern , so if a pattern is missing you can silently get a placeholder `TVar "a"`.

In other parts of the compiler, negative pattern IDs are explicitly treated as synthetic and require special handling via a parent pattern ID . If MONO_018 is triggered by list-alias / destructuring patterns, the leak might be coming from pattern typing/propagation rather than the Group B expression IDs POST_001 focuses on.

So if TOPT_004 flags anything pattern-related, that’s a strong lead.

---

If you want, paste one MONO_018 failing example with the canonical **expr id(s)** involved (case id + offending inline/branch expr id). Then we can decide whether to:
- extend POST_003 to track “hole vars” originating from *pattern IDs* (not just expr IDs), or
- go straight to a targeted TOPT_004 check on decision-tree `Inline` nodes (which is where MONO_018 is asserting type equality downstream).

## USER
Analysis: TOPT_004 Invariant Test Logic vs Actual Implementation

  Documented TOPT_004 Test Logic

  From /work/design_docs/invariant-test-logic.md:

  name: Typed optimization is type preserving
  phase: typed optimization
  invariants: TOPT_004
  ir: TypedCanonical.Expr vs TypedOptimized.Expr types
  logic: For transformations (inlining, DCE, case-to-decision-tree, etc.):
    * For each optimized expression, derive its expected type from the input
      TypedCanonical or NodeTypes.
    * Check that the stored `Can.Type` on TOpt.Expr matches that expected type
      via simple local rules (function arg/result, call result, etc.).
  inputs: Pairs of TypedCanonical and TypedOptimized IR
  oracle: Types attached to optimized expressions are always equal
          (alpha-equivalent) to the inferred types.

  Actual Test Implementation

  The OptimizeEquivalent.elm test does something completely different:

  1. Runs Erased optimization pipeline → produces Opt.LocalGraph
  2. Runs Typed optimization pipeline → produces TOpt.LocalGraph
  3. Compares the two graphs structurally, ignoring all types

  Key evidence from the code:

  -- Line 11-12: Test description
  {-| Test infrastructure for verifying Erased and Typed optimization paths 
      produce equivalent results. ... ignoring types, the structures are 
      exactly the same. -}

  -- Line 313: Explicitly ignores type annotation
  ( Opt.Define erasedExpr erasedDeps, TOpt.Define typedExpr typedDeps _ ) ->
                                                                       ^^^
                                                        (ignores Can.Type)

  -- Line 517: Compares Bool but ignores type
  ( Opt.Bool r1 b1, TOpt.Bool r2 b2 _ ) ->
                                    ^^^
                          (ignores Can.Type)

  Every expression comparison explicitly ignores the Can.Type field.

  Verdict: NO - The test does NOT implement TOPT_004 reliably
  ┌────────────────────────────────────────────────────┬──────────────────────────────┐
  │               Documented Requirement               │         Implemented?         │
  ├────────────────────────────────────────────────────┼──────────────────────────────┤
  │ Derive expected type from TypedCanonical/NodeTypes │ ❌ No                        │
  ├────────────────────────────────────────────────────┼──────────────────────────────┤
  │ Check stored Can.Type on TOpt.Expr                 │ ❌ No                        │
  ├────────────────────────────────────────────────────┼──────────────────────────────┤
  │ Verify types are alpha-equivalent                  │ ❌ No                        │
  ├────────────────────────────────────────────────────┼──────────────────────────────┤
  │ Compare structure ignoring types                   │ ✅ Yes (but wrong invariant) │
  └────────────────────────────────────────────────────┴──────────────────────────────┘
  What the Test Actually Verifies

  The test verifies a different property: that Erased and Typed optimization pipelines produce structurally equivalent output (same nodes, expressions, dependencies). This is useful but it's NOT TOPT_004.

  What TOPT_004 Should Verify

  A correct TOPT_004 implementation would:
  1. For each TOpt.Expr in the optimized output
  2. Derive the expected type from:
    - The corresponding input expression's type in NodeTypes
    - Or via local type rules (function result type, call result type, etc.)
  3. Assert the stored Can.Type on the expression equals the expected type (alpha-equivalent)


## ASSISTANT
You’re correct: what you described as `OptimizeEquivalent.elm` is a **useful “erased vs typed structure equivalence” test**, but it does **not** implement TOPT_004 as defined in the invariants doc.

TOPT_004 is documented as “typed optimization is type preserving” and explicitly requires validating the `Can.Type` stored on `TOpt.Expr` nodes against an expected type derived from the IR / local rules / NodeTypes . The typed-optimization theory also spells out the kind of local typing rules we should enforce (Function, Call, Let, etc.) .

Below is a concrete, engineer-followable design to implement a *real* TOPT_004 test, with all code changes.

---

## Design: Implement TOPT_004 as a “TypedOptimized internal type checker”

### Core idea
Instead of comparing erased vs typed graphs, we directly validate that the **typed optimized graph is self-consistent w.r.t. types**, and (critically for your MONO_018 chase) that **Case/Decider inline expressions have the same type as the case result type**, mirroring MONO_018 but earlier.

This aligns with the documented TOPT_004: “derive expected type via simple local rules (function arg/result, call result, etc.) and compare to stored type” , and with the typed optimization IR structure (every expr carries a `Can.Type`, including `Case`) .

### What this catches (relevant to MONO_018)
If typed optimization builds a `TOpt.Case ... resultType` but leaves some branch/inline body carrying a different `Can.Type` (including stray `TVar`s), TOPT_004 will fail immediately—before monomorphization.

---

## Code Changes (ALL)

### 1) Keep `OptimizeEquivalent.elm`, but reclassify it (optional but recommended)

**File:** `compiler/tests/.../OptimizeEquivalent.elm` (wherever it currently lives)

**Change:**
- Update module docs/comments and test name to reflect what it actually checks:
  - “Erased and Typed optimization outputs are structurally equivalent (ignoring types).”
- Optionally rename the test suite label from “TOPT_004” to something like “TOPT_EQUIV” or “TYPED_OPT_EQUIV”.

**Why:**
So TOPT_004 is no longer “claimed” by a test that ignores types (your analysis is right).

*(No repo citation here since we don’t have the file text in the uploaded docs, but this is purely test hygiene.)*

---

### 2) Add a real TOPT_004 test module

**File (new):**
`compiler/tests/Compiler/Optimize/Typed/TypedOptimizeTypePreservationTest.elm`

**Purpose:**
Compile a set of modules through the typed pipeline and validate type-preservation invariants over the resulting `TOpt.LocalGraph`.

**Key dependencies / pipeline:**
You already have a `compileTyped` pipeline that produces `typedObjects : TOpt.LocalGraph` . We’ll reuse whatever existing test harness you’re using to compile the StandardTestSuites modules.

**What this test does:**
For each resulting `TOpt.LocalGraph`:
- traverse all nodes / expressions
- run `TypePreservation.checkExpr : Env -> TOpt.Expr -> List Error`
- assert no errors

---

### 3) Implement the TOPT_004 checker logic

**File (new):**
`compiler/tests/Compiler/Optimize/Typed/TypePreservation.elm`

#### 3A) Define errors
```elm
type Error
    = WrongType { context : String, expected : Can.Type, actual : Can.Type }
    | CallResultMismatch { funcType : Can.Type, argCount : Int, actual : Can.Type }
    | FunctionTypeMismatch { expected : Can.Type, actual : Can.Type }
    | CaseBranchTypeMismatch { caseType : Can.Type, branchType : Can.Type }
    | CaseInlineTypeMismatch { caseType : Can.Type, inlineType : Can.Type }
    | MissingBranchIndex Int
    -- etc
```

#### 3B) Implement alpha-equivalence
Reuse the same alpha-equivalence implementation you already have for POST tests (you just extended it for accessors). This keeps comparisons robust.

#### 3C) Implement local typing rules (the “oracle”)

These are derived straight from typed optimization theory:

- **Function**: `funcType == argTypes -> bodyType` 
- **Call**: `callType == peelResult(typeOf func, length args)` 
- **Let**: `letType == typeOf body` 
- **Case**: `caseType == typeOf every branch body`, plus every `Inline expr` in the decider must match the case type (this parallels MONO_018 but at TOpt stage; `Case` is part of the typed AST) 
- **If**: each branch body type == if expression type, and final branch type == if expression type.

Pseudo-skeleton:

```elm
checkExpr : Env -> TOpt.Expr -> List Error
checkExpr env expr =
  case expr of
    TOpt.Bool _ _ t ->
      [] -- optionally check t == Bool

    TOpt.Function params body funcType ->
      let
        paramTypes = List.map Tuple.second params
        bodyType = TOpt.typeOf body
        expected = List.foldr Can.TLambda bodyType paramTypes
      in
      errorsIfNotAlphaEq "Function" expected funcType
        ++ checkExpr (extendEnv params env) body

    TOpt.Call region func args callType ->
      let
        funcType = TOpt.typeOf func
        expectedResult = peelResult funcType (List.length args)
      in
      checkExpr env func
        ++ List.concatMap (checkExpr env) args
        ++ case expectedResult of
             Nothing -> [ CallResultMismatch { funcType = funcType, argCount = List.length args, actual = callType } ]
             Just expected -> errorsIfNotAlphaEq "Call result" expected callType

    TOpt.Let def body letType ->
      errorsIfNotAlphaEq "Let type" (TOpt.typeOf body) letType
        ++ checkDef env def
        ++ checkExpr (extendEnvFromDef def env) body

    TOpt.Case scrutName scrutType decider jumps caseType ->
      checkCase env decider jumps caseType
        ++ ... recurse into scrutinee expr if represented ...
```

#### 3D) `peelResult` helper
Implement a simple peel over `Can.TLambda`:

```elm
peelResult : Can.Type -> Int -> Maybe Can.Type
peelResult t n =
  if n <= 0 then Just t else
  case t of
    Can.TLambda _ ret -> peelResult ret (n - 1)
    _ -> Nothing
```

#### 3E) Case/Decider check (most important for MONO_018 alignment)

Typed optimization uses decision trees and `Choice = Inline Expr | Jump Int` per theory . So implement:

- For each `(idx, branchExpr)` in `jumps`:
  - assert `typeOf branchExpr == caseType`
- Walk the `decider`:
  - `Leaf (Inline expr)` ⇒ assert `typeOf expr == caseType`
  - `Leaf (Jump idx)` ⇒ assert `idx` exists in `jumps` (avoid dangling jump)
  - recurse for `Chain`/`FanOut` etc.

This is precisely analogous to MONO_018’s “case branches match result type”, just earlier (TypedOptimized rather than Monomorphized).

---

### 4) Wire the new test into the test runner

Wherever your “All Invariant Tests” or typed optimization test suite is assembled, add:

- `TypedOptimizeTypePreservationTest.suite`

If you have a pattern like `Compiler/tests/AllTests.elm` or similar, add it there.

---

### 5) (Optional but strong) Add coverage assertions to ensure the test is exercising cases

Because you’re chasing MONO_018, you want this test to actually encounter `TOpt.Case` nodes in practice.

In the checker, collect counts:
- number of `Case` expressions seen
- number of `Inline` leaves checked

At end of module check, assert `caseCount > 0` for the standard suite modules that should have case expressions.

---

## Why this is the correct TOPT_004 (and why it’s better than trying to “map back” to TypedCanonical)

You *can* try to compare every TOpt expression back to the original TypedCanonical/NodeTypes, but typed optimization legitimately transforms structure (decision tree compilation, inlining, DCE). The invariant definition explicitly allows using “simple local rules” , and those local rules are already the contract of the pass (Function/Call/Let typing) .

So implementing TOPT_004 as an internal type checker is:
- faithful to the documented invariant
- robust under optimization rewrites
- directly targeted at the kind of “branch inline type doesn’t match case result type” issue you’re seeing later in MONO_018.

---

If you paste the `TOpt.Expr` and `TOpt.Decider/Choice` type definitions (or point me at the file), I can turn the above into a constructor-exhaustive implementation plan (i.e. exactly which variants to check and which to treat as “recurse only”).

## USER
 1. Should we check Destructor types against the pattern being destructured?
  2. How strict should we be on TailCall return types?
  3. Should VarKernel types be verified against KernelTypeEnv?
  4. Does TypedOptimized instantiate polymorphic types at VarGlobal sites, or do we need scheme instantiation?


## ASSISTANT
### 1) Should we check `Destructor` types against the pattern being destructured?

Yes, but do it in **layers**, because “full correctness” requires path-sensitive reasoning (tuple index vs record field vs list tail) and you’ll want to avoid false failures.

**Layer A (cheap + high signal): “Destruct node type is body type”**
- For any `TOpt.Destruct _ body destructType`, assert `destructType == typeOf body` (alpha-eq).
- This matches the general “Let types are the body type” style rule used throughout typed optimization 【】 and catches a common class of bugs where the wrapper node is annotated incorrectly.

**Layer B (still cheap): “bound var type matches destructor annotation”**
- For each `Destructor name _ annotatedType`, ensure all `VarLocal name` occurrences in the body use the same `annotatedType` (or alpha-eq). This is essentially an “internal consistency of environment threading” check.

**Layer C (strong + precise, but more work): “path projection matches pattern/container type”**
- This is the one that answers your question literally: the destructor’s `annotatedType` should equal the type you get by projecting along the `TOpt.Path` from the scrutinee/container type.
- You already have compiler logic that relies on pattern typing to pick destructor field types (e.g. record pattern destructuring extracts a field type from the pattern’s record type) 【】, so it’s reasonable to test it.
- Keep it **limited to the projection kinds you can prove**:
  - `Index` with `HintTuple2/HintTuple3` → compute from tuple element types
  - `Field` on record → compute from `TRecord` field dict
  - `Unbox` if you have a known unboxed wrapper convention
- For list destructuring and negative pattern IDs, note the compiler already has “synthetic pattern id” plumbing using a parent id fallback during destructuring 【】; mirroring that perfectly in a test is possible, but I would only add it once Layer A/B is in.

Recommendation: implement A+B first (fast, low risk), then add C only for tuple/record projections where it’s unambiguous.

---

### 2) How strict should we be on `TailCall` return types?

Be strict on **return type equality**, tolerant on **callee representation**.

For TOPT_004 purposes, the important invariants are:

- The `TailCall` expression’s attached `Can.Type` must equal the surrounding expression type (alpha-eq).
- It must also equal the function’s return type implied by the callee’s function type after consuming the number of arguments (same “peel result” logic you’d use for `Call`) — this matches the documented “Call result type comes from peeling function type” rule 【】.

What *not* to do in TOPT_004:
- Don’t try to enforce “tailcall only appears in tail position” here; that’s a control-flow / transform legality check, not type preservation.
- Don’t require the callee to be syntactically a particular node (that’s closer to monomorphization/codegen invariants).

So: treat TailCall like Call from a type perspective, but require the node’s own return type to be correct.

---

### 3) Should `VarKernel` types be verified against `KernelTypeEnv`?

Yes, that’s a very good and very cheap check, and it’s directly aligned with the typed optimization contract:

Typed optimization says kernel vars get their types by lookup from `kernelEnv`:
`VarKernel h n -> VarKernel ... (lookupKernel h n kernelEnv)` 【】.

And PostSolve is explicitly responsible for building `kernelEnv` before typed optimization runs 【】.

So in TOPT_004/TOPT checks:

- For every `TOpt.VarKernel region home name canType`:
  - look up `(home, name)` in the `KernelTypeEnv` that was passed into typed optimization
  - assert `alphaEq canType (kernelEnvType home name)`
  - if missing: fail (because typed optimization should not be producing a typed kernel var without a kernel type available, given PostSolve’s post-condition that kernel types are computed for used kernels 【】)

This check is also extremely relevant to your MONO_018 symptoms because unresolved kernel/polymorphic types often end up preserved as `TVar`/`MVar` later.

---

### 4) Does `TypedOptimized` instantiate polymorphic types at `VarGlobal` sites, or do we need scheme instantiation?

TypedOptimized expressions store a **`Can.Type`**, while top-level annotations are **schemes** (in `Annotations`) and are preserved in the typed graph (TOPT_003) 【】.

The safe, testable stance for TOPT_004 is:

- A `VarGlobal` site should carry a `Can.Type` that is an **instance of** the global’s annotation scheme (i.e. the scheme type with some substitution for quantified variables).
- Therefore, *yes*, there is an implicit “scheme instantiation” relationship to verify, even if the implementation does it by freshening names or by some other mechanism.

Why this matters: if you don’t instantiate (or otherwise freshen) scheme variables per use-site, two separate uses of a polymorphic value could accidentally share type variables by name, and later unification/specialization can go wrong. Typed optimization’s whole goal is preserving correct type flow to monomorphization 【】, so this is worth checking.

**Concrete TOPT check to add:**
- For each `TOpt.VarGlobal ... global canType`:
  - fetch its `Can.Annotation` scheme from the `Annotations` dict (the same dict that TOPT_003 validates is preserved) 【】
  - assert: `canType` is an instance of the scheme’s body type (existential substitution)
    - i.e. implement `isInstanceOf : schemeType -> canType -> Bool` using a one-way “scheme TVars may bind, but structure must match” unifier (very similar in spirit to PostSolve’s one-way unifier described in theory) 【】

This avoids guessing “does TypedOptimized already instantiate?”: even if it *does*, the check still passes; if it *doesn’t* (and shouldn’t), the check will fail in exactly the cases that are dangerous for later phases.

---

If you want, I can outline exactly which subset of `TOpt.Expr` constructors you should start with for TOPT_004 to maximize signal for MONO_018 (Case/Decider/Inline/Jump, Destruct, Function, Call, VarGlobal/VarKernel) while keeping the first implementation small.

## USER
Precise Description of TOPT_004 Type Preservation Test

  What It Checks

  TOPT_004 walks the TypedOptimized IR and verifies type consistency at these specific points:

  1. Case/Decider Branch Consistency (Critical)
    - For every TOpt.Case expression with result type T:
        - Every TOpt.Inline expr in the Decider tree must have typeOf expr alpha-equivalent to T
      - Every Jump target expression must have type alpha-equivalent to T
    - This catches MONO_018-class bugs where case branches produce values of different types
  2. VarLocal Binding Consistency
    - When a TOpt.VarLocal name is encountered, if name is in the local environment, the variable's type must match the binding's type
  3. VarKernel vs KernelTypeEnv Consistency
    - For TOpt.VarKernel home name, if the kernel is in KernelTypeEnv, the expression's type must match the env's type
  4. Recursive Expression Traversal
    - Recursively checks all sub-expressions in Function bodies, Let/Destruct bodies, If branches, Call arguments, etc.

  What It Does NOT Check

  - Literal types - Int/Float/Char/String/Bool literals are not checked against expected primitive types (because Elm uses number constraint variables)
  - Function type = params → body type - Not checked (polymorphic functions may have more general return types)
  - Call result type - Not checked against function return type (polymorphism)
  - VarGlobal scheme instantiation - Disabled (complex polymorphism handling)
  - If branch types match If type - Disabled (the If expression may be polymorphic while branches are concrete)

  Alpha-Equivalence Rules

  Two types are alpha-equivalent if:
  - Both are TVar (any TVar matches any TVar)
  - Either is TVar (TVar matches any concrete type - handles polymorphism)
  - Both are TType with same package and type name (module can differ for re-exports like Basics.String ≡ String.String)
  - Both are TLambda with alpha-equivalent arg and result types
  - Both are TRecord with same field names and alpha-equivalent field types
  - TAlias is unwrapped and compared to underlying type

It passes all test cases.

## ASSISTANT
Your TOPT_004 as described is a good *shape* of test (especially the Case/Decider consistency), but the current “alpha-equivalence” definition makes it far too permissive to catch the exact MONO_018-class failures you’re chasing.

### The core problem: your alpha-eq turns `TVar` into a wildcard
You wrote:

- “Both are TVar (any TVar matches any TVar)”
- “Either is TVar (TVar matches any concrete type)”

That means this mismatch will **pass** TOPT_004:

- Case result type: `List Int`
- Inline branch type: `List a`

because when you recurse into the element type you hit `TVar` and treat it as matching any concrete type.

But that mismatch is *exactly* the kind of “polymorphic remnant under structure” that later becomes `MVar "a" CEcoValue` and triggers MONO_018.

So as implemented, your TOPT_004 Case check cannot reliably catch “branch is more polymorphic than the case result type”, which is the key failure mode.

### This also diverges from the documented TOPT_004 intent
The invariant doc says TOPT_004 should ensure “Types attached to optimized expressions are always equal (alpha-equivalent) to the inferred types” . Alpha-equivalent does **not** mean “TVar matches anything”; it means “equal up to consistent renaming”.

---

## What I would change (precisely) to make TOPT_004 effective

### 1) Split the notion into two relations
Implement two comparisons:

1) **`alphaEqStrict`** (real alpha-equivalence)
- `TVar x` matches `TVar y` only via a *consistent renaming map* (x↔y), not “any var matches any var”.
- `TVar` does **not** match a concrete type.
- Record extension vars also need consistent renaming (same idea as your Accessor fix in POST_001).

2) **`alphaEqPermissive`** (optional, for places where you truly want “unknown”)
- This is where you can keep “TVar matches anything”, but you should use it only where you *want to ignore precision*.

### 2) Use `alphaEqStrict` for the checks that matter for MONO_018
Specifically:

- **Case/Decider checks must use `alphaEqStrict`** for:
  - `Inline expr` type vs Case result type
  - jump target expr type vs Case result type

This will now fail on:
- `List Int` vs `List a`
- `Int -> Int` vs `Int -> a`
etc.

That’s the direct early warning you want before monomorphization.

### 3) Keep environment consistency strict too
- VarLocal binding consistency should also be strict (otherwise “VarLocal x : a” would match “x bound as Int” and you’ll miss real corruption).

### 4) About “module can differ for re-exports”
Be careful with “module can differ (Basics.String ≡ String.String)”. Unless you have a principled canonicalization of type constructors, this can create false positives.

If your `Can.TType` includes a canonical home/module identity, prefer requiring that to match. If you truly need aliasing/re-export equivalence, handle it by normalizing known special cases, not by blanket “module can differ”.

---

## Answers implied by your “Does NOT check” list

Some of your disabled checks are fine *for an incremental TOPT_004*, but they shouldn’t justify wildcard TVars:

- Skipping literal-type exactness is reasonable because numeric literals can involve constrained vars in some compilers.
- Skipping “Call result type equals peelResult” loses signal, but it’s not required to catch MONO_018.

However: the doc’s examples of “simple local rules” explicitly include function/call result typing  and the typed optimization theory describes those rules (Function builds argTypes->bodyType, Call peels result, Let uses body type) . So long-term, TOPT_004 should grow toward checking at least those three.

---

## Minimal change that would immediately make your current TOPT_004 meaningful
If you don’t want to do the full strict alpha-equivalence machinery yet, the smallest improvement is:

- Keep your current permissive alpha-eq *globally*, **but override it for Case**:
  - If either side is `TVar`, treat it as **not equal** (or only equal if *both* are TVar).
  - If the types are structured (List, Function, Record, Tuple), recurse structurally and do **not** allow leaf `TVar` to match a concrete type.

That one tweak alone will make TOPT_004 start catching “structured type contains a leftover TVar” in branches, which is the MONO_018 precursor.

---

If you paste the actual `alphaEq` function you implemented for TOPT_004, I can rewrite it into a strict version (with consistent var mapping) in the same style as your POST_001 `isAccessorType` improvement, and tell you exactly where to switch the Case checks over.

## USER
Write this up as a full design that an engineer could follow to implement it.

Make sure to provide ALL code changes needed, and for each one be clear about where in the code it needs to go as well as giving a brief write up explaining the change.

## ASSISTANT
Below is a full, implementable design to fix TOPT_004 so it **actually catches MONO_018-class bugs** (case branch/inline expression type mismatches caused by “TVar-as-wildcard” comparisons), while keeping the rest of TOPT_004 intentionally lightweight.

This design is consistent with:

- The documented intent of TOPT_004 (“types attached to optimized expressions are always equal (alpha-equivalent) … using simple local rules”) 
- The fact that TypedOptimized carries a `Can.Type` on every expression 
- The concrete MONO_018 invariant (“MonoCase branches match case result type”) which we want to approximate earlier in the pipeline 

---

# Problem Statement

Your current TOPT_004 “alpha-equivalence” treats `TVar` as a wildcard:

- `TVar` matches any `TVar` (no consistent mapping)
- `TVar` matches any concrete type

That makes TOPT_004 incapable of failing on the key bug shape:

- `case : List Int`
- branch expression has type `List a`

Because it hits the element `TVar` and accepts it.

This is exactly the kind of “polymorphic remnant under structure” that later becomes `MVar "a" CEcoValue` and fails MONO_018.

---

# Design Overview

## Key change
Introduce **two** type comparators:

1. **`alphaEqStrict`**  
   Real alpha-equivalence with **consistent renaming** of type variables and record extension variables.
   - `TVar` only matches `TVar`, and only via a consistent mapping.
   - `TVar` does **not** match a concrete type.

2. **`alphaEqLoose`** (optional, for legacy behavior)  
   Retains your current permissive behavior where `TVar` may match anything.
   - Used only where you intentionally want to ignore precision.

## Where to use strict vs loose
Update TOPT_004 to use **strict** equivalence for the checks that must catch MONO_018-class problems:

- Case result type vs Inline leaf expression type
- Case result type vs Jump target expression type
- VarLocal type vs environment binding type
- VarKernel type vs KernelTypeEnv entry type (when present)

Everything else remains “recursive traversal only”, per your current scope.

---

# Code Changes (ALL)

## Change 1 — Add a shared strict alpha-equivalence module (new)

**Add file:** `compiler/tests/Compiler/Optimize/Typed/TypeEq.elm`

### Purpose
Provide `alphaEqStrict` (and optionally `alphaEqLoose`) for comparing `Can.Type` values robustly and deterministically in tests.

### Implementation details

#### Public API
```elm
module Compiler.Optimize.Typed.TypeEq exposing
    ( alphaEqStrict
    , alphaEqLoose
    )
```

(Use whatever namespace matches your test folder conventions; the important part is: it’s importable by your TOPT_004 test.)

#### `alphaEqStrict` state
Alpha-equivalence must be consistent across a whole comparison, so we track renamings:

```elm
type alias AlphaState =
    { tvarsL2R : Dict.Dict String Name.Name Name.Name
    , tvarsR2L : Dict.Dict String Name.Name Name.Name
    , extL2R : Dict.Dict String Name.Name Name.Name
    , extR2L : Dict.Dict String Name.Name Name.Name
    }
```

#### Core rules implemented (strict)
- `TVar a` vs `TVar b`:
  - if `a` already mapped, must map to `b`
  - if `b` already reverse-mapped, must map to `a`
  - otherwise extend mapping `a ↔ b`
- `TVar _` vs non-`TVar`: **fail**
- `TType home name args` vs `TType home2 name2 args2`:
  - require `home == home2` and `name == name2`
  - require same arg length, recurse on args
- `TLambda a b` vs `TLambda a2 b2`: recurse
- `TTuple`/`TUnit`/`TRecord`/etc: structural recursion
- `TRecord fields ext`:
  - require same field name set
  - compare each field type (ignore `FieldType` index; compare the contained type)
  - compare extension vars using a separate ext-var mapping (same logic as TVars)
- `TAlias ...`:
  - unwrap to underlying alias body **after applying alias args substitution** (see below), then recurse

Why the alias substitution matters: your current “unwrap alias and compare underlying type” is only correct if you substitute alias parameters. Canonical aliases are represented as `TAlias home name (List (Name, Type)) AliasType` , so the alias body may still contain parameter TVars.

Implement:

```elm
unwrapAlias : Can.Type -> Can.Type
unwrapAlias t =
    case t of
        Can.TAlias _ _ args aliasType ->
            let
                subst = Dict.fromList (List.map (\(n, ty) -> (n, ty)) args)
                body =
                    case aliasType of
                        Can.Filled filled -> filled
                        Can.Holey holey -> holey
            in
            applyCanSubst subst body

        _ ->
            t
```

Where `applyCanSubst` replaces `Can.TVar name` by `subst[name]` if present, and recurses.

> This makes the strict equality stable and more correct than “strip TAlias and hope”.

#### `alphaEqLoose` (optional)
If you still need the old behavior anywhere, keep it, but make it explicit:

- `TVar _` matches anything
- or keep your current implementation

**Write-up:** This isolates “intentional imprecision” and prevents it from accidentally masking MONO_018-class bugs in Case checking.

---

## Change 2 — Update TOPT_004 test to use strict equality for critical checks

You already have a TOPT_004 test implementation that:
- walks TypedOptimized
- checks Case/Decider leaf types, VarLocal environment, VarKernel vs KernelTypeEnv
- uses permissive alpha-eq

We will modify that test.

### 2A) Import new module
**File:** your existing TOPT_004 test file (whatever it is currently named; e.g. `compiler/tests/.../TOPT_004_*.elm`)

Add:

```elm
import Compiler.Optimize.Typed.TypeEq as TypeEq
```

### 2B) Replace Case/Decider comparisons with `alphaEqStrict`

Where you currently do:

- `alphaEq caseType (typeOf inlineExpr)`

Change to:

- `TypeEq.alphaEqStrict caseType (TOpt.typeOf inlineExpr)`

Specifically implement:

#### For `TOpt.Case ... caseType`
- For each `(idx, branchExpr)` in the jump table:
  - assert `alphaEqStrict (TOpt.typeOf branchExpr) caseType`
- Walk the decider:
  - `Leaf (Inline expr)`:
    - assert `alphaEqStrict (TOpt.typeOf expr) caseType`
  - `Leaf (Jump idx)`:
    - assert idx exists in jump table (this prevents silent dangling references)

This mirrors the MONO_018 definition but at the TypedOptimized stage .

### 2C) Replace VarLocal binding comparisons with `alphaEqStrict`
When encountering `TOpt.VarLocal name varType` and `name` is in your local environment:

- assert `alphaEqStrict varType envType`

This ensures you catch “local variable got a more-polymorphic type” (e.g. `a`) when the environment expects `Int`.

### 2D) Replace VarKernel vs KernelTypeEnv comparisons with `alphaEqStrict`
Typed optimization is documented to assign kernel var types from kernelEnv lookup , and kernelEnv comes from PostSolve .

So when you see:

- `TOpt.VarKernel region home name ty`

and `KernelTypeEnv` contains `(home,name)`:

- assert `alphaEqStrict ty (kernelEnvType home name)`

If the kernel isn’t in the env, keep the current behavior (“do nothing”) if that’s consistent with your pipeline, but note: in a fully correct pipeline, used kernels should be in kernelEnv as a PostSolve post-condition .

**Write-up:** This makes TOPT_004 capable of catching “typed optimization attached the wrong kernel type”, a very common source of later monomorphization mismatches.

---

## Change 3 — Keep the rest of your TOPT_004 scope unchanged (but make it explicit)

Your current “What it does NOT check” list is acceptable for a “targeted TOPT_004” so long as the *critical checks* are strict.

Keep:
- no literal-type checking
- no function-type = params→body checking
- no call-result checking
- no VarGlobal scheme instantiation checks
- no If-branch type checks

But ensure:
- the traversal is still exhaustive (it must recurse into all children so it reaches Case/Inline nodes deep inside lets/functions)

TypedOptimized’s “everything carries types” model supports this style of validation .

---

## Change 4 — Add a coverage guard (recommended)

Strict Case checks can be correct but still “never run” if the test corpus doesn’t include cases.

Add counters to the test state:

- `casesSeen : Int`
- `inlineLeavesSeen : Int`
- `jumpBranchesSeen : Int`

At end of the suite, assert something like:

- `casesSeen > 0`

You can choose whether to require a minimum inline/jump count.

**Write-up:** Prevents a future refactor from silently removing case-heavy inputs and leaving TOPT_004 unable to catch MONO_018-class regressions.

---

## Change 5 — Wire into the test suite / runner

Wherever your test suites are aggregated (e.g. `AllTests.elm`, `OptimizeTests.elm`, etc.):

- Ensure the TOPT_004 test module is included in the “All Invariant Tests” list.

No production compiler code changes are required.

---

# Why this design is correct

- It restores “alpha-equivalence” to mean what it should mean: **equality up to consistent renaming**, not “TVar matches anything”.
- It uses strictness exactly where it must in order to catch MONO_018-class mismatches: typed case result types vs branch expression types.
- It does not require reconstructing types from NodeTypes/TypedCanonical, which is hard after optimization rewrites; it focuses on TypedOptimized’s contract: internal type consistency plus case-branch agreement, which is the earliest practical place to catch the later monomorphization failure .

---

# Notes / gotchas to be aware of during implementation

1) **Alias unwrapping must substitute alias arguments**  
Canonical aliases have argument bindings in the `TAlias` node ; you should apply them before comparing alias bodies, otherwise strict checks will be wrong.

2) **Record extension variables**  
If you compare record extension vars literally, you’ll get spurious failures. Use the same consistent mapping approach as type variables.

3) **Destructuring / negative pattern IDs**  
Other compiler code treats negative pattern IDs as synthetic and may require special handling , but your TOPT_004 design doesn’t need to reason about pattern IDs directly—just ensure traversal enters destruct bodies so Case checks still run.

---

If you paste the current TOPT_004 test file (the one that implements your permissive `alphaEq`), I can produce a concrete patch-style edit plan (“replace function X with Y, update these call sites”) rather than describing it abstractly.

## USER
 Report

  Implementation Complete

  Created two files:
  1. /work/compiler/tests/Compiler/Optimize/Typed/TypeEq.elm - New module with alphaEqStrict using consistent TVar renaming
  2. Updated /work/compiler/tests/Compiler/Optimize/TypePreservation.elm to use strict equality for critical checks

  Test Results: 24 failures out of 9511 tests

  The strict alpha-equivalence is working correctly and detecting real bugs.

  Failure Categories
  ┌──────────────────────────────────────┬───────┬────────────────────────────────────────────────┐
  │               Category               │ Count │                  Description                   │
  ├──────────────────────────────────────┼───────┼────────────────────────────────────────────────┤
  │ TOPT_004 "preserves types"           │ 8     │ New strict check catching polymorphic remnants │
  ├──────────────────────────────────────┼───────┼────────────────────────────────────────────────┤
  │ CGEN_052 "papExtend remaining_arity" │ 12    │ Pre-existing issue (unrelated to this change)  │
  ├──────────────────────────────────────┼───────┼────────────────────────────────────────────────┤
  │ "case branch types match"            │ 4     │ Related MONO_018-style failures                │
  └──────────────────────────────────────┴───────┴────────────────────────────────────────────────┘
  Example TOPT_004 Violations Caught

  1. Closure in case branch:
  stored:   Int -> a           ← polymorphic remnant
  expected: Int -> Int
  2. If with variable condition:
  stored:   a                  ← unresolved TVar
  expected: Bool
  3. Case returns curried function:
  stored:   Int -> Int -> Int -> a
  expected: Int -> Int -> Int -> Int
  4. Nested list pattern:
  stored:   List a             ← polymorphic remnant
  expected: List Int

  Conclusion

  The strict alphaEqStrict is correctly detecting MONO_018-class bugs where:
  - Branch expressions have polymorphic remnant types (a, List a, etc.)
  - The Case/VarLocal/VarKernel expected type is concrete

  These are genuine type preservation violations in the compiler pipeline. The previous permissive implementation was masking these issues by treating TVar as a wildcard.


## ASSISTANT
## Goal

Implement **TOPT_004: “Typed optimization is type preserving”** as an *actual type-checking invariant* over the **TypedOptimized IR**, with enough strictness to catch **MONO_018-class “polymorphic remnant” bugs** (e.g. `List a` leaking where `List Int` is expected), which were previously masked by a permissive “TVar matches anything” comparator.

This matches the documented intent for TOPT_004 in `design_docs/invariant-test-logic.md`  and the stated typed-optimization responsibility to preserve and attach `Can.Type` everywhere .

---

## Design principles

### What TOPT_004 should check (scope)
TOPT_004 should **only** check places where typed optimization is expected to be *type-preserving and locally consistent* without needing full scheme instantiation:

1. **Case/DecisionTree branch consistency (critical for MONO_018)**
   - For every `TOpt.Case ... resultType`:
     - Every `Inline expr` leaf in the `Decider` must have `typeOf expr` **alphaEqStrict** to `resultType`
     - Every `Jump i` must refer to a jump-table entry whose expression type is **alphaEqStrict** to `resultType`
   - Rationale: `Compiler.Optimize.Typed.Case.optimize` explicitly stamps `resultType` onto the `TOpt.Case` node . If branch bodies carry a different type annotation, that’s a typed optimization bug (and a direct precursor to MONO_018).

2. **VarLocal binding consistency**
   - When encountering `TOpt.VarLocal name ty`, if `name` is in the current environment, require `ty` **alphaEqStrict** the bound type.

3. **VarKernel consistency vs KernelTypeEnv**
   - If a `TOpt.VarKernel home name ty` is present and `(home,name)` exists in `KernelTypeEnv`, require `ty` **alphaEqStrict** that env type.
   - Rationale: typed optimization is documented to look up kernel types and attach them . KernelTypeEnv is computed by PostSolve and is intended to be authoritative for kernel references .

4. **Recursive traversal**
   - Walk all subexpressions so the above checks happen everywhere, not just top-level.

### What TOPT_004 should *not* check (initially)
These require either scheme instantiation or number/comparable constraint reasoning and will cause false positives if done naïvely:

- Call result type matches function return type (polymorphic functions/schemes)
- Function/lambda “computed” type equals the `TLambda` chain (that’s TOPT_005 per invariant doc )
- Literal types for numbers (number vars)
- `If` condition is Bool *unless* you can derive it without schemes (see optional extension below)

---

## Key enabling change: strict alpha-equivalence for `Can.Type`

### Problem
The old “alpha-eq” effectively treated `TVar` as a wildcard (so `List a` could match `List Int`), which defeats the purpose of catching “polymorphic remnants”.

### Solution
Introduce a **strict** alpha-equivalence:
- `TVar a` matches `TVar b` only if a consistent renaming mapping can be maintained.
- `TVar` does **not** match a concrete type.
- Record extension variables are handled consistently (same mapping discipline).
- `TAlias` is dealiased before comparison (use the existing dealias helpers; see `Compiler.AST.Utils.Type` functions like `deepDealias` / `iteratedDealias` ).

---

## Concrete code changes (ALL)

### Change 1 — Add shared strict type equality module for tests

**Add new file**
- **Path:** `compiler/tests/Compiler/Optimize/Typed/TypeEq.elm`
- **Purpose:** centralize type equality so all typed-optimization invariants use the same strict definition.

**Public API**
```elm
module Compiler.Optimize.Typed.TypeEq exposing
  ( alphaEqStrict
  )
```

**Implementation requirements**
- Define an internal state:
  - `leftToRight : Dict String String`
  - `rightToLeft : Dict String String`
- Implement:

```elm
alphaEqStrict : Can.Type -> Can.Type -> Bool
```

**Rules**
1. **Dealias both inputs first**
   - Use `Type.deepDealias` or `Type.iteratedDealias` from `Compiler.AST.Utils.Type` .
2. **TVar**
   - `TVar a` vs `TVar b`: enforce consistent bijection via both dicts.
   - `TVar _` vs non-`TVar`: fail.
3. **TLambda**
   - Recurse on arg and result.
4. **TType**
   - Require identical `(home, name)` and recurse on args.
   - (Do *not* do “module-can-differ” heuristics unless you have a known re-export normalization list.)
5. **TRecord**
   - Same field-name set, recurse each field type in key order.
   - Extension: `Nothing` must match `Nothing`. `Just extVar` must match `Just extVar2` using the same TVar mapping logic.
6. **TTuple / TUnit**
   - Structural equality by components.

**Write-up to include in comments**
- Explain why strictness is required to catch MONO_018 remnants and why “TVar matches anything” is unsound for TOPT_004.

---

### Change 2 — Implement/replace TOPT_004 test with an actual type-preservation walk

**Add or edit file**
- **Path:** `compiler/tests/Compiler/Optimize/TypePreservation.elm`
- **Goal:** make this test implement the TOPT_004 logic described in `design_docs/invariant-test-logic.md`  instead of “erased-vs-typed structural equivalence ignoring types”.

#### 2.1 Imports
- Import TypedOptimized AST (`Compiler.AST.TypedOptimized as TOpt`)
- Import `Compiler.Optimize.Typed.TypeEq` (Change 1)
- Import `KernelTypeEnv` type (wherever it lives in your codebase; it is produced by typed typecheck+PostSolve in `Compile.compileTyped` )

#### 2.2 Add `typeOf : TOpt.Expr -> Can.Type`
Implement `typeOf` by pattern matching and returning the final `Can.Type` field. This is consistent with the “every expression carries Can.Type” contract of typed optimization .

#### 2.3 Define an environment for VarLocal checks
```elm
type alias Env =
  { locals : Dict String Name Can.Type
  , kernelEnv : KernelTypeEnv
  }
```

#### 2.4 Core checker entrypoint
```elm
checkGraph : KernelTypeEnv -> TOpt.LocalGraph -> List Failure
```

You likely already have graph traversal infrastructure (walk nodes/defs). The key is to call `checkExpr` on every root expression with an empty local env and the module’s `kernelEnv`.

#### 2.5 `checkExpr : Env -> TOpt.Expr -> List Failure`
Recursive traversal over every expression constructor.

**Critical checks to implement:**

##### (A) Case consistency (the MONO_018 catcher)
For `TOpt.Case temp root decider jumps resultType`:
1. Traverse `decider`:
   - If you hit `Inline expr`, require `alphaEqStrict (typeOf expr) resultType`
   - If you hit `Jump i`, record that jump index for validation
2. Validate jump table:
   - Build `Dict Int TOpt.Expr` from `jumps`
   - For every referenced jump index:
     - It must exist
     - Its expression type must satisfy `alphaEqStrict (typeOf jumpExpr) resultType`
3. Recurse into:
   - scrutinee/root vars if represented as expressions in your AST (some case forms store names)
   - all `Inline` and jump expressions

This aligns with how typed-case optimization is assembled: `Case.optimize ... resultType = TOpt.Case ... resultType` , so a mismatch indicates typed optimization produced inconsistent type annotations.

##### (B) VarLocal binding consistency
On `TOpt.VarLocal name ty`:
- If `name` exists in `env.locals`, require `alphaEqStrict ty boundTy`

##### (C) VarKernel vs KernelTypeEnv
On `TOpt.VarKernel home name ty`:
- If kernelEnv has an entry for `(home,name)`, require `alphaEqStrict ty kernelTy`

This is directly tied to typed optimization’s documented “lookup kernel types” behavior  and PostSolve’s role in producing the kernel env .

##### (D) Standard recursion
Recurse through:
- function bodies
- let/letrec bodies
- call func + args
- if branches and condition
- destruct/tuple/record/list subexprs
- decision tree substructures

#### 2.6 Failure reporting
Define:
```elm
type alias Failure =
  { context : List String
  , expected : Can.Type
  , actual : Can.Type
  }
```

Include context frames like:
- `"Case result"`
- `"Case inline leaf"`
- `"Case jump target #3"`
- `"VarLocal x"`
- `"VarKernel Basics.add"`

Print enough info to reproduce.

---

### Change 3 — Update/rename the existing “OptimizeEquivalent” test (optional but recommended)

**Why**
You observed that the current test compares Erased vs Typed output while explicitly ignoring types, which is useful but it is **not TOPT_004** (and doesn’t implement the TOPT_004 logic described in the invariant doc ).

**Edit file**
- Wherever your current “erased vs typed equivalence ignoring types” test lives (commonly named something like `OptimizeEquivalent.elm`).

**Change**
- Rename the test label/invariant tag to something like:
  - `TOPT_EQUIV_STRUCTURE` (new)
  - or keep `TOPT_*` naming but not `TOPT_004`

**Write-up**
- “This test verifies structural equivalence between erased and typed optimization outputs; it intentionally ignores type annotations and therefore does not check type preservation.”

(No compiler behavior changes, just correctness of the invariant catalog.)

---

### Change 4 — Update invariant documentation to match implementation

**Edit file**
- **Path:** `design_docs/invariant-test-logic.md`

**Change**
- Under TOPT_004, replace the “derive expected type from input via local rules” description with the precise implemented checks:
  - Case/decider inline+jump consistency
  - VarLocal env match
  - VarKernel env match (when present)
  - recursion

The doc already defines TOPT_004 generally , but you want it to reflect what you actually enforce so future engineers don’t assume broader coverage than exists.

---

## Optional tightening (once the current failures are fixed)

### Optional A — If condition must be Bool (selective)
If your TypedOptimized `If` constructor stores the condition expression explicitly and you can recognize `Bool` type canonically, add:
- `alphaEqStrict (typeOf cond) Bool`

This is safe only if you’re sure the `Can.Type` attached to the condition is expected to be concrete Bool at this phase (it often is; typed optimization theory assigns literals concrete types , but variables can still be polymorphic depending on where types were lost).

### Optional B — Destructor/path typing checks
You asked earlier about destructor typing vs patterns. I’d keep this out of TOPT_004 initially because:
- it’s more naturally a separate invariant (“paths are well-typed”) and may require global type env knowledge for custom types.
- but you *can* add it later using the global type environment infrastructure used by monomorphization (see type-env dependent path computation in monomorphization specialization code ).

---

## Why these changes catch MONO_018 earlier

MONO_018 failures manifest when `Can.TVar` placeholders escape into monomorphization and become `Mono.MVar _ CEcoValue`. Your strict TOPT_004 case-branch check fails *before monomorphization* whenever a case has:
- `resultType = List Int`
- but an inline/jump branch is annotated `List a`

This is exactly the inconsistency that `Compiler.Optimize.Typed.Case.optimize` is supposed to prevent by stamping a single `resultType` on the whole case , and it’s a direct violation of typed optimization’s “preserve types everywhere” contract .

---

## Next step (triage guidance, since you now see real failures)

Given your report that strict TOPT_004 now finds real issues:
1. Treat the new failures as **compiler bugs**, not test bugs, unless you can demonstrate a legitimate polymorphic case where the case result is intentionally more general than its branches (that would be very surprising in TypedOptimized).
2. For each failing case:
   - locate where that `TOpt.Expr`’s type annotation is assigned in `compiler/src/Compiler/Optimize/Typed/Expression.elm` / `Case.elm` (typed optimization implementation is explicitly responsible for attaching looked-up types )
   - check whether the annotation comes from:
     - the PostSolve-fixed `nodeTypes`
     - or from a stale/unfixed source
     - or is being synthesized without substitution

If you paste one concrete failing minimized module + the exact failure output (expected/actual types + expression constructor path), I can point to the most likely responsible transformation site in typed optimization and suggest the smallest correct fix.

## USER
 Test Failure Analysis Report

  Summary
  ┌───────────────────────────────────────────┬──────────┬─────────────────────┐
  │                   Test                    │ Failures │       Status        │
  ├───────────────────────────────────────────┼──────────┼─────────────────────┤
  │ TOPT_004 TypedOptimized type preservation │ 4        │ FAILED              │
  ├───────────────────────────────────────────┼──────────┼─────────────────────┤
  │ Total tests                               │ 95       │ 91 passed, 4 failed │
  └───────────────────────────────────────────┴──────────┴─────────────────────┘
  ---
  Failure Categorization

  All 4 failures share a single root cause: Polymorphic type variables not resolved to concrete types.
  #: 1
  Test Name: Closure in case branch
  Expression: \x -> x (case branch)
  Stored Type: Int -> a
  Expected Type: Int -> Int
  ────────────────────────────────────────
  #: 2
  Test Name: Case returns curried ternary function
  Expression: \a b c -> a etc. (3 branches)
  Stored Type: Int -> Int -> Int -> a
  Expected Type: Int -> Int -> Int -> Int
  ────────────────────────────────────────
  #: 3
  Test Name: If with variable condition
  Expression: cond (VarLocal)
  Stored Type: a
  Expected Type: Bool
  ────────────────────────────────────────
  #: 4
  Test Name: Nested list pattern
  Expression: first (case branch)
  Stored Type: List a
  Expected Type: List Int
  ---
  Compiler Phase: PostSolve

  Root Cause Location: compiler/src/Compiler/Type/PostSolve.elm

  The failures originate in the PostSolve phase, which populates the NodeTypes dictionary that TypedOptimized consumes.

  Key Code Path

  1. TypedCanonical.toTypedExpr (line 212-228): Looks up expression types from exprTypes
  2. PostSolve.postSolveCase (line 771-792): Processes case branches without enforcing result type matching
  3. PostSolve.postSolveLambda (line 1007-1041): Builds function type from arg/body types

  Problem Analysis

  In postSolveLambda:
  bodyType =
      case body of
          A.At _ info ->
              Dict.get Basics.identity info.id nodeTypes2
                  |> Maybe.withDefault (Can.TVar "b")

  The body type is taken directly from nodeTypes2 without unification against the expected context. When the body is a variable like varExpr "a", its type is whatever the solver determined, which may be polymorphic (a) even when context requires it to be concrete (Int).

  ---
  Bug Shape

  This is the MONO_018-class bug the strict TOPT_004 was designed to catch:

  Case expression type:     List Int
  Branch expression type:   List a     ← VIOLATION (polymorphic remnant)

  The type solver correctly types the case expression, but individual branch expressions retain their polymorphic types because PostSolve doesn't:
  1. Propagate the case result type constraint down to branches
  2. Unify branch types with the expected result type

  ---
  Affected Test Cases

  1. closureInCaseBranch: Lambda \x -> x should be Int -> Int, not Int -> a
  2. caseReturnsCurriedTernaryFn: Lambda \a b c -> a should return Int, not a
  3. ifWithVariableCondition: Variable cond bound as True : Bool used as a
  4. nestedListPatternTest: Pattern variable first : List Int used as List a

  ---
  Conclusion

  The TOPT_004 strict alpha-equivalence is working correctly. It is detecting real type preservation violations in the compiler pipeline.

  The fix belongs in PostSolve (not TOPT_004). PostSolve needs to:
  1. Propagate context types (case result type, binding type) to constrain branch/variable expression types
  2. Or ensure the solver's constraint generation captures these relationships

===

Is this analysis correct ?

## ASSISTANT
Your conclusion that **the strict TOPT_004 failures are “real” inconsistencies in the types attached to TypedOptimized** is correct.

But the attribution “the fix belongs in PostSolve because PostSolve must propagate context and unify branch types” is **only partially supported**, and in a couple of your examples it’s quite likely **not the right root cause**.

### What your failures *definitively* mean

1. **TypedOptimized `Case` is being stamped with a single `resultType`**, and branch bodies are carrying types that do not match it. That is a genuine internal inconsistency: `TOpt.Case ... resultType` is constructed with the passed-in `resultType` and does not compute it from branches. See `Compiler.Optimize.Typed.Case.optimize`, which sets the `resultType` field directly when building `TOpt.Case` .

2. Typed optimization is *supposed* to attach looked-up types everywhere (VarLocal, VarKernel, function types, etc.) , and the typed pipeline is wired so typed optimization consumes PostSolve’s `nodeTypes` and `kernelEnv` . So if you see `VarLocal cond : a` but your local env expects `Bool`, **some earlier phase produced (or later preserved) a wrong type annotation for that occurrence**.

So: **yes, strict TOPT_004 is doing its job**—it is no longer hiding polymorphic remnants.

---

## Where your analysis overreaches

### A) “PostSolve doesn’t enforce result type matching in cases”
This is not a documented responsibility of PostSolve.

PostSolve’s documented responsibilities are:
- fill in missing structural types for certain “Group B” expressions
- infer kernel function types from usage (KernelTypeEnv)
and in particular the “postSolveCase” behavior described in the theory is about **kernel env first-usage** behavior, not branch/result type unification .

In *normal* Elm typing, **the solver** is what guarantees:
- the case’s overall type equals each branch body type
- an `if` condition is `Bool`

So if you have:
- case type is concrete `List Int`
- but a branch body expression is recorded as `List a`

then either:
1) **the solver nodeTypes were already inconsistent** (constraint gen / solver bug), *or*
2) **PostSolve overwrote some expression IDs with “structural” types computed from still-unresolved children**, leaving a remnant, *or*
3) **TypedCanonical/TypedOptimized is looking up the wrong IDs** (very plausible for the “if condition VarLocal” example), so you’re attaching the wrong `Can.Type` to that node.

PostSolve “unifying branch type against the case result type” could be made to *paper over* some of these, but it would be compensating for a deeper mismatch—and it’s easy to make it unsound if applied broadly.

### B) The `if` condition failure is a red flag for a different bug class
This one is especially suspicious:

- `cond` used as an `if` condition
- stored type: `a`
- expected: `Bool`

In Elm, the solver should hard-constrain `if` conditions to `Bool`. If nodeTypes for the condition expression ID is `a`, I would first suspect:
- **constraint generation didn’t impose the Bool constraint** (typechecking bug), or
- **TypedCanonical/TypedOptimized attached the wrong type to that VarLocal occurrence** (ID mismatch / lookup bug), not “PostSolve didn’t propagate context”.

Typed optimization’s own “variables carry their looked-up types” rule suggests it’s doing a lookup; a wrong lookup key would produce exactly this kind of error .

---

## What I’d change in the report (recommended wording)

Instead of:

> “The fix belongs in PostSolve. PostSolve needs to propagate context types (case result type, binding type)…”

Use:

> These failures indicate **type annotations on some TypedOptimized expressions do not match the types required by their enclosing constructs** (case result type, if condition type, etc.). Since typed optimization is meant to preserve and attach inferred types  and consumes PostSolve-fixed nodeTypes/kernelEnv , the root cause is likely one of:
> 1) **inconsistent nodeTypes from the solver** (constraint gen / solver bug),
> 2) **PostSolve failing to fully resolve/fill certain placeholder types for specific expression IDs**, or
> 3) **a type lookup/ID association bug while building TypedCanonical or TypedOptimized**, causing the wrong type to be attached to a node.

---

## Minimal next debugging step (to pinpoint blame correctly)

For each failing example, grab the **expression ID(s)** involved and compare:

1. `nodeTypesPre[id]` (solver output)
2. `nodeTypesPost[id]` (after PostSolve)

If:
- `pre` is already polymorphic (`a`) where it must be concrete ⇒ likely **constraint gen/solver/ID issue**, not PostSolve.
- `pre` is concrete but `post` becomes polymorphic ⇒ **PostSolve regression** (it overwrote a good type).
- `pre` and `post` are fine, but TypedOptimized stores the wrong thing ⇒ **TypedCanonical/TypedOptimized lookup bug**.

That will tell you whether “fix belongs in PostSolve” is actually true for these 4 failures.

If you paste one failure’s expression IDs and the `(preType, postType)` for each relevant node (case node, branch body node, lambda node, var occurrence node), I can help you classify it into (1)/(2)/(3) very quickly.

## USER
Write a guide to fixing this issue, starting with the most likely cause and fix, and also offering as many alternative cause/fix descriptions as are reasonable, given the probability of earlier ones fixing the issue. This is an outline guide to implementing a fix that an engineer could use as a checklist or worklist to cover to find the correct solution.

## ASSISTANT
Below is a **worklist / checklist guide** for fixing the TOPT_004 failures (polymorphic remnants like `List a`, `Int -> a`, `a` where concrete is required). It is ordered by **most likely** causes to check/fix first, then progressively less likely alternatives.

This guide assumes the current situation:

- Typed optimization is supposed to attach looked-up types everywhere 【】.
- Typed compilation runs typecheck + PostSolve to produce `nodeTypes` + `kernelEnv`, then typed optimization consumes those outputs 【】.
- `TOpt.Case` is built with a single `resultType` that is stamped onto the case node 【】, so branch expressions whose stored types don’t match are internal inconsistencies that TOPT_004 should catch.

---

## 0) First make the bug class concrete (quick triage checklist)

For **each failing TOPT_004 assertion**, capture these facts:

1. The **TypedOptimized expression path** where it fails:
   - `Case → Decider Inline branch`
   - `Case → Jump target`
   - `If → cond`
   - `VarLocal lookup`
2. The relevant **expression IDs** from TypedCanonical / nodeTypes:
   - `caseExprId`
   - each `branchBodyExprId`
   - `ifCondExprId`
   - the exprId for the lambda body and the var occurrence inside it
3. Compare types at three points:
   - `nodeTypesPre[id]` (solver output)
   - `nodeTypesPost[id]` (after PostSolve)
   - `type attached in TypedOptimized` (what TOPT_004 sees)

**Classification rule:**

- If `pre` is already wrong → suspect **solver / constraint generation / ID association** (later sections).
- If `pre` ok but `post` wrong → suspect **PostSolve overwrote something incorrectly**.
- If both `pre` and `post` ok but TypedOptimized wrong → suspect **TypedCanonical→TypedOptimized lookup / environment bug**.

Do not start “fixing PostSolve by unifying branch types” until you’ve done this classification, because it can mask deeper issues.

---

## 1) Most likely: wrong `exprId → type` association during TypedCanonical / TypedOptimized construction

### Why this is high probability
Your failures include cases like:

- `if` condition stored type is `a` but expected `Bool`

In Elm typing, the solver should strongly constrain `if` conditions to `Bool`. If your `nodeTypesPost[condId]` is actually `Bool` but the TypedOptimized node stores `a`, that’s almost always a lookup/ID mismatch rather than a type inference weakness.

Also: typed optimization’s own spec says variables carry looked-up types 【】—so if it’s wrong, it’s often because the wrong key was looked up (wrong exprId, wrong map, shadowing bug, etc.).

### Checklist to confirm
- For the failing `If`, print:
  - `condExprId`
  - `nodeTypesPost[condExprId]`
  - `TOpt` condition expression’s stored type
- If those differ: you have an association bug.

### Fix patterns
1) **TypedCanonical.toTypedExpr uses the wrong ID**
- Symptom: nested AST nodes reuse parent IDs or child IDs aren’t the ones looked up.
- Fix: ensure every `A.At _ info` uses `info.id` for lookup, and that you never accidentally use a parent `info` when descending.

2) **Wrong nodeTypes map passed to TypedCanonical**
- Symptom: typed pipeline uses pre-PostSolve nodeTypes rather than post-PostSolve.
- Verify in the compilation wiring that typed optimization is fed the PostSolve-fixed nodeTypes (compileTyped is explicitly supposed to do this) 【】.
- Fix: ensure the `nodeTypes` value inside the `{ annotations, typedCanonical, nodeTypes, kernelEnv }` record returned by typed typecheck is *post-PostSolve*.

3) **Typed optimization rebuilds types instead of using attached types**
- Symptom: some constructors compute new types using local heuristics, not `typeOf` or nodeTypes.
- Fix: for each expression transformation in `Compiler/Optimize/Typed/Expression.elm`, make sure the final `Can.Type` attached is either:
  - pulled from the already typed input expression, or
  - looked up from the correct env/nodeTypes.

---

## 2) Next likely: PostSolve does not fully fill *specific* placeholder TVars for some expression IDs

### Why this is plausible
PostSolve is responsible for “Group B” structural types and for producing stable nodeTypes suitable for typed optimization 【】, and you already have evidence of “synthetic placeholder TVars” escaping.

However: don’t assume PostSolve must “propagate context”; the normal expectation is that solver constraints already force case branch types and if conditions. PostSolve should mostly be *filling in missing shapes* and kernel env.

### Checklist to confirm
For each failing ID where you see a polymorphic remnant in TypedOptimized:
- Check `nodeTypesPre[id]`:
  - If it’s a bare TVar placeholder (often numeric in your ecosystem), PostSolve should fill it.
- Check `nodeTypesPost[id]`:
  - If it’s still `TVar _` (or contains one), PostSolve failed to fill it.

### Common PostSolve failure modes & fixes
1) **PostSolve only fills the parent expression but not children**
- Example: case result type is fixed, but branch body expr IDs remain as placeholders.
- Fix approach:
  - When PostSolve computes a “context expected type” (e.g. case result type), it should be able to *apply that expected type* to the branch body nodes if those nodes were placeholders.
  - Concretely: “if branch body type is a synthetic placeholder TVar, overwrite it with the case result type” (only for synthetic placeholders, not general TVars).

2) **PostSolveLambda builds function type from arg/body types, but body stays placeholder**
- If the lambda’s body type is a leftover placeholder, you get `Int -> a`.
- Fix: same principle—if the lambda expression ID itself had a placeholder and PostSolve is responsible for structural typing, PostSolve must ensure the lambda’s body is looked up after all relevant children have been post-solved.

3) **Traversal order bug**
- PostSolve might compute a parent structural type before it has fixed child types.
- Fix: ensure PostSolve processes children first, then uses updated nodeTypes to compute parent.

**Important safety rule:** only “force” a child expression’s type from context when the child is clearly a *solver-generated placeholder* (your numeric TVar heuristic, or synthetic expr id set). Avoid rewriting legitimate polymorphic user TVars.

---

## 3) Medium likelihood: Case decision tree / branch handling stamps the wrong result type, or typed-case optimizer mismaps branches

### Why check this
`Compiler.Optimize.Typed.Case.optimize` takes an explicit `resultType` and stamps it onto the `TOpt.Case` node 【】. If that `resultType` is incorrect, TOPT_004 will report mismatch even if branches are correct.

### Checklist to confirm
For a failing case:
- Find the case node’s expression ID in TypedCanonical.
- Compare `nodeTypesPost[caseExprId]` vs the `resultType` passed into `Case.optimize`.
  - They should match exactly.

### Fix patterns
1) **Result type fetched from wrong ID**
- Fix: ensure the case expression’s ID is used to look up result type, not the scrutinee’s ID or a branch ID.

2) **Jump targets refer to the wrong branch expressions**
- In `Case.optimize`, jumps are created from indexed branches and stored as `(Int, expr)` pairs 【】.
- If indices are mismatched, you may compare case result type against a different expression than intended.
- Fix: validate `indexify` / insertion logic and any later transformation that reorders branches.

---

## 4) Medium likelihood: Typed optimization’s VarLocal environment tracking is incorrect (shadowing / let / destruct / function params)

### Why this matters
TOPT_004 checks `VarLocal name : ty` against an expected env type. If typed optimization binds the wrong type to a name, you’ll see spurious mismatches.

### Checklist to confirm
For the failing “If with variable condition”:
- Is `cond` truly a local bound to `Bool`, or is it a different `cond` shadowed by a pattern/let?
- Compare:
  - the binder’s recorded type (from nodeTypesPost at the binder ID)
  - what typed optimization inserts into its env

### Fix patterns
- Ensure env insertion uses the type from the correct binder node, and that destructuring binders use pattern IDs consistently.
- Ensure environment is pushed/popped correctly for:
  - `Let`
  - `LetRec`
  - function params
  - destruct patterns

---

## 5) Lower likelihood but important: solver/constraint-generation isn’t enforcing the constraints you assume

### Why this is possible
If you find that `nodeTypesPre[ifCondId]` is already `TVar a`, that indicates a genuine inference bug: the solver never constrained the condition to `Bool`.

### Checklist to confirm
- Inspect `nodeTypesPre` for the condition expression ID:
  - if it’s already polymorphic, this is upstream of PostSolve and typed optimization.

### Fix patterns
- Constraint generation for `If` must add a constraint “cond ~ Bool”.
- Constraint generation for `Case` must constrain each branch body type to equal the case result type.
- If you recently introduced typed IDs or new AST forms, it’s easy to miss these constraints.

---

## 6) If you need a “stopgap” fix: PostSolve contextual patching (use only if classification proves PostSolve is at fault)

If classification shows:
- solver pre-types are placeholders for particular IDs, and
- PostSolve is responsible for resolving them, and
- they remain unfilled post-PostSolve,

then a pragmatic fix is:

- In `postSolveCase`, when you know the case result type (from `nodeTypes[caseExprId]`), ensure each branch body expression ID is not left as a synthetic placeholder:
  - if branch body is a synthetic placeholder TVar → set it to case result type
- Similarly for `postSolveIf`, ensure:
  - condition expr id is `Bool` if it’s a synthetic placeholder
  - each branch expr id matches the `if` expression type if they are synthetic placeholders

This is consistent with PostSolve being the “fix-up” pass that produces nodeTypes usable by downstream typed optimization 【】, but again: apply only to **clearly synthetic placeholders**, not general polymorphic types.

---

## 7) Validation checklist after implementing a fix

1) Re-run TOPT_004 (strict) and confirm the 4 failures disappear.
2) Re-run POST invariants (especially the “no synthetic holes remain” type of checks described in the invariant doc) 【】.
3) Ensure you did not reintroduce the old problem where tests explode due to legitimate polymorphism:
   - Accessors are intentionally polymorphic shapes (`{ ext | x : a } -> a`)—this is known and should remain legal.
4) If you add PostSolve contextual patching, add targeted tests that:
   - demonstrate the placeholder IDs are synthetic
   - prove you didn’t rewrite a legitimate polymorphic expression

---

## Most efficient next action (if you want the shortest path)
Do the classification step (Section 0) for **one** failing example (the `if` condition is usually the clearest). Once you know whether:
- `nodeTypesPost[condId]` is `Bool` or `a`,
you’ll immediately know whether to focus on:
- TypedCanonical/TypedOptimized association bugs (most likely), or
- PostSolve fill/traversal, or
- constraint generation.

If you paste the `(condExprId, nodeTypesPre, nodeTypesPost, typedOptimizedStoredType)` for the failing `if`, I can tell you which branch of this guide you should pursue first and what file/function is the most likely culprit.

## USER
  Confirmed Bug Location

  File: compiler/src/Compiler/Type/Constrain/Typed/Expression.elm
  Function: constrainGenericWithIdsProg (lines 404-418)

  The Bug

  constrainGenericWithIdsProg rtv region info expected =
      Prog.opMkFlexVarS
          |> Prog.andThenS
              (\exprVar ->
                  -- Records exprVar for this expression ID
                  Prog.opModifyS (NodeIds.recordSyntheticExprVar info.id exprVar)
                      |> Prog.andThenS
                          (\() ->
                              constrainNodeWithIdsProg rtv region info.node expected
                                  |> Prog.mapS
                                      (\con ->
                                          -- BUG: exprVar is existentially quantified but NEVER CONSTRAINED
                                          Type.exists [ exprVar ] con
                                      )
                          )
              )

  Problem: The synthetic exprVar is:
  1. Created as a fresh FlexVar
  2. Recorded in nodeVars for the expression ID via recordSyntheticExprVar
  3. Never unified with anything - just existentially quantified

  After solving, exprVar remains a free FlexVar → becomes TVar "a" in nodeTypes.

  Contrast with Working Group A Expressions

  For example, constrainCallWithIdsProg (line 1183):

  constrainCallWithIdsProg rtv region exprId ... expected =
      ...
      Prog.opMkFlexVarS
          |> Prog.andThenS
              (\resultVar ->
                  -- Records resultVar for this call expression  
                  Prog.opModifyS (NodeIds.recordNodeVar exprId resultVar)
                      |> ...
                      -- CORRECT: resultVar is unified with expected
                      CEqual region category resultType expected
              )

  The key difference: Group A expressions unify their recorded variable with expected.

  Affected Expressions (Group B going through generic path)

  From constrainWithIdsProg (lines 365-394), the following go through constrainGenericWithIdsProg:
  - Can.VarLocal → CLocal constraint, but exprVar never unified
  - Can.Lambda → lambda constraints generated, but exprVar never unified
  - Can.VarTopLevel, Can.VarKernel, Can.VarForeign, etc.
  - Can.Str, Can.Chr, Can.Float, Can.List, Can.Tuple, Can.Record, etc.

  Trace for Each Failing Test

  1. "If with variable condition" - VarLocal cond has type a instead of Bool

  let cond = True in if cond then 1 else 0
                        ^^^^

  1. cond VarLocal goes through constrainGenericWithIdsProg
  2. Creates exprVar, records as synthetic placeholder for cond's expr ID
  3. constrainNodeWithIdsProg generates CLocal region "cond" expected
  4. expected = Bool (from If condition context)
  5. CLocal correctly looks up cond in env and unifies with Bool
  6. But exprVar is never touched - stays free FlexVar
  7. nodeTypes[cond_expr_id] = TVar "a"

  2. "Closure in case branch" - Lambda has type Int -> a instead of Int -> Int

  case m of
      Just n -> \x -> x + n  -- lambda type should be Int -> Int

  1. Lambda goes through constrainGenericWithIdsProg
  2. Creates exprVar, records as synthetic placeholder
  3. constrainLambdaWithIdsProg generates proper lambda constraints
  4. But exprVar is never unified with the lambda's function type
  5. nodeTypes[lambda_expr_id] = TVar "a"
  6. PostSolve's postSolveLambda builds type from arg/body types
  7. If body also has placeholder issues, result is Int -> a

  3. "Nested list pattern" - Result first has type List a instead of List Int

  case xss of
      first :: _ -> first  -- first should be List Int

  1. first VarLocal goes through constrainGenericWithIdsProg
  2. Same issue as #1 - exprVar never unified
  3. nodeTypes[first_varlocal_id] = TVar "a"

  4. "Case returns curried ternary" - Lambdas have type Int -> Int -> Int -> a

  Same pattern as #2, but with 3-argument lambdas.

  Root Cause Category

  PostSolve does NOT fix this because:
  - PostSolve trusts solver types for VarLocal: Can.VarLocal _ -> ( nodeTypes0, kernel0 )
  - PostSolve builds Lambda types from children, but if children have placeholder issues, the problem propagates

  The issue is upstream in constraint generation, not PostSolve.

  Fix Approach

  In constrainGenericWithIdsProg, the exprVar must be unified with expected:

  constrainGenericWithIdsProg rtv region info expected =
      Prog.opMkFlexVarS
          |> Prog.andThenS
              (\exprVar ->
                  Prog.opModifyS (NodeIds.recordSyntheticExprVar info.id exprVar)
                      |> Prog.andThenS
                          (\() ->
                              constrainNodeWithIdsProg rtv region info.node expected
                                  |> Prog.mapS
                                      (\con ->
                                          Type.exists [ exprVar ]
                                              (CAnd
                                                  [ con
                                                  -- FIX: Unify exprVar with expected
                                                  , CEqual region Literal (VarN exprVar) expected
                                                  ]
                                              )
                                      )
                          )
              )

  Or alternatively, expressions that need tracking should be moved to Group A with proper recording, similar to how constrainCallWithIdsProg handles Call expressions.

===

Examine this bug analysis carefully and give your opinion on its correctness.

## ASSISTANT
Your bug analysis is **substantially correct**, and the file you pointed at demonstrates the exact problem: **the “synthetic exprVar” that gets recorded for an expression ID is never connected to the constraint graph**, so it can solve to an arbitrary free variable and then shows up as a polymorphic remnant in `nodeTypes`.

### What the code proves

In `constrainWithIdsProg`, everything not in the explicit “Group A” list goes through `constrainGenericWithIdsProg` . That generic path:

- creates `exprVar` (`opMkFlexVarS`)
- records it via `NodeIds.recordSyntheticExprVar info.id exprVar`
- generates constraints for the expression using `constrainNodeWithIdsProg ... expected`
- then returns `Type.exists [ exprVar ] con` **without ever mentioning `exprVar` inside `con`** 

So yes: `exprVar` is existentially quantified but **unused** ⇒ unconstrained ⇒ solver leaves it free ⇒ when you later translate solver vars to `Can.Type`, that ID’s type becomes `TVar "a"`-shaped.

This is made even clearer by the doc comment directly above `constrainGenericWithIdsProg`, which claims it is “adding a CEqual to connect exprVar to the expected type” — but it doesn’t .

### Why your “VarLocal cond in if condition” trace is correct

`constrainNodeWithIdsProg` for `Can.VarLocal name` returns `CLocal region name expected` . That means the *program typing* constraints can still correctly enforce that `cond` is `Bool` (via whatever `CLocal` does internally).

But the **expression-id-to-type** mapping for `cond` is recording `exprVar`, and since `exprVar` never appears in the constraint, the mapping is effectively disconnected from the real typing constraint. That explains exactly how you can end up with:

- environment/binding knows `cond : Bool`
- but `nodeTypes[condExprId] = TVar a`

So the core diagnosis (“ID tracking variable is never unified with expected”) is correct.

### Why your “Lambda has Int -> a” story is plausible

`constrainLambdaWithIdsProg` *does* generate a `CEqual region Lambda props.tipe expected` constraint, i.e. it ties the lambda’s *computed function type* to the surrounding expected type .

However, if the **lambda expression ID** itself is recorded via `recordSyntheticExprVar` (because it routes through the generic wrapper), and that recorded `exprVar` is never equated to anything, then `nodeTypes[lambdaExprId]` will be the unconstrained TVar instead of the actual lambda type. PostSolve may try to rebuild lambdas structurally, but it can still be polluted if it consults `nodeTypes` for body/child nodes that have the same “disconnected exprVar” issue (e.g. `VarLocal` occurrences) or if PostSolve only partially fixes lambdas.

So your *mechanism* is right: the type solver may know the lambda’s real type, but the `nodeTypes` entry for that expression ID can still be wrong because it’s mapped to the wrong solver var.

### Your proposed fix is the right minimal fix

Conceptually: **either**
1) stop allocating a fresh variable for an expr ID if you can record an existing one, **or**
2) if you allocate it, you must constrain it.

Given the current structure, the minimal, correct repair is: in `constrainGenericWithIdsProg`, return:

- `Type.exists [exprVar] (CAnd [ con, CEqual region <someCategory> (VarN exprVar) expected ])`

That is exactly what the comment says it should have been doing, and it matches the “working” Group A pattern where recorded vars are tied to expected via `CEqual ... expected` (e.g. `constrainCallWithIdsProg` records `resultVar` and later uses `CEqual ... resultType expected`) .

### One nuance: pick the right Category

In your sketch you used `Literal`. That will *work for unification*, but for good error reporting you probably want a category that corresponds to “expression result” rather than “literal”. The existing code uses categories like `Lambda`, `If`, `Case`, etc. in its `CEqual`s  . So the only adjustment I’d make to your fix is: use a sensible category (maybe a new one like `Expr` or `GenericExprResult`) rather than `Literal`.

### Alternative “better” fix (optional)

For some nodes routed through the generic path, you can avoid the extra `exprVar` entirely by recording an already-existing variable:

- Patterns already do this optimization when expectation contains a `VarN` (they record the existing var rather than creating a new one) .
- You could do something similar for expressions: if `expected`’s type is `VarN v`, record `v` directly for the expr id (like Group A helpers do), otherwise create a fresh var + constrain.

But you don’t need that to fix correctness; the “add missing CEqual” fix is the right first step.

**Bottom line:** your analysis correctly identifies a real bug in the typed constraint generation with IDs; the code as written clearly disconnects the recorded exprVar from the constraint graph , and adding the missing `CEqual` is the correct minimal fix.

## USER
 Analysis Report: PostSolve Non-Regression Test Failure

  Test Run Summary

  Test: Compiler.Type.PostSolve.PostSolveNonRegressionInvariantsTest
  Result: 1 failure out of 95 tests

  ---
  1. Failure Categorization
  Category: POST_005: PostSolve type overwriting
  Count: 1
  Compiler Phase: Type Reconstruction (PostSolve)
  Description: PostSolve overwrites solver-structured types
  Failing Test

  - Test Name: "Array type variable scoping non-regression" (slice function)
  - Invariant: POST_005 (PostSolve does not rewrite solver-structured node types)

  ---
  2. Failure Details

  POST_005 violation at nodeId 84 (Other):
    preType:  TType (Array) [TVar "a"]
    postType: TVar "a"
    details:  PostSolve changed structured type

  POST_005 violation at nodeId 83 (Other):
    preType:  TType (Array) [TVar "a"]
    postType: TVar "a"
    details:  PostSolve changed structured type

  Meaning: The type solver correctly determined Array a for expressions with node IDs 83 and 84, but PostSolve changed these to TVar "a".

  ---
  3. Root Cause Investigation

  Affected Function: postSolveLetType

  Location: compiler/src/Compiler/Type/PostSolve.elm:507-518

  postSolveLetType exprId body nodeTypes0 kernel0 =
      let
          bodyType =
              case body of
                  A.At _ info ->
                      Dict.get Basics.identity info.id nodeTypes0
                          |> Maybe.withDefault (Can.TVar "a")

          nodeTypes1 =
              Dict.insert Basics.identity exprId bodyType nodeTypes0
      in
      ( nodeTypes1, kernel0 )

  Bug Mechanism

  1. Solver Phase: The type solver correctly determines Array a for the Let expression (through constraint unification)
  2. PostSolve Phase: When processing Let expressions:
    - postSolveLetType looks up the body's type (the if-expression inside the let)
    - If the body's type isn't in nodeTypes, it defaults to TVar "a"
    - It then unconditionally inserts this type for the Let expression's ID
    - This overwrites the solver's correctly-determined Array a with TVar "a"
  3. Test Case Context: The slice function in the Array test:
  slice : Int -> Int -> Array a -> Array a
  slice from to array =
      let
          correctFrom = translateIndex from array
          correctTo = translateIndex to array
      in
      if correctFrom > correctTo then
          empty
      else
          array |> sliceRight correctTo |> sliceLeft correctFrom
  3. The Let expression has type Array a (from the annotation), but postSolveLetType computes a fallback TVar "a" when it can't find the body's type.

  Pattern Consistency

  This is the same bug pattern we fixed in other PostSolve functions:
  - postSolveList ✓ (fixed)
  - postSolveAccessor ✓ (fixed)
  - postSolveTuple ✓ (fixed)
  - postSolveRecord ✓ (fixed)
  - postSolveLambda ✓ (fixed)
  - postSolveLetType ✗ (NOT fixed - this is the remaining bug)

  ---
  4. Required Fix

  Apply the same "check-before-overwrite" pattern to postSolveLetType:

  postSolveLetType exprId body nodeTypes0 kernel0 =
      -- Check if solver already resolved the type for this let expression
      case Dict.get Basics.identity exprId nodeTypes0 of
          Just _ ->
              -- Solver already resolved the type, trust it
              ( nodeTypes0, kernel0 )

          Nothing ->
              -- No solver type available, compute from body
              let
                  bodyType =
                      case body of
                          A.At _ info ->
                              Dict.get Basics.identity info.id nodeTypes0
                                  |> Maybe.withDefault (Can.TVar "a")

                  nodeTypes1 =
                      Dict.insert Basics.identity exprId bodyType nodeTypes0
              in
              ( nodeTypes1, kernel0 )


===

There are type changes in PostSolve also being detected. Take a close look at this test analysis and check if you think it is correct.

## ASSISTANT
Your analysis is **very likely correct**, and the behavior you’re seeing (solver pre-type is structured `Array a`, but PostSolve changes it to a bare `a`) is consistent with an unconditional overwrite bug in `postSolveLetType`.

### 1) Does PostSolve actually call `postSolveLetType` for `let` / `letrec` / `let destruct`?
Yes. In `postSolveExpr`, the `Can.Let`, `Can.LetRec`, and `Can.LetDestruct` cases all recurse into the body and then call `postSolveLetType exprId body ...` with the comment “Let expression type is the body type” . So a bug in `postSolveLetType` can definitely affect a `let ... in ...` expression’s nodeId type.

### 2) Is “PostSolve overwrites solver-structured types” the correct interpretation of POST_005?
Yes. POST_005 is explicitly: if the solver pre-type is **not** a bare `TVar`, PostSolve must not change it . Your failure example shows:

- preType: `Array a` (structured)
- postType: `a` (bare TVar)

That is exactly a POST_005 violation.

### 3) Is the specific mechanism you describe plausible?
Yes, because other Group B structural fixups in PostSolve have already been switched to a “check-before-overwrite” pattern:

- `postSolveList` checks `Dict.get exprId` and **returns early** if solver already resolved the type 
- `postSolveTuple` does the same 
- `postSolveRecord` does the same 

So it is entirely consistent that `postSolveLetType` might still be using an older “just insert the body type” behavior and therefore can overwrite a solver-determined structured type with a fallback.

Your described version of the buggy logic (“lookup body type, default to `TVar "a"`, then `Dict.insert exprId bodyType` unconditionally”) matches the *kind of* fallback logic used elsewhere in PostSolve when a lookup fails (you can see many `Maybe.withDefault (Can.TVar "a")` patterns in the file, e.g. `postSolveCase`’s `caseResultType` fallback ).

Given your reported symptom includes “it can’t find the body’s type”, it’s completely plausible that the `bodyType` fell back to `TVar "a"` and then overwrote the correct pre-type.

### 4) Is your proposed fix correct?
Yes, the fix you propose is aligned with the established PostSolve approach already used for lists/tuples/records:

> If solver already has a type for `exprId`, trust it and do not overwrite.

That’s exactly what the updated `postSolveList` does , and what `postSolveTuple` does .

So your recommended patch is not only correct for POST_005, it also brings `postSolveLetType` into consistency with the rest of the file.

### 5) One important nuance
Your fix prevents overwriting when `Dict.get exprId nodeTypes0 == Just _`. That’s probably what you want, but there’s one subtle policy decision:

- If solver recorded `exprId -> TVar <placeholder>` for some reason, you might still want PostSolve to fill it from the body.
- But POST_005’s rule is about “don’t rewrite solver-structured types”; it allows rewriting bare TVars (placeholders). The existing pattern in `postSolveList`/tuple/record is even stricter: it trusts *any* `Just`, not only structured types  .

So your proposed fix is consistent with the codebase’s current approach.

---

## Conclusion

- The reported POST_005 failure (structured `Array a` becoming bare `a`) is a **legitimate regression** per the invariant definition .
- The hypothesized cause (unconditional overwrite in `postSolveLetType` with fallback `TVar "a"`) is **highly plausible** and consistent with how similar PostSolve functions have previously been fixed  .
- The proposed fix (“check-before-overwrite”) is the correct remediation pattern and matches existing PostSolve code.

If you want, paste the actual `postSolveLetType` implementation as it exists in your working tree right now (or the relevant snippet), and I’ll confirm line-for-line that it matches your diagnosis and suggest the exact patch shape (including the “only overwrite if missing vs only overwrite if bare TVar” choice).

## USER
Analysis Report: MonoCaseBranchResultType Test Failure

  Test Run Summary

  Test: Compiler.Generate.Monomorphize.MonoCaseBranchResultTypeTest
  Result: 1 failure out of 95 tests

  ---
  1. Failure Categorization
  Category: MONO_018: Lambda staging inconsistency
  Count: 1
  Compiler Phase: Monomorphization
  Description: Branch MonoType differs from Case resultType due to lambda currying vs flattening
  ---
  2. Failure Details

  Test Name: "Case returns differently staged lambdas"

  SpecId 0 inline-leaf: MONO_018 violation: inline leaf type != MonoCase resultType
    resultType: MFunction [MInt] (MFunction [MInt] MInt)
    inline type: MFunction [MInt,MInt] MInt

  Meaning:
  - resultType: Curried representation Int -> (Int -> Int)
  - inline type: Flat/uncurried representation (Int, Int) -> Int

  These are semantically equivalent in Elm but have different MonoType representations.

  ---
  3. Root Cause Investigation

  Test Case Code

  selectFn : Selector -> Int -> Int -> Int -> Int
  selectFn sel a =
      case sel of
          UseFlat   -> \b c -> a + b + c     -- Multi-arg lambda
          UseNested -> \b -> \c -> a + b + c -- Nested lambdas

  Bug Mechanism

  Step 1: Case resultType derivation (Specialize.elm:1143-1146)
  TOpt.Case label root decider jumps canType ->
      let
          monoType = TypeSubst.applySubst subst canType
  The Case's canType is Int -> Int -> Int represented as TLambda Int (TLambda Int Int).
  TypeSubst.applySubst preserves this nested structure, producing:
  - MFunction [MInt] (MFunction [MInt] MInt) ← curried

  Step 2: Branch expression specialization (Specialize.elm:260-267)
  effectiveMonoType =
      if isFullyPeelable then
          Mono.MFunction flatArgTypes flatRetType  -- Flattens all args!
      else
          ...
  For the UseFlat branch (\b c -> ...):
  - peelFunctionChain peels both b and c as params
  - isFullyPeelable = True (paramCount == totalArity)
  - Produces MFunction [MInt, MInt] MInt ← flat/uncurried

  Step 3: Type mismatch
  - MonoCase resultType: MFunction [MInt] (MFunction [MInt] MInt)
  - Branch inline type: MFunction [MInt, MInt] MInt
  - These are not equal → MONO_018 violation

  Root Cause Summary

  The monomorphizer has inconsistent lambda staging between:
  1. Type derivation (from TypeSubst.applySubst): Preserves curried structure
  2. Lambda specialization (specializeLambda): Flattens fully-peelable lambdas

  When a Case expression returns a lambda, the Case's resultType follows path (1) while branch expressions follow path (2), causing type mismatches.

===

So now we can look at the actual Monomorphization branch type difference test error.

Is the analysis correct ? How to fix it ?

## ASSISTANT
Your analysis is **basically correct**: the failure is coming from **inconsistent function “staging” (curried vs flattened) inside `MonoType`**, where the *case node* is using one representation and a *branch expression* is using another.

The key fact in the failure is:

- `MonoCase resultType = MFunction [MInt] (MFunction [MInt] MInt)` (curried “Int -> Int -> Int”)
- `inline leaf type = MFunction [MInt, MInt] MInt` (flattened “(Int,Int) -> Int”)

Those are extensionally equivalent in Elm source, but they are **not equivalent for your compiler pipeline unless you also insert wrappers and/or normalize call conventions**, so MONO_018 is right to complain.

---

## Why this is happening (confirmed by the codebase behavior)

1) **Case result type is derived from the `Can.Type` attached to the `TOpt.Case` node**, via substitution:
- `Specialize` (for `TOpt.Case`) does essentially: `monoType = TypeSubst.applySubst subst canType` (your report’s Step 1).
- That produces a *curried* nested `MFunction` chain, because `Can.TLambda` is nested and `applySubst` preserves that staging.

2) **Lambda specialization is sometimes flattening the function type to match a multi-parameter lambda value**, producing `MFunction [a,b] r`.

So you end up with “same semantic function type” represented in two different MonoType shapes depending on which codepath produced it.

This is exactly the class of inconsistency MONO_018 is meant to catch.

---

## How to fix it (recommended approach)

### Fix strategy: pick ONE canonical MonoType representation for functions at monomorphization output

You have two viable directions:

### Option A (recommended): **Canonicalize to curried (staged) MonoType everywhere**
This is the least invasive because it matches the canonical `Can.Type` structure (`TLambda` chain) and tends to preserve partial-application semantics naturally.

**Goal:** ensure that any Mono expression whose type is `Int -> Int -> Int` always uses:
`MFunction [Int] (MFunction [Int] Int)`
and never `MFunction [Int,Int] Int` at the MonoType level.

#### Implementation checklist
1. **In `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`**, locate the lambda specialization logic (your “effectiveMonoType … flattens all args” area).
2. Change the “fully peelable → flatten” branch so it does **not** produce `MFunction [t1,t2,...] r` when the *expected/declared* function type is curried.

Concretely:
- compute `monoTypeFromCan = TypeSubst.applySubst subst canType` (this is the same type the Case node uses)
- use **that** `monoTypeFromCan` as the function’s attached type, not a flattened recomputation.

3. Ensure the *expression shape* matches the *type shape*:
   - If your Mono AST represents lambdas as a single `MonoFunction params body monoType` where `params : List (Name, MonoType)`, then:
     - a **curried type** must correspond to either:
       - nested `MonoFunction` nodes (each stage one param), or
       - a single node but with a type that encodes the same staging convention used elsewhere.
   - Given you currently flatten types to match multi-param `params`, you likely need to **re-curry the lambda expression** when `params` has length > 1.
     - I.e. translate `\b c -> body` into `\b -> (\c -> body)` in the Mono AST, so the *value representation* is staged too.
     - This makes both branches (`UseFlat` and `UseNested`) produce the same MonoType and avoids mismatched case branch types.

4. Add a small helper in `Specialize.elm` (or wherever lambdas are built):

   - `splitFunctionType : MonoType -> Maybe (argType, resultType)` which peels one stage (`MFunction [t] rest`)
   - `buildCurriedFunctionExpr : List (Name, MonoType) -> Mono.Expr -> MonoType -> Mono.Expr`
     - builds nested `MonoFunction` nodes stage-by-stage

5. Re-run:
   - `MonoCaseBranchResultTypeTest` (should pass)
   - any PAP/call-arity tests, because this change affects arity/staging assumptions.

**Why Option A is safest:** it makes the monomorphizer’s output consistent with the `Can.Type` it is derived from, and avoids needing global call-convention changes.

---

### Option B: **Canonicalize to fully-flattened MonoType everywhere**
This means: always represent `Int -> Int -> Int` as `MFunction [Int,Int] Int` (or `[Int,Int,Int]` depending on arity), and eliminate nested `MFunction` staging at the type level.

To do this correctly, you must also ensure:
- case result type is flattened the same way (so `TOpt.Case` resultType becomes flattened)
- call sites / PAP / closure-calling logic uses “total arity” rather than staged arity (this tends to ripple into codegen invariants like remaining_arity)

This option can be good if your backend wants uncurried calling conventions, but it’s typically a larger refactor because partial application becomes wrapper-heavy.

---

## A “test-only” fix is not recommended here

You *could* change `MonoCaseBranchResultTypeTest` to treat curried and flattened function types as “equivalent up to reassociation”, but that would mask a real pipeline consistency problem: later passes will use these types to decide arity/calling conventions, and inconsistent representation will keep causing subtle bugs.

So: keep the test strict; fix the compiler.

---

## Quick sanity check to confirm the right option

Before implementing, answer:

- Does your runtime/codegen treat `Mono.MFunction [a,b] r` as a function taking **two arguments at once** (uncurried), or just as a convenient encoding for a curried chain?

If it’s “two at once”, then Option A is strongly preferred unless you’re also ready to normalize all call conventions.

---

If you paste the relevant `specializeLambda` portion from `Specialize.elm` (the code around your reported “effectiveMonoType” branch), I can give you an exact patch sketch that matches your existing Mono AST constructors and avoids breaking the rest of the pipeline.

## USER
The idea of staged-uncurrying, is to uncurry as much as possible, but where a lambda is inside an enclosing boundary, let..in or case..of, keep it curried as an inner "stage".

selectFn : Selector -> Int -> Int -> Int -> Int
  selectFn sel a =
      case sel of
          UseFlat   -> \b c -> a + b + c     -- Multi-arg lambda
          UseNested -> \b -> \c -> a + b + c -- Nested lambdas

What is the staged-uncurried type of this function? How to handle the braches?

We are not doing Option A or B, but something else... Option C

## ASSISTANT
### What “staged‑uncurrying” means (Option C)

From your description, Option C matches the “**one call stage** = one `Mono.MFunction argTypes resultType`” model, where:

- You **uncurry within a stage as much as possible** (arg list can be length > 1),
- but you **do not merge across staging boundaries** introduced by constructs like `case .. of` / `let .. in`.

This is exactly the intent described in the “still curried at Mono stage” writeup: `MFunction argTypes resultType` is one stage, and the result may itself be another `MFunction` stage .

---

## Staged‑uncurried type of `selectFn`

```elm
selectFn : Selector -> Int -> Int -> Int -> Int
selectFn sel a =
    case sel of
        UseFlat   -> \b c -> a + b + c
        UseNested -> \b -> \c -> a + b + c
```

### Stage boundary
The boundary is the **`case sel of ...`**. The outer function consumes `(sel, a)` and then returns a function value produced by the case.

Because `peelFunctionChain` only peels through nested `Function/TrackedFunction` bodies and stops at the first non-function body (like `Case`) , the outer “stage” is exactly the syntactic params `[sel, a]`.

### Therefore the staged‑uncurried MonoType is:

- **Stage 1:** takes `(Selector, Int)` and returns a function
- **Stage 2:** takes `(Int, Int)` and returns `Int`

So:

```
selectFn : (Selector, Int)  ->  (Int, Int) -> Int
MonoType: MFunction [MSelector, MInt] (MFunction [MInt, MInt] MInt)
```

(Where `MSelector` is whatever MonoType you use for the `Selector` custom type.)

This is the key “Option C” shape: **two stages**, each stage internally uncurried.

---

## How to handle the branches

Both branches are *values returned by the `case`*, so they must have the **same Stage‑2 MonoType**:

- `UseFlat   -> \b c -> ...` naturally becomes `MFunction [Int, Int] Int`
- `UseNested -> \b -> \c -> ...` should *also* become `MFunction [Int, Int] Int` by flattening that pure lambda chain *within the stage*

So branch specialization should normalize both to:

```
Mono.MonoClosure ... (MFunction [MInt, MInt] MInt)
```

This is already aligned with the “fully peelable → uncurried” path in `specializeLambda` (when the lambda chain is “simple” and peelable) .

### The real issue (why you got the MONO_018 mismatch)
Right now your **Case’s resultType** is coming out as the *curried chain*:

```
MFunction [Int] (MFunction [Int] Int)
```

while the branches end up *stage-uncurried*:

```
MFunction [Int, Int] Int
```

So the fix is not “make branches curried”; it’s “make the **case resultType** use the same Option‑C stage normalization as branches.”

---

## Practical “Option C” fix rule for `case` (and similarly `let`)

When specializing a `TOpt.Case ... canType`, do **not** attach `TypeSubst.applySubst subst canType` directly as the MonoCase result type if it is a function type.

Instead:

1. Compute `monoType0 = TypeSubst.applySubst subst canType`
2. If `monoType0` is a function type, **stage‑uncurry that function type into a single stage** (flatten all immediately available arg stages into one arg list) and use that as the `MonoCase` result type.

In terms of helpers you already have in the monomorphizer codebase:
- use `Types.decomposeFunctionType monoType0` (or the equivalent flatten helper you use for “flatArgTypes/flatRetType”) and rebuild:
  - `Mono.MFunction flatArgTypes flatRetType`

This makes the case result type become `MFunction [Int,Int] Int`, matching both branches.

### Why this matches your Option C intent
- The `case` itself is the stage boundary.
- The value it returns is a function **for the next stage**.
- Within that next stage, you want to “uncurry as much as possible” → flatten the function type to one `MFunction` stage.

---

## Summary for this example

- **Desired staged‑uncurried type of `selectFn`:**
  - `MFunction [Selector, Int] (MFunction [Int, Int] Int)`

- **Branch rule:**
  - Both `UseFlat` and `UseNested` branches must specialize to the same stage‑2 type: `MFunction [Int, Int] Int`
  - Achieve by:
    - allowing `specializeLambda` to flatten “pure lambda chains” within a stage 
    - and making the `Case` node’s `resultType` apply the same stage‑uncurry normalization rather than keeping the curried chain.

If you share the current `Specialize.elm` `TOpt.Case` branch (the code that constructs `MonoCase` and attaches its `resultType`), I can give a precise patch that introduces a `stageUncurryFunctionType` helper and applies it only where Option C says it should (case/let boundaries returning function values).

## USER
Compute monoType0 = TypeSubst.applySubst subst canType
If monoType0 is a function type, stage‑uncurry that function type into a single stage (flatten all immediately available arg stages into one arg list) and use that as the MonoCase result type.

## ASSISTANT
Your proposed rule is the right “Option C” normalization point: **the `case..of` expression is a staging boundary**, so if the *result* of the case is a function, we should **collapse that returned function into a single stage** so it matches how branch lambdas are already being specialized (fully-peelable lambdas flatten into `MFunction [a,b,…] ret`). The current inconsistency is visible in `specializeExpr` where `TOpt.Case …` just uses `TypeSubst.applySubst` directly as the stored `MonoCase` type , while `specializeLambda` may flatten into a single-stage `MFunction` using `Types.decomposeFunctionType` .

Below is a concrete, engineer-ready implementation plan.

---

## Design: Stage‑uncurry the *result type* of `MonoCase`

### Goal
When specializing:

```elm
TOpt.Case label root decider jumps canType
```

we currently compute:

```elm
monoType = TypeSubst.applySubst subst canType
```

and store that on `Mono.MonoCase … monoType` .

**Change it to:**

1. Compute `monoType0 = TypeSubst.applySubst subst canType`
2. If `monoType0` is a function type (`Mono.MFunction …`), replace it with a **single-stage function type**:
   - `(flatArgs, flatRet) = Types.decomposeFunctionType monoType0`
   - `Mono.MFunction flatArgs flatRet`
3. Otherwise leave it unchanged.

This makes the case’s stored result type match the representation produced by “fully peelable” branch lambdas (which already flatten).

---

## Code changes (all required edits)

### Change 1 — Add a small helper to normalize boundary-returned function types
**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

**Where to put it:** near the other local helpers in `Specialize.elm` (anywhere top-level in the module is fine; I’d place it near other type helpers like `dropNArgsFromType` / `buildFuncType`).

**Add:**
```elm
stageUncurryBoundaryResultType : Mono.MonoType -> Mono.MonoType
stageUncurryBoundaryResultType monoType0 =
    case monoType0 of
        Mono.MFunction _ _ ->
            let
                ( flatArgTypes, flatRetType ) =
                    Types.decomposeFunctionType monoType0
            in
            Mono.MFunction flatArgTypes flatRetType

        _ ->
            monoType0
```

**Why:** encapsulates the policy: “if the boundary returns a function, collapse it to one stage”.

This uses the same decomposition mechanism already used elsewhere in specialization logic .

---

### Change 2 — Use the helper when constructing `Mono.MonoCase`
**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

**Location:** inside `specializeExpr`, in the `TOpt.Case label root decider jumps canType ->` branch which currently does:

```elm
monoType =
    TypeSubst.applySubst subst canType
...
( Mono.MonoCase label root monoDecider monoJumps monoType, state2 )
```


**Replace that part with:**
```elm
        TOpt.Case label root decider jumps canType ->
            let
                monoType0 =
                    TypeSubst.applySubst subst canType

                monoType =
                    stageUncurryBoundaryResultType monoType0

                initialVarTypes =
                    state.varTypes

                ( monoDecider, state1 ) =
                    specializeDecider decider subst state

                state1WithResetVarTypes =
                    { state1 | varTypes = initialVarTypes }

                ( monoJumps, state2 ) =
                    specializeJumps jumps subst state1WithResetVarTypes
            in
            ( Mono.MonoCase label root monoDecider monoJumps monoType, state2 )
```

**Why this fixes the failing test:** the `MonoCase` result type will now be `MFunction [Int,Int] Int` instead of `MFunction [Int] (MFunction [Int] Int)` in cases like your `UseFlat`/`UseNested` example, so it will match the branch inline lambda type that `specializeLambda` already flattens when fully peelable.

---

## Notes / expected follow-ups

1. **This is intentionally *not* Option B (global uncurrying):** we’re only normalizing at the `case` boundary.
2. **Potential new failures:** if you have branches that return *non-lambda* function values (e.g. returning a `VarLocal f` where `f`’s type is still multi-stage), you may introduce the *opposite* mismatch (case type becomes flat, but leaf stays curried). If that shows up, the next step is to apply the same “boundary result normalization” to the *inline leaf types* (or insert a wrapper closure) — but don’t do that preemptively unless tests demonstrate it.

This change is minimal, matches your stated rule exactly, and targets the inconsistency shown in the current `TOpt.Case` specialization implementation .

## USER
Compute monoType0 = TypeSubst.applySubst subst canType
If monoType0 is a function type, stage‑uncurry that function type into a single stage (flatten all immediately available arg stages into one arg list) and use that as the MonoCase result type.

Is this correct though? To stage-uncurry the type in isolation from the case branches seems like it could diverge from the staged type the branches get.

Would a better approach be - stage-uncurry all branches, then substitute the branch type for the case type on the case to make it match ?

## ASSISTANT
Flattening the `MonoCase` result type “in isolation” is only correct if you also commit to a semantic rule that **any function value coming out of a `case` is represented as a single-stage function**. That rule is *not* compatible with your existing staged-uncurrying semantics, because staged lambdas can represent *real runtime staging* (a closure that takes 1 arg and returns another closure) when there is a `let/case` boundary inside the lambda.

Why that matters in your code today:

- `TypeSubst.applySubst` converts `Can.TLambda` to a *curried* nested `MFunction [arg] ret` chain 【】.
- `specializeLambda` sometimes flattens to `MFunction [a,b] ret` when the lambda is “fully peelable” (no `let/case` boundary in the syntactic chain) 【】.
- But `TOpt.Case` currently sets its result type directly from `applySubst` (curried) 【】, so you get the mismatch you observed.

## So is “flatten case result type always” correct?

It fixes your reported failure (`\b c -> ...` vs `\b -> \c -> ...`) because **both branches are fully peelable**, so `specializeLambda` will flatten both to the same single-stage type, while the case result stayed curried.

However, it is *not* generally correct under staged-uncurrying.

### Counterexample (where “flatten in isolation” becomes wrong)
If a branch returns a *staged* lambda (wrapper) like:

```elm
case sel of
  A -> (\x -> let t = ... in \y -> ...)
  B -> (\x -> let t = ... in \y -> ...)
```

Your existing `specializeLambda` logic is designed to **keep this curried/staged** (because the lambda chain is interrupted by a boundary). In that situation, the runtime value is genuinely “one arg now, another later”. If you flatten the case result type to `MFunction [x,y] ret`, you’re claiming it’s callable in one go, which diverges from the actual closure’s calling convention.

So yes: flattening the `Case` type without looking at branches can diverge from the staged type branches get.

## Better approach: derive the Case result type from the specialized branches (your proposal)

Yes—this is the more robust fix.

Instead of:
- computing case type from `canType` alone and then hoping branches match,

do:
1. Specialize the decider and jumps first (you already do this) 【】.
2. Extract the `MonoType` of every leaf result:
   - every `Inline` leaf expression’s `Mono.typeOf`
   - every `Jump` target expression’s `Mono.typeOf` (from the jump table)
3. Assert they are all equal (this *is* MONO_018, but enforce it at construction time).
4. Use that common leaf type as the `MonoCase` result type.

That makes the `MonoCase` type follow the same staging policy as whatever `specializeLambda` produced for the branches (flattened for fully peelable lambdas, curried for staged wrappers), instead of inventing a representation from `Can.Type`.

### What about `canType` then?
You still keep `monoType0 = TypeSubst.applySubst subst canType` as a “sanity reference”, but you should not use it as the stored case result type unless it matches the derived leaf type under your chosen equality notion.

In practice, you can add a debug/invariant check like:
- `monoType0` is *compatible with* `leafType` (maybe via a normalization that only collapses type-level currying that doesn’t correspond to runtime staging), but the stored type is `leafType`.

## Recommendation
- If your compiler’s runtime representation really distinguishes staged vs un-staged lambdas (and your `specializeLambda` clearly does), then **do not flatten `Case` result type in isolation**.
- Implement “case result type = common leaf type” and treat `canType` as an input check, not the output truth.

If you want, I can write the concrete code-level design for this (new helper to collect leaf types from `MonoDecider` + `MonoJumps`, where to add the invariant crash, and how to handle edge cases like empty leaf sets).

## USER
This leaves the problem of getting a consistent type for all branches.

Suppose we have this function:

someFun sel =
    case sel of
      A -> (\x -> let t = ... in \y -> ...)
      B -> (\x y -> ...)

What will its stage curried type be?

How do we get the branches to have the same type?
Generally, how to we always get branches to have the same type?

Is this staged currying scheme doomed to fail or can it be saved?

## ASSISTANT
It can be saved, but only if you treat “staging” as part of the *function value ABI* (calling convention) and therefore something you must make consistent at **join points** (`case`, `if`, `let`), not something each branch independently “chooses” based purely on peelability.

Right now you have exactly the failure mode you’d expect if staging is chosen locally:

- `specializeLambda` sometimes chooses **flat ABI** `MFunction [x,y] r` for `\x y -> ...` (fully peelable) 【】
- but `TypeSubst.applySubst` always produces **curried types** from `Can.TLambda` (nested `MFunction [x] (MFunction [y] r)`) 【】
- and `TOpt.Case` currently just stores `monoType = applySubst subst canType` as the case result type, without reconciling with branch ABIs 【】

So, to your concrete example:

```elm
someFun sel =
  case sel of
    A -> (\x -> let t = ... in \y -> ...)
    B -> (\x y -> ...)
```

## 1) What is the “staged-curried type” of `someFun`?

At the *source* (Elm) type level, both branches are extensionally a 2‑arg function, so `someFun : Selector -> X -> Y -> R` (curried).

At the *monomorphized ABI* level, there are multiple possible representations:

- Branch A is inherently **staged** (it allocates/returns an inner closure after applying `x` because the `let` is between `x` and `y`). Its natural ABI is:
  - `MFunction [X] (MFunction [Y] R)`.

- Branch B is peelable and your current monomorphizer naturally prefers the **flat ABI**:
  - `MFunction [X,Y] R`.

There is no single “stage-curried type” unless you define a *join rule*.

## 2) How do we get branches to have the same type?

You only have three coherent choices. Anything else will keep producing MONO_018-style mismatches.

### Choice C1 (recommended for staged-uncurrying): **Join chooses the more-staged ABI**, and you *prevent flattening* where needed
Define the join ABI for “function values produced by a boundary” as “curried/staged”.

Concretely: **inside a `case` branch result position, do not flatten peelable lambdas**. Even `\x y -> ...` becomes a staged function value with type `MFunction [X] (MFunction [Y] R)`.

This matches your stated intent:

> “where a lambda is inside an enclosing boundary (let..in or case..of), keep it curried as an inner stage”

Under this rule:

- Branch A stays `MFunction [X] (MFunction [Y] R)`
- Branch B is forced to *also* be `MFunction [X] (MFunction [Y] R)` (even if peelable)
- The case result type can remain the curried one coming from `TypeSubst.applySubst` and everything matches.

**Key insight:** you’re not “deriving types from syntax”; you’re choosing a consistent *ABI at boundaries*.

This requires changing specialization so `specializeLambda` has a context flag like:

- `FlattenFullyPeelable` (top-level / safe positions)
- `PreserveStages` (boundary-return position: branch leaf, let body being stored, etc.)

Without that context, a peelable lambda will keep choosing the flat ABI and you’ll keep getting join mismatches.

### Choice C2: **Join chooses the flatter ABI**, and you insert adapters (wrappers)
Pick `MFunction [X,Y] R` as the case result ABI, and then adapt staged branches.

For branch A you’d synthesize a wrapper closure:

- wrapper takes `(x,y)` in one stage
- calls the staged closure: `((f x) y)`
- returns `R`

This makes all branches produce the flat ABI, but costs wrappers/extra closure allocation.

This is viable, but it’s more engineering work because you must implement an explicit “ABI coercion” transform in monomorphization.

### Choice C3: “Derive case type from branches” *without adapters* — **not sufficient**
This is what you suggested (“stage-uncurry all branches, then substitute the branch type for the case type”).

That only works if the branches already agree. In your example they don’t:

- If you “stage-uncurry” branch B you’ll likely get `MFunction [X,Y] R`
- Branch A remains `MFunction [X] (MFunction [Y] R)`

So “pick a branch type and slap it on the case” just moves the inconsistency around; it doesn’t solve it unless you also **force** or **coerce** the other branches.

## 3) “How do we *always* get branches to have the same type?”

General rule: at join points, you need a **canonical ABI** for the joined value, plus either:

- **context-driven construction**: ensure each branch *produces* that ABI, or
- **coercions**: wrap/eta-expand branches that don’t match.

In other words:

> Staging is part of representation, so joins require an ABI unification step (like a phi-node needing casts).

Your current approach (each lambda decides “flat vs staged” locally, then you compare types structurally) guarantees that you will eventually hit cases where branches differ, because different syntactic shapes imply different staging opportunities.

## 4) Is staged currying doomed?

Not doomed, but you must stop thinking of it as “just a different MonoType pretty-printing”. It is an ABI decision.

The scheme is saveable if you pick one of these and apply it consistently:

- **PreserveStages under boundary-return positions** (my recommendation given your stated intent and the existing “stop peel at let/case” behavior in `specializeLambda` docs/comments 【】), *or*
- Implement **ABI coercions** at joins.

If you tell me which direction you want (C1 vs C2), I can outline the exact implementation changes in `Specialize.elm` (where to thread a context flag through `specializeExpr`/`specializeDecider`, and what invariants to enforce).

