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
---

---
---

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

C-ABI header for stable ByteBuffer and UTF-8 accessors:

```c
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint8_t  u8;
typedef uint32_t u32;

typedef struct elm_bytebuffer ByteBuffer;

// Allocate ByteBuffer with header.size = byteCount (in bytes).
ByteBuffer* elm_alloc_bytebuffer(u32 byteCount);

// Return ByteBuffer byte length (header.size).
u32 elm_bytebuffer_len(ByteBuffer* bb);

// Return pointer to first payload byte (bb->bytes).
u8* elm_bytebuffer_data(ByteBuffer* bb);

// Return UTF-8 byte width of an ElmString (UTF-16 internally).
// This computes how many bytes are needed to encode the string as UTF-8.
u32 elm_utf8_width(void* elmString);

// Copy ElmString (UTF-16) as UTF-8 bytes to dst buffer.
// Returns number of bytes written.
u32 elm_utf8_copy(void* elmString, u8* dst);

#ifdef __cplusplus
}
#endif
```

### 1.2 Create `runtime/src/allocator/ElmBytesRuntime.cpp`

Implementation notes:
- `elm_alloc_bytebuffer` - use existing allocator infrastructure
- `elm_bytebuffer_len` / `elm_bytebuffer_data` - simple accessors
- `elm_utf8_width` - **NEW**: iterate UTF-16 chars, compute UTF-8 byte count
- `elm_utf8_copy` - **NEW**: convert UTF-16 to UTF-8 into destination buffer

**UTF-8 implementation detail:** ElmString is stored as UTF-16 (`u16 chars[]`). Need to:
- Handle BMP characters (U+0000 to U+FFFF): 1-3 UTF-8 bytes
- Handle surrogate pairs for non-BMP characters: 4 UTF-8 bytes

```cpp
#include "ElmBytesRuntime.h"
#include "Heap.hpp"
#include "Allocator.hpp"

extern "C" {

ByteBuffer* elm_alloc_bytebuffer(u32 byteCount) {
    auto& allocator = Allocator::instance();
    size_t total_size = sizeof(ByteBuffer) + byteCount;
    total_size = (total_size + 7) & ~7;  // 8-byte align
    ByteBuffer* bb = static_cast<ByteBuffer*>(
        allocator.allocate(total_size, Tag_ByteBuffer));
    bb->header.size = byteCount;
    return bb;
}

u32 elm_bytebuffer_len(ByteBuffer* bb) {
    return bb->header.size;
}

u8* elm_bytebuffer_data(ByteBuffer* bb) {
    return bb->bytes;
}

u32 elm_utf8_width(void* elmString) {
    ElmString* s = static_cast<ElmString*>(elmString);
    u32 width = 0;
    size_t i = 0;
    while (i < s->header.size) {
        u16 c = s->chars[i];
        if (c < 0x80) {
            width += 1;  // ASCII: 1 byte
        } else if (c < 0x800) {
            width += 2;  // 2-byte UTF-8
        } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s->header.size) {
            // High surrogate - check for low surrogate
            u16 c2 = s->chars[i + 1];
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                width += 4;  // Surrogate pair -> 4-byte UTF-8
                i++;  // Skip low surrogate
            } else {
                width += 3;  // Lone high surrogate (invalid, but encode as-is)
            }
        } else {
            width += 3;  // BMP character: 3-byte UTF-8
        }
        i++;
    }
    return width;
}

u32 elm_utf8_copy(void* elmString, u8* dst) {
    ElmString* s = static_cast<ElmString*>(elmString);
    u8* start = dst;
    size_t i = 0;
    while (i < s->header.size) {
        u16 c = s->chars[i];
        if (c < 0x80) {
            *dst++ = static_cast<u8>(c);
        } else if (c < 0x800) {
            *dst++ = static_cast<u8>(0xC0 | (c >> 6));
            *dst++ = static_cast<u8>(0x80 | (c & 0x3F));
        } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s->header.size) {
            u16 c2 = s->chars[i + 1];
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                // Decode surrogate pair to code point
                u32 cp = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                *dst++ = static_cast<u8>(0xF0 | (cp >> 18));
                *dst++ = static_cast<u8>(0x80 | ((cp >> 12) & 0x3F));
                *dst++ = static_cast<u8>(0x80 | ((cp >> 6) & 0x3F));
                *dst++ = static_cast<u8>(0x80 | (cp & 0x3F));
                i++;  // Skip low surrogate
            } else {
                // Lone high surrogate - encode as 3-byte
                *dst++ = static_cast<u8>(0xE0 | (c >> 12));
                *dst++ = static_cast<u8>(0x80 | ((c >> 6) & 0x3F));
                *dst++ = static_cast<u8>(0x80 | (c & 0x3F));
            }
        } else {
            *dst++ = static_cast<u8>(0xE0 | (c >> 12));
            *dst++ = static_cast<u8>(0x80 | ((c >> 6) & 0x3F));
            *dst++ = static_cast<u8>(0x80 | (c & 0x3F));
        }
        i++;
    }
    return static_cast<u32>(dst - start);
}

} // extern "C"
```

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
- `bf.write.u8/u16_be/u16_le/u32_be/u32_le/f32_be/f64_be`
- `bf.write.bytes_copy` - Copy ByteBuffer payload
- `bf.write.utf8` - Copy UTF-8 string bytes
- `bf.require` - Bounds check (for future decoder support)

---

## Step 3: bf → LLVM Lowering

### 3.1 Create `runtime/src/codegen/Passes/BFToLLVM.cpp`

**Cursor representation:** `(ptr, end)` as LLVM struct `{ i8*, i8* }`

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

import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..), Global(..), SpecKey(..))
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
        Mono.MonoLet _ body _ ->
            reifyEncoderHelp registry body

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
- `SpecKey = SpecKey Global MonoType (Maybe LambdaId)`
- `Global = Global IO.Canonical Name | Accessor Name`

Bytes.BE and Bytes.LE are nullary constructors of Bytes.Endianness.
-}
reifyEndianness : Mono.MonoRegistry -> Mono.MonoExpr -> Maybe Endianness
reifyEndianness registry expr =
    case expr of
        -- Nullary constructors are represented as MonoVarGlobal
        Mono.MonoVarGlobal _ specId _ ->
            case Mono.lookupSpecKey specId registry of
                Just (Mono.SpecKey (Mono.Global (IO.Canonical pkg moduleName) name) _ _) ->
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
    , ops : List MlirOp      -- Accumulated ops (in reverse)
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
    { ops = List.reverse finalState.ops
    , resultVar = finalState.bufferVar
    , resultType = Types.ecoValue  -- ByteBuffer* as eco.value
    , ctx = finalState.ctx
    , isTerminated = False
    }


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
                        |> Ops.opBuilder.withResults [ ( curVar, NamedStruct "bf.cur" ) ]
                        |> Ops.opBuilder.build
            in
            { st
                | ctx = ctx5
                , cursor = curVar
                , bufferVar = allocVar
                , ops = cursorOp :: allocOp :: (widthOps ++ st.ops)
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
                |> Ops.opBuilder.withResults [ ( newCurVar, NamedStruct "bf.cur" ) ]
                |> Ops.opBuilder.build
    in
    { st
        | ctx = ctx2
        , cursor = newCurVar  -- Thread new cursor forward
        , ops = writeOp :: (valueResult.ops ++ st.ops)
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
                |> Ops.opBuilder.withResults [ ( newCurVar, NamedStruct "bf.cur" ) ]
                |> Ops.opBuilder.build
    in
    { st
        | ctx = ctx2
        , cursor = newCurVar
        , ops = writeOp :: (srcResult.ops ++ st.ops)
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
- SpecId resolves via `lookupSpecKey` to `SpecKey (Global (IO.Canonical pkg moduleName) name) _ _`
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

### 1.1 Add decoder helpers to `ElmBytesRuntime.h`

```c
// UTF-8 decode: read `len` bytes from src as UTF-8, return ElmString*
// Returns NULL if invalid UTF-8.
void* elm_utf8_decode(const u8* src, u32 len);

// Maybe constructors (if not already exposed)
void* elm_maybe_nothing(void);
void* elm_maybe_just(void* value);
```

### 1.2 Implement in `ElmBytesRuntime.cpp`

```cpp
void* elm_utf8_decode(const u8* src, u32 len) {
    // Convert UTF-8 bytes to ElmString (UTF-16 internal)
    // 1. Validate UTF-8 and compute UTF-16 length
    // 2. Allocate ElmString with computed length
    // 3. Convert UTF-8 → UTF-16 into buffer
    // 4. Return ElmString* or NULL on invalid UTF-8

    // Implementation sketch:
    size_t utf16Len = 0;
    const u8* p = src;
    const u8* end = src + len;

    // First pass: validate and count UTF-16 code units
    while (p < end) {
        u32 cp;
        if ((*p & 0x80) == 0) {
            cp = *p++;
            utf16Len += 1;
        } else if ((*p & 0xE0) == 0xC0) {
            if (p + 2 > end) return nullptr;
            cp = ((*p & 0x1F) << 6) | (*(p+1) & 0x3F);
            p += 2;
            utf16Len += 1;
        } else if ((*p & 0xF0) == 0xE0) {
            if (p + 3 > end) return nullptr;
            cp = ((*p & 0x0F) << 12) | ((*(p+1) & 0x3F) << 6) | (*(p+2) & 0x3F);
            p += 3;
            utf16Len += 1;
        } else if ((*p & 0xF8) == 0xF0) {
            if (p + 4 > end) return nullptr;
            cp = ((*p & 0x07) << 18) | ((*(p+1) & 0x3F) << 12) |
                 ((*(p+2) & 0x3F) << 6) | (*(p+3) & 0x3F);
            p += 4;
            utf16Len += 2;  // Surrogate pair
        } else {
            return nullptr;  // Invalid UTF-8
        }
    }

    // Allocate and convert
    ElmString* s = allocateElmString(utf16Len);
    // ... second pass to fill s->chars ...
    return s;
}

void* elm_maybe_nothing(void) {
    // Return the Nothing singleton or allocate Nothing constructor
    // Depends on how Maybe is represented in your runtime
    return /* Nothing representation */;
}

void* elm_maybe_just(void* value) {
    // Allocate Just constructor with value
    return /* Just value representation */;
}
```

### 1.3 Register new symbols in `RuntimeSymbols.cpp`

```cpp
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

## Step 2: Extend bf Dialect for Decoding

### 2.1 Add to `BFOps.td`

```tablegen
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

// Read operations - return (value, newCursor, ok)
def BF_ReadU8Op : Op<BFDialect, "read.u8", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I8:$value, BF_CurType:$newCur, BF_StatusType:$ok);
}

def BF_ReadU16BEOp : Op<BFDialect, "read.u16_be", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I16:$value, BF_CurType:$newCur, BF_StatusType:$ok);
}

def BF_ReadU16LEOp : Op<BFDialect, "read.u16_le", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I16:$value, BF_CurType:$newCur, BF_StatusType:$ok);
}

def BF_ReadU32BEOp : Op<BFDialect, "read.u32_be", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I32:$value, BF_CurType:$newCur, BF_StatusType:$ok);
}

def BF_ReadU32LEOp : Op<BFDialect, "read.u32_le", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I32:$value, BF_CurType:$newCur, BF_StatusType:$ok);
}

def BF_ReadF32BEOp : Op<BFDialect, "read.f32_be", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs F32:$value, BF_CurType:$newCur, BF_StatusType:$ok);
}

def BF_ReadF64BEOp : Op<BFDialect, "read.f64_be", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs F64:$value, BF_CurType:$newCur, BF_StatusType:$ok);
}

// Read N bytes as sub-slice (returns ByteBuffer*)
def BF_ReadBytesOp : Op<BFDialect, "read.bytes", [Pure]> {
  let arguments = (ins BF_CurType:$cur, I32:$len);
  let results   = (outs LLVM_Pointer:$bytes, BF_CurType:$newCur, BF_StatusType:$ok);
}

// Read N bytes as UTF-8 string (returns ElmString* or NULL)
def BF_ReadUtf8Op : Op<BFDialect, "read.utf8", [Pure]> {
  let arguments = (ins BF_CurType:$cur, I32:$len);
  let results   = (outs LLVM_Pointer:$string, BF_CurType:$newCur, BF_StatusType:$ok);
}
```

---

## Step 3: Extend bf → LLVM Lowering

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

// bf.read.u8(cur) → (value, newCur, ok)
struct ReadU8OpLowering : public ConvertOpToLLVMPattern<bf::ReadU8Op> {
  LogicalResult matchAndRewrite(bf::ReadU8Op op, OpAdaptor adaptor,
                                 ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    auto cur = adaptor.getCur();

    Value ptr = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 0);
    Value end = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 1);

    // Bounds check: ptr + 1 <= end
    Value one = rewriter.create<LLVM::ConstantOp>(loc, i64Type, 1);
    Value newPtr = rewriter.create<LLVM::GEPOp>(loc, ptrType, i8Type, ptr, one);
    Value ok = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ule, newPtr, end);

    // Read value (safe if ok is true, but we always read - check happens after)
    Value value = rewriter.create<LLVM::LoadOp>(loc, i8Type, ptr);

    // Build new cursor
    Value newCur = rewriter.create<LLVM::UndefOp>(loc, cursorType);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, newPtr, 0);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, end, 1);

    rewriter.replaceOp(op, {value, newCur, ok});
    return success();
  }
};

// Multi-byte reads: use byte-wise loads for portability
struct ReadU16BEOpLowering : public ConvertOpToLLVMPattern<bf::ReadU16BEOp> {
  LogicalResult matchAndRewrite(bf::ReadU16BEOp op, OpAdaptor adaptor,
                                 ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    auto cur = adaptor.getCur();

    Value ptr = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 0);
    Value end = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 1);

    // Bounds check: ptr + 2 <= end
    Value two = rewriter.create<LLVM::ConstantOp>(loc, i64Type, 2);
    Value newPtr = rewriter.create<LLVM::GEPOp>(loc, ptrType, i8Type, ptr, two);
    Value ok = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ule, newPtr, end);

    // Byte-wise load (big-endian): value = (b0 << 8) | b1
    Value b0 = rewriter.create<LLVM::LoadOp>(loc, i8Type, ptr);
    Value ptr1 = rewriter.create<LLVM::GEPOp>(loc, ptrType, i8Type, ptr,
                   rewriter.create<LLVM::ConstantOp>(loc, i64Type, 1));
    Value b1 = rewriter.create<LLVM::LoadOp>(loc, i8Type, ptr1);

    Value b0Ext = rewriter.create<LLVM::ZExtOp>(loc, i16Type, b0);
    Value b1Ext = rewriter.create<LLVM::ZExtOp>(loc, i16Type, b1);
    Value shifted = rewriter.create<LLVM::ShlOp>(loc, b0Ext,
                      rewriter.create<LLVM::ConstantOp>(loc, i16Type, 8));
    Value value = rewriter.create<LLVM::OrOp>(loc, shifted, b1Ext);

    // Build new cursor
    Value newCur = rewriter.create<LLVM::UndefOp>(loc, cursorType);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, newPtr, 0);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, end, 1);

    rewriter.replaceOp(op, {value, newCur, ok});
    return success();
  }
};

// bf.read.utf8(cur, len) → (string, newCur, ok)
struct ReadUtf8OpLowering : public ConvertOpToLLVMPattern<bf::ReadUtf8Op> {
  LogicalResult matchAndRewrite(bf::ReadUtf8Op op, OpAdaptor adaptor,
                                 ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    auto cur = adaptor.getCur();
    Value len = adaptor.getLen();

    Value ptr = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 0);
    Value end = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 1);

    // Bounds check
    Value lenExt = rewriter.create<LLVM::ZExtOp>(loc, i64Type, len);
    Value newPtr = rewriter.create<LLVM::GEPOp>(loc, ptrType, i8Type, ptr, lenExt);
    Value boundsOk = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ule, newPtr, end);

    // Call elm_utf8_decode(ptr, len)
    Value string = rewriter.create<LLVM::CallOp>(loc, ptrType,
                     "elm_utf8_decode", ValueRange{ptr, len}).getResult();

    // ok = boundsOk && string != null
    Value null = rewriter.create<LLVM::ZeroOp>(loc, ptrType);
    Value notNull = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::ne, string, null);
    Value ok = rewriter.create<LLVM::AndOp>(loc, boundsOk, notNull);

    // Build new cursor
    Value newCur = rewriter.create<LLVM::UndefOp>(loc, cursorType);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, newPtr, 0);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, end, 1);

    rewriter.replaceOp(op, {string, newCur, ok});
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
-}
type DecoderOp
    = InitReadCursor String Mono.MonoExpr  -- cursorName, bytes expression
    | ReadU8 String String                  -- cursorName, resultVarName
    | ReadU16 String Endianness String
    | ReadU32 String Endianness String
    | ReadF32 String Endianness String
    | ReadF64 String Endianness String
    | ReadBytes String Mono.MonoExpr String -- cursorName, length expr, resultVarName
    | ReadUtf8 String Mono.MonoExpr String  -- cursorName, length expr, resultVarName
    | CheckOk String                         -- Branch to fail if not ok
    | BuildResult Mono.MonoExpr              -- Build the decoded value
    | ReturnJust String                      -- Return Just resultVar
    | ReturnNothing                          -- Return Nothing (fail path)
```

### 4.2 Create `compiler/src/Compiler/Generate/MLIR/BytesFusion/ReifyDecoder.elm`

```elm
module Compiler.Generate.MLIR.BytesFusion.ReifyDecoder exposing (reifyDecoder, DecoderNode(..))

{-| Reify a MonoExpr representing a Bytes.Decode.Decoder into
a normalized decoder structure.

Phase 2 scope: Simple decoders only (no andThen, no loop).
-}

import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..), Global(..), SpecKey(..))
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
                        Just (SpecKey (Global (Canonical pkg moduleName) name) _ _) ->
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

        Mono.MonoLet _ body _ ->
            reifyDecoder registry body

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
                Just (SpecKey (Global (Canonical pkg moduleName) name) _ _) ->
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
    List.reverse finalState.ops


compileNode : DecoderNode -> CompileState -> CompileState
compileNode node st =
    case node of
        DU8 ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = CheckOk "cur" :: ReadU8 "cur" varName :: st1.ops
                , decodedVars = varName :: st1.decodedVars
            }

        DS8 ->
            -- Same as DU8 but result is signed (handled in type)
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = CheckOk "cur" :: ReadU8 "cur" varName :: st1.ops
                , decodedVars = varName :: st1.decodedVars
            }

        DU16 endian ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = CheckOk "cur" :: ReadU16 "cur" endian varName :: st1.ops
                , decodedVars = varName :: st1.decodedVars
            }

        DS16 endian ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = CheckOk "cur" :: ReadU16 "cur" endian varName :: st1.ops
                , decodedVars = varName :: st1.decodedVars
            }

        DU32 endian ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = CheckOk "cur" :: ReadU32 "cur" endian varName :: st1.ops
                , decodedVars = varName :: st1.decodedVars
            }

        DS32 endian ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = CheckOk "cur" :: ReadU32 "cur" endian varName :: st1.ops
                , decodedVars = varName :: st1.decodedVars
            }

        DF32 endian ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = CheckOk "cur" :: ReadF32 "cur" endian varName :: st1.ops
                , decodedVars = varName :: st1.decodedVars
            }

        DF64 endian ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = CheckOk "cur" :: ReadF64 "cur" endian varName :: st1.ops
                , decodedVars = varName :: st1.decodedVars
            }

        DBytes lenExpr ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = CheckOk "cur" :: ReadBytes "cur" lenExpr varName :: st1.ops
                , decodedVars = varName :: st1.decodedVars
            }

        DString lenExpr ->
            let
                ( varName, st1 ) = freshVar st
            in
            { st1
                | ops = CheckOk "cur" :: ReadUtf8 "cur" lenExpr varName :: st1.ops
                , decodedVars = varName :: st1.decodedVars
            }

        DSucceed valueExpr ->
            { st
                | ops = BuildResult valueExpr :: st.ops
            }

        DFail ->
            { st
                | ops = ReturnNothing :: st.ops
            }

        DMap fnExpr innerDecoder ->
            let
                st1 = compileNode innerDecoder st
            in
            { st1
                | ops = BuildResult fnExpr :: st1.ops
                -- fnExpr will be applied to the decoded value
            }

        DMap2 fnExpr d1 d2 ->
            let
                st1 = compileNode d1 st
                st2 = compileNode d2 st1
            in
            { st2
                | ops = BuildResult fnExpr :: st2.ops
            }

        DMap3 fnExpr d1 d2 d3 ->
            let
                st1 = compileNode d1 st
                st2 = compileNode d2 st1
                st3 = compileNode d3 st2
            in
            { st3
                | ops = BuildResult fnExpr :: st3.ops
            }

        DMap4 fnExpr d1 d2 d3 d4 ->
            let
                st1 = compileNode d1 st
                st2 = compileNode d2 st1
                st3 = compileNode d3 st2
                st4 = compileNode d4 st3
            in
            { st4
                | ops = BuildResult fnExpr :: st4.ops
            }

        DMap5 fnExpr d1 d2 d3 d4 d5 ->
            let
                st1 = compileNode d1 st
                st2 = compileNode d2 st1
                st3 = compileNode d3 st2
                st4 = compileNode d4 st3
                st5 = compileNode d5 st4
            in
            { st5
                | ops = BuildResult fnExpr :: st5.ops
            }


freshVar : CompileState -> ( String, CompileState )
freshVar st =
    ( "v" ++ String.fromInt st.varCounter
    , { st | varCounter = st.varCounter + 1 }
    )
```

### 4.4 Create `compiler/src/Compiler/Generate/MLIR/BytesFusion/EmitBFDecoder.elm`

```elm
module Compiler.Generate.MLIR.BytesFusion.EmitBFDecoder exposing (emitFusedDecoder)

{-| Emit bf dialect MLIR operations for a fused decoder.

Key difference from encoder: must handle failure path.
Uses scf.if for branching on ok status.
-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.MLIR.BytesFusion.LoopIR as IR exposing (DecoderOp(..), Endianness(..))
import Compiler.Generate.MLIR.Context as Ctx exposing (Context)
import Compiler.Generate.MLIR.Expr as Expr exposing (ExprResult)
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Mlir.Mlir exposing (MlirOp, MlirType(..), MlirAttr(..))


{-| Internal state for decoder emission.
-}
type alias EmitState =
    { ctx : Context
    , cursor : String              -- Current cursor SSA variable
    , bytesVar : String            -- Input bytes variable
    , ops : List MlirOp            -- Accumulated ops (in reverse)
    , decodedValues : List String  -- Stack of decoded value SSA vars
    , okVar : String               -- Current ok status
    }


{-| Emit a complete fused decoder, returning Maybe a.
-}
emitFusedDecoder : Context -> Mono.MonoExpr -> List DecoderOp -> ExprResult
emitFusedDecoder ctx bytesExpr ops =
    let
        -- First, generate the bytes expression
        bytesResult = Expr.generateExpr ctx bytesExpr

        -- Initialize cursor from bytes
        ( curVar, ctx1 ) = Ctx.freshVar bytesResult.ctx
        ( ctx2, initOp ) =
            Ops.mlirOp ctx1 "bf.cursor.init"
                |> Ops.opBuilder.withOperands [ bytesResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( curVar, NamedStruct "bf.cur" ) ]
                |> Ops.opBuilder.build

        initialState =
            { ctx = ctx2
            , cursor = curVar
            , bytesVar = bytesResult.resultVar
            , ops = initOp :: bytesResult.ops
            , decodedValues = []
            , okVar = ""
            }

        -- Process all decoder ops
        finalState =
            List.foldl emitDecoderOp initialState ops

        -- Wrap result in Maybe (emit scf.if for success/failure)
        ( maybeResult, finalCtx, maybeOps ) =
            emitMaybeWrapper finalState
    in
    { ops = List.reverse finalState.ops ++ maybeOps
    , resultVar = maybeResult
    , resultType = Types.ecoValue  -- Maybe a as eco.value
    , ctx = finalCtx
    , isTerminated = False
    }


{-| Emit a single decoder operation.
-}
emitDecoderOp : DecoderOp -> EmitState -> EmitState
emitDecoderOp op st =
    case op of
        InitReadCursor _ bytesExpr ->
            -- Already handled in emitFusedDecoder
            st

        ReadU8 _curName resultVarName ->
            emitReadOp st "bf.read.u8" I8 resultVarName

        ReadU16 _curName endian resultVarName ->
            let
                opName = case endian of
                    BE -> "bf.read.u16_be"
                    LE -> "bf.read.u16_le"
            in
            emitReadOp st opName I16 resultVarName

        ReadU32 _curName endian resultVarName ->
            let
                opName = case endian of
                    BE -> "bf.read.u32_be"
                    LE -> "bf.read.u32_le"
            in
            emitReadOp st opName I32 resultVarName

        ReadF32 _curName endian resultVarName ->
            let
                opName = case endian of
                    BE -> "bf.read.f32_be"
                    LE -> "bf.read.f32_le"
            in
            emitReadOp st opName F32 resultVarName

        ReadF64 _curName endian resultVarName ->
            let
                opName = case endian of
                    BE -> "bf.read.f64_be"
                    LE -> "bf.read.f64_le"
            in
            emitReadOp st opName F64 resultVarName

        ReadBytes _curName lenExpr resultVarName ->
            emitReadBytesOp st lenExpr resultVarName

        ReadUtf8 _curName lenExpr resultVarName ->
            emitReadUtf8Op st lenExpr resultVarName

        CheckOk _curName ->
            -- The ok check is embedded in read ops via scf.if
            -- This op is a marker for control flow
            st

        BuildResult valueExpr ->
            -- Build the result value using decoded values
            let
                valueResult = Expr.generateExpr st.ctx valueExpr
            in
            { st
                | ctx = valueResult.ctx
                , ops = valueResult.ops ++ st.ops
                , decodedValues = valueResult.resultVar :: st.decodedValues
            }

        ReturnJust resultVarName ->
            -- Handled in emitMaybeWrapper
            st

        ReturnNothing ->
            -- Handled in emitMaybeWrapper
            st


{-| Emit a read operation with ok status tracking.
-}
emitReadOp : EmitState -> String -> MlirType -> String -> EmitState
emitReadOp st opName valueTy resultVarName =
    let
        ( valueVar, ctx1 ) = Ctx.freshVar st.ctx
        ( newCurVar, ctx2 ) = Ctx.freshVar ctx1
        ( okVar, ctx3 ) = Ctx.freshVar ctx2

        ( ctx4, readOp ) =
            Ops.mlirOp ctx3 opName
                |> Ops.opBuilder.withOperands [ st.cursor ]
                |> Ops.opBuilder.withResults
                    [ ( valueVar, valueTy )
                    , ( newCurVar, NamedStruct "bf.cur" )
                    , ( okVar, I1 )
                    ]
                |> Ops.opBuilder.build

        -- Combine ok with previous ok (short-circuit AND)
        ( combinedOk, ctx5, andOp ) =
            if st.okVar == "" then
                ( okVar, ctx4, [] )
            else
                let
                    ( combinedVar, c1 ) = Ctx.freshVar ctx4
                    ( c2, op ) =
                        Ops.mlirOp c1 "arith.andi"
                            |> Ops.opBuilder.withOperands [ st.okVar, okVar ]
                            |> Ops.opBuilder.withResults [ ( combinedVar, I1 ) ]
                            |> Ops.opBuilder.build
                in
                ( combinedVar, c2, [ op ] )
    in
    { st
        | ctx = ctx5
        , cursor = newCurVar
        , ops = andOp ++ [ readOp ] ++ st.ops
        , decodedValues = valueVar :: st.decodedValues
        , okVar = combinedOk
    }


{-| Emit read.bytes operation.
-}
emitReadBytesOp : EmitState -> Mono.MonoExpr -> String -> EmitState
emitReadBytesOp st lenExpr resultVarName =
    let
        lenResult = Expr.generateExpr st.ctx lenExpr
        ( bytesVar, ctx1 ) = Ctx.freshVar lenResult.ctx
        ( newCurVar, ctx2 ) = Ctx.freshVar ctx1
        ( okVar, ctx3 ) = Ctx.freshVar ctx2

        ( ctx4, readOp ) =
            Ops.mlirOp ctx3 "bf.read.bytes"
                |> Ops.opBuilder.withOperands [ st.cursor, lenResult.resultVar ]
                |> Ops.opBuilder.withResults
                    [ ( bytesVar, Types.ecoValue )
                    , ( newCurVar, NamedStruct "bf.cur" )
                    , ( okVar, I1 )
                    ]
                |> Ops.opBuilder.build
    in
    { st
        | ctx = ctx4
        , cursor = newCurVar
        , ops = readOp :: (lenResult.ops ++ st.ops)
        , decodedValues = bytesVar :: st.decodedValues
        , okVar = okVar
    }


{-| Emit read.utf8 operation.
-}
emitReadUtf8Op : EmitState -> Mono.MonoExpr -> String -> EmitState
emitReadUtf8Op st lenExpr resultVarName =
    let
        lenResult = Expr.generateExpr st.ctx lenExpr
        ( stringVar, ctx1 ) = Ctx.freshVar lenResult.ctx
        ( newCurVar, ctx2 ) = Ctx.freshVar ctx1
        ( okVar, ctx3 ) = Ctx.freshVar ctx2

        ( ctx4, readOp ) =
            Ops.mlirOp ctx3 "bf.read.utf8"
                |> Ops.opBuilder.withOperands [ st.cursor, lenResult.resultVar ]
                |> Ops.opBuilder.withResults
                    [ ( stringVar, Types.ecoValue )
                    , ( newCurVar, NamedStruct "bf.cur" )
                    , ( okVar, I1 )
                    ]
                |> Ops.opBuilder.build
    in
    { st
        | ctx = ctx4
        , cursor = newCurVar
        , ops = readOp :: (lenResult.ops ++ st.ops)
        , decodedValues = stringVar :: st.decodedValues
        , okVar = okVar
    }


{-| Emit Maybe wrapper: scf.if(ok) { Just result } else { Nothing }
-}
emitMaybeWrapper : EmitState -> ( String, Context, List MlirOp )
emitMaybeWrapper st =
    let
        -- Get the final decoded value (top of stack)
        resultVar =
            case st.decodedValues of
                v :: _ -> v
                [] -> ""  -- Should not happen

        ( justVar, ctx1 ) = Ctx.freshVar st.ctx
        ( nothingVar, ctx2 ) = Ctx.freshVar ctx1
        ( maybeVar, ctx3 ) = Ctx.freshVar ctx2

        -- scf.if %ok -> eco.value {
        --   %just = call @elm_maybe_just(%result)
        --   scf.yield %just
        -- } else {
        --   %nothing = call @elm_maybe_nothing()
        --   scf.yield %nothing
        -- }
        ( ctx4, ifOp ) =
            Ops.scfIf ctx3 st.okVar Types.ecoValue
                -- Then block: Just result
                { body =
                    [ Ops.callNamed "elm_maybe_just" [ ( resultVar, Types.ecoValue ) ] justVar Types.ecoValue
                    , Ops.scfYield justVar
                    ]
                }
                -- Else block: Nothing
                { body =
                    [ Ops.callNamed "elm_maybe_nothing" [] nothingVar Types.ecoValue
                    , Ops.scfYield nothingVar
                    ]
                }
                maybeVar
    in
    ( maybeVar, ctx4, [ ifOp ] )
```

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

### 3. Signed vs unsigned integer handling

For `signedInt8/16/32`, do we need separate MLIR types or just cast at use site?

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
            case closureInfo.args of
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
                        Just (SpecKey (Global (Canonical pkg moduleName) name) _ _) ->
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
    = -- ... existing ops ...

    -- NEW: Length-prefixed operations
    | ReadLengthPrefixedString String LengthReadOp String
      -- cursorName, how to read length, resultVarName
    | ReadLengthPrefixedBytes String LengthReadOp String
      -- cursorName, how to read length, resultVarName


{-| How to read the length value.
-}
type LengthReadOp
    = ReadLenU8
    | ReadLenU16BE
    | ReadLenU16LE
    | ReadLenU32BE
    | ReadLenU32LE
```

---

## Step 3: Extend Compiler for Length-Prefixed

### 3.1 Update `CompileDecoder.elm`

```elm
compileNode : DecoderNode -> CompileState -> CompileState
compileNode node st =
    case node of
        -- ... existing cases ...

        DLengthPrefixedString lenDecoder ->
            let
                ( varName, st1 ) = freshVar st
                lenReadOp = lengthDecoderToReadOp lenDecoder
            in
            { st1
                | ops = CheckOk "cur" :: ReadLengthPrefixedString "cur" lenReadOp varName :: st1.ops
                , decodedVars = varName :: st1.decodedVars
            }

        DLengthPrefixedBytes lenDecoder ->
            let
                ( varName, st1 ) = freshVar st
                lenReadOp = lengthDecoderToReadOp lenDecoder
            in
            { st1
                | ops = CheckOk "cur" :: ReadLengthPrefixedBytes "cur" lenReadOp varName :: st1.ops
                , decodedVars = varName :: st1.decodedVars
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
// Read length (u32 BE) then that many bytes as UTF-8 string
def BF_ReadLenStringU32BEOp : Op<BFDialect, "read.len_string_u32be", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs LLVM_Pointer:$string, BF_CurType:$newCur, BF_StatusType:$ok);
  let summary = "Read u32 BE length, then that many bytes as UTF-8";
}

// Read length (u16 LE) then that many bytes as UTF-8 string
def BF_ReadLenStringU16LEOp : Op<BFDialect, "read.len_string_u16le", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs LLVM_Pointer:$string, BF_CurType:$newCur, BF_StatusType:$ok);
}

// Similar for bytes...
def BF_ReadLenBytesU32BEOp : Op<BFDialect, "read.len_bytes_u32be", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs LLVM_Pointer:$bytes, BF_CurType:$newCur, BF_StatusType:$ok);
}

// ... add variants for u8, u16 BE/LE, u32 BE/LE ...
```

**Alternative approach:** Keep ops separate and rely on the lowering to combine them:

```tablegen
// Use existing read ops + a "read dynamic bytes" op
def BF_ReadDynBytesOp : Op<BFDialect, "read.dyn_bytes", [Pure]> {
  let arguments = (ins BF_CurType:$cur, I32:$len);
  let results   = (outs LLVM_Pointer:$bytes, BF_CurType:$newCur, BF_StatusType:$ok);
}

def BF_ReadDynUtf8Op : Op<BFDialect, "read.dyn_utf8", [Pure]> {
  let arguments = (ins BF_CurType:$cur, I32:$len);
  let results   = (outs LLVM_Pointer:$string, BF_CurType:$newCur, BF_StatusType:$ok);
}
```

I recommend the **alternative approach** - it's more composable and we already have the read primitives.

---

## Step 5: Extend bf → LLVM Lowering

### 5.1 Update `BFToLLVM.cpp`

The lowering for length-prefixed is straightforward with the dynamic ops:

```cpp
// bf.read.dyn_utf8(cur, len) → (string, newCur, ok)
struct ReadDynUtf8OpLowering : public ConvertOpToLLVMPattern<bf::ReadDynUtf8Op> {
  LogicalResult matchAndRewrite(bf::ReadDynUtf8Op op, OpAdaptor adaptor,
                                 ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    auto cur = adaptor.getCur();
    Value len = adaptor.getLen();

    Value ptr = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 0);
    Value end = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 1);

    // Bounds check: ptr + len <= end
    Value lenExt = rewriter.create<LLVM::ZExtOp>(loc, i64Type, len);
    Value newPtr = rewriter.create<LLVM::GEPOp>(loc, ptrType, i8Type, ptr, lenExt);
    Value boundsOk = rewriter.create<LLVM::ICmpOp>(
        loc, LLVM::ICmpPredicate::ule, newPtr, end);

    // Call elm_utf8_decode(ptr, len) - returns string or NULL
    Value string = rewriter.create<LLVM::CallOp>(
        loc, ptrType, "elm_utf8_decode", ValueRange{ptr, len}).getResult();

    // ok = boundsOk && string != null
    Value null = rewriter.create<LLVM::ZeroOp>(loc, ptrType);
    Value notNull = rewriter.create<LLVM::ICmpOp>(
        loc, LLVM::ICmpPredicate::ne, string, null);
    Value ok = rewriter.create<LLVM::AndOp>(loc, boundsOk, notNull);

    // Build new cursor
    Value newCur = rewriter.create<LLVM::UndefOp>(loc, cursorType);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, newPtr, 0);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, end, 1);

    rewriter.replaceOp(op, {string, newCur, ok});
    return success();
  }
};

// bf.read.dyn_bytes(cur, len) → (bytes, newCur, ok)
struct ReadDynBytesOpLowering : public ConvertOpToLLVMPattern<bf::ReadDynBytesOp> {
  LogicalResult matchAndRewrite(bf::ReadDynBytesOp op, OpAdaptor adaptor,
                                 ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    auto cur = adaptor.getCur();
    Value len = adaptor.getLen();

    Value ptr = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 0);
    Value end = rewriter.create<LLVM::ExtractValueOp>(loc, cur, 1);

    // Bounds check
    Value lenExt = rewriter.create<LLVM::ZExtOp>(loc, i64Type, len);
    Value newPtr = rewriter.create<LLVM::GEPOp>(loc, ptrType, i8Type, ptr, lenExt);
    Value ok = rewriter.create<LLVM::ICmpOp>(
        loc, LLVM::ICmpPredicate::ule, newPtr, end);

    // Allocate ByteBuffer and copy
    Value bytes = rewriter.create<LLVM::CallOp>(
        loc, ptrType, "elm_alloc_bytebuffer", ValueRange{len}).getResult();
    Value data = rewriter.create<LLVM::CallOp>(
        loc, ptrType, "elm_bytebuffer_data", ValueRange{bytes}).getResult();

    // memcpy(data, ptr, len)
    rewriter.create<LLVM::MemcpyOp>(loc, data, ptr, lenExt, /*isVolatile=*/false);

    // Build new cursor
    Value newCur = rewriter.create<LLVM::UndefOp>(loc, cursorType);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, newPtr, 0);
    newCur = rewriter.create<LLVM::InsertValueOp>(loc, newCur, end, 1);

    rewriter.replaceOp(op, {bytes, newCur, ok});
    return success();
  }
};
```

---

## Step 6: Emit Length-Prefixed Operations

### 6.1 Update `EmitBFDecoder.elm`

```elm
emitDecoderOp : DecoderOp -> EmitState -> EmitState
emitDecoderOp op st =
    case op of
        -- ... existing cases ...

        ReadLengthPrefixedString _curName lenReadOp resultVarName ->
            emitLengthPrefixedRead st lenReadOp "bf.read.dyn_utf8"

        ReadLengthPrefixedBytes _curName lenReadOp resultVarName ->
            emitLengthPrefixedRead st lenReadOp "bf.read.dyn_bytes"


{-| Emit a length-prefixed read: read length, then read that many bytes.
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
                    , ( curAfterLen, NamedStruct "bf.cur" )
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
                    , ( newCurVar, NamedStruct "bf.cur" )
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
            case closureInfo.args of
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
// List operations for loop support
void* elm_list_nil(void);
void* elm_list_cons(void* head, void* tail);
void* elm_list_reverse(void* list);
```

### 5.2 Implement in `ElmBytesRuntime.cpp`

```cpp
extern "C" {

void* elm_list_nil(void) {
    // Return empty list (Nil constructor)
    return /* Nil representation */;
}

void* elm_list_cons(void* head, void* tail) {
    // Allocate Cons cell
    // Cons { head: head, tail: tail }
    return /* Cons allocation */;
}

void* elm_list_reverse(void* list) {
    // Reverse list in place or build new reversed list
    // This should reuse existing ListOps implementation
    return /* Reversed list */;
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

### Types
- `!bf.cur` - Cursor type (ptr, end) pair
- `!bf.status` - i1 ok/fail flag (Phase 2+)

### Phase 1 Operations (Write)
- `bf.alloc` - Allocate ByteBuffer
- `bf.cursor.init` - Create cursor from ByteBuffer*
- `bf.write.u8`, `bf.write.u16_be`, `bf.write.u16_le`
- `bf.write.u32_be`, `bf.write.u32_le`
- `bf.write.f32_be`, `bf.write.f32_le`, `bf.write.f64_be`, `bf.write.f64_le`
- `bf.write.bytes_copy`, `bf.write.utf8`

### Phase 2 Operations (Read)
- `bf.require` - Bounds check
- `bf.read.u8`, `bf.read.u16_be`, `bf.read.u16_le`
- `bf.read.u32_be`, `bf.read.u32_le`
- `bf.read.f32_be`, `bf.read.f64_be`
- `bf.read.bytes`, `bf.read.utf8`

### Phase 3 Operations (Dynamic)
- `bf.read.dyn_bytes` - Read N bytes where N is runtime value
- `bf.read.dyn_utf8` - Read N bytes as UTF-8 where N is runtime value

---

# Combined Questions and Assumptions

## Resolved Questions (Confirmed)

| # | Question | Resolution |
|---|----------|------------|
| 1 | Endianness representation | `Bytes.BE`/`Bytes.LE` are nullary constructors as `MonoVarGlobal`, resolved via `lookupSpecKey` |
| 2 | Context.setVar for cursors | Not needed - use SSA-threaded cursor in EmitState |
| 3 | Pkg.bytes identifier | Confirmed at `Package.elm:204` |

## Open Questions

### Phase 1
1. **Build verification** - Does `cmake --build build` currently succeed?

### Phase 2
1. **Maybe representation** - How is `Maybe a` represented at runtime? Is there a `Nothing` singleton?
2. **scf.if support** - Does `Ops.elm` support emitting `scf.if` with then/else regions?
3. **Signed vs unsigned integers** - Do we need separate MLIR types or just cast at use site?

### Phase 3
1. **Lambda closure analysis** - How does `MonoClosure` represent closures? Need to verify parameter extraction.
2. **Negative length handling** - Treat as unsigned (matches JS) or fail?
3. **Maximum length limit** - Should there be a sanity check to prevent OOM?

### Phase 4
1. **List representation** - How are lists represented at runtime?
2. **scf.while support** - Does `Ops.elm` support emitting `scf.while` with condition/body blocks?
3. **Step type pattern matching** - How is `Step state a` (Loop/Done) represented in MonoExpr?
4. **State tuple destructuring** - How does the compiler represent `\( n, acc ) -> ...`?

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
