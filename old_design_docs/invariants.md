# Invariant Analysis Report

## Executive Summary

This report documents a comprehensive deep analysis of invariants across the eco-runtime project, covering:
- **Monomorphization** (MONO_*) - Elm compiler type specialization
- **MLIR Codegen** (CGEN_*) - Code generation to MLIR IR
- **Runtime Heap** (HEAP_*) - GC and memory management

**Critical Findings:**
- **1 Critical architectural issue**: `eco.construct` and `eco.project` hardcode `Custom` struct layout, causing layout mismatches for Records, Tuples, and Cons cells
- **2 Invariant violations**: MONO_002 (CNumber handling) and HEAP_010 (constants heap allocated)
- **Multiple Tag misuses**: Several places use tag=0 or incorrect tags in MLIR.elm

---

## Heap Tag Integer Values (HEAP_001)

The `Tag` enum in `runtime/src/allocator/Heap.hpp:64-84` defines heap object types:

| Tag Name | Integer Value | Purpose |
|----------|---------------|---------|
| Tag_Int | 0 | Boxed 64-bit signed integer |
| Tag_Float | 1 | Boxed 64-bit floating point |
| Tag_Char | 2 | Boxed Unicode character |
| Tag_String | 3 | Variable-length UTF-16 string |
| Tag_Tuple2 | 4 | Fixed 2-element tuple |
| Tag_Tuple3 | 5 | Fixed 3-element tuple |
| Tag_Cons | 6 | List cons cell |
| Tag_Custom | 7 | Algebraic data type variant |
| Tag_Record | 8 | Fixed record |
| Tag_DynRecord | 9 | Dynamic record |
| Tag_FieldGroup | 10 | Record field names |
| Tag_Closure | 11 | Function closure |
| Tag_Process | 12 | Concurrent process |
| Tag_Task | 13 | Async task |
| Tag_ByteBuffer | 14 | Immutable byte array |
| Tag_Array | 15 | Mutable array |
| Tag_Forward | 16 | GC forwarding pointer |

---

## Critical Architectural Issue: Layout Mismatch

### Problem Description

The MLIR codegen uses `eco.construct` for ALL composite heap allocations, but this operation is hardcoded to:
1. Allocate via `eco_alloc_custom()` which always uses `Tag_Custom`
2. Use the `Custom` struct memory layout

However, different heap types have **incompatible memory layouts**:

| Type | Layout | Fields Offset |
|------|--------|---------------|
| Custom | Header(8) + ctor/id/unboxed(8) + values[] | **16 bytes** |
| Record | Header(8) + unboxed(8) + values[] | **16 bytes** |
| Tuple2 | Header(8) + a(8) + b(8) | **8 bytes** |
| Tuple3 | Header(8) + a(8) + b(8) + c(8) | **8 bytes** |
| Cons | Header(8) + head(8) + tail(8) | **8 bytes** |

**Key difference**: Custom/Record have fields starting at offset 16, while Tuple2/Tuple3/Cons have fields starting at offset 8.

### Evidence

**EcoToLLVM.cpp:894-896** (ProjectOpLowering):
```cpp
// Calculate byte offset to the field in Custom object layout.
// Custom layout: Header (8) + ctor/unboxed (8) + fields[index * 8].
int64_t offsetBytes = 8 + 8 + index * 8;
```

**EcoToLLVM.cpp:384-495** (ConstructOpLowering):
```cpp
auto allocCall = rewriter.create<LLVM::CallOp>(
    loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_custom"),
    ValueRange{typeId, tag, size, scalarBytes});
```

**RuntimeExports.cpp:144-157** (eco_alloc_custom):
```cpp
extern "C" void* eco_alloc_custom(uint32_t type_id, uint32_t ctor_tag,
                                   uint32_t field_count, uint32_t scalar_bytes) {
    size_t size = sizeof(Header) + 8 + field_count * sizeof(Unboxable) + scalar_bytes;
    void* obj = Allocator::instance().allocate(size, Tag_Custom);  // ALWAYS Tag_Custom!
    Custom* custom = static_cast<Custom*>(obj);
    custom->ctor = ctor_tag;  // ctor_tag stored here, NOT in header.tag
    custom->id = type_id;
    custom->unboxed = 0;
    return obj;
}
```

### Why This Breaks

1. **getObjectSize** (AllocatorCommon.hpp:56-126) uses `switch(hdr->tag)`:
   - `Tag_Tuple2` → `sizeof(Tuple2)` = 24 bytes
   - `Tag_Custom` → `sizeof(Custom) + hdr->size * sizeof(Unboxable)` = dynamic

2. **scanObject** (NurserySpace.cpp:682-811) uses `switch(hdr->tag)`:
   - `Tag_Tuple2` → accesses `t->a` and `t->b` at offsets 8 and 16
   - `Tag_Custom` → accesses `c->values[i]` starting at offset 16

3. **markChildren** (OldGenSpace.cpp:383-468) uses same tag-based dispatch

If Tuples/Cons are allocated with Tag_Custom:
- GC computes **wrong object size** → memory corruption
- GC traces **wrong pointer locations** → lost objects or invalid pointers
- Field access reads **wrong memory** → garbage data

### Impact

- **Memory corruption**: Field access reads/writes wrong addresses
- **GC failures**: `scanObject`/`markChildren` expect different layouts based on Tag
- **Silent data corruption**: Values may appear correct but reference wrong data

---

## MLIR.elm Tag Usage Analysis

File: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

### Violations Found

| Line | Code | Issue |
|------|------|-------|
| 1820 | `ecoConstruct ctx1 resultVar 0 arity 0 defVarPairs Nothing Nothing` | Cycle creation with Tag=0 (Tag_Int). No Tag_Cycle exists. |
| 2271 | `ecoConstruct ctx1 var 0 0 0 [] Nothing Nothing` | Empty list with Tag=0. Should use `eco.constant Nil`. |
| 2285 | `ecoConstruct ctx1 nilVar 0 0 0 [] Nothing Nothing` | Nil creation with Tag=0. Should use `eco.constant Nil`. |
| 2303 | `ecoConstruct ctx4 consVar 1 2 0 [...]` | **Cons cell with Tag=1 (Tag_Float!)**. Should be Tag_Cons=6. |
| 3414 | `ecoConstruct ctx3 resultVar 0 0 0 [] Nothing Nothing` | Dummy value after tail call with Tag=0. |
| 4092 | `ecoConstruct ctx2 dummyVar 0 0 0 [] Nothing Nothing` | Joinpoint dummy with Tag=0. |
| 4160 | `ecoConstruct ctx1 dummyVar 0 0 0 [] Nothing Nothing` | Leaf dummy with Tag=0. |
| 4557 | `ecoConstruct ctx3 resultVar 0 layout.fieldCount layout.unboxedBitmap fieldVarPairs Nothing Nothing` | **Record creation with Tag=0 (Tag_Int!)**. Should be Tag_Record=8. |
| 4632 | `ecoConstruct ctx1 resultVar 0 1 0 [...]` | Record update with Tag=0. Should be Tag_Record=8. |
| 4690 | `ecoConstruct ctx3 resultVar 0 layout.arity layout.unboxedBitmap elemVarPairs Nothing Nothing` | **Tuple creation with Tag=0 (Tag_Int!)**. Should be Tag_Tuple2=4 or Tag_Tuple3=5. |
| 4710 | `ecoConstruct ctx1 var 0 0 0 [] Nothing Nothing` | Unit with Tag=0. Should use `eco.constant Unit`. |

### Analysis

The codegen uses the `tag` parameter of `ecoConstruct` inconsistently:

1. **For Custom types (ADTs)**: `ctorLayout.tag` is passed, which is the constructor INDEX (0, 1, 2...), not the heap Tag. This happens to work because:
   - `eco_alloc_custom` stores the tag as `custom->ctor` (constructor index)
   - `eco_alloc_custom` always uses `Tag_Custom` for the heap header

2. **For Records**: Tag=0 is passed, but `eco_alloc_custom` ignores this and uses `Tag_Custom`. The Record is treated as a Custom object.

3. **For Tuples**: Tag=0 is passed. Same issue as Records.

4. **For Cons cells**: Tag=1 is passed (accidentally Tag_Float!), but `eco_alloc_custom` still uses `Tag_Custom`.

5. **For Unit/Nil**: These should be embedded constants (Const_Unit, Const_Nil), not heap allocations.

### Unused Runtime Functions

The runtime has correct type-specific allocation functions that are **NOT being used**:
- `eco_alloc_cons()` - Uses `Tag_Cons` (RuntimeExports.cpp:189-193)
- `eco_alloc_tuple2()` - Uses `Tag_Tuple2` (RuntimeExports.cpp:195-199)
- `eco_alloc_tuple3()` - Uses `Tag_Tuple3` (RuntimeExports.cpp:201-205)

---

## Monomorphization Invariants

### MONO_002 - VIOLATED

**Description**: At MLIR codegen time, no MonoType may contain MVar with CNumber constraint.

**Finding**: `monoTypeToMlir` at `MLIR.elm:98-139` silently handles CNumber:
```elm
Mono.MVar name constraint_ ->
    case constraint_ of
        Mono.CNumber ->
            I64  -- Should error, not silently return I64

        Mono.CEcoValue ->
            ecoValue
```

**Status**: VIOLATED - Should crash/error to surface monomorphization bugs.

### MONO_003 - PRESERVED

**Description**: CEcoValue MVar allowed, represented as boxed eco.value.

**Finding**: Correctly maps to `ecoValue` in `monoTypeToMlir` at line 138.

### MONO_004 - PRESERVED

**Description**: Every MonoNode whose MonoType is a function must be callable (MonoTailFunc or MonoClosure).

**Finding**: `checkCallableTopLevels` at `Monomorphize.elm:81-132` validates that:
- `MonoDefine` with function type must wrap a `MonoClosure`
- `MonoTailFunc` is inherently callable (has params and body)

### MONO_006 - PRESERVED

**Description**: RecordLayout and TupleLayout store complete layout info.

**Finding**: Structures at `Monomorphized.elm:195-230` contain:
- `RecordLayout`: fieldCount, unboxedCount, unboxedBitmap, fields (List FieldInfo)
- `TupleLayout`: arity, unboxedBitmap, elements (List (MonoType, Bool))

### MONO_007 - PRESERVED

**Description**: Record field access uses indices from layout.

**Finding**: `lookupFieldIndex` at `Monomorphize.elm:2192-2207` extracts (index, isUnboxed) from layout.fields.

**Note**: Returns (0, False) as default for non-record types - could mask bugs if called incorrectly.

---

## MLIR Codegen Invariants

### CGEN_001 - CONCERN

**Description**: Boxing only between primitives and eco.value; primitive mismatches are bugs.

**Finding**: `boxToMatchSignature` at `MLIR.elm:2616-2657` has silent fallthrough:
```elm
else
    -- Types don't match but no boxing solution - use expression type
    ( opsAcc, pairsAcc ++ [ ( var, exprMlirTy ) ], ctxAcc )
```

This could mask type mismatch bugs instead of failing loudly.

### CGEN_004 - PRESERVED

**Description**: generateDestruct uses destructor MonoType for path target.

**Finding**: Explicit comment and correct implementation at `MLIR.elm:3533-3569`:
```elm
-- IMPORTANT: Do NOT use destType to determine the path's target type!
-- destType is the type of the overall body expression, not the destructed value.
destructorMlirType =
    monoTypeToMlir monoType
```

### CGEN_005 - PRESERVED

**Description**: generateMonoPath uses eco.project with correct unboxed attribute.

**Finding**: `ecoProject` at `MLIR.elm:4887-4903` sets `unboxed = not (isEcoValueType resultType)`.
`generateMonoPath` at lines 3573-3636 navigates containers as `ecoValue` and uses `ecoProject` correctly.

### CGEN_007 - PRESERVED

**Description**: boxToMatchSignature adjusts only box/unbox differences.

**Finding**: Handles three cases correctly:
1. Types match → no change
2. Expected boxed, have unboxed → box it
3. Expected unboxed, have boxed → unbox it

### CGEN_008 - PRESERVED

**Description**: eco.construct, eco.project, eco.call, eco.return carry _operand_types.

**Finding**: All operations include the attribute:
- `ecoConstruct` (MLIR.elm:4801-4847): `Dict.singleton "_operand_types" (ArrayAttr ...)`
- `ecoProject` (MLIR.elm:4887-4903): `Dict.fromList [("_operand_types", ...)]`
- Call operations: Include `_operand_types` in attrs

---

## Runtime Heap Invariants

### HEAP_001 - PRESERVED (with architectural concerns)

**Description**: Every heap object begins with 8-byte Header; first 5 bits encode Tag.

**Finding**: Header struct correct at `Heap.hpp:87-97`. However, the **Tag values being written are wrong** due to `eco_alloc_custom` hardcoding `Tag_Custom`.

### HEAP_002 - PRESERVED

**Description**: All heap objects are 8-byte aligned.

**Finding**: `getObjectSize` at `AllocatorCommon.hpp:125` uses `(size + 7) & ~7`.

### HEAP_003 - PRESERVED (but broken by Tag misuse)

**Description**: GC interprets layout via Header.tag switch.

**Finding**: `getObjectSize`, `scanObject`, `markChildren` all use tag-based switch correctly.

**Concern**: If all objects are allocated as Tag_Custom but have different actual layouts, GC will corrupt memory.

### HEAP_004 - PRESERVED

**Description**: New types require updating Tag enum, struct, getObjectSize, scanObject, markChildren.

**Finding**: All functions handle all tags consistently. ByteBuffer (Tag_ByteBuffer=14) and Array (Tag_Array=15) are fully implemented.

### HEAP_005 - PRESERVED

**Description**: No old-to-young pointers; guaranteed by Elm immutability.

**Finding**: No write barriers in codebase. GC design relies on immutability guarantee.

### HEAP_008 - PRESERVED

**Description**: HPointer is 40-bit offset from heap_base.

**Finding**: `Allocator.hpp:182-197`:
```cpp
static inline void* fromPointerRaw(HPointer ptr) {
    if (ptr.constant != 0) return nullptr;
    uintptr_t byte_offset = static_cast<uintptr_t>(ptr.ptr) << 3;
    return heap_base + byte_offset;
}

static inline HPointer toPointerRaw(void* obj) {
    uintptr_t byte_offset = static_cast<char*>(obj) - heap_base;
    ptr.ptr = byte_offset >> 3;
    ptr.constant = 0;
    ...
}
```

### HEAP_009 - PRESERVED

**Description**: HPointer is canonical type; use fromPointer/toPointer helpers.

**Finding**: Code consistently uses `Allocator::fromPointerRaw`/`toPointerRaw` for conversions.

### HEAP_010 - VIOLATED

**Description**: Common constants (Unit, EmptyRec, True, False, Nil, Nothing, EmptyString) embedded in HPointer.

**Finding**:
- Booleans correctly use `eco.constant` at `MLIR.elm:5030-5050`
- **Unit** heap-allocated via `ecoConstruct` at `MLIR.elm:4710` instead of `eco.constant Unit`
- **Nil** heap-allocated via `ecoConstruct` at `MLIR.elm:2271, 2285` instead of `eco.constant Nil`

The runtime supports embedded constants:
- `Ops.td:83-93`: `Eco_ConstantKind` enum (Unit=1, EmptyRec=2, True=3, False=4, Nil=5, Nothing=6, EmptyString=7)
- `EcoToLLVM.cpp:151-170`: `ConstantOpLowering` encodes as `kindValue << 40`
- `Heap.hpp:102-110`: `Constant` enum matches

### HEAP_011 - PRESERVED

**Description**: Allocation may trigger GC.

**Finding**: `ThreadLocalHeap::allocate` at `NurserySpace.cpp` checks threshold and calls `minorGC()`.

### HEAP_013 - CRITICAL VIOLATION

**Description**: Tag passed to allocate must match concrete struct written.

**Finding**:
- `eco_alloc_custom` always uses `Tag_Custom` regardless of actual type
- Records/Tuples/Cons allocated via `eco.construct` get wrong Tag
- GC tracing functions expect specific layouts per Tag
- **This will cause memory corruption when GC runs**

---

## Summary Table

| ID | Status | Severity | Description |
|----|--------|----------|-------------|
| MONO_002 | VIOLATED | High | CNumber silently returns I64 |
| MONO_003 | Preserved | - | CEcoValue maps to ecoValue |
| MONO_004 | Preserved | - | checkCallableTopLevels validates |
| MONO_006 | Preserved | - | Layouts complete |
| MONO_007 | Preserved | - | Field indices from layout |
| CGEN_001 | Concern | Medium | Silent fallthrough on mismatch |
| CGEN_004 | Preserved | - | Uses destructor MonoType |
| CGEN_005 | Preserved | - | eco.project correct |
| CGEN_007 | Preserved | - | box/unbox adjustments |
| CGEN_008 | Preserved | - | _operand_types present |
| HEAP_001 | Architectural Issue | **Critical** | Layout mismatch for all non-Custom types |
| HEAP_002 | Preserved | - | 8-byte alignment |
| HEAP_003 | Preserved | - | Tag-based switch (broken by Tag misuse) |
| HEAP_004 | Preserved | - | Consistent tag handling |
| HEAP_005 | Preserved | - | No write barriers |
| HEAP_008 | Preserved | - | 40-bit offset |
| HEAP_009 | Preserved | - | Canonical HPointer usage |
| HEAP_010 | Violated | Medium | Unit/Nil allocated instead of constants |
| HEAP_011 | Preserved | - | GC on allocation |
| HEAP_013 | **CRITICAL** | **Critical** | Tag mismatch for Records/Tuples/Cons |

---

## Recommended Actions

### Critical (Must Fix)

1. **Layout Architecture**: Decide on unified approach:
   - **Option A**: Make all composite types use Custom layout (consolidate Tags). Simplest but wasteful (8 extra bytes per Tuple/Cons).
   - **Option B**: Add type-specific allocation operations and lowering for Record, Tuple2, Tuple3, Cons. More work but correct and efficient.

2. **Fix ProjectOpLowering**: Either:
   - Use runtime dispatch based on actual Tag to compute correct offset
   - Or ensure all allocated types have same layout (Option A)

3. **Fix List Construction (Line 2303)**: Cons cells use Tag=1 (Float!). Must use Tag=6 or allocate via `eco_alloc_cons`.

### High Priority

4. **MONO_002**: Change `monoTypeToMlir` to crash on CNumber instead of returning I64.
   ```elm
   Mono.CNumber ->
       Debug.crash "CNumber at codegen time indicates monomorphization bug"
   ```

5. **Record/Tuple Tags**: Either:
   - Use correct Tag values (Tag_Record=8, Tag_Tuple2=4, Tag_Tuple3=5)
   - Or consolidate all to Tag_Custom with unified layout

### Medium Priority

6. **Constants (HEAP_010)**: Unit and Nil should use embedded constants:
   ```elm
   -- Instead of: ecoConstruct ctx1 var 0 0 0 [] Nothing Nothing
   -- Use: eco.constant Unit  (or Nil)
   ```

7. **CGEN_001**: Add assertion for unexpected type mismatches in `boxToMatchSignature`:
   ```elm
   else
       Debug.crash ("Type mismatch: expected " ++ Debug.toString expectedMlirTy
                    ++ " but got " ++ Debug.toString exprMlirTy)
   ```

---

## Appendix: File Locations

### Key Files

- Tag enum: `runtime/src/allocator/Heap.hpp:64-84`
- MLIR codegen: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`
- LLVM lowering: `runtime/src/codegen/Passes/EcoToLLVM.cpp`
- Runtime allocation: `runtime/src/allocator/RuntimeExports.cpp`
- GC tracing (nursery): `runtime/src/allocator/NurserySpace.cpp:682-811`
- GC marking (old gen): `runtime/src/allocator/OldGenSpace.cpp:383-468`
- Object sizing: `runtime/src/allocator/AllocatorCommon.hpp:56-126`
- HPointer conversion: `runtime/src/allocator/Allocator.hpp:182-197`
- Monomorphization: `compiler/src/Compiler/Generate/Monomorphize.elm`
- Monomorphized types: `compiler/src/Compiler/AST/Monomorphized.elm`
- MLIR operations: `runtime/src/codegen/Ops.td`

### Evidence Trail for Critical Issue

1. `MLIR.elm:4690` - Tuple uses tag=0
2. `MLIR.elm:4801-4847` - `ecoConstruct` creates `eco.construct` op
3. `EcoToLLVM.cpp:400-402` - `ConstructOpLowering` calls `eco_alloc_custom`
4. `RuntimeExports.cpp:148` - `eco_alloc_custom` uses `Tag_Custom` always
5. `EcoToLLVM.cpp:896` - `ProjectOpLowering` assumes 16-byte offset (Custom layout)
6. `AllocatorCommon.hpp:73-75` - `getObjectSize` for `Tag_Tuple2` uses `sizeof(Tuple2)` = 24 bytes
7. `NurserySpace.cpp:690-694` - `scanObject` for `Tag_Tuple2` accesses `t->a`, `t->b` at offsets 8, 16

When a Tuple is created:
- Allocated as Tag_Custom with Custom layout (fields at offset 16)
- BUT if it somehow had Tag_Tuple2, GC would read wrong memory locations

Current situation: All tuples get Tag_Custom, so GC traces them as Custom objects. This "works" only because:
1. Custom layout has fields at same offset (16) as where we write them
2. But the size calculation would be wrong if we used correct tags
