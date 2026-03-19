# Plan: CallGenericApply for Dynamic Callees (Path A)

## Goal

Enable `CallGenericApply` only for truly dynamic callees (function parameters whose staging slot the solver marked dynamic), using `eco_apply_closure` with all-boxed HPointer args.

After this work:
- **GlobalOpt** sets `callKind = CallGenericApply` when the callee is a dynamic staging slot.
- **MLIR codegen** emits generic `eco.papExtend` (no `remaining_arity`) with primitives left unboxed in the MLIR IR and `newargs_unboxed_bitmap` marking them. Result is always `!eco.value`, coerced back to the expected ABI type.
- **EcoToLLVM** `lowerGenericApply` boxes all primitive newargs to HPointer at the LLVM level (using `_operand_types` / SSA types to know which type to box as), then passes only HPointers in the `uint64_t[]` to `eco_apply_closure`.
- **Runtime** `eco_apply_closure` is unchanged — it receives all-boxed HPointer args as today.

---

## Design Decisions (Resolved)

### Q1 resolved: Option 3 — box at LLVM level, not runtime

The bitmap alone cannot tell the runtime *which* primitive type an unboxed arg is (Int vs Float vs Char). Rather than adding type bitmaps or changing the runtime ABI, we box primitives in `lowerGenericApply` where the LLVM types are known. The runtime sees only HPointers. This eliminates Steps 6-8 (no runtime signature changes). The MLIR `newargs_unboxed_bitmap` remains correct for verification and future Path B use.

### Q2 resolved: Verify dynamic slots empirically

`identifyDynamicSlots` is intended to mark slots with no producer segmentation (e.g., function parameters). Before implementing, add a debug dump after solving to confirm `dynamicSlots` is non-empty for patterns like `apply f x = f x`. If the solver assigns fallback segmentations, `isDynamicCallee` would never fire and must be fixed in the staging graph first.

### Q3 resolved: Only `MonoTailFunc` parameters need `SlotParam` mapping

`SlotParam(funcId, paramIndex)` is created by GraphBuilder for `MonoTailFunc` parameters. `MonoDefine` closures use `SlotCapture`. `isDynamicCallee` works uniformly via `dynamicSlots` keys as long as GraphBuilder creates `SlotParam` for all relevant parameters.

### Q4 resolved: No bitmap splitting needed

Under Option 3, `eco_apply_closure` receives all-boxed HPointer args. Over-saturation chaining just slices the args array — no bitmap to split.

### Q5 resolved: Bypassing `applyByStages` is correct

For `CallGenericApply`, a single generic `eco.papExtend` delegates staging to the runtime. `eco_apply_closure` handles under/exact/over-saturation via the closure header, including chaining for over-saturated calls. `applyByStages` is only for `CallDirectKnownSegmentation`.

### Q6 resolved: All calls annotated before codegen

`defaultCallInfo` (with `CallGenericApply`) is a placeholder from monomorphization. `annotateCallStaging` in GlobalOpt overwrites `CallInfo` on every `MonoCall` before MLIR codegen, per invariant XPHASE_010.

---

## Step-by-step Plan

### Step 0: Verify `dynamicSlots` fires for HOF parameters

**File:** `compiler/src/Compiler/GlobalOpt/Staging/Solver.elm`

**Action:** Add a temporary `Debug.log` in `identifyDynamicSlots` or after `solve` returns, then compile a test module:
```elm
apply : (Int -> Int) -> Int -> Int
apply f x = f x
```

**Verify:** The `dynamicSlots` set contains a key like `"P:<nodeId>:0"` for `f`'s parameter slot. If empty, investigate whether GraphBuilder creates `SlotParam` for it and whether `identifyDynamicSlots` correctly detects the no-producer class.

**Exit criterion:** `dynamicSlots` is non-empty for the `f` parameter. If not, fix the staging solver first (out of scope for this plan).

---

### Step 1: Thread node ID into call annotation

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

**Problem:** `annotateCallStaging` uses `Array.map` (line 1090), so `annotateNodeCalls` doesn't receive the node ID. But `dynamicSlots` keys are `"P:<nodeId>:<paramIndex>"`, requiring the node ID to map parameter names to slot keys.

**Changes:**

1. Add a field to `CallEnv`:
   ```elm
   type alias CallEnv =
       { varCallModel : Dict Name Mono.CallModel
       , varSourceArity : Dict Name Int
       , dynamicSlots : Set String
       , paramSlotKeys : Dict Name String   -- NEW: param Name → slot key
       }
   ```
   Initialize `paramSlotKeys = Dict.empty` in `emptyCallEnv`.

2. Change `annotateCallStaging` (line 1090) from `Array.map` to `Array.indexedMap`:
   ```elm
   newNodes =
       Array.indexedMap
           (\nodeId -> Maybe.map (annotateNodeCalls graph nodeId env))
           record.nodes
   ```

3. Update `annotateNodeCalls` signature to accept `nodeId : Int`.

4. In the `MonoTailFunc params body tipe` branch, build `paramSlotKeys` and merge into `env`:
   ```elm
   Mono.MonoTailFunc params body tipe ->
       let
           paramSlotKeys =
               params
                   |> List.indexedMap
                       (\index ( name, ty ) ->
                           if Mono.isFunctionType ty then
                               Just
                                   ( name
                                   , "P:" ++ String.fromInt nodeId ++ ":" ++ String.fromInt index
                                   )
                           else
                               Nothing
                       )
                   |> List.filterMap identity
                   |> Dict.fromList

           envWithParams =
               { env | paramSlotKeys = paramSlotKeys }
       in
       Mono.MonoTailFunc params (annotateExprCalls graph envWithParams body) tipe
   ```

---

### Step 2: Add `isDynamicCallee` helper

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

Add near `computeCallInfo`:

```elm
{-| Check if a callee expression is a dynamic staging slot (function parameter
    whose equivalence class has no producer segmentation). Only these callees
    should use CallGenericApply for runtime dispatch.
-}
isDynamicCallee : CallEnv -> Mono.MonoExpr -> Bool
isDynamicCallee env funcExpr =
    case funcExpr of
        Mono.MonoVarLocal name monoType ->
            case Dict.get name env.paramSlotKeys of
                Just slotKey ->
                    Set.member slotKey env.dynamicSlots
                        && Mono.isFunctionType monoType

                Nothing ->
                    False

        _ ->
            False
```

---

### Step 3: Use `isDynamicCallee` in `computeCallInfo`

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

In the `StageCurried` branch of `computeCallInfo` (around line 1847), change:
```elm
callKind : Mono.CallKind
callKind =
    Mono.CallDirectKnownSegmentation
```
to:
```elm
callKind : Mono.CallKind
callKind =
    if isDynamicCallee env func then
        Mono.CallGenericApply
    else
        Mono.CallDirectKnownSegmentation
```

---

### Step 4: Add `_call_kind` debug annotations to MLIR

**Files:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`, `compiler/src/Compiler/Generate/MLIR/Ops.elm`

Every MLIR call site produced from a `MonoCall` must carry a string attribute `_call_kind` with one of:
- `"generic_apply"` — for `CallGenericApply`
- `"direct_flat"` — for `CallDirectFlat`
- `"direct_known_segmentation"` — for `CallDirectKnownSegmentation`

This is debug-only: EcoToLLVM and the runtime ignore it.

#### 4a. Add a helper to convert `CallKind` to the attribute string

```elm
callKindToAttrString : Mono.CallKind -> String
callKindToAttrString callKind =
    case callKind of
        Mono.CallGenericApply ->
            "generic_apply"

        Mono.CallDirectFlat ->
            "direct_flat"

        Mono.CallDirectKnownSegmentation ->
            "direct_known_segmentation"
```

#### 4b. Thread `callKind` into lowering functions

Modify `generateCall` to pass the `_call_kind` string into each lowering path:

1. **`generateGenericApply`** (lines 1281-1285): Add `("_call_kind", StringAttr "generic_apply")` to the `papExtendAttrs` `Dict.fromList`.

2. **`generateSaturatedCall`**: This function emits `eco.call` via `Ops.ecoCallNamed` (lines 2077, 2154, 2216, 2258, 2301). Two options:
   - **(Preferred)** Add an optional `extraAttrs : Dict String MlirAttr` parameter to `ecoCallNamed` in `Ops.elm` (or a variant `ecoCallNamedWithAttrs`), so `generateSaturatedCall` can pass `_call_kind` through.
   - Alternatively, post-process the returned `MlirOp` to insert the attribute before appending to ops.

   When called from `CallDirectFlat`: pass `"direct_flat"`.
   When called from `CallDirectKnownSegmentation` (single-stage saturated): pass `"direct_known_segmentation"`.

3. **`generateClosureApplication` → `applyByStages`** (lines 1427-1431): Add `("_call_kind", StringAttr "direct_known_segmentation")` to the `papExtendAttrs` on the **first** `eco.papExtend` only. Add a parameter `isFirstStage : Bool` (or pass the attribute as `Maybe`) to `applyByStages`; set `True` on the initial call, `False` on recursive calls.

#### Insertion points (by line):

| Path | Op | File:Line | Attribute dict |
|------|-----|-----------|----------------|
| `CallGenericApply` | `eco.papExtend` (no `remaining_arity`) | Expr.elm:1281 | `papExtendAttrs` `Dict.fromList` |
| `CallDirectFlat` | `eco.call` via `Ops.ecoCallNamed` | Ops.elm:451 | `attrs` in `ecoCallNamed` |
| `CallDirectKnownSegmentation` (saturated) | `eco.call` via `Ops.ecoCallNamed` | Ops.elm:451 | `attrs` in `ecoCallNamed` |
| `CallDirectKnownSegmentation` (multi-stage) | first `eco.papExtend` | Expr.elm:1427 | `papExtendAttrs` `Dict.fromList` |

#### Invariant

Every MLIR call site from a `MonoCall` must have exactly one `_call_kind` on its primary op. Absence indicates a codegen bug (call path not wired through `generateCall` or missing instrumentation).

---

### Step 5: Change `generateGenericApply` boxing strategy

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

In `generateGenericApply` (line ~1247), change:
```elm
( boxOps, boxedArgsWithTypes, ctx2 ) =
    boxArgsForClosureBoundary True ctx1 argsWithTypes
```
to:
```elm
( boxOps, argsForClosure, ctx2 ) =
    boxArgsForClosureBoundary False ctx1 argsWithTypes
```

**Effect:**
- `False` means only Bool (i1) is boxed to `!eco.value`; Int/Float/Char stay as primitives in the MLIR IR.
- The existing `newargs_unboxed_bitmap` computation now correctly marks primitive args (previously it was always 0 because everything was pre-boxed).
- Update the variable names downstream from `boxedArgsWithTypes` to `argsForClosure` for clarity.

---

### Step 6: Add result coercion in `generateCall`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

In the `CallGenericApply` branch of `generateCall` (line ~1201), wrap the result:

```elm
Mono.CallGenericApply ->
    let
        genericRes =
            generateGenericApply ctx func args resultType callInfo

        expectedType =
            Types.monoTypeToAbi resultType

        ( coerceOps, finalVar, finalCtx ) =
            coerceResultToType genericRes.ctx
                genericRes.resultVar
                genericRes.resultType
                expectedType
    in
    { ops = genericRes.ops ++ coerceOps
    , resultVar = finalVar
    , resultType = expectedType
    , ctx = finalCtx
    , isTerminated = False
    }
```

`coerceResultToType` (line 1168) inserts `eco.unbox` when `expectedType` is primitive and `genericRes.resultType` is `!eco.value`, and is a no-op when types already match.

---

### Step 7: Update `lowerGenericApply` to box primitives at LLVM level

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` (lines 831-894)

The current `lowerGenericApply` already boxes all arguments. The change is to make boxing **type-aware using `_operand_types`** rather than unconditional:

For each newarg, read its type from `_operand_types` (or the SSA type):
- **i64 (Int):** Call `eco_alloc_int(val)` → get HPointer, store as i64.
- **f64 (Float):** Call `eco_alloc_float(val)` → get HPointer, store as i64.
- **i16 (Char):** Call `eco_alloc_char(zext val)` → get HPointer, store as i64.
- **ptr (`!eco.value`):** Already HPointer, `ptrtoint` to i64 and store.

Then call `eco_apply_closure(closure, args, num_args)` with the **existing 3-parameter signature** (no bitmap).

**Note:** This is functionally very similar to what the code does today. The main difference is that the MLIR operands now arrive with their native types (i64/f64/i16) instead of all being `!eco.value`, so the LLVM lowering dispatches boxing based on SSA type rather than assuming everything is already a pointer.

---

### Step 8: Tests

1. **Elm E2E test cases** — create test files exercising dynamic function parameters:
   ```elm
   apply : (Int -> Int) -> Int -> Int
   apply f x = f x

   apply2 : (Int -> Int -> Int) -> Int -> Int -> Int
   apply2 f x y = f x y

   applyFloat : (Float -> Float) -> Float -> Float
   applyFloat f x = f x

   mapApply : (Int -> Int) -> List Int -> List Int
   mapApply f xs = List.map f xs
   ```

2. **MLIR inspection** — for the test cases above, verify:
   - Calls to `f` have `callKind = CallGenericApply` in Mono IR.
   - Generated MLIR shows `eco.papExtend` without `remaining_arity`.
   - `_operand_types` includes a mix of primitives and `!eco.value`.
   - `newargs_unboxed_bitmap` correctly marks primitive args.
   - Result is followed by `eco.unbox` when the Elm result type is primitive.
   - Every call site op carries a `_call_kind` attribute with the correct value:
     - Dynamic callee calls: `_call_kind = "generic_apply"` on `eco.papExtend`.
     - Known saturated calls: `_call_kind = "direct_known_segmentation"` on `eco.call`.
     - Flat extern/kernel calls: `_call_kind = "direct_flat"` on `eco.call`.
     - Multi-stage closure calls: `_call_kind = "direct_known_segmentation"` on first `eco.papExtend`.

3. **Runtime behavior** — `cmake --build build --target check` passes with no new failures.

4. **Invariant compliance**:
   - REP_ABI_001 / REP_CLOSURE_001: Only Int/Float/Char unboxed in closures.
   - XPHASE_002: Every `!eco.value` is a valid heap object (no raw primitives masquerading as pointers).
   - XPHASE_010: CallInfo flows unchanged from GlobalOpt to MLIR.

---

## Summary of files changed

| File | Change |
|------|--------|
| `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` | Add `paramSlotKeys` to `CallEnv`, thread `nodeId`, add `isDynamicCallee`, use in `computeCallInfo` |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Add `_call_kind` debug attrs to all call paths, change `boxArgsForClosureBoundary True` → `False` in `generateGenericApply`, add result coercion in `generateCall` |
| `compiler/src/Compiler/Generate/MLIR/Ops.elm` | Extend `ecoCallNamed` to accept optional extra attributes (for `_call_kind`) |
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | Update `lowerGenericApply` to box primitives based on SSA type (type-aware instead of unconditional) |

**No runtime changes** — `eco_apply_closure` signature and implementation stay as-is.

---

## Assumptions

1. The staging solver produces non-empty `dynamicSlots` for HOF parameter patterns (verified in Step 0).
2. `eco_apply_closure`'s over-saturated chaining correctly handles multi-stage function application with all-boxed args.
3. Only `MonoTailFunc` parameters generate `SlotParam` nodes; `MonoDefine` closures use `SlotCapture`.
4. All `MonoCall` nodes are annotated by GlobalOpt before MLIR codegen (XPHASE_010).
5. `lowerGenericApply` can read primitive types from `_operand_types` attribute or SSA types to dispatch boxing correctly.
