# `.ecot` String Interning

## Problem

`.ecot` artifacts spend **83 % of their bytes** on string content — mostly canonical-type / module-name / def-name identifiers repeated millions of times. Measured on the post-shrink (Phase 1) corpus of 247 `.ecot` files (301.9 MB total): 251.9 MB is string bytes.

The single biggest file (`Compiler-Generate-MLIR-Expr.ecot`, 41.6 MB) has 1,785 unique strings appearing 3,247,038 times. Top offenders:

```
459,917 × "core"      459,916 × "elm"     357,644 × "String"
253,897 × "compiler"  253,897 × "eco"     200,332 × "List"
114,629 × "Dict"       94,572 × "Compiler.AST.Monomorphized"
```

Other large files show the same shape (string % between 70 and 86 %).

If each occurrence is replaced by a fixed-width index into a per-file string table at the head of the artifact, expected savings:

| | Current | After interning | Saved |
|---|---:|---:|---:|
| String bytes (corpus) | 251.9 MB | 47.1 MB | 204.8 MB (81 %) |
| Total `.ecot` bytes | 301.9 MB | 97.0 MB | 204.8 MB (**~68 %**) |

This is ~100× larger than the field-drop Phase 1 plan delivered (0.65 %).

## Strategy

Per-file string table at the head of each artifact (`.ecot` + `typed-artifacts.dat`):

```
┌────────────────────────────────────────────────┐
│ idxWidth : u8   -- 1 = u8 index, 2 = u16, 4 = u32
│ count    : u32  -- number of strings in table
│ strings  : count × { len:u32, utf8:bytes }     -- the table proper
│ body     : original artifact bytes, but every
│            `BE.string s` is replaced by an
│            index of `idxWidth` bytes
└────────────────────────────────────────────────┘
```

`idxWidth` is chosen at encode time based on `count`: u8 if ≤ 256 unique strings, u16 if ≤ 65,536, u32 otherwise. The biggest `.ecot` in the corpus has 1,785 uniques; u16 will be the universal choice in practice, but small modules drop to u8.

Per-file (not whole-program) for natural artifact decoupling — `.ecot` files are decoded independently. Whole-program interning would save more but couple the artifacts in awkward ways (any module recompile invalidates the shared table). Out of scope.

This plan **assumes Phase 1 (`ecot-artifact-shrink.md`) has landed**, since the wire format is changing on top of those drops.

## Affected files

- **New:** `compiler/src/Compiler/AST/StringTable.elm` — table type, build/encode/decode primitives, the `stringRefEncoder` / `stringRefDecoder` pair.
- **New:** `compiler/src/Compiler/AST/StringCollector.elm` (or fold into each AST module) — `collectStrings*` companions that walk every AST type and accumulate uniques.
- **Modified (every encoder/decoder that calls `BE.string` for string-payload content):**
  - `Compiler/AST/TypedOptimized.elm` — `Expr`, `Node`, `Def`, `Destructor`, `Path`, `Global`, plus the top-level local/global graph encoders.
  - `Compiler/AST/TypeEnv.elm` — `ModuleTypeEnv`, `GlobalTypeEnv`.
  - `Compiler/AST/TypedModuleArtifact.elm` — top-level wrapper.
  - `Compiler/AST/Canonical.elm` — `typeEncoder`, `annotationEncoder`, `unionEncoder`, `aliasEncoder`, `Ctor`, `FieldType`.
  - `Compiler/Elm/ModuleName.elm` — `canonicalEncoder`, the dominant string-emitter.
  - `Compiler/Elm/Kernel.elm` — `chunkEncoder`.
  - `Compiler/AST/Utils/Shader.elm` — `sourceEncoder`.
  - `Compiler/AST/DecisionTree/Test.elm` — `testEncoder`.
  - `Compiler/AST/DecisionTree/TypedPath.elm` — `pathEncoder`.
  - `Compiler/Reporting/Annotation.elm` — `locatedEncoder` (carries `Name = String`).
  - `Builder/Elm/Details.elm` — `packageTypedArtifactsEncoder` calls `globalGraphEncoder` and `globalTypeEnvEncoder`.
- **Not modified:** `.eci` (interface) format, `.eco` (Opt-graph) format — different code paths, separate plan if/when wanted.

## Decision log

| Question | Decision |
|----------|----------|
| Per-file vs. whole-program table? | **Per-file.** Keeps artifacts self-contained; captures the dominant repetition (intra-file). |
| Fixed-width or varint index? | **Fixed width per file, chosen at encode time** (u8 / u16 / u32 depending on table size). Simpler than varint, almost the same compression. |
| Determinism of table order? | **Sorted alphabetically.** Required for the bootstrap byte-equality fixed-point checks (Stages 4b / 8c / 9c). |
| Apply to `.eci` / `.eco` too? | **No.** Out of scope. Smaller files, different code paths. |
| Apply to `typed-artifacts.dat` (package)? | **Yes.** Same encoder family, same shape. |
| Two-pass vs. streaming encoder? | **Two-pass.** Elm `Bytes.Encode.Encoder` is pure; threading state through a streaming writer is awkward. The cost is one extra AST walk per encode (collect step); negligible vs. monomorphization cost. |
| Interleave with Phase 1 changes? | **No.** Phase 1 lands first; this plan is incremental on top. |
| Bump format version / cache-invalidation? | **Not relevant (per project convention).** A clean cache-wipe between landings is expected. |

## Steps

### Step 0 — Land Phase 1 first

Confirm `ecot-artifact-shrink.md` is merged and the cache hazard (stale `typed-artifacts.dat` in `eco-kernel-cpp/` and `~/.eco/`, `~/.guida/`) is documented or codified. This plan builds on that wire format.

### Step 1 — `Compiler/AST/StringTable.elm`

New module exposing:

```elm
type alias StringTable =
    { strToIdx : Dict String Int       -- for encoders
    , idxToStr : Array String          -- for decoders
    , width    : Int                   -- 1, 2, or 4
    }

empty : StringTable
build : Set String -> StringTable
    -- Sorts alphabetically; assigns indices 0..n-1; picks width.

stringRefEncoder : StringTable -> String -> BE.Encoder
    -- Dict.get >> emit idx as u8/u16/u32 per table.width.

stringRefDecoder : StringTable -> BD.Decoder String
    -- Read idx as u8/u16/u32; Array.get.

tableEncoder : StringTable -> BE.Encoder
    -- u8 width, u32 count, count × length-prefixed UTF-8 strings.

tableDecoder : BD.Decoder StringTable
    -- Read width, count, strings; build idxToStr Array.
```

Crash-on-miss for `stringRefEncoder` if `Dict.get` returns `Nothing` — that would indicate a `collectStrings*` bug (an encoder emitted a string that the collector didn't visit).

### Step 2 — `collectStrings*` companion fold for each AST type

For every encoder function `xEncoder : X -> Encoder`, add a peer `collectStringsFromX : X -> Set String -> Set String` that mirrors the same case-by-case structure and inserts every string the encoder would write. Examples:

```elm
collectStringsFromExpr : TOpt.Expr Name -> Set String -> Set String
collectStringsFromExpr expr acc =
    case expr of
        Str _ value meta ->
            acc
                |> Set.insert value
                |> collectStringsFromCanType meta.tipe

        VarLocal name meta ->
            acc
                |> Set.insert name
                |> collectStringsFromCanType meta.tipe

        VarGlobal _ (Global home name) meta ->
            acc
                |> collectStringsFromCanonical home
                |> Set.insert name
                |> collectStringsFromCanType meta.tipe

        -- ...etc for all 30 Expr variants
```

These are mechanical but verbose. Single-pass; one new function per existing encoder.

### Step 3 — Refactor encoders to thread `StringTable`

Every encoder that touches a string gets a new first parameter:

```elm
-- Before:
exprEncoder : Expr Name -> BE.Encoder

-- After:
exprEncoder : StringTable -> Expr Name -> BE.Encoder
```

Inside, every `BE.string s` becomes `StringTable.stringRefEncoder table s`. Recursive calls pass `table` through.

This cascades through `Can.typeEncoder`, `Can.annotationEncoder`, `ModuleName.canonicalEncoder`, etc. Affects ~10 modules.

### Step 4 — Refactor decoders symmetrically

Every decoder that reads a string becomes table-parameterized:

```elm
-- Before:
exprDecoder : BD.Decoder (Expr Name)

-- After:
exprDecoder : StringTable -> BD.Decoder (Expr Name)
```

Inside, every `BD.string` becomes `StringTable.stringRefDecoder table`. The top-level decoder uses `andThen` to thread the table after reading it.

### Step 5 — Top-level artifact wiring

```elm
-- Compiler/AST/TypedModuleArtifact.elm

typedModuleArtifactEncoder : TypedModuleArtifact -> BE.Encoder
typedModuleArtifactEncoder artifact =
    let
        strings =
            Set.empty
                |> collectStringsFromLocalGraph artifact.typedGraph
                |> collectStringsFromModuleTypeEnv artifact.typeEnv

        table =
            StringTable.build strings
    in
    BE.sequence
        [ StringTable.tableEncoder table
        , TOpt.localGraphEncoder table artifact.typedGraph
        , TypeEnv.moduleTypeEnvEncoder table artifact.typeEnv
        ]


typedModuleArtifactDecoder : BD.Decoder TypedModuleArtifact
typedModuleArtifactDecoder =
    StringTable.tableDecoder
        |> BD.andThen
            (\table ->
                BD.map2 TypedModuleArtifact
                    (TOpt.localGraphDecoder table)
                    (TypeEnv.moduleTypeEnvDecoder table)
            )
```

Mirror for `packageTypedArtifactsEncoder` / `Decoder` in `Builder/Elm/Details.elm`.

### Step 6 — Tests and verification

- A round-trip test for a non-trivial `TypedModuleArtifact` (small synthetic + a real one read from disk).
- A determinism test: encode the same artifact twice, assert byte-equality.
- A determinism test: encode after permuting AST construction order (still alphabetical table → still byte-equal).
- `cmake --build build` — compiler builds clean.
- `cmake --build build --target elm-tests`.
- `cmake --build build --target full` — E2E.
- `cmake --build build --target eco-compiler-mlir` — Stage 5 baseline parity (MLIR output should be byte-identical pre/post).
- `cmake --build build --target bootstrap` — full fixed-point chain. Stages 4b / 8c / 9c byte-equality must still hold, otherwise table ordering is non-deterministic.

### Step 7 — Measure

Re-run the `/work/ecot-sizes.csv` measurement (clear caches, baseline Stage 5, intern, re-Stage 5) and append a third column. Update the report. Expected ~68 % reduction.

### Step 8 — Invariant note

Add a row to `design_docs/invariants.csv`:

```
ECOT_002;Builder;ArtifactSerialization;enforced;.ecot and typed-artifacts.dat files
begin with a string-table preamble: u8 idxWidth (1|2|4), u32 count, count ×
length-prefixed UTF-8 strings in alphabetical order, followed by a body in
which every string field is encoded as an idxWidth-byte index into the table.
collectStrings* must visit exactly the same strings the encoders emit;
mismatches crash at encode time via stringRefEncoder's missing-key check.
String-table order is alphabetical for bootstrap fixed-point reproducibility.
(Added 2026-MM-DD);Compiler/AST/StringTable.elm|Compiler/AST/TypedOptimized.elm
```

And update the comment block in `TypedModuleArtifact.elm` (already pointing to `ECOT_001`) to also cite `ECOT_002`.

## Non-goals

- No change to `.eci` (interface) or `.eco` (Opt-graph) formats — separate work, separate plan if wanted.
- No whole-program shared string table — per-file only.
- No further wire-format changes beyond the string-table preamble.
- No removal of any AST type or behavioral change to encoders/decoders beyond the redirection through `StringTable`.

## Risks / open questions

1. **Encode-time cost.** Two-pass AST walk doubles encode work. Mitigation: the collection pass is structurally identical to the encoder and roughly the same constant factor as the existing encode; combined cost should still be a small fraction of monomorphization. If profiling shows a hot path, consider an alternative writer that collects and emits in one pass (more code, harder to maintain).

2. **`Set String` build cost.** A 1.8 M-occurrence file produces a Set of 1,785 entries — fine. Larger files (hypothetical) would scale with number of *unique* strings, not occurrences.

3. **Determinism.** Sort the unique strings alphabetically before assigning indices. The bootstrap byte-equality checks (Stages 4b, 8c, 9c) will catch any non-determinism. The most likely failure mode is iterating an Elm `Dict`'s `keys` in insertion order rather than sorted order — must convert to a sorted list explicitly.

4. **`collectStrings*` drift.** Every time a new string field is added to an AST type, both the encoder *and* the collector must be updated. Static checking does not catch a missed insert. Mitigation: keep encoder and collector co-located (same module, adjacent functions, identical case-statement structure); the missing-key crash in `stringRefEncoder` catches drift at encode time, not at compile time.

5. **Interaction with package-typed-artifacts caching.** `typed-artifacts.dat` files written under `eco-kernel-cpp/` and `~/.eco/` will be invalid after the format change. Document the cache-clear command on the merge note; do not bother with a version byte (per project convention).

6. **Index width promotion mid-encoding.** Width is fixed for the entire body. If a corner case turned up a >65k-unique file, encode falls back to u32 silently. Decode reads the width byte first and uses the right size. No special-case needed.

7. **Could we go further with a varint?** Saves ~25 % on small tables vs fixed u8/u16/u32. Not worth the complexity at this stage — fixed-width is already a >65 % reduction.
