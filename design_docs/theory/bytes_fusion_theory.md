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
    | EOpaque MonoExpr          -- unrecognised subtree — partial-fusion escape hatch
                                -- (May 23, 2026; see "Phase 4+5" below)
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

When fusion cannot be applied (complex patterns, unsupported combinators), the regular kernel implementation is used. This ensures correctness — fusion is an optimization, not a requirement. The partial-fusion escape hatch (next section) reduces how often this whole-expression fallback fires.

## Phase 4+5: Broader Recognition and Partial-Fusion Escape Hatch *(May 23, 2026)*

The original Phase 1+2 reifier was binary: any encoder subtree it didn't recognise poisoned the whole `Bytes.encode` call back to the kernel walker. Two May-23 changes lift this:

### Phase 4+5 — Broader recognition via inliner cooperation

Bytes fusion is invoked from MLIR generation on the post-inlining IR, so the encoder shape the reifier sees depends on what the global inliner has unfolded. Two complementary `Compiler.GlobalOpt.MonoInlineSimplify` changes give the reifier the encoder structure it can actually pattern-match on:

1. **Broaden `defaultWhitelist`** with the public `elm/bytes` API constructors (`Bytes.Encode.signedInt8`/`signedInt16`/`signedInt32`, `unsignedInt8`/`16`/`32`, `float32`/`64`, `bytes`, `string`, `sequence`) plus the Eco-internal encoder/decoder helpers commonly seen in compiler-style code (e.g. `Utils.Bytes.Encode.list`). Whitelist entries bypass the inliner cost gate.
2. **Raise the per-function inliner cap** from 10 to **1000** (`Compiler/Eco/Config.elm`'s `maxPerFunction`, threaded through to `MonoInlineSimplify.maxInlinesPerFunction`). Encoder-heavy serialisers (e.g. `Compiler.AST.Optimized.exprEncoder`) routinely inline 50–100 helpers; the old 10-per-function cap throttled them long before the reifier saw a fusable shape.

The reifier's pattern set itself stays strictly general — it only matches upstream `elm/bytes` API symbols and the idiomatic `List.map` / `(::)` / `List.length` shapes. Eco-internal helpers are reached only via inlining, never by name. Plan: `plans/bytes-fusion-broader-recognition.md`.

### Partial-fusion escape hatch — `EOpaque` + `bf.write.encoder`

After the cap-1000 change, the post-inlining `eco-compiler.mlir` had ~21 `Bytes.encode` sites — but only 3 fused, because at least one HO subtree in each remaining encoder (typically `Utils.Bytes.Encode.list someEncoderFn xs` where `someEncoderFn` is a function parameter) still didn't reify. The binary failure mode meant the other ~56 primitive writes in those encoders never reached `bf.write_*`.

The escape hatch lifts the reifier from "all-or-nothing" to **"fuse what you can, delegate the rest"**:

- **`EncoderNode = ... | EOpaque MonoExpr`** — the four `reifyEncoderHelp` arms that previously returned `Nothing` now wrap the unrecognised expression as `EOpaque` (carve-outs: a single bare `Bytes.encode` call still goes through the existing kernel path; the wrapper detects the trivial-EOpaque-only case).
- **`LoopIR.Op = ... | WriteOpaque String MonoExpr`** and **`WidthExpr = ... | WOpaqueWidth MonoExpr`** — mirrors the existing `WriteUtf8` / `WStringUtf8Width` arms.
- **Two new BF ops**:
  - `bf.encoder.width` *(operand: Encoder HPtr; result: i32)* — calls `elm_encoder_size` to get the byte count this opaque subtree will need.
  - `bf.write.encoder` *(operands: `!bf.cursor`, Encoder HPtr; result: `!bf.cursor`)* — calls `elm_encoder_write_into(encoder, dst)` which reuses the existing `writeEncoder` walker against the BF cursor's destination buffer at the current offset, then advances the cursor by the returned `bytesWritten`.
- **Runtime symbols** `elm_encoder_size` and `elm_encoder_write_into` (in `elm-kernel-cpp/src/bytes/BytesExports.cpp`) — both `gc-leaf-function` (no Elm allocs). They share the underlying `writeEncoder(encoder, dst, offset&)` walker with the legacy kernel path.

The outer expression still produces a single `bf.alloc → cursor.init → writes → ReturnBuffer` sequence; opaque subtrees lower to `bf.write.encoder` calls that walk against the same buffer. The 56-ish primitive writes that previously poisoned-out now fuse, and only the irreducible HO subtree pays the kernel-walker cost.

Plan: `plans/bytes-fusion-escape-hatch.md`.

### Runtime side: zero-copy / single-copy / LOT-aware

The runtime `elm/bytes` kernel got companion changes so the fused output is cheap to produce:

- **LOT-aware top-level allocation**: `Elm_Kernel_Bytes_encode` calls `alloc::allocByteBufferBlank(totalSize)`, which routes large results through the Large-Object-Table (split-header **HEAP_026**) path. Oversize byte buffers land directly in a pinned old-gen body so they aren't evacuated on every minor GC; only the small header forwards through Cheney.
- **Zero-copy slices**: `Bytes.slice` no longer materialises a fresh leaf for sub-ranges; it builds a slice view over the existing buffer where the access pattern allows.
- **Single-copy memcpys**: the `bf.write_bytes` / `bf.write_utf8` lowerings copy directly into the destination cursor, rather than allocating an intermediate buffer.
- Stack roots are taken across `allocByteBufferBlank` (via `StackRootRangeGuard`) so the encoder tree HPointer survives the allocation that might trigger GC.

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
| anything else | `EOpaque` *(May 23, 2026)* | from `bf.encoder.width` at runtime |

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

**Type converter unification** *(Apr 17, 2026)*: `BFTypeConverter` is now unified with `EcoTypeConverter` — both map `!eco.value` → `ptr addrspace(1)`. All BF runtime LLVM declarations use `ptr<1>` for HPtr params/returns. `BF op` result types that were `i64` for HPointer-valued results are now `!eco.value` (in MLIR) / `ptr addrspace(1)` (in LLVM). `ReadUtf8OpLowering` compares `elm_utf8_decode` result against a null `ptr<1>` via `LLVM::ZeroOp` instead of an `i64` zero constant. 88 BF test `.mlir` files were updated accordingly.

**`Bytes.cpp` `readSuccess*` bitmask fix** *(Apr 2026)*: Updated 1-bit → 2-bit Tuple2 mask encoding to match the new kind-bitmap format.

**`Json.Encode` empty-string handling** *(Apr 2026)*: Now returns `""` rather than `null` for empty strings.

## Performance Benefits

1. **No interpreter overhead**: Direct cursor operations instead of closure interpretation
2. **Static width computation**: Buffer allocation is exact, no reallocation (`bf.encoder.width` handles the opaque tail dynamically)
3. **Inlined operations**: Byte writes become simple stores
4. **Bounds check hoisting**: Single check for known-size decoders
5. **Better LLVM optimization**: Fused ops expose more optimization opportunities
6. **Partial fusion** *(May 23, 2026)*: a single unrecognised HO subtree no longer poisons the whole call back to the kernel walker — only that subtree pays the kernel cost
7. **LOT-aware top-level allocation** *(May 23, 2026)*: oversize `Bytes.encode` results land in a pinned old-gen body via the HEAP_026 split-header path, avoiding minor-GC evacuation

## Relationship to Other Passes

- **Requires**: MonoGraph with resolved kernel calls; broadened inliner whitelist + cap-1000 per-function inlines for encoder helpers to unfold into reifiable shapes
- **Enables**: Efficient byte encoding/decoding without kernel interpreter
- **Falls back to**: C++ kernel implementation (`BytesExports.cpp`) when fusion fails entirely — and to `bf.write.encoder` for individual unrecognised subtrees inside an otherwise-fused expression

## See Also

- [MLIR Generation Theory](pass_mlir_generation_theory.md) — Integration point for fusion
- [EcoToLLVM Theory](pass_eco_to_llvm_theory.md) — BF dialect lowering to LLVM
- `plans/bytes-fusion-broader-recognition.md` — inliner whitelist + cap raise (Phase 4+5)
- `plans/bytes-fusion-escape-hatch.md` — `EOpaque` + `bf.write.encoder` design
