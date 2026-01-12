# Type Table Construction

## Overview

The Type Table is a runtime data structure that maps TypeIds to type descriptors, enabling typed debug printing of Elm values. During MLIR generation, types are registered in a TypeRegistry, and the complete type graph is emitted as an `eco.type_table` operation.

**Phase**: MLIR Code Generation (integrated)

**Pipeline Position**: Built incrementally during MLIR generation, emitted at module end

## Purpose

Unlike JavaScript where `Debug.log` can inspect any value's structure dynamically, native code needs type information to print values correctly. The Type Table provides:

1. **Debug printing**: `eco.dbg` operations reference TypeIds to know how to format values
2. **Type introspection**: Runtime can traverse type graph for complex types
3. **Field names**: Records and constructors include field/constructor names for pretty-printing

## Architecture

### TypeRegistry (Compile-time)

Built during MLIR code generation:

```elm
type alias TypeRegistry =
    { nextTypeId : Int
    , typeIds : Dict (List String) Int      -- MonoType key -> TypeId
    , typeInfos : List (Int, Mono.MonoType) -- Registered types for emission
    , ctorLayouts : Dict (List String) (List Mono.CtorLayout)  -- Custom type constructors
    }
```

### Type Table (Runtime)

Emitted as MLIR op with four arrays:

```
eco.type_table
    types    = [...]    -- Type descriptors
    fields   = [...]    -- Field information (for records, tuples, ctors)
    ctors    = [...]    -- Constructor information (for custom types)
    func_args = [...]   -- Function argument type IDs
    strings  = [...]    -- String table for names
```

## Type Registration

### Lazy Registration

Types are registered on-demand when encountered during code generation:

```
FUNCTION getOrCreateTypeIdForMonoType(monoType, ctx):
    key = toComparableMonoType(monoType)

    IF key IN ctx.typeRegistry.typeIds:
        RETURN (existing_typeId, ctx)

    -- First register nested types (depth-first)
    ctx = registerNestedTypes(monoType, ctx)

    -- Then register this type
    typeId = ctx.typeRegistry.nextTypeId
    ctx.typeRegistry.nextTypeId += 1
    ctx.typeRegistry.typeIds[key] = typeId
    ctx.typeRegistry.typeInfos.push((typeId, monoType))

    RETURN (typeId, ctx)
```

### Nested Type Registration

Ensures child types are registered before parents:

```
FUNCTION registerNestedTypes(monoType, ctx):
    CASE monoType OF
        MList elemType:
            ctx = getOrCreateTypeIdForMonoType(elemType, ctx)

        MTuple layout:
            FOR elemType IN layout.elements:
                ctx = getOrCreateTypeIdForMonoType(elemType, ctx)

        MRecord layout:
            FOR field IN layout.fields:
                ctx = getOrCreateTypeIdForMonoType(field.monoType, ctx)

        MCustom _ _ _:
            FOR ctor IN ctorLayouts:
                FOR field IN ctor.fields:
                    ctx = getOrCreateTypeIdForMonoType(field.monoType, ctx)

        MFunction argTypes resultType:
            FOR argType IN argTypes:
                ctx = getOrCreateTypeIdForMonoType(argType, ctx)
            ctx = getOrCreateTypeIdForMonoType(resultType, ctx)

        -- Primitives have no nested types
        MInt | MFloat | MBool | MChar | MString | MUnit:
            -- No nested types

    RETURN ctx
```

## Type Kind Enumeration

Types are classified by kind (matches C++ `EcoTypeKind` enum):

| Kind | Value | Description |
|------|-------|-------------|
| TKPrimitive | 0 | Int, Float, Char, Bool, String, Unit |
| TKList | 1 | List of element type |
| TKTuple | 2 | 2-tuple or 3-tuple |
| TKRecord | 3 | Record with named fields |
| TKCustom | 4 | Custom type (union/ADT) |
| TKFunction | 5 | Function type |
| TKPolymorphic | 6 | Type variable with constraint |

### Primitive Kinds

Sub-classification for primitives:

| PrimKind | Value | MonoType |
|----------|-------|----------|
| PKInt | 0 | MInt |
| PKFloat | 1 | MFloat |
| PKChar | 2 | MChar |
| PKBool | 3 | MBool |
| PKString | 4 | MString |
| PKUnit | 5 | MUnit |

## Type Descriptor Format

### Primitive Types

```
[typeId, TKPrimitive, primKind]
```

Example: `[0, 0, 0]` = TypeId 0, Primitive, Int

### List Types

```
[typeId, TKList, elemTypeId]
```

Example: `[5, 1, 0]` = TypeId 5, List, element is TypeId 0 (Int)

### Tuple Types

```
[typeId, TKTuple, arity, firstFieldIndex, fieldCount]
```

Fields array entries: `[0, elemTypeId]` (name_index 0, not used for tuples)

Example for `(Int, String)`:
- Types: `[6, 2, 2, 0, 2]` = TypeId 6, Tuple, arity 2, fields start at 0, 2 fields
- Fields: `[[0, 0], [0, 4]]` = (unused, Int), (unused, String)

### Record Types

```
[typeId, TKRecord, firstFieldIndex, fieldCount]
```

Fields array entries: `[nameIndex, fieldTypeId]`

Example for `{ name : String, age : Int }`:
- Types: `[7, 3, 2, 2]` = TypeId 7, Record, fields start at 2, 2 fields
- Fields: `[[0, 4], [1, 0]]` = ("name", String), ("age", Int)
- Strings: `["name", "age"]`

### Custom Types

```
[typeId, TKCustom, firstCtorIndex, ctorCount]
```

Ctors array entries: `[ctorTag, nameIndex, firstFieldIndex, fieldCount]`

Example for `type Maybe a = Nothing | Just a` at `a = Int`:
- Types: `[8, 4, 0, 2]` = TypeId 8, Custom, ctors start at 0, 2 constructors
- Ctors: `[[0, 0, 0, 0], [1, 1, 0, 1]]` = Nothing (tag 0, no fields), Just (tag 1, 1 field)
- Fields: `[[2, 0]]` = (unused, Int) for Just's field
- Strings: `["Nothing", "Just", ...]`

### Function Types

```
[typeId, TKFunction, firstArgIndex, argCount, resultTypeId]
```

func_args array entries: `[argTypeId]`

Example for `Int -> String -> Bool`:
- Types: `[9, 5, 0, 2, 3]` = TypeId 9, Function, args start at 0, 2 args, result is Bool
- func_args: `[0, 4]` = [Int, String]

### Polymorphic Types

```
[typeId, TKPolymorphic, constraintValue]
```

Constraint values:
- 0 = CNumber (must be Int or Float)
- 1 = CEcoValue (any boxed value)

These appear when kernel functions use type variables.

## Type Table Generation

The `generateTypeTable` function builds the final op:

```
FUNCTION generateTypeTable(ctx):
    sortedTypes = sortBy(typeId, ctx.typeRegistry.typeInfos)

    accum = {
        strings = {},
        fields = [],
        ctors = [],
        funcArgs = [],
        typeAttrs = [],
        typeIds = ctx.typeRegistry.typeIds,
        ctorLayouts = ctx.typeRegistry.ctorLayouts
    }

    FOR (typeId, monoType) IN sortedTypes:
        accum = processType(typeId, monoType, accum)

    RETURN eco.type_table {
        types = reverse(accum.typeAttrs),
        fields = reverse(accum.fields),
        ctors = reverse(accum.ctors),
        func_args = reverse(accum.funcArgs),
        strings = sortedByIndex(accum.strings)
    }
```

## String Table

Names (field names, constructor names) are deduplicated in a string table:

```
FUNCTION getOrCreateStringIndex(str, accum):
    IF str IN accum.strings:
        RETURN (accum.strings[str], accum)

    index = accum.nextStringIndex
    accum.strings[str] = index
    accum.nextStringIndex += 1
    RETURN (index, accum)
```

## Integration with Debug Printing

### eco.dbg Operation

When generating `Debug.log` calls:

```elm
generateDbg : List (MonoExpr, MonoType) -> Context -> (MlirOp, Context)
generateDbg args ctx =
    -- Register types and get type IDs
    (typeIds, ctx') = foldl registerArgType ([], ctx) args

    -- Generate eco.dbg with arg_type_ids attribute
    op = { name = "eco.dbg"
         , attrs = { arg_type_ids = typeIds }
         , ... }
```

### Runtime Printing

At runtime, `eco_dbg_print_value(value, typeId)`:

1. Looks up TypeId in type table
2. Dispatches based on type kind
3. For compound types, recursively prints fields/elements
4. Uses string table for names

## Implementation Details

### File Location

`compiler/src/Compiler/Generate/CodeGen/MLIR.elm` (integrated into code generation)

### Key Functions

| Function | Purpose |
|----------|---------|
| `getOrCreateTypeIdForMonoType` | Register a type, return TypeId |
| `registerNestedTypes` | Ensure child types are registered first |
| `generateTypeTable` | Build the eco.type_table op |
| `processType` | Convert MonoType to type descriptor |
| `addPrimitiveType` | Add primitive descriptor |
| `addListType` | Add list descriptor |
| `addTupleType` | Add tuple descriptor + fields |
| `addRecordType` | Add record descriptor + named fields |
| `addCustomType` | Add custom type descriptor + ctors |
| `addFunctionType` | Add function descriptor + arg types |
| `getOrCreateStringIndex` | String table management |

## Pre-conditions

1. MonoGraph is complete with all specializations
2. Constructor layouts are available for custom types
3. GlobalTypeEnv has union definitions

## Post-conditions

1. Every MonoType used in code has a TypeId
2. Type table includes all registered types
3. String table includes all field/constructor names
4. eco.type_table op is valid MLIR

## Example

Elm code:
```elm
type User = User { name : String, age : Int }

Debug.log "user" (User { name = "Alice", age = 30 })
```

Generated type table:
```
eco.type_table
    types = [
        [0, 0, 0],     -- TypeId 0: Int (primitive)
        [1, 0, 4],     -- TypeId 1: String (primitive)
        [2, 3, 0, 2],  -- TypeId 2: Record { name, age }
        [3, 4, 0, 1]   -- TypeId 3: User (custom)
    ]
    fields = [
        [0, 1],        -- Field 0: name -> String
        [1, 0],        -- Field 1: age -> Int
        [2, 2]         -- Field 2: User ctor field -> record
    ]
    ctors = [
        [0, 2, 2, 1]   -- Ctor 0: User, name at 2, fields start at 2, 1 field
    ]
    func_args = []
    strings = ["name", "age", "User"]
```

## Relationship to Other Passes

- **Requires**: Monomorphization (MonoGraph with all types)
- **Integrated into**: MLIR Generation
- **Enables**: Runtime debug printing with type information
- **Output**: eco.type_table op in generated module
