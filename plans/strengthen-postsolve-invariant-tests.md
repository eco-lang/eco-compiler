# Plan: Strengthen PostSolve Invariant Tests (POST_007, POST_008, POST_009)

## Problem

The three PostSolve invariant tests pass on code that actually has escaping free type
variables. The checks are structurally present but too weak to catch the real bug:
lambdas whose PostSolve-generated TVars escape through monomorphization without being
specialized.

### Root causes in the test logic

**POST_008 (Lambda Context Vars) — critical escape hatch**
`PostSolveLambdaContextVarsTest.elm:120-124`:  When a lambda has no entry in
`nodeTypesPre`, the test sets `contextVars = postVars` (the lambda's own post vars),
making `postVars ⊆ postVars` trivially true.  These are exactly the Group B lambdas
where `postSolveLambda` invents `TVar "a"` / `TVar "b"` fallbacks — the most likely
source of escaping vars — and they get zero checking.

**POST_009 (Placeholder Vars) — global var universe**
`PostSolvePlaceholderVarsTest.elm:73-77`:  `allPreVarNames` collects every TVar name
from every pre-type across the *entire module*.  A PostSolve-generated `TVar "a"` in
function `foo` passes as long as any unrelated node anywhere has `"a"` in its pre-type.
Since `"a"` is the most common Elm type variable, this is nearly vacuous.

**POST_007 (Lambda Structural Types) — alpha-eq erases identity**
`PostSolveLambdaStructuralTypesTest.elm:232-235`: `alphaEq` treats all TVar pairs as
equal (`TVar _ == TVar _` → True`), so it only checks shape, not whether specific TVars
are consistent or properly bound.

### Confirming the weakness

`postSolveLambda` (PostSolve.elm:1086-1110) creates types from scratch when there is no
solver type.  It defaults missing pattern types to `TVar "a"` and missing body types to
`TVar "b"`.  These names are globally common, so:
- POST_008 skips the lambda (no pre-type → allow anything)
- POST_009 finds `"a"` and `"b"` in the global pre-var universe
- POST_007 sees the right shape (TLambda chain) and accepts any TVars

## Design

### Step 1: Fix POST_008 — scope-aware context vars

Replace the "no pre type → allow anything" branch with a scope-aware check.

When a lambda has no pre-type, compute context vars from the **enclosing definition's
annotation** instead of from the lambda's own post vars.

The test already receives `artifacts.annotations` (a `Dict Name.Name Can.Annotation`).
We need to:

1. **Extend `walkExprs` (or add a parallel walker) to track the enclosing def name** for
   each expression node.  Add `enclosingDef : Maybe Name.Name` to `ExprNode`.

2. **In `checkLambdaContextVars`**, when `nodeTypesPre` has no entry for the lambda,
   look up the enclosing def's annotation in `artifacts.annotations`:
   - `Forall freeVars defType` → `contextVars = Dict.keys freeVars` (the quantified
     vars are the legitimate scope)
   - If the def has no annotation (an un-annotated `Def`), use `freeTypeVars` of the
     def's own pre-type from `nodeTypesPre` (looked up by the def's body expression ID).
   - If neither is available, **flag as violation** (a lambda with no pre-type and no
     enclosing scope is always suspect).

3. **Remove the `( postVars, Nothing )` escape hatch entirely.**

### Step 2: Fix POST_009 — per-node pre-var check

Replace the global `allPreVarNames` with a per-node comparison.

1. **For each node**, compare its post-type TVars against its **own** pre-type TVars
   (from the same node ID in `nodeTypesPre`).

2. When the node has no pre-type (Group B), use the **enclosing def's annotation vars**
   as the legitimate set (same mechanism as Step 1).

3. Keep the kernel-node exemption.

The change is in `checkNoPlaceholdersInFuncPositions`: instead of receiving
`allPreVars : EverySet String String`, it receives:
- `nodeTypesPre : PostSolve.NodeTypes` (the full pre-map)
- `enclosingDefVars : EverySet String String` (from the annotation, for fallback)

And computes the legitimate vars as:
```
case Dict.get nodeId nodeTypesPre of
    Just preType -> freeTypeVars preType
    Nothing      -> enclosingDefVars
```

### Step 3: Fix POST_007 — bijective TVar consistency

Strengthen `alphaEq` to verify that TVars form a **consistent bijection** (a proper
alpha-renaming) rather than treating all TVar pairs as equal.

1. Thread a `Dict String String` (mapping from left TVar names to right TVar names)
   through `alphaEq`.

2. On `(TVar a, TVar b)`:
   - If `a` is already mapped, check that it maps to `b`
   - If `a` is unmapped but `b` is already a target, fail (not injective)
   - Otherwise, add `a → b` to the mapping

3. This catches cases where PostSolve uses unrelated TVars at positions where the
   recomputed structural type expects consistent variables.

### Step 4: Shared infrastructure — `ExprNode` with scope

Add `enclosingDef : Maybe Name.Name` to `ExprNode` in `PostSolveInvariantHelpers`:

```elm
type alias ExprNode =
    { id : Int
    , node : Can.Expr_
    , enclosingDef : Maybe Name.Name
    }
```

Update `walkDecls`/`walkDef` to propagate the current def name:

```elm
walkDef : Maybe Name.Name -> Can.Def -> List ExprNode -> List ExprNode
walkDef defName def acc = ...

walkExpr : Maybe Name.Name -> Can.Expr -> List ExprNode -> List ExprNode
walkExpr defName (A.At _ exprInfo) acc =
    let
        thisNode = { id = exprInfo.id, node = exprInfo.node, enclosingDef = defName }
        ...
```

Add a helper to look up enclosing annotation vars:

```elm
enclosingAnnotationVars :
    Maybe Name.Name
    -> Dict Name.Name Can.Annotation
    -> EverySet String String
enclosingAnnotationVars maybeName annotations =
    case maybeName of
        Nothing -> EverySet.empty
        Just name ->
            case Dict.get name annotations of
                Just (Can.Forall freeVars _) ->
                    Dict.keys freeVars |> EverySet.fromList identity
                Nothing -> EverySet.empty
```

## File changes

| File | Change |
|------|--------|
| `compiler/tests/TestLogic/Type/PostSolve/PostSolveInvariantHelpers.elm` | Add `enclosingDef` to `ExprNode`; thread def name through walkers; add `enclosingAnnotationVars` helper |
| `compiler/tests/TestLogic/Type/PostSolve/PostSolveLambdaContextVarsTest.elm` | Remove `( postVars, Nothing )` escape; use enclosing annotation vars as context when no pre-type exists; pass `artifacts.annotations` to checker |
| `compiler/tests/TestLogic/Type/PostSolve/PostSolvePlaceholderVarsTest.elm` | Replace global `allPreVarNames` with per-node pre-type + enclosing-def fallback |
| `compiler/tests/TestLogic/Type/PostSolve/PostSolveLambdaStructuralTypesTest.elm` | Replace `alphaEq` with bijective variant that threads a renaming map |
| `compiler/tests/TestLogic/Type/PostSolve/PostSolveNonRegressionInvariants.elm` | Update `collectNodeKinds` call sites if walker signature changes |
| `design_docs/invariant-test-logic.md` | Update POST_007/008/009 test logic descriptions |

## Order of implementation

1. **Step 4** (shared infra) — update `ExprNode` and walkers first since Steps 1-3 depend on it
2. **Step 1** (POST_008 fix) — most critical, directly addresses the escape hatch
3. **Step 2** (POST_009 fix) — uses same infra as Step 1
4. **Step 3** (POST_007 fix) — independent of scoping, just the alphaEq change

## Expected outcome after implementation

- Lambdas where PostSolve invents fallback TVars (`"a"`, `"b"`) will be checked against
  their enclosing definition's quantified variables, not against themselves or the whole
  module
- TVars that don't originate from the solver or annotations will be flagged as violations
- The tests may initially **fail** on existing test cases, exposing the real escaping-var
  bugs that currently pass silently — this is the desired outcome, as it surfaces the
  actual PostSolve deficiency for targeted fixing
