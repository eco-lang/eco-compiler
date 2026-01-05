Below is a concrete design and set of code deltas that an engineer can follow.

I’ll organize it by layer:

1. Heap layout (C++)
2. Runtime API + printing (C++)
3. JIT symbol registration (C++)
4. Eco dialect changes (TableGen)
5. Eco→LLVM lowering (C++)
6. Elm→Eco MLIR codegen (Elm)

I’ll explicitly call out file names and show “before → after” style snippets.

---

## 1. Heap layout: new `Custom` model

**File:** `elm-kernel-cpp/src/Heap.hpp`

### 1.1. Update `Custom` struct

Currently:

```cpp
typedef struct {
    Header header; // Header.size contains field count (max 63).
    u64 ctor : CTOR_BITS;
    u64 unboxed : 48; // Bitmap: bit N set means field N is unboxed (primitive value).
    Unboxable values[];
} Custom;
```

Change to:

```cpp
typedef struct {
    Header header;           // header.size = field count (max 63).
    u64 ctor   : CTOR_BITS;  // Constructor index within this Elm custom type.
    u64 id     : ID_BITS;    // Custom type id (global across program).
    u64 unboxed: 32;         // Bitmap: bit N set -> field N is unboxed primitive (max 32).
    Unboxable values[];
} Custom;
```

**Notes / rationale:**

- Uses existing `CTOR_BITS` and `ID_BITS` macros (both 16) and gives the remaining 32 bits to `unboxed`.
- Reduces the unboxed bitmap from 48→32 bits; we’ll clamp compiler‑side bitmaps accordingly (see §6.3).
- Keeps total metadata size for `Custom` at `sizeof(Header) + 8` bytes (the bitfield still occupies one `u64`).

No further GC size changes are needed: all sizing that uses `sizeof(Custom)` will automatically see the new layout.

---

## 2. Runtime API + printing changes

**File:** `runtime/src/RuntimeExports.h`

### 2.1. Define `CustomCtorInfo` and new APIs

Add near the bottom, before the GC section (after the “Tag Extraction” or “Arithmetic Helpers” block):

```cpp
//===----------------------------------------------------------------------===//
// Custom Constructor Name Tables
//===----------------------------------------------------------------------===//

/// Static description of a custom constructor for debug printing.
struct CustomCtorInfo {
    uint32_t type_id;   ///< Custom type id (matches Custom.id field).
    uint32_t ctor_id;   ///< Constructor index within that type (matches Custom.ctor).
    const char* name;   ///< Human-readable constructor name (e.g., "Just", "Nothing").
};

/// Registers a static table of custom constructors for debug printing.
/// Typically called once per module with a pointer to a static array.
void eco_register_custom_ctors(const CustomCtorInfo* table, uint32_t count);

/// Extracts the Custom.id (type id) field from a Custom object.
uint32_t eco_get_custom_type_id(void* obj);
```

Keep existing declarations for:

```cpp
uint32_t eco_get_custom_ctor(void* obj);
``` 

### 2.2. Implement registration + lookup

**File:** `runtime/src/RuntimeExports.cpp` (not shown in snippets, but exists next to `RuntimeExports.h`).

Add:

```cpp
#include <unordered_map>
#include <string>
#include "Heap.hpp"
#include "RuntimeExports.h"

using Elm::Custom;
using Elm::u64;

// Global map: (type_id << 32) | ctor_id -> name.
static std::unordered_map<u64, std::string> g_customCtorNames;

// Helper to combine ids
static inline u64 makeCtorKey(uint32_t type_id, uint32_t ctor_id) {
    return (static_cast<u64>(type_id) << 32) | static_cast<u64>(ctor_id);
}

extern "C" void eco_register_custom_ctors(const CustomCtorInfo* table, uint32_t count) {
    for (uint32_t i = 0; i < count; ++i) {
        const auto& info = table[i];
        u64 key = makeCtorKey(info.type_id, info.ctor_id);
        // Last registration wins if there are duplicates; that’s fine for debug.
        g_customCtorNames[key] = info.name;
    }
}

extern "C" uint32_t eco_get_custom_type_id(void* obj) {
    Custom* c = static_cast<Custom*>(obj);
    return static_cast<uint32_t>(c->id);
}
```

### 2.3. Use names in `eco_print_value` for `Tag_Custom`

In the runtime file that implements `eco_print_value` (not shown, but it switches on `Header.tag` as per `Heap.hpp` layout ):

Locate the `Tag_Custom` case, which today effectively does:

```cpp
case Tag_Custom: {
    Custom* c = static_cast<Custom*>(obj);
    uint32_t ctor = eco_get_custom_ctor(obj);
    // Currently something like: print "Ctor<ctor>" or generic representation
    ...
}
```

Change that branch to:

```cpp
case Tag_Custom: {
    Custom* c = static_cast<Custom*>(obj);
    uint32_t type_id = eco_get_custom_type_id(obj);
    uint32_t ctor_id = eco_get_custom_ctor(obj);

    u64 key = makeCtorKey(type_id, ctor_id);
    auto it = g_customCtorNames.find(key);

    const char* ctorName = nullptr;
    if (it != g_customCtorNames.end()) {
        ctorName = it->second.c_str();
    }

    if (ctorName) {
        // Print "CtorName arg1 arg2 ..." using existing list/record printing routines.
        printCustomWithName(ctorName, c);
    } else {
        // Fallback: Ctor<id> as today
        printCustomWithFallback(ctor_id, c);
    }
    break;
}
```

`printCustomWithName`/`printCustomWithFallback` are placeholders; reuse/extend whatever helpers you currently have for printing Custom values; the important part is name lookup via the map.

*(You may move `makeCtorKey` and `g_customCtorNames` into a shared runtime source file if `eco_print_value` is not in `RuntimeExports.cpp`.)*

---

## 3. JIT symbol registration

**File:** `runtime/src/RuntimeSymbols.h`

The comment already mentions:

> Tag extraction (eco_get_header_tag, eco_get_custom_ctor)

Update the comment to include the new symbols:

```cpp
///   - Tag extraction (eco_get_header_tag, eco_get_custom_ctor, eco_get_custom_type_id)
///   - Custom ctor tables (eco_register_custom_ctors)
```

And in the implementation of `eco::registerRuntimeSymbols` (C++ file not shown, but next to this header), add:

```cpp
engine.registerSymbol("eco_register_custom_ctors",
                      reinterpret_cast<void*>(&eco_register_custom_ctors));
engine.registerSymbol("eco_get_custom_type_id",
                      reinterpret_cast<void*>(&eco_get_custom_type_id));
```

This ensures JITted code can call these new runtime functions.

---

## 4. Eco dialect changes (MLIR ops)

### 4.1. Extend `eco.construct` with `type_id`

**File:** `runtime/src/codegen/Ops.td`

The doc describes `Eco_ConstructOp` with attributes `constructor`, `tag`, `size`.  The actual TableGen snippet isn’t fully in the search result, but it looks like:

```tablegen
def Eco_ConstructOp : Eco_Op<"construct", [Pure]> {
  let arguments = (ins
    Variadic<Eco_AnyValue>:$fields
  );
  let results = (outs Eco_AnyValue:$result);
  let attributes = [
    FlatSymbolRefAttr:$constructor,
    I64Attr:$tag,
    I64Attr:$size,
    OptionalAttr<I64Attr>:$unboxed_bitmap
  ];
  ...
}
```

Change the attributes list to add `type_id`:

```tablegen
  let arguments = (ins
    Variadic<Eco_AnyValue>:$fields
  );
  let results = (outs Eco_AnyValue:$result);
  let attributes = [
    FlatSymbolRefAttr:$constructor, // Optional: @"Module.Type.Ctor"
    I64Attr:$tag,                   // Constructor tag id (per Elm ADT)
    I64Attr:$size,                  // Field count
    OptionalAttr<I64Attr>:$unboxed_bitmap,
    OptionalAttr<I64Attr>:$type_id  // New: global custom type id for Custom layout (0 = unknown/non-Custom)
  ];
```

Update the description to mention `type_id`:

> - `type_id : i64` – custom type id used in the runtime `Custom.id` field; 0 for non‑Custom layouts.

No changes are required to other ops (records, lists) because they use different runtime layouts (`Record`, `Cons`, etc.)

---

## 5. Eco→LLVM lowering

The design doc already describes lowering `eco.construct` to a call to `@eco_alloc_custom(%tag, %size)` that initializes `Header.tag = Tag_Custom`, `Header.size = size`, and `Custom.ctor = tag`.

We will extend this:

- New runtime signature:

  ```c
  void* eco_alloc_custom(uint32_t type_id,
                         uint32_t ctor_id,
                         uint32_t field_count,
                         uint32_t scalar_bytes);
  ```   

- `Custom.id = type_id`, `Custom.ctor = ctor_id`, `Custom.unboxed = lower 32 bits of bitmap`.

### 5.1. Change `eco_alloc_custom` declaration

**File:** `runtime/src/RuntimeExports.h` (we already saw)

It currently is:

```cpp
void* eco_alloc_custom(uint32_t ctor_tag, uint32_t field_count, uint32_t scalar_bytes);
```

Change to:

```cpp
/// Allocates a Custom ADT object.
/// @param type_id     Custom type id (for printing/reflection).
/// @param ctor_id     Constructor tag (per Elm ADT, stored in Custom.ctor).
/// @param field_count Number of pointer-sized fields.
/// @param scalar_bytes Additional bytes for unboxed scalar fields.
void* eco_alloc_custom(uint32_t type_id,
                       uint32_t ctor_id,
                       uint32_t field_count,
                       uint32_t scalar_bytes);
```

Update the implementation accordingly to set `obj->id` and `obj->ctor` based on these arguments.

### 5.2. Lower `eco.construct` with `type_id` → `eco_alloc_custom`

**File:** `runtime/src/codegen/EcoToLLVM.cpp` (not shown; part of `createEcoToLLVMPass()` ).

In the pattern that handles `Eco_ConstructOp` for Custom layouts (the docs show pseudo‑code) :

Before (conceptual):

```cpp
// Pseudocode inside Eco_ConstructOpLowering
auto tagAttr  = op.getTag();
auto sizeAttr = op.getSize();
...
Value customPtr = rewriter.create<LLVM::CallOp>(
    loc, customPtrType, SymbolRefAttr::get(ctx, "eco_alloc_custom"),
    ValueRange{ tagValue, sizeValue, scalarBytesValue });
```

After:

```cpp
auto tagAttr  = op.getTag();      // ctor_id
auto sizeAttr = op.getSize();     // field_count
auto typeIdAttr = op.getTypeId(); // Optional<I64Attr>

// Default type_id = 0 if missing (non-Custom or old IR)
uint32_t typeId = typeIdAttr ? (uint32_t) typeIdAttr.getInt() : 0;
uint32_t ctorId = (uint32_t) tagAttr.getInt();

// Create constants
Value typeIdVal  = llvmI32Constant(typeId);
Value ctorIdVal  = llvmI32Constant(ctorId);
Value sizeVal    = llvmI32Constant((uint32_t) sizeAttr.getInt());
Value scalarVal  = llvmI32Constant(/* 0 or computed scalar bytes */);

// Call: %obj = @eco_alloc_custom(type_id, ctor_id, field_count, scalar_bytes)
Value customPtr = rewriter.create<LLVM::CallOp>(
    loc, customPtrType, SymbolRefAttr::get(ctx, "eco_alloc_custom"),
    ValueRange{ typeIdVal, ctorIdVal, sizeVal, scalarVal });
```

> **Note:** Only `Eco_ConstructOp`s that lower to `Custom` layout should call `eco_alloc_custom`. For lists/records/tuples, re-use their existing allocation code with `Cons`, `Record`, `Tuple2/3`, etc.

### 5.3. Emit a static global constructor table (Option B)

Still in `EcoToLLVM.cpp`, in the module‑level pass where you build the conversions:

1. **Collect constructor info.**

   Before rewriting, scan the module for `eco.construct` ops with non‑zero `type_id`:

   ```cpp
   struct CtorKey {
       uint32_t type_id;
       uint32_t ctor_id;
       std::string name;
   };

   std::vector<CtorKey> ctorInfos;

   module.walk([&](eco::ConstructOp op) {
       auto typeIdAttr = op.getTypeId();
       if (!typeIdAttr) return; // or if == 0, skip

       uint32_t typeId = (uint32_t) typeIdAttr.getInt();
       uint32_t ctorId = (uint32_t) op.getTag().getInt();

       // Assume we added a 'ctor_name' or reuse 'constructor' symbol:
       StringRef ctorName = op.getConstructor().getValue(); // e.g. "Just"
       ctorInfos.push_back({ typeId, ctorId, ctorName.str() });
   });
   ```

   If `Eco_ConstructOp` already has a `constructor : FlatSymbolRefAttr` with `"Module.Type.Ctor"`, you can use that and strip module/type prefixes to get the short name, or store full name in the table.

2. **Create an LLVM struct and global array.**

   In the same pass, after collection:

   ```cpp
   auto &llvmCtx = typeConverter.getContext();
   auto i32Ty = LLVM::LLVMIntegerType::get(&llvmCtx, 32);
   auto i8PtrTy = LLVM::LLVMPointerType::get(IntegerType::get(&llvmCtx, 8));

   auto ctorInfoTy = LLVM::LLVMStructType::getLiteral(&llvmCtx,
                      { i32Ty, i32Ty, i8PtrTy }); // (type_id, ctor_id, name*)

   SmallVector<Attribute> elements;
   for (const auto &info : ctorInfos) {
       // Create name global
       auto nameGlobal = createStringGlobal(builder, info.name);
       auto namePtr = builder.create<LLVM::AddressOfOp>(
           loc, nameGlobal.getType(), nameGlobal.getSymNameAttr());

       elements.push_back(LLVM::ConstantStructAttr::get(
           ctorInfoTy,
           { builder.getI32IntegerAttr(info.type_id),
             builder.getI32IntegerAttr(info.ctor_id),
             namePtr.getResult().getType() /* placeholder, actual attr uses GlobalRef */ }));
   }

   auto arrayTy = LLVM::LLVMArrayType::get(ctorInfoTy, elements.size());

   // Lower-level: use llvm.mlir.global to define:
   auto tableGlobal = builder.create<LLVM::GlobalOp>(
       loc, arrayTy, /*isConstant=*/true, LLVM::Linkage::Internal,
       "_eco_custom_ctors", builder.getArrayAttr(elements));
   ```

   The exact API is standard LLVM dialect usage; the main idea is: define a `!llvm.global` array of `{i32, i32, i8*}` rows.

3. **Call `eco_register_custom_ctors` once at startup.**

   To actually use the table, emit a small `@_eco_init_custom_ctors` function in LLVM dialect that:

    - takes no args,
    - computes `ptr` to the first element of the table,
    - knows the `count` (length of array),
    - calls `@eco_register_custom_ctors(ptr, count)`.

   Pseudocode in LLVM dialect:

   ```mlir
   llvm.func @_eco_init_custom_ctors() {
     %table = llvm.address_of @_eco_custom_ctors
     %zero  = llvm.constant 0 : i64
     %ptr   = llvm.getelementptr %table[%zero, %zero]
              : (!llvm.ptr<array<N x struct<(i32,i32,ptr<i8>)>>>)
                -> !llvm.ptr<struct<(i32,i32,ptr<i8>)>>
     %count = llvm.constant N : i32
     llvm.call @eco_register_custom_ctors(%ptr, %count)
       : (!llvm.ptr<struct<(i32,i32,ptr<i8>)>>, i32) -> ()
     llvm.return
   }
   ```

   Then arrange for this to be called once before `main` in your runner; for example:

    - In the JIT runner (`EcoRunner`), after loading the module, explicitly call `_eco_init_custom_ctors` via the execution engine, or
    - Treat it as part of your existing “module init” sequence if you already have one.

This realizes Option B: the mapping is in a static global, and only a single O(NumCtors) registration happens per module.

---

## 6. Elm → Eco MLIR codegen changes

We need to:

- Assign `type_id` for each **custom type** (Elm `type` / union).
- Attach that `type_id` and a ctor name to `eco.construct`.
- Ensure unboxed bitmaps respect the 32‑bit limit.

### 6.1. Track type IDs per `MCustom`

**File:** `Compiler/AST/Monomorphized.elm`

We already have:

- `MonoType = MCustom IO.Canonical Name (List MonoType) | ...`
- `toComparableMonoType : MonoType -> List String` that uniquely encodes a mono type.
- `CtorLayout` with `name`, `tag`, `unboxedBitmap`, etc.

We won’t change these types. Instead, we’ll augment the MLIR codegen `Context` to carry a mapping from `MCustom` → `type_id`.

**File:** `Compiler/Generate/CodeGen/MLIR.elm`

Find the `Context` type definition (earlier in this file; not in snippets). Extend it with:

```elm
type alias Context =
    { ...
    , nextCustomTypeId : Int
    , customTypeIds : Dict (List String) Int
    }
```

Initialize these fields in the initial context (where you currently set `nextVar`, etc.) to `0` and `Dict.empty`.

Add a helper:

```elm
import Compiler.AST.Monomorphized as Mono
import Data.Map as Dict exposing (Dict)

getOrCreateCustomTypeId : Mono.MonoType -> Context -> ( Int, Context )
getOrCreateCustomTypeId monoType ctx =
    case monoType of
        Mono.MCustom _ _ _ ->
            let
                key =
                    Mono.toComparableMonoType monoType

                maybeId =
                    Dict.get identity key ctx.customTypeIds
            in
            case maybeId of
                Just tid ->
                    ( tid, ctx )

                Nothing ->
                    let
                        tid =
                            ctx.nextCustomTypeId

                        newMap =
                            Dict.insert identity key tid ctx.customTypeIds
                    in
                    ( tid
                    , { ctx | nextCustomTypeId = tid + 1, customTypeIds = newMap }
                    )

        _ ->
            -- Non-custom types don't get a type_id (0 = unknown)
            ( 0, ctx )
```

### 6.2. Extend `ecoConstruct` helper to carry `type_id`

Still in `MLIR.elm` , we currently have:

```elm
ecoConstruct : Context -> String -> Int -> Int -> Int -> List ( String, MlirType ) -> ( Context, MlirOp )
ecoConstruct ctx resultVar tag size unboxedBitmap operands =
    let
        operandNames =
            List.map Tuple.first operands

        operandTypesAttr =
            ...
        attrs =
            Dict.union operandTypesAttr
                (Dict.fromList
                    [ ( "tag", IntAttr Nothing tag )
                    , ( "size", IntAttr Nothing size )
                    , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                    ]
                )
    in
    mlirOp ctx "eco.construct"
        |> opBuilder.withOperands operandNames
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build
```

Change the signature to include `typeId` as an extra argument:

```elm
ecoConstruct :
    Context
    -> String   -- result SSA name
    -> Int      -- typeId (0 for non-custom)
    -> Int      -- tag (ctor_id)
    -> Int      -- size (field count)
    -> Int      -- unboxedBitmap
    -> List ( String, MlirType )
    -> ( Context, MlirOp )
ecoConstruct ctx resultVar typeId tag size unboxedBitmap operands =
    let
        operandNames =
            List.map Tuple.first operands

        operandTypesAttr =
            if List.isEmpty operands then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map (\( _, t ) -> TypeAttr t) operands))

        baseAttrs =
            [ ( "tag", IntAttr Nothing tag )
            , ( "size", IntAttr Nothing size )
            , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
            ]

        attrs =
            Dict.union operandTypesAttr
                (Dict.fromList
                    (if typeId == 0 then
                        baseAttrs
                     else
                        ( "type_id", IntAttr Nothing typeId ) :: baseAttrs
                    )
                )
    in
    mlirOp ctx "eco.construct"
        |> opBuilder.withOperands operandNames
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build
```

### 6.3. Update all `ecoConstruct` call sites

We must now supply `typeId` explicitly.

#### 6.3.1. Custom constructors

In `generateCtor` (same file) :

Current:

```elm
generateCtor ctx funcName ctorLayout ctorResultType =
    let
        arity = List.length ctorLayout.fields
    in
    if arity == 0 then
        ...
        ( ctx2, constructOp ) =
            ecoConstruct ctx1 resultVar ctorLayout.tag 0 0 []
        ...
    else
        ...
        ( ctx2, constructOp ) =
            ecoConstruct ctx1 resultVar ctorLayout.tag arity ctorLayout.unboxedBitmap argPairs
```

We know the **result mono type** from the caller; if it is `MCustom`, we can compute `typeId`.

Change the function signature (if needed) so that you have the mono type (already present: `Mono.MonoType` parameter). Then:

```elm
generateCtor ctx funcName ctorLayout ctorResultType =
    let
        ( typeId, ctx0 ) =
            getOrCreateCustomTypeId ctorResultType ctx

        arity =
            List.length ctorLayout.fields
    in
    if arity == 0 then
        let
            ( resultVar, ctx1 ) =
                freshVar ctx0

            ( ctx2, constructOp ) =
                ecoConstruct ctx1 resultVar typeId ctorLayout.tag 0 0 []
            ...
        in
        ...

    else
        ...
        let
            ( resultVar, ctx1 ) =
                freshVar { ctx0 | nextVar = arity }

            ( ctx2, constructOp ) =
                ecoConstruct ctx1 resultVar typeId ctorLayout.tag arity ctorLayout.unboxedBitmap argPairs
            ...
        in
        ...
```

#### 6.3.2. Enums (`generateEnum`)

`generateEnum` currently emits constructors for `Can.Enum` (zero‑arg) with only a `tag` and no type info .

```elm
generateEnum ctx funcName tag monoType =
    let
        ( resultVar, ctx1 ) =
            freshVar ctx

        ( ctx2, constructOp ) =
            ecoConstruct ctx1 resultVar tag 0 0 []
        ...
```

Update:

```elm
generateEnum ctx funcName tag monoType =
    let
        ( typeId, ctx0 ) =
            getOrCreateCustomTypeId monoType ctx

        ( resultVar, ctx1 ) =
            freshVar ctx0

        ( ctx2, constructOp ) =
            ecoConstruct ctx1 resultVar typeId tag 0 0 []
        ...
```

#### 6.3.3. Records / tuples / lists / unit / cycle

These are *not* `Custom` layout in the heap (they use `Record`, `Tuple2`, `Cons`, etc. ), so we set `typeId = 0`.

Examples:

- `generateRecordCreate` :

  ```elm
  ( ctx4, constructOp ) =
      ecoConstruct ctx3 resultVar 0 layout.fieldCount layout.unboxedBitmap fieldVarPairs
  ```

  → add zero `typeId`:

  ```elm
  ( ctx4, constructOp ) =
      ecoConstruct ctx3 resultVar 0 0 layout.fieldCount layout.unboxedBitmap fieldVarPairs
  ```

- `generateTupleCreate` (similar) :

  ```elm
  ( ctx4, constructOp ) =
      ecoConstruct ctx3 resultVar 0 layout.arity layout.unboxedBitmap elemVarPairs
  ```

  →

  ```elm
  ( ctx4, constructOp ) =
      ecoConstruct ctx3 resultVar 0 0 layout.arity layout.unboxedBitmap elemVarPairs
  ```

- `generateUnit` :

  ```elm
  ( ctx2, constructOp ) =
      ecoConstruct ctx1 var 0 0 0 []
  ```

  →

  ```elm
  ( ctx2, constructOp ) =
      ecoConstruct ctx1 var 0 0 0 0 []
  ```

- `generateList` for `[]` and `(::)` cases :

  ```elm
  ( ctx2, nilOp ) =
      ecoConstruct ctx1 nilVar 0 0 0 []
  ...
  ( ctx5, consOp ) =
      ecoConstruct ctx4 consVar 1 2 0 [ ( boxedVar, ecoValue ), ( tailVar, ecoValue ) ]
  ```

  →

  ```elm
  ( ctx2, nilOp ) =
      ecoConstruct ctx1 nilVar 0 0 0 0 []
  ...
  ( ctx5, consOp ) =
      ecoConstruct ctx4 consVar 0 1 2 0 [ ( boxedVar, ecoValue ), ( tailVar, ecoValue ) ]
  ```

  (typeId stays 0 for list; list uses `Cons` layout, not `Custom`.)

- `generateCycle` (record‑like thunk) :

  ```elm
  ( ctx2, cycleOp ) =
      ecoConstruct ctx1 resultVar 0 arity 0 defVarPairs
  ```

  →

  ```elm
  ( ctx2, cycleOp ) =
      ecoConstruct ctx1 resultVar 0 0 arity 0 defVarPairs
  ```

- Dummy constructs in tail calls/cases that just produce a value to satisfy the type system (e.g. `createDummyValue` uses `eco.construct` for default eco.value) :

  ```elm
  ( ctx2, op ) =
      mlirOp ctx1 "eco.construct"
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs
            (Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [] )
                , ( "size", IntAttr Nothing 0 )
                , ( "tag", IntAttr Nothing 0 )
                , ( "unboxed_bitmap", IntAttr Nothing 0 )
                ]
            )
        |> opBuilder.build
  ```

  You can leave this as-is (it bypasses `ecoConstruct` helper), or if you prefer consistency, switch to `ecoConstruct` with `typeId=0`, `tag=0`, etc.

### 6.4. Clamp unboxed bitmaps to 32 bits

Because `Custom.unboxed` now has only 32 bits, compiler layout computations should never set higher bits.

**File:** `Compiler/AST/Monomorphized.elm`

- **For records** (`computeRecordLayout`) :

  Today:

  ```elm
  unboxedBitmap =
      if unboxedCount == 0 then
          0
      else
          (2 ^ unboxedCount) - 1
  ```

  This is fine for `Record` (which still has a 64‑bit unboxed bitmap). No change needed.

- **For custom ctors** (`buildCtorLayoutFromArity`) :

  Today:

  ```elm
  unboxedBitmap =
      List.foldl
          (\field acc ->
              if field.isUnboxed then
                  acc + (2 ^ field.index)
              else
                  acc
          )
          0
          fields
  ```

  Change to limit to 32 bits:

  ```elm
  unboxedBitmap =
      List.foldl
          (\field acc ->
              if field.isUnboxed && field.index < 32 then
                  acc + (2 ^ field.index)
              else
                  acc
          )
          0
          fields
  ```

  So fields at index ≥ 32 are always considered boxed in the layout bitmap.

You don’t need to change `computeTupleLayout`; tuples use their own `TupleLayout.unboxedBitmap` and map to `Tuple2`/`Tuple3` which already limit unboxed bits via header.unboxed or similar.

---

With these changes:

- Every `Custom` heap object carries:
    - `ctor` = per‑type constructor id (your existing tag),
    - `id`   = global custom type id (assigned by MLIR codegen),
    - `unboxed` = 32‑bit bitmap for up to 32 unboxed fields.
- EcoToLLVM always initializes `ctor` and `id` via `eco_alloc_custom`.
- EcoToLLVM also emits an LLVM global table of `(type_id, ctor_id, name)` rows and a one‑time call to `eco_register_custom_ctors`.
- The runtime uses this table to map `(type_id, ctor_id)` → constructor name in `eco_print_value`, so `eco.dbg` and `Debug.toString` can show true Elm constructor names instead of `Ctor0`, `Ctor1`, etc.

This is all you need for an engineer to implement the feature end‑to‑end.

