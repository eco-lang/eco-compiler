# Option X: Make Monomorphize Staging-Agnostic

## Goals

1. **Monomorphization becomes staging-agnostic** - does only type specialization + closure creation
2. **GlobalOpt owns all staging/ABI decisions** - canonicalizes staging, enforces invariants
3. **Invariants renamed** - MONO_016 → GOPT_016, MONO_018 → GOPT_018

---

## Phase 1: Simplify `specializeLambda` (Staging-Agnostic)

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

### 1.1 Replace `specializeLambda` with staging-agnostic version

**Current behavior (to remove):**
- Uses `peelFunctionChain` to gather all params from nested lambdas
- Computes `flatArgTypes`, `flatRetType` via `Mono.decomposeFunctionType`
- Computes `totalArity`, `isFullyPeelable`
- Picks `effectiveMonoType` based on flat vs staged encoding
- Uses `dropNArgsFromType` for wrapper return types
- Enforces MONO_016 assertion

**New behavior:**
- Specialize exactly one `TOpt.Function`/`TOpt.TrackedFunction` node at a time
- Use direct `params` and `body` from the node (no `peelFunctionChain`)
- Specialize the whole function type once with `TypeSubst.applySubst`
- Specialize each parameter's declared `Can.Type`
- Build closure with the specialized type as-is (no flattening/currying decisions)
- No MONO_016 enforcement

**Key insight:** With this approach:
- `\x y -> body` (one `TOpt.Function [x,y] body`) → one `MonoClosure` with 2 params
- `\x -> \y -> body` (nested `TOpt.Function [x] (TOpt.Function [y] body)`) → outer `MonoClosure` with 1 param, body contains inner `MonoClosure`

The syntactic difference is preserved. GlobalOpt's wrapper generation handles unification if needed.

### 1.2 New `specializeLambda` implementation

```elm
specializeLambda :
    TOpt.Expr
    -> Can.Type
    -> Substitution
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
specializeLambda lambdaExpr canType subst state =
    let
        -- 1. Specialize the whole function type once (no flattening).
        monoType0 : Mono.MonoType
        monoType0 =
            TypeSubst.applySubst subst canType

        -- 2. Extract params and body directly (no peelFunctionChain).
        ( params, bodyExpr ) =
            case lambdaExpr of
                TOpt.Function ps body _ ->
                    ( ps, body )

                TOpt.TrackedFunction trackedPs body _ ->
                    ( List.map (\( A.At _ n, t ) -> ( n, t )) trackedPs, body )

                _ ->
                    Utils.Crash.crash
                        ("specializeLambda: called with non-lambda: "
                            ++ Debug.toString lambdaExpr
                        )

        -- Guard: paramCount == 0 is a bug
        paramCount =
            List.length params

        _ =
            if paramCount == 0 then
                Utils.Crash.crash "specializeLambda: called with zero-param lambda"
            else
                ()

        -- 3. Specialize each parameter's declared Can.Type.
        monoParams : List ( Name, Mono.MonoType )
        monoParams =
            List.map
                (\( name, paramCanType ) ->
                    ( name, TypeSubst.applySubst subst paramCanType )
                )
                params

        lambdaId =
            Mono.AnonymousLambda state.currentModule state.lambdaCounter

        newVarTypes =
            List.foldl
                (\( name, monoParamType ) vt ->
                    Dict.insert identity name monoParamType vt
                )
                state.varTypes
                monoParams

        stateWithLambda =
            { state
                | lambdaCounter = state.lambdaCounter + 1
                , varTypes = newVarTypes
            }

        -- 4. Specialize the body.
        ( monoBody, stateAfter ) =
            specializeExpr bodyExpr subst stateWithLambda

        -- 5. Compute captures.
        captures =
            Closure.computeClosureCaptures monoParams monoBody

        closureInfo =
            { lambdaId = lambdaId
            , captures = captures
            , params = monoParams
            }

        -- 6. Reconcile return type with body type (no staging changes).
        bodyType : Mono.MonoType
        bodyType =
            Mono.typeOf monoBody

        monoTypeFixed : Mono.MonoType
        monoTypeFixed =
            case monoType0 of
                Mono.MFunction argTypes _ ->
                    Mono.MFunction argTypes bodyType

                _ ->
                    monoType0
    in
    ( Mono.MonoClosure closureInfo monoBody monoTypeFixed, stateAfter )
```

### 1.3 Delete unused code

- Delete `dropNArgsFromType` helper (lines 93-112)
- Delete `peelFunctionChain` helper if no longer used elsewhere
- Remove all `isFullyPeelable`, `totalArity`, `flatArgTypes`, `effectiveMonoType` logic

---

## Phase 2: Remove MONO_016 Enforcement from Closure.elm

**File:** `compiler/src/Compiler/Monomorphize/Closure.elm`

### 2.1 Simplify `ensureCallableTopLevel`

**Current behavior (lines 52-119):**
- Computes `stageArgTypes`, `stageRetType`, `stageArity`
- For `MonoClosure`: crashes if `length closureInfo.params < stageArity`
- For other expressions: creates alias/general closures

**New behavior:**
- Keep `stageArgTypes`, `stageRetType` computation (structural helpers for alias/general closures)
- For `MonoClosure`: accept as-is, defer staging consistency to GlobalOpt
- For other expressions: unchanged (alias/general closure creation)

**Code change:** Replace the `MonoClosure` branch:

```elm
Mono.MonoClosure _ _ _ ->
    -- Do not enforce MONO_016 here; GlobalOpt will.
    ( expr, state )
```

Remove the crash block (lines 68-83) that checks `List.length closureInfo.params >= stageArity`.

### 2.2 Keep kernel handling unchanged

The `MonoVarKernel` branch must remain as-is:
- Kernels have a fixed C-like ABI (all args at once, fully flattened)
- `flattenFunctionType kernelAbiType` produces the flat arg list
- `makeAliasClosure` builds a flattened closure for the kernel

```elm
Mono.MonoVarKernel region home name kernelAbiType ->
    let
        ( kernelFlatArgTypes, kernelFlatRetType ) =
            flattenFunctionType kernelAbiType

        flattenedFuncType =
            Mono.MFunction kernelFlatArgTypes kernelFlatRetType
    in
    makeAliasClosure
        (Mono.MonoVarKernel region home name kernelAbiType)
        region
        kernelFlatArgTypes
        kernelFlatRetType
        flattenedFuncType
        state
```

GlobalOpt can wrap these if Elm code expects staged ABI, but the kernel call itself stays flat.

---

## Phase 3: Update GlobalOpt Error Messages

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

### 3.1 Rename MONO_016 → GOPT_016 in `validateExprClosures`

**Location:** Lines 996-1003

Change:
```elm
Debug.todo
    ("MONO_016 violation: closure has "
        ++ ...
    )
```
to:
```elm
Debug.todo
    ("GOPT_016 violation: closure has "
        ++ ...
    )
```

### 3.2 Add defensive total arity check to `buildAbiWrapperGO`

**Location:** After line 327 (after computing `targetSeg` and `srcSeg`)

Add:
```elm
_ =
    if List.sum srcSeg /= List.sum targetSeg then
        Debug.todo
            ("GOPT_018: branch total arity mismatch: src="
                ++ Debug.toString srcSeg
                ++ ", target="
                ++ Debug.toString targetSeg
            )
    else
        ()
```

### 3.3 Rename in `MonoReturnArity.elm`

**File:** `compiler/src/Compiler/GlobalOpt/MonoReturnArity.elm`

**Location:** Lines 31-37

Change:
```elm
"MonoReturnArity: MONO_016 violation: ..."
```
to:
```elm
"MonoReturnArity: GOPT_016 violation: ..."
```

---

## Phase 4: Update Invariants Documentation

**File:** `design_docs/invariants.csv`

### 4.1 Mark MONO_016 as migrated

Update the MONO_016 row:
- Add note: "Migrated to GOPT_016; see GlobalOpt section"
- Remove Monomorphization as enforcer

### 4.2 Mark MONO_018 as migrated

Update the MONO_018 row:
- Add note: "Migrated to GOPT_018; see GlobalOpt section"
- Remove Monomorphization as enforcer

### 4.3 Add GOPT_016 row

```csv
GOPT_016,GlobalOpt,Closure params match stage arity,"For every MonoClosure with function type MFunction after GlobalOpt, length(closureInfo.params) == length(stageParamTypes(monoType))",MonoGlobalOptimize.validateClosureStaging
```

### 4.4 Add GOPT_018 row

```csv
GOPT_018,GlobalOpt,Case branch types match after ABI normalization,"For every MonoCase after normalizeCaseIfAbi, all branch result types equal the case result type (including staging)",MonoGlobalOptimize.normalizeCaseIfAbi
```

### 4.5 Add GOPT_017 row (returned closure arity)

```csv
GOPT_017,GlobalOpt,Returned closure param counts match stage arity,"For every function returning a closure, returnedClosureParamCounts[specId] equals the first-stage param count of the returned closure type",MonoReturnArity.annotateReturnedClosureArity
```

**Note:** Do NOT renumber existing MONO_* invariants. Gaps in numbering preserve historical references.

---

## Phase 5: Update Tests

### 5.1 Update MONO_016 test references

Search for files referencing MONO_016:
```bash
grep -r "MONO_016" compiler/tests/
```

For each match:
- Update comments to reference GOPT_016
- Ensure test runs on graph AFTER `globalOptimize`

### 5.2 Update MONO_018 test references

**Files:**
- `compiler/tests/Compiler/GlobalOpt/MonoCaseBranchResultTypeTest.elm`
- `compiler/tests/Compiler/GlobalOpt/JoinpointABITest.elm`

For each:
- Update comments/names to reference GOPT_018
- Ensure tests validate after `normalizeCaseIfAbi`

**Expected outcome:** The 2 pre-existing MONO_018 failures should disappear once Monomorphize stops flattening, since the "curried vs flat" mismatch was caused by `isFullyPeelable` logic.

### 5.3 Update tests that assume `\x y ->` == `\x -> \y ->` at Monomorphize

Search for tests that may expect staging equivalence at Monomorphize boundary:
```bash
grep -r "WrapperCurried\|peelable\|flatten" compiler/tests/
```

For each match:
- If test asserts staging equality at Monomorphize output → move assertion to after GlobalOpt
- If test asserts closure structure at Monomorphize → weaken to "well-typed" or move to GlobalOpt

**New contract:**
- **After Monomorphize:** Lambda shape follows syntax; staging may vary
- **After GlobalOpt:** Staging is normalized and ABI is consistent

---

## Phase 6: Clean Up Unused Code

### 6.1 Remove unused helpers from Specialize.elm

After simplifying `specializeLambda`:
- Delete `dropNArgsFromType` (lines 93-112)
- Delete `peelFunctionChain` if unused (keep if used by other transforms like `NormalizeLambdaBoundaries`)

### 6.2 Verify no stale MONO_016/018 references

```bash
grep -r "MONO_016\|MONO_018" compiler/src/
```

Update any remaining references in comments/error messages.

---

## Phase 7: Run Tests and Verify

### 7.1 Run elm-test-rs
```bash
cd compiler && npx elm-test-rs --fuzz 1
```

**Expected:**
- Tests should pass
- The 2 pre-existing MONO_018 failures should now pass (curried vs flat mismatch is eliminated)

### 7.2 Run cmake check
```bash
cmake --build build --target check
```

**Expected:** Same pass rate or better.

### 7.3 Run boundary check
```bash
cd compiler && npx elm-review --rules EnforceBoundaries
```

**Expected:** No errors.

---

## Implementation Order

1. **Phase 1:** Simplify `specializeLambda` (highest risk, most complex)
2. **Phase 2:** Remove MONO_016 from Closure.elm (dependent on Phase 1)
3. **Phase 7 (partial):** Run tests to verify Phases 1-2 work
4. **Phase 3:** Update GlobalOpt error messages (low risk)
5. **Phase 4:** Update invariants documentation (low risk)
6. **Phase 5:** Update tests (dependent on Phases 3-4)
7. **Phase 6:** Clean up unused code (after all else works)
8. **Phase 7 (full):** Final test verification

---

## Risk Assessment

**High risk:**
- Phase 1: `specializeLambda` is complex; must handle all edge cases correctly

**Medium risk:**
- Phase 2: `ensureCallableTopLevel` changes could affect closure creation

**Low risk:**
- Phases 3-6: Documentation, error messages, and cleanup

---

## Rollback Strategy

If issues arise:
1. Revert `specializeLambda` changes first (Phase 1)
2. Re-enable MONO_016 checks in Closure.elm (Phase 2)
3. Revert invariant renames last (Phases 3-5 are cosmetic)

---

## Key Design Decisions (from Q&A)

1. **No `peelFunctionChain` in `specializeLambda`** - Specialize one lambda node at a time, preserving syntactic structure

2. **`normalizeCaseIfAbi` unchanged** - Already handles arbitrary staging via `chooseCanonicalSegmentation` and `buildAbiWrapperGO`

3. **MONO_018 failures expected to resolve** - Caused by `isFullyPeelable` flattening, which is being removed

4. **TrackedFunction handled identically** - Just strip `A.At` wrappers from param names

5. **MLIR codegen unaffected** - Works with per-stage arity; GlobalOpt guarantees GOPT_016/018 before MLIR

6. **No invariant renumbering** - Mark MONO_016/018 as "migrated to GOPT_*" to preserve historical references

7. **No `augmentedSubst` needed** - Since monoParams are computed directly via `applySubst subst`, the body sees the same mappings. `augmentedSubst` was only needed when `specializeLambda` could pick param types different from what `applySubst` produced (via `effectiveParamTypes`). With the staging-agnostic version, we use `subst` unchanged for the body.

8. **Kernel handling unchanged** - Kernels have a fixed C-like ABI (all args at once, fully flattened). Keep the special `MonoVarKernel` branch in `ensureCallableTopLevel` that builds flattened alias closures. GlobalOpt can wrap these if Elm code expects staged ABI, but the inner kernel call stays flat.

9. **Tests assuming `\x y ->` == `\x -> \y ->` must be updated** - After this change, these produce different MonoType shapes at Monomorphize output:
   - `\x y -> body` → one `MonoClosure` with 2 params, type `MFunction [A, B] R`
   - `\x -> \y -> body` → outer closure with 1 param, inner closure with 1 param, type `MFunction [A] (MFunction [B] R)`

   Tests that assert these are equal at Monomorphize boundary should be updated to either:
   - Assert equality **after GlobalOpt** (where ABI normalization unifies them), or
   - Weaken expectations to "well-typed but not staging-normalized"

   Look for tests named like `*WrapperCurriedCallsTest*` and anything referencing MONO_016/018 at Monomorphize boundary.
