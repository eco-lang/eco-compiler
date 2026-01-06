# Plan: Heap Layout Invariant Fixes (HEAP_013, HEAP_015)

## Overview

This plan implements the design in `design_docs/invariant-fixes.md` to enforce proper heap layout invariants. The core change is ensuring that Lists, Tuples, and Records use their correct runtime types (`Tag_Cons`, `Tag_Tuple2`, `Tag_Tuple3`, `Tag_Record`) instead of being allocated as `Tag_Custom`.

**Invariant (HEAP_015)**: For every heap allocation, the header tag and in-memory layout must match the concrete runtime type. No List, Tuple, or Record may be represented using the Custom struct.

---

## Current State Analysis

### What exists:
- `eco.construct` / `eco.project` ops in Ops.td (generic for all types)
- `ConstructOpLowering` always calls `eco_alloc_custom` with `Tag_Custom`
- `ProjectOpLowering` assumes Custom layout: offset = 8 + 8 + index * 8
- Runtime has skeleton allocators (`eco_alloc_cons`, `eco_alloc_tuple2`, `eco_alloc_tuple3`) but they don't initialize fields
- No `eco_alloc_record` exists

### Struct Layouts (from Heap.hpp):

| Type | Layout | Fields Start At | Unboxed Bitmap Location |
|------|--------|-----------------|------------------------|
| Cons | Header(8) + head(8) + tail(8) | offset 8 | `Header.unboxed` (bit 0 = head) |
| Tuple2 | Header(8) + a(8) + b(8) | offset 8 | `Header.unboxed` (bits 0-1) |
| Tuple3 | Header(8) + a(8) + b(8) + c(8) | offset 8 | `Header.unboxed` (bits 0-2) |
| Record | Header(8) + unboxed(8) + values[] | offset 16 | `Record.unboxed` (64-bit) |
| Custom | Header(8) + ctor/id/unboxed(8) + values[] | offset 16 | `Custom.unboxed` (32-bit) |

**Key insight**: Cons/Tuple2/Tuple3 have fields at offset 8 and use `Header.unboxed`. Record/Custom have fields at offset 16 and use struct-level `unboxed` field.

---

## Design Decisions (from Q&A)

### D1: Unboxed Field Handling

All composite fields are stored as `Unboxable` union with a bitmap indicating which are primitives vs pointers.

- **Dialect ops** use `Eco_AnyValue` for field operands/results (not just `Eco_Value`)
- **Each op carries `unboxed_bitmap`** (or `head_unboxed` for Cons)
- **Lowering** builds `Unboxable` unions and sets `Header.unboxed` or struct `unboxed` fields
- **SSA type consistency**: bitmap bit and SSA type must agree (debug assertions)

### D2: Record Update

Implement proper copy-update now (not a stub):
1. Evaluate base record
2. For each field: use update expression if present, else project from base
3. Construct new record with `generateRecordCreate`

### D3: Dummy Value Allocations

Replace ALL dummy `eco.construct` calls (tag=0, size=0) with `eco.constant Unit`:
- `createDummyValue` for `ecoValue` types
- `generateLeaf` for `Mono.Jump` (joinpoint leaf)
- Post-`eco.jump` dummies in joinpoint code

### D4: Path Navigation (generateMonoPath)

Use type-specific projection ops based on static container type:
- `MList _` → `eco.project.list_head` / `eco.project.list_tail`
- `MTuple layout` → `eco.project.tuple2` / `eco.project.tuple3` with `field` attr
- `MRecord _` → `eco.project.record` with `field_index` attr
- `MCustom _ _ _` → `eco.project` (generic, reserved for Custom ADTs)
- `MVar _ CEcoValue` → fallback to generic `eco.project` with runtime dispatch

---

## Phase 1: Runtime Allocators

**File**: `runtime/src/allocator/RuntimeExports.cpp`

### 1.1 Update `eco_alloc_cons`

```cpp
// head can be boxed (void*) or unboxed (i64/f64 stored as void*)
// head_unboxed: 0 = boxed pointer, 1 = unboxed primitive
extern "C" void* eco_alloc_cons(void* head, void* tail, uint32_t head_unboxed) {
    size_t size = sizeof(Cons);
    void* obj = Allocator::instance().allocate(size, Tag_Cons);
    if (!obj) return nullptr;

    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = head_unboxed;

    // Store head as Unboxable (raw 64-bit value)
    cons->head.i = reinterpret_cast<int64_t>(head);

    // Tail is always a boxed list pointer
    cons->tail = Allocator::toPointerRaw(tail);

    return obj;
}
```

### 1.2 Update `eco_alloc_tuple2`

```cpp
// a, b can be boxed or unboxed; unboxed_mask bits 0,1 indicate which
extern "C" void* eco_alloc_tuple2(void* a, void* b, uint32_t unboxed_mask) {
    size_t size = sizeof(Tuple2);
    void* obj = Allocator::instance().allocate(size, Tag_Tuple2);
    if (!obj) return nullptr;

    Tuple2* tup = static_cast<Tuple2*>(obj);
    tup->header.unboxed = unboxed_mask;

    // Store as raw 64-bit values
    tup->a.i = reinterpret_cast<int64_t>(a);
    tup->b.i = reinterpret_cast<int64_t>(b);

    return obj;
}
```

### 1.3 Update `eco_alloc_tuple3`

```cpp
extern "C" void* eco_alloc_tuple3(void* a, void* b, void* c, uint32_t unboxed_mask) {
    size_t size = sizeof(Tuple3);
    void* obj = Allocator::instance().allocate(size, Tag_Tuple3);
    if (!obj) return nullptr;

    Tuple3* tup = static_cast<Tuple3*>(obj);
    tup->header.unboxed = unboxed_mask;

    tup->a.i = reinterpret_cast<int64_t>(a);
    tup->b.i = reinterpret_cast<int64_t>(b);
    tup->c.i = reinterpret_cast<int64_t>(c);

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
//===----------------------------------------------------------------------===//
// List Operations (Cons / Nil)
//===----------------------------------------------------------------------===//

def Eco_ListConsOp : Eco_Op<"cons.list", [Pure]> {
  let summary = "Construct a list Cons cell";
  let description = [{
    Allocate a list cons cell: head :: tail.

    Head can be boxed (!eco.value) or unboxed primitive (i64, f64, etc.).
    Tail is always boxed (!eco.value). Nil is represented as an embedded
    constant via `eco.constant Nil`, not heap-allocated.

    The `head_unboxed` attribute indicates whether head is stored unboxed.
  }];

  let arguments = (ins
    Eco_AnyValue:$head,
    Eco_Value:$tail,
    DefaultValuedAttr<BoolAttr, "false">:$head_unboxed
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$head `,` $tail attr-dict `:` type($head) `,` type($tail) `->` type($result)";
}

def Eco_ListHeadOp : Eco_Op<"project.list_head", [Pure]> {
  let summary = "Project head of a list Cons cell";
  let description = [{
    Project the head field of a non-empty list (Cons cell).
    Result type depends on whether head is unboxed.
  }];

  let arguments = (ins Eco_Value:$list);
  let results = (outs Eco_AnyValue:$head);

  let assemblyFormat = "$list attr-dict `:` type($list) `->` type($head)";
}

def Eco_ListTailOp : Eco_Op<"project.list_tail", [Pure]> {
  let summary = "Project tail of a list Cons cell";
  let description = [{
    Project the tail field of a non-empty list (Cons cell).
    Tail is always a boxed list pointer (!eco.value).
  }];

  let arguments = (ins Eco_Value:$list);
  let results = (outs Eco_Value:$tail);

  let assemblyFormat = "$list attr-dict `:` type($list) `->` type($tail)";
}
```

### 2.2 Add Tuple Operations

```tablegen
//===----------------------------------------------------------------------===//
// Tuple Operations
//===----------------------------------------------------------------------===//

def Eco_Tuple2ConstructOp : Eco_Op<"construct.tuple2", [Pure]> {
  let summary = "Construct a 2-tuple";
  let description = [{
    Construct a 2-tuple value. Elements may be boxed (!eco.value) or
    unboxed primitives. The `unboxed_bitmap` attribute indicates which
    fields are stored unboxed (bit 0 = a, bit 1 = b).
  }];

  let arguments = (ins
    Eco_AnyValue:$a,
    Eco_AnyValue:$b,
    DefaultValuedAttr<I64Attr, "0">:$unboxed_bitmap
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$a `,` $b attr-dict `:` type($a) `,` type($b) `->` type($result)";
}

def Eco_Tuple3ConstructOp : Eco_Op<"construct.tuple3", [Pure]> {
  let summary = "Construct a 3-tuple";
  let description = [{
    Construct a 3-tuple value. The `unboxed_bitmap` attribute indicates
    which fields are stored unboxed (bits 0-2 for a, b, c).
  }];

  let arguments = (ins
    Eco_AnyValue:$a,
    Eco_AnyValue:$b,
    Eco_AnyValue:$c,
    DefaultValuedAttr<I64Attr, "0">:$unboxed_bitmap
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$a `,` $b `,` $c attr-dict `:` type($a) `,` type($b) `,` type($c) `->` type($result)";
}

def Eco_Tuple2ProjectOp : Eco_Op<"project.tuple2", [Pure]> {
  let summary = "Project field from 2-tuple";
  let description = [{
    Project element 0 or 1 from a 2-tuple. Result type is the concrete
    SSA type (primitive or !eco.value) based on unboxed status.
  }];

  let arguments = (ins Eco_Value:$tuple, I64Attr:$field);
  let results = (outs Eco_AnyValue:$result);

  let assemblyFormat = "$tuple `[` $field `]` attr-dict `:` type($tuple) `->` type($result)";
}

def Eco_Tuple3ProjectOp : Eco_Op<"project.tuple3", [Pure]> {
  let summary = "Project field from 3-tuple";
  let description = [{
    Project element 0, 1, or 2 from a 3-tuple.
  }];

  let arguments = (ins Eco_Value:$tuple, I64Attr:$field);
  let results = (outs Eco_AnyValue:$result);

  let assemblyFormat = "$tuple `[` $field `]` attr-dict `:` type($tuple) `->` type($result)";
}
```

### 2.3 Add Record Operations

```tablegen
//===----------------------------------------------------------------------===//
// Record Operations
//===----------------------------------------------------------------------===//

def Eco_RecordConstructOp : Eco_Op<"construct.record", [Pure]> {
  let summary = "Construct an Elm record";
  let description = [{
    Construct a record with a fixed set of fields. The `field_count` and
    `unboxed_bitmap` attributes describe layout. Fields may be boxed or
    unboxed primitives.
  }];

  let arguments = (ins
    Variadic<Eco_AnyValue>:$fields,
    I64Attr:$field_count,
    I64Attr:$unboxed_bitmap
  );
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "`(` $fields `)` attr-dict `:` functional-type($fields, $result)";
}

def Eco_RecordProjectOp : Eco_Op<"project.record", [Pure]> {
  let summary = "Project a record field";
  let description = [{
    Project the field at a given index from a record. Result type is
    the concrete SSA type based on unboxed status.
  }];

  let arguments = (ins Eco_Value:$record, I64Attr:$field_index);
  let results = (outs Eco_AnyValue:$result);

  let assemblyFormat = "$record `[` $field_index `]` attr-dict `:` type($record) `->` type($result)";
}
```

### 2.4 Keep existing `eco.construct` / `eco.project` for Custom ADTs only

The existing `Eco_ConstructOp` and `Eco_ProjectOp` remain **exclusively for Custom ADTs**. After this change, they should never be used for Lists, Tuples, or Records.

---

## Phase 3: LLVM Lowerings

**File**: `runtime/src/codegen/Passes/EcoToLLVM.cpp`

### 3.1 ListConsOpLowering

```cpp
struct ListConsOpLowering : public OpConversionPattern<eco::ListConsOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult matchAndRewrite(eco::ListConsOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value head = adaptor.getHead();
        Value tail = adaptor.getTail();

        // Determine if head is unboxed from attribute
        bool headUnboxed = op.getHeadUnboxed();
        auto unboxedFlag = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, headUnboxed ? 1 : 0);

        // Convert head to i64 for storage (handles both ptr and primitive)
        auto i64Ty = IntegerType::get(ctx, 64);
        Value headAsI64;
        if (head.getType().isInteger(64) || head.getType().isF64()) {
            headAsI64 = rewriter.create<LLVM::BitcastOp>(loc, i64Ty, head);
        } else {
            headAsI64 = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, head);
        }
        auto headAsPtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, headAsI64);

        // Call eco_alloc_cons(head, tail, head_unboxed)
        auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy, ptrTy, i32Ty});
        getOrInsertFunc(op->getParentOfType<ModuleOp>(), rewriter,
                        "eco_alloc_cons", funcTy);

        auto result = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_cons"),
            ValueRange{headAsPtr, tail, unboxedFlag});

        rewriter.replaceOp(op, result.getResult());
        return success();
    }
};
```

### 3.2 ListHeadOpLowering

```cpp
struct ListHeadOpLowering : public OpConversionPattern<eco::ListHeadOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult matchAndRewrite(eco::ListHeadOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value list = adaptor.getList();
        auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, list);

        // Cons layout: Header (8) + head (8) + tail (8)
        // Head field is at offset 8
        int64_t offsetBytes = 8;
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                     ValueRange{offset});

        // Load as the result type
        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);

        rewriter.replaceOp(op, result);
        return success();
    }
};
```

### 3.3 ListTailOpLowering

```cpp
struct ListTailOpLowering : public OpConversionPattern<eco::ListTailOp> {
    // Similar to ListHeadOpLowering but offset = 16 (after Header + head)
    // Tail is always loaded as i64 (boxed pointer)
};
```

### 3.4 Tuple2ConstructOpLowering

```cpp
struct Tuple2ConstructOpLowering : public OpConversionPattern<eco::Tuple2ConstructOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult matchAndRewrite(eco::Tuple2ConstructOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value a = adaptor.getA();
        Value b = adaptor.getB();
        int64_t unboxedBitmap = op.getUnboxedBitmap();

        // Convert operands to ptr representation (raw 64-bit)
        Value aAsPtr = convertToPtr(rewriter, loc, a);
        Value bAsPtr = convertToPtr(rewriter, loc, b);

        auto unboxedMask = rewriter.create<LLVM::ConstantOp>(
            loc, i32Ty, static_cast<int32_t>(unboxedBitmap));

        // Call eco_alloc_tuple2(a, b, unboxed_mask)
        auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy, ptrTy, i32Ty});
        getOrInsertFunc(op->getParentOfType<ModuleOp>(), rewriter,
                        "eco_alloc_tuple2", funcTy);

        auto result = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_tuple2"),
            ValueRange{aAsPtr, bAsPtr, unboxedMask});

        rewriter.replaceOp(op, result.getResult());
        return success();
    }
};
```

### 3.5 Tuple2ProjectOpLowering

```cpp
struct Tuple2ProjectOpLowering : public OpConversionPattern<eco::Tuple2ProjectOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult matchAndRewrite(eco::Tuple2ProjectOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value tuple = adaptor.getTuple();
        int64_t field = op.getField();

        auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, tuple);

        // Tuple2 layout: Header (8) + a (8) + b (8)
        // Fields start at offset 8
        int64_t offsetBytes = 8 + field * 8;
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                     ValueRange{offset});

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);

        rewriter.replaceOp(op, result);
        return success();
    }
};
```

### 3.6 Tuple3ConstructOpLowering / Tuple3ProjectOpLowering

Similar to Tuple2 variants, with 3 fields and appropriate offsets.

### 3.7 RecordConstructOpLowering

```cpp
struct RecordConstructOpLowering : public OpConversionPattern<eco::RecordConstructOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult matchAndRewrite(eco::RecordConstructOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto module = op->getParentOfType<ModuleOp>();
        auto *ctx = rewriter.getContext();
        auto i32Ty = IntegerType::get(ctx, 32);
        auto i64Ty = IntegerType::get(ctx, 64);
        auto f64Ty = Float64Type::get(ctx);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);
        auto voidTy = LLVM::LLVMVoidType::get(ctx);

        int64_t fieldCount = op.getFieldCount();
        int64_t unboxedBitmap = op.getUnboxedBitmap();

        // Declare functions
        auto allocFuncTy = LLVM::LLVMFunctionType::get(ptrTy, {i32Ty, i64Ty});
        getOrInsertFunc(module, rewriter, "eco_alloc_record", allocFuncTy);

        auto storeFuncTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy, i32Ty, ptrTy});
        getOrInsertFunc(module, rewriter, "eco_store_record_field", storeFuncTy);

        auto storeI64FuncTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy, i32Ty, i64Ty});
        getOrInsertFunc(module, rewriter, "eco_store_record_field_i64", storeI64FuncTy);

        auto storeF64FuncTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy, i32Ty, f64Ty});
        getOrInsertFunc(module, rewriter, "eco_store_record_field_f64", storeF64FuncTy);

        // Allocate record
        auto fieldCountVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, fieldCount);
        auto bitmapVal = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, unboxedBitmap);

        auto recPtr = rewriter.create<LLVM::CallOp>(
            loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_record"),
            ValueRange{fieldCountVal, bitmapVal}).getResult();

        // Store each field
        ValueRange fields = adaptor.getFields();
        for (size_t i = 0; i < fields.size(); ++i) {
            Value field = fields[i];
            auto indexVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, i);

            bool isUnboxed = (unboxedBitmap >> i) & 1;
            if (isUnboxed) {
                // Store as primitive
                Type fieldTy = field.getType();
                if (fieldTy.isF64()) {
                    rewriter.create<LLVM::CallOp>(
                        loc, voidTy, SymbolRefAttr::get(ctx, "eco_store_record_field_f64"),
                        ValueRange{recPtr, indexVal, field});
                } else {
                    // i64, i16, i1 - extend to i64
                    Value asI64 = field;
                    if (!fieldTy.isInteger(64)) {
                        asI64 = rewriter.create<LLVM::ZExtOp>(loc, i64Ty, field);
                    }
                    rewriter.create<LLVM::CallOp>(
                        loc, voidTy, SymbolRefAttr::get(ctx, "eco_store_record_field_i64"),
                        ValueRange{recPtr, indexVal, asI64});
                }
            } else {
                // Store as boxed pointer
                rewriter.create<LLVM::CallOp>(
                    loc, voidTy, SymbolRefAttr::get(ctx, "eco_store_record_field"),
                    ValueRange{recPtr, indexVal, field});
            }
        }

        rewriter.replaceOp(op, recPtr);
        return success();
    }
};
```

### 3.8 RecordProjectOpLowering

```cpp
struct RecordProjectOpLowering : public OpConversionPattern<eco::RecordProjectOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult matchAndRewrite(eco::RecordProjectOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();
        auto i64Ty = IntegerType::get(ctx, 64);
        auto i8Ty = IntegerType::get(ctx, 8);
        auto ptrTy = LLVM::LLVMPointerType::get(ctx);

        Value record = adaptor.getRecord();
        int64_t fieldIndex = op.getFieldIndex();

        auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, record);

        // Record layout: Header (8) + unboxed (8) + values[]
        // Fields start at offset 16
        int64_t offsetBytes = 16 + fieldIndex * 8;
        auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
        auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr,
                                                     ValueRange{offset});

        Type resultType = getTypeConverter()->convertType(op.getResult().getType());
        Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);

        rewriter.replaceOp(op, result);
        return success();
    }
};
```

### 3.9 Register new patterns

Add to `populateEcoToLLVMConversionPatterns`:

```cpp
patterns.add<
    ListConsOpLowering,
    ListHeadOpLowering,
    ListTailOpLowering,
    Tuple2ConstructOpLowering,
    Tuple3ConstructOpLowering,
    Tuple2ProjectOpLowering,
    Tuple3ProjectOpLowering,
    RecordConstructOpLowering,
    RecordProjectOpLowering
>(typeConverter, patterns.getContext());
```

---

## Phase 4: Elm MLIR Codegen

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

### 4.1 Add new op builders

```elm
-- List operations
ecoListCons : Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> Bool -> ( Context, MlirOp )
ecoListCons ctx resultVar ( headVar, headTy ) ( tailVar, tailTy ) headUnboxed =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr headTy, TypeAttr tailTy ] )
                , ( "head_unboxed", BoolAttr headUnboxed )
                ]
    in
    mlirOp ctx "eco.cons.list"
        |> opBuilder.withOperands [ headVar, tailVar ]
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


ecoProjectListHead : Context -> String -> MlirType -> String -> ( Context, MlirOp )
ecoProjectListHead ctx resultVar resultType listVar =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr ecoValue ])
    in
    mlirOp ctx "eco.project.list_head"
        |> opBuilder.withOperands [ listVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


ecoProjectListTail : Context -> String -> String -> ( Context, MlirOp )
ecoProjectListTail ctx resultVar listVar =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr ecoValue ])
    in
    mlirOp ctx "eco.project.list_tail"
        |> opBuilder.withOperands [ listVar ]
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


-- Tuple operations
ecoConstructTuple2 : Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> Int -> ( Context, MlirOp )
ecoConstructTuple2 ctx resultVar ( aVar, aTy ) ( bVar, bTy ) unboxedBitmap =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr aTy, TypeAttr bTy ] )
                , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                ]
    in
    mlirOp ctx "eco.construct.tuple2"
        |> opBuilder.withOperands [ aVar, bVar ]
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


ecoConstructTuple3 : Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> ( String, MlirType ) -> Int -> ( Context, MlirOp )
ecoConstructTuple3 ctx resultVar ( aVar, aTy ) ( bVar, bTy ) ( cVar, cTy ) unboxedBitmap =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr aTy, TypeAttr bTy, TypeAttr cTy ] )
                , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                ]
    in
    mlirOp ctx "eco.construct.tuple3"
        |> opBuilder.withOperands [ aVar, bVar, cVar ]
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


ecoProjectTuple2 : Context -> String -> Int -> MlirType -> String -> ( Context, MlirOp )
ecoProjectTuple2 ctx resultVar field resultType tupleVar =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr ecoValue ] )
                , ( "field", IntAttr Nothing field )
                ]
    in
    mlirOp ctx "eco.project.tuple2"
        |> opBuilder.withOperands [ tupleVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


ecoProjectTuple3 : Context -> String -> Int -> MlirType -> String -> ( Context, MlirOp )
ecoProjectTuple3 ctx resultVar field resultType tupleVar =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr ecoValue ] )
                , ( "field", IntAttr Nothing field )
                ]
    in
    mlirOp ctx "eco.project.tuple3"
        |> opBuilder.withOperands [ tupleVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


-- Record operations
ecoConstructRecord : Context -> String -> Int -> Int -> List ( String, MlirType ) -> ( Context, MlirOp )
ecoConstructRecord ctx resultVar fieldCount unboxedBitmap fieldPairs =
    let
        operandTypesAttr =
            if List.isEmpty fieldPairs then
                Dict.empty
            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map (\( _, t ) -> TypeAttr t) fieldPairs))

        attrs =
            Dict.union operandTypesAttr
                (Dict.fromList
                    [ ( "field_count", IntAttr Nothing fieldCount )
                    , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                    ]
                )

        operandNames =
            List.map Tuple.first fieldPairs
    in
    mlirOp ctx "eco.construct.record"
        |> opBuilder.withOperands operandNames
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


ecoProjectRecord : Context -> String -> Int -> MlirType -> String -> ( Context, MlirOp )
ecoProjectRecord ctx resultVar fieldIndex resultType recordVar =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr ecoValue ] )
                , ( "field_index", IntAttr Nothing fieldIndex )
                ]
    in
    mlirOp ctx "eco.project.record"
        |> opBuilder.withOperands [ recordVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


-- Constant helpers
ecoConstantUnit : Context -> String -> ( Context, MlirOp )
ecoConstantUnit ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 1))
        |> opBuilder.build


ecoConstantNil : Context -> String -> ( Context, MlirOp )
ecoConstantNil ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 5))
        |> opBuilder.build
```

### 4.2 Update `generateList`

```elm
generateList : Context -> List Mono.MonoExpr -> ExprResult
generateList ctx items =
    case items of
        [] ->
            -- Use embedded Nil constant (HEAP_010)
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( ctx2, constOp ) =
                    ecoConstantNil ctx1 var
            in
            { ops = [ constOp ]
            , resultVar = var
            , resultType = ecoValue
            , ctx = ctx2
            }

        _ ->
            let
                -- Start from Nil constant
                ( nilVar, ctx1 ) =
                    freshVar ctx

                ( ctx2, nilOp ) =
                    ecoConstantNil ctx1 nilVar

                -- Build list right-to-left
                ( consOps, finalVar, finalCtx ) =
                    List.foldr
                        (\item ( accOps, tailVar, accCtx ) ->
                            let
                                result =
                                    generateExpr accCtx item

                                -- Determine if head should be unboxed
                                headUnboxed =
                                    not (isEcoValueType result.resultType)

                                ( headVar, headTy, boxOps, ctx3 ) =
                                    if headUnboxed then
                                        -- Keep unboxed
                                        ( result.resultVar, result.resultType, [], result.ctx )
                                    else
                                        -- Box to eco.value
                                        let
                                            ( ops, boxed, c ) =
                                                boxToEcoValue result.ctx result.resultVar result.resultType
                                        in
                                        ( boxed, ecoValue, ops, c )

                                ( consVar, ctx4 ) =
                                    freshVar ctx3

                                ( ctx5, consOp ) =
                                    ecoListCons ctx4 consVar
                                        ( headVar, headTy )
                                        ( tailVar, ecoValue )
                                        headUnboxed
                            in
                            ( accOps ++ result.ops ++ boxOps ++ [ consOp ]
                            , consVar
                            , ctx5
                            )
                        )
                        ( [], nilVar, ctx2 )
                        items
            in
            { ops = nilOp :: consOps
            , resultVar = finalVar
            , resultType = ecoValue
            , ctx = finalCtx
            }
```

### 4.3 Update `generateTupleCreate`

```elm
generateTupleCreate : Context -> List Mono.MonoExpr -> Mono.TupleLayout -> ExprResult
generateTupleCreate ctx elements layout =
    let
        ( elemOps, elemVarsWithTypes, ctx1 ) =
            generateExprListTyped ctx elements

        -- Process elements according to layout unboxed flags
        ( processedElems, ctx2 ) =
            List.map2 Tuple.pair elemVarsWithTypes layout.elements
                |> List.foldl
                    (\( ( var, ssaType ), ( _, isUnboxed ) ) ( acc, ctxAcc ) ->
                        if isUnboxed then
                            -- Keep as primitive
                            ( acc ++ [ ( var, ssaType ) ], ctxAcc )
                        else if isEcoValueType ssaType then
                            -- Already boxed
                            ( acc ++ [ ( var, ssaType ) ], ctxAcc )
                        else
                            -- Need to box
                            let
                                ( boxOps, boxedVar, ctxNew ) =
                                    boxToEcoValue ctxAcc var ssaType
                            in
                            ( acc ++ [ ( boxedVar, ecoValue ) ], ctxNew )
                    )
                    ( [], ctx1 )

        ( resultVar, ctx3 ) =
            freshVar ctx2
    in
    case layout.arity of
        2 ->
            let
                [ ( aVar, aTy ), ( bVar, bTy ) ] =
                    processedElems

                ( ctx4, constructOp ) =
                    ecoConstructTuple2 ctx3 resultVar ( aVar, aTy ) ( bVar, bTy ) layout.unboxedBitmap
            in
            { ops = elemOps ++ [ constructOp ]
            , resultVar = resultVar
            , resultType = ecoValue
            , ctx = ctx4
            }

        3 ->
            let
                [ ( aVar, aTy ), ( bVar, bTy ), ( cVar, cTy ) ] =
                    processedElems

                ( ctx4, constructOp ) =
                    ecoConstructTuple3 ctx3 resultVar ( aVar, aTy ) ( bVar, bTy ) ( cVar, cTy ) layout.unboxedBitmap
            in
            { ops = elemOps ++ [ constructOp ]
            , resultVar = resultVar
            , resultType = ecoValue
            , ctx = ctx4
            }

        _ ->
            Debug.crash "Unsupported tuple arity"
```

### 4.4 Update `generateRecordCreate`

```elm
generateRecordCreate : Context -> List Mono.MonoExpr -> Mono.RecordLayout -> ExprResult
generateRecordCreate ctx fields layout =
    let
        ( fieldsOps, fieldVarsWithTypes, ctx1 ) =
            generateExprListTyped ctx fields

        -- Process fields according to layout
        ( processedFields, ctx2 ) =
            List.map2 Tuple.pair fieldVarsWithTypes layout.fields
                |> List.foldl
                    (\( ( var, ssaType ), fieldInfo ) ( acc, ctxAcc ) ->
                        if fieldInfo.isUnboxed then
                            ( acc ++ [ ( var, ssaType ) ], ctxAcc )
                        else if isEcoValueType ssaType then
                            ( acc ++ [ ( var, ssaType ) ], ctxAcc )
                        else
                            let
                                ( boxOps, boxedVar, ctxNew ) =
                                    boxToEcoValue ctxAcc var ssaType
                            in
                            ( acc ++ [ ( boxedVar, ecoValue ) ], ctxNew )
                    )
                    ( [], ctx1 )

        ( resultVar, ctx3 ) =
            freshVar ctx2

        ( ctx4, constructOp ) =
            ecoConstructRecord ctx3 resultVar layout.fieldCount layout.unboxedBitmap processedFields
    in
    { ops = fieldsOps ++ [ constructOp ]
    , resultVar = resultVar
    , resultType = ecoValue
    , ctx = ctx4
    }
```

### 4.5 Update `generateRecordAccess`

```elm
generateRecordAccess : Context -> Mono.MonoExpr -> Name.Name -> Int -> Bool -> Mono.MonoType -> ExprResult
generateRecordAccess ctx record _ index isUnboxed fieldType =
    let
        recordResult =
            generateExpr ctx record

        ( projectVar, ctx1 ) =
            freshVar recordResult.ctx

        fieldMlirType =
            monoTypeToMlir fieldType

        resultType =
            if isUnboxed then
                fieldMlirType
            else
                ecoValue

        ( ctx2, projectOp ) =
            ecoProjectRecord ctx1 projectVar index resultType recordResult.resultVar
    in
    if isUnboxed || isEcoValueType fieldMlirType then
        { ops = recordResult.ops ++ [ projectOp ]
        , resultVar = projectVar
        , resultType = resultType
        , ctx = ctx2
        }
    else
        -- Need to unbox after projection
        let
            ( unboxOps, unboxedVar, ctx3 ) =
                unboxToType ctx2 projectVar fieldMlirType
        in
        { ops = recordResult.ops ++ [ projectOp ] ++ unboxOps
        , resultVar = unboxedVar
        , resultType = fieldMlirType
        , ctx = ctx3
        }
```

### 4.6 Implement `generateRecordUpdate` (copy-update)

```elm
generateRecordUpdate : Context -> Mono.MonoExpr -> List ( Int, Mono.MonoExpr ) -> Mono.RecordLayout -> ExprResult
generateRecordUpdate ctx record updates layout =
    let
        -- Evaluate base record
        baseResult =
            generateExpr ctx record

        updateDict =
            Dict.fromList updates

        -- For each field: use update if present, else project from base
        ( fieldOps, fieldVars, ctx1 ) =
            layout.fields
                |> List.indexedMap Tuple.pair
                |> List.foldl
                    (\( idx, fieldInfo ) ( opsAcc, varsAcc, ctxAcc ) ->
                        case Dict.get idx updateDict of
                            Just updateExpr ->
                                -- Use the update expression
                                let
                                    updateResult =
                                        generateExpr ctxAcc updateExpr
                                in
                                ( opsAcc ++ updateResult.ops
                                , varsAcc ++ [ ( updateResult.resultVar, updateResult.resultType ) ]
                                , updateResult.ctx
                                )

                            Nothing ->
                                -- Project from base record
                                let
                                    ( projVar, ctxP1 ) =
                                        freshVar ctxAcc

                                    resultType =
                                        if fieldInfo.isUnboxed then
                                            monoTypeToMlir fieldInfo.monoType
                                        else
                                            ecoValue

                                    ( ctxP2, projOp ) =
                                        ecoProjectRecord ctxP1 projVar idx resultType baseResult.resultVar
                                in
                                ( opsAcc ++ [ projOp ]
                                , varsAcc ++ [ ( projVar, resultType ) ]
                                , ctxP2
                                )
                    )
                    ( baseResult.ops, [], baseResult.ctx )

        -- Construct new record with collected fields
        ( resultVar, ctx2 ) =
            freshVar ctx1

        ( ctx3, constructOp ) =
            ecoConstructRecord ctx2 resultVar layout.fieldCount layout.unboxedBitmap fieldVars
    in
    { ops = fieldOps ++ [ constructOp ]
    , resultVar = resultVar
    , resultType = ecoValue
    , ctx = ctx3
    }
```

### 4.7 Update `generateUnit`

```elm
generateUnit : Context -> ExprResult
generateUnit ctx =
    let
        ( var, ctx1 ) =
            freshVar ctx

        ( ctx2, constOp ) =
            ecoConstantUnit ctx1 var
    in
    { ops = [ constOp ]
    , resultVar = var
    , resultType = ecoValue
    , ctx = ctx2
    }
```

### 4.8 Update `createDummyValue` and `generateStubValue`

Replace `eco.construct` for dummy values with `eco.constant Unit`:

```elm
createDummyValue : Context -> MlirType -> ( List MlirOp, String, Context )
createDummyValue ctx mlirType =
    let
        ( resultVar, ctx1 ) =
            freshVar ctx
    in
    if mlirType == I64 then
        -- Return 0 for i64
        ...
    else if mlirType == F64 then
        -- Return 0.0 for f64
        ...
    else
        -- For ecoValue and other types, use Unit constant
        let
            ( ctx2, constOp ) =
                ecoConstantUnit ctx1 resultVar
        in
        ( [ constOp ], resultVar, ctx2 )
```

### 4.9 Update `generateMonoPath` for type-specific projections

```elm
generateMonoPath : Context -> Mono.MonoPath -> String -> MlirType -> ( List MlirOp, String, MlirType, Context )
generateMonoPath ctx path containerVar containerType =
    case path of
        Mono.MonoHere ->
            ( [], containerVar, containerType, ctx )

        Mono.MonoIndex index subPath containerMonoType ->
            let
                -- Determine projection op based on container type
                ( projOps, projVar, projType, ctx1 ) =
                    case containerMonoType of
                        Mono.MList elemType ->
                            let
                                ( pVar, ctxP ) = freshVar ctx
                                elemMlirType = monoTypeToMlir elemType
                            in
                            if index == 0 then
                                -- Head
                                let
                                    ( ctxOp, op ) = ecoProjectListHead ctxP pVar elemMlirType containerVar
                                in
                                ( [ op ], pVar, elemMlirType, ctxOp )
                            else
                                -- Tail (index == 1)
                                let
                                    ( ctxOp, op ) = ecoProjectListTail ctxP pVar containerVar
                                in
                                ( [ op ], pVar, ecoValue, ctxOp )

                        Mono.MTuple layout ->
                            let
                                ( pVar, ctxP ) = freshVar ctx
                                ( elemType, isUnboxed ) =
                                    List.drop index layout.elements |> List.head |> Maybe.withDefault ( Mono.MUnit, False )
                                elemMlirType =
                                    if isUnboxed then monoTypeToMlir elemType else ecoValue
                            in
                            if layout.arity == 2 then
                                let ( ctxOp, op ) = ecoProjectTuple2 ctxP pVar index elemMlirType containerVar
                                in ( [ op ], pVar, elemMlirType, ctxOp )
                            else
                                let ( ctxOp, op ) = ecoProjectTuple3 ctxP pVar index elemMlirType containerVar
                                in ( [ op ], pVar, elemMlirType, ctxOp )

                        Mono.MRecord layout ->
                            let
                                ( pVar, ctxP ) = freshVar ctx
                                fieldInfo =
                                    List.drop index layout.fields |> List.head
                                fieldMlirType =
                                    case fieldInfo of
                                        Just fi -> if fi.isUnboxed then monoTypeToMlir fi.monoType else ecoValue
                                        Nothing -> ecoValue
                                ( ctxOp, op ) = ecoProjectRecord ctxP pVar index fieldMlirType containerVar
                            in
                            ( [ op ], pVar, fieldMlirType, ctxOp )

                        Mono.MCustom _ _ _ ->
                            -- Use generic eco.project for Custom ADTs
                            let
                                ( pVar, ctxP ) = freshVar ctx
                                ( ctxOp, op ) = ecoProject ctxP pVar index ecoValue False containerVar
                            in
                            ( [ op ], pVar, ecoValue, ctxOp )

                        _ ->
                            -- Fallback for MVar CEcoValue or unknown
                            let
                                ( pVar, ctxP ) = freshVar ctx
                                ( ctxOp, op ) = ecoProject ctxP pVar index ecoValue False containerVar
                            in
                            ( [ op ], pVar, ecoValue, ctxOp )

                -- Continue with subpath
                ( subOps, finalVar, finalType, ctx2 ) =
                    generateMonoPath ctx1 subPath projVar projType
            in
            ( projOps ++ subOps, finalVar, finalType, ctx2 )
```

---

## Phase 5: Invariant Enforcement

### 5.1 MONO_002: Crash on CNumber at codegen

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

```elm
monoTypeToMlir : Mono.MonoType -> MlirType
monoTypeToMlir monoType =
    case monoType of
        -- ... other cases ...

        Mono.MVar _ constraint_ ->
            case constraint_ of
                Mono.CNumber ->
                    Debug.crash "CNumber at codegen time indicates monomorphization bug (MONO_002)"

                Mono.CEcoValue ->
                    ecoValue
```

### 5.2 CGEN_001: Crash on type mismatch in boxToMatchSignatureTyped

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

```elm
boxToMatchSignatureTyped ctx actualArgs expectedTypes =
    let
        helper ( ( var, actualTy ), expectedTy ) ( opsAcc, pairsAcc, ctxAcc ) =
            let
                expectedMlirTy =
                    monoTypeToMlir expectedTy
            in
            if expectedMlirTy == actualTy then
                ( opsAcc, pairsAcc ++ [ ( var, actualTy ) ], ctxAcc )

            else if isEcoValueType expectedMlirTy && not (isEcoValueType actualTy) then
                -- Box primitive to eco.value
                let
                    ( boxOps, boxedVar, ctx1 ) =
                        boxToEcoValue ctxAcc var actualTy
                in
                ( opsAcc ++ boxOps, pairsAcc ++ [ ( boxedVar, ecoValue ) ], ctx1 )

            else if not (isEcoValueType expectedMlirTy) && isEcoValueType actualTy then
                -- Unbox eco.value to primitive
                let
                    ( unboxOps, unboxedVar, ctx1 ) =
                        unboxToType ctxAcc var expectedMlirTy
                in
                ( opsAcc ++ unboxOps, pairsAcc ++ [ ( unboxedVar, expectedMlirTy ) ], ctx1 )

            else
                -- Type mismatch that can't be resolved by boxing/unboxing
                Debug.crash
                    ("Type mismatch in boxToMatchSignatureTyped: expected "
                        ++ Debug.toString expectedMlirTy
                        ++ " but got "
                        ++ Debug.toString actualTy
                    )
    in
    List.foldl helper ( [], [], ctx ) (List.map2 Tuple.pair actualArgs expectedTypes)
```

---

## Implementation Order

1. **Phase 1**: Runtime allocators (C++)
2. **Phase 2**: Ops.td definitions (TableGen)
3. **Phase 3**: LLVM lowerings (C++)
4. **Phase 5.1-5.2**: Invariant enforcement in MLIR.elm (can catch bugs early)
5. **Phase 4**: Elm codegen updates (depends on Ops.td being compiled)

Within Phase 4, recommended order:
1. Add op builders (4.1)
2. Add constant helpers (ecoConstantUnit, ecoConstantNil)
3. Update generateUnit (4.7) and createDummyValue (4.8)
4. Update generateList (4.2)
5. Update generateTupleCreate (4.3)
6. Update generateRecordCreate (4.4)
7. Update generateRecordAccess (4.5)
8. Implement generateRecordUpdate (4.6)
9. Update generateMonoPath (4.9)

---

## Testing Strategy

1. **Runtime unit tests**: Verify each allocator produces correct Tag and layout
2. **MLIR roundtrip tests**: Verify new ops parse/print correctly
3. **Integration tests**: Compile Elm programs using lists/tuples/records
4. **GC property tests**: Extend RapidCheck to stress list/tuple/record allocation with GC cycles
5. **Regression tests**: Ensure existing Elm programs still compile and run correctly

---

## Estimated Scope

| Component | Lines Changed |
|-----------|---------------|
| RuntimeExports.cpp | ~80 |
| Ops.td | ~120 |
| EcoToLLVM.cpp | ~350 |
| MLIR.elm | ~400 |
| **Total** | ~950 |

---

## Risks and Mitigations

1. **Risk**: Breaking existing code that relies on `eco.construct` for tuples/records
   - **Mitigation**: Update all codegen paths in MLIR.elm before removing old behavior

2. **Risk**: Unboxed bitmap inconsistency between MLIR and runtime
   - **Mitigation**: Debug assertions in lowering to verify bitmap matches SSA types

3. **Risk**: GC corruption if layout mismatch persists
   - **Mitigation**: Add runtime debug checks in allocators; run GC stress tests

4. **Risk**: Performance regression from additional runtime calls
   - **Mitigation**: Keep allocators simple; consider inlining in lowering later
