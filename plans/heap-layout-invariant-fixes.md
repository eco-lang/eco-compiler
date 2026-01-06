# Plan: Heap Layout Invariant Fixes (HEAP_013, HEAP_015)

## Overview

This plan implements the design in `design_docs/invariant-fixes.md` to enforce proper heap layout invariants. The core change is ensuring that Lists, Tuples, and Records use their correct runtime types (`Tag_Cons`, `Tag_Tuple2`, `Tag_Tuple3`, `Tag_Record`) instead of being allocated as `Tag_Custom`.

**Invariant (HEAP_015)**: For every heap allocation, the header tag and in-memory layout must match the concrete runtime type. No List, Tuple, or Record may be represented using the Custom struct.

## Current State Analysis

### What exists:
- `eco.construct` / `eco.project` ops in Ops.td (generic for all types)
- `ConstructOpLowering` always calls `eco_alloc_custom` with `Tag_Custom`
- `ProjectOpLowering` assumes Custom layout: offset = 8 + 8 + index * 8
- Runtime has skeleton allocators (`eco_alloc_cons`, `eco_alloc_tuple2`, `eco_alloc_tuple3`) but they don't initialize fields
- No `eco_alloc_record` exists

### Struct Layouts (from Heap.hpp):

| Type | Layout | Fields Start At |
|------|--------|-----------------|
| Cons | Header(8) + head(8) + tail(8) | offset 8 |
| Tuple2 | Header(8) + a(8) + b(8) | offset 8 |
| Tuple3 | Header(8) + a(8) + b(8) + c(8) | offset 8 |
| Record | Header(8) + unboxed(8) + values[] | offset 16 |
| Custom | Header(8) + ctor/id/unboxed(8) + values[] | offset 16 |

**Key insight**: Cons/Tuple2/Tuple3 have fields at offset 8. Record/Custom have fields at offset 16.

---

## Phase 1: Runtime Allocators

**File**: `runtime/src/allocator/RuntimeExports.cpp`

### 1.1 Update `eco_alloc_cons` to accept and store fields

```cpp
extern "C" void* eco_alloc_cons(void* head, void* tail) {
    size_t size = sizeof(Cons);
    void* obj = Allocator::instance().allocate(size, Tag_Cons);
    if (!obj) return nullptr;

    Cons* cons = static_cast<Cons*>(obj);
    cons->head.p = Allocator::toPointerRaw(head);
    cons->tail = Allocator::toPointerRaw(tail);
    return obj;
}
```

### 1.2 Update `eco_alloc_tuple2` to accept and store fields

```cpp
extern "C" void* eco_alloc_tuple2(void* a, void* b) {
    size_t size = sizeof(Tuple2);
    void* obj = Allocator::instance().allocate(size, Tag_Tuple2);
    if (!obj) return nullptr;

    Tuple2* tup = static_cast<Tuple2*>(obj);
    tup->a.p = Allocator::toPointerRaw(a);
    tup->b.p = Allocator::toPointerRaw(b);
    return obj;
}
```

### 1.3 Update `eco_alloc_tuple3` to accept and store fields

```cpp
extern "C" void* eco_alloc_tuple3(void* a, void* b, void* c) {
    size_t size = sizeof(Tuple3);
    void* obj = Allocator::instance().allocate(size, Tag_Tuple3);
    if (!obj) return nullptr;

    Tuple3* tup = static_cast<Tuple3*>(obj);
    tup->a.p = Allocator::toPointerRaw(a);
    tup->b.p = Allocator::toPointerRaw(b);
    tup->c.p = Allocator::toPointerRaw(c);
    return obj;
}
```

### 1.4 Add `eco_alloc_record`

```cpp
extern "C" void* eco_alloc_record(uint32_t field_count, uint64_t unboxed_bitmap) {
    size_t size = sizeof(Header) + 8 + field_count * sizeof(Unboxable);
    void* obj = Allocator::instance().allocate(size, Tag_Record);
    if (!obj) return nullptr;

    Record* rec = static_cast<Record*>(obj);
    rec->header.size = field_count;
    rec->unboxed = unboxed_bitmap;
    return obj;
}
```

### 1.5 Add field store functions for Record

```cpp
extern "C" void eco_store_record_field(void* record, uint32_t index, void* value) {
    Record* rec = static_cast<Record*>(record);
    rec->values[index].p = Allocator::toPointerRaw(value);
}

extern "C" void eco_store_record_field_i64(void* record, uint32_t index, int64_t value) {
    Record* rec = static_cast<Record*>(record);
    rec->values[index].i = value;
}

extern "C" void eco_store_record_field_f64(void* record, uint32_t index, double value) {
    Record* rec = static_cast<Record*>(record);
    rec->values[index].f = value;
}
```

---

## Phase 2: MLIR Dialect Operations

**File**: `runtime/src/codegen/Ops.td`

### 2.1 Add List Operations

```tablegen
def Eco_ListConsOp : Eco_Op<"cons.list", [Pure]> {
  let summary = "Construct a list Cons cell";
  let arguments = (ins Eco_Value:$head, Eco_Value:$tail);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$head `,` $tail attr-dict `:` type($head) `,` type($tail) `->` type($result)";
}

def Eco_ListHeadOp : Eco_Op<"project.list_head", [Pure]> {
  let summary = "Project head of a list Cons cell";
  let arguments = (ins Eco_Value:$list);
  let results = (outs Eco_Value:$head);
  let assemblyFormat = "$list attr-dict `:` type($list) `->` type($head)";
}

def Eco_ListTailOp : Eco_Op<"project.list_tail", [Pure]> {
  let summary = "Project tail of a list Cons cell";
  let arguments = (ins Eco_Value:$list);
  let results = (outs Eco_Value:$tail);
  let assemblyFormat = "$list attr-dict `:` type($list) `->` type($tail)";
}
```

### 2.2 Add Tuple Operations

```tablegen
def Eco_Tuple2ConstructOp : Eco_Op<"construct.tuple2", [Pure]> {
  let summary = "Construct a 2-tuple";
  let arguments = (ins Eco_AnyValue:$a, Eco_AnyValue:$b);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$a `,` $b attr-dict `:` type($a) `,` type($b) `->` type($result)";
}

def Eco_Tuple3ConstructOp : Eco_Op<"construct.tuple3", [Pure]> {
  let summary = "Construct a 3-tuple";
  let arguments = (ins Eco_AnyValue:$a, Eco_AnyValue:$b, Eco_AnyValue:$c);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "$a `,` $b `,` $c attr-dict `:` type($a) `,` type($b) `,` type($c) `->` type($result)";
}

def Eco_Tuple2ProjectOp : Eco_Op<"project.tuple2", [Pure]> {
  let summary = "Project field from 2-tuple";
  let arguments = (ins Eco_Value:$tuple, I64Attr:$field);
  let results = (outs Eco_AnyValue:$result);
  let assemblyFormat = "$tuple `[` $field `]` attr-dict `:` type($tuple) `->` type($result)";
}

def Eco_Tuple3ProjectOp : Eco_Op<"project.tuple3", [Pure]> {
  let summary = "Project field from 3-tuple";
  let arguments = (ins Eco_Value:$tuple, I64Attr:$field);
  let results = (outs Eco_AnyValue:$result);
  let assemblyFormat = "$tuple `[` $field `]` attr-dict `:` type($tuple) `->` type($result)";
}
```

### 2.3 Add Record Operations

```tablegen
def Eco_RecordConstructOp : Eco_Op<"construct.record", [Pure]> {
  let summary = "Construct an Elm record";
  let arguments = (ins Variadic<Eco_AnyValue>:$fields, I64Attr:$field_count, I64Attr:$unboxed_bitmap);
  let results = (outs Eco_Value:$result);
  let assemblyFormat = "`(` $fields `)` attr-dict `:` functional-type($fields, $result)";
}

def Eco_RecordProjectOp : Eco_Op<"project.record", [Pure]> {
  let summary = "Project a record field";
  let arguments = (ins Eco_Value:$record, I64Attr:$field_index);
  let results = (outs Eco_AnyValue:$result);
  let assemblyFormat = "$record `[` $field_index `]` attr-dict `:` type($record) `->` type($result)";
}
```

---

## Phase 3: LLVM Lowerings

**File**: `runtime/src/codegen/Passes/EcoToLLVM.cpp`

### 3.1 Add ListConsOpLowering

- Call `eco_alloc_cons(head, tail)`
- Return the allocated pointer

### 3.2 Add ListHeadOpLowering / ListTailOpLowering

- Offset for head: 8 bytes (after Header)
- Offset for tail: 16 bytes
- Load field at correct offset

### 3.3 Add Tuple2ConstructOpLowering / Tuple3ConstructOpLowering

- Call `eco_alloc_tuple2(a, b)` or `eco_alloc_tuple3(a, b, c)`
- Handle unboxed fields via separate store calls if needed

### 3.4 Add Tuple2ProjectOpLowering / Tuple3ProjectOpLowering

- Offset: 8 + field * 8 (fields start at offset 8)
- Load field at correct offset

### 3.5 Add RecordConstructOpLowering

- Call `eco_alloc_record(field_count, unboxed_bitmap)`
- Store each field using `eco_store_record_field*` functions

### 3.6 Add RecordProjectOpLowering

- Offset: 16 + field_index * 8 (fields start at offset 16, after Header + unboxed bitmap)
- Load field at correct offset

### 3.7 Register new patterns

Add all new lowering patterns to `populateEcoToLLVMConversionPatterns`.

---

## Phase 4: Elm MLIR Codegen

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

### 4.1 Add new op builders

```elm
ecoListCons : Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> ( Context, MlirOp )
ecoProjectListHead : Context -> String -> String -> ( Context, MlirOp )
ecoProjectListTail : Context -> String -> String -> ( Context, MlirOp )
ecoConstructTuple2 : Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> ( Context, MlirOp )
ecoConstructTuple3 : Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> ( String, MlirType ) -> ( Context, MlirOp )
ecoProjectTuple2 : Context -> String -> Int -> MlirType -> String -> ( Context, MlirOp )
ecoProjectTuple3 : Context -> String -> Int -> MlirType -> String -> ( Context, MlirOp )
ecoConstructRecord : Context -> String -> Int -> Int -> List ( String, MlirType ) -> ( Context, MlirOp )
ecoProjectRecord : Context -> String -> Int -> MlirType -> String -> ( Context, MlirOp )
```

### 4.2 Update `generateList`

- Use `eco.constant Nil` (kind=5) for empty list instead of `ecoConstruct ctx1 var 0 0 0 []`
- Use `ecoListCons` for cons cells instead of `ecoConstruct ctx4 consVar 1 2 0 [...]`

### 4.3 Update `generateTupleCreate`

- Use `ecoConstructTuple2` for 2-tuples
- Use `ecoConstructTuple3` for 3-tuples
- Remove use of `ecoConstruct` with tag=0

### 4.4 Update `generateRecordCreate`

- Use `ecoConstructRecord` instead of `ecoConstruct` with tag=0

### 4.5 Update `generateRecordAccess`

- Use `ecoProjectRecord` instead of `ecoProject`

### 4.6 Update `generateUnit`

- Use `eco.constant Unit` (kind=1) instead of `ecoConstruct ctx1 var 0 0 0 []`

### 4.7 Update path navigation in `generateMonoPath`

- When projecting from Cons: use `ecoProjectListHead` / `ecoProjectListTail`
- When projecting from Tuple: use `ecoProjectTuple2` / `ecoProjectTuple3`
- When projecting from Record: use `ecoProjectRecord`
- Keep `ecoProject` for Custom ADTs only

---

## Phase 5: Invariant Enforcement

### 5.1 MONO_002: Crash on CNumber at codegen

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

In `monoTypeToMlir`:
```elm
Mono.MVar _ constraint_ ->
    case constraint_ of
        Mono.CNumber ->
            Debug.crash "CNumber at codegen time indicates monomorphization bug (MONO_002)"

        Mono.CEcoValue ->
            ecoValue
```

### 5.2 CGEN_001: Crash on type mismatch in boxToMatchSignatureTyped

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

In `boxToMatchSignatureTyped`, change the final `else` branch:
```elm
else
    Debug.crash
        ("Type mismatch in boxToMatchSignatureTyped: expected "
            ++ Debug.toString expectedMlirTy
            ++ " but got "
            ++ Debug.toString actualTy
        )
```

### 5.3 HEAP_010: Use constants for Unit and Nil

Already covered in 4.2 and 4.6 above.

---

## Implementation Order

1. **Phase 1**: Runtime allocators (no dependencies)
2. **Phase 2**: Ops.td definitions (no dependencies)
3. **Phase 3**: LLVM lowerings (depends on 1, 2)
4. **Phase 5.1-5.2**: Invariant enforcement in MLIR.elm (no dependencies, can catch bugs early)
5. **Phase 4**: Elm codegen updates (depends on 2, 3)

---

## Testing Strategy

1. **Unit tests**: Verify each new allocator produces correct Tag and layout
2. **MLIR roundtrip**: Verify new ops parse/print correctly
3. **Integration tests**: Compile Elm programs using lists/tuples/records, verify GC correctness
4. **Property tests**: Extend RapidCheck tests to stress list/tuple/record allocation

---

## Open Questions

### Q1: Unboxed fields in Tuples

The `Tuple2` and `Tuple3` structs use `Unboxable` for fields and `Header.unboxed` for the bitmap. Should the new allocators accept unboxed primitives directly, or should all fields be boxed first?

**Current design assumption**: All fields passed to allocators are `void*` (boxed). Unboxing is handled at the MLIR level via the `_operand_types` attribute. The runtime stores raw 64-bit values.

### Q2: Record field storage order

Do record fields need special ordering, or are they stored in the order specified by `RecordLayout.fields`?

**Current design assumption**: Fields are stored in layout order. The `unboxed_bitmap` indicates which are primitives.

### Q3: Backward compatibility of existing `ecoConstruct` calls

Some uses of `ecoConstruct` are for dummy values (e.g., after tail calls, in joinpoints). Should these use `eco.constant Unit` or remain as-is?

**Current design assumption**: Convert dummy allocations to `eco.constant Unit` where semantically appropriate.

### Q4: Record update (`generateRecordUpdate`)

The design mentions leaving record updates unimplemented with an error. Is this acceptable, or should we implement copy-on-write record update?

**Current design assumption**: Leave as stub initially, implement properly in a follow-up.

---

## Estimated Scope

- **Runtime (C++)**: ~100 lines
- **Ops.td**: ~150 lines
- **EcoToLLVM.cpp**: ~300 lines
- **MLIR.elm**: ~200 lines
- **Total**: ~750 lines of code changes
