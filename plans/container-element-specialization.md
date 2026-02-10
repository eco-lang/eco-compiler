# Container-Element Specialization for Kernel ABIs

## Problem Statement

Currently, `number` type variables that remain unresolved after type inference are only mapped to `MInt` at MLIR codegen time (via `Types.monoTypeToAbi`). This creates issues for container-oriented kernels like `List.cons` where we want element types to be specialized during monomorphization, not deferred to codegen.

We need:
1. A **general "resolve number→Int" helper** at the MonoType level, used *during* monomorphization
2. A **container-element specialization path for kernel ABIs**, analogous to the existing `NumberBoxed` path
3. Wiring this path for kernels like `List.cons`

## Design Decisions

### 1. Scope: Universal CNumber→Int Resolution, Selective Container Specialization

**Decision:** Apply `forceCNumberToInt` **universally** for reachable MonoTypes during monomorphization, but keep container-element specialization **selective** via a whitelist (`containerSpecializedKernels`).

**Rationale:**
- `MonoType` explicitly allows `MVar _ CNumber` only as an intermediate form; MONO_002 requires no `CNumber` survive to codegen
- Universal resolution makes the CNumber→Int rule effective for all codegen paths
- Selective container-specialization allows incremental rollout and testing

### 2. Kernel Whitelist: Start with `List.cons` Only

**Decision:** Initial `containerSpecializedKernels` contains only `("List", "cons")`.

**Rationale:**
- `List.cons` is at the core of `foldl`/`reverse` and is the immediate source of the PAP mismatch issue
- Higher-order kernels like `List.map2`/`map3` are more complex; add after `cons` is stable
- `List.append` depends less on element representation; lower priority

**Future expansion (after tests pass):**
- `List.map2`, `List.map3`, `List.map4`, `List.map5`
- `List.append`

### 3. MLIR Strategy: Wrappers with Boxing/Unboxing

**Decision:** Keep kernel C declarations boxed; specialize via wrappers that box/unbox at MLIR.

**Rationale:**
- Respects FORBID_REP_001, FORBID_REP_002, FORBID_REP_003 (no SSA→heap or ABI→heap assumptions)
- Respects XPHASE_001/XPHASE_002 (heap layout and `eco.value` consistency across phases)
- Boxing/unboxing is explicit (CGEN_001)
- Less invasive than changing kernel C ABIs

**Implementation:**
- Declare `Elm_Kernel_List_cons` with boxed signature: `(!eco.value, !eco.value) -> !eco.value`
- Generate specialized wrappers (e.g., `List_cons_$_Int`) with unboxed signatures
- Wrapper body boxes `i64` args before calling kernel, unboxes results if needed

### 4. Invariant Implications

This plan helps **multiple** invariants beyond MONO_002:

| Invariant | Impact |
|-----------|--------|
| MONO_002 | **Fixed** - explicit `forceCNumberToInt` enforces no CNumber at codegen |
| CGEN_001/CGEN_012 | Simplified - `Types.monoTypeToAbi` sees only concrete `MInt`/`MFloat` |
| XPHASE_001/XPHASE_002 | Maintained - wrapper strategy keeps heap layout consistent |
| FORBID_REP_001/002/003 | Respected - boxing is explicit, no SSA↔heap conflation |

### 5. Float Handling: Only Rewrite `MVar _ CNumber`

**Decision:** `forceCNumberToInt` only affects `MVar _ CNumber`; `MFloat` and Float-typed code are untouched.

**Rationale:**
- Float-specific kernels (`Basics.toFloat`, trig functions, `Basics./`) have canonical type `Float -> Float`; they resolve to `MFloat` directly without going through `CNumber`
- `Basics./` (float division) vs `Basics.//` (int division) have different canonical types
- Elm's type system forces Float contexts via signatures; if a function is `Float -> Float`, PostSolve/Monomorphize yield `MFloat` directly

**Backend policy:** Ambiguous `number` defaults to `MInt`. This is sound because:
- Float-specific operations already carry `Float` in their canonical types
- Only truly unresolved numeric vars are subject to CNumber→Int conversion

**Future extension:** Could add `resolveCNumber : MonoType -> MonoType` that picks `MInt` or `MFloat` based on additional constraint analysis.

## Current State

### Existing Pieces

- `MonoType` and `Constraint` in `Monomorphized.elm` allow `MVar _ CNumber` as an intermediate state that must be resolved before codegen (MONO_002)
- `Types.monoTypeToAbi` and `Types.monoTypeToOperand` map `Mono.MVar _ CNumber` → `i64` at ABI/SSA levels
- `KernelAbi.deriveKernelAbiMode` implements three kernel ABI modes:
  - `UseSubstitution` - monomorphic kernels
  - `PreserveVars` - polymorphic kernels with boxed ABI
  - `NumberBoxed` - numeric kernels like `Basics.add`
- `Specialize.deriveKernelAbiType` (lines 1961-1996) uses mode to produce appropriate MonoTypes

## Implementation Plan

### Phase 1: Add `forceCNumberToInt` Helper

**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

Add near the `MonoType` definition (around line 181):

```elm
{-| Force all numeric-constrained type variables (MVar _ CNumber)
to concrete Int (MInt) inside a MonoType.

Backend policy: when we have an ambiguous `number` that has not
been resolved to Float by constraints, we default it to Int.
This is sound for ECO because Elm `number` is morally "Int or Float",
and we only commit to Int where no Float-specific behaviour is required.

IMPORTANT: This does NOT affect MFloat or Float-typed code. Only
unresolved MVar _ CNumber is converted. Float-specific operations
(Basics./, trig functions, etc.) have canonical Float types and
resolve to MFloat directly without going through CNumber.
-}
forceCNumberToInt : MonoType -> MonoType
forceCNumberToInt monoType =
    case monoType of
        MVar _ CNumber ->
            MInt

        MVar name CEcoValue ->
            MVar name CEcoValue

        MList elemType ->
            MList (forceCNumberToInt elemType)

        MFunction args result ->
            MFunction
                (List.map forceCNumberToInt args)
                (forceCNumberToInt result)

        MTuple elems ->
            MTuple (List.map forceCNumberToInt elems)

        MRecord fields ->
            MRecord (Dict.map (\_ t -> forceCNumberToInt t) fields)

        MCustom can name args ->
            MCustom can name (List.map forceCNumberToInt args)

        -- Primitives unchanged (including MFloat!)
        MInt -> MInt
        MFloat -> MFloat
        MBool -> MBool
        MChar -> MChar
        MString -> MString
        MUnit -> MUnit
```

**Action:** Export `forceCNumberToInt` from the module's `exposing` list.

### Phase 2: Add Container-Specialized Kernels Set

**File:** `compiler/src/Compiler/Monomorphize/KernelAbi.elm`

Add near `numberBoxedKernels`:

```elm
{-| Kernels whose container element representation we want to specialize
based on call-site types.

These kernels use PreserveVars mode but can benefit from element-aware
specialization when the call-site provides fully monomorphic types.

Start small and expand incrementally after invariant tests pass.
-}
containerSpecializedKernels : EverySet ( String, String )
containerSpecializedKernels =
    EverySet.fromList comparePair
        [ ( "List", "cons" )
        ]
```

### Phase 3: Modify `deriveKernelAbiType`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm` (lines 1961-1996)

Change from current implementation to:

```elm
deriveKernelAbiType : ( String, String ) -> Can.Type -> Substitution -> Mono.MonoType
deriveKernelAbiType kernelId canFuncType callSubst =
    let
        -- Monomorphic function type at this use-site, after substitution.
        monoAfterSubstRaw : Mono.MonoType
        monoAfterSubstRaw =
            TypeSubst.applySubst callSubst canFuncType

        -- Backend policy: eagerly resolve any remaining CNumber vars to Int.
        -- This does NOT affect MFloat - only unresolved numeric vars.
        monoAfterSubst : Mono.MonoType
        monoAfterSubst =
            Mono.forceCNumberToInt monoAfterSubstRaw

        mode : KernelAbi.KernelAbiMode
        mode =
            KernelAbi.deriveKernelAbiMode kernelId canFuncType
    in
    case mode of
        KernelAbi.NumberBoxed ->
            -- Numeric kernels: prefer monomorphic type if available
            if isFullyMonomorphicType monoAfterSubst then
                monoAfterSubst
            else
                KernelAbi.canTypeToMonoType_numberBoxed canFuncType

        KernelAbi.UseSubstitution ->
            monoAfterSubst

        KernelAbi.PreserveVars ->
            -- Container-specializable kernels get monomorphic, element-aware ABI
            if EverySet.member KernelAbi.comparePair kernelId KernelAbi.containerSpecializedKernels
                && isFullyMonomorphicType monoAfterSubst
            then
                -- e.g. List.cons : Int -> List Int -> List Int at this site
                monoAfterSubst
            else
                -- default: all vars become CEcoValue (fully boxed ABI)
                KernelAbi.canTypeToMonoType_preserveVars canFuncType
```

**Required imports:** Add `containerSpecializedKernels` to the `KernelAbi` import.

### Phase 4: Universal CNumber→Int in `specializeExpr`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

Apply `forceCNumberToInt` to **all** `TypeSubst.applySubst` calls in `specializeExpr` for non-kernel expressions. This ensures no `MVar _ CNumber` survives in reachable MonoTypes.

**Affected branches:**
- `TOpt.Int` literals
- `TOpt.Float` literals
- `TOpt.List`, `TOpt.Tuple`, `TOpt.Record`
- `TOpt.VarLocal`, `TOpt.TrackedVarLocal`
- `TOpt.Access`, `TOpt.Update`
- Any other expression that computes a MonoType via `TypeSubst.applySubst`

**Change pattern:**
```elm
monoType =
    TypeSubst.applySubst subst canType
```

To:
```elm
monoType =
    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
```

This makes CNumber→Int resolution universal for monomorphization, satisfying MONO_002.

### Phase 5: MLIR Wrapper Generation (Deferred)

Once MonoTypes for container kernels are specialized, MLIR codegen needs wrappers that box/unbox when calling boxed-ABI kernels with unboxed parameters.

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Strategy:**
1. Continue declaring `Elm_Kernel_List_cons` with boxed signature in MLIR
2. Generate specialized wrappers (e.g., `List_cons_$_Int`) when MonoType has unboxed parameters
3. Wrapper implementation:
   - Box `i64`/`f64` args to `!eco.value` via `eco.box` before calling kernel
   - Optionally unbox `!eco.value` results via `eco.unbox` if needed

**Note:** This is structurally similar to existing `Basics_add_$_1` wrappers for numeric intrinsics.

## Expected Behavior After Implementation

For `List.cons` with a `List Int`:
1. Canonical type: `a -> List a -> List a`
2. After call-site unification + `forceCNumberToInt`: `MFunction [MInt] (MFunction [MList MInt] (MList MInt))`
3. `deriveKernelAbiMode` returns `PreserveVars`
4. Since `("List","cons")` is in `containerSpecializedKernels` and type is fully monomorphic, `deriveKernelAbiType` returns the monomorphic type
5. `MonoVarKernel` for `List.cons` has `MInt` arguments
6. `Types.monoTypeToAbi` maps `MInt` → `i64` and `MList MInt` → `!eco.value`

## Files Modified

| Phase | File | Change |
|-------|------|--------|
| 1 | `compiler/src/Compiler/AST/Monomorphized.elm` | Add and export `forceCNumberToInt` |
| 2 | `compiler/src/Compiler/Monomorphize/KernelAbi.elm` | Add `containerSpecializedKernels` |
| 3 | `compiler/src/Compiler/Monomorphize/Specialize.elm` | Modify `deriveKernelAbiType` |
| 4 | `compiler/src/Compiler/Monomorphize/Specialize.elm` | Apply `forceCNumberToInt` universally in `specializeExpr` |
| 5 | `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Add wrapper generation for specialized kernel calls |

## Testing Strategy

1. **Unit tests:** `cd compiler && npx elm-test-rs --fuzz 1`
2. **E2E tests:** `cmake --build build --target check`
3. **Specific test cases:**
   - `List.cons` with `Int` element type
   - `List.cons` with `Float` element type (should still use `MFloat`)
   - `foldl` building `List Int` (the original motivating case)
4. **Invariant verification:**
   - MONO_002: No `MVar _ CNumber` in MLIR output
   - CGEN_012: Correct type mapping (`MInt` → `i64`, `MFloat` → `f64`)
   - XPHASE_001/002: Consistent layout across phases

## Future Work

After this plan is implemented and stable:

1. **Expand `containerSpecializedKernels`:**
   - `List.map2`, `List.map3`, `List.map4`, `List.map5`
   - `List.append`

2. **Enhanced constraint analysis:**
   - Extend `forceCNumberToInt` to `resolveCNumber` that picks `MInt` or `MFloat` based on usage context
   - Example: `sqrt` usage could force `CNumber` → `MFloat`

3. **Direct kernel ABI specialization (Strategy B):**
   - Once wrapper strategy is proven, consider changing kernel C ABIs for hot paths
   - Requires coordinated changes to MLIR declarations and runtime C++ signatures
