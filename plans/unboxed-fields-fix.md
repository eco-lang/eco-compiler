# Fix: Unboxed Field Types in eco.construct

## Problem

The MLIR verifier reports errors like:
```
'eco.construct' op unboxed_bitmap bit 0 is set but field has boxed type '!eco.value'
```

The `unboxed_bitmap` attribute indicates which fields are unboxed (bit N set = field N is unboxed), but all field operands are generated with type `!eco.value` (boxed), causing a type/bitmap mismatch.

## Root Cause

Three functions in `MLIR.elm` always emit `ecoValue` for all fields, ignoring the layout's unboxing information:

1. **generateRecordCreate** (line 1643-1646):
   ```elm
   -- All record fields are boxed values  <-- WRONG
   fieldVarPairs =
       List.map (\v -> ( v, ecoValue )) fieldVars
   ```

2. **generateTupleCreate** (line 1700-1703):
   ```elm
   -- All tuple elements are boxed values  <-- WRONG
   elemVarPairs =
       List.map (\v -> ( v, ecoValue )) elemVars
   ```

3. **generateCustomCreate** (line 1744-1747):
   ```elm
   -- All fields are boxed values  <-- WRONG
   fieldVarPairs =
       List.map (\v -> ( v, ecoValue )) fieldVars
   ```

## Available Type Information

The layouts contain complete type information:

- **RecordLayout.fields**: `List FieldInfo` where `FieldInfo` has:
  - `monoType : MonoType` - the field's type
  - `isUnboxed : Bool` - whether it's unboxed

- **TupleLayout.elements**: `List (MonoType, Bool)` - (type, isUnboxed)

- **CtorLayout.fields**: `List FieldInfo` - same as RecordLayout

The correct pattern already exists in `generateCtor` (line 703-713):
```elm
argTypes =
    List.map
        (\field ->
            if field.isUnboxed then
                monoTypeToMlir field.monoType
            else
                ecoValue
        )
        ctorLayout.fields
```

## Fix

### 1. generateRecordCreate

Change from:
```elm
fieldVarPairs : List ( String, MlirType )
fieldVarPairs =
    List.map (\v -> ( v, ecoValue )) fieldVars
```

To:
```elm
fieldVarPairs : List ( String, MlirType )
fieldVarPairs =
    List.map2
        (\v field ->
            ( v
            , if field.isUnboxed then
                monoTypeToMlir field.monoType
              else
                ecoValue
            )
        )
        fieldVars
        layout.fields
```

### 2. generateTupleCreate

Change from:
```elm
elemVarPairs : List ( String, MlirType )
elemVarPairs =
    List.map (\v -> ( v, ecoValue )) elemVars
```

To:
```elm
elemVarPairs : List ( String, MlirType )
elemVarPairs =
    List.map2
        (\v ( elemType, isUnboxed ) ->
            ( v
            , if isUnboxed then
                monoTypeToMlir elemType
              else
                ecoValue
            )
        )
        elemVars
        layout.elements
```

### 3. generateCustomCreate

Change from:
```elm
fieldVarPairs : List ( String, MlirType )
fieldVarPairs =
    List.map (\v -> ( v, ecoValue )) fieldVars
```

To:
```elm
fieldVarPairs : List ( String, MlirType )
fieldVarPairs =
    List.map2
        (\v field ->
            ( v
            , if field.isUnboxed then
                monoTypeToMlir field.monoType
              else
                ecoValue
            )
        )
        fieldVars
        layout.fields
```

## Testing

After the fix:
1. Rebuild the compiler: `npm run build:bin`
2. Compile Buttons.elm: `../../elm2llvm src/Buttons.elm`
3. Verify the generated MLIR has correct types matching the unboxed_bitmap

For example, if `unboxed_bitmap = 1` (field 0 unboxed), field 0's operand should have type `i64` (or appropriate unboxed type), not `!eco.value`.

## Notes

- The `monoTypeToMlir` function already handles the conversion: `MInt -> i64`, `MFloat -> f64`, `MChar -> i32`, `MBool -> i1`
- The layout's `isUnboxed` flag is computed by `canUnbox` which returns true for `MInt`, `MFloat`, `MChar`, `MBool`
