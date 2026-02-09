# Numeric Kernel Call-Site Specialization

## Problem Statement

When `Basics.add` (or other number-polymorphic kernels) is passed as a higher-order argument to functions like `List.foldl`, the compiler currently:
1. Specializes `List_foldl_$_2` to use `i64` for accumulator/elements
2. Does NOT specialize `Basics_add_$_1` - it remains `(!eco.value, !eco.value) -> !eco.value`

This causes an ABI mismatch: `papExtend` passes `(i64, i64)` to a closure whose evaluator expects `(!eco.value, !eco.value)`, causing runtime crashes.

## Solution Overview

Make `deriveKernelAbiType` respect **call-site specialization** for number-boxed kernels:
- If the call has been fully specialized to `Int` or `Float` → use the monomorphic type (enables `eco.int.add` intrinsic)
- Otherwise → fall back to the boxed ABI (`Elm_Kernel_Basics_add`)

## Implementation Steps

### Step 1: Add `isFullyMonomorphicType` Helper

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

**Location:** Add immediately above the `-- ========== KERNEL ABI TYPE DERIVATION ==========` comment

**Code to add:**
```elm
{-| Return True if a MonoType contains no remaining type variables.

Used to detect when a kernel use has been fully specialized at a call site
(e.g. Basics.add : number -> number -> number instantiated as
 Int -> Int -> Int or Float -> Float -> Float).
-}
isFullyMonomorphicType : Mono.MonoType -> Bool
isFullyMonomorphicType monoType =
    case monoType of
        Mono.MVar _ _ ->
            False

        Mono.MList inner ->
            isFullyMonomorphicType inner

        Mono.MFunction args result ->
            List.all isFullyMonomorphicType args
                && isFullyMonomorphicType result

        Mono.MTuple elems ->
            List.all isFullyMonomorphicType elems

        Mono.MRecord fields ->
            Dict.foldl
                (\_ fieldType acc -> acc && isFullyMonomorphicType fieldType)
                True
                fields

        Mono.MCustom _ _ args ->
            List.all isFullyMonomorphicType args

        -- Primitive / unit types are trivially monomorphic
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MBool ->
            True

        Mono.MChar ->
            True

        Mono.MString ->
            True

        Mono.MUnit ->
            True
```

### Step 2: Modify `deriveKernelAbiType`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

**Find:** The existing `deriveKernelAbiType` function

**Replace with:**
```elm
-- ========== KERNEL ABI TYPE DERIVATION ==========


{-| Derive the MonoType for a kernel function's ABI.

This is *call-site aware*:

  * For monomorphic uses (no remaining MVar in the instantiated function type),
    we prefer the fully specialized MonoType obtained by applying the call-site
    substitution. This enables specializing number-polymorphic kernels like
    Basics.add to Int/Float and using intrinsics (eco.int.add / eco.float.add).

  * For genuinely polymorphic uses, we fall back to the KernelAbiMode-driven
    behavior:

        - UseSubstitution  -> applySubst
        - PreserveVars     -> all CEcoValue (boxed) vars
        - NumberBoxed      -> treat CNumber vars as CEcoValue (boxed)

-}
deriveKernelAbiType : ( String, String ) -> Can.Type -> Substitution -> Mono.MonoType
deriveKernelAbiType kernelId canFuncType callSubst =
    let
        -- Monomorphic function type at this use-site, if substitution is complete.
        -- Example for Basics.add in an Int context:
        --   canFuncType = number -> number -> number
        --   monoAfterSubst = MFunction [MInt] (MFunction [MInt] MInt)
        monoAfterSubst : Mono.MonoType
        monoAfterSubst =
            TypeSubst.applySubst callSubst canFuncType

        mode : KernelAbi.KernelAbiMode
        mode =
            KernelAbi.deriveKernelAbiMode kernelId canFuncType
    in
    case mode of
        KernelAbi.NumberBoxed ->
            -- Special case: number-polymorphic kernels like Basics.add/sub/mul/pow.
            --
            -- If this PARTICULAR use-site has been fully specialized (e.g. Int or
            -- Float everywhere), prefer the fully-monomorphic type. This lets
            -- MLIR see concrete MInt/MFloat arguments for intrinsics and avoids
            -- going through the boxed C ABI (@Elm_Kernel_Basics_add).
            if isFullyMonomorphicType monoAfterSubst then
                monoAfterSubst

            else
                -- Still genuinely number-polymorphic here: fall back to boxed ABI.
                KernelAbi.canTypeToMonoType_numberBoxed canFuncType

        KernelAbi.UseSubstitution ->
            -- Monomorphic kernel type from the outset (no type variables).
            monoAfterSubst

        KernelAbi.PreserveVars ->
            -- Polymorphic kernel whose ABI must remain fully boxed (!eco.value).
            KernelAbi.canTypeToMonoType_preserveVars canFuncType
```

### Step 3: Add MONO_NUM_001 Invariant Test

**File:** `compiler/tests/Compiler/Monomorphize/NumericKernelSpecializationTest.elm` (new file)

**Purpose:** Verify that numeric kernel calls in MonoGraph are either:
1. Fully monomorphic numeric (no MVar) with primitive Int/Float types, OR
2. Fully boxed (MVar CEcoValue everywhere)

**Test cases to include:**
- `List.foldl (+) 0 [1,2,3]` → should produce `MInt -> MInt -> MInt` for the `(+)` use
- `List.foldl (*) 1.0 [1.0,2.0]` → should produce `MFloat -> MFloat -> MFloat`
- Polymorphic use (if testable) → should remain fully boxed

### Step 4: Add CGEN_NUM_001 MLIR Invariant

**File:** Extend existing MLIR verification in `runtime/src/codegen/EcoOps.cpp`

**Purpose:** Ensure `eco.call @Elm_Kernel_Basics_add` (and similar) only receives `!eco.value` operands

**Implementation:** Add check in `CallOp::verify()` or create a dedicated pass that:
- Finds all `eco.call` ops to `Elm_Kernel_Basics_{add,sub,mul,pow}`
- Asserts all operand types are `!eco.value`
- Asserts result type is `!eco.value`

### Step 5: Update E2E Tests

**Expected outcomes after fix:**
- `ListFoldlTest` → PASS (no more ABI mismatch)
- `ListFoldrTest` → PASS
- `ListReverseTest` → PASS
- `ListConcatTest` → PASS
- `LambdaCaseBoundaryTest` → PASS

## Verification Plan

1. Run `cd compiler && npx elm-test-rs --fuzz 1` to verify no regressions in frontend
2. Run `cmake --build build --target clean && cmake --build build --target check` for full E2E
3. Run `TEST_FILTER=elm-core cmake --build build --target check` to verify the 5 crashing tests now pass

## Risk Assessment

**Low risk:** This change is additive - it only affects `NumberBoxed` kernels when the call-site is fully monomorphic. Polymorphic uses continue through the existing boxed ABI path.

**Invariants guard against regression:** The new MONO_NUM_001 and CGEN_NUM_001 invariants will catch any future changes that break the "either fully specialized OR fully boxed" property.

## Open Questions

1. **Resolved:** Should we also handle `negate`, `abs`, `toFloat`, `round`, etc.?
   - Answer: Only kernels in `numberBoxedKernels` set are affected. Check `KernelAbi.elm` for the full list.

2. **Resolved:** Does `isFullyMonomorphicType` need to handle `MRecExt` or other record extension types?
   - Answer: Verified - `MonoType` ADT (Monomorphized.elm:167-179) has no `MRecExt`. The helper covers all cases:
     `MInt | MFloat | MBool | MChar | MString | MUnit | MList | MTuple | MRecord | MCustom | MFunction | MVar`

## Code Locations (verified)

- `deriveKernelAbiType`: `Specialize.elm` lines 1845-1857
- `MonoType` ADT: `Monomorphized.elm` lines 167-179
- Call sites using `deriveKernelAbiType`:
  - `VarKernel` handling: lines 695-700
  - `Call` with kernel func: lines 764-780
  - `Call` with Debug func: lines 787-802

## Files Modified

| File | Change |
|------|--------|
| `compiler/src/Compiler/Monomorphize/Specialize.elm` | Add `isFullyMonomorphicType`, modify `deriveKernelAbiType` |
| `compiler/tests/Compiler/Monomorphize/NumericKernelSpecializationTest.elm` | New invariant test file |
| `runtime/src/codegen/EcoOps.cpp` | Optional: Add CGEN_NUM_001 verification |
