# MLIR Bytecode Format and Streaming

## Overview

The ECO compiler can emit MLIR in two formats: **text** (human-readable `.mlir`) and **binary bytecode** (compact binary `.mlir`). Bytecode is the default output format. The `--text-mlir` CLI flag selects text for debugging.

Both formats use the same `.mlir` file extension. MLIR's C++ `parseSourceFile` transparently handles both formats by inspecting the magic bytes at the start of the file — no C++ changes are needed on the consumer side.

**Files**: `compiler/src/Mlir/Bytecode/` (8 modules), `compiler/src/Compiler/Generate/MLIR/Backend.elm`, `compiler/src/Terminal/Make.elm`

## Motivation

The text MLIR output for a large compilation (e.g., compiler self-compilation: ~240 modules) can reach ~76MB. The bytecode format achieves roughly 3-5x compression over text, reducing I/O and parse time. More importantly, the **streaming bytecode encoder** avoids holding all generated `MlirOp` values in memory simultaneously — a critical property for large compilations where the full in-memory representation would peak at ~2.5GB.

## Bytecode Format

ECO targets **MLIR bytecode version 4** (pre-properties), which avoids the ODS properties segment complexity of versions 5-6. MLIR's parser supports all bytecode versions back to 0, so version 4 is fully compatible with the LLVM/MLIR toolchain.

### File Structure

```
[Magic: 0x4D 0x4C 0xEF 0x52]  ("MLïR")
[Version: varint(4)]
[Producer: "eco\0"]
[Section 0: String Table]
[Section 1: Dialect Registry]
[Section 2: Attribute/Type Data]
[Section 3: Attribute/Type Offsets]
[Section 4: IR]
```

### Encoding Primitives

**PrefixVarInt**: A variable-length unsigned integer encoding where trailing bits indicate byte count:
- `xxxxxxx1` = 7-bit value in 1 byte
- `xxxxxx10` = 14-bit value in 2 bytes
- ...up to 9 bytes for 64-bit values

**Signed VarInt**: Zigzag encoding (`(value << 1) ^ (value >> 63)`) followed by unsigned PrefixVarInt.

**Section Framing**: Each section is `[ID byte] [varint length] [content bytes]`. Aligned sections set the high bit of the ID byte and include alignment padding with marker byte `0xCB`.

### String Table (Section 0)

All strings in the module (dialect names, op names, attribute keys, symbol names, type names) are deduplicated into a single table. Each string gets a stable index. The section encodes:
1. `numStrings` varint
2. String lengths in reverse order as varints
3. Concatenated string data blob

### Dialect Registry (Section 1)

Groups operation names by dialect prefix. ECO typically uses dialects: `eco`, `bf`, `func`, `arith`, `scf`, `builtin`. Each op name is stored as a string table index with a flag indicating whether it is a registered ODS operation (always `1` for ECO).

### Attribute/Type Sections (Sections 2-3)

All unique attributes and types are deduplicated and assigned sequential indices. ECO uses the **assembly format fallback** encoding: each attribute and type is stored as its textual representation string rather than a custom binary encoding. This is simple and correct; custom binary encoding could reduce size further but would also require implementing `BytecodeDialectInterface` on the C++ side.

### IR Section (Section 4)

The core section encoding all operations, regions, and blocks.

**SSA Value Numbering**: Values are numbered sequentially within each isolated region (each `func.func` body). Block arguments and operation results receive sequential indices.

**Operation Encoding**:
```
opNameIndex: varint      (index into dialect op table)
encodingMask: byte       (bitmask: attrs|results|operands|successors|regions)
locationIndex: varint    (index into attribute table — UnknownLoc for all ops)

-- Present based on mask bits:
attrDict: varint         (attribute table index)
numResults + types: varint[]
numOperands + values: varint[]   (SSA value indices)
numSuccessors + blocks: varint[]
regionEncoding: varint   (numRegions << 1 | isIsolatedFromAbove)
regions: region[]
```

**Region Encoding**: `numBlocks` varint, `numValues` varint (total SSA values defined in the region), then encoded blocks.

**Block Encoding**: `(numOps << 1) | hasBlockArgs` varint, optional block argument types, then encoded operations.

## Streaming Architecture

The streaming encoder processes functions one at a time, matching the text streaming pipeline's memory profile:

### Phase 1: Per-Function Collection and Encoding

```
For each MonoGraph node:
    1. Generate MlirOps (Functions.generateNode)
    2. Collect strings/attrs/types/dialects into GROWING append-only tables
    3. Encode the func.func op body to Bytes
    4. Append encoded Bytes to accumulating list
    5. Discard MlirOps (eligible for GC)

Similarly for: lambdas, main entry, kernel declarations, type_table
```

### Phase 2: Module Assembly

After all functions are processed, the global tables are complete:

```
1. Encode header: magic + version + producer
2. Encode String section (from complete StringTable)
3. Encode Dialect section (from complete DialectRegistry)
4. Encode AttrType sections (from complete AttrTypeTable)
5. Encode IR section:
   a. Module block header
   b. Module op (builtin.module)
   c. Module region containing all pre-encoded func bytes
6. Write assembled bytes to output file
```

### Why Append-Only Tables Preserve Index Validity

The key insight enabling streaming: each table is append-only.

- **StringTable**: Indices are assigned by `addString`. Once assigned, an index never changes. Function A's strings get indices 0..N; function B's new strings get N+1..M. Function A's encoded IR references indices 0..N, which remain valid.
- **AttrTypeTable**: Same append-only property. New attributes and types get new indices; existing indices are stable.
- **DialectRegistry**: Op names are collected incrementally with the same stability guarantee.

Because `func.func` bodies are **isolated regions** in MLIR, each function's bytecode is a self-contained section that references global tables only by index. The indices assigned during encoding remain valid when the tables grow.

### Memory Profile

| Mode | Peak Memory | Notes |
|------|-------------|-------|
| Text streaming | ~200MB | Writes text chunks per function |
| Bytecode (batch) | ~2.5GB | Holds all MlirOps until encode completes |
| **Bytecode (streaming)** | ~100-200MB | Tables (~50MB) + largest single function's MlirOps |

The streaming bytecode encoder achieves batch-equivalent output quality with text-streaming-equivalent memory usage.

## Module Organization

```
compiler/src/Mlir/Bytecode/
├── Encode.elm          -- Top-level: MlirModule -> Bytes (batch, ~89 lines)
├── StreamEncode.elm    -- Streaming: per-func collection + assembly (~300 lines)
├── VarInt.elm          -- PrefixVarInt + zigzag signed encoders (~251 lines)
├── Section.elm         -- Section framing with alignment (~117 lines)
├── StringTable.elm     -- String dedup + collection (~299 lines)
├── DialectSection.elm  -- Dialect + op-name registry (~284 lines)
├── AttrType.elm        -- Attribute/type encoding + offsets (~644 lines)
└── IrSection.elm       -- SSA-numbered op/region/block encoding (~732 lines)
```

## Pipeline Integration

**CLI flag**: `--text-mlir` (registered in `Terminal/Main.elm`, parsed in `Terminal/Make.elm`)

**Decision point** in `Terminal/Make.elm` `handleMlirOutput`:
```elm
if ctx.textMlir then
    Generate.writeMonoMlirStreaming ...        -- text streaming path
else
    Generate.writeMonoMlirStreamingBytecode ... -- bytecode streaming (default)
```

**C++ consumers** (`ecoc.cpp`, `eco-boot.cpp`, `EcoRunner.cpp`) all use:
```cpp
auto module = parseSourceFile<ModuleOp>(sourceMgr, &context);
```
This is format-transparent. No C++ changes were needed to support bytecode input.

**Test suite**: The `ECO_TEXT_MLIR` environment variable forces text format in E2E tests:
```cpp
// test/TestSuite.hpp
inline std::string getTextMlirFlag() {
    const char* env = std::getenv("ECO_TEXT_MLIR");
    return (env && std::string(env) != "0") ? " --text-mlir" : "";
}
```

## Design Decisions

### Version 4 (Not 6)

MLIR bytecode version 6 requires handling the Properties section and `kNativePropertiesODSSegmentSize`. ECO dialect ops do not use ODS properties (no `Properties` in `Ops.td`), so version 4 avoids this complexity entirely. MLIR's parser is fully backward-compatible.

### Assembly Format Fallback for Types

Rather than implementing custom binary encoders for ECO dialect types (`!eco.value`, `!bf.cursor`, etc.), all types are encoded as their textual assembly format string. This is slightly larger but much simpler. Custom encoding would also require a `BytecodeDialectInterface` on the C++ side.

### UnknownLoc for All Operations

The text MLIR printer does not emit source locations. The bytecode encoder matches this by using `UnknownLoc` for all operations. Real source locations could be added in the future for improved debugging.

### Same File Extension

Both text and bytecode use `.mlir`. MLIR tools detect the format from magic bytes. This avoids downstream build script changes and keeps the pipeline simple.
