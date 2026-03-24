# Plan: MLIR Bytecode Encoder

## Goal

Implement a binary MLIR bytecode encoder in Elm that produces the same IR as the
existing text printer (`Mlir/Pretty.elm`) but in the MLIR bytecode format (version 6,
matching LLVM/MLIR 21.1.4). Binary becomes the default output; a `--text-mlir` CLI
flag selects text format for debugging.

## Background

- **Bytecode spec:** `design_docs/mlir-docs/BytecodeFormat.md` + authoritative
  header `/opt/llvm-mlir/include/mlir/Bytecode/Encoding.h`
- **Current pipeline:** `MlirModule` → `Pretty.ppModule` → `.mlir` text → parsed
  by C++ `parseSourceFile<ModuleOp>()` in `ecoc.cpp`, `eco-boot.cpp`, `EcoRunner.cpp`
- **Key fact:** MLIR's `parseSourceFile` already handles both text and bytecode
  transparently — no C++ changes needed for reading.
- **Elm Bytes support:** `elm/bytes 1.0.8` available; `Eco.File.writeBytes` exists;
  `Builder.File.writeBinary` provides encoder→file pipeline.

## Bytecode Version 6 Details

From `Encoding.h`:
- Version 6 = `kNativePropertiesODSSegmentSize`
- Section IDs: String(0), Dialect(1), AttrType(2), AttrTypeOffset(3), IR(4),
  Resource(5), ResourceOffset(6), DialectVersions(7), Properties(8)
- Op encoding mask: attrs(0x01), results(0x02), operands(0x04), successors(0x08),
  inlineRegions(0x10), useListOrders(0x20), properties(0x40)
- Alignment byte: 0xCB

**Version 6 vs. the design doc:** The doc predates v5/v6 and omits the Properties
section (ID=8) and properties encoding mask bit. Eco dialect ops do NOT use ODS
properties (no `Properties` in `Ops.td`), so we can emit empty properties or omit
the bit entirely. We can also target version 4 or 5 to avoid properties complexity
entirely (see Question Q1).

## Architecture

```
compiler/src/Mlir/Bytecode/
├── Encode.elm         -- Top-level: MlirModule → Bytes (orchestrates all sections)
├── VarInt.elm         -- PrefixVarInt and signed zigzag encoders
├── StringTable.elm    -- String collection, dedup, and section encoding
├── DialectSection.elm -- Dialect + op-name section encoding
├── AttrType.elm       -- Attribute/type encoding + offset section
├── IrSection.elm      -- Operation/region/block encoding
└── Section.elm        -- Section framing (ID, length, alignment, padding)
```

Plus modifications to:
- `compiler/src/Compiler/Generate/CodeGen.elm` — add `BinaryOutput Bytes` variant
- `compiler/src/Compiler/Generate/MLIR/Backend.elm` — branch on format
- `compiler/src/Terminal/Make.elm` — add `--text-mlir` flag, thread through
- `compiler/src/Terminal/Main.elm` — register the new flag in make command
- `compiler/src/Builder/Generate.elm` — wire binary output path

## Implementation Steps

### Step 1: VarInt encoder (`Bytecode/VarInt.elm`)

Implement the PrefixVarInt encoding described in the bytecode spec:
- `encodeVarInt : Int -> Bytes.Encode.Encoder` — unsigned, 1-9 byte encoding
  with prefix bit pattern (xxxxxxx1 = 7 bits / 1 byte, ... 00000000 = 64 bits / 9 bytes)
- `encodeSignedVarInt : Int -> Bytes.Encode.Encoder` — zigzag encoding:
  `(value << 1) ^ (value >> 63)` then delegate to unsigned
- Unit-testable in isolation with known byte sequences

**Size:** ~80 lines

### Step 2: Section framing (`Bytecode/Section.elm`)

- `encodeSection : Int -> Bytes.Encode.Encoder -> Bytes.Encode.Encoder`
  Takes section ID and content encoder; wraps with ID byte, varint length, content.
- `encodeSectionAligned : Int -> Int -> Bytes.Encode.Encoder -> Bytes.Encode.Encoder`
  Variant with alignment (sets high bit on ID byte, adds alignment varint + 0xCB padding)
- Helper: `sectionBytes : Bytes.Encode.Encoder -> Bytes` to pre-encode content
  so we can measure its length before writing the header.

**Size:** ~60 lines

### Step 3: String table (`Bytecode/StringTable.elm`)

**Collection phase** — walk `MlirModule` and collect every string that appears:
- Dialect names: `eco`, `bf`, `func`, `arith`, `scf`, `builtin`
- Operation name suffixes (e.g., for `eco.call` → `call`)
- Attribute keys and string values (sym_name, callee, field names, etc.)
- Type names (`!eco.value`, `!bf.cursor`, struct names)
- Symbol references

Build a `Dict String Int` mapping each unique string to its index.

**Encoding phase:**
- `numStrings` varint
- Reverse string lengths as varints
- Concatenated string data blob

**Exposed API:**
- `type StringTable` (opaque)
- `collect : MlirModule -> StringTable`
- `indexOf : String -> StringTable -> Int`
- `encode : StringTable -> Bytes.Encode.Encoder`

**Size:** ~150 lines

### Step 4: Dialect section (`Bytecode/DialectSection.elm`)

**Collection:** Scan all ops in the module, group by dialect prefix.
Build registry:
- Dialect list with indices (matching string table entries)
- Op names grouped by dialect, each with string index and `isRegistered` flag

**Encoding:**
```
numDialects: varint
dialectNames: [varint(stringIdx << 1 | hasVersion)] -- no versioning for now
opNames: [dialect varint, numOps varint, [varint(nameIdx << 1 | isRegistered)]]
```

All our ops are registered (defined in ODS), so `isRegistered = 1`.

**Exposed API:**
- `type DialectRegistry` (opaque)
- `collect : MlirModule -> StringTable -> DialectRegistry`
- `opIndex : String -> DialectRegistry -> Int` (global op name → index)
- `encode : DialectRegistry -> Bytes.Encode.Encoder`

**Size:** ~120 lines

### Step 5: Attribute/Type sections (`Bytecode/AttrType.elm`)

**Two paired sections:**

1. `attr_type_section` — encoded representation of each unique attr/type
2. `attr_type_offset_section` — offsets grouped by dialect

**Collection:** Walk the module, deduplicate all `MlirAttr` and `MlirType` values.
Assign sequential indices (attrs first, then types).

**Encoding strategy — assembly format fallback:**
For the initial implementation, encode all attributes and types using their textual
assembly format representation (null-terminated string). This is simple and correct.
Custom bytecode encoding can be added later for size optimization.

For each attr/type:
- `hasCustomEncoding = 0` (always using assembly fallback initially)
- Content = the text representation as a string blob

Offset section groups entries by dialect with relative size offsets.

**Exposed API:**
- `type AttrTypeTable` (opaque)
- `collect : MlirModule -> StringTable -> AttrTypeTable`
- `attrIndex : MlirAttr -> AttrTypeTable -> Int`
- `typeIndex : MlirType -> AttrTypeTable -> Int`
- `encodeData : AttrTypeTable -> Bytes.Encode.Encoder`
- `encodeOffsets : AttrTypeTable -> Bytes.Encode.Encoder`

**Size:** ~200 lines

### Step 6: IR section (`Bytecode/IrSection.elm`)

The core encoder. Walks the `MlirModule` and encodes every operation, region, and
block in the bytecode IR format.

**SSA value numbering:**
Maintain a counter and assign sequential indices to:
- Block arguments (in order of appearance)
- Operation results (in order of appearance)
Value indices are scoped to the nearest isolated-from-above region (for Eco, every
`func.func` body is isolated).

**Operation encoding:**
```
name: varint (index into dialect op table)
encodingMask: byte (bitmask of present components)
location: varint (index into attribute table)

-- Optional components based on mask:
attrDict: varint (index into attribute table)
numResults: varint, resultTypes: varint[] (type table indices)
numOperands: varint, operands: varint[] (SSA value indices)
numSuccessors: varint, successors: varint[] (block indices within region)
regionEncoding: varint (numRegions << 1 | isIsolatedFromAbove)
regions: region[]
```

**Region encoding:** numBlocks varint, numValues varint (if non-empty), blocks[]

**Block encoding:** `(numOps << 1) | hasBlockArgs` varint, block_arguments?, ops[]

**What to skip initially:**
- Use-list orders (emit 0 for numUseListOrders — ordering matches reference)
- Properties section (Eco ops don't use ODS properties)

**Exposed API:**
- `encode : MlirModule -> DialectRegistry -> AttrTypeTable -> Bytes.Encode.Encoder`

**Size:** ~350 lines (largest module)

### Step 7: Top-level encoder (`Bytecode/Encode.elm`)

Orchestrates everything:

```elm
encodeModule : MlirModule -> Bytes
encodeModule mod =
    let
        stringTable = StringTable.collect mod
        dialectRegistry = DialectSection.collect mod stringTable
        attrTypeTable = AttrType.collect mod stringTable
        irEncoder = IrSection.encode mod dialectRegistry attrTypeTable
    in
    Bytes.Encode.encode <|
        Bytes.Encode.sequence
            [ -- Magic: 0x4D 0x4C 0xEF 0x52
              encodeMagic
            , -- Version: varint(6)  [or chosen target version]
              VarInt.encodeVarInt 6
            , -- Producer: null-terminated string "eco"
              encodeProducerString "eco"
            , -- Sections in order
              Section.encodeSection 0 (StringTable.encode stringTable)
            , Section.encodeSection 1 (DialectSection.encode dialectRegistry)
            , Section.encodeSection 2 (AttrType.encodeData attrTypeTable)
            , Section.encodeSection 3 (AttrType.encodeOffsets attrTypeTable)
            , Section.encodeSection 4 irEncoder
            -- Resource sections omitted (empty)
            ]
```

**Size:** ~80 lines

### Step 8: CodeGen output type extension

In `Compiler/Generate/CodeGen.elm`:
- Add `BinaryOutput Bytes` to the `Output` type
- Add `outputToBytes` function
- Update `outputToString` to handle the new variant (crash on binary)

### Step 9: Backend format branching

In `Compiler/Generate/MLIR/Backend.elm`:
- Accept a format flag (text vs binary)
- For binary: call `Bytecode.Encode.encodeModule` instead of `Pretty.ppModule`
- For streaming: use `Eco.File.writeBytes` instead of `Eco.File.hWriteString`

In `Builder/Generate.elm`:
- Add `writeMonoMlirBinary` alongside `writeMonoMlirStreaming`
- Binary path: generate full module in memory → encode to Bytes → write once
  (two-pass encoding prevents true streaming; bytecode is ~3-5x smaller than text
  so memory pressure is actually reduced)

### Step 10: CLI flag integration

In `Terminal/Make.elm`:
- Add `textMlir : Bool` field to `FlagsData`
- Keep `Output` type as-is (still `MLIR String` for path)
- Thread `textMlir` flag through to the backend

In `Terminal/Main.elm`:
- Add `Terminal.onOff "text-mlir" "Output MLIR in text format instead of binary bytecode (for debugging)"`
  to `makeFlags`
- Add `Chomp.chompOnOffFlag "text-mlir"` to the Chomp parser chain

In `Terminal/Make.elm` `handleMlirOutput`:
- If `textMlir` → use existing streaming text path
- If not → use new binary write path (default)

### Step 11: Testing & validation

**Round-trip validation** — the primary correctness test:
1. Compile an Elm program to `.mlir` (text)
2. Compile same program to `.mlir` (binary bytecode)
3. Load both with `mlir-opt` and dump as text
4. Diff outputs — must be identical

**Unit tests:**
- VarInt: known input/output pairs from the spec
- StringTable: collect from a small module, verify indices
- Section framing: verify length prefixes

**Integration:**
- Run existing E2E test suite with binary output (should pass unchanged since
  `parseSourceFile` handles both formats)
- Add a test flag to run E2E with `--text-mlir` to keep text path exercised

## Actual Size (Implemented)

| Module | Lines |
|--------|-------|
| VarInt.elm | 251 |
| Section.elm | 117 |
| StringTable.elm | 299 |
| DialectSection.elm | 284 |
| AttrType.elm | 644 |
| IrSection.elm | 732 |
| Encode.elm | 89 |
| CLI/Backend changes | ~80 |
| **Total** | **~2496** |

All modules compile cleanly. Full test suite passes (11667/11668, 1 pre-existing failure).

## Questions & Open Issues

### Q1: Target bytecode version — 4, 5, or 6?

Version 6 is current for LLVM 21.1.4 but requires handling the Properties section
and `kNativePropertiesODSSegmentSize`. Eco ops don't use ODS properties, so we could:
- **Option A:** Target version 6 with empty/absent Properties section
- **Option B:** Target version 4 (pre-properties, simpler) — `parseSourceFile`
  supports all versions back to 0
- **Option C:** Target version 5 (native properties but not ODS segment size)

**Recommendation:** Option A (version 6) — it's what the toolchain expects as current,
and we simply omit the Properties section + never set the `kHasProperties` mask bit.
But this needs validation that MLIR's reader accepts v6 bytecode without a Properties
section.

### Q2: Assembly format fallback vs custom encoding for eco types?

Using assembly format fallback (encoding `!eco.value` as the string `"!eco.value"`)
is simple and correct but larger. Custom bytecode encoding would be smaller but
requires implementing `BytecodeDialectInterface` on the C++ side too.

**Recommendation:** Start with assembly format fallback. Optimize later if bytecode
size becomes a concern.

### Q3: Memory model — full in-memory encoding vs streaming?

The two-pass requirement (collect tables, then encode) prevents true streaming of
the bytecode. Options:
- **Option A:** Encode entire module to `Bytes` in memory, write once
- **Option B:** Stream section-by-section (still need full module walk for tables)

**Recommendation:** Option A. Bytecode is significantly smaller than text (~3-5x),
so even though we hold the whole thing in memory, it uses less memory than the
current text streaming approach holds in intermediate strings.

### Q4: Location encoding

Currently `Pretty.elm` does NOT emit locations (returns empty string). For bytecode,
we need at least an `UnknownLoc` attribute in the attribute table. Should we:
- Encode all locations as `UnknownLoc` (simplest, matches current behavior)?
- Encode real source locations from `Mlir.Loc` data (more useful for debugging)?

**Recommendation:** Start with `UnknownLoc` for all operations to match current
behavior. Real locations can be added later.

### Q5: File extension convention

Should binary bytecode use `.mlir` (same extension) or `.mlirbc` (MLIR convention
for bytecode)? Using `.mlirbc` would make format detection by extension trivial
and avoid needing the `--text-mlir` flag for detection. But it changes the output
file naming.

**Recommendation:** Use `.mlir` for both (MLIR tools handle both transparently).
The `--text-mlir` flag controls which encoder is used. This minimizes downstream
build script changes.

### Q6: Interaction with `eco-boot.cpp` pipeline

`eco-boot` can accept `.elm` or `.mlir` input. When it receives `.elm`, it invokes
the Node.js frontend which outputs `.mlir`. Does `eco-boot` need any changes to
handle bytecode input? `parseSourceFile` handles both formats, so this should be
transparent — but needs verification.

### Assumptions

- A1: `Eco.File.writeBytes` works correctly for arbitrary `Bytes` values (no size limits)
- A2: MLIR's `parseSourceFile` in LLVM 21.1.4 transparently handles bytecode
  files with `.mlir` extension (not just `.mlirbc`)
- A3: Elm's `Bytes.Encode` can handle the output sizes we need (typical module
  bytecode likely 100KB-10MB range)
- A4: The eco and bf dialect ops, when registered on the C++ side via TableGen,
  are recognized as "registered" by the bytecode reader (matching our `isRegistered=1`
  encoding)
