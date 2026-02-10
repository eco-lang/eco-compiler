# Fix List.cons Kernel ABI: Generic Backend ABI Policy

## Problem

When `List.cons` is used at a monomorphic call site (e.g., `Int -> List Int -> List Int`), the monomorphizer produces a specialized `funcType` like `MFunction [MInt, MList MInt] (MList MInt)`. MLIR codegen then derives the kernel ABI from this type, emitting `Elm_Kernel_List_cons(i64, !eco.value) -> !eco.value`. But at a polymorphic call site the same kernel gets `(!eco.value, !eco.value) -> !eco.value`, triggering `registerKernelCall`'s "Kernel signature mismatch" crash (`Context.elm:522-547`).

Even when no mismatch crash occurs, passing a raw `i64` to the C++ `Elm_Kernel_List_cons` (which expects boxed `uint64_t` pointers) causes a runtime segfault.

## Design: Two-Layer Kernel ABI

For each kernel `(home, name)` there are now two distinct type concepts:

1. **Elm wrapper type** (from monomorphization): The call-site specialized `funcType` attached to `MonoVarKernel`. For `containerSpecializedKernels`, this is concrete (e.g., `MFunction [MInt, MList MInt] (MList MInt)`). Used for specializing Elm-level wrapper closures (`List_cons_$_N`).

2. **Kernel backend ABI policy** (new, in MLIR codegen): Says how the underlying C++ symbol should actually be called:
   - **AllBoxed**: every arg and result is `!eco.value`, regardless of the wrapper type.
   - **ElmDerived**: derive ABI from the wrapper `funcType` via `monoTypeToAbi` (current behavior).

The fix separates these two layers: MLIR codegen consults the **backend ABI policy** (not the wrapper type) when emitting kernel calls. `boxToMatchSignatureTyped` adapts from actual SSA types to the backend ABI, inserting `eco.box`/`eco.unbox` as needed.

## C++ Kernel ABI Survey

Analysis of `elm-kernel-cpp/src/` to determine which modules are safe for `AllBoxed`:

| Module   | C++ ABI | Safe for AllBoxed? | Notes |
|----------|---------|--------------------|-------|
| List     | All `uint64_t` (boxed) | YES | All args/returns are boxed eco.value |
| Utils    | All `uint64_t` (boxed) | YES (but deferred) | compare, equal, append — all boxed; no bug today since not in `containerSpecializedKernels` |
| String   | MIXED | NO | `length` returns `int64_t`; `cons` takes `uint16_t`; `slice` takes `int64_t, int64_t` |
| Char     | MIXED | NO | Uses `uint16_t` (i16) and `int64_t` |
| Basics   | MIXED | NO | Trig: `double`; arith: mixed; conversions: typed |
| Bitwise  | All `int64_t` (unboxed) | NO | Unboxed integer ABI |
| Json     | MIXED | NO | `decodeIndex` takes `int64_t` |

**Conservative approach**: Only `List` is marked `AllBoxed` initially. `Utils` is left as `ElmDerived` — its `PreserveVars` mode with `canTypeToMonoType_preserveVars` already produces all-boxed types via the existing path, and it's not in `containerSpecializedKernels`, so there's no mismatch bug to fix. Flipping Utils to `AllBoxed` later is safe but unnecessary now.

## Changes

### Step 1: Add `KernelBackendAbiPolicy` type and classifier in `Context.elm`

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

#### 1a. Add the type (near `FuncSignature`, around line 65)

```elm
{-| Backend ABI policy for kernel function calls.

    AllBoxed   -> All args and result are !eco.value in MLIR, regardless of
                  the monomorphized Elm wrapper type. Used for kernels whose
                  C++ implementation uniformly takes boxed uint64_t values
                  (e.g., List.cons).

    ElmDerived -> ABI is derived from the Elm wrapper's funcType via
                  kernelFuncSignatureFromType + monoTypeToAbi. Used for
                  kernels with typed C++ signatures (e.g., Basics.fdiv takes
                  double, String.cons takes uint16_t).
-}
type KernelBackendAbiPolicy
    = AllBoxed
    | ElmDerived
```

#### 1b. Add the classifier function

Uses `(home, name)` matching from the start to support per-name overrides without API changes:

```elm
{-| Determine the backend ABI policy for a kernel call.

Only kernels whose C++ implementation takes ALL arguments as boxed
uint64_t (eco.value) and returns uint64_t should be marked AllBoxed.
When in doubt, use ElmDerived (safe default — preserves current behavior).
-}
kernelBackendAbiPolicy : String -> String -> KernelBackendAbiPolicy
kernelBackendAbiPolicy home name =
    case ( home, name ) of
        -- List.cons: container-specialized kernel with all-boxed C++ ABI.
        -- The Elm wrapper type may be monomorphic (e.g., MFunction [MInt, MList MInt] ...),
        -- but the C++ Elm_Kernel_List_cons always takes (uint64_t, uint64_t) -> uint64_t.
        ( "List", "cons" ) ->
            AllBoxed

        -- All other List kernels are also all-boxed in C++.
        -- (fromArray, toArray, map2..map5, sortBy, sortWith)
        ( "List", _ ) ->
            AllBoxed

        -- Everything else: derive ABI from the Elm wrapper type.
        -- This preserves current behavior for:
        --   Utils   (all boxed, but no bug today — not in containerSpecializedKernels)
        --   Basics  (mixed: double, int64_t, uint64_t)
        --   Bitwise (all int64_t — unboxed)
        --   String  (mixed: uint16_t for Char, int64_t for length/slice)
        --   Char    (mixed: uint16_t, int64_t)
        --   Json    (mixed: int64_t for decodeIndex)
        _ ->
            ElmDerived
```

#### 1c. Update module exports (line 1-8)

Add `KernelBackendAbiPolicy(..)` and `kernelBackendAbiPolicy` to the exposing list:

```elm
module Compiler.Generate.MLIR.Context exposing
    ( Context, FuncSignature, PendingLambda, TypeRegistry, VarInfo
    , initContext
    , freshVar, freshOpId, lookupVar, addVarMapping
    , getOrCreateTypeIdForMonoType, registerKernelCall
    , buildSignatures, kernelFuncSignatureFromType
    , isTypeVar, hasKernelImplementation
    , KernelBackendAbiPolicy(..), kernelBackendAbiPolicy
    )
```

### Step 2: Refactor kernel call lowering in `Expr.elm` to use the policy

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`
**Location:** Lines 1849-1882, the `Nothing ->` branch inside the `MonoVarKernel` case of `MonoCall` handling.

Replace the single generic kernel path with policy-driven dispatch:

```elm
                        Nothing ->
                            let
                                policy : Ctx.KernelBackendAbiPolicy
                                policy =
                                    Ctx.kernelBackendAbiPolicy home name
                            in
                            case policy of
                                Ctx.AllBoxed ->
                                    -- Underlying C++ ABI: all args and result are !eco.value,
                                    -- regardless of the monomorphic Elm wrapper type.
                                    -- Box any primitive SSA values to match the kernel ABI.
                                    let
                                        elmSig : Ctx.FuncSignature
                                        elmSig =
                                            Ctx.kernelFuncSignatureFromType funcType

                                        numArgs : Int
                                        numArgs =
                                            List.length elmSig.paramTypes

                                        -- Backend ABI: all MUnit => all !eco.value
                                        backendParamTypes : List Mono.MonoType
                                        backendParamTypes =
                                            List.repeat numArgs Mono.MUnit

                                        ( boxOps, argVarPairs, ctx1b ) =
                                            boxToMatchSignatureTyped ctx1 argsWithTypes backendParamTypes

                                        ( resVar, ctx2 ) =
                                            Ctx.freshVar ctx1b

                                        kernelName : String
                                        kernelName =
                                            "Elm_Kernel_" ++ home ++ "_" ++ name

                                        resultMlirType : MlirType
                                        resultMlirType =
                                            Types.ecoValue

                                        ( ctx3, callOp ) =
                                            Ops.ecoCallNamed ctx2 resVar kernelName argVarPairs resultMlirType
                                    in
                                    { ops = argOps ++ boxOps ++ [ callOp ]
                                    , resultVar = resVar
                                    , resultType = resultMlirType
                                    , ctx = ctx3
                                    , isTerminated = False
                                    }

                                Ctx.ElmDerived ->
                                    -- ABI derived from the Elm wrapper's funcType.
                                    -- This is the original generic path, unchanged.
                                    let
                                        elmSig : Ctx.FuncSignature
                                        elmSig =
                                            Ctx.kernelFuncSignatureFromType funcType

                                        ( boxOps, argVarPairs, ctx1b ) =
                                            boxToMatchSignatureTyped ctx1 argsWithTypes elmSig.paramTypes

                                        ( resVar, ctx2 ) =
                                            Ctx.freshVar ctx1b

                                        kernelName : String
                                        kernelName =
                                            "Elm_Kernel_" ++ home ++ "_" ++ name

                                        resultMlirType : MlirType
                                        resultMlirType =
                                            Types.monoTypeToAbi elmSig.returnType

                                        ( ctx3, callOp ) =
                                            Ops.ecoCallNamed ctx2 resVar kernelName argVarPairs resultMlirType
                                    in
                                    { ops = argOps ++ boxOps ++ [ callOp ]
                                    , resultVar = resVar
                                    , resultType = resultMlirType
                                    , ctx = ctx3
                                    , isTerminated = False
                                    }
```

**How `AllBoxed` works:**
- Gets arity from the wrapper's `funcType` (e.g., 2 for `List.cons`).
- Constructs `backendParamTypes = [MUnit, MUnit]`. `monoTypeToAbi MUnit = !eco.value`.
- `boxToMatchSignatureTyped` compares actual SSA types against expected `!eco.value`:
  - `i64` head -> inserts `eco.box` -> `!eco.value`
  - `!eco.value` tail -> no-op
- Sets `resultMlirType = Types.ecoValue` (i.e., `!eco.value`).
- `Ops.ecoCallNamed` registers the kernel in `registerKernelCall` with the consistent all-boxed signature.

**How `ElmDerived` works:** Identical to current code — no behavioral change.

### Step 3: No changes to monomorphization (`Specialize.elm`)

`deriveKernelAbiType` for `("List", "cons")` in `PreserveVars` mode already returns the call-site monomorphic type when fully monomorphic. This is correct — the specialized type drives **Elm-level wrapper** specialization, not the C++ kernel ABI.

**Action:** Update the comment in the `PreserveVars` branch (line ~2001 of `Specialize.elm`) to clarify:

```elm
            -- Container-specializable kernels get monomorphic, element-aware type
            -- for Elm-level wrapper specialization. The C++ kernel ABI is determined
            -- separately by kernelBackendAbiPolicy in MLIR codegen, which may
            -- override this type with all-boxed !eco.value arguments.
```

### Step 4: No changes to GlobalOpt (`MonoGlobalOptimize.elm`)

`ensureCallableForNode` (lines 744-790) wraps kernel references in alias closures using the specialized type. These closures ARE the per-type specialized wrappers (`List_cons_$_N`). Their body calls `MonoVarKernel` which then goes through the policy-driven path in Expr.elm. GlobalOpt behavior is already correct.

### Step 5: Update comment in `KernelAbi.elm`

**File:** `compiler/src/Compiler/Monomorphize/KernelAbi.elm`
**Location:** Comment near `containerSpecializedKernels` (line ~132)

```elm
{-| Kernels that benefit from element-aware specialization at fully monomorphic
call sites. The specialized MonoType drives Elm-level wrapper generation
(different List_cons_$_N closures per element type), NOT the C++ kernel ABI.

The actual C++ kernel ABI is determined by `kernelBackendAbiPolicy` in
MLIR codegen (Context.elm), which may force all-boxed !eco.value arguments
regardless of the wrapper's specialized types.
-}
containerSpecializedKernels =
    EverySet.fromList comparePair
        [ ( "List", "cons" )
        ]
```

### Step 6: No changes to Runtime/C++

`Elm_Kernel_List_cons(uint64_t head, uint64_t tail)` expects boxed `eco.value` arguments. After step 2, all MLIR call sites pass `(!eco.value, !eco.value)`, matching the C++ expectation.

## Other kernel call sites in Expr.elm (no changes needed)

There are several other places in Expr.elm that emit kernel calls. None need the policy:

| Location | What | Why unchanged |
|----------|------|---------------|
| Lines 1713-1755 | `Basics.logBase` special case | Inlined as eco.float.log + eco.float.div |
| Lines 1757-1823 | `Debug.log` special case | Emits eco.dbg, not a kernel call |
| Lines 1826-1847 | Intrinsic dispatch | Handled before the `Nothing ->` branch |
| Lines 1459-1487 | `Bytes.Encode.encode` fallback | Reached via `MonoVarGlobal`, not `MonoVarKernel`; `Bytes.Encode.encode` takes `Encoder -> Bytes`, both always `!eco.value` |
| Lines 1537-1564 | `Bytes.decode` fallback | Reached via `MonoVarGlobal`; already uses `[MUnit, MUnit]` pattern |
| Lines 1595-1626 | `hasKernelImplementation` path | Dead code (`hasKernelImplementation` always returns `False`) |
| Line 447-479 | `generateVarKernel` (reference, not call) | Produces a kernel *reference*, not a call; goes through intrinsic check for constants |

## What this does NOT change

- **Monomorphization behavior** — `deriveKernelAbiType` still returns specialized types for `containerSpecializedKernels`
- **GlobalOpt wrapper generation** — alias closures still have specialized param types
- **ElmDerived kernel ABIs** — Utils, Basics, Bitwise, String, Char, Json, etc. keep their current behavior
- **Intrinsics path** — kernels with intrinsic lowering (e.g., `Basics.add` -> `eco.int.add`) are unaffected

## Scaling

To add a new kernel to the `AllBoxed` policy:

1. **Verify** the C++ implementation takes all `uint64_t` args and returns `uint64_t`.
2. **Add** it to `kernelBackendAbiPolicy` in `Context.elm` (per-name or widen to per-module).
3. **Optionally** add it to `containerSpecializedKernels` in `KernelAbi.elm` if you want element-aware wrapper specialization.

No changes to `Expr.elm` are needed — the policy-driven dispatch handles all `AllBoxed` kernels uniformly.

For future kernels with a partially-typed C++ ABI (e.g., one unboxed `i64` arg and one boxed arg), add a third policy constructor:
```elm
    | Custom (List Mono.MonoType) Mono.MonoType
```

## Testing

1. **Rebuild and run E2E tests:**
   ```bash
   cmake --build build && cmake --build build --target check
   ```

2. **Previously failing tests should pass:**
   - `ListConcatTest` — uses `List.cons` via `++`
   - `ListFoldrTest` — `List.foldr` builds lists with `cons`
   - `ListReverseTest` — `List.reverse` builds with `cons`
   - `RecordAccessorFunctionTest` — exercises list operations
   - `ListConsTest` — direct `::` cons operator

3. **Verify MLIR output** for a program like `List.reverse [1,2,3]`:
   - Wrapper functions `List_cons_$_N` should have `i64` head parameters
   - Single kernel declaration: `func.func private @Elm_Kernel_List_cons(!eco.value, !eco.value) -> !eco.value`
   - Wrapper bodies should contain `eco.box` before the kernel call when head is `i64`

4. **Run frontend tests** to verify monomorphization is unchanged:
   ```bash
   cd compiler && npx elm-test-rs --fuzz 1
   ```

## Invariant compliance

- **REP_ABI_001**: `AllBoxed` kernels now always receive `!eco.value` args, matching C++ expectations
- **CGEN_012**: Type mapping correct — `MUnit -> !eco.value`, `MInt -> i64` (boxed before call)
- **CGEN_003**: Wrapper closure captures unaffected (still use SSA types)
- **CGEN_007**: `boxToMatchSignatureTyped` correctly adapts SSA types to backend ABI
- No new `FORBID_*` patterns introduced
