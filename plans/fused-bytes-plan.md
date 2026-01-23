# Fused Bytes Compilation - Unified Implementation Plan

**Goal:** Compile Elm's `Bytes.Encode` and `Bytes.Decode` expressions into fused, single-loop byte kernels, bypassing stub implementations for dramatically improved performance.

**Design Document:** `/work/design_docs/fused-bytes-compilation.md`

---

## Executive Summary

This unified plan covers four phases of implementation:

| Phase | Focus | Key Capability |
|-------|-------|----------------|
| **Phase 1** | Encoder | Fuse `Bytes.Encode.encode` with sequence/primitives |
| **Phase 2** | Decoder | Fuse `Bytes.Decode.decode` with map/map2-5/primitives |
| **Phase 3** | andThen | Length-prefixed patterns (`andThen \len -> Decode.string len`) |
| **Phase 4** | loop | Variable-length sequences via `Decode.loop` |

Each phase builds on the previous, sharing infrastructure:
- **Runtime ABI** (`ElmBytesRuntime.h/cpp`) - C functions for byte operations
- **bf MLIR Dialect** - Custom dialect for byte cursor operations  
- **Compiler modules** - AST recognizers, Loop IR, MLIR emitters

### Key Architecture Insight

Encoders and decoders are **NOT** runtime ADTs. They are **monomorphized expression trees** made of `MonoCall`/`MonoVarGlobal`/`MonoVarKernel` nodes.

**Therefore:** Reification is **pure AST pattern matching** that happens **before MLIR emission**.

### SSA-Threaded Cursor Design

Each `bf.write.*` / `bf.read.*` returns a new `!bf.cur` value. The cursor is threaded through `EmitState` - no `Context.setVar` needed:

```elm
type alias EmitState =
    { ctx : Context
    , cursor : String        -- Current cursor SSA variable
    , bufferVar : String     -- The allocated ByteBuffer*
    , ops : List MlirOp
    }
```

---

## Table of Contents

1. [Phase 1: Encoder Fusion](#phase-1-encoder-fusion)
2. [Phase 2: Decoder Fusion](#phase-2-decoder-fusion)
3. [Phase 3: andThen Support](#phase-3-andthen-support)
4. [Phase 4: loop Support](#phase-4-loop-support)
5. [Combined File Summary](#combined-file-summary)
6. [Combined Questions and Assumptions](#combined-questions-and-assumptions)
7. [Overall Implementation Order](#overall-implementation-order)

---

## Critical Design Constraint: Stable Accessors Only

**IMPORTANT:** The `Header` struct uses bitfields whose layout is **NOT ABI-stable**. All MLIR lowering code (bf → LLVM) must **NEVER** GEP directly into header fields.

**Clarification:** The `elm_*` runtime helpers in `ElmBytesRuntime.cpp` **are allowed** to access `header.size` directly - that's their purpose. The constraint applies only to generated MLIR/LLVM code.

**Rule:** All `header.size` reads/writes and pointer arithmetic must go through `elm_*` runtime helpers:

| Operation | Use This Helper | NOT This |
|-----------|-----------------|----------|
| Get buffer length | `elm_bytebuffer_len(bb)` | `bb->header.size` |
| Get buffer data pointer | `elm_bytebuffer_data(bb)` | `bb->bytes` or GEP |
| Get buffer end pointer | `elm_bytebuffer_data(bb) + elm_bytebuffer_len(bb)` | Direct arithmetic |
| Get string length | Runtime string accessor | `s->header.size` |

This applies to:
- bf → LLVM lowering (must call helpers, not inline struct access)
- Runtime ABI implementations (helpers encapsulate layout knowledge)
- Cursor initialization (compute `(ptr, end)` via helper calls)

---
---

# Phase 1: Encoder Fusion

**Goal:** Compile `Bytes.Encode` expressions into fused, single-loop byte kernels, bypassing the current stub implementations.

**Design Document:** `/work/design_docs/fused-bytes-compilation.md`

---

## Key Architecture Insight

The encoder is **NOT** a runtime ADT that can be destructured. Instead, it's a **monomorphized expression tree** made of `MonoCall`/`MonoVarGlobal`/`MonoVarKernel` nodes.

**Therefore:** `reifyEncoder` must be a **pure AST recognizer** over `MonoExpr` that:
- Recognizes `MonoCall` to `Bytes.Encode.sequence` with a `MonoList` argument
- Recognizes `MonoCall` to `Bytes.Encode.unsignedInt8` with a value argument
- Recursively reifies nested encoders
- Returns `Maybe (List EncoderNode)` for the normalized encoder sequence

This happens **before MLIR emission**, not after.

---

## Overview

```
Elm source
  ↓ (standard compilation)
Monomorphized AST (MonoExpr)
  ↓ (recognizer in generateSaturatedCall)
Encoder AST pattern detected?
  ↓ YES                           ↓ NO
reifyEncoder : MonoExpr           Fall back to kernel call
  → Maybe (List EncoderNode)      (stub Elm_Kernel_Bytes_encode)
  ↓
Loop IR (fused cursor ops)
  ↓
bf dialect MLIR
  ↓ (BFToLLVM pass)
LLVM IR
  ↓
Native code
```

---

## Step 1: Runtime ABI Foundation

### 1.1 Create `runtime/src/allocator/ElmBytesRuntime.h`

**✅ CORRECTION C10: All heap values use `u64` (eco.value) at the C ABI boundary.**

The runtime helpers take/return `u64` for Elm heap objects. Internal pointer conversion
happens only inside `ElmBytesRuntime.cpp`. This matches `!eco.value` lowering to `i64`.

```c
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint8_t  u8;
typedef uint32_t u32;
typedef uint64_t u64;  // eco.value representation

// ============================================================================
// ByteBuffer operations (heap values are u64)
// ============================================================================

// Allocate ByteBuffer with byteCount bytes. Returns eco.value (u64).
u64 elm_alloc_bytebuffer(u32 byteCount);

// Return ByteBuffer byte length. Takes eco.value (u64).
u32 elm_bytebuffer_len(u64 bb);

// Return pointer to first payload byte. Takes eco.value (u64).
// Returns raw pointer (for cursor setup only - not an eco.value).
u8* elm_bytebuffer_data(u64 bb);

// ============================================================================
// String operations (heap values are u64)
// ============================================================================

// Return UTF-8 byte width of an ElmString. Takes eco.value (u64).
u32 elm_utf8_width(u64 elmString);

// Copy ElmString as UTF-8 bytes to dst buffer. Returns bytes written.
u32 elm_utf8_copy(u64 elmString, u8* dst);

// ✅ FINAL: Failure signaling for elm_utf8_decode
//
// Preferred ABI (if eco.value(0) is guaranteed invalid in your runtime):
//   - Return 0 on failure (invalid UTF-8), else return a valid eco.value.
//
// HARD GATE (must be verified before implementation):
//   Confirm that eco.value == 0 can never represent a valid Elm heap value.
//
// If eco.value(0) could ever be valid, DO NOT use the 0-sentinel.
// Use this alternative ABI instead:
//
//   bool elm_utf8_decode_checked(const u8* src, u32 len, u64* outValue);
//
// and expose it to MLIR lowering as:
//   i1 @elm_utf8_decode_checked(i8* src, i32 len, i64* outValue)
//
// (This avoids ambiguous sentinel values.)
u64 elm_utf8_decode(const u8* src, u32 len);

// ============================================================================
// Maybe operations (heap values are u64)
// ============================================================================

// Return Nothing as eco.value (u64).
u64 elm_maybe_nothing(void);

// Return Just(value) as eco.value (u64).
u64 elm_maybe_just(u64 value);

#ifdef __cplusplus
}
#endif
```

### 1.2 Create `runtime/src/allocator/ElmBytesRuntime.cpp`

**✅ CORRECTED C17: Header Access Clarification**

The runtime helpers (`elm_bytebuffer_len`, `elm_bytebuffer_data`, etc.) are the **ONLY** code allowed to access `header.size` and other struct internals directly. This is NOT a contradiction with the "NEVER GEP into headers" rule - that rule applies to **generated MLIR/LLVM code**, not to these C++ helpers.

The purpose of these helpers is to encapsulate layout knowledge so generated code doesn't need it.

**IMPORTANT:** UTF-8 helpers must be **thin wrappers** around existing runtime string infrastructure to avoid baking in layout assumptions. Do NOT iterate over presumed UTF-16 storage directly.

Implementation approach:
- `elm_alloc_bytebuffer` - use existing allocator infrastructure (encapsulate header setup)
- `elm_bytebuffer_len` / `elm_bytebuffer_data` - thin accessors **(allowed to access header.size internally)**
- `elm_utf8_width` - **delegate to existing StringOps** UTF-8 sizing logic
- `elm_utf8_copy` - **delegate to existing StringOps** UTF-8 encoding logic

```cpp
// ✅ CORRECTED C19: All signatures use u64 (eco.value), matching header exactly

#include "ElmBytesRuntime.h"
#include "Heap.hpp"
#include "Allocator.hpp"
#include "StringOps.hpp"  // Use existing string runtime!

// Helper: convert eco.value (u64) to internal pointer
// This encapsulates the eco.value → pointer conversion in one place
static inline ByteBuffer* toByteBuffer(u64 val) {
    return reinterpret_cast<ByteBuffer*>(static_cast<uintptr_t>(val));
}

static inline ElmString* toElmString(u64 val) {
    return reinterpret_cast<ElmString*>(static_cast<uintptr_t>(val));
}

static inline u64 toEcoValue(void* ptr) {
    return static_cast<u64>(reinterpret_cast<uintptr_t>(ptr));
}

extern "C" {

u64 elm_alloc_bytebuffer(u32 byteCount) {
    // Use existing allocator - encapsulate size computation and header setup
    ByteBuffer* bb = ByteBuffer::allocate(byteCount);
    return toEcoValue(bb);
}

u32 elm_bytebuffer_len(u64 bbVal) {
    // Convert eco.value to pointer, then access layout
    ByteBuffer* bb = toByteBuffer(bbVal);
    return ByteBuffer::length(bb);
}

u8* elm_bytebuffer_data(u64 bbVal) {
    // Convert eco.value to pointer, then access data
    ByteBuffer* bb = toByteBuffer(bbVal);
    return ByteBuffer::data(bb);
}

u32 elm_utf8_width(u64 strVal) {
    // DELEGATE to existing StringOps - do NOT manually iterate UTF-16
    ElmString* str = toElmString(strVal);
    return StringOps::utf8ByteLength(str);
}

u32 elm_utf8_copy(u64 strVal, u8* dst) {
    // DELEGATE to existing StringOps - do NOT manually iterate UTF-16
    ElmString* str = toElmString(strVal);
    return StringOps::writeUtf8(str, dst);
}

u64 elm_utf8_decode(const u8* src, u32 len) {
    // DELEGATE to existing StringOps for UTF-8 → internal string conversion
    // Returns eco.value (u64) or 0 on failure (see C22 for failure semantics)
    ElmString* str = StringOps::fromUtf8(src, len);
    if (!str) return 0;  // Failure sentinel - see C22
    return toEcoValue(str);
}

u64 elm_maybe_nothing() {
    // Return eco.value for Nothing singleton
    return toEcoValue(Maybe::nothing());
}

u64 elm_maybe_just(u64 value) {
    // Wrap value in Just, return eco.value
    return toEcoValue(Maybe::just(value));
}

} // extern "C"
```

**Implementation Note:** The exact method names (`ByteBuffer::allocate`, `StringOps::utf8ByteLength`, etc.) depend on your existing runtime. The key principle is:
1. **`ElmBytesRuntime.cpp` is the *only* place allowed to know the ByteBuffer/String header layout**; all generated MLIR/LLVM must call `elm_bytebuffer_len/data` instead of GEPs.
2. **Never iterate `s->chars[]` directly** - use existing string utilities
3. These helpers become the **single source of truth** for layout knowledge

### 1.3 Update `runtime/src/codegen/CMakeLists.txt`

Add to `ecoc` sources (line ~196) and `EcoRunner` sources (line ~263):

```cmake
../allocator/ElmBytesRuntime.cpp
../allocator/BytesOps.cpp
```

### 1.4 Update `runtime/src/codegen/RuntimeSymbols.cpp`

Add include at top:
```cpp
#include "../allocator/ElmBytesRuntime.h"
```

Add symbol registrations (after line ~100):
```cpp
// ByteFusion runtime symbols
symbolMap[interner("elm_alloc_bytebuffer")] =
    llvm::orc::ExecutorSymbolDef(
        llvm::orc::ExecutorAddr::fromPtr(&elm_alloc_bytebuffer),
        llvm::JITSymbolFlags::Exported);
symbolMap[interner("elm_bytebuffer_len")] =
    llvm::orc::ExecutorSymbolDef(
        llvm::orc::ExecutorAddr::fromPtr(&elm_bytebuffer_len),
        llvm::JITSymbolFlags::Exported);
symbolMap[interner("elm_bytebuffer_data")] =
    llvm::orc::ExecutorSymbolDef(
        llvm::orc::ExecutorAddr::fromPtr(&elm_bytebuffer_data),
        llvm::JITSymbolFlags::Exported);

symbolMap[interner("elm_utf8_width")] =
    llvm::orc::ExecutorSymbolDef(
        llvm::orc::ExecutorAddr::fromPtr(&elm_utf8_width),
        llvm::JITSymbolFlags::Exported);
symbolMap[interner("elm_utf8_copy")] =
    llvm::orc::ExecutorSymbolDef(
        llvm::orc::ExecutorAddr::fromPtr(&elm_utf8_copy),
        llvm::JITSymbolFlags::Exported);
symbolMap[interner("elm_utf8_decode")] =
    llvm::orc::ExecutorSymbolDef(
        llvm::orc::ExecutorAddr::fromPtr(&elm_utf8_decode),
        llvm::JITSymbolFlags::Exported);

symbolMap[interner("elm_maybe_nothing")] =
    llvm::orc::ExecutorSymbolDef(
        llvm::orc::ExecutorAddr::fromPtr(&elm_maybe_nothing),
        llvm::JITSymbolFlags::Exported);
symbolMap[interner("elm_maybe_just")] =
    llvm::orc::ExecutorSymbolDef(
        llvm::orc::ExecutorAddr::fromPtr(&elm_maybe_just),
        llvm::JITSymbolFlags::Exported);
```

---

## Step 2: bf MLIR Dialect

*(Same as previous plan - creating BF directory with TableGen files)*

### 2.1-2.5 Create bf dialect infrastructure

Files to create in `runtime/src/codegen/BF/`:
- `BFDialect.td` - Dialect definition
- `BFOps.td` - Types and operations
- `BFDialect.h/.cpp` - C++ scaffolding
- `BFOps.h/.cpp` - Generated includes
- `BFTypes.h/.cpp` - Type definitions

**Operations (MVP for encoder):**
- `bf.alloc` - Allocate ByteBuffer
- `bf.cursor.init` - Create cursor from ByteBuffer*
- `bf.write.u8(cur, i64) -> !bf.cur` (uses low 8 bits)
- `bf.write.u16_be/le(cur, i64) -> !bf.cur` (uses low 16 bits)
- `bf.write.u32_be/le(cur, i64) -> !bf.cur` (uses low 32 bits)
- `bf.write.f32_be/le(cur, f64) -> !bf.cur` (casts f64 → f32 then writes bytes)
- `bf.write.f64_be/le(cur, f64) -> !bf.cur`
- `bf.write.bytes_copy(cur, !eco.value) -> !bf.cur` - Copy ByteBuffer payload
- `bf.write.utf8(cur, !eco.value) -> !bf.cur` - Copy UTF-8 string bytes
- `bf.require` - Bounds check (for decoder support)

---

## Step 3: bf → LLVM Lowering

### 3.1 Create `runtime/src/codegen/Passes/BFToLLVM.cpp`

**Cursor representation:** `(ptr, end)` as LLVM struct `{ i8*, i8* }`

**⚠️ IMPORTANT: Runtime Call Requirements**

The bf → LLVM lowering emits calls to `elm_*` runtime helpers (e.g., `@elm_utf8_copy`, `@elm_bytebuffer_data`). For these to work:

1. **Symbol Registration** (already covered in Step 1.3) - JIT must know these symbols
2. **LLVM Call Emission** - Use `LLVM::CallOp` with proper function type
3. **Extern Declarations** - If EcoToLLVM pass requires explicit extern function declarations, add them to the module:

```cpp
// ✅ CORRECTED: Runtime functions use i64 for eco.value types

// In BFToLLVM.cpp, ensure extern functions are declared
void declareRuntimeFunctions(ModuleOp module) {
    auto builder = OpBuilder::atBlockEnd(module.getBody());
    auto i64 = builder.getI64Type();  // eco.value is i64
    auto i32 = builder.getI32Type();
    auto i8Ptr = LLVM::LLVMPointerType::get(builder.getContext());  // For cursor ptr

    // Helpers that take/return eco.value use i64:

    // extern u32 elm_utf8_copy(i64 elmString, u8* dst)
    // Takes eco.value (i64) for the string, raw ptr for destination
    auto utf8CopyType = LLVM::LLVMFunctionType::get(i32, {i64, i8Ptr});
    builder.create<LLVM::LLVMFuncOp>(module.getLoc(), "elm_utf8_copy", utf8CopyType);

    // extern u8* elm_bytebuffer_data(i64 bb)
    // Takes eco.value (i64), returns raw ptr (for cursor setup)
    auto dataType = LLVM::LLVMFunctionType::get(i8Ptr, {i64});
    builder.create<LLVM::LLVMFuncOp>(module.getLoc(), "elm_bytebuffer_data", dataType);

    // extern u32 elm_bytebuffer_len(i64 bb)
    auto lenType = LLVM::LLVMFunctionType::get(i32, {i64});
    builder.create<LLVM::LLVMFuncOp>(module.getLoc(), "elm_bytebuffer_len", lenType);

    // extern i64 elm_alloc_bytebuffer(u32 size)
    // Returns eco.value (i64) for the new ByteBuffer
    // ✅ CORRECTED C11: Symbol name matches header (elm_alloc_bytebuffer, not elm_bytebuffer_alloc)
    auto allocType = LLVM::LLVMFunctionType::get(i64, {i32});
    builder.create<LLVM::LLVMFuncOp>(module.getLoc(), "elm_alloc_bytebuffer", allocType);

    // extern i64 elm_maybe_nothing()
    auto nothingType = LLVM::LLVMFunctionType::get(i64, {});
    builder.create<LLVM::LLVMFuncOp>(module.getLoc(), "elm_maybe_nothing", nothingType);

    // extern i64 elm_maybe_just(i64 value)
    auto justType = LLVM::LLVMFunctionType::get(i64, {i64});
    builder.create<LLVM::LLVMFuncOp>(module.getLoc(), "elm_maybe_just", justType);

    // extern i64 elm_utf8_decode(u8* src, u32 len)
    // Returns eco.value (i64) for ElmString (or tagged null on failure)
    auto decodeType = LLVM::LLVMFunctionType::get(i64, {i8Ptr, i32});
    builder.create<LLVM::LLVMFuncOp>(module.getLoc(), "elm_utf8_decode", decodeType);

    // ✅ CORRECTED C11: Removed elm_bytes_slice - use bf.read.bytes which calls
    // elm_alloc_bytebuffer + memcpy internally. No separate "slice" helper needed.
}
```

**Key insight:** The `!bf.cur` type is internal to bf dialect and lowered to `{i8*, i8*}`.
But `!eco.value` is the boundary type for Elm heap objects and is lowered to `i64`.

Key lowering patterns (same as before, but with UTF-8 details):

- `bf.write.utf8(cur, elmString)`:
  1. `bytesWritten = call @elm_utf8_copy(elmString, cur.ptr)`
  2. `newPtr = gep cur.ptr, bytesWritten`
  3. Return `(newPtr, end)`

### 3.2-3.3 Register pass and update pipeline

*(Same as previous plan)*

---

## Step 4: Compiler Frontend - Encoder Reification

**This is the key changed section.**

### 4.1 Create `compiler/src/Compiler/Generate/MLIR/BytesFusion/LoopIR.elm`

```elm
module Compiler.Generate.MLIR.BytesFusion.LoopIR exposing (..)

{-| Loop IR for fused byte encoding.

Values are represented as MonoExpr to preserve the original AST
structure for later MLIR emission.
-}

import Compiler.AST.Monomorphized as Mono


type Endianness
    = LE
    | BE


{-| Expression for computing buffer width.
-}
type WidthExpr
    = WConst Int
    | WAdd WidthExpr WidthExpr
    | WStringUtf8Width Mono.MonoExpr  -- Runtime: elm_utf8_width
    | WBytesWidth Mono.MonoExpr       -- Runtime: elm_bytebuffer_len


{-| Loop IR operations for encoding.
Values are MonoExpr (not yet lowered to MLIR SSA).
-}
type Op
    = InitCursor String WidthExpr      -- cursorName, totalWidth (allocate buffer)
    | WriteU8 String Mono.MonoExpr     -- cursorName, value expression
    | WriteU16 String Endianness Mono.MonoExpr
    | WriteU32 String Endianness Mono.MonoExpr
    | WriteF32 String Endianness Mono.MonoExpr
    | WriteF64 String Endianness Mono.MonoExpr
    | WriteBytesCopy String Mono.MonoExpr  -- cursorName, bytes expression
    | WriteUtf8 String Mono.MonoExpr       -- cursorName, string expression
    | ReturnBuffer                         -- Return the allocated buffer


{-| Simplify width expression by folding constants.
-}
simplifyWidth : WidthExpr -> WidthExpr
simplifyWidth expr =
    case expr of
        WAdd (WConst a) (WConst b) ->
            WConst (a + b)

        WAdd a b ->
            let
                a_ = simplifyWidth a
                b_ = simplifyWidth b
            in
            case ( a_, b_ ) of
                ( WConst 0, _ ) -> b_
                ( _, WConst 0 ) -> a_
                ( WConst x, WConst y ) -> WConst (x + y)
                _ -> WAdd a_ b_

        _ ->
            expr
```

### 4.2 Create `compiler/src/Compiler/Generate/MLIR/BytesFusion/Reify.elm`

**This is the critical new module: pattern-match MonoExpr to recognize encoder combinators.**

```elm
module Compiler.Generate.MLIR.BytesFusion.Reify exposing (reifyEncoder)

{-| Reify a MonoExpr representing a Bytes.Encode.Encoder into
a normalized list of encoder operations.

This is a PURE AST RECOGNIZER that pattern-matches the monomorphized
expression tree to identify Bytes.Encode combinator calls.
-}

import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..), Global(..))
import Compiler.Elm.Package as Pkg
import Compiler.Generate.MLIR.BytesFusion.LoopIR as IR exposing (Endianness(..), Op(..), WidthExpr(..))
import Data.IO as IO exposing (Canonical(..))


{-| Normalized encoder node (after flattening sequences).
-}
type EncoderNode
    = EU8 Mono.MonoExpr
    | EU16 Endianness Mono.MonoExpr
    | EU32 Endianness Mono.MonoExpr
    | EF32 Endianness Mono.MonoExpr
    | EF64 Endianness Mono.MonoExpr
    | EBytes Mono.MonoExpr
    | EUtf8 Mono.MonoExpr


{-| Try to reify a MonoExpr into a list of encoder nodes.
Returns Nothing if the expression contains dynamic/opaque encoders.
-}
reifyEncoder : Mono.MonoRegistry -> Mono.MonoExpr -> Maybe (List EncoderNode)
reifyEncoder registry expr =
    reifyEncoderHelp registry expr
        |> Maybe.map flattenSequences


{-| Internal helper that returns nested structure.
-}
reifyEncoderHelp : Mono.MonoRegistry -> Mono.MonoExpr -> Maybe (List EncoderNode)
reifyEncoderHelp registry expr =
    case expr of
        -- Call to a Bytes.Encode function
        Mono.MonoCall _ func args _ ->
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    case Mono.lookupSpecKey specId registry of
                        Just ( Mono.Global (IO.Canonical pkg moduleName) name, _, _ ) ->
                            if pkg == Pkg.bytes && moduleName == "Bytes.Encode" then
                                reifyBytesEncodeCall registry name args

                            else
                                -- Not a Bytes.Encode function
                                Nothing

                        _ ->
                            Nothing

                Mono.MonoVarKernel _ "Bytes" name _ ->
                    -- Kernel function from Bytes module
                    reifyBytesKernelCall registry name args

                _ ->
                    -- Unknown function - can't reify
                    Nothing

        -- A let binding - reify the body
        -- ⚠️ CORRECTION 4: This is UNSOUND as written!
        -- If body is `MonoVarLocal x` referencing the let-bound encoder,
        -- reifyEncoderHelp will return Nothing (MonoVarLocal is opaque).
        -- Compiler pipelines often introduce lets, defeating fusion.
        Mono.MonoLet letDef body _ ->
            {- HARD GATE (C18):
               Do not implement MonoLet handling until MonoLet / MonoLetDef is grounded
               from Compiler/AST/Monomorphized.elm.

               Once grounded, implement environment-based substitution:

                 reifyEncoderWithEnv : Dict Name (List EncoderNode) -> MonoExpr -> Maybe (List EncoderNode)

               Rules:
               1) If a let binding RHS reifies successfully, extend env with (name -> nodes)
               2) When encountering MonoVarLocal name, consult env
               3) Fall back to Nothing if the let introduces non-reifiable structure

               This avoids relying on non-existent fields like def.name/def.body.
            -}
            Nothing

        -- Variable reference - can't statically analyze
        _ ->
            Nothing


{-| Reify a call to a Bytes.Encode.* function.
-}
reifyBytesEncodeCall : Mono.MonoRegistry -> String -> List Mono.MonoExpr -> Maybe (List EncoderNode)
reifyBytesEncodeCall registry name args =
    case ( name, args ) of
        ( "sequence", [ listExpr ] ) ->
            -- sequence : List Encoder -> Encoder
            reifyEncoderList registry listExpr

        ( "unsignedInt8", [ valueExpr ] ) ->
            Just [ EU8 valueExpr ]

        ( "signedInt8", [ valueExpr ] ) ->
            -- Signed and unsigned have same encoding for 8 bits
            Just [ EU8 valueExpr ]

        ( "unsignedInt16", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU16 e valueExpr ])

        ( "signedInt16", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU16 e valueExpr ])

        ( "unsignedInt32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU32 e valueExpr ])

        ( "signedInt32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EU32 e valueExpr ])

        ( "float32", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EF32 e valueExpr ])

        ( "float64", [ endiannessExpr, valueExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map (\e -> [ EF64 e valueExpr ])

        ( "bytes", [ bytesExpr ] ) ->
            Just [ EBytes bytesExpr ]

        ( "string", [ stringExpr ] ) ->
            Just [ EUtf8 stringExpr ]

        _ ->
            -- Unknown Bytes.Encode function
            Nothing


{-| Reify a kernel call (e.g., from Elm.Kernel.Bytes).
-}
reifyBytesKernelCall : Mono.MonoRegistry -> String -> List Mono.MonoExpr -> Maybe (List EncoderNode)
reifyBytesKernelCall registry name args =
    -- Kernel functions like write_i8, write_u16, etc.
    case ( name, args ) of
        ( "write_u8", [ valueExpr ] ) ->
            Just [ EU8 valueExpr ]

        ( "write_i8", [ valueExpr ] ) ->
            Just [ EU8 valueExpr ]

        -- Add more kernel function patterns as needed
        _ ->
            Nothing


{-| Reify a list of encoders (from sequence argument).
-}
reifyEncoderList : Mono.MonoRegistry -> Mono.MonoExpr -> Maybe (List EncoderNode)
reifyEncoderList registry listExpr =
    case listExpr of
        Mono.MonoList _ items _ ->
            -- Literal list of encoders
            items
                |> List.map (reifyEncoderHelp registry)
                |> combineResults
                |> Maybe.map List.concat

        _ ->
            -- Dynamic list - can't statically analyze
            Nothing


{-| Reify an endianness expression (BE or LE).

Based on MonoExpr structure:
- `MonoVarGlobal Region SpecId MonoType` references global values including constructors
- `Mono.lookupSpecKey` returns `Maybe (Global, MonoType, Maybe LambdaId)` (a tuple!)
- `Global = Global IO.Canonical Name | Accessor Name`

Bytes.BE and Bytes.LE are nullary constructors of Bytes.Endianness.
-}
reifyEndianness : Mono.MonoRegistry -> Mono.MonoExpr -> Maybe Endianness
reifyEndianness registry expr =
    case expr of
        -- Nullary constructors are represented as MonoVarGlobal
        Mono.MonoVarGlobal _ specId _ ->
            case Mono.lookupSpecKey specId registry of
                Just (Mono.Global (IO.Canonical pkg moduleName) name, _, _) ->
                    if pkg == Pkg.bytes && moduleName == "Bytes" then
                        case name of
                            "LE" -> Just LE
                            "BE" -> Just BE
                            _ -> Nothing
                    else
                        Nothing

                _ ->
                    Nothing

        -- Unwrap trivial zero-arg calls (sometimes nullary ctors get wrapped)
        Mono.MonoCall _ fn [] _ ->
            reifyEndianness registry fn

        _ ->
            Nothing


{-| Flatten nested sequences.
-}
flattenSequences : List EncoderNode -> List EncoderNode
flattenSequences nodes =
    -- Already flat since we recursively reify
    nodes


{-| Combine a list of Maybe results.
-}
combineResults : List (Maybe a) -> Maybe (List a)
combineResults maybes =
    List.foldr
        (\ma acc ->
            Maybe.map2 (::) ma acc
        )
        (Just [])
        maybes
```

### 4.3 Create `compiler/src/Compiler/Generate/MLIR/BytesFusion/Compile.elm`

**Compile EncoderNodes to Loop IR operations.**

```elm
module Compiler.Generate.MLIR.BytesFusion.Compile exposing (compileEncoder)

{-| Compile a list of EncoderNodes to Loop IR operations.
-}

import Compiler.Generate.MLIR.BytesFusion.LoopIR as IR exposing (Endianness(..), Op(..), WidthExpr(..))
import Compiler.Generate.MLIR.BytesFusion.Reify exposing (EncoderNode(..))


{-| Compile encoder nodes to Loop IR.
-}
compileEncoder : List EncoderNode -> List Op
compileEncoder nodes =
    let
        totalWidth =
            nodes
                |> List.map widthOf
                |> List.foldl IR.WAdd (IR.WConst 0)
                |> IR.simplifyWidth

        curName =
            "cur"
    in
    [ InitCursor curName totalWidth ]
        ++ List.map (emitWrite curName) nodes
        ++ [ ReturnBuffer ]


{-| Compute width of an encoder node.
-}
widthOf : EncoderNode -> WidthExpr
widthOf node =
    case node of
        EU8 _ -> WConst 1
        EU16 _ _ -> WConst 2
        EU32 _ _ -> WConst 4
        EF32 _ _ -> WConst 4
        EF64 _ _ -> WConst 8
        EBytes bytesExpr -> WBytesWidth bytesExpr
        EUtf8 stringExpr -> WStringUtf8Width stringExpr


{-| Generate write operation for an encoder node.
-}
emitWrite : String -> EncoderNode -> Op
emitWrite curName node =
    case node of
        EU8 expr -> WriteU8 curName expr
        EU16 e expr -> WriteU16 curName e expr
        EU32 e expr -> WriteU32 curName e expr
        EF32 e expr -> WriteF32 curName e expr
        EF64 e expr -> WriteF64 curName e expr
        EBytes expr -> WriteBytesCopy curName expr
        EUtf8 expr -> WriteUtf8 curName expr
```

### 4.4 Create `compiler/src/Compiler/Generate/MLIR/BytesFusion/EmitBF.elm`

**Emit bf MLIR ops from Loop IR operations.**

**Key Design Decision:** Use **SSA-threaded cursor** approach instead of `Context.setVar`.
Each `bf.write.*` returns a new `!bf.cur`, and we thread that value through the emitter loop.
This is natural for SSA and avoids needing mutable variable tracking in Context.

---

#### ⚠️ CORRECTION 1: Op Accumulation Order Bug

**Problem:** The code mixes `::` (cons) with `++` (append) when `EmitState.ops` is "accumulated in reverse". This causes incorrect MLIR program order:

```elm
-- BUGGY:
ops = writeOp :: (valueResult.ops ++ st.ops)
-- If valueResult.ops = [a, b] and st.ops = [c, d] (reverse order means d executes first)
-- Result: [writeOp, a, b, c, d]
-- After List.reverse: [d, c, b, a, writeOp]  -- WRONG! a,b should come before writeOp
```

**Fix (Option B - keep reverse invariant):** When splicing in a list, reverse it first:
```elm
ops = writeOp :: (List.reverse valueResult.ops ++ st.ops)
```

Or use **Option A (recommended):** Store ops in forward order, never reverse at end.

---

#### ✅ CORRECTION 2 APPLIED: bf.cur Is a Dialect Type

**Requirement:** `!bf.cur` is a bf dialect type. Only BFToLLVM lowering maps it to `{i8*, i8*}`.

**Implementation:** Add to `Types.elm`:
```elm
-- In Compiler/Generate/MLIR/Types.elm:

{-| bf dialect cursor type (!bf.cur)
    Lowered to {i8*, i8*} (ptr, end) by BFToLLVM pass.
-}
bfCur : MlirType
bfCur =
    DialectType "bf" "cur"
```

**Ensure `MlirType` has `DialectType` constructor:**
```elm
-- In Mlir/Mlir.elm:
type MlirType
    = I1 | I8 | I16 | I32 | I64 | F32 | F64
    | NamedStruct String
    | DialectType String String  -- dialectName, typeName (e.g. "bf", "cur")
    | ...
```

All code in this plan now uses `Types.bfCur` (representing `!bf.cur`).

---

#### ✅ CORRECTION C4: _operand_types Attrs for arith.* Ops

**Problem:** Raw `arith.addi`/`arith.andi`/`arith.extui` calls need `_operand_types`.

**SOLUTION: Add helpers to `Ops.elm`** (recommended over hand-rolling attrs):

```elm
-- In Compiler/Generate/MLIR/Ops.elm:

{-| arith.addi with proper _operand_types attr -}
arithAddI32 : Context -> String -> String -> String -> ( Context, MlirOp )
arithAddI32 ctx aVar bVar resVar =
    mlirOp ctx "arith.addi"
        |> opBuilder.withOperands [ aVar, bVar ]
        |> opBuilder.withResults [ ( resVar, I32 ) ]
        |> opBuilder.withAttrs
            [ ( "_operand_types"
              , ArrayAttr [ TypeAttr I32, TypeAttr I32 ]
              )
            ]
        |> opBuilder.build

{-| arith.andi for i1 (boolean and) -}
arithAndI1 : Context -> String -> String -> String -> ( Context, MlirOp )
arithAndI1 ctx aVar bVar resVar =
    mlirOp ctx "arith.andi"
        |> opBuilder.withOperands [ aVar, bVar ]
        |> opBuilder.withResults [ ( resVar, I1 ) ]
        |> opBuilder.withAttrs
            [ ( "_operand_types"
              , ArrayAttr [ TypeAttr I1, TypeAttr I1 ]
              )
            ]
        |> opBuilder.build

{-| arith.extui (unsigned extend) -}
arithExtUI : Context -> String -> MlirType -> MlirType -> String -> ( Context, MlirOp )
arithExtUI ctx srcVar srcTy dstTy resVar =
    mlirOp ctx "arith.extui"
        |> opBuilder.withOperands [ srcVar ]
        |> opBuilder.withResults [ ( resVar, dstTy ) ]
        |> opBuilder.withAttrs
            [ ( "_operand_types"
              , ArrayAttr [ TypeAttr srcTy ]
              )
            ]
        |> opBuilder.build
```

**Usage in emitters:**
```elm
-- Instead of hand-rolling:
( ctx2, addOp ) = Ops.arithAddI32 ctx1 aVar bVar resVar
( ctx2, andOp ) = Ops.arithAndI1 ctx1 ok1 ok2 combinedOk
( ctx2, extOp ) = Ops.arithExtUI ctx1 lenVar I8 I32 lenI32Var
```

-- arith.andi i1
Ops.mlirOp ctx "arith.andi"
    |> Ops.opBuilder.withOperands [ ok1, ok2 ]
    |> Ops.opBuilder.withResults [ ( combinedOk, I1 ) ]
    |> Ops.opBuilder.withAttrs [ ( "_operand_types", TypeArrayAttr [ I1, I1 ] ) ]
    |> Ops.opBuilder.build

-- arith.extui i8 -> i32
Ops.mlirOp ctx "arith.extui"
    |> Ops.opBuilder.withOperands [ i8Var ]
    |> Ops.opBuilder.withResults [ ( i32Var, I32 ) ]
    |> Ops.opBuilder.withAttrs [ ( "_operand_types", TypeArrayAttr [ I8 ] ) ]
    |> Ops.opBuilder.build
```

**BETTER FIX:** Add helpers in `Ops.elm` that include `_operand_types` automatically, similar to existing `arithCmpI`.

Also: Use `withAttrs` (plural) consistently, not `withAttr`.

---

```elm
module Compiler.Generate.MLIR.BytesFusion.EmitBF exposing (emitFusedEncoder)

{-| Emit bf dialect MLIR operations from Loop IR.

Uses SSA-threaded cursor: each write returns a new cursor value,
which is passed to the next operation. No Context.setVar needed.
-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.MLIR.BytesFusion.LoopIR as IR exposing (Endianness(..), Op(..), WidthExpr(..))
import Compiler.Generate.MLIR.Context as Ctx exposing (Context)
import Compiler.Generate.MLIR.Expr as Expr exposing (ExprResult)
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Mlir.Mlir exposing (MlirOp, MlirType(..), MlirAttr(..))


{-| Internal state for emission, keeping cursor tracking isolated.
-}
type alias EmitState =
    { ctx : Context
    , cursor : String        -- Current cursor SSA variable
    , bufferVar : String     -- The allocated ByteBuffer* for return
    , ops : List MlirOp      -- ✅ FIXED: Accumulated ops in FORWARD execution order
    }


{-| Emit a complete fused encoder, returning the ByteBuffer result.
-}
emitFusedEncoder : Context -> List Op -> ExprResult
emitFusedEncoder ctx ops =
    let
        initialState =
            { ctx = ctx
            , cursor = ""
            , bufferVar = ""
            , ops = []
            }

        finalState =
            List.foldl emitOp initialState ops
    in
    { ops = finalState.ops  -- ✅ FIXED: No List.reverse needed (forward order)
    , resultVar = finalState.bufferVar
    , resultType = Types.ecoValue  -- ByteBuffer* as eco.value
    , ctx = finalState.ctx
    , isTerminated = False
    }

{- ⚠️ CORRECTION 5: Bytes Representation Consistency

The plan uses `eco.value` (opaque pointer) for ByteBuffer* returns.

**Design Choice:** All Elm heap values (including ByteBuffer*, String*, List*) flow
through the uniform `eco.value` representation. This means:
- bf.alloc returns `eco.value` (not raw LLVM ptr)
- bf.read.* returns decoded values as `eco.value`
- No "LLVM pointer islands" where raw ptrs escape into Elm code

**Alternative (NOT used):** Some bytecode VMs keep raw pointers for intermediate
byte ops, only wrapping at API boundaries. We chose uniform eco.value for simplicity.

If you need raw pointer manipulation, use LLVM extraction inside bf ops before
returning to Elm-level code.
-}


{- ✅ CORRECTION C3 APPLIED: Forward Order Op Accumulation

**Strategy:** `EmitState.ops` stores ops in **forward execution order**.
- No `List.reverse` needed at the end
- Always **append** new ops: `st.ops ++ subOps ++ [ newOp ]`

**The code below uses the CORRECTED forward-order patterns.**
-}

{-| Emit a single Loop IR operation, threading cursor through SSA.
-}
emitOp : Op -> EmitState -> EmitState
emitOp op st =
    case op of
        InitCursor _curName widthExpr ->
            -- 1. Compute width
            -- 2. Allocate buffer: bf.alloc
            -- 3. Initialize cursor: bf.cursor.init
            let
                ( widthOps, widthVar, ctx1 ) =
                    emitWidthExpr st.ctx widthExpr

                ( allocVar, ctx2 ) =
                    Ctx.freshVar ctx1

                -- bf.alloc op
                ( ctx3, allocOp ) =
                    Ops.mlirOp ctx2 "bf.alloc"
                        |> Ops.opBuilder.withOperands [ widthVar ]
                        |> Ops.opBuilder.withResults [ ( allocVar, Types.ecoValue ) ]
                        |> Ops.opBuilder.build

                ( curVar, ctx4 ) =
                    Ctx.freshVar ctx3

                -- bf.cursor.init op
                ( ctx5, cursorOp ) =
                    Ops.mlirOp ctx4 "bf.cursor.init"
                        |> Ops.opBuilder.withOperands [ allocVar ]
                        |> Ops.opBuilder.withResults [ ( curVar, Types.bfCur ) ]
                        |> Ops.opBuilder.build
            in
            { st
                | ctx = ctx5
                , cursor = curVar
                , bufferVar = allocVar
                , ops = st.ops ++ widthOps ++ [ allocOp, cursorOp ]  -- ✅ Forward order
            }

        WriteU8 _curName valueExpr ->
            emitWriteOp st valueExpr "bf.write.u8"

        WriteU16 _curName endian valueExpr ->
            let
                opName = case endian of
                    BE -> "bf.write.u16_be"
                    LE -> "bf.write.u16_le"
            in
            emitWriteOp st valueExpr opName

        WriteU32 _curName endian valueExpr ->
            let
                opName = case endian of
                    BE -> "bf.write.u32_be"
                    LE -> "bf.write.u32_le"
            in
            emitWriteOp st valueExpr opName

        WriteF32 _curName endian valueExpr ->
            let
                opName = case endian of
                    BE -> "bf.write.f32_be"
                    LE -> "bf.write.f32_le"
            in
            emitWriteOp st valueExpr opName

        WriteF64 _curName endian valueExpr ->
            let
                opName = case endian of
                    BE -> "bf.write.f64_be"
                    LE -> "bf.write.f64_le"
            in
            emitWriteOp st valueExpr opName

        WriteBytesCopy _curName bytesExpr ->
            emitWriteCopyOp st bytesExpr "bf.write.bytes_copy"

        WriteUtf8 _curName stringExpr ->
            emitWriteCopyOp st stringExpr "bf.write.utf8"

        ReturnBuffer ->
            -- Buffer var is already tracked in state, nothing to emit
            st


{-| Emit a write operation for a scalar value.
    Returns updated state with new cursor SSA variable.
-}
emitWriteOp : EmitState -> Mono.MonoExpr -> String -> EmitState
emitWriteOp st valueExpr opName =
    let
        -- Generate the value expression
        valueResult = Expr.generateExpr st.ctx valueExpr

        -- Fresh var for new cursor (SSA: each write produces new cursor)
        ( newCurVar, ctx1 ) = Ctx.freshVar valueResult.ctx

        -- Emit bf.write.* op: (cursor, value) -> newCursor
        ( ctx2, writeOp ) =
            Ops.mlirOp ctx1 opName
                |> Ops.opBuilder.withOperands [ st.cursor, valueResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( newCurVar, Types.bfCur ) ]
                |> Ops.opBuilder.build
    in
    { st
        | ctx = ctx2
        , cursor = newCurVar  -- Thread new cursor forward
        , ops = st.ops ++ valueResult.ops ++ [ writeOp ]  -- ✅ Forward order
    }


{-| Emit a write operation for bytes/string copy.
-}
emitWriteCopyOp : EmitState -> Mono.MonoExpr -> String -> EmitState
emitWriteCopyOp st srcExpr opName =
    let
        srcResult = Expr.generateExpr st.ctx srcExpr
        ( newCurVar, ctx1 ) = Ctx.freshVar srcResult.ctx

        ( ctx2, writeOp ) =
            Ops.mlirOp ctx1 opName
                |> Ops.opBuilder.withOperands [ st.cursor, srcResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( newCurVar, Types.bfCur ) ]  -- ✅ Dialect type
                |> Ops.opBuilder.build
    in
    { st
        | ctx = ctx2
        , cursor = newCurVar
        , ops = st.ops ++ srcResult.ops ++ [ writeOp ]  -- ✅ Forward order
    }


{-| Emit width expression computation.
-}
emitWidthExpr : Context -> WidthExpr -> ( List MlirOp, String, Context )
emitWidthExpr ctx expr =
    case IR.simplifyWidth expr of
        IR.WConst n ->
            -- Constant width: emit arith.constant
            let
                ( varName, ctx1 ) = Ctx.freshVar ctx
                ( ctx2, constOp ) = Ops.arithConstantInt32 ctx1 varName n
            in
            ( [ constOp ], varName, ctx2 )

        IR.WAdd a b ->
            -- Add two widths
            let
                ( aOps, aVar, ctx1 ) = emitWidthExpr ctx a
                ( bOps, bVar, ctx2 ) = emitWidthExpr ctx1 b
                ( resVar, ctx3 ) = Ctx.freshVar ctx2
                ( ctx4, addOp ) =
                    Ops.mlirOp ctx3 "arith.addi"
                        |> Ops.opBuilder.withOperands [ aVar, bVar ]
                        |> Ops.opBuilder.withResults [ ( resVar, I32 ) ]
                        |> Ops.opBuilder.build
            in
            ( aOps ++ bOps ++ [ addOp ], resVar, ctx4 )

        IR.WStringUtf8Width stringExpr ->
            -- Runtime call: elm_utf8_width(string)
            let
                strResult = Expr.generateExpr ctx stringExpr
                ( resVar, ctx1 ) = Ctx.freshVar strResult.ctx
                ( ctx2, callOp ) =
                    Ops.ecoCallNamed ctx1 resVar "elm_utf8_width"
                        [ ( strResult.resultVar, strResult.resultType ) ]
                        I32
            in
            ( strResult.ops ++ [ callOp ], resVar, ctx2 )

        IR.WBytesWidth bytesExpr ->
            -- Runtime call: elm_bytebuffer_len(bytes)
            let
                bytesResult = Expr.generateExpr ctx bytesExpr
                ( resVar, ctx1 ) = Ctx.freshVar bytesResult.ctx
                ( ctx2, callOp ) =
                    Ops.ecoCallNamed ctx1 resVar "elm_bytebuffer_len"
                        [ ( bytesResult.resultVar, bytesResult.resultType ) ]
                        I32
            in
            ( bytesResult.ops ++ [ callOp ], resVar, ctx2 )
```

---

## Step 5: Compiler Integration

### 5.1 Update `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Add imports at top:
```elm
import Compiler.Generate.MLIR.BytesFusion.Reify as Reify
import Compiler.Generate.MLIR.BytesFusion.Compile as Compile
import Compiler.Generate.MLIR.BytesFusion.EmitBF as EmitBF
import Compiler.Elm.Package as Pkg
```

In `generateSaturatedCall`, modify the `MonoVarGlobal` case to intercept `Bytes.Encode.encode`:

```elm
Mono.MonoVarGlobal _ specId funcType ->
    let
        -- ... existing code to get argOps, argsWithTypes, ctx1 ...

        maybeCoreInfo =
            case Mono.lookupSpecKey specId ctx.registry of
                Just ( Mono.Global (IO.Canonical pkg moduleName) name, _, _ ) ->
                    Just ( pkg, moduleName, name )
                _ ->
                    Nothing
    in
    case maybeCoreInfo of
        -- NEW: Intercept Bytes.Encode.encode
        Just ( pkg, "Bytes.Encode", "encode" ) ->
            if pkg == Pkg.bytes then
                case args of
                    [ encoderExpr ] ->
                        -- Try to reify the encoder AST
                        case Reify.reifyEncoder ctx.registry encoderExpr of
                            Just encoderNodes ->
                                -- Compile to Loop IR and emit bf ops
                                let
                                    loopOps = Compile.compileEncoder encoderNodes
                                in
                                EmitBF.emitFusedEncoder ctx1 loopOps

                            Nothing ->
                                -- Can't statically analyze - fall back to kernel
                                generateKernelCallFallback ctx funcInfo resultType argOps argsWithTypes

                    _ ->
                        -- Wrong number of args - fall back
                        generateKernelCallFallback ctx funcInfo resultType argOps argsWithTypes
            else
                -- ... existing code ...

        -- ... rest of existing cases ...
```

---

## Step 6: Testing

### 6.1 Unit tests for Reify module

Test `reifyEncoder` with various MonoExpr patterns.

### 6.2 E2E tests

Create `test/elm/src/BytesEncodeTests.elm` with cases that exercise:
- Simple u8 encoding
- Multi-byte with endianness
- Sequences
- String encoding

---

## File Change Summary

### New Files (15)

| File | Description |
|------|-------------|
| `runtime/src/allocator/ElmBytesRuntime.h` | C-ABI header |
| `runtime/src/allocator/ElmBytesRuntime.cpp` | C-ABI + UTF-8 impl |
| `runtime/src/codegen/BF/BFDialect.td` | bf dialect TableGen |
| `runtime/src/codegen/BF/BFOps.td` | bf ops TableGen |
| `runtime/src/codegen/BF/BFDialect.h` | bf dialect C++ header |
| `runtime/src/codegen/BF/BFDialect.cpp` | bf dialect C++ impl |
| `runtime/src/codegen/BF/BFOps.h` | bf ops C++ header |
| `runtime/src/codegen/BF/BFOps.cpp` | bf ops C++ impl |
| `runtime/src/codegen/BF/BFTypes.h` | bf types C++ header |
| `runtime/src/codegen/BF/BFTypes.cpp` | bf types C++ impl |
| `runtime/src/codegen/Passes/BFToLLVM.cpp` | bf → LLVM lowering |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/LoopIR.elm` | Loop IR types |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/Reify.elm` | **AST recognizer** |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/Compile.elm` | Encoder → Loop IR |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/EmitBF.elm` | Loop IR → bf MLIR |

### Modified Files (5)

| File | Changes |
|------|---------|
| `runtime/src/codegen/CMakeLists.txt` | Add bf TableGen + sources |
| `runtime/src/codegen/RuntimeSymbols.cpp` | Register elm_* symbols |
| `runtime/src/codegen/Passes.h` | Declare `createBFToLLVMPass()` |
| `runtime/src/codegen/EcoPipeline.cpp` | Load bf dialect, add pass |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Intercept Bytes.Encode.encode |

---

## Resolved Questions

### ✅ 1. Endianness representation

**Resolved:** `Bytes.BE` and `Bytes.LE` are nullary constructors represented as:
- `MonoVarGlobal Region SpecId MonoType`
- SpecId resolves via `lookupSpecKey` to tuple `(Global (IO.Canonical pkg moduleName) name, _, _)`
- Pattern match on `pkg == Pkg.bytes && moduleName == "Bytes"` and `name == "BE"` or `"LE"`

See updated `reifyEndianness` implementation in Step 4.2.

### ✅ 2. Context.setVar

**Resolved:** Not needed. Use **SSA-threaded cursor** approach:
- Each `bf.write.*` returns a new `!bf.cur` value
- Thread cursor through `EmitState` record instead of modifying Context
- This is natural for SSA and keeps changes isolated

See updated `EmitBF.elm` in Step 4.4.

---

## Remaining Questions

### 1. Build verification

Can you confirm `cmake --build build` currently succeeds before starting implementation?

---

## Confirmed Assumptions

- **A1**: ✅ Endianness values identified by pattern-matching on constructor SpecIds (confirmed)
- **A2**: ✅ Cursor tracked via SSA threading in EmitState, no Context changes needed (confirmed)
- **A3**: Portable byte-wise stores (no bswap intrinsics initially)
- **A4**: `Pkg.bytes` is the `elm/bytes` package identifier (confirmed in Package.elm:204)

---

## Implementation Order

1. **Step 1** - Runtime (ElmBytesRuntime.h/cpp) - testable independently
2. **Step 2** - bf dialect - verify TableGen compiles
3. **Step 3** - bf lowering - test with hand-written bf MLIR
4. **Step 4.1-4.3** - Compiler modules (LoopIR, Reify, Compile)
5. **Step 4.4** - EmitBF
6. **Step 5** - Integration in Expr.elm
7. **Step 6** - E2E tests
---
---

# Phase 2: Decoder Fusion

**Goal:** Compile `Bytes.Decode` expressions into fused byte kernels, returning `Maybe a`.
---
---


**Prerequisite:** Phase 1 (Encoder) must be complete - provides:
- Runtime ABI (`ElmBytesRuntime.h/cpp`)
- bf dialect infrastructure (TableGen, C++ scaffolding)
- bf → LLVM lowering pass
- BytesFusion compiler modules (`LoopIR.elm`, `Reify.elm`, etc.)

**Design Document:** `/work/design_docs/fused-bytes-compilation.md`

---

## Key Differences from Encoder

| Aspect | Encoder (Phase 1) | Decoder (Phase 2) |
|--------|-------------------|-------------------|
| **Return type** | `Bytes` (always succeeds) | `Maybe a` (can fail) |
| **Cursor ops** | Write-only, cursor advances | Read + bounds check, cursor advances |
| **Failure handling** | None | Branch to fail block on bounds error |
| **Value construction** | Single ByteBuffer allocation | Build result value + wrap in Just/Nothing |

---

## Overview

```
Elm source
  ↓ (standard compilation)
Monomorphized AST (MonoExpr)
  ↓ (recognizer in generateSaturatedCall)
Decoder AST pattern detected?
  ↓ YES                           ↓ NO
reifyDecoder : MonoExpr           Fall back to kernel call
  → Maybe DecoderNode             (stub Elm_Kernel_Bytes_decode)
  ↓
Decoder Loop IR (reads + checks)
  ↓
bf dialect MLIR (with scf.if for failure)
  ↓ (BFToLLVM pass)
LLVM IR
  ↓
Native code returning Maybe a
```

---

## Step 1: Extend Runtime ABI

### ✅ CORRECTED C20: No Additional Header Changes Needed

**The decoder helpers are already defined in Phase 1's `ElmBytesRuntime.h` with proper `u64` ABI:**

```c
// Already in Phase 1 header (u64 eco.value ABI):
u64 elm_utf8_decode(const u8* src, u32 len);  // Returns eco.value or 0 on failure
u64 elm_maybe_nothing(void);
u64 elm_maybe_just(u64 value);
```

**DO NOT add the old `void*` signatures shown below - they are OBSOLETE:**
```c
// ❌ OBSOLETE - DO NOT USE:
// void* elm_utf8_decode(const u8* src, u32 len);
// void* elm_maybe_nothing(void);
// void* elm_maybe_just(void* value);
```

### 1.2 Implementation in `ElmBytesRuntime.cpp`

**✅ CORRECTED C20: Already implemented in Phase 1**

The decoder helpers (`elm_utf8_decode`, `elm_maybe_nothing`, `elm_maybe_just`) are already
implemented in Phase 1's `ElmBytesRuntime.cpp` with proper `u64` ABI:

```cpp
// Already in Phase 1 implementation (see Step 1.2 of Phase 1):
u64 elm_utf8_decode(const u8* src, u32 len) {
    ElmString* str = StringOps::fromUtf8(src, len);
    if (!str) return 0;  // Failure sentinel
    return toEcoValue(str);
}

u64 elm_maybe_nothing() {
    return toEcoValue(Maybe::nothing());
}

u64 elm_maybe_just(u64 value) {
    return toEcoValue(Maybe::just(value));
}
```

### 1.3 Symbol Registration

**✅ Already done in Phase 1's `RuntimeSymbols.cpp`** - the decoder symbols
(`elm_utf8_decode`, `elm_maybe_nothing`, `elm_maybe_just`) are registered
alongside the encoder symbols.

---

## Step 2: Extend bf Dialect for Decoding

### ✅ CORRECTION C5 APPLIED: bf Dialect Uses eco.value for Heap Objects

**Design Decision:** All bf ops that produce/consume Elm heap objects use `!eco.value` (lowered to `i64`).

**TableGen type definitions (add to ECODialect.td or BFDialect.td):**
```tablegen
// ECO value type - represents tagged Elm heap pointer (lowered to i64)
// This should already exist in ECODialect; if not, define it:
def ECO_ValueType : TypeDef<ECODialect, "Value"> {
  let mnemonic = "value";
  let summary = "Elm heap value (tagged pointer, lowered to i64)";
}
```

**BFToLLVM lowering implications:**
- `!eco.value` lowers to `i64` (not `i8*`)
- Runtime helpers take/return `i64` (cast internally if needed)
- `bf.read.bytes`/`bf.read.utf8` call runtime helpers returning `i64`

**The TableGen below is CORRECTED to use `ECO_ValueType`:**

---

### 2.1 Add to `BFOps.td`

```tablegen
// ✅ FINAL: ECO_ValueType include
//
// Use the SAME include style already used by existing ECO TableGen files in this repo.
// Do not use filesystem paths like "runtime/src/...".
//
// REQUIRED GROUNDING TASK:
//   Find a working include in an existing .td file (e.g. wherever ECO ops/types are defined)
//   and mirror it here.
//
// Typical working include (only if ECO/ is already in the tblgen include dirs):
include "ECO/ECODialect.td"

// CMake task: Ensure the BF tablegen target has the ECO TableGen include dir
// in its `-I` list, matching how existing dialects are built.

// If ECO_ValueType doesn't exist yet, add this to ECODialect.td:
// def ECO_ValueType : TypeDef<ECODialect, "Value"> {
//   let mnemonic = "value";
//   let summary = "Elm heap value (tagged pointer, lowered to i64)";
// }

// Status type for success/failure
def BF_StatusType : TypeDef<BFDialect, "Status"> {
  let mnemonic = "status";
  let summary = "i1 ok/fail flag";
}

// Bounds check: returns ok if cursor has at least n bytes remaining
def BF_RequireOp : Op<BFDialect, "require", [Pure]> {
  let arguments = (ins BF_CurType:$cur, I32:$n);
  let results   = (outs BF_StatusType:$ok);
  let summary = "Check cursor has n bytes remaining";
}

// ✅ FINAL: Scalar type policy
//
// Elm-level values:
// - Elm Int  => i64 at MLIR level
// - Elm Float => f64 at MLIR level
//
// Therefore primitive read ops return Elm-level types (i64/f64), even though
// they read byte-sized encodings. BFToLLVM performs the byte loads and
// appropriate extension/bitcast.
//
// Caller MUST emit bf.require + fail-fast control flow BEFORE calling these ops.

// Read operations - return (value, newCursor) only
def BF_ReadU8Op : Op<BFDialect, "read.u8", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I64:$value, BF_CurType:$newCur);
}

def BF_ReadI8Op : Op<BFDialect, "read.i8", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I64:$value, BF_CurType:$newCur);
}

def BF_ReadU16BEOp : Op<BFDialect, "read.u16_be", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I64:$value, BF_CurType:$newCur);
}
def BF_ReadU16LEOp : Op<BFDialect, "read.u16_le", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I64:$value, BF_CurType:$newCur);
}

def BF_ReadI16BEOp : Op<BFDialect, "read.i16_be", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I64:$value, BF_CurType:$newCur);
}
def BF_ReadI16LEOp : Op<BFDialect, "read.i16_le", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I64:$value, BF_CurType:$newCur);
}

def BF_ReadU32BEOp : Op<BFDialect, "read.u32_be", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I64:$value, BF_CurType:$newCur);
}
def BF_ReadU32LEOp : Op<BFDialect, "read.u32_le", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I64:$value, BF_CurType:$newCur);
}

def BF_ReadI32BEOp : Op<BFDialect, "read.i32_be", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I64:$value, BF_CurType:$newCur);
}
def BF_ReadI32LEOp : Op<BFDialect, "read.i32_le", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I64:$value, BF_CurType:$newCur);
}

// Float32 encoding returns Elm Float (f64) after extending.
// Float64 encoding returns Elm Float (f64).
def BF_ReadF32BEOp : Op<BFDialect, "read.f32_be", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs F64:$value, BF_CurType:$newCur);
}
def BF_ReadF32LEOp : Op<BFDialect, "read.f32_le", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs F64:$value, BF_CurType:$newCur);
}

def BF_ReadF64BEOp : Op<BFDialect, "read.f64_be", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs F64:$value, BF_CurType:$newCur);
}
def BF_ReadF64LEOp : Op<BFDialect, "read.f64_le", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs F64:$value, BF_CurType:$newCur);
}

// Heap reads (may fail for reasons OTHER than bounds):
// - Caller MUST guard bounds via bf.require + fail-fast control flow BEFORE calling.
// - These ops advance cursor by len unconditionally (safe because bounds already verified).
// - ok indicates non-bounds failure (e.g. invalid UTF-8, allocation failure).
def BF_ReadBytesOp : Op<BFDialect, "read.bytes", [Pure]> {
  let arguments = (ins BF_CurType:$cur, I32:$len);
  let results   = (outs ECO_ValueType:$bytes, BF_CurType:$newCur, BF_StatusType:$ok);
  let summary   = "Read len bytes into new ByteBuffer; assumes bounds already checked";
}

def BF_ReadUtf8Op : Op<BFDialect, "read.utf8", [Pure]> {
  let arguments = (ins BF_CurType:$cur, I32:$len);
  let results   = (outs ECO_ValueType:$string, BF_CurType:$newCur, BF_StatusType:$ok);
  let summary   = "Decode len bytes as UTF-8 string; assumes bounds already checked";
}
```

---

## Step 3: Extend bf → LLVM Lowering

### ⚠️ CRITICAL SAFETY REQUIREMENT: Bounds Check BEFORE Load

**PROBLEM:** The naive lowering below performs loads unconditionally, then computes `ok` afterward. This can **segfault** if `ptr >= end`:

```cpp
// UNSAFE - DO NOT USE:
Value ok = rewriter.create<LLVM::ICmpOp>(...);  // Check AFTER
Value value = rewriter.create<LLVM::LoadOp>(...);  // Load happens even if out-of-bounds!
```

**SOLUTION:** Use the "single fail continuation" strategy:

1. Compiler emits `bf.require(cur, n)` BEFORE each `bf.read.*`
2. If `ok` is false, branch **immediately** to the fail block
3. No read occurs unless bounds check passes

**Recommended IR Pattern:**
```
%ok = bf.require(%cur, 4)        ; check 4 bytes available
cf.cond_br %ok, ^read, ^fail     ; branch immediately on failure
^read:
  %value, %newCur = bf.read.u32_be(%cur)  ; safe - we checked first
  ...
^fail:
  %nothing = call @elm_maybe_nothing()
  return %nothing
```

**Alternative (more complex):** Keep `bf.read.*` returning `(value, newCur, ok)` but lower with control flow so the load happens only in the ok path. Requires block splitting.

### 3.1 Update `BFToLLVM.cpp` with read patterns

```cpp
// bf.require(cur, n) → ok = (cur.ptr + n <= cur.end)
struct RequireOpLowering : public ConvertOpToLLVMPattern<bf::RequireOp> {
  LogicalResult matchAndRewrite(bf::RequireOp op, OpAdaptor adaptor,
                                 ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    auto cur = adaptor.getCur();  // {i8*, i8*}

    // Extract ptr and end
    Value ptr = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 0);
    Value end = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 1);

    // newPtr = gep ptr, n
    Value n = adaptor.getN();
    Value nExt = rewriter.create<LLVM::ZExtOp>(loc, i64Type, n);
    Value newPtr = rewriter.create<LLVM::GEPOp>(loc, ptrType, i8Type, ptr, nExt);

    // ok = newPtr <= end
    Value ok = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ule, newPtr, end);

    rewriter.replaceOp(op, ok);
    return success();
  }
};

// ✅ CORRECTED C21: bf.read.u8(cur) → (value, newCur) - NO ok result
// Safety is guaranteed by bf.require + branch BEFORE this op.
// This lowering performs unconditional load - safe because bounds already verified.
struct ReadU8OpLowering : public ConvertOpToLLVMPattern<bf::ReadU8Op> {
  LogicalResult matchAndRewrite(bf::ReadU8Op op, OpAdaptor adaptor,
                                 ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    auto cur = adaptor.getCur();

    Value ptr = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 0);
    Value end = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 1);

    // Read value - SAFE: bf.require + branch already verified bounds!
    Value value = rewriter.create<LLVM::LoadOp>(loc, i8Type, ptr);

    // Advance pointer
    Value one = rewriter.create<LLVM::ConstantOp>(loc, i64Type, 1);
    Value newPtr = rewriter.create<LLVM::GEPOp>(loc, ptrType, i8Type, ptr, one);

    // Build new cursor (NO ok computation - that's bf.require's job)
    Value newCur = rewriter.create<LLVM::UndefOp>(loc, cursorType);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, newPtr, 0);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, end, 1);

    rewriter.replaceOp(op, {value, newCur});  // ✅ Only 2 results
    return success();
  }
};

// ✅ CORRECTED C21: Multi-byte reads also return (value, newCur) only
// Byte-wise loads for portability. Safety from bf.require + branch.
struct ReadU16BEOpLowering : public ConvertOpToLLVMPattern<bf::ReadU16BEOp> {
  LogicalResult matchAndRewrite(bf::ReadU16BEOp op, OpAdaptor adaptor,
                                 ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    auto cur = adaptor.getCur();

    Value ptr = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 0);
    Value end = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 1);

    // Byte-wise load (big-endian): value = (b0 << 8) | b1
    // SAFE: bf.require(cur, 2) + branch already verified bounds!
    Value b0 = rewriter.create<LLVM::LoadOp>(loc, i8Type, ptr);
    Value ptr1 = rewriter.create<LLVM::GEPOp>(loc, ptrType, i8Type, ptr,
                   rewriter.create<LLVM::ConstantOp>(loc, i64Type, 1));
    Value b1 = rewriter.create<LLVM::LoadOp>(loc, i8Type, ptr1);

    Value b0Ext = rewriter.create<LLVM::ZExtOp>(loc, i16Type, b0);
    Value b1Ext = rewriter.create<LLVM::ZExtOp>(loc, i16Type, b1);
    Value shifted = rewriter.create<LLVM::ShlOp>(loc, b0Ext,
                      rewriter.create<LLVM::ConstantOp>(loc, i16Type, 8));
    Value value = rewriter.create<LLVM::OrOp>(loc, shifted, b1Ext);

    // Advance pointer
    Value two = rewriter.create<LLVM::ConstantOp>(loc, i64Type, 2);
    Value newPtr = rewriter.create<LLVM::GEPOp>(loc, ptrType, i8Type, ptr, two);

    // Build new cursor (NO ok computation)
    Value newCur = rewriter.create<LLVM::UndefOp>(loc, cursorType);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, newPtr, 0);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, end, 1);

    rewriter.replaceOp(op, {value, newCur});  // ✅ Only 2 results
    return success();
  }
};

// bf.read.utf8(cur, len32) -> (i64 stringVal, newCur, i1 ok)
// ASSUMPTION: bounds were already checked by bf.require + fail-fast control flow.
// ok checks ONLY utf8 decode success (stringVal != 0).
struct ReadUtf8OpLowering : public ConvertOpToLLVMPattern<bf::ReadUtf8Op> {
  LogicalResult matchAndRewrite(bf::ReadUtf8Op op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    Value cur = adaptor.getCur();
    Value len32 = adaptor.getLen();

    Value ptr = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 0);
    Value end = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 1);

    // newPtr = ptr + len
    Value len64 = rewriter.create<LLVM::ZExtOp>(loc, i64Type, len32);
    Value newPtr = rewriter.create<LLVM::GEPOp>(loc, ptrType, i8Type, ptr, len64);

    // stringVal : i64 = call @elm_utf8_decode(ptr, len32)
    Value stringVal = rewriter.create<LLVM::CallOp>(
        loc, i64Type, "elm_utf8_decode", ValueRange{ptr, len32}).getResult();

    // ok = (stringVal != 0)
    Value zero64 = rewriter.create<LLVM::ConstantOp>(loc, i64Type, 0);
    Value ok = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ne, stringVal, zero64);

    // newCur = { newPtr, end }
    Value newCur = rewriter.create<LLVM::UndefOp>(loc, cursorType);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, newPtr, 0);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, end, 1);

    rewriter.replaceOp(op, {stringVal, newCur, ok});
    return success();
  }
};
```

---

## Step 4: Compiler Frontend - Decoder Reification

### 4.1 Extend `LoopIR.elm` with decoder operations

```elm
module Compiler.Generate.MLIR.BytesFusion.LoopIR exposing (..)

-- ... existing encoder types ...

{-| Decoder operations.

Each primitive read produces an Elm-level value (`Int` as i64, `Float` as f64).
The emitter is responsible for inserting `bf.require` and `scf.if` fail-fast
control flow around each read.

Bounds checking is handled via nested scf.if in the emitter, not via explicit
Require/BranchOnFail ops. This removes the need for CF block jumps and makes
control flow explicit.
-}
type DecoderOp
    = InitReadCursor String Mono.MonoExpr  -- cursorName, bytes expression
    -- Primitive fixed-size reads:
    | ReadU8 String String                  -- cursorName, resultVarName
    | ReadU16 String Endianness String
    | ReadU32 String Endianness String
    | ReadF32 String Endianness String
    | ReadF64 String Endianness String
    -- Variable-length reads (length from Elm expr):
    | ReadBytes String Mono.MonoExpr String -- cursorName, length expr, resultVarName
    | ReadUtf8 String Mono.MonoExpr String  -- cursorName, length expr, resultVarName
    -- Function application: REQUIRED for map/map2/etc
    | Apply1 Mono.MonoExpr String String    -- fnExpr, argVar, resultVar
    | Apply2 Mono.MonoExpr String String String  -- fnExpr, arg1Var, arg2Var, resultVar
    | Apply3 Mono.MonoExpr String String String String
    | Apply4 Mono.MonoExpr String String String String String
    | Apply5 Mono.MonoExpr String String String String String String
    -- Constant value (for Decode.succeed):
    | PushValue Mono.MonoExpr String        -- valueExpr, resultVar - push without reading
    -- Final result:
    | ReturnJust String                      -- Return Just resultVar
    | ReturnNothing                          -- Return Nothing (fail path)
```

**⚠️ CRITICAL: Function Application**

The original `BuildResult Mono.MonoExpr` is **insufficient**. It doesn't actually apply `fnExpr` to decoded values!

**Problem:** `Expr.generateExpr` resolves `MonoVarLocal` via `Ctx.lookupVar`. But decoded SSA values are NOT in the Context - they're just MLIR SSA variables.

**Solution:** Add explicit `Apply1`/`Apply2`/etc operations that:
1. Take the function expression AND the SSA variable names of decoded args
2. In the emitter, either:
   - Emit an `eco.call` / `eco.apply` using the SSA vars directly, OR
   - Bind the SSA vars into Context temporarily so `Expr.generateExpr` can find them

### 4.2 Create `compiler/src/Compiler/Generate/MLIR/BytesFusion/ReifyDecoder.elm`

```elm
module Compiler.Generate.MLIR.BytesFusion.ReifyDecoder exposing (reifyDecoder, DecoderNode(..))

{-| Reify a MonoExpr representing a Bytes.Decode.Decoder into
a normalized decoder structure.

Phase 2 scope: Simple decoders only (no andThen, no loop).
-}

import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..), Global(..))
import Compiler.Elm.Package as Pkg
import Compiler.Generate.MLIR.BytesFusion.LoopIR as IR exposing (Endianness(..))
import Data.IO as IO exposing (Canonical(..))


{-| Normalized decoder node.
-}
type DecoderNode
    = DU8
    | DS8
    | DU16 Endianness
    | DS16 Endianness
    | DU32 Endianness
    | DS32 Endianness
    | DF32 Endianness
    | DF64 Endianness
    | DBytes Mono.MonoExpr        -- length expression
    | DString Mono.MonoExpr       -- length expression
    | DSucceed Mono.MonoExpr      -- value expression
    | DFail
    | DMap Mono.MonoExpr DecoderNode           -- fn, inner decoder
    | DMap2 Mono.MonoExpr DecoderNode DecoderNode
    | DMap3 Mono.MonoExpr DecoderNode DecoderNode DecoderNode
    | DMap4 Mono.MonoExpr DecoderNode DecoderNode DecoderNode DecoderNode
    | DMap5 Mono.MonoExpr DecoderNode DecoderNode DecoderNode DecoderNode DecoderNode


{-| Try to reify a MonoExpr into a decoder node.
Returns Nothing if the expression contains dynamic/opaque decoders
or unsupported combinators (andThen, loop).
-}
reifyDecoder : Mono.MonoRegistry -> Mono.MonoExpr -> Maybe DecoderNode
reifyDecoder registry expr =
    case expr of
        Mono.MonoCall _ func args _ ->
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    case Mono.lookupSpecKey specId registry of
                        Just (Global (Canonical pkg moduleName) name, _, _) ->
                            if pkg == Pkg.bytes && moduleName == "Bytes.Decode" then
                                reifyBytesDecodeCall registry name args
                            else
                                Nothing
                        _ ->
                            Nothing

                Mono.MonoVarKernel _ "Bytes" name _ ->
                    reifyBytesKernelDecodeCall registry name args

                _ ->
                    Nothing

        Mono.MonoLet letDef body _ ->
            {- HARD GATE (C18):
               Do not implement MonoLet handling until MonoLet / MonoLetDef is grounded
               from Compiler/AST/Monomorphized.elm.

               Once grounded, implement environment-based substitution:

                 reifyDecoderWithEnv : Dict Name DecoderNode -> MonoExpr -> Maybe DecoderNode

               Rules:
               1) If a let binding RHS reifies successfully, extend env with (name -> node)
               2) When encountering MonoVarLocal name, consult env
               3) Fall back to Nothing if the let introduces non-reifiable structure

               This avoids relying on non-existent fields like def.name/def.body.
            -}
            Nothing

        _ ->
            Nothing


{-| Reify a call to a Bytes.Decode.* function.
-}
reifyBytesDecodeCall : Mono.MonoRegistry -> String -> List Mono.MonoExpr -> Maybe DecoderNode
reifyBytesDecodeCall registry name args =
    case ( name, args ) of
        -- Primitive decoders
        ( "unsignedInt8", [] ) ->
            Just DU8

        ( "signedInt8", [] ) ->
            Just DS8

        ( "unsignedInt16", [ endiannessExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map DU16

        ( "signedInt16", [ endiannessExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map DS16

        ( "unsignedInt32", [ endiannessExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map DU32

        ( "signedInt32", [ endiannessExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map DS32

        ( "float32", [ endiannessExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map DF32

        ( "float64", [ endiannessExpr ] ) ->
            reifyEndianness registry endiannessExpr
                |> Maybe.map DF64

        ( "bytes", [ lenExpr ] ) ->
            Just (DBytes lenExpr)

        ( "string", [ lenExpr ] ) ->
            Just (DString lenExpr)

        -- Succeed/fail
        ( "succeed", [ valueExpr ] ) ->
            Just (DSucceed valueExpr)

        ( "fail", [] ) ->
            Just DFail

        -- Map combinators
        ( "map", [ fnExpr, decoderExpr ] ) ->
            reifyDecoder registry decoderExpr
                |> Maybe.map (DMap fnExpr)

        ( "map2", [ fnExpr, d1Expr, d2Expr ] ) ->
            Maybe.map2 (DMap2 fnExpr)
                (reifyDecoder registry d1Expr)
                (reifyDecoder registry d2Expr)

        ( "map3", [ fnExpr, d1Expr, d2Expr, d3Expr ] ) ->
            Maybe.map3 (DMap3 fnExpr)
                (reifyDecoder registry d1Expr)
                (reifyDecoder registry d2Expr)
                (reifyDecoder registry d3Expr)

        ( "map4", [ fnExpr, d1Expr, d2Expr, d3Expr, d4Expr ] ) ->
            Maybe.map4 (DMap4 fnExpr)
                (reifyDecoder registry d1Expr)
                (reifyDecoder registry d2Expr)
                (reifyDecoder registry d3Expr)
                (reifyDecoder registry d4Expr)

        ( "map5", [ fnExpr, d1Expr, d2Expr, d3Expr, d4Expr, d5Expr ] ) ->
            Maybe.map5 (DMap5 fnExpr)
                (reifyDecoder registry d1Expr)
                (reifyDecoder registry d2Expr)
                (reifyDecoder registry d3Expr)
                (reifyDecoder registry d4Expr)
                (reifyDecoder registry d5Expr)

        -- NOT SUPPORTED in Phase 2
        ( "andThen", _ ) ->
            Nothing  -- Phase 3

        ( "loop", _ ) ->
            Nothing  -- Phase 4

        _ ->
            Nothing


{-| Reify kernel decode calls.
-}
reifyBytesKernelDecodeCall : Mono.MonoRegistry -> String -> List Mono.MonoExpr -> Maybe DecoderNode
reifyBytesKernelDecodeCall _ name _ =
    -- Kernel decode functions are internal; typically not exposed
    Nothing


{-| Reify endianness (same as encoder).
-}
reifyEndianness : Mono.MonoRegistry -> Mono.MonoExpr -> Maybe Endianness
reifyEndianness registry expr =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            case Mono.lookupSpecKey specId registry of
                Just (Global (Canonical pkg moduleName) name, _, _) ->
                    if pkg == Pkg.bytes && moduleName == "Bytes" then
                        case name of
                            "LE" -> Just LE
                            "BE" -> Just BE
                            _ -> Nothing
                    else
                        Nothing
                _ ->
                    Nothing

        Mono.MonoCall _ fn [] _ ->
            reifyEndianness registry fn

        _ ->
            Nothing
```

### 4.3 Create `compiler/src/Compiler/Generate/MLIR/BytesFusion/CompileDecoder.elm`

**⚠️ OP ORDERING BUG WARNING:**

The code below prepends ops with `::` then calls `List.reverse`. This causes:
```elm
ops = CheckOk "cur" :: ReadU8 "cur" varName :: st1.ops
-- After List.reverse: [..., ReadU8, CheckOk]  -- WRONG ORDER!
```

**CORRECTION:** Either:
1. Append in forward order (no reverse), or
2. Cons in REVERSE of desired execution order:
   ```elm
   ops = ReadU8 "cur" varName :: Require "cur" 1 :: st1.ops
   -- After List.reverse: [Require, ReadU8, ...]  -- CORRECT!
   ```

**Recommended approach with single-fail-continuation:**
```elm
ops = ReadU8 "cur" varName :: BranchOnFail "cur" :: Require "cur" 1 :: st1.ops
-- After reverse: [Require, BranchOnFail, ReadU8, ...]
```

Where `BranchOnFail` emits `cf.cond_br %ok, ^continue, ^fail` to short-circuit.

```elm
module Compiler.Generate.MLIR.BytesFusion.CompileDecoder exposing (compileDecoder)

{-| Compile a DecoderNode to Loop IR operations.
-}

import Compiler.Generate.MLIR.BytesFusion.LoopIR as IR exposing (DecoderOp(..), Endianness(..))
import Compiler.Generate.MLIR.BytesFusion.ReifyDecoder exposing (DecoderNode(..))


type alias CompileState =
    { ops : List DecoderOp
    , varCounter : Int
    , decodedVars : List String  -- Stack of decoded variable names
    }


{-| Compile decoder to Loop IR.

✅ CORRECTED C13: ops are accumulated in forward execution order.
No List.reverse needed at the end.
-}
compileDecoder : DecoderNode -> List DecoderOp
compileDecoder node =
    let
        initialState =
            { ops = []
            , varCounter = 0
            , decodedVars = []
            }

        finalState =
            compileNode node initialState
    in
    finalState.ops  -- ✅ Forward order - no reverse


{-| Compile a decoder node to Loop IR operations.

✅ SCF-COMPATIBLE: This compiler produces only Read* and Apply* ops.
Bounds checking is handled by the EMITTER via nested scf.if, NOT here.

Each primitive read just emits the read op. The emitter wraps each in:
  bf.require(cursor, N) -> ok
  scf.if ok { read... } else { return Nothing }

Ops are accumulated in forward order using `++` (append).
-}
compileNode : DecoderNode -> CompileState -> CompileState
compileNode node st =
    case node of
        DU8 ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = st1.ops ++ [ ReadU8 "cur" varName ]
                , decodedVars = varName :: st1.decodedVars
            }

        DS8 ->
            -- Same as DU8 but result is signed (handled in type annotation)
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = st1.ops ++ [ ReadU8 "cur" varName ]
                , decodedVars = varName :: st1.decodedVars
            }

        DU16 endian ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = st1.ops ++ [ ReadU16 "cur" endian varName ]
                , decodedVars = varName :: st1.decodedVars
            }

        DS16 endian ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = st1.ops ++ [ ReadU16 "cur" endian varName ]
                , decodedVars = varName :: st1.decodedVars
            }

        DU32 endian ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = st1.ops ++ [ ReadU32 "cur" endian varName ]
                , decodedVars = varName :: st1.decodedVars
            }

        DS32 endian ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = st1.ops ++ [ ReadU32 "cur" endian varName ]
                , decodedVars = varName :: st1.decodedVars
            }

        DF32 endian ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = st1.ops ++ [ ReadF32 "cur" endian varName ]
                , decodedVars = varName :: st1.decodedVars
            }

        DF64 endian ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = st1.ops ++ [ ReadF64 "cur" endian varName ]
                , decodedVars = varName :: st1.decodedVars
            }

        DBytes lenExpr ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = st1.ops ++ [ ReadBytes "cur" lenExpr varName ]
                , decodedVars = varName :: st1.decodedVars
            }

        DString lenExpr ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = st1.ops ++ [ ReadUtf8 "cur" lenExpr varName ]
                , decodedVars = varName :: st1.decodedVars
            }

        DSucceed valueExpr ->
            -- Push the constant value onto the stack (no read needed)
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = st1.ops ++ [ PushValue valueExpr varName ]
                , decodedVars = varName :: st1.decodedVars
            }

        DFail ->
            -- Immediate failure - emitter will generate ReturnNothing
            { st
                | ops = st.ops ++ [ ReturnNothing ]
            }

        DMap fnExpr innerDecoder ->
            let
                st1 = compileNode innerDecoder st
                argVar = List.head st1.decodedVars |> Maybe.withDefault "??"
                ( resultVar, st2 ) = freshVar st1
            in
            { st2
                | ops = st2.ops ++ [ Apply1 fnExpr argVar resultVar ]
                , decodedVars = resultVar :: List.drop 1 st2.decodedVars
            }

        DMap2 fnExpr d1 d2 ->
            let
                st1 = compileNode d1 st
                st2 = compileNode d2 st1
                arg1Var = List.head (List.drop 1 st2.decodedVars) |> Maybe.withDefault "??"
                arg2Var = List.head st2.decodedVars |> Maybe.withDefault "??"
                ( resultVar, st3 ) = freshVar st2
            in
            { st3
                | ops = st3.ops ++ [ Apply2 fnExpr arg1Var arg2Var resultVar ]
                , decodedVars = resultVar :: List.drop 2 st3.decodedVars
            }

        DMap3 fnExpr d1 d2 d3 ->
            let
                st1 = compileNode d1 st
                st2 = compileNode d2 st1
                st3_ = compileNode d3 st2
                arg1Var = List.head (List.drop 2 st3_.decodedVars) |> Maybe.withDefault "??"
                arg2Var = List.head (List.drop 1 st3_.decodedVars) |> Maybe.withDefault "??"
                arg3Var = List.head st3_.decodedVars |> Maybe.withDefault "??"
                ( resultVar, st4 ) = freshVar st3_
            in
            { st4
                | ops = st4.ops ++ [ Apply3 fnExpr arg1Var arg2Var arg3Var resultVar ]
                , decodedVars = resultVar :: List.drop 3 st4.decodedVars
            }

        DMap4 fnExpr d1 d2 d3 d4 ->
            let
                st1 = compileNode d1 st
                st2 = compileNode d2 st1
                st3_ = compileNode d3 st2
                st4_ = compileNode d4 st3_
                arg1Var = List.head (List.drop 3 st4_.decodedVars) |> Maybe.withDefault "??"
                arg2Var = List.head (List.drop 2 st4_.decodedVars) |> Maybe.withDefault "??"
                arg3Var = List.head (List.drop 1 st4_.decodedVars) |> Maybe.withDefault "??"
                arg4Var = List.head st4_.decodedVars |> Maybe.withDefault "??"
                ( resultVar, st5 ) = freshVar st4_
            in
            { st5
                | ops = st5.ops ++ [ Apply4 fnExpr arg1Var arg2Var arg3Var arg4Var resultVar ]
                , decodedVars = resultVar :: List.drop 4 st5.decodedVars
            }

        DMap5 fnExpr d1 d2 d3 d4 d5 ->
            let
                st1 = compileNode d1 st
                st2 = compileNode d2 st1
                st3_ = compileNode d3 st2
                st4_ = compileNode d4 st3_
                st5_ = compileNode d5 st4_
                arg1Var = List.head (List.drop 4 st5_.decodedVars) |> Maybe.withDefault "??"
                arg2Var = List.head (List.drop 3 st5_.decodedVars) |> Maybe.withDefault "??"
                arg3Var = List.head (List.drop 2 st5_.decodedVars) |> Maybe.withDefault "??"
                arg4Var = List.head (List.drop 1 st5_.decodedVars) |> Maybe.withDefault "??"
                arg5Var = List.head st5_.decodedVars |> Maybe.withDefault "??"
                ( resultVar, st6 ) = freshVar st5_
            in
            { st6
                | ops = st6.ops ++ [ Apply5 fnExpr arg1Var arg2Var arg3Var arg4Var arg5Var resultVar ]
                , decodedVars = resultVar :: List.drop 5 st6.decodedVars
            }


freshVar : CompileState -> ( String, CompileState )
freshVar st =
    ( "v" ++ String.fromInt st.varCounter
    , { st | varCounter = st.varCounter + 1 }
    )
```

### 4.4 Create `compiler/src/Compiler/Generate/MLIR/BytesFusion/EmitBFDecoder.elm`

**✅ SCF-ONLY Emission Strategy (FINAL)**

The emitter uses nested `scf.if` for fail-fast bounds checking. No CF dialect blocks.

**Architecture:**
- Each read is wrapped in `scf.if` that checks bounds first
- If bounds check fails, immediately return Nothing
- If bounds check passes, do the read and continue
- No `okVar` accumulation - failure is handled immediately

**Generated MLIR Pattern:**

```mlir
// For decode(map2(f, decodeU8, decodeU16)):
%ok1 = bf.require(%cur, 1)
%result = scf.if %ok1 -> !eco.value {
  %v1, %cur2 = bf.read.u8(%cur)
  %ok2 = bf.require(%cur2, 2)
  %inner = scf.if %ok2 -> !eco.value {
    %v2, %cur3 = bf.read.u16_be(%cur2)
    %applied = eco.call @apply2(%f, %v1, %v2)
    %just = call @elm_maybe_just(%applied)
    scf.yield %just : !eco.value
  } else {
    %nothing = call @elm_maybe_nothing()
    scf.yield %nothing : !eco.value
  }
  scf.yield %inner : !eco.value
} else {
  %nothing = call @elm_maybe_nothing()
  scf.yield %nothing : !eco.value
}
```

**Elm Implementation:**

```elm
module Compiler.Generate.MLIR.BytesFusion.EmitBFDecoder exposing (emitFusedDecoder)

{-| SCF-based decoder emitter with fail-fast bounds checking.

Each read is wrapped in scf.if: check bounds, if ok then read+continue, else Nothing.
No okVar accumulation. Ops are in forward execution order.
-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.MLIR.BytesFusion.LoopIR as IR exposing (DecoderOp(..), Endianness(..))
import Compiler.Generate.MLIR.Context as Ctx exposing (Context)
import Compiler.Generate.MLIR.Expr as Expr exposing (ExprResult)
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Mlir.Mlir exposing (MlirOp, MlirType(..), MlirAttr(..))


{-| Emitter state - no okVar, uses nested scf.if instead.
-}
type alias EmitState =
    { ctx : Context
    , cursor : String              -- Current cursor SSA variable
    , decodedValues : List String  -- Stack of decoded value SSA vars
    }


{-| Emit a complete fused decoder, returning Maybe a.

Recursively emits nested scf.if for each read op.
-}
emitFusedDecoder : Context -> Mono.MonoExpr -> List DecoderOp -> ExprResult
emitFusedDecoder ctx bytesExpr ops =
    let
        -- Generate the bytes expression
        bytesResult = Expr.generateExpr ctx bytesExpr

        -- Initialize cursor from bytes
        ( curVar, ctx1 ) = Ctx.freshVar bytesResult.ctx
        ( ctx2, initOp ) =
            Ops.bfCursorInit ctx1 bytesResult.resultVar curVar

        -- Emit nested scf.if structure for all ops
        ( resultVar, finalCtx, bodyOps ) =
            emitOpsNested ctx2 curVar ops []
    in
    { ops = bytesResult.ops ++ [ initOp ] ++ bodyOps
    , resultVar = resultVar
    , resultType = Types.ecoValue
    , ctx = finalCtx
    , isTerminated = False
    }


{-| Emit ops as nested scf.if structure.

For each read op: bf.require -> scf.if ok { read, continue } else { Nothing }
-}
emitOpsNested : Context -> String -> List DecoderOp -> List String -> ( String, Context, List MlirOp )
emitOpsNested ctx cursor ops decodedVars =
    case ops of
        [] ->
            -- No more ops - return Just with final decoded value
            emitJustResult ctx decodedVars

        (ReadU8 _ resultVar) :: rest ->
            emitReadWithScfIf ctx cursor 1 "bf.read.u8" I8 resultVar rest decodedVars

        (ReadU16 _ endian resultVar) :: rest ->
            let opName = endianOpName "bf.read.u16" endian
            in emitReadWithScfIf ctx cursor 2 opName I16 resultVar rest decodedVars

        (ReadU32 _ endian resultVar) :: rest ->
            let opName = endianOpName "bf.read.u32" endian
            in emitReadWithScfIf ctx cursor 4 opName I32 resultVar rest decodedVars

        (ReadF32 _ endian resultVar) :: rest ->
            let opName = endianOpName "bf.read.f32" endian
            in emitReadWithScfIf ctx cursor 4 opName F32 resultVar rest decodedVars

        (ReadF64 _ endian resultVar) :: rest ->
            let opName = endianOpName "bf.read.f64" endian
            in emitReadWithScfIf ctx cursor 8 opName F64 resultVar rest decodedVars

        (ReadBytes _ lenExpr resultVar) :: rest ->
            emitReadBytesWithScfIf ctx cursor lenExpr resultVar rest decodedVars

        (ReadUtf8 _ lenExpr resultVar) :: rest ->
            emitReadUtf8WithScfIf ctx cursor lenExpr resultVar rest decodedVars

        (PushValue valueExpr resultVar) :: rest ->
            -- Decode.succeed: push value without reading
            let
                valueResult = Expr.generateExpr ctx valueExpr
                newDecodedVars = valueResult.resultVar :: decodedVars
                ( resultVar_, ctx2, restOps ) =
                    emitOpsNested valueResult.ctx cursor rest newDecodedVars
            in
            ( resultVar_, ctx2, valueResult.ops ++ restOps )

        (Apply1 fnExpr argVar resultVar) :: rest ->
            emitApplyN ctx cursor [ argVar ] fnExpr resultVar rest decodedVars

        (Apply2 fnExpr arg1 arg2 resultVar) :: rest ->
            emitApplyN ctx cursor [ arg1, arg2 ] fnExpr resultVar rest decodedVars

        (Apply3 fnExpr arg1 arg2 arg3 resultVar) :: rest ->
            emitApplyN ctx cursor [ arg1, arg2, arg3 ] fnExpr resultVar rest decodedVars

        (Apply4 fnExpr arg1 arg2 arg3 arg4 resultVar) :: rest ->
            emitApplyN ctx cursor [ arg1, arg2, arg3, arg4 ] fnExpr resultVar rest decodedVars

        (Apply5 fnExpr arg1 arg2 arg3 arg4 arg5 resultVar) :: rest ->
            emitApplyN ctx cursor [ arg1, arg2, arg3, arg4, arg5 ] fnExpr resultVar rest decodedVars

        (ReturnJust resultVar) :: _ ->
            emitJustResult ctx (resultVar :: decodedVars)

        ReturnNothing :: _ ->
            emitNothingResult ctx

        (InitReadCursor _ _) :: rest ->
            -- Already handled at top level
            emitOpsNested ctx cursor rest decodedVars


{-| Emit a read wrapped in scf.if for bounds check.
-}
emitReadWithScfIf : Context -> String -> Int -> String -> MlirType -> String
                  -> List DecoderOp -> List String
                  -> ( String, Context, List MlirOp )
emitReadWithScfIf ctx cursor byteCount opName valueTy resultVar rest decodedVars =
    let
        -- bf.require(cursor, byteCount) -> ok : i1
        ( okVar, ctx1 ) = Ctx.freshVar ctx
        ( ctx2, requireOp ) = Ops.bfRequire ctx1 cursor byteCount okVar

        -- Then branch: read and continue
        ( valueVar, ctx3 ) = Ctx.freshVar ctx2
        ( newCursor, ctx4 ) = Ctx.freshVar ctx3
        ( ctx5, readOp ) =
            Ops.mlirOp ctx4 opName
                |> Ops.opBuilder.withOperands [ cursor ]
                |> Ops.opBuilder.withResults
                    [ ( valueVar, valueTy )
                    , ( newCursor, Types.bfCur )
                    ]
                |> Ops.opBuilder.build

        -- Recursively emit rest with new cursor and decoded value
        ( innerResult, ctx6, innerOps ) =
            emitOpsNested ctx5 newCursor rest (valueVar :: decodedVars)

        -- Else branch: return Nothing
        ( nothingVar, ctx7 ) = Ctx.freshVar ctx6
        ( ctx8, nothingOp ) = Ops.callRuntime ctx7 "elm_maybe_nothing" [] nothingVar Types.ecoValue

        -- Build scf.if
        ( scfResult, ctx9 ) = Ctx.freshVar ctx8
        ( ctx10, scfIfOp ) =
            Ops.scfIf ctx9 okVar Types.ecoValue
                { body = [ readOp ] ++ innerOps ++ [ Ops.scfYield innerResult ] }
                { body = [ nothingOp, Ops.scfYield nothingVar ] }
                scfResult
    in
    ( scfResult, ctx10, [ requireOp, scfIfOp ] )


{-| ✅ HARD REQUIREMENT: Length conversion (Elm Int -> i32)

Bytes.Decode.bytes/string take an Elm Int length. At MLIR level this is i64.

But bf.require and bf.read.{bytes,utf8} take i32 lengths.

Therefore every length expression must be:
1) evaluated as i64
2) checked: 0 <= len && len <= 0xFFFF_FFFF
3) truncated to i32 for bf.require/bf.read

If the check fails, the decoder must return Nothing.
-}


{-| Emit read.bytes with dynamic length and scf.if.
-}
emitReadBytesWithScfIf : Context -> String -> Mono.MonoExpr -> String
                       -> List DecoderOp -> List String
                       -> ( String, Context, List MlirOp )
emitReadBytesWithScfIf ctx cursor lenExpr resultVar rest decodedVars =
    let
        -- Evaluate length expression (produces i64)
        lenResult = Expr.generateExpr ctx lenExpr

        -- Convert length from i64 to i32 with bounds check
        ( len32Var, lenOkVar, ctx1, lenConvOps ) =
            Ops.convertLenI64ToI32Checked lenResult.ctx lenResult.resultVar

        -- bf.require(cursor, len32) -> ok : i1
        ( okVar, ctx2 ) = Ctx.freshVar ctx1
        ( ctx3, requireOp ) = Ops.bfRequireDyn ctx2 cursor len32Var okVar

        -- Combine length ok and bounds ok
        ( combinedOk, ctx4 ) = Ctx.freshVar ctx3
        ( ctx5, andOp ) = Ops.arithAndI1 ctx4 lenOkVar okVar combinedOk

        -- Then branch: read.bytes -> (bytes: eco.value, newCur, heapOk: i1)
        -- Note: heap reads return ok for allocation/decode failures
        ( bytesVar, ctx6 ) = Ctx.freshVar ctx5
        ( newCursor, ctx7 ) = Ctx.freshVar ctx6
        ( heapOk, ctx8 ) = Ctx.freshVar ctx7
        ( ctx9, readOp ) =
            Ops.mlirOp ctx8 "bf.read.bytes"
                |> Ops.opBuilder.withOperands [ cursor, len32Var ]
                |> Ops.opBuilder.withResults
                    [ ( bytesVar, Types.ecoValue )  -- ✅ heap object stays !eco.value in MLIR
                    , ( newCursor, Types.bfCur )
                    , ( heapOk, I1 )
                    ]
                |> Ops.opBuilder.build

        -- Inner scf.if for heap operation success
        ( innerResult, ctx7, innerOps ) =
            emitOpsNested ctx6 newCursor rest (bytesVar :: decodedVars)

        ( nothingVar1, ctx8 ) = Ctx.freshVar ctx7
        ( ctx9, nothingOp1 ) = Ops.callRuntime ctx8 "elm_maybe_nothing" [] nothingVar1 Types.ecoValue

        ( innerScfResult, ctx10 ) = Ctx.freshVar ctx9
        ( ctx11, innerScfOp ) =
            Ops.scfIf ctx10 heapOk Types.ecoValue
                { body = innerOps ++ [ Ops.scfYield innerResult ] }
                { body = [ nothingOp1, Ops.scfYield nothingVar1 ] }
                innerScfResult

        -- Else branch (bounds fail): return Nothing
        ( nothingVar2, ctx12 ) = Ctx.freshVar ctx11
        ( ctx13, nothingOp2 ) = Ops.callRuntime ctx12 "elm_maybe_nothing" [] nothingVar2 Types.ecoValue

        -- Outer scf.if for combined (length ok AND bounds ok)
        ( scfResult, ctx14 ) = Ctx.freshVar ctx13
        ( ctx15, scfIfOp ) =
            Ops.scfIf ctx14 combinedOk Types.ecoValue
                { body = [ readOp, innerScfOp, Ops.scfYield innerScfResult ] }
                { body = [ nothingOp2, Ops.scfYield nothingVar2 ] }
                scfResult
    in
    ( scfResult, ctx15, lenResult.ops ++ lenConvOps ++ [ requireOp, andOp, scfIfOp ] )


{-| Emit read.utf8 with dynamic length and scf.if.
-}
emitReadUtf8WithScfIf : Context -> String -> Mono.MonoExpr -> String
                      -> List DecoderOp -> List String
                      -> ( String, Context, List MlirOp )
emitReadUtf8WithScfIf ctx cursor lenExpr resultVar rest decodedVars =
    -- Same structure as emitReadBytesWithScfIf but calls bf.read.utf8
    let
        -- Evaluate length expression (produces i64)
        lenResult = Expr.generateExpr ctx lenExpr

        -- Convert length from i64 to i32 with bounds check
        ( len32Var, lenOkVar, ctx1, lenConvOps ) =
            Ops.convertLenI64ToI32Checked lenResult.ctx lenResult.resultVar

        -- bf.require(cursor, len32) -> ok : i1
        ( okVar, ctx2 ) = Ctx.freshVar ctx1
        ( ctx3, requireOp ) = Ops.bfRequireDyn ctx2 cursor len32Var okVar

        -- Combine length ok and bounds ok
        ( combinedOk, ctx4 ) = Ctx.freshVar ctx3
        ( ctx5, andOp ) = Ops.arithAndI1 ctx4 lenOkVar okVar combinedOk

        ( stringVar, ctx6 ) = Ctx.freshVar ctx5
        ( newCursor, ctx7 ) = Ctx.freshVar ctx6
        ( heapOk, ctx8 ) = Ctx.freshVar ctx7
        ( ctx9, readOp ) =
            Ops.mlirOp ctx8 "bf.read.utf8"
                |> Ops.opBuilder.withOperands [ cursor, len32Var ]
                |> Ops.opBuilder.withResults
                    [ ( stringVar, Types.ecoValue )  -- ✅ heap object stays !eco.value in MLIR
                    , ( newCursor, Types.bfCur )
                    , ( heapOk, I1 )
                    ]
                |> Ops.opBuilder.build

        ( innerResult, ctx10, innerOps ) =
            emitOpsNested ctx9 newCursor rest (stringVar :: decodedVars)

        ( nothingVar1, ctx11 ) = Ctx.freshVar ctx10
        ( ctx12, nothingOp1 ) = Ops.callRuntime ctx11 "elm_maybe_nothing" [] nothingVar1 Types.ecoValue

        ( innerScfResult, ctx13 ) = Ctx.freshVar ctx12
        ( ctx14, innerScfOp ) =
            Ops.scfIf ctx13 heapOk Types.ecoValue
                { body = innerOps ++ [ Ops.scfYield innerResult ] }
                { body = [ nothingOp1, Ops.scfYield nothingVar1 ] }
                innerScfResult

        ( nothingVar2, ctx15 ) = Ctx.freshVar ctx14
        ( ctx16, nothingOp2 ) = Ops.callRuntime ctx15 "elm_maybe_nothing" [] nothingVar2 Types.ecoValue

        ( scfResult, ctx17 ) = Ctx.freshVar ctx16
        ( ctx18, scfIfOp ) =
            Ops.scfIf ctx17 combinedOk Types.ecoValue
                { body = [ readOp, innerScfOp, Ops.scfYield innerScfResult ] }
                { body = [ nothingOp2, Ops.scfYield nothingVar2 ] }
                scfResult
    in
    ( scfResult, ctx18, lenResult.ops ++ lenConvOps ++ [ requireOp, andOp, scfIfOp ] )


{-| Emit function application and continue.
-}
emitApplyN : Context -> String -> List String -> Mono.MonoExpr -> String
           -> List DecoderOp -> List String
           -> ( String, Context, List MlirOp )
emitApplyN ctx cursor argVars fnExpr resultVar rest decodedVars =
    let
        -- Generate the function expression
        fnResult = Expr.generateExpr ctx fnExpr

        -- Emit eco.apply / eco.call for the function application
        ( appliedVar, ctx2 ) = Ctx.freshVar fnResult.ctx
        ( ctx3, applyOps ) =
            Ops.ecoApply ctx2 fnResult.resultVar argVars appliedVar

        -- Update decoded vars: remove consumed args, add result
        newDecodedVars = appliedVar :: List.drop (List.length argVars) decodedVars

        -- Continue with rest
        ( resultVar_, ctx4, restOps ) =
            emitOpsNested ctx3 cursor rest newDecodedVars
    in
    ( resultVar_, ctx4, fnResult.ops ++ applyOps ++ restOps )


{-| Emit Just wrapping the final decoded value.
-}
emitJustResult : Context -> List String -> ( String, Context, List MlirOp )
emitJustResult ctx decodedVars =
    let
        resultVar =
            case decodedVars of
                v :: _ -> v
                [] -> ""  -- Error case

        ( justVar, ctx1 ) = Ctx.freshVar ctx
        ( ctx2, justOp ) = Ops.callRuntime ctx1 "elm_maybe_just" [ resultVar ] justVar Types.ecoValue
    in
    ( justVar, ctx2, [ justOp ] )


{-| Emit Nothing result.
-}
emitNothingResult : Context -> ( String, Context, List MlirOp )
emitNothingResult ctx =
    let
        ( nothingVar, ctx1 ) = Ctx.freshVar ctx
        ( ctx2, nothingOp ) = Ops.callRuntime ctx1 "elm_maybe_nothing" [] nothingVar Types.ecoValue
    in
    ( nothingVar, ctx2, [ nothingOp ] )


{-| Helper: endian-specific op name.
-}
endianOpName : String -> Endianness -> String
endianOpName base endian =
    case endian of
        BE -> base ++ "_be"
        LE -> base ++ "_le"
```

**Required Ops.elm helpers** (assumption - must exist or be created):
- `Ops.bfRequire : Context -> String -> Int -> String -> ( Context, MlirOp )`
- `Ops.bfRequireDyn : Context -> String -> String -> String -> ( Context, MlirOp )`
- `Ops.bfCursorInit : Context -> String -> String -> ( Context, MlirOp )`
- `Ops.scfIf : Context -> String -> MlirType -> { body : List MlirOp } -> { body : List MlirOp } -> String -> ( Context, MlirOp )`
- `Ops.scfYield : String -> MlirOp`
- `Ops.ecoApply : Context -> String -> List String -> String -> ( Context, List MlirOp )`
- `Ops.callRuntime : Context -> String -> List String -> String -> MlirType -> ( Context, MlirOp )`
- `Ops.convertLenI64ToI32Checked : Context -> String -> ( String, String, Context, List MlirOp )` - returns `(len32Var, okVar, ctxOut, ops)` with bounds check `0 <= len && len <= 0xFFFF_FFFF`
- `Ops.arithAndI1 : Context -> String -> String -> String -> ( Context, MlirOp )` - i1 AND operation

---

## Step 5: Compiler Integration

### 5.1 Update `Expr.elm` to intercept `Bytes.Decode.decode`

In the `generateSaturatedCall` function, add:

```elm
-- Intercept Bytes.Decode.decode
Just ( pkg, "Bytes.Decode", "decode" ) ->
    if pkg == Pkg.bytes then
        case args of
            [ decoderExpr, bytesExpr ] ->
                -- Try to reify the decoder AST
                case ReifyDecoder.reifyDecoder ctx.registry decoderExpr of
                    Just decoderNode ->
                        -- Compile to Loop IR and emit bf ops
                        let
                            loopOps = CompileDecoder.compileDecoder decoderNode
                        in
                        EmitBFDecoder.emitFusedDecoder ctx bytesExpr loopOps

                    Nothing ->
                        -- Can't statically analyze - fall back to kernel
                        generateKernelCallFallback ctx funcInfo resultType argOps argsWithTypes

            _ ->
                -- Wrong number of args - fall back
                generateKernelCallFallback ctx funcInfo resultType argOps argsWithTypes
    else
        -- ... existing code ...
```

---

## Step 6: Testing

### 6.1 Unit tests for ReifyDecoder

Test pattern matching on various decoder expressions.

### 6.2 E2E tests

Create `test/elm/src/BytesDecodeTests.elm`:

```elm
module BytesDecodeTests exposing (..)

import Bytes exposing (Bytes)
import Bytes.Decode as Decode
import Bytes.Encode as Encode


-- Test simple u8 decode
testDecodeU8 =
    let
        bytes = Encode.encode (Encode.unsignedInt8 42)
        result = Decode.decode Decode.unsignedInt8 bytes
    in
    -- CHECK: Just 42
    Debug.log "testDecodeU8" result


-- Test u16 big-endian
testDecodeU16BE =
    let
        bytes = Encode.encode (Encode.unsignedInt16 Bytes.BE 0x1234)
        result = Decode.decode (Decode.unsignedInt16 Bytes.BE) bytes
    in
    -- CHECK: Just 4660
    Debug.log "testDecodeU16BE" result


-- Test map2
testDecodeMap2 =
    let
        bytes = Encode.encode (Encode.sequence
            [ Encode.unsignedInt8 10
            , Encode.unsignedInt8 20
            ])
        decoder = Decode.map2 Tuple.pair
            Decode.unsignedInt8
            Decode.unsignedInt8
        result = Decode.decode decoder bytes
    in
    -- CHECK: Just (10, 20)
    Debug.log "testDecodeMap2" result


-- Test failure (not enough bytes)
testDecodeFailure =
    let
        bytes = Encode.encode (Encode.unsignedInt8 42)
        result = Decode.decode (Decode.unsignedInt16 Bytes.BE) bytes
    in
    -- CHECK: Nothing
    Debug.log "testDecodeFailure" result


-- Test string decode
testDecodeString =
    let
        bytes = Encode.encode (Encode.string "hello")
        result = Decode.decode (Decode.string 5) bytes
    in
    -- CHECK: Just "hello"
    Debug.log "testDecodeString" result
```

---

## File Change Summary

### New Files (4)

| File | Description |
|------|-------------|
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/ReifyDecoder.elm` | Decoder AST recognizer |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/CompileDecoder.elm` | Decoder → Loop IR |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/EmitBFDecoder.elm` | Loop IR → bf MLIR (decoder) |
| `test/elm/src/BytesDecodeTests.elm` | E2E decoder tests |

### Modified Files (5)

| File | Changes |
|------|---------|
| `runtime/src/allocator/ElmBytesRuntime.h` | Add `elm_utf8_decode`, `elm_maybe_*` |
| `runtime/src/allocator/ElmBytesRuntime.cpp` | Implement new functions |
| `runtime/src/codegen/RuntimeSymbols.cpp` | Register new symbols |
| `runtime/src/codegen/BF/BFOps.td` | Add read ops, require, status type |
| `runtime/src/codegen/Passes/BFToLLVM.cpp` | Add read lowering patterns |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/LoopIR.elm` | Add DecoderOp type |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Intercept Bytes.Decode.decode |

---

## Remaining Questions

### 1. Maybe representation

How is `Maybe a` represented in the runtime?
- Is there a `Nothing` singleton?
- How is `Just value` allocated?

This affects `elm_maybe_nothing` and `elm_maybe_just` implementation.

### 2. scf.if support in Ops.elm

Does the existing `Ops.elm` support emitting `scf.if` with then/else regions?
If not, this needs to be added.

### 3. Scalar representation (HARD GATE)

Confirm the MLIR-level representation of Elm `Int` and `Float`. This plan assumes:
- Elm `Int` lowers to `i64`
- Elm `Float` lowers to `f64`

Therefore, **bf ops must consume/produce Elm-level scalars (`i64`/`f64`)**, and BFToLLVM must do trunc/extend/bitcasts internally for byte encodings (u8/u16/u32/f32/f64 storage).

If Elm `Int` is not `i64` or Elm `Float` not `f64`, update bf op signatures and all emitter typing accordingly before implementing fusion.

---

## Assumptions

- **A1**: Phase 1 is complete and working
- **A2**: `scf.if` can be emitted from Elm codegen (may need to add support)
- **A3**: Maybe is a standard custom type with Nothing/Just constructors
- **A4**: Signed integers use the same read ops, just different type interpretation

---

## Future Phases

### Phase 3: andThen support

- Recognize `andThen` patterns for length-prefixed data
- e.g., `Decode.unsignedInt32 BE |> Decode.andThen (\len -> Decode.string len)`

### Phase 4: loop support

- Emit `scf.while` for list decoding
- Recognize `Decode.loop` patterns
---
---

# Phase 3: andThen Support

**Goal:** Recognize and fuse common `andThen` patterns in `Bytes.Decode`, specifically length-prefixed data.

**Prerequisite:** Phase 2 (Decoder) must be complete - provides:
---
---

- Decoder reification infrastructure
- bf read ops and lowering
- Maybe return type handling

**Design Document:** `/work/design_docs/fused-bytes-compilation.md`

---

## Understanding andThen

### Signature

```elm
andThen : (a -> Decoder b) -> Decoder a -> Decoder b
```

### Semantics

1. Run the first decoder to get value `a`
2. Apply the function to `a` to get a new decoder
3. Run that decoder to get value `b`
4. Return `b` (wrapped in Maybe at top level)

### Why andThen is Challenging

The function `(a -> Decoder b)` can be **arbitrary Elm code**. We cannot fuse:
```elm
-- Arbitrary function - cannot analyze statically
Decode.unsignedInt8 |> Decode.andThen myComplexFunction
```

But we CAN fuse **bounded patterns** where the function body is simple and predictable.

---

## Fuseable Patterns

### Pattern 1: Length-Prefixed String

```elm
-- Read 4-byte length, then read that many bytes as UTF-8
Decode.unsignedInt32 Bytes.BE
    |> Decode.andThen (\len -> Decode.string len)
```

**Structure:**
- First decoder: primitive integer decoder
- Lambda: single parameter used directly as argument to `Decode.string`

**Fused form:**
```
1. Read u32 BE → len
2. Read len bytes as UTF-8 → string
3. Return string
```

### Pattern 2: Length-Prefixed Bytes

```elm
-- Read 2-byte length, then read that many raw bytes
Decode.unsignedInt16 Bytes.LE
    |> Decode.andThen (\len -> Decode.bytes len)
```

**Structure:**
- First decoder: primitive integer decoder
- Lambda: single parameter used directly as argument to `Decode.bytes`

**Fused form:**
```
1. Read u16 LE → len
2. Read len bytes → bytes
3. Return bytes
```

### Pattern 3: Chained andThen (Length + String + More)

```elm
-- Read length, string, then another field
Decode.unsignedInt32 Bytes.BE
    |> Decode.andThen (\len ->
        Decode.map2 Tuple.pair
            (Decode.string len)
            Decode.unsignedInt8
    )
```

**Structure:**
- First decoder: primitive integer decoder
- Lambda body: uses parameter in a decoder that we can recursively analyze

### Pattern 4: Nested Length-Prefixed

```elm
-- Read outer length, then inner structure with its own length
Decode.unsignedInt32 Bytes.BE
    |> Decode.andThen (\outerLen ->
        Decode.unsignedInt32 Bytes.BE
            |> Decode.andThen (\innerLen -> Decode.string innerLen)
    )
```

---

## Non-Fuseable Patterns (Fall Back to Kernel)

### Case Expressions / Conditionals

```elm
-- Tag-based decoding - requires runtime branching
Decode.unsignedInt8
    |> Decode.andThen (\tag ->
        case tag of
            0 -> Decode.map Foo Decode.unsignedInt32
            1 -> Decode.map Bar Decode.string 10
            _ -> Decode.fail
    )
```

**Why not fuseable:** The decoder chosen depends on runtime value. Would require emitting a switch/case in MLIR, which is complex.

### External Function Calls

```elm
-- Function defined elsewhere
Decode.unsignedInt8 |> Decode.andThen decodeBasedOnVersion
```

**Why not fuseable:** Cannot see inside `decodeBasedOnVersion`.

### Complex Lambda Bodies

```elm
-- Arithmetic in lambda
Decode.unsignedInt32 Bytes.BE
    |> Decode.andThen (\len -> Decode.string (len - 4))
```

**Phase 3 scope:** Could potentially support simple arithmetic, but start with direct use only.

---

## Implementation Strategy

### Key Insight: Lambda Body Analysis

To fuse `andThen`, we must analyze the lambda body at the MonoExpr level:

```elm
MonoCall _ andThenFunc [ lambdaExpr, firstDecoderExpr ] _ ->
    case lambdaExpr of
        MonoClosure closureInfo bodyExpr _ ->
            -- Analyze bodyExpr to see if it's a fuseable pattern
            analyzeLambdaBody closureInfo bodyExpr
```

The lambda captures the parameter name. We look for patterns where that parameter is used directly as an argument to `Decode.string` or `Decode.bytes`.

---

## Step 1: Extend DecoderNode for andThen

### 1.1 Update `ReifyDecoder.elm`

```elm
type DecoderNode
    = -- ... existing constructors from Phase 2 ...

    -- NEW: Length-prefixed patterns
    | DLengthPrefixedString LengthDecoder  -- Read length, then string
    | DLengthPrefixedBytes LengthDecoder   -- Read length, then bytes

    -- NEW: General andThen (for patterns we can analyze)
    | DAndThen DecoderNode LambdaBinding DecoderNode
      -- firstDecoder, paramName, bodyDecoder (which may reference param)


{-| How to decode the length value.
-}
type LengthDecoder
    = LenU8
    | LenU16 Endianness
    | LenU32 Endianness
    | LenI8
    | LenI16 Endianness
    | LenI32 Endianness


{-| Lambda binding info for andThen.
-}
type alias LambdaBinding =
    { paramName : String
    , paramType : Mono.MonoType
    }
```

### 1.2 Add andThen Pattern Recognition

```elm
reifyBytesDecodeCall : Mono.MonoRegistry -> String -> List Mono.MonoExpr -> Maybe DecoderNode
reifyBytesDecodeCall registry name args =
    case ( name, args ) of
        -- ... existing cases ...

        ( "andThen", [ lambdaExpr, firstDecoderExpr ] ) ->
            reifyAndThen registry lambdaExpr firstDecoderExpr

        _ ->
            Nothing


{-| Try to reify an andThen expression into a fuseable pattern.
-}
reifyAndThen : Mono.MonoRegistry -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
reifyAndThen registry lambdaExpr firstDecoderExpr =
    -- First, reify the initial decoder
    case reifyDecoder registry firstDecoderExpr of
        Nothing ->
            Nothing

        Just firstDecoder ->
            -- Analyze the lambda
            case lambdaExpr of
                Mono.MonoClosure closureInfo bodyExpr _ ->
                    reifyAndThenBody registry firstDecoder closureInfo bodyExpr

                _ ->
                    Nothing


{-| Analyze the lambda body to identify fuseable patterns.
-}
reifyAndThenBody :
    Mono.MonoRegistry
    -> DecoderNode
    -> Mono.ClosureInfo
    -> Mono.MonoExpr
    -> Maybe DecoderNode
reifyAndThenBody registry firstDecoder closureInfo bodyExpr =
    let
        -- Get the lambda parameter name
        paramName =
            case closureInfo.params of
                [ ( name, _ ) ] -> name
                _ -> ""  -- andThen lambda should have exactly 1 param
    in
    if paramName == "" then
        Nothing
    else
        -- Try to match length-prefixed patterns
        case matchLengthPrefixedPattern registry paramName bodyExpr of
            Just pattern ->
                -- Convert firstDecoder to LengthDecoder if it's an integer type
                case decoderToLengthDecoder firstDecoder of
                    Just lenDecoder ->
                        Just pattern lenDecoder

                    Nothing ->
                        -- First decoder isn't an integer - can't use as length
                        Nothing

            Nothing ->
                -- Try general andThen pattern (recursive analysis)
                case reifyDecoder registry bodyExpr of
                    Just bodyDecoder ->
                        Just (DAndThen firstDecoder
                            { paramName = paramName, paramType = Mono.monoTypeOf bodyExpr }
                            bodyDecoder)

                    Nothing ->
                        Nothing


{-| Match patterns like (\len -> Decode.string len) or (\len -> Decode.bytes len)
-}
matchLengthPrefixedPattern :
    Mono.MonoRegistry
    -> String
    -> Mono.MonoExpr
    -> Maybe (LengthDecoder -> DecoderNode)
matchLengthPrefixedPattern registry paramName bodyExpr =
    case bodyExpr of
        Mono.MonoCall _ func [ argExpr ] _ ->
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    case Mono.lookupSpecKey specId registry of
                        Just (Global (Canonical pkg moduleName) name, _, _) ->
                            if pkg == Pkg.bytes && moduleName == "Bytes.Decode" then
                                -- Check if arg is just the parameter variable
                                if isVarReference paramName argExpr then
                                    case name of
                                        "string" ->
                                            Just DLengthPrefixedString
                                        "bytes" ->
                                            Just DLengthPrefixedBytes
                                        _ ->
                                            Nothing
                                else
                                    Nothing
                            else
                                Nothing
                        _ ->
                            Nothing
                _ ->
                    Nothing

        _ ->
            Nothing


{-| Check if expression is a simple variable reference to the given name.

**NOTE:** This check is correct for pattern recognition. However, at emission time,
the decoded "len" value must become an SSA variable that the emitter can reference.
This depends on the Phase 2 fix for "decoded SSA vars must be usable" (Apply1/2/etc).
-}
isVarReference : String -> Mono.MonoExpr -> Bool
isVarReference name expr =
    case expr of
        Mono.MonoVarLocal varName _ ->
            varName == name
        _ ->
            False


{-| Convert a primitive decoder to a LengthDecoder.
-}
decoderToLengthDecoder : DecoderNode -> Maybe LengthDecoder
decoderToLengthDecoder decoder =
    case decoder of
        DU8 -> Just LenU8
        DS8 -> Just LenI8
        DU16 e -> Just (LenU16 e)
        DS16 e -> Just (LenI16 e)
        DU32 e -> Just (LenU32 e)
        DS32 e -> Just (LenI32 e)
        _ -> Nothing
```

---

## Step 2: Extend Loop IR for Length-Prefixed

### 2.1 Update `LoopIR.elm`

```elm
type DecoderOp
    = -- ... existing ops from Phase 2 (ReadU8, ReadUtf8, Apply1-5, PushValue, etc.) ...

    -- NEW: Length-reading operations (fixed-size length field)
    | ReadLen String LengthReadOp String
      -- cursorName, lengthReadOp, resultVarName (stores length as i32)
      -- Emitter wraps in scf.if for bounds check (1/2/4 bytes)

    -- NEW: Dynamic-length read operations (length from SSA var)
    | ReadDynUtf8 String String String
      -- cursorName, lengthVarName, resultVarName
      -- Emitter emits: bf.require(cur, len), scf.if ok { bf.read.dyn_utf8 ... }

    | ReadDynBytes String String String
      -- cursorName, lengthVarName, resultVarName
      -- Same pattern as ReadDynUtf8


{-| How to read the length value.

NOTE: Bounds checking is handled by the emitter via scf.if, not here.
-}
type LengthReadOp
    = ReadLenU8      -- 1 byte, emitter checks bounds for 1 byte
    | ReadLenU16BE   -- 2 bytes big-endian
    | ReadLenU16LE   -- 2 bytes little-endian
    | ReadLenU32BE   -- 4 bytes big-endian
    | ReadLenU32LE   -- 4 bytes little-endian
```

**Note:** The old `ReadLengthPrefixedString/Bytes` ops are REMOVED. They combined
too much logic. Instead, use the decomposed ops above with explicit require+branch.

---

## Step 3: Extend Compiler for Length-Prefixed

### 3.1 Update `CompileDecoder.elm`

```elm
compileNode : DecoderNode -> CompileState -> CompileState
compileNode node st =
    case node of
        -- ... existing cases ...

        DLengthPrefixedString lenDecoder ->
            {- SCF-compatible: Just emit ReadLen + ReadDynUtf8.
               Bounds checking is handled by the emitter via scf.if.
            -}
            let
                ( lenVar, st1 ) = freshVar st
                ( outVar, st2 ) = freshVar st1
                lenReadOp = lengthDecoderToReadOp lenDecoder
            in
            { st2
                | ops =
                    st2.ops
                        ++ [ ReadLen "cur" lenReadOp lenVar
                           , ReadDynUtf8 "cur" lenVar outVar
                           ]
                , decodedVars = outVar :: st2.decodedVars
            }

        DLengthPrefixedBytes lenDecoder ->
            {- SCF-compatible: Just emit ReadLen + ReadDynBytes.
               Bounds checking is handled by the emitter via scf.if.
            -}
            let
                ( lenVar, st1 ) = freshVar st
                ( outVar, st2 ) = freshVar st1
                lenReadOp = lengthDecoderToReadOp lenDecoder
            in
            { st2
                | ops =
                    st2.ops
                        ++ [ ReadLen "cur" lenReadOp lenVar
                           , ReadDynBytes "cur" lenVar outVar
                           ]
                , decodedVars = outVar :: st2.decodedVars
            }

        DAndThen firstDecoder binding bodyDecoder ->
            -- Compile first decoder
            let
                st1 = compileNode firstDecoder st
                -- The result is now on decodedVars stack
                -- Compile body decoder (which may reference the result)
                st2 = compileNode bodyDecoder st1
            in
            st2

lengthDecoderToReadOp : LengthDecoder -> LengthReadOp
lengthDecoderToReadOp ld =
    case ld of
        LenU8 -> ReadLenU8
        LenU16 BE -> ReadLenU16BE
        LenU16 LE -> ReadLenU16LE
        LenU32 BE -> ReadLenU32BE
        LenU32 LE -> ReadLenU32LE
        LenI8 -> ReadLenU8  -- Same read, different interpretation
        LenI16 BE -> ReadLenU16BE
        LenI16 LE -> ReadLenU16LE
        LenI32 BE -> ReadLenU32BE
        LenI32 LE -> ReadLenU32LE
```

---

## Step 4: Extend bf Dialect

### 4.1 Add Combined Ops to `BFOps.td`

For efficiency, add combined length-prefixed ops that avoid intermediate values:

```tablegen
// ✅ CORRECTED: All results use ECO_ValueType (eco.value)

// Read length (u32 BE) then that many bytes as UTF-8 string
def BF_ReadLenStringU32BEOp : Op<BFDialect, "read.len_string_u32be", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs ECO_ValueType:$string, BF_CurType:$newCur, BF_StatusType:$ok);
  let summary = "Read u32 BE length, then that many bytes as UTF-8";
}

// Read length (u16 LE) then that many bytes as UTF-8 string
def BF_ReadLenStringU16LEOp : Op<BFDialect, "read.len_string_u16le", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs ECO_ValueType:$string, BF_CurType:$newCur, BF_StatusType:$ok);
}

// Similar for bytes...
def BF_ReadLenBytesU32BEOp : Op<BFDialect, "read.len_bytes_u32be", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs ECO_ValueType:$bytes, BF_CurType:$newCur, BF_StatusType:$ok);
}

// ... add variants for u8, u16 BE/LE, u32 BE/LE ...
```

**Alternative approach (recommended):** Keep ops separate and rely on the lowering to combine them:

```tablegen
// Use existing read ops + a "read dynamic bytes" op
def BF_ReadDynBytesOp : Op<BFDialect, "read.dyn_bytes", [Pure]> {
  let arguments = (ins BF_CurType:$cur, I32:$len);
  let results   = (outs ECO_ValueType:$bytes, BF_CurType:$newCur, BF_StatusType:$ok);
}

def BF_ReadDynUtf8Op : Op<BFDialect, "read.dyn_utf8", [Pure]> {
  let arguments = (ins BF_CurType:$cur, I32:$len);
  let results   = (outs ECO_ValueType:$string, BF_CurType:$newCur, BF_StatusType:$ok);
}
```

I recommend the **alternative approach** - it's more composable and we already have the read primitives.

---

## Step 5: Extend bf → LLVM Lowering

### 5.1 Update `BFToLLVM.cpp`

The lowering for length-prefixed is straightforward with the dynamic ops:

```cpp
// bf.read.dyn_utf8(cur, len) -> (i64 string, newCur, i1 ok)
// ASSUMPTION: bounds were already checked by bf.require + fail-fast control flow.
struct ReadDynUtf8OpLowering : public ConvertOpToLLVMPattern<bf::ReadDynUtf8Op> {
  LogicalResult matchAndRewrite(bf::ReadDynUtf8Op op, OpAdaptor adaptor,
                                 ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    Value cur = adaptor.getCur();
    Value len32 = adaptor.getLen();

    Value ptr = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 0);
    Value end = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 1);

    // newPtr = ptr + len
    Value len64 = rewriter.create<LLVM::ZExtOp>(loc, i64Type, len32);
    Value newPtr = rewriter.create<LLVM::GEPOp>(loc, ptrType, i8Type, ptr, len64);

    // stringVal : i64 = call @elm_utf8_decode(ptr, len32)
    Value stringVal = rewriter.create<LLVM::CallOp>(
        loc, i64Type, "elm_utf8_decode", ValueRange{ptr, len32}).getResult();

    // ok = (stringVal != 0)
    Value zero64 = rewriter.create<LLVM::ConstantOp>(loc, i64Type, 0);
    Value ok = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ne, stringVal, zero64);

    // Build new cursor
    Value newCur = rewriter.create<LLVM::UndefOp>(loc, cursorType);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, newPtr, 0);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, end, 1);

    rewriter.replaceOp(op, {stringVal, newCur, ok});
    return success();
  }
};

// bf.read.dyn_bytes(cur, len) -> (i64 bytes, newCur, i1 ok)
// ASSUMPTION: bounds were already checked by bf.require + fail-fast control flow.
struct ReadDynBytesOpLowering : public ConvertOpToLLVMPattern<bf::ReadDynBytesOp> {
  LogicalResult matchAndRewrite(bf::ReadDynBytesOp op, OpAdaptor adaptor,
                                 ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    Value cur = adaptor.getCur();
    Value len32 = adaptor.getLen();

    Value ptr = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 0);
    Value end = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 1);

    // newPtr = ptr + len
    Value len64 = rewriter.create<LLVM::ZExtOp>(loc, i64Type, len32);
    Value newPtr = rewriter.create<LLVM::GEPOp>(loc, ptrType, i8Type, ptr, len64);

    // Allocate ByteBuffer and copy
    // bytesVal : i64 = call @elm_alloc_bytebuffer(len32)
    Value bytesVal = rewriter.create<LLVM::CallOp>(
        loc, i64Type, "elm_alloc_bytebuffer", ValueRange{len32}).getResult();
    Value data = rewriter.create<LLVM::CallOp>(
        loc, ptrType, "elm_bytebuffer_data", ValueRange{bytesVal}).getResult();

    // memcpy(data, ptr, len)
    rewriter.create<LLVM::MemcpyOp>(loc, data, ptr, len64, /*isVolatile=*/false);

    // ok = (bytesVal != 0) -- allocation could fail
    Value zero64 = rewriter.create<LLVM::ConstantOp>(loc, i64Type, 0);
    Value ok = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ne, bytesVal, zero64);

    // Build new cursor
    Value newCur = rewriter.create<LLVM::UndefOp>(loc, cursorType);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, newPtr, 0);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, end, 1);

    rewriter.replaceOp(op, {bytesVal, newCur, ok});
    return success();
  }
};
```

---

## Step 6: Emit Length-Prefixed Operations

### 6.1 Update `EmitBFDecoder.elm`

```elm
{- ✅ CORRECTED C15: ReadLengthPrefixedString/Bytes ops are REMOVED.

Instead of monolithic ops, use the decomposed pattern:
1. Require + read length (e.g., bf.read.u32_be)
2. RequireDyn + read data (e.g., bf.read.dyn_utf8)

This gives proper fail-fast at each step.
-}

emitDecoderOp : DecoderOp -> EmitState -> EmitState
emitDecoderOp op st =
    case op of
        -- ... existing cases ...

        -- ❌ REMOVED: ReadLengthPrefixedString/Bytes
        -- These monolithic ops are replaced by the decomposed sequence:
        --   Require "cur" 4 → BranchOnFail "cur"
        --   ReadU32 "cur" BE "lenVar"
        --   RequireDyn "cur" "lenVar" → BranchOnFail "cur"
        --   ReadDynUtf8 "cur" "lenVar" "resultVar"

        -- Dynamic-length reads (length is already computed)
        ReadDynBytes _curName lenVar resultVarName ->
            emitReadDynOp st lenVar "bf.read.dyn_bytes" resultVarName

        ReadDynUtf8 _curName lenVar resultVarName ->
            emitReadDynOp st lenVar "bf.read.dyn_utf8" resultVarName


{- ⚠️⚠️⚠️ CORRECTION C8: SAME SAFETY ISSUE AS C7

**PROBLEM:** This function uses `okLen`, `okData`, and `arith.andi` to accumulate ok flags.
This has the SAME memory safety issue as C7: the second read (`dynOp`) happens BEFORE
we check if the first read (`lenOp`) succeeded.

**REQUIRED REWRITE:** Use require+branch before EACH read:

```elm
emitLengthPrefixedRead st lenReadOp dynReadOpName =
    -- Step 1: require(byteCount for length field) → branch to fail
    let
        lenBytes = case lenReadOp of
            ReadLenU8 -> 1
            ReadLenU16BE -> 2
            ReadLenU16LE -> 2
            ReadLenU32BE -> 4
            ReadLenU32LE -> 4

        st1 = emitRequire st lenBytes  -- branches to fail if OOB

        -- Step 2: read length (safe - we checked)
        st2 = emitReadLen st1 lenReadOp

        -- Step 3: require(lenValue) → branch to fail
        -- NOTE: lenValue is dynamic! Need bf.require with variable operand
        st3 = emitRequireDynamic st2 st2.lenVar

        -- Step 4: read data (safe - we checked)
        st4 = emitReadDynamic st3 dynReadOpName st2.lenVar
    in
    st4
```

**DELETE the `okLen`, `okData`, `arith.andi` pattern below!**
-}

{-| ⚠️ WARNING: This implementation is MEMORY UNSAFE!
    See CORRECTION C8 above for the required architecture.
-}
emitLengthPrefixedRead : EmitState -> LengthReadOp -> String -> EmitState
emitLengthPrefixedRead st lenReadOp dynReadOpName =
    let
        -- Step 1: Read the length
        ( lenReadOpName, lenType ) =
            case lenReadOp of
                ReadLenU8 -> ( "bf.read.u8", I8 )
                ReadLenU16BE -> ( "bf.read.u16_be", I16 )
                ReadLenU16LE -> ( "bf.read.u16_le", I16 )
                ReadLenU32BE -> ( "bf.read.u32_be", I32 )
                ReadLenU32LE -> ( "bf.read.u32_le", I32 )

        ( lenVar, ctx1 ) = Ctx.freshVar st.ctx
        ( curAfterLen, ctx2 ) = Ctx.freshVar ctx1
        ( okLen, ctx3 ) = Ctx.freshVar ctx2

        ( ctx4, lenOp ) =
            Ops.mlirOp ctx3 lenReadOpName
                |> Ops.opBuilder.withOperands [ st.cursor ]
                |> Ops.opBuilder.withResults
                    [ ( lenVar, lenType )
                    , ( curAfterLen, Types.bfCur )
                    , ( okLen, I1 )
                    ]
                |> Ops.opBuilder.build

        -- Step 2: Extend length to i32 if needed
        ( lenI32, ctx5, extOps ) =
            if lenType == I32 then
                ( lenVar, ctx4, [] )
            else
                let
                    ( extVar, c1 ) = Ctx.freshVar ctx4
                    ( c2, extOp ) =
                        Ops.mlirOp c1 "arith.extui"
                            |> Ops.opBuilder.withOperands [ lenVar ]
                            |> Ops.opBuilder.withResults [ ( extVar, I32 ) ]
                            |> Ops.opBuilder.build
                in
                ( extVar, c2, [ extOp ] )

        -- Step 3: Read dynamic bytes/string using length
        ( resultVar, ctx6 ) = Ctx.freshVar ctx5
        ( newCurVar, ctx7 ) = Ctx.freshVar ctx6
        ( okData, ctx8 ) = Ctx.freshVar ctx7

        ( ctx9, dynOp ) =
            Ops.mlirOp ctx8 dynReadOpName
                |> Ops.opBuilder.withOperands [ curAfterLen, lenI32 ]
                |> Ops.opBuilder.withResults
                    [ ( resultVar, Types.ecoValue )
                    , ( newCurVar, Types.bfCur )
                    , ( okData, I1 )
                    ]
                |> Ops.opBuilder.build

        -- Step 4: Combine ok flags
        ( combinedOk, ctx10 ) = Ctx.freshVar ctx9
        ( ctx11, andOp ) =
            Ops.mlirOp ctx10 "arith.andi"
                |> Ops.opBuilder.withOperands [ okLen, okData ]
                |> Ops.opBuilder.withResults [ ( combinedOk, I1 ) ]
                |> Ops.opBuilder.build

        -- Combine with previous ok if exists
        ( finalOk, ctx12, prevAndOps ) =
            if st.okVar == "" then
                ( combinedOk, ctx11, [] )
            else
                let
                    ( finalVar, c1 ) = Ctx.freshVar ctx11
                    ( c2, op ) =
                        Ops.mlirOp c1 "arith.andi"
                            |> Ops.opBuilder.withOperands [ st.okVar, combinedOk ]
                            |> Ops.opBuilder.withResults [ ( finalVar, I1 ) ]
                            |> Ops.opBuilder.build
                in
                ( finalVar, c2, [ op ] )
    in
    { st
        | ctx = ctx12
        , cursor = newCurVar
        , ops = prevAndOps ++ [ andOp, dynOp ] ++ extOps ++ [ lenOp ] ++ st.ops
        , decodedValues = resultVar :: st.decodedValues
        , okVar = finalOk
    }
```

---

## Step 7: Testing

### 7.1 E2E Tests

Create `test/elm/src/BytesDecodeAndThenTests.elm`:

```elm
module BytesDecodeAndThenTests exposing (..)

import Bytes exposing (Bytes)
import Bytes.Decode as Decode
import Bytes.Encode as Encode


-- Test length-prefixed string (u32 BE length)
testLengthPrefixedString =
    let
        -- Encode: 4-byte length (5) + "hello"
        bytes = Encode.encode (Encode.sequence
            [ Encode.unsignedInt32 Bytes.BE 5
            , Encode.string "hello"
            ])

        decoder =
            Decode.unsignedInt32 Bytes.BE
                |> Decode.andThen (\len -> Decode.string len)

        result = Decode.decode decoder bytes
    in
    -- CHECK: Just "hello"
    Debug.log "testLengthPrefixedString" result


-- Test length-prefixed bytes (u16 LE length)
testLengthPrefixedBytes =
    let
        bytes = Encode.encode (Encode.sequence
            [ Encode.unsignedInt16 Bytes.LE 3
            , Encode.unsignedInt8 0xAA
            , Encode.unsignedInt8 0xBB
            , Encode.unsignedInt8 0xCC
            ])

        decoder =
            Decode.unsignedInt16 Bytes.LE
                |> Decode.andThen (\len -> Decode.bytes len)

        result = Decode.decode decoder bytes
    in
    -- CHECK: Just <3 bytes>
    Debug.log "testLengthPrefixedBytes" result


-- Test length-prefixed with map
testLengthPrefixedWithMap =
    let
        bytes = Encode.encode (Encode.sequence
            [ Encode.unsignedInt32 Bytes.BE 5
            , Encode.string "hello"
            , Encode.unsignedInt8 42
            ])

        decoder =
            Decode.unsignedInt32 Bytes.BE
                |> Decode.andThen (\len ->
                    Decode.map2 Tuple.pair
                        (Decode.string len)
                        Decode.unsignedInt8
                )

        result = Decode.decode decoder bytes
    in
    -- CHECK: Just ("hello", 42)
    Debug.log "testLengthPrefixedWithMap" result


-- Test failure: length exceeds available bytes
testLengthPrefixedFailure =
    let
        -- Only 2 bytes of data, but length says 100
        bytes = Encode.encode (Encode.sequence
            [ Encode.unsignedInt32 Bytes.BE 100
            , Encode.unsignedInt8 0xAA
            , Encode.unsignedInt8 0xBB
            ])

        decoder =
            Decode.unsignedInt32 Bytes.BE
                |> Decode.andThen (\len -> Decode.string len)

        result = Decode.decode decoder bytes
    in
    -- CHECK: Nothing
    Debug.log "testLengthPrefixedFailure" result


-- Test chained andThen
testChainedAndThen =
    let
        bytes = Encode.encode (Encode.sequence
            [ Encode.unsignedInt8 3           -- first length
            , Encode.string "abc"             -- first string
            , Encode.unsignedInt8 2           -- second length
            , Encode.string "xy"              -- second string
            ])

        decoder =
            Decode.unsignedInt8
                |> Decode.andThen (\len1 ->
                    Decode.string len1
                        |> Decode.andThen (\str1 ->
                            Decode.unsignedInt8
                                |> Decode.andThen (\len2 ->
                                    Decode.map (\str2 -> (str1, str2))
                                        (Decode.string len2)
                                )
                        )
                )

        result = Decode.decode decoder bytes
    in
    -- CHECK: Just ("abc", "xy")
    Debug.log "testChainedAndThen" result
```

---

## File Change Summary

### New Files (1)

| File | Description |
|------|-------------|
| `test/elm/src/BytesDecodeAndThenTests.elm` | E2E tests for andThen patterns |

### Modified Files (6)

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/ReifyDecoder.elm` | Add andThen pattern recognition |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/LoopIR.elm` | Add length-prefixed ops |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/CompileDecoder.elm` | Compile length-prefixed patterns |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/EmitBFDecoder.elm` | Emit length-prefixed bf ops |
| `runtime/src/codegen/BF/BFOps.td` | Add `bf.read.dyn_bytes`, `bf.read.dyn_utf8` |
| `runtime/src/codegen/Passes/BFToLLVM.cpp` | Add lowering for dyn ops |

---

## Scope Boundaries

### In Scope (Phase 3)

- Length-prefixed string: `intDecoder |> andThen (\len -> Decode.string len)`
- Length-prefixed bytes: `intDecoder |> andThen (\len -> Decode.bytes len)`
- Chained andThen with length-prefixed patterns
- andThen where body is recursively fuseable

### Out of Scope (Future Phases)

- Case expressions in lambda body (tag-based decoding)
- Arithmetic on length (`len - 4`, `len * 2`)
- External function calls in lambda
- `Decode.loop` patterns

---

## Remaining Questions

### 1. Lambda Closure Analysis

How does `MonoClosure` represent the closure? Need to verify:
- How to extract parameter names
- How to identify free variables vs bound variables

### 2. Negative Length Handling

What happens if a signed integer is used as length and the value is negative?
- Option A: Treat as unsigned (cast)
- Option B: Fail if negative
- **Recommendation:** Option A (matches JS behavior)

### 3. Maximum Length Limit

Should there be a sanity check on length values to prevent OOM?
- e.g., fail if `len > MAX_SAFE_LENGTH`
- **Recommendation:** Defer to Phase 4 or leave to runtime

---

## Assumptions

- **A1:** Phase 2 decoder infrastructure is complete
- **A2:** `MonoClosure` provides access to lambda parameter info
- **A3:** Length values are treated as unsigned for bounds checking
- **A4:** No maximum length enforcement (rely on system memory limits)

---

## Future: Phase 4 (loop)

Phase 4 will add support for `Decode.loop`:

```elm
Decode.loop : (state -> Decoder (Step state a)) -> state -> Decoder a
```

This requires:
- `scf.while` emission for the loop
- Step variant handling (Loop vs Done)
- Accumulator state management
---
---

# Phase 4: loop Support

**Goal:** Recognize and fuse `Decode.loop` patterns for decoding variable-length sequences.

**Prerequisite:** Phase 3 (andThen) must be complete - provides:
- Lambda body analysis infrastructure
- Dynamic length read operations

---

## ⚠️⚠️⚠️ HARD GATE: PHASE 4 IS NON-AUTHORITATIVE ⚠️⚠️⚠️

### CORRECTION C9: Phase 4 = Requirements + Investigation Tasks ONLY

**CRITICAL WARNING:** All code blocks in Phase 4 are **HYPOTHETICAL SKETCHES** intended
as *appendix material* for future reference, NOT implementation-ready code.

**What Phase 4 SHOULD contain:**
- High-level requirements and goals
- Investigation tasks to ground assumptions
- Open questions needing answers before implementation

**What Phase 4 code blocks actually are:**
- Unverified guesses about MonoExpr representation
- Unconfirmed assumptions about `scf.while` API
- Placeholder patterns that may be completely wrong

---

**BEFORE IMPLEMENTING PHASE 4, you MUST:**

1. **Complete Phases 1-3 end-to-end** - proven working, tested
2. **Ground every assumption:**
   - How is `\( n, acc ) -> ...` represented in MonoExpr?
   - What are the SpecIds for `Loop` and `Done` constructors?
   - Does `Ops.elm` support `scf.while` with condition+body regions?
   - Does `Ops.elm` support `scf.if` for structured conditionals?
3. **Rewrite Phase 4 from scratch** based on grounded information

**TREAT ALL CODE BLOCKS BELOW AS:**
```
┌─────────────────────────────────────────────────────────────┐
│  APPENDIX: HYPOTHETICAL CODE - TO BE VERIFIED AND REWRITTEN │
└─────────────────────────────────────────────────────────────┘
```

---

## ⚠️ GROUNDING REQUIREMENTS

Phase 4 is **speculative** - it includes many `Nothing  -- TODO` placeholders and assumes specific MonoExpr shapes without verification.

**Before implementation, you MUST ground:**

1. **Tuple destructuring in Mono** - How is `\( n, acc ) -> ...` represented?
   - Is it pattern matching in the lambda params?
   - Or `\state -> let (n, acc) = state in ...`?

2. **Step type representation** - How do `Loop` and `Done` constructors appear in MonoExpr?
   - Need to identify their SpecIds for pattern matching

3. **scf.while support in Ops.elm** - Does it exist?
   - `Ops.elm` has `arithCmpI` for predicates, but likely lacks `scf.while` with regions
   - If not, you must implement region-capable builders first:
     ```elm
     scfWhile : Context -> ... -> (Context, MlirOp)
     -- Must support condition region + body region with yields
     ```

4. **scf.if support in Ops.elm** - Same question for structured conditionals

**Recommendation:** Before writing loop fusion, add/confirm `scf.if` and `scf.while` support in `Ops.elm`.
---
---


**Design Document:** `/work/design_docs/fused-bytes-compilation.md`

---

## Understanding Decode.loop

### Signature

```elm
loop : (state -> Decoder (Step state a)) -> state -> Decoder a
```

### Step Type

```elm
type Step state a
    = Loop state  -- Continue with new state
    | Done a      -- Finished with result
```

### Semantics

1. Start with `initialState`
2. Run `stepDecoder initialState` to get `Step state a`
3. If `Loop newState`: go to step 2 with `newState`
4. If `Done result`: return `result`

### Common Use Cases

**1. Count-prefixed list:**
```elm
-- Decode N items where N is read first
decodeList : Decoder (List Int)
decodeList =
    Decode.unsignedInt32 Bytes.BE
        |> Decode.andThen (\count ->
            Decode.loop ( count, [] ) listStep
        )

listStep : ( Int, List Int ) -> Decoder (Step ( Int, List Int ) (List Int))
listStep ( remaining, acc ) =
    if remaining <= 0 then
        Decode.succeed (Done (List.reverse acc))
    else
        Decode.map (\item -> Loop ( remaining - 1, item :: acc ))
            Decode.unsignedInt32 Bytes.BE
```

**2. Sentinel-terminated list:**
```elm
-- Decode until sentinel value (e.g., 0)
decodeNullTerminated : Decoder (List Int)
decodeNullTerminated =
    Decode.loop [] nullTermStep

nullTermStep : List Int -> Decoder (Step (List Int) (List Int))
nullTermStep acc =
    Decode.unsignedInt8
        |> Decode.andThen (\byte ->
            if byte == 0 then
                Decode.succeed (Done (List.reverse acc))
            else
                Decode.succeed (Loop (byte :: acc))
        )
```

**3. Length-prefixed with nested structure:**
```elm
-- Decode items until all bytes consumed
decodeUntilEnd : Int -> Decoder (List Item)
decodeUntilEnd totalBytes =
    Decode.loop ( totalBytes, [] ) byteBoundedStep
```

---

## Fuseable Loop Patterns

### Pattern 1: Count-Based Loop (Most Common)

```elm
Decode.loop ( count, [] ) (\( n, acc ) ->
    if n <= 0 then
        Decode.succeed (Done (List.reverse acc))
    else
        Decode.map (\item -> Loop ( n - 1, item :: acc )) itemDecoder
)
```

**Structure:**
- State is `( Int, List a )` - counter and accumulator
- Condition: `counter <= 0`
- Body: decode item, decrement counter, cons to accumulator
- Final: reverse accumulator

**Fused form:**
```
1. Initialize: counter = count, acc = []
2. while (counter > 0):
   a. Read item
   b. counter--
   c. acc = item :: acc
3. Return List.reverse acc
```

### Pattern 2: Sentinel-Terminated

```elm
Decode.loop [] (\acc ->
    Decode.unsignedInt8
        |> Decode.andThen (\byte ->
            if byte == 0 then
                Decode.succeed (Done (List.reverse acc))
            else
                Decode.succeed (Loop (byte :: acc))
        )
)
```

**Structure:**
- State is `List a` - accumulator only
- Read value first, then check sentinel
- Condition: read value == sentinel

**Fused form:**
```
1. Initialize: acc = []
2. while true:
   a. Read byte
   b. if byte == 0: break
   c. acc = byte :: acc
3. Return List.reverse acc
```

### Pattern 3: Fixed-Count Without State Tuple

```elm
-- Using andThen to set up count
Decode.unsignedInt32 Bytes.BE
    |> Decode.andThen (\count ->
        Decode.loop count (\n ->
            if n <= 0 then
                Decode.succeed (Done [])  -- Base case builds from here
            else
                Decode.map2 (\item rest -> Loop (n - 1))
                    itemDecoder
                    ...  -- This pattern is harder to fuse
        )
    )
```

---

## Non-Fuseable Loop Patterns

### Complex State Transformations

```elm
-- State depends on decoded value in complex way
Decode.loop initialState (\state ->
    itemDecoder
        |> Decode.andThen (\item ->
            let
                newState = complexTransform state item
            in
            if shouldStop newState then
                Decode.succeed (Done (extractResult newState))
            else
                Decode.succeed (Loop newState)
        )
)
```

### Multiple Exit Conditions

```elm
-- Different Done values based on conditions
Decode.loop state (\s ->
    decoder
        |> Decode.andThen (\v ->
            if condition1 v then Decode.succeed (Done result1)
            else if condition2 v then Decode.succeed (Done result2)
            else Decode.succeed (Loop newState)
        )
)
```

---

## Implementation Strategy

### MLIR Loop Construct: `scf.while`

```mlir
%result = scf.while (%state = %init) : (StateType) -> ResultType {
    // Condition block - returns i1
    %cond = ... compute condition ...
    scf.condition(%cond) %state : StateType
} do {
^bb0(%state: StateType):
    // Body block - returns new state
    %newState = ... loop body ...
    scf.yield %newState : StateType
}
```

### State Representation

For count-based loops with accumulator:
- Counter: `i32`
- Accumulator: `eco.value` (Elm List)

MLIR state tuple: `!llvm.struct<(i32, !eco.value)>`

---

## Step 1: Extend DecoderNode for loop

### 1.1 Update `ReifyDecoder.elm`

```elm
type DecoderNode
    = -- ... existing constructors ...

    -- NEW: Loop patterns
    | DCountLoop
        { countSource : CountSource      -- Where count comes from
        , itemDecoder : DecoderNode      -- How to decode each item
        , itemType : Mono.MonoType       -- Type of list items
        }
    | DSentinelLoop
        { sentinel : Int                 -- Value that terminates loop
        , itemDecoder : DecoderNode      -- Decoder for items (must produce Int)
        }
    | DGeneralLoop
        { initialState : Mono.MonoExpr
        , stepDecoder : LoopStepDecoder
        }


{-| Where the loop count comes from.
-}
type CountSource
    = CountFromPreviousRead String       -- Variable name from earlier decode
    | CountLiteral Int                   -- Fixed count
    | CountFromExpr Mono.MonoExpr        -- Expression to evaluate


{-| Analyzed step function for general loops.
-}
type alias LoopStepDecoder =
    { statePattern : StatePattern
    , condition : LoopCondition
    , bodyDecoder : DecoderNode
    , doneExpr : Mono.MonoExpr
    }


type StatePattern
    = CounterAccPair String String       -- ( counter, acc ) pattern
    | AccOnly String                     -- Just accumulator


type LoopCondition
    = CounterZero String                 -- counter <= 0
    | SentinelValue Int                  -- read value == sentinel
    | CustomCondition Mono.MonoExpr      -- Not fuseable, fall back
```

### 1.2 Add Loop Pattern Recognition

```elm
reifyBytesDecodeCall : Mono.MonoRegistry -> String -> List Mono.MonoExpr -> Maybe DecoderNode
reifyBytesDecodeCall registry name args =
    case ( name, args ) of
        -- ... existing cases ...

        ( "loop", [ stepFnExpr, initialStateExpr ] ) ->
            reifyLoop registry stepFnExpr initialStateExpr

        _ ->
            Nothing


{-| Try to reify a loop expression.
-}
reifyLoop : Mono.MonoRegistry -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe DecoderNode
reifyLoop registry stepFnExpr initialStateExpr =
    case stepFnExpr of
        Mono.MonoClosure closureInfo bodyExpr _ ->
            analyzeLoopStep registry closureInfo bodyExpr initialStateExpr

        _ ->
            Nothing


{-| Analyze the step function to identify fuseable patterns.
-}
analyzeLoopStep :
    Mono.MonoRegistry
    -> Mono.ClosureInfo
    -> Mono.MonoExpr
    -> Mono.MonoExpr
    -> Maybe DecoderNode
analyzeLoopStep registry closureInfo bodyExpr initialStateExpr =
    let
        -- Get state parameter name and pattern
        stateParam =
            case closureInfo.params of
                [ ( name, _ ) ] -> Just name
                _ -> Nothing
    in
    case stateParam of
        Nothing ->
            Nothing

        Just paramName ->
            -- Try to match count-based loop pattern
            case matchCountLoopPattern registry paramName bodyExpr initialStateExpr of
                Just countLoop ->
                    Just countLoop

                Nothing ->
                    -- Try sentinel pattern
                    case matchSentinelLoopPattern registry paramName bodyExpr of
                        Just sentinelLoop ->
                            Just sentinelLoop

                        Nothing ->
                            -- Can't fuse this loop
                            Nothing


{-| Match count-based loop pattern:
    \( n, acc ) ->
        if n <= 0 then
            Decode.succeed (Done (List.reverse acc))
        else
            Decode.map (\item -> Loop ( n - 1, item :: acc )) itemDecoder
-}
matchCountLoopPattern :
    Mono.MonoRegistry
    -> String
    -> Mono.MonoExpr
    -> Mono.MonoExpr
    -> Maybe DecoderNode
matchCountLoopPattern registry paramName bodyExpr initialStateExpr =
    -- This requires deep pattern matching on the AST
    -- Looking for:
    -- 1. If expression with counter comparison
    -- 2. Done branch with List.reverse
    -- 3. Loop branch with counter decrement and cons

    case bodyExpr of
        Mono.MonoIf branches elseExpr _ ->
            case branches of
                [ ( condExpr, thenExpr ) ] ->
                    -- Check if condition is "counter <= 0"
                    case analyzeCounterCondition paramName condExpr of
                        Just counterName ->
                            -- Check if thenExpr is Done (List.reverse acc)
                            case analyzeDoneBranch registry thenExpr of
                                Just accName ->
                                    -- Check if elseExpr is Loop with decrement
                                    case analyzeLoopBranch registry counterName accName elseExpr of
                                        Just itemDecoder ->
                                            -- Extract count from initial state
                                            case analyzeInitialState initialStateExpr of
                                                Just countSource ->
                                                    Just (DCountLoop
                                                        { countSource = countSource
                                                        , itemDecoder = itemDecoder
                                                        , itemType = Mono.monoTypeOf itemDecoder
                                                        })

                                                Nothing ->
                                                    Nothing

                                        Nothing ->
                                            Nothing

                                Nothing ->
                                    Nothing

                        Nothing ->
                            Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Analyze counter comparison: n <= 0 or n == 0
-}
analyzeCounterCondition : String -> Mono.MonoExpr -> Maybe String
analyzeCounterCondition paramName condExpr =
    -- Look for:
    -- MonoCall to (<=) or (==) with counter variable and 0
    -- This is simplified - real impl needs to handle tuple destructuring
    Nothing  -- TODO: Implement


{-| Analyze Done branch: Decode.succeed (Done (List.reverse acc))
-}
analyzeDoneBranch : Mono.MonoRegistry -> Mono.MonoExpr -> Maybe String
analyzeDoneBranch registry expr =
    -- Look for:
    -- MonoCall Decode.succeed [ MonoCall Done [ MonoCall List.reverse [ accVar ] ] ]
    Nothing  -- TODO: Implement


{-| Analyze Loop branch with counter decrement and cons.
-}
analyzeLoopBranch : Mono.MonoRegistry -> String -> String -> Mono.MonoExpr -> Maybe DecoderNode
analyzeLoopBranch registry counterName accName expr =
    -- Look for:
    -- Decode.map (\item -> Loop ( counter - 1, item :: acc )) itemDecoder
    Nothing  -- TODO: Implement


{-| Extract count from initial state expression.
-}
analyzeInitialState : Mono.MonoExpr -> Maybe CountSource
analyzeInitialState expr =
    case expr of
        Mono.MonoTupleCreate _ [ countExpr, _ ] _ _ ->
            case countExpr of
                Mono.MonoLiteral (Mono.LInt n) _ ->
                    Just (CountLiteral n)

                Mono.MonoVarLocal name _ ->
                    Just (CountFromPreviousRead name)

                _ ->
                    Just (CountFromExpr countExpr)

        _ ->
            Nothing
```

---

## Step 2: Extend Loop IR

### 2.1 Update `LoopIR.elm`

```elm
type DecoderOp
    = -- ... existing ops ...

    -- NEW: Loop operations
    | BeginCountLoop
        { countVar : String              -- SSA var holding count
        , accVar : String                -- SSA var for accumulator (starts as [])
        , loopLabel : String             -- Label for loop block
        }
    | LoopReadItem
        { itemDecoder : List DecoderOp   -- Ops to decode one item
        , itemVar : String               -- SSA var for decoded item
        }
    | LoopCons
        { itemVar : String
        , accVar : String
        , newAccVar : String
        }
    | LoopDecrement
        { countVar : String
        , newCountVar : String
        }
    | EndCountLoop
        { countVar : String              -- Check this for zero
        , accVar : String                -- Final accumulator
        , resultVar : String             -- After List.reverse
        }

    -- Sentinel loop ops
    | BeginSentinelLoop
        { accVar : String
        , loopLabel : String
        }
    | LoopReadAndCheckSentinel
        { sentinel : Int
        , valueVar : String
        , shouldContinueVar : String     -- i1: true if not sentinel
        }
    | EndSentinelLoop
        { accVar : String
        , resultVar : String
        }
```

---

## Step 3: Extend Compiler

### 3.1 Update `CompileDecoder.elm`

```elm
compileNode : DecoderNode -> CompileState -> CompileState
compileNode node st =
    case node of
        -- ... existing cases ...

        DCountLoop { countSource, itemDecoder, itemType } ->
            compileCountLoop st countSource itemDecoder

        DSentinelLoop { sentinel, itemDecoder } ->
            compileSentinelLoop st sentinel itemDecoder

        DGeneralLoop _ ->
            -- Cannot fuse general loops
            st


compileCountLoop : CompileState -> CountSource -> DecoderNode -> CompileState
compileCountLoop st countSource itemDecoder =
    let
        ( countVar, st1 ) = freshVar st
        ( accVar, st2 ) = freshVar st1
        ( loopLabel, st3 ) = freshLabel st2

        -- Emit count source
        countOps =
            case countSource of
                CountLiteral n ->
                    []  -- Count already in SSA from literal

                CountFromPreviousRead name ->
                    []  -- Count already decoded, reference by name

                CountFromExpr _ ->
                    []  -- Would need to emit expression - simplified here

        -- Compile item decoder to get its ops
        itemSt = compileNode itemDecoder { st3 | ops = [], decodedVars = [] }
        itemOps = List.reverse itemSt.ops
        ( itemVar, st4 ) =
            case itemSt.decodedVars of
                v :: _ -> ( v, itemSt )
                [] -> freshVar itemSt

        ( newAccVar, st5 ) = freshVar st4
        ( newCountVar, st6 ) = freshVar st5
        ( resultVar, st7 ) = freshVar st6

        loopOps =
            [ BeginCountLoop
                { countVar = countVar
                , accVar = accVar
                , loopLabel = loopLabel
                }
            , LoopReadItem
                { itemDecoder = itemOps
                , itemVar = itemVar
                }
            , LoopCons
                { itemVar = itemVar
                , accVar = accVar
                , newAccVar = newAccVar
                }
            , LoopDecrement
                { countVar = countVar
                , newCountVar = newCountVar
                }
            , EndCountLoop
                { countVar = newCountVar
                , accVar = newAccVar
                , resultVar = resultVar
                }
            ]
    in
    { st7
        | ops = loopOps ++ st.ops
        , decodedVars = resultVar :: st7.decodedVars
    }
```

---

## Step 4: Emit scf.while

### 4.1 Update `EmitBFDecoder.elm`

```elm
emitDecoderOp : DecoderOp -> EmitState -> EmitState
emitDecoderOp op st =
    case op of
        -- ... existing cases ...

        BeginCountLoop { countVar, accVar, loopLabel } ->
            emitCountLoopBegin st countVar accVar

        LoopReadItem { itemDecoder, itemVar } ->
            -- Item decoder ops are emitted inline in the loop body
            st

        EndCountLoop { countVar, accVar, resultVar } ->
            emitCountLoopEnd st countVar accVar resultVar

        _ ->
            st


{-| Emit a count-based loop using scf.while.

    %result = scf.while (%count = %initCount, %acc = %initAcc)
        : (i32, !eco.value) -> !eco.value {
        // Condition: count > 0
        %zero = arith.constant 0 : i32
        %cond = arith.cmpi sgt, %count, %zero : i32
        scf.condition(%cond) %count, %acc : i32, !eco.value
    } do {
    ^bb0(%count: i32, %acc: !eco.value):
        // Body: read item, cons, decrement
        %item, %newCur, %ok = bf.read.u32_be(%cur)
        %newAcc = eco.cons(%item, %acc)
        %one = arith.constant 1 : i32
        %newCount = arith.subi %count, %one : i32
        scf.yield %newCount, %newAcc : i32, !eco.value
    }
    // After loop: reverse the list
    %final = call @elm_list_reverse(%result)
-}
emitCountLoop :
    EmitState
    -> String                    -- countVar (initial count)
    -> List DecoderOp            -- itemOps
    -> String                    -- resultVar
    -> EmitState
emitCountLoop st countVar itemOps resultVar =
    let
        -- Create initial accumulator (empty list)
        ( emptyListVar, ctx1 ) = Ctx.freshVar st.ctx
        ( ctx2, emptyListOp ) =
            Ops.ecoCallNamed ctx1 emptyListVar "elm_list_nil" [] Types.ecoValue

        -- State type: (i32, eco.value) for (count, acc)
        stateType = NamedStruct "loop_state"

        -- Build initial state
        ( initStateVar, ctx3 ) = Ctx.freshVar ctx2
        ( ctx4, initStateOp ) = buildLoopState ctx3 initStateVar countVar emptyListVar

        -- scf.while
        ( loopResultVar, ctx5 ) = Ctx.freshVar ctx4
        ( whileOp, ctx6 ) =
            emitScfWhile ctx5
                { initState = initStateVar
                , stateType = stateType
                , resultVar = loopResultVar
                , conditionBlock = emitCountLoopCondition
                , bodyBlock = emitCountLoopBody st.cursor itemOps
                }

        -- Extract accumulator from result and reverse
        ( accFromResult, ctx7 ) = Ctx.freshVar ctx6
        ( ctx8, extractOp ) = extractLoopAcc ctx7 accFromResult loopResultVar

        ( finalListVar, ctx9 ) = Ctx.freshVar ctx8
        ( ctx10, reverseOp ) =
            Ops.ecoCallNamed ctx9 finalListVar "elm_list_reverse"
                [ ( accFromResult, Types.ecoValue ) ]
                Types.ecoValue
    in
    { st
        | ctx = ctx10
        , ops = [ reverseOp, extractOp, whileOp, initStateOp, emptyListOp ] ++ st.ops
        , decodedValues = finalListVar :: st.decodedValues
    }


{-| Emit scf.while condition block: count > 0
-}
emitCountLoopCondition : Context -> ( Context, List MlirOp, String )
emitCountLoopCondition ctx =
    let
        ( zeroVar, ctx1 ) = Ctx.freshVar ctx
        ( ctx2, zeroOp ) = Ops.arithConstantInt32 ctx1 zeroVar 0

        ( condVar, ctx3 ) = Ctx.freshVar ctx2
        ( ctx4, cmpOp ) =
            Ops.mlirOp ctx3 "arith.cmpi"
                |> Ops.opBuilder.withAttr "predicate" (IntAttr 4)  -- sgt
                |> Ops.opBuilder.withOperands [ "%count", zeroVar ]
                |> Ops.opBuilder.withResults [ ( condVar, I1 ) ]
                |> Ops.opBuilder.build

        ( ctx5, condOp ) =
            Ops.mlirOp ctx4 "scf.condition"
                |> Ops.opBuilder.withOperands [ condVar, "%count", "%acc" ]
                |> Ops.opBuilder.build
    in
    ( ctx5, [ zeroOp, cmpOp, condOp ], condVar )


{-| Emit scf.while body block: read item, cons, decrement
-}
emitCountLoopBody : String -> List DecoderOp -> Context -> ( Context, List MlirOp )
emitCountLoopBody cursorVar itemOps ctx =
    -- This is complex - would need to:
    -- 1. Emit item decoder ops
    -- 2. Emit cons operation
    -- 3. Emit counter decrement
    -- 4. Emit scf.yield with new state
    ( ctx, [] )  -- Placeholder
```

---

## Step 5: Runtime Support

### 5.1 Add to `ElmBytesRuntime.h`

```c
// ✅ CORRECTED C19: List operations use u64 (eco.value), not void*
// List operations for loop support
u64 elm_list_nil(void);
u64 elm_list_cons(u64 head, u64 tail);
u64 elm_list_reverse(u64 list);
```

### 5.2 Implement in `ElmBytesRuntime.cpp`

```cpp
// ✅ CORRECTED C19: All list helpers use u64 ABI

extern "C" {

u64 elm_list_nil(void) {
    // Return empty list (Nil constructor) as eco.value
    return toEcoValue(List::nil());
}

u64 elm_list_cons(u64 headVal, u64 tailVal) {
    // Allocate Cons cell, convert eco.values to internal pointers
    // Cons { head: head, tail: tail }
    return toEcoValue(List::cons(headVal, tailVal));
}

u64 elm_list_reverse(u64 listVal) {
    // Reverse list - reuse existing ListOps implementation
    void* list = reinterpret_cast<void*>(static_cast<uintptr_t>(listVal));
    return toEcoValue(ListOps::reverse(list));
}

} // extern "C"
```

### 5.3 Register Symbols

```cpp
symbolMap[interner("elm_list_nil")] =
    llvm::orc::ExecutorSymbolDef(
        llvm::orc::ExecutorAddr::fromPtr(&elm_list_nil),
        llvm::JITSymbolFlags::Exported);
symbolMap[interner("elm_list_cons")] =
    llvm::orc::ExecutorSymbolDef(
        llvm::orc::ExecutorAddr::fromPtr(&elm_list_cons),
        llvm::JITSymbolFlags::Exported);
symbolMap[interner("elm_list_reverse")] =
    llvm::orc::ExecutorSymbolDef(
        llvm::orc::ExecutorAddr::fromPtr(&elm_list_reverse),
        llvm::JITSymbolFlags::Exported);
```

---

## Step 6: Testing

### 6.1 E2E Tests

Create `test/elm/src/BytesDecodeLoopTests.elm`:

```elm
module BytesDecodeLoopTests exposing (..)

import Bytes exposing (Bytes)
import Bytes.Decode as Decode exposing (Decoder, Step(..))
import Bytes.Encode as Encode


-- Test count-prefixed list of u8
testCountPrefixedU8List =
    let
        bytes = Encode.encode (Encode.sequence
            [ Encode.unsignedInt32 Bytes.BE 3  -- count
            , Encode.unsignedInt8 10
            , Encode.unsignedInt8 20
            , Encode.unsignedInt8 30
            ])

        decoder =
            Decode.unsignedInt32 Bytes.BE
                |> Decode.andThen (\count ->
                    Decode.loop ( count, [] ) listStep
                )

        listStep ( remaining, acc ) =
            if remaining <= 0 then
                Decode.succeed (Done (List.reverse acc))
            else
                Decode.map (\item -> Loop ( remaining - 1, item :: acc ))
                    Decode.unsignedInt8

        result = Decode.decode decoder bytes
    in
    -- CHECK: Just [10, 20, 30]
    Debug.log "testCountPrefixedU8List" result


-- Test count-prefixed list of u32
testCountPrefixedU32List =
    let
        bytes = Encode.encode (Encode.sequence
            [ Encode.unsignedInt16 Bytes.LE 2  -- count
            , Encode.unsignedInt32 Bytes.BE 0x12345678
            , Encode.unsignedInt32 Bytes.BE 0xDEADBEEF
            ])

        decoder =
            Decode.unsignedInt16 Bytes.LE
                |> Decode.andThen (\count ->
                    Decode.loop ( count, [] ) listStep
                )

        listStep ( remaining, acc ) =
            if remaining <= 0 then
                Decode.succeed (Done (List.reverse acc))
            else
                Decode.map (\item -> Loop ( remaining - 1, item :: acc ))
                    (Decode.unsignedInt32 Bytes.BE)

        result = Decode.decode decoder bytes
    in
    -- CHECK: Just [305419896, 3735928559]
    Debug.log "testCountPrefixedU32List" result


-- Test empty list
testEmptyList =
    let
        bytes = Encode.encode (Encode.unsignedInt32 Bytes.BE 0)  -- count = 0

        decoder =
            Decode.unsignedInt32 Bytes.BE
                |> Decode.andThen (\count ->
                    Decode.loop ( count, [] ) listStep
                )

        listStep ( remaining, acc ) =
            if remaining <= 0 then
                Decode.succeed (Done (List.reverse acc))
            else
                Decode.map (\item -> Loop ( remaining - 1, item :: acc ))
                    Decode.unsignedInt8

        result = Decode.decode decoder bytes
    in
    -- CHECK: Just []
    Debug.log "testEmptyList" result


-- Test failure: not enough bytes for all items
testLoopFailure =
    let
        bytes = Encode.encode (Encode.sequence
            [ Encode.unsignedInt32 Bytes.BE 10  -- count = 10
            , Encode.unsignedInt8 1             -- only 1 item
            ])

        decoder =
            Decode.unsignedInt32 Bytes.BE
                |> Decode.andThen (\count ->
                    Decode.loop ( count, [] ) listStep
                )

        listStep ( remaining, acc ) =
            if remaining <= 0 then
                Decode.succeed (Done (List.reverse acc))
            else
                Decode.map (\item -> Loop ( remaining - 1, item :: acc ))
                    Decode.unsignedInt8

        result = Decode.decode decoder bytes
    in
    -- CHECK: Nothing
    Debug.log "testLoopFailure" result


-- Test nested structures in list
testListOfPairs =
    let
        bytes = Encode.encode (Encode.sequence
            [ Encode.unsignedInt8 2  -- count
            , Encode.unsignedInt8 1
            , Encode.unsignedInt8 2
            , Encode.unsignedInt8 3
            , Encode.unsignedInt8 4
            ])

        pairDecoder =
            Decode.map2 Tuple.pair
                Decode.unsignedInt8
                Decode.unsignedInt8

        decoder =
            Decode.unsignedInt8
                |> Decode.andThen (\count ->
                    Decode.loop ( count, [] ) (\( remaining, acc ) ->
                        if remaining <= 0 then
                            Decode.succeed (Done (List.reverse acc))
                        else
                            Decode.map (\pair -> Loop ( remaining - 1, pair :: acc ))
                                pairDecoder
                    )
                )

        result = Decode.decode decoder bytes
    in
    -- CHECK: Just [(1, 2), (3, 4)]
    Debug.log "testListOfPairs" result
```

---

## File Change Summary

### New Files (1)

| File | Description |
|------|-------------|
| `test/elm/src/BytesDecodeLoopTests.elm` | E2E tests for loop patterns |

### Modified Files (6)

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/ReifyDecoder.elm` | Add loop pattern recognition |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/LoopIR.elm` | Add loop ops |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/CompileDecoder.elm` | Compile loop patterns |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/EmitBFDecoder.elm` | Emit scf.while |
| `runtime/src/allocator/ElmBytesRuntime.h` | Add list ops |
| `runtime/src/allocator/ElmBytesRuntime.cpp` | Implement list ops |
| `runtime/src/codegen/RuntimeSymbols.cpp` | Register list symbols |

---

## Complexity Assessment

### High Complexity Areas

1. **Lambda Pattern Matching** - Analyzing the step function AST to identify count-based patterns is intricate. Requires matching:
   - If expression structure
   - Counter comparison
   - Done/Loop constructors
   - List.reverse in done branch
   - Counter decrement in loop branch

2. **scf.while Emission** - MLIR's structured control flow requires careful handling of:
   - Block arguments
   - Yield semantics
   - State threading

3. **Cursor Threading in Loop** - The cursor must be properly threaded through loop iterations.

### Simplification Options

**Option A: Only support explicit helper functions**

Instead of pattern-matching arbitrary lambdas, require users to use a specific helper:

```elm
-- Compiler recognizes this specific pattern
Decode.countPrefixedList : Decoder Int -> Decoder a -> Decoder (List a)
```

**Option B: Start with fixed patterns only**

Phase 4a: Only support the exact count-loop idiom shown above.
Phase 4b: Generalize to other patterns.

**Recommendation:** Start with Option B - implement the most common count-loop pattern first.

---

## Remaining Questions

### 1. List Representation

How are lists represented at runtime?
- Need `elm_list_nil`, `elm_list_cons`, `elm_list_reverse` implementations

### 2. scf.while in Ops.elm

Does the existing `Ops.elm` support emitting `scf.while` with condition/body blocks?
If not, significant work needed.

### 3. Step Type Pattern Matching

How is `Step state a` (Loop/Done) represented in MonoExpr?
- Need to identify Loop/Done constructors

### 4. State Tuple Destructuring

How does the compiler represent tuple destructuring in lambda parameters?
- `\( n, acc ) -> ...` vs `\state -> let (n, acc) = state in ...`

---

## Assumptions

- **A1:** Phase 3 andThen is complete
- **A2:** scf.while can be emitted (may need to add support)
- **A3:** List operations available from existing runtime
- **A4:** Step type uses standard ADT representation

---

## Future Enhancements

### Sentinel-Terminated Loops

Add support for patterns that read until a sentinel value:

```elm
Decode.loop [] (\acc ->
    Decode.unsignedInt8
        |> Decode.andThen (\b ->
            if b == 0 then Done (List.reverse acc)
            else Loop (b :: acc)
        )
)
```

### Nested Loops

Support loops within loops for multi-dimensional data.

### Loop Unrolling

For small fixed counts, unroll the loop entirely.

---
---

---
---

# Combined File Summary

This section consolidates all file changes across all four phases.

## All New Files (19 total)

### Runtime Files (12)

| File | Phase | Description |
|------|-------|-------------|
| `runtime/src/allocator/ElmBytesRuntime.h` | 1 | C-ABI header for ByteBuffer and UTF-8 |
| `runtime/src/allocator/ElmBytesRuntime.cpp` | 1 | C-ABI impl + UTF-8 conversion |
| `runtime/src/codegen/BF/BFDialect.td` | 1 | bf dialect TableGen definition |
| `runtime/src/codegen/BF/BFOps.td` | 1 | bf ops TableGen definition |
| `runtime/src/codegen/BF/BFDialect.h` | 1 | bf dialect C++ header |
| `runtime/src/codegen/BF/BFDialect.cpp` | 1 | bf dialect C++ impl |
| `runtime/src/codegen/BF/BFOps.h` | 1 | bf ops C++ header |
| `runtime/src/codegen/BF/BFOps.cpp` | 1 | bf ops C++ impl |
| `runtime/src/codegen/BF/BFTypes.h` | 1 | bf types C++ header |
| `runtime/src/codegen/BF/BFTypes.cpp` | 1 | bf types C++ impl |
| `runtime/src/codegen/Passes/BFToLLVM.cpp` | 1 | bf → LLVM lowering pass |
| `runtime/src/allocator/BytesOps.cpp` | 1 | Additional byte operations |

### Compiler Files (7)

| File | Phase | Description |
|------|-------|-------------|
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/LoopIR.elm` | 1 | Loop IR types for encoder/decoder |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/Reify.elm` | 1 | Encoder AST recognizer |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/Compile.elm` | 1 | Encoder → Loop IR compiler |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/EmitBF.elm` | 1 | Encoder Loop IR → bf MLIR emitter |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/ReifyDecoder.elm` | 2 | Decoder AST recognizer |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/CompileDecoder.elm` | 2 | Decoder → Loop IR compiler |
| `compiler/src/Compiler/Generate/MLIR/BytesFusion/EmitBFDecoder.elm` | 2 | Decoder Loop IR → bf MLIR emitter |

### Test Files (4)

| File | Phase | Description |
|------|-------|-------------|
| `test/elm/src/BytesEncodeTests.elm` | 1 | E2E encoder tests |
| `test/elm/src/BytesDecodeTests.elm` | 2 | E2E decoder tests |
| `test/elm/src/BytesDecodeAndThenTests.elm` | 3 | E2E andThen tests |
| `test/elm/src/BytesDecodeLoopTests.elm` | 4 | E2E loop tests |

## All Modified Files (7 total)

| File | Phases | Changes |
|------|--------|---------|
| `runtime/src/codegen/CMakeLists.txt` | 1 | Add bf TableGen targets + source files |
| `runtime/src/codegen/RuntimeSymbols.cpp` | 1,2,4 | Register elm_* symbols (bytebuffer, utf8, maybe, list) |
| `runtime/src/codegen/Passes.h` | 1 | Declare `createBFToLLVMPass()` |
| `runtime/src/codegen/EcoPipeline.cpp` | 1 | Load bf dialect, add BFToLLVM pass to pipeline |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | 1,2 | Intercept `Bytes.Encode.encode` and `Bytes.Decode.decode` |
| `runtime/src/codegen/BF/BFOps.td` | 2,3 | Add read ops (Phase 2), dyn_bytes/dyn_utf8 (Phase 3) |
| `runtime/src/codegen/Passes/BFToLLVM.cpp` | 2,3,4 | Add read lowering patterns |

## Runtime Symbols Registered (All Phases)

### Phase 1 (Encoder)
- `elm_alloc_bytebuffer`
- `elm_bytebuffer_len`
- `elm_bytebuffer_data`
- `elm_utf8_width`
- `elm_utf8_copy`

### Phase 2 (Decoder)
- `elm_utf8_decode`
- `elm_maybe_nothing`
- `elm_maybe_just`

### Phase 4 (Loop)
- `elm_list_nil`
- `elm_list_cons`
- `elm_list_reverse`

## bf Dialect Operations (All Phases)

**✅ CORRECTED C25: Updated to reflect current API surface**

### Types
- `!bf.cur` - Cursor type (ptr, end) pair, lowered to `{i8*, i8*}`
- `!bf.status` - i1 ok/fail flag (returned by `bf.require` only)
- `!eco.value` - Elm heap value (lowered to i64)

### Phase 1 Operations (Write)
- `bf.alloc(size) -> !eco.value` - Allocate ByteBuffer
- `bf.cursor.init(bb) -> !bf.cur` - Create cursor from ByteBuffer
- `bf.write.u8(cur, val) -> !bf.cur`
- `bf.write.u16_be/le(cur, val) -> !bf.cur`
- `bf.write.u32_be/le(cur, val) -> !bf.cur`
- `bf.write.f32_be/le(cur, val) -> !bf.cur`
- `bf.write.f64_be/le(cur, val) -> !bf.cur`
- `bf.write.bytes_copy(cur, bytes) -> !bf.cur`
- `bf.write.utf8(cur, string) -> !bf.cur`

### Phase 2 Operations (Read)

**Bounds check (returns ok):**
- `bf.require(cur, n) -> !bf.status` - Check n bytes available

**Primitive reads (NO ok - caller must require+branch first):**
- `bf.read.u8(cur) -> (i8, !bf.cur)` - ✅ C12/C21 corrected
- `bf.read.u16_be/le(cur) -> (i16, !bf.cur)`
- `bf.read.u32_be/le(cur) -> (i32, !bf.cur)`
- `bf.read.f32_be/le(cur) -> (f32, !bf.cur)`
- `bf.read.f64_be/le(cur) -> (f64, !bf.cur)`

**Heap reads (may fail for reasons other than bounds):**
- `bf.read.bytes(cur, len) -> (!eco.value, !bf.cur, !bf.status)`
- `bf.read.utf8(cur, len) -> (!eco.value, !bf.cur, !bf.status)`

### Phase 3 Operations (Dynamic Length)
- `bf.read.dyn_bytes(cur, lenVar) -> (!eco.value, !bf.cur, !bf.status)`
- `bf.read.dyn_utf8(cur, lenVar) -> (!eco.value, !bf.cur, !bf.status)`

**❌ REMOVED (C15): ReadLengthPrefixed* ops are replaced by decomposed require+read sequences.**

---

# Combined Questions and Assumptions

## Resolved Questions (Confirmed)

| # | Question | Resolution |
|---|----------|------------|
| 1 | Endianness representation | `Bytes.BE`/`Bytes.LE` are nullary constructors as `MonoVarGlobal`, resolved via `lookupSpecKey` |
| 2 | Context.setVar for cursors | Not needed - use SSA-threaded cursor in EmitState |
| 3 | Pkg.bytes identifier | Confirmed at `Package.elm:204` |
| 4 | `lookupSpecKey` return type | Returns `Maybe (Global, MonoType, Maybe LambdaId)` - a **tuple**, not `SpecKey` constructor |
| 5 | `MonoLet` constructor | Has 3 args: `MonoLet def body monoType` |
| 6 | `MonoClosure` parameter access | Use `closureInfo.params`, not `closureInfo.args` |
| 7 | Header bitfield stability | **NOT ABI-stable** - never GEP into header fields, use runtime accessors |

## Open Questions

### Phase 1
1. **Build verification** - Does `cmake --build build` currently succeed?

### Phase 2
1. **Maybe representation** - How is `Maybe a` represented at runtime? Is there a `Nothing` singleton?
2. **scf.if support** - Does `Ops.elm` support emitting `scf.if` with then/else regions? (**CRITICAL for C24 decision**)
3. **Signed vs unsigned integers** - Do we need separate MLIR types or just cast at use site?
4. **✅ C22: eco.value 0 validity** - Is 0 a valid eco.value? If so, `elm_utf8_decode` failure signaling needs rethinking.

### Phase 3
1. ~~**Lambda closure analysis**~~ - **RESOLVED:** Use `closureInfo.params` for parameter extraction
2. **Negative length handling** - Treat as unsigned (matches JS) or fail?
3. **Maximum length limit** - Should there be a sanity check to prevent OOM?
4. **✅ C23: ECO TableGen include path** - What is the correct include path for ECO_ValueType in your build system?

### Phase 4
1. **List representation** - How are lists represented at runtime?
2. **scf.while support** - Does `Ops.elm` support emitting `scf.while` with condition/body blocks?
3. **Step type pattern matching** - How is `Step state a` (Loop/Done) represented in MonoExpr?
4. **State tuple destructuring** - How does the compiler represent `\( n, acc ) -> ...`?

### ✅ CORRECTED C18: MonoLet Grounding Task (All Phases)

**HARD GATE:** Before implementing ANY MonoLet-related code, you MUST:

1. **Read the actual type definition** in `Compiler/AST/Monomorphized.elm`:
   ```bash
   grep -A 20 "type alias MonoLetDef" compiler/src/Compiler/AST/Monomorphized.elm
   grep -A 5 "MonoLet " compiler/src/Compiler/AST/Monomorphized.elm
   ```

2. **Verify the MonoLet constructor signature:**
   - Is it `MonoLet MonoLetDef MonoExpr MonoType`?
   - Or `MonoLet (List MonoLetDef) MonoExpr MonoType`?
   - Or something else entirely?

3. **Verify MonoLetDef record fields:**
   - The plan assumes fields like `def.name`, `def.body`, `def.expr`
   - VERIFY: What are the ACTUAL field names?
   - Common patterns: `{ name : Name, args : List Pattern, body : Expr, ... }`

4. **Update all reify* functions** to use correct field access:
   ```elm
   -- PLACEHOLDER - replace with actual field names after verification
   Mono.MonoLet defs body _ ->
       case body of
           Mono.MonoVarLocal varName _ ->
               -- Find the def where ACTUAL_NAME_FIELD == varName
               -- Then reify ACTUAL_BODY_FIELD
   ```

5. **Locations that need updating** (search for "def.???"):
   - `Reify.elm` - encoder reification
   - `ReifyDecoder.elm` - decoder reification
   - Any other MonoLet pattern matches

**This grounding step is BLOCKING for implementation.**

## All Assumptions

| # | Assumption | Phase |
|---|------------|-------|
| A1 | Endianness values identified by pattern-matching constructor SpecIds | 1 ✓ |
| A2 | Cursor tracked via SSA threading in EmitState | 1 ✓ |
| A3 | Portable byte-wise stores (no bswap intrinsics initially) | 1 |
| A4 | `Pkg.bytes` is the `elm/bytes` package identifier | 1 ✓ |
| A5 | Phase 1 complete before starting Phase 2 | 2 |
| A6 | scf.if can be emitted from Elm codegen | 2 |
| A7 | Maybe is a standard custom type with Nothing/Just constructors | 2 |
| A8 | Signed integers use same read ops, different type interpretation | 2 |
| A9 | Phase 2 complete before starting Phase 3 | 3 |
| A10 | MonoClosure provides access to lambda parameter info | 3 |
| A11 | Length values treated as unsigned for bounds checking | 3 |
| A12 | No maximum length enforcement (rely on system limits) | 3 |
| A13 | Phase 3 complete before starting Phase 4 | 4 |
| A14 | scf.while can be emitted (may need to add support) | 4 |
| A15 | List operations available from existing runtime | 4 |
| A16 | Step type uses standard ADT representation | 4 |

---

# Overall Implementation Order

## Phase 1: Encoder Fusion

| Step | Task | Dependencies | Testable |
|------|------|--------------|----------|
| 1.1 | Create `ElmBytesRuntime.h/cpp` | None | Yes (unit tests) |
| 1.2 | Update `CMakeLists.txt` | 1.1 | Build check |
| 1.3 | Register runtime symbols | 1.1, 1.2 | Build check |
| 1.4 | Create bf dialect TableGen | None | TableGen compiles |
| 1.5 | Create bf C++ scaffolding | 1.4 | Build check |
| 1.6 | Create `BFToLLVM.cpp` | 1.4, 1.5 | Hand-written bf MLIR |
| 1.7 | Create `LoopIR.elm` | None | Unit tests |
| 1.8 | Create `Reify.elm` | 1.7 | Unit tests |
| 1.9 | Create `Compile.elm` | 1.7, 1.8 | Unit tests |
| 1.10 | Create `EmitBF.elm` | 1.7, 1.9 | Integration test |
| 1.11 | Update `Expr.elm` | 1.8, 1.9, 1.10 | E2E test |
| 1.12 | Create encoder E2E tests | 1.11 | Full validation |

## Phase 2: Decoder Fusion

| Step | Task | Dependencies | Testable |
|------|------|--------------|----------|
| 2.1 | Add decoder helpers to runtime | Phase 1 | Unit tests |
| 2.2 | Add bf read ops to TableGen | Phase 1 | TableGen compiles |
| 2.3 | Add read lowering to `BFToLLVM.cpp` | 2.2 | Hand-written bf MLIR |
| 2.4 | Extend `LoopIR.elm` with DecoderOp | Phase 1 | Unit tests |
| 2.5 | Create `ReifyDecoder.elm` | 2.4 | Unit tests |
| 2.6 | Create `CompileDecoder.elm` | 2.4, 2.5 | Unit tests |
| 2.7 | Create `EmitBFDecoder.elm` | 2.4, 2.6 | Integration test |
| 2.8 | Update `Expr.elm` for decode | 2.5, 2.6, 2.7 | E2E test |
| 2.9 | Create decoder E2E tests | 2.8 | Full validation |

## Phase 3: andThen Support

| Step | Task | Dependencies | Testable |
|------|------|--------------|----------|
| 3.1 | Extend DecoderNode with length-prefixed | Phase 2 | Unit tests |
| 3.2 | Implement lambda body analysis | 3.1 | Unit tests |
| 3.3 | Add dyn read ops to TableGen | Phase 2 | TableGen compiles |
| 3.4 | Add dyn read lowering | 3.3 | Hand-written MLIR |
| 3.5 | Update `CompileDecoder.elm` | 3.1, 3.2 | Unit tests |
| 3.6 | Update `EmitBFDecoder.elm` | 3.4, 3.5 | Integration test |
| 3.7 | Create andThen E2E tests | 3.6 | Full validation |

## Phase 4: loop Support

| Step | Task | Dependencies | Testable |
|------|------|--------------|----------|
| 4.1 | Add list ops to runtime | Phase 3 | Unit tests |
| 4.2 | Register list symbols | 4.1 | Build check |
| 4.3 | Extend DecoderNode with loop types | Phase 3 | Unit tests |
| 4.4 | Implement loop pattern recognition | 4.3 | Unit tests |
| 4.5 | Update `CompileDecoder.elm` for loops | 4.3, 4.4 | Unit tests |
| 4.6 | Implement scf.while emission | 4.5 | Integration test |
| 4.7 | Create loop E2E tests | 4.6 | Full validation |

---

# Success Criteria

Each phase is complete when:

1. ✅ All new files created and compiling
2. ✅ All modified files updated  
3. ✅ Unit tests passing for reification modules
4. ✅ E2E tests passing for full pipeline
5. ✅ Fallback to kernel works for non-fuseable patterns
6. ✅ No regressions in existing functionality

## Phase-Specific Milestones

### Phase 1 Complete When:
- `Bytes.Encode.encode (Encode.sequence [...])` compiles to fused bf ops
- Simple u8, u16, u32 encoding works
- String encoding with UTF-8 conversion works
- Non-fuseable encoders fall back to kernel

### Phase 2 Complete When:
- `Bytes.Decode.decode decoder bytes` compiles to fused bf ops
- Returns `Just value` on success, `Nothing` on failure
- map, map2-5 combinators work
- Non-fuseable decoders fall back to kernel

### Phase 3 Complete When:
- Length-prefixed string/bytes patterns fuse
- `andThen \len -> Decode.string len` works
- Chained andThen patterns work
- Non-fuseable andThen falls back to kernel

### Phase 4 Complete When:
- Count-based loops fuse to scf.while
- List accumulation with reverse works
- Empty list case works
- Non-fuseable loops fall back to kernel
