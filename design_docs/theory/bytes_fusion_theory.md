# Bytes Fusion Optimization

## Overview

Bytes Fusion is a compiler optimization that intercepts `Bytes.encode` and `Bytes.decode` calls and lowers them directly to fused cursor-based operations, bypassing the interpreter-style kernel implementation. This eliminates intermediate data structures and function call overhead for byte encoding/decoding.

**Phase**: MLIR Generation

**Pipeline Position**: During MLIR codegen, as an alternative path for Bytes kernel calls

**Related Modules**:
- `compiler/src/Compiler/Generate/MLIR/BytesFusion/Reify.elm`
- `compiler/src/Compiler/Generate/MLIR/BytesFusion/Emit.elm`
- `runtime/src/codegen/BF/BFOps.td`

## Motivation

Elm's `Bytes.Encode` and `Bytes.Decode` modules use a compositional API where encoders and decoders are built from combinators:

```elm
encoder : Encoder
encoder =
    Bytes.Encode.sequence
        [ Bytes.Encode.unsignedInt32 BE 42
        , Bytes.Encode.float64 LE 3.14
        , Bytes.Encode.string "hello"
        ]
```

The standard kernel implementation interprets this encoder tree at runtime, creating intermediate closures and traversing the structure multiple times. Bytes Fusion recognizes these patterns at compile time and generates direct, fused operations.

## The BF Dialect

The BF (ByteFusion) dialect is a custom MLIR dialect for cursor-based byte operations.

### Core Type

```mlir
!bf.cursor  // Paired pointer (ptr, end) for bounds checking
```

A cursor is a pair of pointers `(current_ptr, end_ptr)` that tracks position in a byte buffer. Write operations advance `current_ptr` and return a new cursor (SSA threading).

### Endianness

```tablegen
def BF_Endianness : I32EnumAttr<"Endianness", ...> {
  I32EnumAttrCase<"LE", 0, "le">,  // Little-endian
  I32EnumAttrCase<"BE", 1, "be">   // Big-endian
}
```

### Key Operations

**Buffer Allocation:**
```mlir
%buffer = bf.alloc %size : i64 -> !eco.value
```

**Cursor Initialization:**
```mlir
%cursor = bf.init_write_cursor %buffer : !eco.value -> !bf.cursor
%cursor = bf.init_read_cursor %bytes : !eco.value -> !bf.cursor
```

**Write Operations:**
```mlir
%new_cursor = bf.write_u8 %cursor, %value : !bf.cursor, i64 -> !bf.cursor
%new_cursor = bf.write_u16 %cursor, %value {endian = #bf.endian<be>} : ...
%new_cursor = bf.write_u32 %cursor, %value {endian = #bf.endian<le>} : ...
%new_cursor = bf.write_f32 %cursor, %value {endian = #bf.endian<be>} : ...
%new_cursor = bf.write_f64 %cursor, %value {endian = #bf.endian<le>} : ...
%new_cursor = bf.write_bytes %cursor, %bytes : !bf.cursor, !eco.value -> !bf.cursor
%new_cursor = bf.write_utf8 %cursor, %string : !bf.cursor, !eco.value -> !bf.cursor
```

**Read Operations:**
```mlir
%value, %new_cursor = bf.read_u8 %cursor : !bf.cursor -> i64, !bf.cursor
%value, %new_cursor = bf.read_u16 %cursor {endian = #bf.endian<be>} : ...
%value, %new_cursor = bf.read_f64 %cursor {endian = #bf.endian<le>} : ...
%bytes, %new_cursor = bf.read_bytes %cursor, %len : !bf.cursor, i64 -> !eco.value, !bf.cursor
%string, %new_cursor = bf.read_utf8 %cursor, %len : !bf.cursor, i64 -> !eco.value, !bf.cursor
```

**Bounds Checking:**
```mlir
%ok = bf.require %cursor, %count : !bf.cursor, i64 -> i1
```

## Architecture

The Bytes Fusion pipeline has two main phases:

```
MonoExpr (Bytes.encode call)
    ↓
┌─────────────────────────────┐
│  Reify.elm                  │
│  - Pattern match encoder    │
│  - Build EncoderNode tree   │
└─────────────────────────────┘
    ↓
EncoderNode / DecoderNode
    ↓
┌─────────────────────────────┐
│  Emit.elm                   │
│  - Emit bf.alloc            │
│  - Emit bf.init_cursor      │
│  - Emit bf.write_* ops      │
└─────────────────────────────┘
    ↓
MLIR BF dialect ops
```

### Phase 1: Reification (Reify.elm)

The reifier pattern-matches the MonoExpr AST to recognize encoder/decoder combinators:

```elm
type EncoderNode
    = EU8 MonoExpr              -- unsignedInt8
    | EU16 Endianness MonoExpr  -- unsignedInt16
    | EU32 Endianness MonoExpr  -- unsignedInt32
    | EF32 Endianness MonoExpr  -- float32
    | EF64 Endianness MonoExpr  -- float64
    | EBytes MonoExpr           -- bytes
    | EUtf8 MonoExpr            -- string (UTF-8)
```

```elm
type DecoderNode
    = DU8                       -- unsignedInt8
    | DS8                       -- signedInt8
    | DU16 Endianness           -- unsignedInt16
    | DF64 Endianness           -- float64
    | DBytes MonoExpr           -- bytes with length expr
    | DString MonoExpr          -- string with length expr
    | DSucceed MonoExpr         -- succeed with value
    | DFail                     -- fail
    | DMap MonoExpr DecoderNode -- map fn decoder
    | DMap2 MonoExpr DecoderNode DecoderNode
    | DMap3 MonoExpr DecoderNode DecoderNode DecoderNode
    | DMap4 ...
    | DMap5 ...
    | DAndThen DecoderNode String DecoderNode
    | DLengthPrefixedString LengthDecoder
    | DLengthPrefixedBytes LengthDecoder
    | DCountLoop CountSource DecoderNode
    | DSentinelLoop Int DecoderNode
```

**Expression Cache**: For let-bindings, the reifier maintains an `exprCache` that maps variable names to their definitions, allowing it to resolve decoder references through variable bindings.

### Phase 2: Emission (Emit.elm)

The emitter generates BF dialect operations from the reified node tree:

**Encoder Emission:**
1. Compute total buffer width (sum of all write sizes)
2. Emit `bf.alloc` with computed size
3. Emit `bf.init_write_cursor`
4. For each EncoderNode, emit corresponding `bf.write_*` op
5. Return the buffer

**Decoder Emission:**
1. Emit `bf.init_read_cursor` on input bytes
2. For each DecoderNode:
   - Emit `bf.require` for bounds checking
   - Emit `bf.read_*` op
   - Thread cursor through SSA
3. Wrap result in `Maybe` (Just for success, Nothing for failure)

### Width Computation

For encoders, the total buffer size is computed statically when possible:

```elm
computeWidth : EncoderNode -> Int
computeWidth node =
    case node of
        EU8 _ -> 1
        EU16 _ _ -> 2
        EU32 _ _ -> 4
        EF32 _ _ -> 4
        EF64 _ _ -> 8
        EBytes expr -> dynamicWidth expr
        EUtf8 expr -> dynamicWidth expr
```

For dynamic widths (strings, bytes), a `bf.width` op queries the length at runtime.

## Integration with Codegen

Bytes Fusion is invoked from `Expr.elm` when a kernel call is detected:

```elm
generateExpr expr =
    case expr of
        MonoCall (MonoVarKernel "Bytes" "encode") [encoder] _ ->
            case BytesFusion.Reify.reifyEncoder encoder of
                Just nodes ->
                    BytesFusion.Emit.emitFusedEncoder nodes
                Nothing ->
                    -- Fall back to kernel call
                    generateKernelCall "Bytes" "encode" [encoder]
        ...
```

### Fallback Path

When fusion cannot be applied (complex patterns, unsupported combinators), the regular kernel implementation is used. This ensures correctness—fusion is an optimization, not a requirement.

## Supported Patterns

### Encoders

| Elm Function | EncoderNode | Width |
|--------------|-------------|-------|
| `unsignedInt8` | `EU8` | 1 |
| `signedInt8` | `EU8` | 1 |
| `unsignedInt16 BE/LE` | `EU16` | 2 |
| `signedInt16 BE/LE` | `EU16` | 2 |
| `unsignedInt32 BE/LE` | `EU32` | 4 |
| `signedInt32 BE/LE` | `EU32` | 4 |
| `float32 BE/LE` | `EF32` | 4 |
| `float64 BE/LE` | `EF64` | 8 |
| `bytes` | `EBytes` | dynamic |
| `string` | `EUtf8` | dynamic |
| `sequence` | flattened list | sum |

### Decoders

| Elm Function | DecoderNode |
|--------------|-------------|
| `unsignedInt8` | `DU8` |
| `signedInt8` | `DS8` |
| `unsignedInt16 BE/LE` | `DU16` |
| `signedInt16 BE/LE` | `DS16` |
| `unsignedInt32 BE/LE` | `DU32` |
| `signedInt32 BE/LE` | `DS32` |
| `float32 BE/LE` | `DF32` |
| `float64 BE/LE` | `DF64` |
| `bytes len` | `DBytes` |
| `string len` | `DString` |
| `succeed val` | `DSucceed` |
| `fail` | `DFail` |
| `map f d` | `DMap` |
| `map2 f d1 d2` | `DMap2` |
| `map3 f d1 d2 d3` | `DMap3` |
| `map4 ...` | `DMap4` |
| `map5 ...` | `DMap5` |
| `andThen f d` | `DAndThen` |
| `loop ...` | `DCountLoop` / `DSentinelLoop` |

## Loop Support

Decoder loops are recognized in two forms:

**Count Loop**: When the loop count is known (from a previously decoded value or constant):
```elm
DCountLoop CountSource DecoderNode
```

**Sentinel Loop**: When the loop terminates on a sentinel value:
```elm
DSentinelLoop Int DecoderNode  -- sentinel value, item decoder
```

These are lowered to `scf.while` loops in MLIR with cursor threading.

## LLVM Lowering

The BF dialect is lowered to LLVM in `BFToLLVM.cpp`:

1. `!bf.cursor` → `{ i8*, i8* }` struct
2. `bf.alloc` → `eco_alloc_bytebuffer(size)` runtime call
3. `bf.write_*` → pointer dereference + endian swap + advance
4. `bf.read_*` → bounds check + dereference + endian swap + advance
5. Endian swaps use `llvm.bswap` intrinsic when needed

## Performance Benefits

1. **No interpreter overhead**: Direct cursor operations instead of closure interpretation
2. **Static width computation**: Buffer allocation is exact, no reallocation
3. **Inlined operations**: Byte writes become simple stores
4. **Bounds check hoisting**: Single check for known-size decoders
5. **Better LLVM optimization**: Fused ops expose more optimization opportunities

## Relationship to Other Passes

- **Requires**: MonoGraph with resolved kernel calls
- **Enables**: Efficient byte encoding/decoding without kernel interpreter
- **Falls back to**: C++ kernel implementation (`BytesExports.cpp`) when fusion fails

## See Also

- [MLIR Generation Theory](pass_mlir_generation_theory.md) — Integration point for fusion
- [EcoToLLVM Theory](pass_eco_to_llvm_theory.md) — BF dialect lowering to LLVM
