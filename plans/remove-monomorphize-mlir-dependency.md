# Remove Monomorphize Dependency on MLIR.Types

## Problem

The Monomorphize phase (an earlier compiler phase) imports from `Compiler.Generate.MLIR.Types` (a later codegen phase). This violates the principle that earlier phases should not depend on later ones.

### Current Violations

**GlobalOpt → MLIR.Types (7 exports):**
- `Segmentation`, `buildSegmentedFunctionType`, `chooseCanonicalSegmentation`
- `segmentLengths`, `stageArity`, `stageParamTypes`, `stageReturnType`

**Monomorphize → MLIR.Types (9 exports):**
- `FieldInfo`, `RecordLayout`, `TupleLayout`
- `computeRecordLayout`, `computeTupleLayout`, `decomposeFunctionType`
- `segmentLengths`, `stageParamTypes`, `stageReturnType`

**Files with violations:**
- `Compiler/GlobalOpt/MonoGlobalOptimize.elm`
- `Compiler/GlobalOpt/MonoReturnArity.elm`
- `Compiler/Monomorphize/Closure.elm`
- `Compiler/Monomorphize/Specialize.elm`
- `Compiler/Monomorphize/Monomorphize.elm` (import present but unused)
- `Compiler/Monomorphize/KernelAbi.elm` (import present but unused)
- `Compiler/Monomorphize/TypeSubst.elm` (import present but unused)

---

## Design Decisions

1. **Merge `Compiler.AST.LayoutShapes` into `Compiler.AST.Monomorphized`** - Remove LayoutShapes as a separate module
2. **`canUnbox` stays in MLIR backend** - It's backend-specific policy
3. **Test files** - Review during implementation, adjust if necessary
4. **`chooseCanonicalSegmentation`** - Move to Monomorphized (used for ABI wrapper building)
5. **Layouts module stays in MLIR backend** - `Compiler.Generate.MLIR.Layouts`. Monomorphization will NOT import it.
6. **Naming convention** - "Shapes" = abstract semantic structure, "Layouts" = heap-specific with indices/unboxing
7. **Defer layout computation to codegen** - Change `MonoRecordAccess` to not store pre-computed index/isUnboxed

---

## Solution Architecture

### Key Insight

Monomorphization currently embeds heap layout decisions in Mono IR via `MonoRecordAccess Int Bool`. This creates a false dependency on layout computation.

**Solution:** Defer layout computation to codegen. The Mono IR stores only semantic information (field name), and codegen computes the heap-specific index/isUnboxed.

### Target State

1. **No Monomorphize or GlobalOpt module imports `Compiler.Generate.MLIR.*`**
2. Function shape/segmentation helpers live in `Compiler.AST.Monomorphized`
3. Layout types and computation stay in `Compiler.Generate.MLIR.Layouts` (new module)
4. `MonoRecordAccess` stores field name only, codegen computes index/isUnboxed
5. `MLIR.Types` delegates layout computation to `MLIR.Layouts`

---

## Implementation Plan

### Phase 1: Merge LayoutShapes into Monomorphized

**Delete:** `compiler/src/Compiler/AST/LayoutShapes.elm`

**Edit:** `compiler/src/Compiler/AST/Monomorphized.elm`

Add the shape types (already has `CtorShape`):
```elm
-- Already exists:
type alias CtorShape = { name : Name, tag : Int, fieldTypes : List MonoType }

-- Add these (currently in LayoutShapes):
type alias MRecordShape = { fields : Dict String Name MonoType }
type alias MTupleShape = { elements : List MonoType }

-- Add comparable conversions:
toComparableRecordShape : MRecordShape -> List ( String, List String )
toComparableTupleShape : MTupleShape -> List (List String)
toComparableCtorShape : CtorShape -> ( String, Int, List (List String) )
```

**Update:** Any imports of `Compiler.AST.LayoutShapes` → `Compiler.AST.Monomorphized`

### Phase 2: Add Function Shape Helpers to Monomorphized

**Edit:** `compiler/src/Compiler/AST/Monomorphized.elm`

Add function shape helpers (move from MLIR.Types):
```elm
-- Function type predicates
isFunctionType : MonoType -> Bool
functionArity : MonoType -> Int
countTotalArity : MonoType -> Int

-- Function type decomposition
decomposeFunctionType : MonoType -> ( List MonoType, MonoType )

-- Stage-level accessors (for curried functions)
stageArity : MonoType -> Int
stageParamTypes : MonoType -> List MonoType
stageReturnType : MonoType -> MonoType

-- Segmentation types and helpers
type alias Segmentation = { segments : List Int }
segmentLengths : MonoType -> List Int
buildSegmentedFunctionType : Segmentation -> List MonoType -> MonoType -> MonoType
chooseCanonicalSegmentation : MonoType -> Segmentation
```

### Phase 3: Change MonoRecordAccess to Defer Layout

**Edit:** `compiler/src/Compiler/AST/Monomorphized.elm`

Change:
```elm
-- BEFORE:
| MonoRecordAccess MonoExpr Name Int Bool MonoType -- Index/isUnboxed precomputed

-- AFTER:
| MonoRecordAccess MonoExpr Name MonoType -- Index/isUnboxed computed at codegen
```

This removes the `Int` (index) and `Bool` (isUnboxed) parameters.

**Update pattern matches** in Monomorphized.elm:
```elm
-- BEFORE:
MonoRecordAccess _ _ _ _ t -> t

-- AFTER:
MonoRecordAccess _ _ t -> t
```

### Phase 4: Update Specialize.elm (Remove Layout Dependency)

**Edit:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

1. **Remove import:**
```elm
-- DELETE:
import Compiler.Generate.MLIR.Types as Types
```

2. **Remove layout-dependent functions:**
   - Delete `getRecordLayout`
   - Delete `getTupleLayout`
   - Delete `findFieldInLayout`
   - Delete `lookupFieldIndex` (or simplify to just return field type)

3. **Simplify MonoRecordAccess construction:**

```elm
-- BEFORE (around line 1241-1243):
( fieldIndex, isUnboxed ) =
    lookupFieldIndex fieldName recordType
( Mono.MonoRecordAccess monoRecord fieldName fieldIndex isUnboxed monoType, stateAfter )

-- AFTER:
( Mono.MonoRecordAccess monoRecord fieldName monoType, stateAfter )
```

4. **Simplify specializeRecordFields:**

The function currently iterates over `layout.fields` to get fields in layout order. Change to iterate over source-order fields:

```elm
-- BEFORE:
specializeRecordFields : Dict String Name TOpt.Expr -> Types.RecordLayout -> Substitution -> MonoState -> ( List Mono.MonoExpr, MonoState )
specializeRecordFields fields layout subst state =
    List.foldr
        (\fieldInfo ( acc, st ) ->
            case Dict.get identity fieldInfo.name fields of
                ...
        )
        ( [], state )
        layout.fields

-- AFTER:
specializeRecordFields : Dict String Name TOpt.Expr -> Substitution -> MonoState -> ( List ( Name, Mono.MonoExpr ), MonoState )
specializeRecordFields fields subst state =
    Dict.foldl compare
        (\name expr ( acc, st ) ->
            let
                ( monoExpr, newSt ) = specializeExpr expr subst st
            in
            ( ( name, monoExpr ) :: acc, newSt )
        )
        ( [], state )
        fields
```

Note: The return type changes to include field names. `MonoRecordCreate` will need adjustment too.

### Phase 5: Update MonoRecordCreate (Optional Enhancement)

Currently `MonoRecordCreate` stores fields in layout order. With deferred layout, we have two options:

**Option 5A: Keep layout order computation in Specialize**
- Just for field ordering, not for index/isUnboxed
- Would still need some layout-adjacent logic

**Option 5B: Store fields with names, let codegen reorder**
```elm
-- BEFORE:
| MonoRecordCreate (List MonoExpr) MonoType

-- AFTER:
| MonoRecordCreate (List ( Name, MonoExpr )) MonoType
```

Codegen would then sort by layout order when emitting.

**Recommendation:** Option 5B for consistency with the "defer to codegen" approach.

### Phase 6: Create MLIR.Layouts Module

**New file:** `compiler/src/Compiler/Generate/MLIR/Layouts.elm`

Move layout types and computation from MLIR.Types:
```elm
module Compiler.Generate.MLIR.Layouts exposing
    ( RecordLayout, FieldInfo, TupleLayout, CtorLayout
    , computeRecordLayout, computeTupleLayout, computeCtorLayout
    , canUnbox, lookupFieldInLayout
    )

{-| Heap-specific layout computation for MLIR codegen.

These types contain backend-specific decisions:
  - Field indices (ordering based on unboxing)
  - Unboxed bitmaps
  - Unboxed counts

Computed from MonoType shapes during code generation.
-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Data.Map as Dict exposing (Dict)

type alias RecordLayout = { ... }
type alias FieldInfo = { name : Name, index : Int, monoType : Mono.MonoType, isUnboxed : Bool }
type alias TupleLayout = { ... }
type alias CtorLayout = { ... }

canUnbox : Mono.MonoType -> Bool
computeRecordLayout : Dict String Name Mono.MonoType -> RecordLayout
computeTupleLayout : List Mono.MonoType -> TupleLayout
computeCtorLayout : Mono.CtorShape -> CtorLayout

-- NEW: Helper for codegen to look up field info by name
lookupFieldInLayout : Name -> RecordLayout -> Maybe FieldInfo
```

### Phase 7: Update MLIR Codegen

**Edit:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Update `MonoRecordAccess` handling:
```elm
-- BEFORE:
Mono.MonoRecordAccess record fieldName index isUnboxed fieldType ->
    generateRecordAccess ctx record fieldName index isUnboxed fieldType

-- AFTER:
Mono.MonoRecordAccess record fieldName fieldType ->
    let
        recordType = Mono.typeOf record
        layout = Types.computeRecordLayout (getRecordFields recordType)
        fieldInfo =
            Layouts.lookupFieldInLayout fieldName layout
                |> Maybe.withDefault { name = fieldName, index = 0, monoType = fieldType, isUnboxed = False }
    in
    generateRecordAccess ctx record fieldName fieldInfo.index fieldInfo.isUnboxed fieldType
```

If using Option 5B for `MonoRecordCreate`:
```elm
-- BEFORE:
Mono.MonoRecordCreate fields monoType ->
    let
        layout = Types.computeRecordLayout (getRecordFields monoType)
    in
    generateRecordCreate ctx fields layout monoType

-- AFTER:
Mono.MonoRecordCreate namedFields monoType ->
    let
        layout = Types.computeRecordLayout (getRecordFields monoType)
        -- Reorder fields according to layout
        orderedFields =
            List.map (\fi ->
                List.find (\(n, _) -> n == fi.name) namedFields
                    |> Maybe.map Tuple.second
                    |> Maybe.withDefault Mono.MonoUnit
            ) layout.fields
    in
    generateRecordCreate ctx orderedFields layout monoType
```

### Phase 8: Simplify MLIR.Types

**Edit:** `compiler/src/Compiler/Generate/MLIR/Types.elm`

1. Import new modules:
```elm
import Compiler.Generate.MLIR.Layouts as Layouts
import Compiler.AST.Monomorphized as Mono
```

2. Remove layout definitions (moved to MLIR.Layouts)

3. Re-export from Layouts for API compatibility:
```elm
type alias RecordLayout = Layouts.RecordLayout
type alias FieldInfo = Layouts.FieldInfo
-- ... etc
computeRecordLayout = Layouts.computeRecordLayout
-- ... etc
```

4. Remove function shape helpers (moved to Monomorphized)

5. Re-export from Monomorphized for API compatibility:
```elm
type alias Segmentation = Mono.Segmentation
isFunctionType = Mono.isFunctionType
-- ... etc
```

6. Keep MLIR-specific functions:
- `ecoValue`, `ecoInt`, `ecoFloat`, `ecoChar`
- `monoTypeToAbi`, `monoTypeToOperand`
- `mlirTypeToString`, `isEcoValueType`, `isUnboxable`

### Phase 9: Update Closure.elm

**Edit:** `compiler/src/Compiler/Monomorphize/Closure.elm`

Replace:
```elm
import Compiler.Generate.MLIR.Types as Types
```

With:
```elm
import Compiler.AST.Monomorphized as Mono
```

Change all `Types.*` → `Mono.*`:
- `Types.stageParamTypes` → `Mono.stageParamTypes`
- `Types.stageReturnType` → `Mono.stageReturnType`
- `Types.segmentLengths` → `Mono.segmentLengths`

### Phase 10: Update GlobalOpt Modules

**Edit:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`
**Edit:** `compiler/src/Compiler/GlobalOpt/MonoReturnArity.elm`

Replace:
```elm
import Compiler.Generate.MLIR.Types as Types
```

With:
```elm
import Compiler.AST.Monomorphized as Mono
```

Change `Types.*` → `Mono.*` for function shape helpers.

### Phase 11: Remove Unused Imports

**Edit:** `Monomorphize.elm`, `KernelAbi.elm`, `TypeSubst.elm`
- Remove unused `import Compiler.Generate.MLIR.Types as Types`

### Phase 12: Update Configuration

**Edit:** `compiler/elm-application.json`
- Remove: `"Compiler.AST.LayoutShapes"`
- Add: `"Compiler.Generate.MLIR.Layouts"`

### Phase 13: Update GlobalOpt Pattern Matches

Any GlobalOpt code that pattern matches on `MonoRecordAccess` needs updating:
```elm
-- BEFORE:
MonoRecordAccess record name index isUnboxed fieldType -> ...

-- AFTER:
MonoRecordAccess record name fieldType -> ...
```

Search for all pattern matches:
```bash
grep -rn "MonoRecordAccess" compiler/src/Compiler/GlobalOpt/
```

---

## File Change Summary

### Deleted Files
1. `compiler/src/Compiler/AST/LayoutShapes.elm`

### New Files
2. `compiler/src/Compiler/Generate/MLIR/Layouts.elm`

### Edited Files - Mono IR Changes
3. `compiler/src/Compiler/AST/Monomorphized.elm`
   - Add shapes from LayoutShapes
   - Add function shape helpers from MLIR.Types
   - Change `MonoRecordAccess` signature (remove Int, Bool)
   - Optionally change `MonoRecordCreate` to store named fields

### Edited Files - Monomorphize Phase
4. `compiler/src/Compiler/Monomorphize/Specialize.elm`
   - Remove MLIR.Types import
   - Remove layout-dependent functions
   - Simplify MonoRecordAccess construction
   - Simplify specializeRecordFields
5. `compiler/src/Compiler/Monomorphize/Closure.elm` - Use Mono.* for function shapes
6. `compiler/src/Compiler/Monomorphize/Monomorphize.elm` - Remove unused import
7. `compiler/src/Compiler/Monomorphize/KernelAbi.elm` - Remove unused import
8. `compiler/src/Compiler/Monomorphize/TypeSubst.elm` - Remove unused import

### Edited Files - GlobalOpt Phase
9. `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`
   - Use Mono.* for function shapes
   - Update MonoRecordAccess pattern matches
10. `compiler/src/Compiler/GlobalOpt/MonoReturnArity.elm` - Use Mono.*

### Edited Files - MLIR Backend
11. `compiler/src/Compiler/Generate/MLIR/Types.elm` - Delegate to Layouts and Mono
12. `compiler/src/Compiler/Generate/MLIR/Expr.elm` - Compute layout for MonoRecordAccess at emission

### Configuration
13. `compiler/elm-application.json` - Update exposed modules

---

## Verification

1. All tests pass (`npx elm-test-rs --fuzz 1`)
2. CMake build succeeds (`cmake --build build --target guida`)
3. E2E tests pass (`cmake --build build --target check`)
4. No imports of `Compiler.Generate.MLIR.*` in:
   - `compiler/src/Compiler/Monomorphize/*.elm`
   - `compiler/src/Compiler/GlobalOpt/*.elm`

```bash
grep -r "import Compiler.Generate.MLIR" compiler/src/Compiler/Monomorphize/ compiler/src/Compiler/GlobalOpt/
# Should return no results
```

---

## Risk Mitigation

### Risk: MonoRecordCreate Field Ordering
If `MonoRecordCreate` currently relies on fields being in layout order, changing to named fields requires careful codegen updates.

**Mitigation:** Can be done incrementally - first change `MonoRecordAccess`, verify tests pass, then tackle `MonoRecordCreate` if needed.

### Risk: Performance
Computing layout at codegen for every `MonoRecordAccess` might be slower than pre-computing.

**Mitigation:**
- Layout computation is O(n) where n is field count (small)
- Can cache layouts by MonoType if needed
- Cleaner architecture is worth minor perf cost

### Risk: Pattern Match Updates
Many files may pattern match on `MonoRecordAccess`.

**Mitigation:** Compiler will catch all mismatches. Search and update systematically:
```bash
grep -rn "MonoRecordAccess" compiler/src/
```
