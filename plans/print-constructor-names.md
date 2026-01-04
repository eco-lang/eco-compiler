# Print Constructor Names Implementation Plan

This plan implements the feature to print actual Elm constructor names (e.g., "Red", "Just", "Nothing") instead of generic names like "Ctor0", "Ctor1" in debug output.

## Overview

The implementation spans 8 steps across the stack:
1. Heap layout changes (C++) - Add `id` field to Custom struct
2. Runtime API + printing (C++) - Update allocation, add registration, use names in printing
3. JIT symbol registration (C++) - Register new runtime functions
4. Eco dialect changes (TableGen) - Add `type_id` and `constructor` attributes
5. Eco→LLVM lowering (C++) - Pass type_id, collect ctors, emit initialization
6. Elm→Eco MLIR codegen (Elm) - Track type IDs, emit attributes
7. Clamp unboxed bitmaps (Elm) - Limit to 32 bits
8. Monomorphization (Elm) - Populate CtorLayout.name from Can.Ctor

## Current State Analysis

### Heap Layout (`runtime/src/allocator/Heap.hpp`)

Current `Custom` struct (line 187-192):
```cpp
typedef struct {
    Header header; // Header.size contains field count (max 63).
    u64 ctor : CTOR_BITS;   // 16 bits
    u64 unboxed : 48;       // Bitmap: bit N set means field N is unboxed
    Unboxable values[];
} Custom;
```

The design proposes adding an `id` field for type identification.

### Runtime Exports (`runtime/src/allocator/RuntimeExports.h`)

Current `eco_alloc_custom` signature (line 38):
```cpp
void* eco_alloc_custom(uint32_t ctor_tag, uint32_t field_count, uint32_t scalar_bytes);
```

### eco.construct Op (`runtime/src/codegen/Ops.td`)

Current attributes (lines 361-366):
```tablegen
let arguments = (ins
    Variadic<Eco_AnyValue>:$fields,
    I64Attr:$tag,
    I64Attr:$size,
    OptionalAttr<I64Attr>:$unboxed_bitmap
);
```

### MLIR Codegen (`compiler/src/Compiler/Generate/CodeGen/MLIR.elm`)

Current `ecoConstruct` signature (lines 4372-4399):
```elm
ecoConstruct : Context -> String -> Int -> Int -> Int -> List ( String, MlirType ) -> ( Context, MlirOp )
ecoConstruct ctx resultVar tag size unboxedBitmap operands = ...
```

---

## Step 1: Update Heap Layout (C++)

**File:** `runtime/src/allocator/Heap.hpp`

### 1.1 Modify Custom struct

**Current** (lines 187-192):
```cpp
typedef struct {
    Header header;
    u64 ctor : CTOR_BITS;
    u64 unboxed : 48;
    Unboxable values[];
} Custom;
```

**Change to:**
```cpp
typedef struct {
    Header header;           // header.size = field count (max 63).
    u64 ctor   : CTOR_BITS;  // Constructor index within this Elm custom type (16 bits).
    u64 id     : ID_BITS;    // Custom type id (global across program, 16 bits).
    u64 unboxed: 32;         // Bitmap: bit N set -> field N is unboxed primitive (max 32).
    Unboxable values[];
} Custom;
```

**Notes:**
- `CTOR_BITS` (16) and `ID_BITS` (16) are already defined in Heap.hpp (lines 60, 62)
- Remaining 32 bits go to `unboxed`
- This reduces max unboxed fields from 48 to 32, which is acceptable
- Total bitfield still occupies 1 u64, so `sizeof(Custom)` is unchanged

---

## Step 2: Runtime API + Printing (C++)

### 2.1 Add CustomCtorInfo struct and APIs

**File:** `runtime/src/allocator/RuntimeExports.h`

Add after "Tag Extraction" section (after line 225):

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

### 2.2 Update eco_alloc_custom signature

**File:** `runtime/src/allocator/RuntimeExports.h`

**Current** (lines 33-38):
```cpp
/// Allocates a Custom ADT object.
/// @param ctor_tag The constructor tag (maps to Custom.ctor field)
/// @param field_count Number of pointer-sized fields
/// @param scalar_bytes Additional bytes for unboxed scalar fields
/// @return Pointer to the allocated object
void* eco_alloc_custom(uint32_t ctor_tag, uint32_t field_count, uint32_t scalar_bytes);
```

**Change to:**
```cpp
/// Allocates a Custom ADT object.
/// @param type_id     Custom type id (for printing/reflection, stored in Custom.id).
/// @param ctor_id     Constructor tag (per Elm ADT, stored in Custom.ctor).
/// @param field_count Number of pointer-sized fields.
/// @param scalar_bytes Additional bytes for unboxed scalar fields.
/// @return Pointer to the allocated object
void* eco_alloc_custom(uint32_t type_id, uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes);
```

### 2.3 Implement registration + lookup

**File:** `runtime/src/allocator/RuntimeExports.cpp`

Add after existing includes (around line 17):
```cpp
#include <unordered_map>
```

Add after the anonymous namespace opening (around line 25):
```cpp
// Global map: (type_id << 32) | ctor_id -> name.
static std::unordered_map<u64, std::string> g_customCtorNames;

// Helper to combine ids
static inline u64 makeCtorKey(uint32_t type_id, uint32_t ctor_id) {
    return (static_cast<u64>(type_id) << 32) | static_cast<u64>(ctor_id);
}
```

Add after the `output_char` helper (after line 54):
```cpp
} // namespace

extern "C" void eco_register_custom_ctors(const CustomCtorInfo* table, uint32_t count) {
    for (uint32_t i = 0; i < count; ++i) {
        const auto& info = table[i];
        u64 key = makeCtorKey(info.type_id, info.ctor_id);
        g_customCtorNames[key] = info.name;
    }
}

extern "C" uint32_t eco_get_custom_type_id(void* obj) {
    Custom* c = static_cast<Custom*>(obj);
    return static_cast<uint32_t>(c->id);
}

namespace {
```

### 2.4 Update eco_alloc_custom implementation

**File:** `runtime/src/allocator/RuntimeExports.cpp`

**Current** (lines 76-88):
```cpp
extern "C" void* eco_alloc_custom(uint32_t ctor_tag, uint32_t field_count, uint32_t scalar_bytes) {
    size_t size = sizeof(Header) + 8 + field_count * sizeof(Unboxable) + scalar_bytes;
    void* obj = Allocator::instance().allocate(size, Tag_Custom);
    if (!obj) return nullptr;
    Custom* custom = static_cast<Custom*>(obj);
    custom->ctor = ctor_tag;
    custom->unboxed = 0;
    return obj;
}
```

**Change to:**
```cpp
extern "C" void* eco_alloc_custom(uint32_t type_id, uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes) {
    size_t size = sizeof(Header) + 8 + field_count * sizeof(Unboxable) + scalar_bytes;
    void* obj = Allocator::instance().allocate(size, Tag_Custom);
    if (!obj) return nullptr;
    Custom* custom = static_cast<Custom*>(obj);
    custom->ctor = ctor_id;
    custom->id = type_id;
    custom->unboxed = 0;
    return obj;
}
```

### 2.5 Update print_custom to use name lookup

**File:** `runtime/src/allocator/RuntimeExports.cpp`

**Current** `print_custom` function (lines 728-766):
```cpp
static void print_custom(Custom* custom, int depth) {
    uint32_t ctor = custom->ctor;
    uint32_t size = custom->header.size;
    output_format("Ctor%u", ctor);
    // ... rest of printing
}
```

**Change to:**
```cpp
static void print_custom(Custom* custom, int depth) {
    uint32_t type_id = custom->id;
    uint32_t ctor_id = custom->ctor;
    uint32_t size = custom->header.size;

    // Look up constructor name
    u64 key = makeCtorKey(type_id, ctor_id);
    auto it = g_customCtorNames.find(key);

    if (it != g_customCtorNames.end()) {
        output_text(it->second.c_str());
    } else {
        // Fallback to generic name
        output_format("Ctor%u", ctor_id);
    }

    // Print fields if any (unchanged from current implementation)
    if (size > 0) {
        output_char(' ');
        for (uint32_t i = 0; i < size; i++) {
            if (i > 0) output_char(' ');
            if (custom->unboxed & (1ULL << i)) {
                output_format("%lld", (long long)custom->values[i].i);
            } else {
                uint64_t val = static_cast<uint64_t>(custom->values[i].i);
                if (val == 0) {
                    output_text("<null>");
                } else if (!print_if_constant(val)) {
                    void* ptr = reinterpret_cast<void*>(val);
                    bool needs_parens = false;
                    if (ptr) {
                        Header* h = static_cast<Header*>(ptr);
                        needs_parens = (h->tag == Tag_Custom && static_cast<Custom*>(ptr)->header.size > 0);
                    }
                    if (needs_parens) output_char('(');
                    print_value(val, depth + 1);
                    if (needs_parens) output_char(')');
                }
            }
        }
    }
}
```

---

## Step 3: JIT Symbol Registration (C++)

**File:** `runtime/src/codegen/RuntimeSymbols.h`

Update comment (around line 28):
```cpp
///   - Tag extraction (eco_get_header_tag, eco_get_custom_ctor, eco_get_custom_type_id)
///   - Custom ctor tables (eco_register_custom_ctors)
```

**File:** `runtime/src/codegen/RuntimeSymbols.cpp`

Add after `eco_get_custom_ctor` registration (after line 158):
```cpp
        symbolMap[interner("eco_get_custom_type_id")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_get_custom_type_id),
                llvm::JITSymbolFlags::Exported);
        symbolMap[interner("eco_register_custom_ctors")] =
            llvm::orc::ExecutorSymbolDef(
                llvm::orc::ExecutorAddr::fromPtr(&eco_register_custom_ctors),
                llvm::JITSymbolFlags::Exported);
```

---

## Step 4: Eco Dialect TableGen Changes

**File:** `runtime/src/codegen/Ops.td`

### 4.1 Add `type_id` as first-class attribute to Eco_ConstructOp

**Current** (lines 361-366):
```tablegen
let arguments = (ins
    Variadic<Eco_AnyValue>:$fields,
    I64Attr:$tag,
    I64Attr:$size,
    OptionalAttr<I64Attr>:$unboxed_bitmap
);
```

**Change to:**
```tablegen
let arguments = (ins
    Variadic<Eco_AnyValue>:$fields,
    I64Attr:$tag,
    I64Attr:$size,
    OptionalAttr<I64Attr>:$unboxed_bitmap,
    OptionalAttr<I64Attr>:$type_id,
    OptionalAttr<StrAttr>:$constructor
);
```

**Notes:**
- `type_id` is the globally-unique type identifier for custom ADTs
- `constructor` stores the constructor name (e.g., "Just", "Nothing", "Red") for table emission
- Both are optional: non-custom types (tuples, records, lists) don't need them
- After changing Ops.td, rebuild to regenerate `Ops.h.inc` and `Ops.cpp.inc`

### 4.2 Similarly update Eco_AllocateCtorOp if it exists

Check if `Eco_AllocateCtorOp` also needs `type_id` and `constructor` attributes.

---

## Step 5: Eco→LLVM Lowering (C++)

**File:** `runtime/src/codegen/Passes/EcoToLLVM.cpp`

### 5.1 Update eco_alloc_custom call signature

**Current** (around line 400):
```cpp
auto allocFuncTy = LLVM::LLVMFunctionType::get(ptrTy, {i32Ty, i32Ty, i32Ty});
getOrInsertFunc(module, rewriter, "eco_alloc_custom", allocFuncTy);
```

**Change to:**
```cpp
auto allocFuncTy = LLVM::LLVMFunctionType::get(ptrTy, {i32Ty, i32Ty, i32Ty, i32Ty});
getOrInsertFunc(module, rewriter, "eco_alloc_custom", allocFuncTy);
```

### 5.2 Update ConstructOpLowering to pass type_id

Now that `type_id` is a first-class attribute (from Step 4), use the generated accessor:

**Current** (around lines 410-423):
```cpp
// eco.construct -> eco_alloc_custom + eco_store_field calls
auto tag = rewriter.create<LLVM::ConstantOp>(
    loc, i32Ty, static_cast<int32_t>(op.getTag()));
auto size = rewriter.create<LLVM::ConstantOp>(
    loc, i32Ty, static_cast<int32_t>(op.getSize()));
auto scalarBytes = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);

auto allocCall = rewriter.create<LLVM::CallOp>(
    loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_custom"),
    ValueRange{tag, size, scalarBytes});
```

**Change to:**
```cpp
// eco.construct -> eco_alloc_custom + eco_store_field calls
// Use generated accessor for type_id (returns std::optional<int64_t>)
int64_t typeId = op.getTypeId().value_or(0);

auto typeIdVal = rewriter.create<LLVM::ConstantOp>(
    loc, i32Ty, static_cast<int32_t>(typeId));
auto tag = rewriter.create<LLVM::ConstantOp>(
    loc, i32Ty, static_cast<int32_t>(op.getTag()));
auto size = rewriter.create<LLVM::ConstantOp>(
    loc, i32Ty, static_cast<int32_t>(op.getSize()));
auto scalarBytes = rewriter.create<LLVM::ConstantOp>(loc, i32Ty, 0);

auto allocCall = rewriter.create<LLVM::CallOp>(
    loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_custom"),
    ValueRange{typeIdVal, tag, size, scalarBytes});
```

### 5.3 Update AllocateCtorOpLowering similarly

**Current** (around lines 540-554):
```cpp
auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {i32Ty, i32Ty, i32Ty});
getOrInsertFunc(module, rewriter, "eco_alloc_custom", funcTy);
auto tag = rewriter.create<LLVM::ConstantOp>(
    loc, i32Ty, static_cast<int32_t>(op.getTag()));
auto size = rewriter.create<LLVM::ConstantOp>(
    loc, i32Ty, static_cast<int32_t>(op.getSize()));
auto scalarBytes = rewriter.create<LLVM::ConstantOp>(
    loc, i32Ty, static_cast<int32_t>(op.getScalarBytes()));
auto call = rewriter.create<LLVM::CallOp>(
    loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_custom"),
    ValueRange{tag, size, scalarBytes});
```

**Change to:**
```cpp
auto funcTy = LLVM::LLVMFunctionType::get(ptrTy, {i32Ty, i32Ty, i32Ty, i32Ty});
getOrInsertFunc(module, rewriter, "eco_alloc_custom", funcTy);

// Use generated accessor for type_id
int64_t typeId = op.getTypeId().value_or(0);

auto typeIdVal = rewriter.create<LLVM::ConstantOp>(
    loc, i32Ty, static_cast<int32_t>(typeId));
auto tag = rewriter.create<LLVM::ConstantOp>(
    loc, i32Ty, static_cast<int32_t>(op.getTag()));
auto size = rewriter.create<LLVM::ConstantOp>(
    loc, i32Ty, static_cast<int32_t>(op.getSize()));
auto scalarBytes = rewriter.create<LLVM::ConstantOp>(
    loc, i32Ty, static_cast<int32_t>(op.getScalarBytes()));
auto call = rewriter.create<LLVM::CallOp>(
    loc, ptrTy, SymbolRefAttr::get(ctx, "eco_alloc_custom"),
    ValueRange{typeIdVal, tag, size, scalarBytes});
```

### 5.4 Collect constructor info for table emission

During EcoToLLVM lowering, collect all `eco.construct` ops with `constructor` attribute:

```cpp
// In the EcoToLLVMPass class, add a member to collect ctor info:
struct CtorInfo {
    int64_t typeId;
    int64_t ctorId;
    std::string name;
};
std::vector<CtorInfo> collectedCtors;

// In ConstructOpLowering::matchAndRewrite, after creating the alloc call:
if (auto ctorNameAttr = op.getConstructorAttr()) {
    int64_t typeId = op.getTypeId().value_or(0);
    if (typeId > 0) {
        collectedCtors.push_back({typeId, op.getTag(), ctorNameAttr.str()});
    }
}
```

### 5.5 Emit constructor table and init function

After all operations are lowered, emit the static constructor table and initialization function:

```cpp
void emitCtorTableAndInit(ModuleOp module, OpBuilder& builder) {
    if (collectedCtors.empty()) return;

    auto loc = builder.getUnknownLoc();
    auto ctx = builder.getContext();
    auto i32Ty = IntegerType::get(ctx, 32);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    // Deduplicate: same (typeId, ctorId) may appear multiple times
    std::set<std::pair<int64_t, int64_t>> seen;
    std::vector<CtorInfo> unique;
    for (const auto& info : collectedCtors) {
        auto key = std::make_pair(info.typeId, info.ctorId);
        if (seen.insert(key).second) {
            unique.push_back(info);
        }
    }

    // Create CustomCtorInfo struct type: {i32, i32, ptr}
    auto ctorInfoTy = LLVM::LLVMStructType::getLiteral(ctx, {i32Ty, i32Ty, ptrTy});

    // Emit global string constants for each constructor name
    // Emit global array of CustomCtorInfo
    // Emit _eco_init_custom_ctors function that calls eco_register_custom_ctors
    // Add to @llvm.global_ctors

    // ... (detailed implementation)
}
```

### 5.6 Emit LLVM global constructors for initialization

Use the `@llvm.global_ctors` pattern (similar to `__eco_init_globals`):

```cpp
// After emitting _eco_init_custom_ctors function, add it to global_ctors:

// Create or get @llvm.global_ctors global
auto ctorsArrayTy = LLVM::LLVMArrayType::get(
    LLVM::LLVMStructType::getLiteral(ctx, {i32Ty, ptrTy, ptrTy}), 1);

// Entry: {priority=65535, @_eco_init_custom_ctors, null}
// This ensures initialization runs before main()
```

**Pattern from existing `__eco_init_globals`:**

The existing codebase already uses this pattern for initializing global string tables. Follow the same approach:

1. Emit a function `@_eco_init_custom_ctors` that:
   - Declares `eco_register_custom_ctors`
   - Passes pointer to static `CustomCtorInfo` array and count
   - Returns void

2. Add to `@llvm.global_ctors` with priority 65535 (default, runs before main)

---

## Step 6: Elm→Eco MLIR Codegen (Elm)

**File:** `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

### 6.1 Extend Context with type ID tracking

**Current** `Context` type (around lines 366-374):
```elm
type alias Context =
    { nextVar : Int
    , nextOpId : Int
    , mode : Mode.Mode
    , registry : Mono.SpecializationRegistry
    , pendingLambdas : List PendingLambda
    , signatures : Dict Int FuncSignature
    , varMappings : Dict String ( String, MlirType )
    }
```

**Change to:**
```elm
type alias Context =
    { nextVar : Int
    , nextOpId : Int
    , mode : Mode.Mode
    , registry : Mono.SpecializationRegistry
    , pendingLambdas : List PendingLambda
    , signatures : Dict Int FuncSignature
    , varMappings : Dict String ( String, MlirType )
    , nextCustomTypeId : Int
    , customTypeIds : Dict (List String) Int  -- toComparableMonoType -> type_id
    }
```

### 6.2 Update initContext

**Current** (around lines 385-394):
```elm
initContext : Mode.Mode -> Mono.SpecializationRegistry -> Dict Int FuncSignature -> Context
initContext mode registry signatures =
    { nextVar = 0
    , nextOpId = 0
    , mode = mode
    , registry = registry
    , pendingLambdas = []
    , signatures = signatures
    , varMappings = Dict.empty
    }
```

**Change to:**
```elm
initContext : Mode.Mode -> Mono.SpecializationRegistry -> Dict Int FuncSignature -> Context
initContext mode registry signatures =
    { nextVar = 0
    , nextOpId = 0
    , mode = mode
    , registry = registry
    , pendingLambdas = []
    , signatures = signatures
    , varMappings = Dict.empty
    , nextCustomTypeId = 1  -- Start at 1 (0 = unknown)
    , customTypeIds = Dict.empty
    }
```

### 6.3 Add helper to get or create custom type ID

Add after `addVarMapping` (around line 432):
```elm
{-| Get or create a type_id for a custom type.
Returns 0 for non-custom types.
-}
getOrCreateCustomTypeId : Mono.MonoType -> Context -> ( Int, Context )
getOrCreateCustomTypeId monoType ctx =
    case monoType of
        Mono.MCustom _ _ _ ->
            let
                key =
                    Mono.toComparableMonoType monoType
            in
            case Dict.get key ctx.customTypeIds of
                Just tid ->
                    ( tid, ctx )

                Nothing ->
                    let
                        tid =
                            ctx.nextCustomTypeId

                        newMap =
                            Dict.insert key tid ctx.customTypeIds
                    in
                    ( tid
                    , { ctx | nextCustomTypeId = tid + 1, customTypeIds = newMap }
                    )

        _ ->
            -- Non-custom types don't get a type_id
            ( 0, ctx )
```

### 6.4 Update ecoConstruct to include type_id and constructor name

**Current** (around lines 4372-4399):
```elm
ecoConstruct : Context -> String -> Int -> Int -> Int -> List ( String, MlirType ) -> ( Context, MlirOp )
ecoConstruct ctx resultVar tag size unboxedBitmap operands =
    let
        operandNames =
            List.map Tuple.first operands

        operandTypesAttr =
            if List.isEmpty operands then
                Dict.empty
            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map (\( _, t ) -> TypeAttr t) operands))

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

**Change to:**
```elm
ecoConstruct : Context -> String -> Int -> String -> Int -> Int -> Int -> List ( String, MlirType ) -> ( Context, MlirOp )
ecoConstruct ctx resultVar typeId ctorName tag size unboxedBitmap operands =
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

        -- Add type_id and constructor attributes for custom types
        customAttrs =
            if typeId == 0 then
                baseAttrs
            else
                ( "type_id", IntAttr Nothing typeId )
                    :: ( "constructor", StringAttr Nothing ctorName )
                    :: baseAttrs

        attrs =
            Dict.union operandTypesAttr (Dict.fromList customAttrs)
    in
    mlirOp ctx "eco.construct"
        |> opBuilder.withOperands operandNames
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build
```

### 6.5 Update all ecoConstruct call sites

Search for all occurrences of `ecoConstruct` and add `typeId` and `ctorName` parameters.

**Key call sites to update:**

1. **generateCtor** (around line 1396 and 1436):
   - Get `typeId` from `getOrCreateCustomTypeId ctorResultType ctx`
   - Get `ctorName` from `CtorLayout.name` (already available in the layout)
   - Pass `typeId ctorName` to `ecoConstruct`
   ```elm
   let
       ( typeId, ctx1 ) = getOrCreateCustomTypeId resultType ctx
       ctorName = layout.name  -- From CtorLayout.name
   in
   ecoConstruct ctx1 resultVar typeId ctorName tag size unboxedBitmap operands
   ```

2. **generateEnum** (around line 1459):
   - Get `typeId` from `getOrCreateCustomTypeId monoType ctx`
   - Get `ctorName` from `CtorLayout.name`
   - Pass `typeId ctorName` to `ecoConstruct`

3. **generateCycle** (around line 1672):
   - Use `typeId = 0` and `ctorName = ""` (cycle nodes are not Custom types)

4. **List operations** (around lines 1981, 1995, 2013):
   - Use `typeId = 0` and `ctorName = ""` (lists use Cons layout)

5. **Pattern match dummy values** (around lines 2954, 3647, 3729):
   - Use `typeId = 0` and `ctorName = ""`

6. **generateRecordCreate** (around line 4130):
   - Use `typeId = 0` and `ctorName = ""` (records use Record layout)

7. **generateRecordUpdate** (around line 4205):
   - Use `typeId = 0` and `ctorName = ""`

8. **generateTupleCreate** (around line 4267):
   - Use `typeId = 0` and `ctorName = ""` (tuples use Tuple2/Tuple3 layout)

9. **generateUnit** (around line 4287):
   - Use `typeId = 0` and `ctorName = ""`

---

## Step 7: Clamp Unboxed Bitmaps (Elm)

**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

Since we reduced `Custom.unboxed` from 48 to 32 bits, we should clamp bitmaps.

The current code doesn't seem to have explicit bitmap computation for custom constructors in this file. The `CtorLayout` type has `unboxedBitmap : Int` but the computation happens elsewhere.

If `CtorLayout.unboxedBitmap` is computed in the monomorphization phase, ensure fields at index >= 32 are treated as boxed:

```elm
-- In buildCtorLayoutFromArity or similar:
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

---

## Step 8: Populate CtorLayout.name During Monomorphization

**File:** `compiler/src/Compiler/AST/Monomorphized.elm` (or appropriate monomorphization file)

The `CtorLayout` type already has a `name : Name` field. Ensure this field is populated from `Can.Ctor` during the monomorphization process.

### 8.1 Verify CtorLayout.name is populated

**Current** `CtorLayout` type (lines 216-222):
```elm
type alias CtorLayout =
    { name : Name
    , index : Int
    , arity : Int
    , types : List MonoType
    , fieldTypes : List ( Name, MonoType )
    , unboxedBitmap : Int
    }
```

**Action:** During monomorphization when creating `CtorLayout` from `Can.Ctor`, ensure `name` is populated:

```elm
-- When building CtorLayout from Can.Ctor:
buildCtorLayout : Can.Ctor -> ... -> CtorLayout
buildCtorLayout canCtor ... =
    { name = Can.ctorName canCtor  -- Use the actual constructor name
    , index = ...
    , arity = ...
    , types = ...
    , fieldTypes = ...
    , unboxedBitmap = ...
    }
```

### 8.2 Use CtorLayout.name in MLIR codegen

In `generateCtor` and `generateEnum`, access the constructor name from the layout:

```elm
generateCtor : ... -> CtorLayout -> ... -> ...
generateCtor ... layout ... =
    let
        ctorName = layout.name  -- Already available
        ( typeId, ctx1 ) = getOrCreateCustomTypeId resultType ctx
    in
    ecoConstruct ctx1 resultVar typeId ctorName tag size unboxedBitmap operands
```

---

## Resolved Design Decisions

The following questions from the original design have been resolved:

### 1. Constructor Name Table Emission
**Decision:** Use LLVM global constructors (`@llvm.global_ctors`)

Similar to the existing `__eco_init_globals` pattern:
- Emit a function `@_eco_init_custom_ctors` that calls `eco_register_custom_ctors`
- Add this function to `@llvm.global_ctors` with priority 65535
- This ensures initialization runs before `main()` is called

### 2. TableGen Changes
**Decision:** Add `type_id` and `constructor` as first-class attributes in `Ops.td`

- Add `OptionalAttr<I64Attr>:$type_id` to `Eco_ConstructOp`
- Add `OptionalAttr<StrAttr>:$constructor` to `Eco_ConstructOp`
- This provides generated accessors (`op.getTypeId()`, `op.getConstructorAttr()`) for clean lowering code
- Requires rebuilding the Eco dialect after changes

### 3. Constructor Name Source
**Decision:** Populate `CtorLayout.name` from `Can.Ctor` during monomorphization

- `CtorLayout` already has a `name : Name` field
- Ensure this field is populated during the monomorphization phase from `Can.Ctor`
- MLIR codegen can then access `layout.name` when generating `eco.construct` ops
- The `constructor` attribute on `eco.construct` carries the name through to EcoToLLVM lowering

### 4. Deduplication
**Decision:** Deduplicate at table emission time in EcoToLLVM

- Collect all `(typeId, ctorId, name)` tuples during lowering
- Use a `std::set<std::pair<int64_t, int64_t>>` to deduplicate before emitting the global table
- This is more efficient than deduplicating at runtime registration

---

## Testing Strategy

1. **Unit Test**: Verify that `eco_register_custom_ctors` stores mappings correctly
2. **Integration Test**: Create an Elm program with custom types and verify `Debug.log` shows proper names
3. **Regression Test**: Ensure existing tests still pass with the new `eco_alloc_custom` signature

Example test case:
```elm
type Color = Red | Green | Blue
type Maybe a = Just a | Nothing

main =
    let
        _ = Debug.log "color" Red
        _ = Debug.log "maybe" (Just 42)
        _ = Debug.log "nothing" Nothing
    in
    text "done"
```

Expected output:
```
color: Red
maybe: Just 42
nothing: Nothing
```

---

## Implementation Order

1. **Phase 1 (Runtime)**: Update heap layout and runtime API
   - Step 1: Heap.hpp - Add `id` field to Custom struct
   - Step 2: RuntimeExports.h/cpp - Update `eco_alloc_custom` signature
   - Step 2: RuntimeExports.cpp - Add `eco_register_custom_ctors` and `g_customCtorNames`
   - Step 2: RuntimeExports.cpp - Update `print_custom` to use name lookup
   - Step 3: RuntimeSymbols.cpp - Register new JIT symbols

2. **Phase 2 (TableGen)**: Update Eco dialect
   - Step 4: Ops.td - Add `type_id` and `constructor` attributes to Eco_ConstructOp
   - Rebuild to regenerate Ops.h.inc and Ops.cpp.inc

3. **Phase 3 (Lowering)**: Update EcoToLLVM pass
   - Step 5: EcoToLLVM.cpp - Update `eco_alloc_custom` call signature (4 args)
   - Step 5: EcoToLLVM.cpp - Extract type_id and constructor from ops
   - Step 5: EcoToLLVM.cpp - Collect constructor info during lowering
   - Step 5: EcoToLLVM.cpp - Emit constructor table and `_eco_init_custom_ctors`
   - Step 5: EcoToLLVM.cpp - Add to `@llvm.global_ctors`

4. **Phase 4 (Compiler)**: Elm codegen changes
   - Step 8: Verify CtorLayout.name is populated from Can.Ctor during monomorphization
   - Step 6: MLIR.elm - Add `nextCustomTypeId`/`customTypeIds` to Context
   - Step 6: MLIR.elm - Add `getOrCreateCustomTypeId` helper
   - Step 6: MLIR.elm - Update `ecoConstruct` signature (add typeId, ctorName)
   - Step 6: MLIR.elm - Update all `ecoConstruct` call sites

5. **Phase 5 (Validation)**: Testing
   - Run existing tests to ensure no regressions
   - Create custom type test to verify constructor names print correctly
   - Verify `@llvm.global_ctors` initialization works in JIT
