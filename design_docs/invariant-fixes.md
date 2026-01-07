Below is a concrete design + patch sketch that an engineer can follow. I’ll group changes by file/module and tie each to the invariants you flagged (MONO_002, CGEN_001, HEAP_010, HEAP_013 and the layout/tag discipline).

I’m extrapolating some C++ details (e.g. `Record` struct fields, `RuntimeExports.cpp` internals) based on your earlier snippets and the allocator utilities in `AllocatorCommon.hpp`; you will need to align them with the actual definitions in `Heap.hpp` and `RuntimeExports.cpp`. The Elm/MLIR pieces are grounded in the provided MLIR backend file and Ops.td.

---

## 0. High‑level goal / invariant

**Heap invariant H (strong)**:  
For every heap object, the header tag (`Header.tag`) and the in‑memory layout must match the concrete runtime type:

- `Tag_Cons` ↔ `Cons` struct layout
- `Tag_Tuple2` ↔ `Tuple2` struct
- `Tag_Tuple3` ↔ `Tuple3` struct
- `Tag_Record` ↔ `Record` struct
- `Tag_Custom` ↔ `Custom` struct
- … (others unchanged)

No lists, tuples or records may be allocated as `Custom`.

`getObjectSize` and the GC walkers already assume this tag→layout bijection ; this design makes the compiler and runtime obey it.

---

## 1. Eco MLIR ops: introduce layout‑specific operations

**File:** `runtime/src/codegen/Ops.td` (you have this as `Ops.td.txt`)

### 1.1. List construction / projections

Add new ops for list construction and projections:

```tablegen
//===----------------------------------------------------------------------===//
// 3.x List Operations (Cons / Nil)
//===----------------------------------------------------------------------===//

def Eco_ListConstructOp : Eco_Op<"construct.list", [Pure]> {
  let summary = "Construct a list Cons cell";
  let description = [{
    Allocate a list cons cell: head :: tail.

    Head and tail are both boxed Elm values (!eco.value). Nil is represented
    as an embedded constant via `eco.constant Nil`, not heap-allocated.

    Example:
    ```mlir
    %list = eco.construct.list %head, %tail : !eco.value, !eco.value -> !eco.value
    ```
  }];

  let arguments = (ins Eco_Value:$head, Eco_Value:$tail);
  let results   = (outs Eco_Value:$result);

  let assemblyFormat = "$head `,` $tail attr-dict `:` type($head) `,` type($tail) `->` type($result)";
}

def Eco_ListHeadOp : Eco_Op<"project.list_head", [Pure]> {
  let summary = "Project head of a list Cons cell";
  let description = [{
    Project the head field of a non-empty list (Cons cell).

    Example:
    ```mlir
    %head = eco.project.list_head %list : !eco.value -> !eco.value
    ```
  }];

  let arguments = (ins Eco_Value:$list);
  let results   = (outs Eco_Value:$head);

  let assemblyFormat = "$list attr-dict `:` type($list) `->` type($head)";
}

def Eco_ListTailOp : Eco_Op<"project.list_tail", [Pure]> {
  let summary = "Project tail of a list Cons cell";
  let description = [{
    Project the tail field of a non-empty list (Cons cell).

    Example:
    ```mlir
    %tail = eco.project.list_tail %list : !eco.value -> !eco.value
    ```
  }];

  let arguments = (ins Eco_Value:$list);
  let results   = (outs Eco_Value:$tail);

  let assemblyFormat = "$list attr-dict `:` type($list) `->` type($tail)";
}
```

### 1.2. Tuples

```tablegen
//===----------------------------------------------------------------------===//
// 3.y Tuple Operations
//===----------------------------------------------------------------------===//

def Eco_Tuple2ConstructOp : Eco_Op<"construct.tuple2", [Pure]> {
  let summary = "Construct a 2-tuple";
  let description = [{
    Construct a 2-tuple value.

    Elements may be boxed (!eco.value) or unboxed primitives depending on
    the calling convention chosen by the compiler; the `_operand_types`
    attribute carries the exact SSA types for GC and debugging.
  }];

  let arguments = (ins Eco_AnyValue:$a, Eco_AnyValue:$b);
  let results   = (outs Eco_Value:$result);

  let assemblyFormat = "$a `,` $b attr-dict `:` type($a) `,` type($b) `->` type($result)";
}

def Eco_Tuple3ConstructOp : Eco_Op<"construct.tuple3", [Pure]> {
  let summary = "Construct a 3-tuple";
  let description = [{
    Construct a 3-tuple value.
  }];

  let arguments = (ins Eco_AnyValue:$a, Eco_AnyValue:$b, Eco_AnyValue:$c);
  let results   = (outs Eco_Value:$result);

  let assemblyFormat =
    "$a `,` $b `,` $c attr-dict `:` type($a) `,` type($b) `,` type($c) `->` type($result)";
}

def Eco_Tuple2ProjectOp : Eco_Op<"project.tuple2", [Pure]> {
  let summary = "Project field of a 2-tuple";
  let description = [{
    Project element 0 or 1 from a 2-tuple.

    The `field` attribute selects which element (0 or 1). The result type
    is the concrete SSA type (primitive or !eco.value).
  }];

  let arguments = (ins Eco_Value:$tuple);
  let results   = (outs Eco_AnyValue:$result);

  let argumentsAttrs = (ins I32Attr:$field);

  let assemblyFormat =
    "$tuple attr-dict `:` type($tuple) `->` type($result)";
}

def Eco_Tuple3ProjectOp : Eco_Op<"project.tuple3", [Pure]> {
  let summary = "Project field of a 3-tuple";
  let description = [{
    Project element 0, 1 or 2 from a 3-tuple.
  }];

  let arguments = (ins Eco_Value:$tuple);
  let results   = (outs Eco_AnyValue:$result);

  let argumentsAttrs = (ins I32Attr:$field);

  let assemblyFormat =
    "$tuple attr-dict `:` type($tuple) `->` type($result)";
}
```

### 1.3. Records

```tablegen
//===----------------------------------------------------------------------===//
// 3.z Record Operations
//===----------------------------------------------------------------------===//

def Eco_RecordConstructOp : Eco_Op<"construct.record", [Pure]> {
  let summary = "Construct an Elm record";
  let description = [{
    Construct a record with a fixed set of fields.

    The `field_count` and `unboxed_bitmap` attributes describe layout. The
    actual operand SSA types are advertised via `_operand_types`.
  }];

  let arguments = (ins Variadic<Eco_AnyValue>:$fields);
  let results   = (outs Eco_Value:$result);

  let argumentsAttrs = (ins I32Attr:$field_count, I32Attr:$unboxed_bitmap);

  let assemblyFormat =
    "($fields^ `:` type($fields))? attr-dict `:` type($result)";
}

def Eco_RecordProjectOp : Eco_Op<"project.record", [Pure]> {
  let summary = "Project a record field";
  let description = [{
    Project the field at a given index from a record.

    The `field_index` attribute selects which field; `unboxed` indicates
    whether the field is stored unboxed.
  }];

  let arguments = (ins Eco_Value:$record);
  let results   = (outs Eco_AnyValue:$result);

  let argumentsAttrs = (ins I32Attr:$field_index, BoolAttr:$unboxed);

  let assemblyFormat =
    "$record attr-dict `:` type($record) `->` type($result)";
}
```

### 1.4. Rename `eco.construct` → `eco.construct.custom` and `eco.project` → `eco.project.custom`

**IMPORTANT**: The generic `eco.construct` and `eco.project` ops are being **removed**. All construction and projection must use type-specific ops.

Rename the existing `Eco_ConstructOp` and `Eco_ProjectOp` to `Eco_CustomConstructOp` and `Eco_CustomProjectOp`:

```tablegen
//===----------------------------------------------------------------------===//
// Custom ADT Operations (user-defined algebraic data types)
//===----------------------------------------------------------------------===//

def Eco_CustomConstructOp : Eco_Op<"construct.custom", [Pure]> {
  let summary = "Construct a custom ADT value";
  let description = [{
    Create a custom algebraic data type (ADT) value for a user-defined type.
    This is ONLY for custom ADTs (Maybe, Result, user types), NOT for:
    - Lists (use eco.construct.list)
    - Tuples (use eco.construct.tuple2, eco.construct.tuple3)
    - Records (use eco.construct.record)

    Example:
    ```mlir
    %just = eco.construct.custom(%inner) {tag = 1, size = 1} : (!eco.value) -> !eco.value
    ```
  }];
  // ... existing attributes ...
}

def Eco_CustomProjectOp : Eco_Op<"project.custom", [Pure]> {
  let summary = "Project field from custom ADT value";
  let description = [{
    Project a field out of a custom ADT value by index.
    This is ONLY for custom ADTs, NOT for lists/tuples/records.

    Example:
    ```mlir
    %inner = eco.project.custom %just[0] : !eco.value -> !eco.value
    ```
  }];
  // ... existing attributes ...
}
```

**Migration required**: All existing uses of `eco.construct` and `eco.project` must be updated:
- Lists → `eco.construct.list`, `eco.project.list_head`, `eco.project.list_tail`
- Tuples → `eco.construct.tuple2`/`tuple3`, `eco.project.tuple2`/`tuple3`
- Records → `eco.construct.record`, `eco.project.record`
- Custom ADTs → `eco.construct.custom`, `eco.project.custom`

**Intent**:
After these changes, there is **no generic `eco.construct` or `eco.project`**. Each heap type has its own dedicated ops that encode the correct layout assumptions.

---

## 2. MLIR→LLVM lowerings for the new ops

**File:** `runtime/src/codegen/Passes/EcoToLLVM.cpp` (declared in `Passes.h` as part of `createHeapOpsToLLVMPass` )

You already have patterns lowering eco heap ops (`construct`, `project`, `allocate_*`, `box`, `unbox`) via `populateEcoHeapOpsToLLVMPatterns`.  Extend that function with additional patterns.

Below I show skeletons; you’ll adapt to your existing style and helper utilities.

### 2.1. List construction / projections

```cpp
struct ListConstructOpLowering : public ConvertOpToLLVMPattern<eco::ListConstructOp> {
  using Base = ConvertOpToLLVMPattern<eco::ListConstructOp>;
  using Base::Base;

  LogicalResult
  matchAndRewrite(eco::ListConstructOp op, OpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    MLIRContext *ctx = op->getContext();

    // head and tail are already converted to llvm.ptr<i8> (eco.value)
    Value head = adaptor.getHead();
    Value tail = adaptor.getTail();

    // Call runtime: extern "C" void* eco_alloc_cons(void* head, void* tail);
    auto i8PtrTy = LLVM::LLVMPointerType::get(IntegerType::get(ctx, 8));
    auto callee  = rewriter.getSymbolRefAttr("eco_alloc_cons");
    auto result  = rewriter.create<LLVM::CallOp>(
        loc, i8PtrTy, callee, ValueRange{head, tail});

    rewriter.replaceOp(op, result.getResult());
    return success();
  }
};

struct ListHeadOpLowering : public ConvertOpToLLVMPattern<eco::ListHeadOp> {
  using Base = ConvertOpToLLVMPattern<eco::ListHeadOp>;
  using Base::Base;

  LogicalResult
  matchAndRewrite(eco::ListHeadOp op, OpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    auto tuplePtr = adaptor.getList(); // !llvm.ptr<i8>

    // Cast to Cons* and load head field.
    auto consPtrTy = ...; // LLVM struct type for Cons*
    Value consPtr = rewriter.create<LLVM::BitcastOp>(loc, consPtrTy, tuplePtr);

    // GEP to head field at offset 0 in Cons struct body.
    // (Implement using your existing layout helper)
    Value headPtr = /* llvm.getelementptr %consPtr[0, <field_index_for_head>] */;
    Value head = rewriter.create<LLVM::LoadOp>(loc, headPtr);

    rewriter.replaceOp(op, head);
    return success();
  }
};

// Similar for Eco_ListTailOpLowering reading tail field.
```

### 2.2. Tuples

```cpp
struct Tuple2ConstructOpLowering
    : public ConvertOpToLLVMPattern<eco::Tuple2ConstructOp> {
  using Base = ConvertOpToLLVMPattern<eco::Tuple2ConstructOp>;
  using Base::Base;

  LogicalResult
  matchAndRewrite(eco::Tuple2ConstructOp op, OpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    MLIRContext *ctx = op->getContext();

    Value a = adaptor.getA();
    Value b = adaptor.getB();

    auto i8PtrTy = LLVM::LLVMPointerType::get(IntegerType::get(ctx, 8));
    auto callee  = rewriter.getSymbolRefAttr("eco_alloc_tuple2");
    Value tuple  = rewriter
                       .create<LLVM::CallOp>(loc, i8PtrTy, callee,
                                             ValueRange{a, b})
                       .getResult(0);

    rewriter.replaceOp(op, tuple);
    return success();
  }
};

struct Tuple2ProjectOpLowering
    : public ConvertOpToLLVMPattern<eco::Tuple2ProjectOp> {
  using Base = ConvertOpToLLVMPattern<eco::Tuple2ProjectOp>;
  using Base::Base;

  LogicalResult
  matchAndRewrite(eco::Tuple2ProjectOp op, OpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    MLIRContext *ctx = op->getContext();

    int32_t fieldIndex = op.getField().getInt(); // 0 or 1
    Value tuple = adaptor.getTuple();

    auto tupleTy   = /* LLVM struct type for Tuple2 */;
    auto tuplePtr  = rewriter.create<LLVM::BitcastOp>(loc, tupleTy, tuple);
    Value fieldPtr = /* GEP to correct element */;
    Value field    = rewriter.create<LLVM::LoadOp>(loc, fieldPtr);

    rewriter.replaceOp(op, field);
    return success();
  }
};

// Similarly for Tuple3ConstructOpLowering, Tuple3ProjectOpLowering
// using eco_alloc_tuple3 and Tuple3 layout.
```

### 2.3. Records

Records mirror your `Custom` lowering, but use `Tag_Record` and `Record` struct/layout:

```cpp
struct RecordConstructOpLowering
    : public ConvertOpToLLVMPattern<eco::RecordConstructOp> {
  using Base = ConvertOpToLLVMPattern<eco::RecordConstructOp>;
  using Base::Base;

  LogicalResult
  matchAndRewrite(eco::RecordConstructOp op, OpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    MLIRContext *ctx = op->getContext();

    int32_t fieldCount =
        op.getField_count().getInt(); // from attribute
    int32_t unboxedBitmap =
        op.getUnboxed_bitmap().getInt();

    ValueRange fields = adaptor.getFields(); // already converted to LLVM types
    // If you need a unified allocator:
    auto i8PtrTy = LLVM::LLVMPointerType::get(IntegerType::get(ctx, 8));
    auto callee  = rewriter.getSymbolRefAttr("eco_alloc_record");
    auto recPtr  = rewriter
                       .create<LLVM::CallOp>(
                           loc, i8PtrTy, callee,
                           /*args, e.g. fieldCount, unboxedBitmap, plus scalars*/)
                       .getResult(0);

    // Store each field into Record's values[] according to layout offsets.

    rewriter.replaceOp(op, recPtr);
    return success();
  }
};

struct RecordProjectOpLowering
    : public ConvertOpToLLVMPattern<eco::RecordProjectOp> {
  using Base = ConvertOpToLLVMPattern<eco::RecordProjectOp>;
  using Base::Base;

  LogicalResult
  matchAndRewrite(eco::RecordProjectOp op, OpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    int32_t index = op.getField_index().getInt();
    bool unboxed  = op.getUnboxed();

    Value record = adaptor.getRecord();

    auto recPtrTy = /* LLVM struct type for Record* */;
    Value recPtr  = rewriter.create<LLVM::BitcastOp>(loc, recPtrTy, record);
    Value fieldPtr =
        /* GEP into Record layout at index (taking unboxedBitmap into account) */;
    Value field = rewriter.create<LLVM::LoadOp>(loc, fieldPtr);

    rewriter.replaceOp(op, field);
    return success();
  }
};
```

### 2.4. Register the new patterns

In `populateEcoHeapOpsToLLVMPatterns` (declared in `Passes.h` ), add:

```cpp
void populateEcoHeapOpsToLLVMPatterns(TypeConverter &typeConverter,
                                       RewritePatternSet &patterns) {
  using namespace eco;

  // NOTE: ConstructOpLowering and ProjectOpLowering are REMOVED.
  // They are replaced by type-specific lowerings below.

  patterns.add<
      // List ops
      ListConstructOpLowering,
      ListHeadOpLowering,
      ListTailOpLowering,
      // Tuple ops
      Tuple2ConstructOpLowering,
      Tuple3ConstructOpLowering,
      Tuple2ProjectOpLowering,
      Tuple3ProjectOpLowering,
      // Record ops
      RecordConstructOpLowering,
      RecordProjectOpLowering,
      // Custom ADT ops (renamed from generic construct/project)
      CustomConstructOpLowering,
      CustomProjectOpLowering
  >(typeConverter, patterns.getContext());
}
```

---

## 3. Runtime allocators: remove “all‑Custom” and add Record allocator

**Files:**

- `runtime/src/allocator/Heap.hpp` (for struct/layout + Tag enums)
- `runtime/src/allocator/AllocatorCommon.hpp` (already uses Tag_Tuple2, Tag_Cons, Tag_Custom, Tag_Record in `getObjectSize`)
- `runtime/src/allocator/RuntimeExports.cpp` (C API used by lowering; already linked in CMake)

### 3.1. Verify type/tag mapping is 1:1

In `Heap.hpp`:

- Ensure you have distinct structs: `Cons`, `Tuple2`, `Tuple3`, `Record`, `Custom` and `Header` at offset 0, as described in your report.
- Ensure `enum Tag` matches the intended tag values: Int=0, Float=1, …, Cons=6, Custom=7, Record=8, etc. (per your initial table).

No code change here beyond verifying those definitions are consistent with `getObjectSize` (which already does a `switch(hdr->tag)` and uses `sizeof(Tuple2)`, `sizeof(Cons)`, `sizeof(Custom) + hdr->size * sizeof(Unboxable)`, etc.)

### 3.2. Enforce tag/layout discipline in allocators

In `RuntimeExports.cpp`:

1. **Lists (`eco_alloc_cons`)**  
   Ensure it allocates a `Cons` object with `Tag_Cons` using `Allocator::allocate(size, Tag_Cons)` and initializes only the `Cons` struct:

   ```cpp
   extern "C" void* eco_alloc_cons(void* head, void* tail) {
       using namespace Elm;

       size_t size  = sizeof(Cons);
       void* obj    = Allocator::instance().allocate(size, Tag_Cons);
       auto* cons   = static_cast<Cons*>(obj);

       cons->head   = Allocator::toPointerRaw(head);
       cons->tail   = Allocator::toPointerRaw(tail);

       return obj;
   }
   ```

   This must **not** go through `eco_alloc_custom`.

2. **Tuples (`eco_alloc_tuple2`, `eco_alloc_tuple3`)**  
   Similar pattern:

   ```cpp
   extern "C" void* eco_alloc_tuple2(void* a, void* b) {
       using namespace Elm;

       size_t size = sizeof(Tuple2);
       void* obj   = Allocator::instance().allocate(size, Tag_Tuple2);
       auto* tup   = static_cast<Tuple2*>(obj);

       tup->a = Allocator::toPointerRaw(a);
       tup->b = Allocator::toPointerRaw(b);

       return obj;
   }

   extern "C" void* eco_alloc_tuple3(void* a, void* b, void* c) {
       using namespace Elm;

       size_t size = sizeof(Tuple3);
       void* obj   = Allocator::instance().allocate(size, Tag_Tuple3);
       auto* tup   = static_cast<Tuple3*>(obj);

       tup->a = Allocator::toPointerRaw(a);
       tup->b = Allocator::toPointerRaw(b);
       tup->c = Allocator::toPointerRaw(c);

       return obj;
   }
   ```

3. **Records (`eco_alloc_record`)**  
   Add a dedicated allocator for records:

   ```cpp
   extern "C" void* eco_alloc_record(uint32_t field_count,
                                     uint32_t unboxed_bitmap,
                                     uint32_t scalar_bytes) {
       using namespace Elm;

       size_t size = sizeof(Record)
                   + field_count * sizeof(Unboxable)
                   + scalar_bytes;

       void* obj = Allocator::instance().allocate(size, Tag_Record);
       auto* rec = static_cast<Record*>(obj);

       rec->field_count    = field_count;
       rec->unboxed_bitmap = unboxed_bitmap;
       // Zero or init rec->values[] and scalar tail as appropriate.

       return obj;
   }
   ```

   Match this to your actual `Record` struct fields.

4. **Custom ADTs (`eco_alloc_custom`)**  
   Keep this **only** for `Custom` types:

    - It must allocate a `Custom` object with `Tag_Custom`.
    - It must **not** be used for lists/tuples/records anywhere in MLIR lowering.

5. **(Optional) Debug assertions**

   In debug builds, add runtime checks such as:

   ```cpp
   #ifndef NDEBUG
   {
       auto* hdr = Elm::getHeader(obj);
       assert(hdr->tag == Tag_Cons && "eco_alloc_cons: wrong header tag!");
   }
   #endif
   ```

   Likewise for tuples and records. This enforces HEAP_013 by construction.

---

## 4. Elm MLIR codegen: use new ops + correct constants

**File:** `compiler/src/Compiler/Generate/CodeGen/MLIR.elm` (you have it as `MLIR.elm.txt`)

### 4.1. New eco op builders

**NOTE**: The existing `ecoConstruct` and `ecoProject` helpers must be **removed** or renamed. Replace them with type-specific builders.

Add helpers for type-specific construction:

```elm
-- List construction (replaces ecoConstruct for lists)
ecoConstructList : Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> ( Context, MlirOp )
ecoConstructList ctx resultVar ( headVar, headTy ) ( tailVar, tailTy ) =
    let
        operandTypesAttr =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr headTy, TypeAttr tailTy ])

        attrs =
            operandTypesAttr
    in
    mlirOp ctx "eco.construct.list"
        |> opBuilder.withOperands [ headVar, tailVar ]
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


ecoProjectListHead : Context -> String -> String -> ( Context, MlirOp )
ecoProjectListHead ctx resultVar listVar =
    let
        attrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr ecoValue ])
    in
    mlirOp ctx "eco.project.list_head"
        |> opBuilder.withOperands [ listVar ]
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


ecoProjectListTail : Context -> String -> String -> ( Context, MlirOp )
ecoProjectListTail ctx resultVar listVar =
    let
        attrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr ecoValue ])
    in
    mlirOp ctx "eco.project.list_tail"
        |> opBuilder.withOperands [ listVar ]
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build
```

Similarly add builders for tuples and records:

```elm
-- Tuple construction
ecoConstructTuple2 :
    Context -> String -> ( String, MlirType ) -> ( String, MlirType )
    -> ( Context, MlirOp )
ecoConstructTuple2 ctx resultVar ( aVar, aTy ) ( bVar, bTy ) =
    let
        operandTypesAttr =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr aTy, TypeAttr bTy ])
    in
    mlirOp ctx "eco.construct.tuple2"
        |> opBuilder.withOperands [ aVar, bVar ]
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs operandTypesAttr
        |> opBuilder.build

-- eco.construct.tuple3, eco.project.tuple2, eco.project.tuple3 similarly...

-- Custom ADT construction (renamed from ecoConstruct)
ecoConstructCustom :
    Context -> String -> Int -> Int -> Int -> List ( String, MlirType ) -> Maybe Int -> Maybe String
    -> ( Context, MlirOp )
ecoConstructCustom ctx resultVar tag size unboxedBitmap fieldPairs typeId constructor =
    -- Same implementation as old ecoConstruct, but emits "eco.construct.custom"
    mlirOp ctx "eco.construct.custom"
        |> opBuilder.withOperands (List.map Tuple.first fieldPairs)
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs (buildCustomAttrs tag size unboxedBitmap typeId constructor fieldPairs)
        |> opBuilder.build

-- Custom ADT projection (renamed from ecoProject)
ecoProjectCustom :
    Context -> String -> Int -> MlirType -> Bool -> String
    -> ( Context, MlirOp )
ecoProjectCustom ctx resultVar index resultType isUnboxed containerVar =
    -- Same implementation as old ecoProject, but emits "eco.project.custom"
    mlirOp ctx "eco.project.custom"
        |> opBuilder.withOperands [ containerVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs (buildProjectAttrs index isUnboxed)
        |> opBuilder.build
```

```elm
ecoConstructRecord :
    Context
    -> String
    -> Int
    -> Int
    -> List ( String, MlirType )
    -> ( Context, MlirOp )
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


ecoProjectRecord :
    Context
    -> String
    -> Int
    -> MlirType
    -> String
    -> ( Context, MlirOp )
ecoProjectRecord ctx resultVar index resultType recordVar =
    let
        isUnboxed =
            not (isEcoValueType resultType)

        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr ecoValue ] )
                , ( "field_index", IntAttr Nothing index )
                , ( "unboxed", BoolAttr isUnboxed )
                ]
    in
    mlirOp ctx "eco.project.record"
        |> opBuilder.withOperands [ recordVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build
```

### 4.2. Fix list generation (HEAP_013, HEAP_010)

Existing `generateList` uses `ecoConstruct` with bogus tags (`0`, `1`) . Replace it with constants + `ecoConstructList`:

```elm
generateList : Context -> List Mono.MonoExpr -> ExprResult
generateList ctx items =
    case items of
        [] ->
            -- Use embedded Nil constant instead of heap allocation
            let
                ( var, ctx1 ) =
                    freshVar ctx

                -- eco.constant Nil
                kindAttr =
                    IntAttr (Just I32) 5 -- Eco_ConstantKind Nil = 5

                ( ctx2, constOp ) =
                    mlirOp ctx1 "eco.constant"
                        |> opBuilder.withResults [ ( var, ecoValue ) ]
                        |> opBuilder.withAttrs (Dict.singleton "kind" kindAttr)
                        |> opBuilder.build
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

                kindAttr =
                    IntAttr (Just I32) 5 -- Nil

                ( ctx2, nilOp ) =
                    mlirOp ctx1 "eco.constant"
                        |> opBuilder.withResults [ ( nilVar, ecoValue ) ]
                        |> opBuilder.withAttrs (Dict.singleton "kind" kindAttr)
                        |> opBuilder.build

                ( consOps, finalVar, finalCtx ) =
                    List.foldr
                        (\item ( accOps, tailVar, accCtx ) ->
                            let
                                result =
                                    generateExpr accCtx item

                                ( boxOps, boxedVar, ctx3 ) =
                                    boxToEcoValue result.ctx result.resultVar result.resultType

                                ( consVar, ctx4 ) =
                                    freshVar ctx3

                                ( ctx5, consOp ) =
                                    ecoConstructList ctx4 consVar
                                        ( boxedVar, ecoValue )
                                        ( tailVar, ecoValue )
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

This:

- Uses `eco.construct.list` instead of the removed generic `eco.construct`.
- Ensures Nil is an embedded constant, satisfying HEAP_010.

### 4.3. Fix tuple generation

Existing `generateTupleCreate` uses `ecoConstruct` with tag=0 (Tag_Int) for tuples . Replace:

```elm
generateTupleCreate : Context -> List Mono.MonoExpr -> Mono.TupleLayout -> ExprResult
generateTupleCreate ctx elements layout =
    let
        ( elemOps, elemVarsWithTypes, ctx1 ) =
            generateExprListTyped ctx elements

        ( boxOps, boxedElemVars, ctx2 ) =
            List.foldl
                (\( ( var, ssaType ), ( _, isUnboxed ) ) ( opsAcc, varsAcc, ctxAcc ) ->
                    if isUnboxed then
                        ( opsAcc, varsAcc ++ [ ( var, ssaType ) ], ctxAcc )

                    else
                        let
                            ( moreOps, boxedVar, newCtx ) =
                                boxToEcoValue ctxAcc var ssaType
                        in
                        ( opsAcc ++ moreOps
                        , varsAcc ++ [ ( boxedVar, ecoValue ) ]
                        , newCtx
                        )
                )
                ( [], [], ctx1 )
                (List.map2 Tuple.pair elemVarsWithTypes layout.elements)

        ( resultVar, ctx3 ) =
            freshVar ctx2
    in
    case layout.arity of
        2 ->
            let
                [ ( aVar, aTy ), ( bVar, bTy ) ] =
                    boxedElemVars

                ( ctx4, constructOp ) =
                    ecoConstructTuple2 ctx3 resultVar ( aVar, aTy ) ( bVar, bTy )
            in
            { ops = elemOps ++ boxOps ++ [ constructOp ]
            , resultVar = resultVar
            , resultType = ecoValue
            , ctx = ctx4
            }

        3 ->
            -- analogous ecoConstructTuple3 case

        _ ->
            Debug.crash "Unsupported tuple arity in generateTupleCreate"
```

### 4.4. Fix record generation and access

**Record creation** currently uses `ecoConstruct` with tag=0 and `layout.fieldCount`/`layout.unboxedBitmap`.  Replace that call with `ecoConstructRecord`:

```elm
generateRecordCreate : Context -> List Mono.MonoExpr -> Mono.RecordLayout -> ExprResult
generateRecordCreate ctx fields layout =
    let
        ( fieldsOps, fieldVarsWithTypes, ctx1 ) =
            generateExprListTyped ctx fields

        ( boxOps, boxedFieldVars, ctx2 ) =
            -- as before
            ...

        ( resultVar, ctx3 ) =
            freshVar ctx2

        fieldVarPairs : List ( String, MlirType )
        fieldVarPairs =
            List.map2
                (\( v, ty ) field ->
                    ( v
                    , if field.isUnboxed then
                        monoTypeToMlir field.monoType
                      else
                        ecoValue
                    )
                )
                boxedFieldVars
                layout.fields

        ( ctx4, constructOp ) =
            ecoConstructRecord ctx3 resultVar layout.fieldCount layout.unboxedBitmap fieldVarPairs
    in
    { ops = fieldsOps ++ boxOps ++ [ constructOp ]
    , resultVar = resultVar
    , resultType = ecoValue
    , ctx = ctx4
    }
```

**Record access** uses `ecoProject` with `index` and `unboxed` flag . Replace that builder with `ecoProjectRecord` in each branch:

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
    in
    if isUnboxed then
        let
            ( ctx2, projectOp ) =
                ecoProjectRecord ctx1 projectVar index fieldMlirType recordResult.resultVar
        in
        { ops = recordResult.ops ++ [ projectOp ]
        , resultVar = projectVar
        , resultType = fieldMlirType
        , ctx = ctx2
        }

    else if isEcoValueType fieldMlirType then
        let
            ( ctx2, projectOp ) =
                ecoProjectRecord ctx1 projectVar index ecoValue recordResult.resultVar
        in
        { ops = recordResult.ops ++ [ projectOp ]
        , resultVar = projectVar
        , resultType = ecoValue
        , ctx = ctx2
        }

    else
        let
            ( ctx2, projectOp ) =
                ecoProjectRecord ctx1 projectVar index ecoValue recordResult.resultVar

            ( unboxOps, unboxedVar, ctx3 ) =
                unboxToType ctx2 projectVar fieldMlirType
        in
        { ops = recordResult.ops ++ [ projectOp ] ++ unboxOps
        , resultVar = unboxedVar
        , resultType = fieldMlirType
        , ctx = ctx3
        }
```

**Record update** currently creates `ecoConstruct` wrapper with tag=0 . Replace with a record‑specific op or (if update is modeled as a runtime kernel) re‑route it there. The simplest safe stub is to leave record updates unimplemented with an internal error until you design a real layout‑preserving update.

---

## 5. Codegen invariants: MONO_002 and CGEN_001

### 5.1. MONO_002 – crash on `CNumber` at codegen

**File:** `Compiler/Generate/CodeGen/MLIR.elm` (the same MLIR codegen file)

Locate `monoTypeToMlir` (it’s used heavily; see `argVarPairsFromExprs`, `boxToMatchSignature`, etc. ). Adjust its `MVar` case:

```elm
monoTypeToMlir : Mono.MonoType -> MlirType
monoTypeToMlir monoTy =
    case monoTy of
        Mono.MInt ->
            I64
        -- ... other concrete cases ...

        Mono.MVar _ constraint_ ->
            case constraint_ of
                Mono.CNumber ->
                    Debug.crash "CNumber at codegen time indicates monomorphization bug (MONO_002)"

                Mono.CEcoValue ->
                    ecoValue
```

This enforces the invariant documented in `Monomorphized.elm`.

### 5.2. CGEN_001 – remove silent mismatch in `boxToMatchSignature`

**File:** `Compiler/Generate/CodeGen/MLIR.elm`

You already identified the problematic fallback in `boxToMatchSignature` and `boxToMatchSignatureTyped`: the final `else` silently accepts mismatches.

Change the final branch of `boxToMatchSignature`:

```elm
else
    Debug.crash
        ("Type mismatch in boxToMatchSignature: expected "
            ++ Debug.toString expectedMlirTy
            ++ " but got "
            ++ Debug.toString exprMlirTy
        )
```

Similarly for `boxToMatchSignatureTyped`:

```elm
else
    Debug.crash
        ("Type mismatch in boxToMatchSignatureTyped: expected "
            ++ Debug.toString expectedMlirTy
            ++ " but got "
            ++ Debug.toString actualTy
        )
```

This prevents latent type mis‑matches from being papered over.

---

## 6. Constants: use `eco.constant` for Unit and Nil (HEAP_010)

**File:** `Compiler/Generate/CodeGen/MLIR.elm`

You already use `eco.constant` for booleans via `ecoConstantBool`.

1. **Nil** – fixed in `generateList` above (Section 4.2).

2. **Unit** – find any place where Unit is heap‑allocated via `ecoConstruct ctx1 var 0 0 0 []` (you mentioned line 4710). Replace with `eco.constant Unit`:

Add helper:

```elm
ecoConstantUnit : Context -> String -> ( Context, MlirOp )
ecoConstantUnit ctx resultVar =
    let
        -- Eco_ConstantKind Unit = 1 (per Ops.td docs) 
        kindAttr =
            IntAttr (Just I32) 1
    in
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" kindAttr)
        |> opBuilder.build
```

Then, wherever you had:

```elm
( ctx2, constructOp ) =
    ecoConstruct ctx1 resultVar 0 0 0 [] Nothing Nothing
```

change to:

```elm
( ctx2, constOp ) =
    ecoConstantUnit ctx1 resultVar
```

This fully enforces HEAP_010 (all Unit/Nil as embedded constants, never heap allocations).

---

## 7. Summary of invariants addressed

- **HEAP_013 + architectural heap invariants**
    - Lists, tuples, records now have dedicated MLIR ops and runtime allocators using correct `Tag_*` and struct layouts (Sections 1–4).
    - No non‑Custom type is ever allocated via `eco_alloc_custom`.

- **HEAP_010 – constants**
    - Nil and Unit now go through `eco.constant` (Sections 4.2, 6), matching the ConstantKind design.

- **MONO_002 – numeric type vars**
    - `monoTypeToMlir` crashes on `MVar _ CNumber` at codegen (Section 5.1), enforcing the invariant documented in `Monomorphized.elm`.

- **CGEN_001 – call arg mismatch**
    - `boxToMatchSignature` and `boxToMatchSignatureTyped` now crash on irreconcilable type mismatches (Section 5.2), instead of silently reusing the wrong types.

Once these changes are in, the "all‑Custom" path is gone for lists/tuples/records, the MLIR and runtime heap invariants line up, and latent monomorphization / boxing bugs are surfaced immediately instead of hiding in the runtime.

---

## 8. Op Naming Summary

The following table summarizes the complete set of construct/project ops after this change:

| Heap Type | Construct Op | Project Op(s) |
|-----------|--------------|---------------|
| List (Cons) | `eco.construct.list` | `eco.project.list_head`, `eco.project.list_tail` |
| Tuple2 | `eco.construct.tuple2` | `eco.project.tuple2` |
| Tuple3 | `eco.construct.tuple3` | `eco.project.tuple3` |
| Record | `eco.construct.record` | `eco.project.record` |
| Custom ADT | `eco.construct.custom` | `eco.project.custom` |

**Removed ops**:
- `eco.construct` (generic) — replaced by type-specific ops above
- `eco.project` (generic) — replaced by type-specific ops above

**Migration checklist for existing code**:
1. Search for all uses of `"eco.construct"` and replace with appropriate type-specific op
2. Search for all uses of `"eco.project"` and replace with appropriate type-specific op
3. Update `ConstructOpLowering` → `CustomConstructOpLowering` (for `eco.construct.custom`)
4. Update `ProjectOpLowering` → `CustomProjectOpLowering` (for `eco.project.custom`)
5. Remove generic `Eco_ConstructOp` and `Eco_ProjectOp` definitions from Ops.td

