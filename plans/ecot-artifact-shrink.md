# `.ecot` Artifact Shrink

## Problem

`.ecot` files (one per compiled Elm module, holding the `TypedModuleArtifact` consumed by the Monomorphization phase) carry a substantial amount of data that is written by the encoder but never read by any consumer downstream of deserialization. The biggest offender is `LocalGraph.main`'s `Dynamic` variant, which serializes a full flags-decoder `Expr` tree per `main`-module; per-`Node` deps sets and `ModuleTypeEnv.aliases` add steady per-module overhead.

A separate investigation (chat transcript, 2026-05-22) traced every field in the wire format to its post-deserialization consumers and identified eight items with zero readers. This plan removes those bytes from the on-disk format.

## Scope

**Phase 1 — wire-format only.** Hard break the encoder/decoder pair. No backwards compatibility, no `.ecot` versioning. AST type definitions, producers (LocalOpt), and consumers (Monomorphize, GraphAssembly) are untouched. On decode, dropped fields are reconstructed locally with `Nothing` / `Dict.empty` / `EverySet.empty` / sentinel constants.

A future Phase 2 (separate plan, not in scope here) could drop these fields from the in-memory AST types — that would also reduce Fresh-module memory pressure but is much more invasive.

## Items to drop from the wire format

| # | Location | Field | Reconstruction on decode |
|---|----------|-------|--------------------------|
| 1 | `LocalGraph` | `main : Maybe (Main Name)` | `Nothing` |
| 2 | `LocalGraph` | `fields : Dict Name Int` | `Dict.empty` |
| 3 | `ModuleTypeEnv` | `aliases : Dict Name Can.Alias` | `Dict.empty` |
| 4 | `Node.Define` | `deps : EverySet Global` | `EverySet.empty` |
| 5 | `Node.TrackedDefine` | `deps : EverySet Global` | `EverySet.empty` |
| 6 | `Node.Cycle` | `deps : EverySet Global` | `EverySet.empty` |
| 7 | `Node.Kernel` | `chunks : List K.Chunk`, `deps : EverySet Global` | `[]`, `EverySet.empty` |
| 8 | `Node.Manager` | `effectsType : EffectsType` | `Cmd` (placeholder; Specialize ignores) |
| 9 | `Node.PortIncoming` | `deps : EverySet Global` | `EverySet.empty` |
| 10 | `Node.PortOutgoing` | `deps : EverySet Global` | `EverySet.empty` |
| 11 | `Expr.VarDebug` | `home : IO.Canonical`, `unhandledValueName : Maybe Name` | `IO.Canonical Pkg.core "Debug"`, `Nothing` |

## Items deliberately NOT touched in this round

- `Tracked*` regions (`TrackedDefine`, `TrackedVarLocal`, `TrackedFunction`, `TrackedRecord`) — kept on the wire for now even though the def-level region in `TrackedDefine` and the var-level region in `TrackedVarLocal` are unused by Monomorphize. Decision: preserve source-location data until a separate pass revisits regions.
- Per-`Name` keying of `annotations` and `schemeRoots` in `LocalGraph` — re-keyed by Global on merge, but the indirection itself is left alone.
- Any AST type definition. Phase 1 is wire-format only.

## Decision log

| Question | Decision |
|----------|----------|
| Hard break vs. emit-empty placeholders? | **Hard break.** No backwards compatibility. Drop the bytes. |
| Bump a `.ecot` format version / cache-invalidation salt? | **Not relevant.** Out of scope. |
| Include type-level removal (in-memory shrink)? | **No.** Phase 1 = wire format only. Phase 2 is a separate plan. |
| Coordinate with `streaming-bytecode-encoder.md`? | **No.** This plan lands first. |
| Drop `Tracked*` regions? | **No.** Keep regions on the wire. |
| Measure first, then decide which items to drop? | **No.** Commit to all eight; impact measured separately. |
| `VarDebug.home` sentinel value on decode? | `IO.Canonical Pkg.core "Debug"` (matches the canonicalizer's natural value; any choice is fine since Specialize hardcodes `"Elm" / "Debug"`). |

## Steps

### Step 0 — Pre-flight: re-verify dead set

Before touching any encoder, re-grep each candidate on current HEAD to confirm no consumer has been added since the original investigation. The investigation report is the source of truth; this is a sanity check.

- `\.main\b` reads on `TOpt.LocalGraph` — expect only the encoder.
- post-deserialization reads of `moduleEnv.aliases` — expect none.
- `data.fields` reads on TOpt graphs — expect only `GraphAssembly.addTypedLocalGraph` (which just unions, never inspects values).
- `deps` / `EverySet Global` reads in `Compiler/Monomorphize/*`, `Compiler/MonoInlineSimplify/*`, `Compiler/MonoGlobalOptimize/*` — expect only pattern-match `_` discards.
- `Manager`'s `EffectsType` consumers — expect only `LocalOpt.Typed.Module` (producer) and the encoder.
- `Kernel`'s `chunks` / `deps` consumers — expect only the encoder and `LocalOpt`.
- `VarDebug` `home` / `unhandledValueName` reads — expect only the encoder; Specialize destructures with `_`.

If any of these turns up a real reader, that item drops from the list and the plan is updated before continuing.

### Step 1 — `Compiler/AST/TypedOptimized.elm` — `localGraphEncoder` / `localGraphDecoder`

Drop the `main` and `fields` slots from the wire layout. New sequence is `nodes, annotations, schemeRoots`.

```elm
localGraphEncoder (LocalGraph data) =
    Bytes.Encode.sequence
        [ BE.assocListDict compareGlobal globalEncoder nodeEncoder data.nodes
        , BE.stdDict BE.string Can.annotationEncoder data.annotations
        , schemeRootsEncoder data.schemeRoots
        ]

localGraphDecoder =
    Bytes.Decode.map3
        (\nodes annotations schemeRoots ->
            LocalGraph
                { main = Nothing
                , nodes = nodes
                , fields = Dict.empty
                , annotations = annotations
                , schemeRoots = schemeRoots
                }
        )
        (BD.assocListDict toComparableGlobal globalDecoder nodeDecoder)
        (BD.stdDict BD.string Can.annotationDecoder)
        schemeRootsDecoder
```

The `mainEncoder` / `mainDecoder` helpers become unused — delete them (and the `Main` import path stays clean since the constructor is still used in-memory by `LocalOpt.Typed.Module`).

### Step 2 — `Compiler/AST/TypedOptimized.elm` — `nodeEncoder` / `nodeDecoder`

Edit per variant. Wire-format tags stay the same (so the dispatch byte is unchanged); only the payload shortens.

| Tag | Variant | New wire payload |
|-----|---------|-------------------|
| 0 | `Define` | `expr, type` (drop deps) |
| 1 | `TrackedDefine` | `region, expr, type` (drop deps) |
| 3 | `Ctor` | (unchanged) |
| 4 | `Enum` | (unchanged) |
| 5 | `Box` | (unchanged) |
| 6 | `Link` | (unchanged) |
| 7 | `Cycle` | `names, valueDefs, funcDefs` (drop deps) |
| 8 | `Manager` | *(empty)* — decoder reconstructs `Manager Cmd` |
| 9 | `Kernel` | *(empty)* — decoder reconstructs `Kernel [] EverySet.empty` |
| 10 | `PortIncoming` | `expr, type` (drop deps) |
| 11 | `PortOutgoing` | `expr, type` (drop deps) |

The `effectsTypeEncoder` / `effectsTypeDecoder` helpers become unused — delete.

### Step 3 — `Compiler/AST/TypedOptimized.elm` — `exprEncoder` / `exprDecoder`

Only `VarDebug` (tag 11) changes.

```elm
-- Encoder
VarDebug region name _home _unhandledValueName meta ->
    Bytes.Encode.sequence
        [ Bytes.Encode.unsignedInt8 11
        , A.regionEncoder region
        , BE.string name
        , Can.typeEncoder meta.tipe
        ]

-- Decoder (case 11)
11 ->
    Bytes.Decode.map3
        (\region name tipe ->
            VarDebug
                region
                name
                (IO.Canonical Pkg.core Name.debug)
                Nothing
                { tipe = tipe, tvar = Nothing }
        )
        A.regionDecoder
        BD.string
        Can.typeDecoder
```

(`Name.debug` if it exists, else the literal `"Debug"`. Verify in `Compiler/Data/Name.elm`.)

### Step 4 — `Compiler/AST/TypeEnv.elm` — `moduleTypeEnvEncoder` / `moduleTypeEnvDecoder`

Drop `aliases` from the wire layout.

```elm
moduleTypeEnvEncoder env =
    Bytes.Encode.sequence
        [ ModuleName.canonicalEncoder env.home
        , BE.stdDict BE.string Can.unionEncoder env.unions
        ]

moduleTypeEnvDecoder =
    Bytes.Decode.map2
        (\home unions ->
            { home = home, unions = unions, aliases = Dict.empty }
        )
        ModuleName.canonicalDecoder
        (BD.stdDict BD.string Can.unionDecoder)
```

### Step 5 — Mirror in `globalGraphEncoder` / `globalGraphDecoder`

`Builder.Elm.Details` uses `globalGraphEncoder` for package-typed-artifacts; that path must stay consistent with the local-graph path. The shared `nodeEncoder` / `exprEncoder` already cover most of the drops via steps 2–3. The only direct change here is:

- Drop the `fields` slot from the global sequence (mirroring step 1).

New `globalGraphEncoder` sequence: `nodes, annotations, allSchemeRoots`. Decoder mirrors.

### Step 6 — Invariant note

Add a row to `design_docs/invariants.csv`:

```
ECOT_001, "On-disk .ecot is a strict subset of TypedModuleArtifact: LocalGraph.main, LocalGraph.fields, Node deps sets, Manager.EffectsType, Kernel.chunks, Kernel.deps, VarDebug.home, VarDebug.unhandledValueName, and ModuleTypeEnv.aliases are NOT serialized. Do not add a post-deserialization reader of any of these fields without first re-adding the corresponding wire-format slot."
```

Add a short comment block at the top of `Compiler/AST/TypedModuleArtifact.elm` listing the skipped fields with a pointer to `ECOT_001`.

### Step 7 — Verification

- `cmake --build build` — compiler builds clean.
- `cmake --build build --target elm-tests` — Elm front-end tests.
- `cmake --build build --target full` — full E2E (monomorphize and codegen unaffected). Single run, `2>&1 | tee /tmp/test_output.txt` per CLAUDE.md.
- Spot-check that the `LocalOpt.Typed.Module.addDefHelp` path (which still populates `LocalGraph.main` in memory) is unaffected — only the encoder/decoder changed.

## Files touched

- `compiler/src/Compiler/AST/TypedOptimized.elm` — encoder/decoder bodies only.
- `compiler/src/Compiler/AST/TypeEnv.elm` — encoder/decoder bodies only.
- `compiler/src/Compiler/AST/TypedModuleArtifact.elm` — comment block.
- `design_docs/invariants.csv` — new `ECOT_001` row.

## Non-goals

- No producer-side changes (LocalOpt continues to populate the in-memory fields).
- No consumer-side changes (Monomorphize/GraphAssembly already ignore these fields).
- No AST type changes.
- No measurement of size impact (separate exercise).
- No memory savings for Fresh modules (Phase 2 territory).
- No `.ecot` versioning / cache-invalidation handling.

## Out of scope / future plans

- Phase 2: drop the dead fields from the in-memory AST types (`LocalGraph`, `Node`, `Expr`, `ModuleTypeEnv`). That saves Fresh-module memory but requires touching producers (LocalOpt) and any code path that constructs these values.
- Revisiting `Tracked*` regions once a region-overhaul plan exists.
- Coordination with `streaming-bytecode-encoder.md`.
