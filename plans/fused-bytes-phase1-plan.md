# Fused Bytes Compilation - Phase 1 Implementation Plan (Revised)

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
