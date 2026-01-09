# Global Type Graph Implementation Plan

This plan implements the design in `design_docs/global-type-graph.md` to add a global type graph for debug printing of Elm values with full type information.

## Overview

The implementation consists of three major components:
1. **Runtime structures** (C++): Type descriptors and typed debug printing
2. **MLIR dialect extensions** (C++): `eco.type_table` op and extended `eco.dbg`
3. **Compiler backend** (Elm): TypeRegistry and type graph emission

## Key Design Decisions

1. **MonoType as Dict key**: Use the codebase's 3-parameter Dict pattern with a comparable encoding (`toComparableMonoType : MonoType -> List String`), following the `SpecKey` pattern in `Monomorphized.elm`.

2. **type_id on eco.construct**: Not required for typed debug printing. The debug printer walks from a root `type_id` through the static type graph using heap layout (tags/bitmaps) - it doesn't read type_id from object headers. Can add for future-proofing but not blocking.

3. **Constructor info source**: All available in `CtorLayout` from monomorphized IR:
   - `CtorLayout.name` - constructor name
   - `CtorLayout.tag` - constructor tag
   - `CtorLayout.fields` - list of `FieldInfo` with `name`, `monoType`, `isUnboxed`

4. **Debug.log connection**: Currently goes through Kernel ABI, not `eco.dbg`. This feature targets `eco.dbg` for MLIR/codegen tests. `Debug.log` integration is a separate follow-up.

---

## Phase 1: Runtime + Op Scaffolding

This phase establishes the foundational structures and verifies dialect changes, linkage, and basic lowering work.

### 1.1 Create TypeInfo.hpp

**File**: `runtime/src/allocator/TypeInfo.hpp`

Add shared type descriptor structures used by both runtime and codegen:

```cpp
enum class EcoTypeKind : uint8_t {
    Primitive, List, Tuple, Record, Custom, Function
};

enum class EcoPrimKind : uint8_t {
    Int, Float, Char, Bool, String
};

struct EcoFieldInfo {
    uint32_t name_index;  // index into string table
    uint32_t type_id;     // TypeId of field type
};

struct EcoCtorInfo {
    uint32_t ctor_id;      // per-type constructor index (0..n-1)
    uint32_t name_index;   // constructor name in string table
    uint32_t first_field;  // index into global field-type array
    uint32_t field_count;
};

struct EcoTypeInfo {
    uint32_t type_id;
    EcoTypeKind kind;
    union { ... } data;  // as specified in design doc §1.2
};

struct EcoTypeGraph {
    const EcoTypeInfo* types;
    uint32_t type_count;
    const EcoFieldInfo* fields;
    uint32_t field_count;
    const EcoCtorInfo* ctors;
    uint32_t ctor_count;
    const uint32_t* function_arg_type_ids;
    uint32_t function_arg_type_count;
    const char* const* strings;
    uint32_t string_count;
};
```

**Testing**: Compile-time `static_assert` for struct sizes

### 1.2 Add stub eco_dbg_print_typed

**Files**:
- `runtime/src/allocator/RuntimeExports.h`: Add declaration
- `runtime/src/allocator/RuntimeExports.cpp`: Add stub implementation

```cpp
extern "C" void eco_dbg_print_typed(
    uint64_t* values,
    uint32_t* type_ids,
    uint32_t num_args);
```

Initial stub just prints `<typed:N>` for each argument (no actual type graph lookup yet).

### 1.3 Add __eco_type_graph extern declaration

**File**: `runtime/src/allocator/RuntimeExports.cpp`

```cpp
extern "C" {
    extern const EcoTypeGraph __eco_type_graph;
}
```

Symbol will be defined by lowering of `eco.type_table`.

### 1.4 Add Eco_TypeTableOp to Ops.td

**File**: `runtime/src/codegen/Ops.td`

```tablegen
def Eco_TypeTableOp : Eco_Op<"type_table", [HasParent<"mlir::ModuleOp">]> {
    let summary = "Global type information graph for debug/reflection";
    let arguments = (ins);
    let results = (outs);
    // Attributes: types, fields, ctors, func_args, strings (ArrayAttr)
}
```

### 1.5 Add trivial TypeTableOp lowering

**File**: `runtime/src/codegen/Passes/EcoToLLVMGlobals.cpp` (or add to existing file)

Emit an empty `__eco_type_graph` global (all counts = 0, all pointers = null).

### 1.6 Extend Eco_DbgOp with arg_type_ids

**File**: `runtime/src/codegen/Ops.td`

```tablegen
def Eco_DbgOp : Eco_Op<"dbg"> {
    let arguments = (ins
        Variadic<Eco_AnyValue>:$args,
        OptionalAttr<DenseI64ArrayAttr>:$arg_type_ids
    );
    let results = (outs);
}
```

**Verification at end of Phase 1**:
- Build succeeds
- `eco.type_table` parses and prints
- `eco.dbg` with `arg_type_ids` parses and prints
- Runtime links with `__eco_type_graph` symbol

---

## Phase 2: TypeRegistry + eco.type_table Emission

This phase implements the Elm-side type registry and emits a real type graph (but printing still uses stubs).

### 2.1 Add TypeRegistry to Context

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

```elm
type alias TypeRegistry =
    { nextTypeId : Int
    , typeIds : Dict (List String) Mono.MonoType Int
    }

type alias Context =
    { ...existing fields...
    , typeRegistry : TypeRegistry
    }
```

### 2.2 Add toComparableMonoType

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm` (or Monomorphized.elm)

```elm
toComparableMonoType : Mono.MonoType -> List String
```

Follows the `toComparableSpecKey` pattern for deterministic, comparable encoding.

### 2.3 Add getOrCreateTypeIdForMonoType

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

```elm
getOrCreateTypeIdForMonoType : Mono.MonoType -> Context -> ( Int, Context )
getOrCreateTypeIdForMonoType monoType ctx =
    let
        key = toComparableMonoType monoType
    in
    case Dict.get identity key ctx.typeRegistry.typeIds of
        Just tid -> ( tid, ctx )
        Nothing ->
            let
                tid = ctx.typeRegistry.nextTypeId
                newTR = { nextTypeId = tid + 1
                        , typeIds = Dict.insert identity key monoType tid ctx.typeRegistry.typeIds
                        }
            in
            ( tid, { ctx | typeRegistry = newTR } )
```

### 2.4 Register types during code generation

Call `getOrCreateTypeIdForMonoType` from:
- `generateCtor` / `generateEnum` - for custom types
- `generateRecordCreate` - for records
- `generateTupleCreate` - for tuples
- `generateList` - for lists
- Literal generation - for primitives

This populates the registry without changing emitted MLIR (yet).

### 2.5 Add generateTypeTable

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

```elm
generateTypeTable : Context -> MlirOp
```

Traverses `ctx.typeRegistry.typeIds` sorted by type_id and builds:
- `types` array: For each MonoType, create descriptor with kind and sub-fields
- `fields` array: Flatten all record/tuple fields
- `ctors` array: For MCustom types, use `CtorLayout` info
- `func_args` array: Flatten function argument type_ids
- `strings` array: Deduplicated string table

### 2.6 Emit eco.type_table at module end

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

Modify `generateModule` to append `generateTypeTable ctx` to module ops.

### 2.7 Implement real TypeTableOp lowering

**File**: `runtime/src/codegen/Passes/EcoToLLVMGlobals.cpp`

Replace trivial lowering with full implementation:
1. Parse attributes from `eco.type_table`
2. Emit LLVM global arrays (`__eco_types`, `__eco_fields`, `__eco_ctors`, `__eco_func_args`, `__eco_strings`)
3. Emit individual string globals
4. Emit `__eco_type_graph` struct pointing to arrays

**Verification at end of Phase 2**:
- MLIR output contains `eco.type_table` with populated attributes
- LLVM IR contains `__eco_type_graph` with correct structure
- Can inspect type graph data in debugger

---

## Phase 3: Wire eco.dbg to eco_dbg_print_typed (Primitives Only)

This phase connects the pieces for primitive type printing.

### 3.1 Extend DbgOpLowering for arg_type_ids

**File**: `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp`

Modify `DbgOpLowering::matchAndRewrite`:

```cpp
if (op.getArgTypeIds()) {
    // Allocate stack arrays for values and type_ids
    // Convert each arg to i64
    // Store type_ids from attribute
    // Call eco_dbg_print_typed(values, type_ids, count)
} else {
    // Existing behavior for backwards compatibility
}
```

### 3.2 Implement eco_dbg_print_typed for primitives

**File**: `runtime/src/allocator/RuntimeExports.cpp`

```cpp
void eco_dbg_print_typed(uint64_t* values, uint32_t* type_ids, uint32_t num_args) {
    for (uint32_t i = 0; i < num_args; ++i) {
        printValueTyped(values[i], type_ids[i]);
        eco_output_text("\n");
    }
}

void printValueTyped(uint64_t raw, uint32_t type_id) {
    const EcoTypeInfo* t = lookupType(type_id);
    if (!t) { eco_output_text("<unknown-type>"); return; }

    switch (t->kind) {
    case EcoTypeKind::Primitive:
        printPrimitive(raw, t->data.primitive.prim_kind);
        break;
    // Other cases print placeholder for now
    default:
        eco_output_text("<container>");
        break;
    }
}
```

### 3.3 Add MLIR tests for typed eco.dbg

**Files**: `test/codegen/dbg_typed_*.mlir`

```mlir
// dbg_typed_int.mlir
eco.type_table { types = [...], ... }
func.func @main() {
    %x = arith.constant 42 : i64
    eco.dbg %x : i64 { arg_type_ids = dense<[0]> : tensor<1xi64> }
    // CHECK: 42
}
```

**Verification at end of Phase 3**:
- Primitives (Int, Float, Char, Bool, String) print correctly via type graph
- MLIR tests pass
- Backwards compatibility: eco.dbg without arg_type_ids still works

---

## Phase 4: Full Container Printing

This phase completes the runtime printing for all container types.

### 4.1 Implement printList

**File**: `runtime/src/allocator/RuntimeExports.cpp`

```cpp
void printList(uint64_t raw, uint32_t elem_type_id) {
    // Handle Const_Nil
    // Iterate cons cells using header.unboxed to determine if head is unboxed
    // Recursively call printValueTyped for each element
}
```

### 4.2 Implement printTuple

```cpp
void printTuple(uint64_t raw, const EcoTypeInfo* t) {
    // Cast to Tuple2/Tuple3 based on arity
    // Use header.unboxed bitmap
    // Print "(a, b, c)" format
}
```

### 4.3 Implement printRecord

```cpp
void printRecord(uint64_t raw, const EcoTypeInfo* t) {
    // Cast to Record*
    // Use rec->unboxed bitmap
    // Lookup field names from string table
    // Print "{ field = value, ... }" format
}
```

### 4.4 Implement printCustom

```cpp
void printCustom(uint64_t raw, const EcoTypeInfo* t) {
    // Cast to Custom*
    // Get ctor_id from object, lookup EcoCtorInfo
    // Print "CtorName arg1 arg2" format
}
```

### 4.5 Implement printFunction

```cpp
void printFunction(uint64_t raw, const EcoTypeInfo* t) {
    eco_output_text("<function>");
    // Optionally print type signature from arg/result type_ids
}
```

### 4.6 Comprehensive integration tests

Test cases from design doc:
```elm
type alias Inner = { a : Int, b : Float }
type alias SomeRecord = { inner : Inner }
-- value : List SomeRecord
-- Expected: [ { inner = { a = 1, b = 2.0 } } ]
```

**Verification at end of Phase 4**:
- All container types print correctly
- Nested structures print correctly
- Unboxed fields handled properly

---

## Testing Strategy

### Per-Phase Testing

**Phase 1**: Build verification + parser/printer roundtrip tests
**Phase 2**: MLIR output inspection + LLVM IR verification
**Phase 3**: MLIR codegen tests with CHECK directives for primitives
**Phase 4**: Full integration tests with nested structures

### Test Files to Create

```
test/codegen/type_table_empty.mlir       # Phase 1: empty type table
test/codegen/type_table_primitives.mlir  # Phase 2: primitive types
test/codegen/type_table_containers.mlir  # Phase 2: list/tuple/record/custom
test/codegen/dbg_typed_int.mlir          # Phase 3: typed int printing
test/codegen/dbg_typed_float.mlir        # Phase 3: typed float printing
test/codegen/dbg_typed_string.mlir       # Phase 3: typed string printing
test/codegen/dbg_typed_list.mlir         # Phase 4: list printing
test/codegen/dbg_typed_record.mlir       # Phase 4: record with field names
test/codegen/dbg_typed_custom.mlir       # Phase 4: ADT with ctor names
test/codegen/dbg_typed_nested.mlir       # Phase 4: List of Records
```

---

## Risk Areas

1. **toComparableMonoType determinism**: Must produce identical output for identical types. Follow `toComparableSpecKey` pattern exactly.

2. **LLVM global struct layout**: Must match C++ `EcoTypeGraph` exactly. Use `static_assert` and explicit padding.

3. **Unboxed bitmap interpretation**: Different container types store unboxed bits differently:
   - `Cons.header.unboxed` (3 bits in header)
   - `Record.unboxed` (64-bit field)
   - `Custom.unboxed` (48 bits in packed field)

4. **Recursive types**: The type graph is acyclic (types reference type_ids, not pointers). Mutual recursion like `type Tree = Node Tree Tree | Leaf` works because we assign type_ids before filling in field references.

5. **CtorLayout availability**: Need to ensure `CtorLayout` info is available when building type graph. May need to collect it during `generateCtor` and store in context.

---

## Files Modified/Created

### New Files
- `runtime/src/allocator/TypeInfo.hpp`

### Modified Files
- `runtime/src/allocator/RuntimeExports.h` - Add `eco_dbg_print_typed` declaration
- `runtime/src/allocator/RuntimeExports.cpp` - Add typed printing implementation
- `runtime/src/codegen/Ops.td` - Add `Eco_TypeTableOp`, extend `Eco_DbgOp`
- `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp` - Extend `DbgOpLowering`
- `runtime/src/codegen/Passes/EcoToLLVMGlobals.cpp` - Add `TypeTableOpLowering`
- `compiler/src/Compiler/Generate/CodeGen/MLIR.elm` - TypeRegistry, generateTypeTable

### Test Files
- `test/codegen/type_table_*.mlir` - Type table tests
- `test/codegen/dbg_typed_*.mlir` - Typed debug printing tests

---

## Future Work (Out of Scope)

1. **Debug.log integration**: Wire `Debug.log` kernel calls to use typed eco.dbg
2. **Elm-level reflection API**: Surface type graph to Elm code
3. **type_id on eco.construct**: Add for dynamic type checks (not needed for printing)
4. **Optimization**: Compact type graph representation for large programs
