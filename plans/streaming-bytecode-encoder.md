# Plan: Streaming Bytecode Encoder

## Problem

The current bytecode encoder requires the full `MlirModule` in memory before
encoding. For the compiler self-compilation (~240 modules, 76MB text output),
this means holding all generated MlirOps in memory simultaneously, peaking at
~2.5GB heap. The text streaming path avoids this by writing each func's text
independently.

## Key Insight

Each `func.func` in the module body has an **isolated region**. In bytecode,
isolated regions are wrapped as self-contained sections:

```
section_id(4) + varint(section_length) + func_body_bytes
```

The `func_body_bytes` reference strings, attrs, types, and dialect ops by INDEX
into global tables. These indices are stable as long as the tables are
**append-only** (new entries don't shift existing indices).

## Architecture

### Phase 1: Stream-collect (per-func)

Process funcs one at a time, matching the text streaming pipeline:

```
For each MonoGraph node:
    1. Generate MlirOps for this func (Functions.generateNode)
    2. Collect strings/attrs/types/dialects into GROWING tables
    3. Encode the func.func op to Bytes (nameIdx + mask + loc + attrs + isolated region section)
    4. Append the encoded Bytes to an accumulating list
    5. Discard the MlirOps (GC can reclaim)
```

Similarly for lambda ops, main entry, kernel decls, type_table.

After all funcs: global tables are complete. We have a list of
pre-encoded func byte chunks and a count of total ops.

### Phase 2: Assemble (after all funcs)

```
1. Encode header: magic + version + producer
2. Encode String section (from complete StringTable)
3. Encode Dialect section (from complete DialectRegistry)
4. Encode AttrType sections (from complete AttrTypeTable — uses computeEncodedGroups)
5. Encode IR section:
   a. Module block header: varint(1 << 1)  — 1 op (module)
   b. Module op: nameIdx + mask(0x10) + locIdx + regionEncoding(3)
   c. Module region section: section_id(4) + varint(total_length)
   d. Region header: numBlocks(1) + numValues(0)
   e. Block header: varint(numOps << 1)
   f. Concatenate all pre-encoded func bytes
6. Encode empty Resource sections
7. Write everything to output file
```

### Why indices remain valid

- **StringTable**: indices are assigned incrementally by `addString`. Once assigned,
  an index never changes. Func A's strings get indices 0..N; func B's new strings
  get N+1..M. Func A's encoded IR references indices 0..N which are still valid.

- **DialectRegistry**: op names are collected from all funcs. Since the module body
  ordering is deterministic (same as text streaming), the dialect list is the same.
  BUT: currently `DialectSection.collect` scans the full MlirModule. For streaming,
  we'd need incremental collection.

- **AttrTypeTable**: same append-only property as StringTable. New attrs get new
  indices; existing indices don't shift.

### What changes

| Component | Current | Streaming |
|-----------|---------|-----------|
| `Backend.writeMlirBytecode` | Calls `generateMlirModule` (full) then `encodeModule` | New streaming pipeline: generate+encode per func |
| `StringTable` | `collect : MlirModule -> StringTable` | `collectOp : MlirOp -> StringTable -> StringTable` (already exists as internal fn) |
| `DialectSection` | `collect : MlirModule -> DialectRegistry` | Need `collectOp : MlirOp -> DialectRegistry -> DialectRegistry` |
| `AttrType` | `collect : MlirModule -> AttrTypeTable` | Need `collectOp : MlirOp -> AttrTypeTable -> AttrTypeTable` |
| `IrSection` | `encode : ... -> MlirModule -> BE.Encoder` | Need `encodeFuncOp : ... -> MlirOp -> Bytes` for each func |
| `Encode` | `encodeModule : MlirModule -> Bytes` | New `StreamEncoder` that accumulates tables + func bytes |

### Memory comparison

**Current (non-streaming bytecode)**:
- All MlirOps: ~2GB (held until encodeModule completes)
- Encoded Bytes: ~9.4MB
- Tables: ~50MB
- Peak: ~2.5GB

**Streaming bytecode**:
- One func's MlirOps: ~5-50MB (varies by func complexity)
- Accumulated func bytes: ~9.4MB (grows incrementally)
- Tables: ~50MB (grow incrementally)
- Peak: ~100-200MB (estimated — dominated by tables + largest single func)

### Implementation steps

1. **Extract per-op collection from StringTable/DialectSection/AttrType** — expose
   the internal `collectOp` functions so they can be called incrementally

2. **Add `encodeFuncOp`** to IrSection — encodes a single func.func to Bytes
   (numberRegion + encodeRegion + wrap in isolated section)

3. **Add module-body op encoder** — for eco.type_table and other non-func ops

4. **Create streaming pipeline** in Backend.elm — mirrors `streamMlirToWriter`
   but accumulates tables + func bytes instead of text chunks

5. **Create assembly function** — takes complete tables + list of func byte chunks,
   produces the final bytecode

6. **Wire into Generate.elm** as `writeMonoMlirStreamingBytecode`

### Risks

- **DenseArrayAttr encoding** creates intermediate `Bytes` values. These are
  small per-entry but accumulate.
- **The final assembly** still needs to hold all func bytes to compute the
  IR section length. Could stream to a temp file if needed.
- **Dict ordering in AttrType grouping** must be deterministic across the
  streaming and assembly phases.

### Estimated effort

~200 lines of new/modified Elm code. The main work is refactoring the collection
and encoding functions to be incremental rather than batch.
