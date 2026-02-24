# Specialize Let-Bound Functions and Lambdas in Monomorphization

## Problem

Today, top-level polymorphic functions are fully specialized via the worklist algorithm: `TypeSubst.unify` maps their canonical type to the concrete `MonoType` requested by each call site. But **local let-bound functions and lambdas** are specialized only with **whatever outer `subst` happens to exist** at the `TOpt.Let` branch in `specializeExpr`.

For a polymorphic local like:

```elm
testValue : Int
testValue =
    let id2 x = x
    in id2 42
```

The outer `subst` for `testValue : Int` has no mapping for `a`, so `specializeLambda` produces `MFunction [MVar a CEcoValue] (MVar a CEcoValue)` for `id2`. The *call site* uses `unifyFuncCall` to correctly see `MInt -> MInt`, but the *function implementation* retains `MVar a CEcoValue`.

This causes:
- MLIR lambda `@Test_lambda_0` returns `!eco.value` instead of `i64`
- CGEN_056 failures: saturated `eco.papExtend` result type (from call site) disagrees with `func.func` return type
- `eco.call` ABI mismatches in E2E tests

## Goal

For user code (non-kernel), **every let-bound function and lambda that is actually called at a concrete type** should have its `MonoType` fully resolved with **no remaining `MVar _ CEcoValue` in parameter/result positions**. This makes MLIR ABI fully concrete by construction in Mono, eliminating the mismatch class entirely.

## Key Insight

We already know the concrete instantiation from call sites via `unifyFuncCall`. We just aren't feeding that information back into the local definition's specialization. The fix is: for each `let`, first infer a substitution for the def's type variables from its call sites in the body, then specialize the def under that enriched substitution.

## Proposed Invariant

**MONO_020** – After monomorphization, for every user-defined local function or lambda (non-kernel), its `MonoType`'s `MFunction` parameter and result positions have no `MVar _ CEcoValue`. Remaining `MVar _ CEcoValue` indicates a failed specialization.

This tightens MONO_003 for the user-code/local-function case.

---

## Implementation Plan

### Step 1: New helper `collectLocalCallSubst`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

Add a function that walks a `TOpt.Expr` body and collects substitution mappings for a named local function based on its call sites. This reuses `TypeSubst.unifyFuncCall` — the same machinery already used at call sites in `specializeExpr`.

```elm
{-| Walk `bodyExpr` to find all calls to `defName`, use `unifyFuncCall`
    to derive type variable mappings, and union them into a single
    substitution that maps the def's type variables to concrete types.
-}
collectLocalCallSubst :
    Name            -- defName
    -> Can.Type     -- defCanType (canonical function type of the def)
    -> TOpt.Expr    -- bodyExpr of the let
    -> Substitution -- outerSubst
    -> Substitution -- extra substitution for this def
```

**Implementation approach:**

Recursively walk the body expression. When encountering a `TOpt.Call` whose callee is `TOpt.VarLocal defName _` or `TOpt.TrackedVarLocal _ defName _`:

1. Compute arg types by applying `outerSubst` to each arg's `canType` via `TypeSubst.applySubst` (lightweight — no MonoState needed, just `Mono.forceCNumberToInt (TypeSubst.applySubst outerSubst (TOpt.typeOf arg))`).
2. Call `TypeSubst.unifyFuncCall defCanType argTypes callCanType outerSubst` to get `callSubst`.
3. Filter `callSubst` to retain only entries that are *new* vs `outerSubst` (i.e., entries for the def's own type variables).
4. Union into the accumulator.

For all other expression forms, recurse into children (mirroring `specializeExpr`'s recursive descent structure):
- `TOpt.Let innerDef innerBody _` → recurse into innerDef's body and innerBody
- `TOpt.If branches final _` → recurse into conditions, then-branches, and final
- `TOpt.Case _ _ decider jumps _` → recurse into decider and jump bodies
- `TOpt.Call _ func args _` → recurse into func and args (after processing the call above)
- `TOpt.Tuple`, `TOpt.List`, `TOpt.Record`, `TOpt.Update`, `TOpt.Access`, `TOpt.Destruct` → recurse into children
- Leaf nodes (`TOpt.Bool`, `TOpt.Int`, `TOpt.VarLocal`, etc.) → return accumulator unchanged

**Note on arg type derivation:** We don't need `processCallArgs` here (which requires MonoState). Instead, for each arg we simply compute `Mono.forceCNumberToInt (TypeSubst.applySubst outerSubst (TOpt.typeOf arg))`. This is sufficient for `unifyFuncCall` because we only need the arg types for unification, not their full monomorphized expressions.

**Decider recursion:** For `Decider` trees (used in case expressions), add a helper `collectFromDecider` that recurses through `Leaf`, `Chain`, and `FanOut` branches mirroring the structure in `specializeDecider`.

### Step 2: Modify `TOpt.Let` branch in `specializeExpr`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`
**Location:** Lines ~948-971 (the `TOpt.Let def body canType ->` branch)

**Current code (abridged):**
```elm
TOpt.Let def body canType ->
    let
        monoType = Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
        ( monoDef, state1 ) = specializeDef def subst state
        defName = getDefName def
        defCanType = getDefCanonicalType def
        defMonoType = Mono.forceCNumberToInt (TypeSubst.applySubst subst defCanType)
        stateWithVar = { state1 | varTypes = Dict.insert identity defName defMonoType state1.varTypes }
        ( monoBody, state2 ) = specializeExpr body subst stateWithVar
    in
    ( Mono.MonoLet monoDef monoBody monoType, state2 )
```

**Changed code:**
```elm
TOpt.Let def body canType ->
    let
        monoType = Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
        defName = getDefName def
        defCanType = getDefCanonicalType def

        -- NEW: Collect call-site substitution for this def's type variables
        -- Only applies when def is a function (has TLambda type)
        substForDef =
            case defCanType of
                Can.TLambda _ _ ->
                    let
                        extraSubst = collectLocalCallSubst defName defCanType body subst
                    in
                    -- extraSubst overrides outerSubst for the def's own type vars
                    Dict.union extraSubst subst

                _ ->
                    -- Non-function defs (values) don't need call-site unification
                    subst

        -- Specialize def under enriched subst
        ( monoDef, state1 ) = specializeDef def substForDef state
        defMonoType = Mono.forceCNumberToInt (TypeSubst.applySubst substForDef defCanType)
        stateWithVar = { state1 | varTypes = Dict.insert identity defName defMonoType state1.varTypes }

        -- Body still uses outer subst (the enriched subst is only for the def itself)
        ( monoBody, state2 ) = specializeExpr body subst stateWithVar
    in
    ( Mono.MonoLet monoDef monoBody monoType, state2 )
```

**Key design decisions:**
- `substForDef` is used only for `specializeDef` and computing `defMonoType` — not for the body.
- `Dict.union extraSubst subst` — extra entries for the def's own type variables (e.g., `a ↦ MInt`) override anything in `subst`. Since `subst` has no mapping for `a` in the problem case, this naturally fills in the gap.
- The `Can.TLambda` guard ensures we only run the analysis for function definitions (which are the ones with type variables in param/result positions).
- Non-function `let` defs (plain values) are unaffected.

### Step 3: Handle the `Def` guard in `collectLocalCallSubst`

The analysis should only look for direct calls of `defName` in the *immediate body* of the let. It does NOT need to recurse into nested let-bound definitions (their own call sites are their own responsibility). However, it DOES need to recurse into:
- `TOpt.Call` arguments (the defName might be called within a sub-expression)
- `TOpt.If` branches
- `TOpt.Case` branches and deciders
- `TOpt.Let innerDef innerBody` — recurse into `innerBody` (not `innerDef`'s lambda body) since `defName` can be called there

### Step 4: Guard against non-function defs

If a `TOpt.Let` binds a non-function value (e.g., `let x = 42 in ...`), `defCanType` won't be a `TLambda`. The `Can.TLambda _ _` guard in Step 2 handles this — `collectLocalCallSubst` is never called for non-function defs.

### Step 5: Handle TailDef in `specializeDef`

`specializeDef` already augments the substitution for `TailDef` by mapping `Can.TVar` params to their mono types (lines 1408-1420). With the enriched `substForDef`, `specializeArg subst` will already see the concrete types for the def's type variables, so `augmentedSubst` will naturally contain those mappings. No additional changes needed in `specializeDef` itself.

For the `Def` case (non-tail), `specializeExpr expr subst state` will invoke `specializeLambda` (if the expr is a `TOpt.Function`), which calls `TypeSubst.applySubst subst canType` — now with the enriched subst, this produces concrete `MInt` instead of `MVar a CEcoValue`.

---

## Scope and Limitations

### Single instantiation per specialization (current scope)

Within a given monomorphic specialization of a top-level function, each local def is instantiated at exactly one concrete type. This is the common case and the one causing the current failures.

If `id2` were used as both `Int -> Int` and `Bool -> Bool` in the same body, the union of call-site substitutions would be inconsistent (`a ↦ MInt` vs `a ↦ MBool`). This doesn't happen in practice because:
- The enclosing top-level function would be specialized per call site type
- Elm's type system ensures consistent type variable instantiation within a single function body

### Recursive local functions

For simple self-recursive local functions (`TailDef`), the analysis in Step 1 finds calls within the body. Since `TailDef` args already augment the substitution, and the `TailCall` will use the same types, this should work naturally.

For mutually recursive local functions (not yet encountered as a `TOpt.Let` form — those are top-level `TOpt.Cycle`), no changes are needed now. Local `let` expressions in TOpt are single definitions, not cycles.

### Kernels

Kernel functions are unaffected — they use `deriveKernelAbiType` and `KernelAbi` modes, not `specializeLambda`. The proposed invariant MONO_020 explicitly excludes kernels.

---

## Testing

### 1. Unit test: Local polymorphic identity function

Add to `compiler/tests/TestLogic/Monomorphize/`:

```elm
-- Test: let id2 x = x in id2 42
-- Expected: id2's MonoType is MFunction [MInt] MInt (not MFunction [MVar a CEcoValue] (MVar a CEcoValue))
```

Verify that after monomorphization:
- The `MonoClosure` for `id2` has `monoType = MFunction [MInt] MInt`
- `closureInfo.params` is `[("x", MInt)]`
- The `MonoCall` result type is `MInt`

### 2. Unit test: Local polymorphic function with multiple args

```elm
-- Test: let swap a b = (b, a) in swap 1 "hello"
-- Expected: swap's MonoType has concrete MInt and MString, no MVar CEcoValue
```

### 3. Invariant enforcement test

Add a test that walks all `MonoNode`s and nested `MonoClosure` expressions, checking that non-kernel function types have no `MVar _ CEcoValue` in param/result positions. This enforces MONO_020.

```elm
assertNoEcoValueInUserFunctionAbi : Mono.MonoGraph -> Test
assertNoEcoValueInUserFunctionAbi graph =
    -- Walk all nodes, for each MonoClosure/MonoTailFunc that isn't a kernel:
    -- Check MFunction param and result types for MVar _ CEcoValue
```

### 4. E2E regression

Run the full test suite:
```bash
cd compiler && npx elm-test-rs --fuzz 1   # Frontend tests
cmake --build build --target full           # Full rebuild + E2E
```

Expected improvements:
- CGEN_056 failures should drop to 0 (lambda return types now match call-site expectations)
- `eco.call` ABI mismatches in JsArray E2E tests should resolve
- `EcoRunner::fixCallResultTypes` should become unnecessary for user code

---

## Invariants File Update

Add to `design_docs/invariants.csv`:

```
MONO_020;Monomorphization;Let-Bound Functions;documented;After monomorphization, every user-defined local function or lambda (non-kernel) that is reachable from MLIR codegen has no MVar with CEcoValue constraint in its MFunction parameter or result positions. Remaining CEcoValue MVar indicates a failed specialization;Compiler.Monomorphize.Specialize
```

---

## Files Changed

1. **`compiler/src/Compiler/Monomorphize/Specialize.elm`**
   - Add `collectLocalCallSubst` helper function (~80-120 lines)
   - Modify `TOpt.Let` branch in `specializeExpr` (~15 lines changed)

2. **`design_docs/invariants.csv`**
   - Add MONO_020 invariant entry

3. **`compiler/tests/TestLogic/Monomorphize/`** (new or extended test file)
   - Add unit tests for local function specialization
   - Add invariant enforcement test for MONO_020

---

## Risk Assessment

### Low risk
- The change is localized to the `TOpt.Let` branch in `specializeExpr`
- `collectLocalCallSubst` is a pure analysis (read-only walk of TOpt.Expr)
- Uses existing `TypeSubst.unifyFuncCall` — no new unification logic
- Non-function `let` defs are guarded by the `Can.TLambda` check

### Medium risk
- If a local function is *never called* in its body (dead code), `collectLocalCallSubst` returns empty and the def keeps the bare `subst` — same as today. This is safe.
- If the call-site unification produces inconsistent results (shouldn't happen with Elm's type system), `Dict.union` would pick one arbitrarily. Safe because Elm guarantees consistent instantiation within a function body.

### Mitigation
- Run full elm-test-rs and E2E suite after implementation
- The invariant test (Step 3) will catch any remaining `MVar CEcoValue` in user function ABIs
