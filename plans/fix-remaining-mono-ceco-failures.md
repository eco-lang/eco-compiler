# Fix Remaining MONO_021/024 CEcoValue Failures

## Problem Statement

Nine monomorphization tests fail because CEcoValue type variables survive into fully monomorphic specializations, violating MONO_021 (no CEcoValue in user function types) and MONO_024 (no CEcoValue anywhere in fully-monomorphic specs). The failures cluster into three root causes:

1. **Lambdas in data structures and HOFs** (Tests 1-3): Polymorphic functions stored in records/let-bindings whose internal TVars never get bound because the enclosing type is itself still polymorphic when the substitution is applied.
2. **Phantom/unconstrained TVars** (Tests 4-6): Genuine absence of constraining information (empty list, unused union parameter, array stub types).
3. **Type variable name collisions** (Test 5, Array scoping): Callee TVars reuse caller TVar names, causing accidental shadowing in substitutions.

## Three Mechanisms

- **Mechanism A**: Aggressive top-down propagation for lambdas and records
- **Mechanism B**: Local erasure of truly unconstrained CEcoValue TVars to `MErased`
- **Mechanism C**: Type-variable hygiene via renaming in `unifyFuncCall`

---

## Detailed Changes

### 1. TypeSubst.elm

#### 1a. Add `fillUnconstrainedCEcoWithErased`

**File**: `compiler/src/Compiler/Monomorphize/TypeSubst.elm`
**Location**: After `resolveMonoVars` (after line 267)
**Export**: Add to module exposing list

Add a new function that maps any CEcoValue TVar in a canonical type that is still unmapped in the substitution to `MErased`. This handles phantom type variables (e.g., the `b` in `Either a b` when only `a` is constrained).

```elm
{-| Extend a substitution by mapping any CEcoValue TVar in the canonical type
that is still unmapped to Mono.MErased. Used for functions whose some type
parameters are genuinely phantom at a given specialization. -}
fillUnconstrainedCEcoWithErased : Can.Type -> Substitution -> Substitution
fillUnconstrainedCEcoWithErased canType subst =
    let
        vars =
            collectCanTypeVars canType []
    in
    List.foldl
        (\name acc ->
            if Data.Map.member identity name acc then
                acc
            else
                case constraintFromName name of
                    Mono.CEcoValue ->
                        Data.Map.insert identity name Mono.MErased acc

                    Mono.CNumber ->
                        acc
        )
        subst
        vars
```

**Rationale**: When specializing a function like `fromLeft : Either a b -> a -> a` at call site `fromLeft (Left 42) 0`, `a` maps to `MInt` from unification, but `b` has no binding. Without this, `b` becomes `MVar "b" CEcoValue` which violates MONO_024. With this function, `b` becomes `MErased` instead — a phantom type that can never affect layout.

#### 1b. Add TVar renaming to `unifyFuncCall`

**File**: `compiler/src/Compiler/Monomorphize/TypeSubst.elm`
**Location**: `unifyFuncCall` function (lines 45-62)

Modify to rename callee TVars that would collide with caller TVars before unification:

```elm
unifyFuncCall funcCanType argMonoTypes resultCanType baseSubst =
    let
        -- Vars from the caller's context (existing substitution bindings)
        callerVarNames =
            Data.Map.keys baseSubst

        -- Vars appearing in the callee's canonical type
        funcVarNames =
            collectCanTypeVars funcCanType []

        renameMap =
            buildRenameMap callerVarNames funcVarNames Data.Map.empty 0

        funcCanTypeRenamed =
            renameCanTypeVars renameMap funcCanType

        resultCanTypeRenamed =
            renameCanTypeVars renameMap resultCanType

        subst1 =
            unifyArgsOnly funcCanTypeRenamed argMonoTypes baseSubst

        desiredResultMono =
            applySubst subst1 resultCanTypeRenamed

        resolvedArgTypes =
            List.map (resolveMonoVars subst1) argMonoTypes

        desiredFuncMono =
            Mono.MFunction resolvedArgTypes desiredResultMono
    in
    unifyHelp funcCanTypeRenamed desiredFuncMono subst1
```

**Rationale**: When `repeat` (with TVar `a`) calls `initialize` (also with TVar `a`), the caller's substitution `{a → MInt}` gets accidentally applied to the callee's unrelated `a`. Renaming the callee's `a` to `a__callee0` prevents this conflict.

**Note**: `buildRenameMap`, `renameCanTypeVars`, and `collectCanTypeVars` already exist in TypeSubst.elm (lines 273-371) but are currently unused by `unifyFuncCall`. This change activates them.

#### 1c. Export the new function

Update the module exposing list (line 1-5) to add `fillUnconstrainedCEcoWithErased`:

```elm
module Compiler.Monomorphize.TypeSubst exposing
    ( applySubst
    , canTypeToMonoType
    , fillUnconstrainedCEcoWithErased
    , unify, unifyExtend, unifyFuncCall, extractParamTypes
    )
```

---

### 2. Specialize.elm — Record Update: use specialized record's MonoType

**File**: `compiler/src/Compiler/Monomorphize/Specialize.elm`
**Location**: `TOpt.Update` case in `specializeExpr` (lines 1341-1395)

**Current code** computes `fieldMonoType` by applying `subst` to the canonical field type from the record's canonical type. When `subst` is empty or incomplete, the result is still polymorphic (e.g., `a -> a`).

**Change**: Instead of deriving `fieldMonoType` from `recordCanType` + `subst`, derive it from the already-specialized `monoRecord`'s type, which carries concrete types from prior specialization.

Replace lines 1349-1386:

```elm
                -- Use the already-specialized record's MonoType for field type lookup.
                -- This is more concrete than re-applying subst to the canonical type,
                -- because monoRecord already encodes constraints from its own specialization.
                recordMonoType =
                    Mono.typeOf monoRecord

                getFieldMonoType fieldName =
                    case recordMonoType of
                        Mono.MRecord fieldMap ->
                            Dict.get fieldName fieldMap

                        _ ->
                            Nothing

                ( monoUpdates, state2 ) =
                    Data.Map.foldl A.compareLocated
                        (\locName updateExpr ( acc, st ) ->
                            let
                                fieldName =
                                    A.toValue locName

                                refinedSubst =
                                    case getFieldMonoType fieldName of
                                        Just fieldMonoType ->
                                            TypeSubst.unifyExtend (TOpt.typeOf updateExpr) fieldMonoType subst

                                        Nothing ->
                                            subst

                                ( monoExpr, newSt ) =
                                    specializeExpr updateExpr refinedSubst st
                            in
                            ( ( fieldName, monoExpr ) :: acc, newSt )
                        )
                        ( [], state1 )
                        updates
```

**Rationale**: For `{ r | fn = \x -> x }`, when `r` has been specialized to `{ fn : Int -> Int }`, `monoRecord`'s type is `MRecord { fn : MFunction [MInt] MInt }`. Unifying the update lambda's canonical type `a -> a` against `MFunction [MInt] MInt` correctly binds `a → MInt`. The old approach re-applied `subst` to the canonical record type, which, if `subst` was empty, produced `MFunction [MVar "a" CEcoValue] (MVar "a" CEcoValue)` — useless for binding.

---

### 3. Specialize.elm — Let function-def single-instance: enrich substitution

**File**: `compiler/src/Compiler/Monomorphize/Specialize.elm`
**Location**: `TOpt.Let` case, function-def branch, single-instance fallback (lines 1109-1133)

**Current code** computes `defMonoType` and inserts it into `varEnv`, but does NOT enrich the substitution for the body below the let. The non-function branch (lines 1208-1242) already does this enrichment pattern.

**Change**: Mirror the non-function branch by computing an `enrichedSubst` and using it for body specialization.

Replace lines 1109-1133:

```elm
                            if Data.Map.isEmpty topEntry.instances then
                                -- No calls to this def were recorded in the body:
                                -- fall back to single-instance behavior using the original name.
                                let
                                    ( monoDef, state1 ) =
                                        specializeDef def subst { stateAfterBody | localMulti = restOfStack }

                                    defMonoType0 =
                                        Mono.forceCNumberToInt (TypeSubst.applySubst subst defCanType)

                                    defMonoType =
                                        if Mono.containsCEcoMVar defMonoType0 then
                                            monoDefExprType monoDef
                                        else
                                            defMonoType0

                                    -- Enrich substitution with bindings discovered from
                                    -- the concrete def type, so the body sees them.
                                    -- This mirrors the non-function let branch below.
                                    enrichedSubst =
                                        if Mono.containsCEcoMVar defMonoType0 then
                                            TypeSubst.unifyExtend defCanType defMonoType subst
                                        else
                                            subst

                                    stateWithVar =
                                        { state1 | varEnv = State.insertVar defName defMonoType state1.varEnv }

                                    -- Re-specialize body with enriched substitution
                                    -- so downstream expressions see the concrete def type.
                                    ( monoBody2, state2 ) =
                                        if Mono.containsCEcoMVar defMonoType0 then
                                            specializeExpr body enrichedSubst stateWithVar
                                        else
                                            ( monoBody, stateWithVar )
                                in
                                ( Mono.MonoLet monoDef monoBody2
                                    (if Mono.containsCEcoMVar monoType0 then Mono.typeOf monoBody2 else monoType0)
                                , state2
                                )
```

**Rationale**: For `let identity x = x in identity 42`, when the body is specialized first (to discover call-site instances), if no `localMulti` instances are recorded (e.g., because `identity` is used once via accessor), the fallback path specializes the def but doesn't feed the resulting concrete type back into the body's substitution. The body then specializes with the original `subst` which lacks bindings for `identity`'s TVars.

**Alternative consideration**: This re-specializes the body when CEcoMVar is detected, which is potentially expensive. However, this only triggers when the def's canonical type has unresolved TVars AND no localMulti instances — a narrow case. A more targeted approach could thread `enrichedSubst` through the *initial* body specialization, but that would require restructuring the localMulti stack push/pop logic more deeply. The re-specialization approach is safer and simpler.

**Important**: Apply the same fix to the `[] ->` fallback case (lines 1182-1205) which has identical logic.

---

### 4. Specialize.elm — Empty list: erase phantom element type

**File**: `compiler/src/Compiler/Monomorphize/Specialize.elm`
**Location**: `TOpt.List` case in `specializeExpr` (lines 845-866)

**Current code** for empty lists with CEcoMVar falls through to keep `monoType0`, which contains `MVar "a" CEcoValue` in the element position.

**Change**: In the `[]` case, erase CEcoValue MVars to `MErased`:

Replace lines 854-864:

```elm
                monoType =
                    if Mono.containsCEcoMVar monoType0 then
                        case monoExprs of
                            first :: _ ->
                                Mono.MList (Mono.typeOf first)

                            [] ->
                                -- Empty list: element type is unconstrained and never
                                -- affects layout. Treat as phantom (MErased).
                                Mono.eraseCEcoVarsToErased monoType0

                    else
                        monoType0
```

**Rationale**: For `case [] of ...`, the element type `a` is never constrained because there are no elements to infer from. The empty list is a phantom construct — its element type cannot affect layout since there are no elements. Using `MErased` instead of `MVar "a" CEcoValue` satisfies MONO_024 while preserving the correct semantics.

---

### 5. Specialize.elm — Function specialization: fill unconstrained phantom TVars

**File**: `compiler/src/Compiler/Monomorphize/Specialize.elm`
**Location**: `specializeNode` function, `TOpt.Define` and `TOpt.TrackedDefine` cases (lines 275-314)

**Change**: After the initial unification, call `fillUnconstrainedCEcoWithErased` to fill any remaining phantom TVars:

For `TOpt.Define` case (lines 278-296), change `subst` computation:

```elm
        TOpt.Define expr _ canType ->
            let
                subst0 =
                    TypeSubst.unify canType requestedMonoType

                subst1 =
                    TypeSubst.unifyExtend (TOpt.typeOf expr) requestedMonoType subst0

                -- Fill any unconstrained CEcoValue TVars with MErased.
                -- These are genuinely phantom (e.g., unused type params like `b`
                -- in `Either a b` when only `a` is constrained at this call site).
                subst =
                    TypeSubst.fillUnconstrainedCEcoWithErased canType subst1
```

Apply the same pattern to `TOpt.TrackedDefine` (lines 299-313).

Also apply to `specializeFuncDefInCycle` (line 572), specifically in the `TOpt.TailDef` branch. After computing `augmentedSubst` (line 599-605), wrap it:

```elm
                finalSubst =
                    TypeSubst.fillUnconstrainedCEcoWithErased returnType augmentedSubst
```

And use `finalSubst` instead of `augmentedSubst` for the body specialization and final type computation.

**Rationale**: For `fromLeft (Left 42) 0`, the def-level unification binds `a → MInt` but `b` remains unbound. `fillUnconstrainedCEcoWithErased` maps `b → MErased`, ensuring all downstream uses see `MErased` instead of `MVar "b" CEcoValue`.

---

### 6. Monomorphize.elm — (Optional, safety net) Post-pass erasure for monomorphic-key internal function types

**File**: `compiler/src/Compiler/Monomorphize/Monomorphize.elm`
**Location**: `patchedNodes` computation in `monomorphizeFromEntry` (lines 131-161)

**Current code** only applies `patchNodeTypesCEcoToErased` when the *key type* has CEcoValue, and leaves monomorphic-key specs unchanged. This is the safety-net layer.

**Change**: Optionally extend the monomorphic-key branch to also erase CEcoValue from *internal* expression types (not the key or node type) for non-kernel nodes. This catches any stragglers from Mechanism A.

```elm
                    if isValueUsed then
                        if keyHasCEcoMVar then
                            patchNodeTypesCEcoToErased node

                        else
                            -- Safety net: erase CEcoValue in internal expression types
                            -- for monomorphic-key value-used specs (non-kernel only).
                            -- The key type and node type are left unchanged.
                            patchInternalExprCEcoToErased node

                    else
                        patchNodeTypesToErased node
```

Where `patchInternalExprCEcoToErased` erases CEcoValue MVars only in expression types within the node's body, leaving the node-level type and parameter types untouched:

```elm
patchInternalExprCEcoToErased : Mono.MonoNode -> Mono.MonoNode
patchInternalExprCEcoToErased node =
    case node of
        Mono.MonoDefine expr t ->
            Mono.MonoDefine (eraseExprCEcoVars expr) t

        Mono.MonoTailFunc params expr t ->
            Mono.MonoTailFunc params (eraseExprCEcoVars expr) t

        _ ->
            node
```

**Rationale**: This is a conservative safety net. If Mechanisms A-C handle all cases correctly, this should be a no-op. But it prevents any missed cases from causing MONO_024 failures. It preserves the node-level type and parameter types (which MONO_021 checks) so any real specialization bugs in those positions still surface.

**Risk assessment**: Low risk. Erasing CEcoValue to MErased in internal expressions of monomorphic-key specs cannot change behavior because these variables are provably unconstrained (if they were constrained, they would have been resolved). The node-level type remains unchanged, so MONO_017 is preserved.

**Decision point**: This step can be deferred if steps 1-5 handle all nine test failures. Implement it only if residual failures remain after the first five changes.

---

## Files Modified (Summary)

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Monomorphize/TypeSubst.elm` | Add `fillUnconstrainedCEcoWithErased`, modify `unifyFuncCall` for TVar renaming, update exports |
| `compiler/src/Compiler/Monomorphize/Specialize.elm` | Fix `TOpt.Update` field type lookup, fix `TOpt.Let` function single-instance enrichment, fix `TOpt.List` empty list erasure, fill phantom TVars in `specializeNode` and `specializeFuncDefInCycle` |
| `compiler/src/Compiler/Monomorphize/Monomorphize.elm` | (Optional) Add `patchInternalExprCEcoToErased` safety net |

## Implementation Order

1. **TypeSubst.elm changes** (steps 1a, 1b, 1c) — foundation for all other changes
2. **Empty list fix** (step 4) — simplest, isolated change
3. **Record update fix** (step 2) — targeted fix for Test 1
4. **Function specialization phantom fill** (step 5) — handles Tests 5, 6
5. **Let function-def enrichment** (step 3) — handles Tests 2, 3
6. **Safety net** (step 6) — only if needed

## Verification

After each step, run:
```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

Filter for specific test suites:
```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1 -- --filter "MONO_021\|MONO_024"
```

## Invariant Compliance

- **MONO_017**: Preserved — we don't change spec keys, and the optional safety net preserves node-level types before patching the registry.
- **MONO_021**: Satisfied — mechanisms A and B ensure no CEcoValue survives in user function types.
- **MONO_024**: Satisfied — mechanisms A, B, C ensure no CEcoValue survives anywhere in fully-monomorphic specs.
- **GOPT_001**: Unaffected — we don't change staging or closure param counts.
- **REP_ABI_001**: Unaffected — `MErased` maps to `!eco.value` at codegen, same as `MVar _ CEcoValue`.

## Risks and Mitigations

1. **Re-specialization in step 3**: Body gets specialized twice when CEcoMVar detected. Mitigated by narrow triggering condition (only when def has unresolved TVars AND no localMulti instances).

2. **TVar renaming in step 1b**: New callee TVar names (`a__callee0`) could in theory collide with user-chosen names. Mitigated by the `__callee` suffix which is not valid Elm syntax, so no user-defined TVars will have this form.

3. **Over-erasure via `fillUnconstrainedCEcoWithErased`**: Could erase a TVar that would later be constrained. Mitigated by the fact that this runs at definition specialization time (after all call-site constraints are known), so any remaining unmapped TVar is genuinely unconstrained for this specialization.

4. **Safety net over-erasure (step 6)**: Could mask real specialization bugs. Mitigated by only erasing internal expression types (not node types), so MONO_021 still catches function-level bugs.
