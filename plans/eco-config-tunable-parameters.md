# eco-config.json — tunable compiler parameters

Add a project-level JSON config file (`eco-config.json`, beside `elm.json`)
that carries tunable compiler knobs — inlining threshold/whitelist, bytes-fusion
toggle, unboxed-aggregate breadth — with sane defaults when absent, an override
flag for a non-standard location, and cache invalidation when the effective
config changes.

First pass wires the config into the two consumers that matter today:
**GlobalOpt** (`MonoInlineSimplify`) and **MLIR codegen** (the bytes-fusion
entry, gated through the codegen `Context`).

## Goals / non-goals

- **Goal:** a single, typed, defaults-merged `EcoConfig` value, read once in
  `Terminal.Make`, threaded to GlobalOpt and codegen along the existing
  `Make → Generate` path.
- **Goal:** absence of the file ⇒ defaults (today's behaviour reproduced
  exactly). An explicit `--config <path>` that is missing or malformed is a
  hard error.
- **Goal:** editing the config invalidates stale builds.
- **Non-goal (this pass):** exposing every constant in the compiler. Only the
  verified-safe knobs in Table A. Hard ABI/representation constants (Table B)
  stay fixed.
- **Non-goal (this pass):** a true *inline-blacklist* that forbids inlining a
  named function. (Attempted historically for `Bytes.Encode.encode` and it
  crashed the bootstrap — see `bytes-fusion-broader-recognition.md` Phase 4.)
  `inline.blacklist` here only subtracts from the whitelist.

## Config file format

`eco-config.json` (text JSON, decoded with `Compiler.Json.Decode` exactly as
`elm.json` is — `Builder/Elm/Outline.elm:269` `File.readUtf8` + `:275`
`D.fromByteString`):

```json
{
  "version": 1,
  "inline": {
    "threshold": 10,
    "whitelist": ["My.Module.helper"],
    "blacklist": [],
    "maxPerFunction": 1000,
    "fixpointIterations": 4
  },
  "bytesFusion": {
    "enabled": true
  },
  "logicalTypes": {
    "customMaxFields": 8
  }
}
```

- Every field optional; each missing field falls back to its `default`.
- `version` gates schema evolution (warn on unknown major).
- Unknown fields are ignored (forward-compatible).
- `inline.whitelist` is **additive**: appended to the built-in `defaultWhitelist`
  (`MonoInlineSimplify.elm:222`). `inline.blacklist` is subtracted afterward:
  `effective = (defaultWhitelist ++ whitelist) − blacklist`.
- `logicalTypes.customMaxFields` is clamped to `[1, 24]` at load (24 is the heap
  ABI hard cap — Table B); out-of-range values warn and clamp.

## Module structure

### New: `Compiler/Eco/Config.elm` (pure — no IO)

Holds the typed record, `default`, and `decoder`. Pure data so both compiler
passes (`Compiler.GlobalOpt.*`, `Compiler.Generate.MLIR.*`) and the builder may
import it without a layering violation. Imports `Compiler.Json.Decode` (already
the shared JSON layer).

```elm
module Compiler.Eco.Config exposing
    ( EcoConfig, InlineConfig, BytesFusionConfig, LogicalTypesConfig
    , default, decoder, hash
    )

type alias EcoConfig =
    { inline : InlineConfig
    , bytesFusion : BytesFusionConfig
    , logicalTypes : LogicalTypesConfig
    }

type alias InlineConfig =
    { threshold : Int
    , whitelist : List String
    , blacklist : List String
    , maxPerFunction : Int
    , fixpointIterations : Int
    }

type alias BytesFusionConfig =
    { enabled : Bool }

type alias LogicalTypesConfig =
    { customMaxFields : Int }

default : EcoConfig
default =
    { inline =
        { threshold = 10
        , whitelist = []
        , blacklist = []
        , maxPerFunction = 1000
        , fixpointIterations = 4
        }
    , bytesFusion = { enabled = True }
    , logicalTypes = { customMaxFields = 8 }
    }

-- Each level uses an `optionalField name dec fallback` helper so partial JSON
-- merges over `default`. Built from Compiler.Json.Decode.
decoder : D.Decoder Exit.EcoConfigProblem EcoConfig

-- Stable digest of the *normalized, defaults-merged* config, used as the cache
-- key. Hash the EcoConfig record (e.g. via Utils.Bytes.Encode + an existing
-- digest util), NOT the raw file bytes — so reformatting / key reordering does
-- not spuriously invalidate, and "no file" hashes identically to "explicit
-- defaults".
hash : EcoConfig -> String
```

**Prerequisite:** `Compiler.Json.Decode` exposes `int`/`string`/`list`/`field`/
`oneOf` but **no `bool`** (`elm.json` never needed one). Add a small
`bool : Decoder x Bool` plus `optionalField : String -> Decoder x a -> a -> Decoder x a`.

### New: `Builder/Eco/Config.elm` (IO loader)

Builder-side because it does IO (`Builder.File`, `Builder.Stuff`). Returns a
`Task` in the same monad as the rest of the build.

```elm
loadEcoConfig : Maybe FilePath -> FilePath -> Task Exit.Make EcoConfig
loadEcoConfig maybeExplicit root =
    let
        path = Maybe.withDefault (root ++ "/eco-config.json") maybeExplicit
    in
    Utils.dirDoesFileExist path
        |> Task.andThen
            (\exists ->
                if not exists then
                    case maybeExplicit of
                        Just p  -> Task.throw (Exit.MakeConfigNotFound p)   -- explicit path must exist
                        Nothing -> Task.succeed Config.default               -- default absent ⇒ defaults
                else
                    File.readUtf8 path
                        |> Task.andThen
                            (\bytes ->
                                case D.fromByteString Config.decoder bytes of
                                    Ok cfg  -> Task.succeed (clampAndWarn cfg)
                                    Err err -> Task.throw (Exit.MakeBadConfig path err)
                            )
            )
```

## Where the file is read — `Terminal/Make.elm`

Read once, right after `Stuff.findRoot` yields the root (`Make.elm:134`), where
both `root` and the new flag are in scope. Thread the **value** (not the path)
down the existing `Make → Generate` call path, mirroring how `details` and the
destructured flags already flow.

- New flag in `FlagsData` (`Make.elm:82`): `configPath : Maybe String`, with a
  parser beside the existing `buildDir`/`output` ones (`Make.elm:~708`).
  Surface as `--config <path>`.
- Call `loadEcoConfig flagsData.configPath root` in `runWithRoot`/
  `runHelpWithScope`, bind the `EcoConfig`, and pass it into the `Generate.*`
  entry calls.

Fallback / error rules:

| Situation | Behaviour |
|---|---|
| Default path absent | silent `Config.default` |
| `--config p` given, `p` missing | hard error `Exit.MakeConfigNotFound p` |
| File present, malformed/invalid | hard error `Exit.MakeBadConfig path err` (render the `Compiler.Json.Decode` error, same as `Exit.OP_Bad*` for `elm.json`) |
| `customMaxFields` out of `[1,24]` | clamp + warning |

Two new `Exit.Make` constructors + renderers in `Builder/Reporting/Exit.elm`.

## Propagation A → GlobalOpt (`MonoInlineSimplify`)

The mono-opt pipeline is a chain of deliberately-separated top-level functions
(`Builder/Generate.elm:715-780` — split this way so JS closures don't pin the
big graphs across phases). `EcoConfig` is tiny (ints/bools/short string lists),
so passing it as a leading arg and partially applying preserves that property.

```
writeMonoMlirStreaming cfg … root …              -- Generate.elm:790  (+ cfg param)
  └ buildMonoGraph cfg root …                    -- :665              (+ cfg param)
      └ buildMonoGraphFromMerged cfg roots …     -- :701              (+ cfg param)
          └ runMonoOptPipeline cfg typed env     -- :723              (+ cfg param)
              └ Task.andThen (runInlineSimplifyPhase cfg)   -- :741   (partial-apply: cfg captured, graphs not)
                  └ runInlineSimplifyPhase cfg monoGraph0   -- :746
                      └ MonoInlineSimplify.optimize cfg.inline monoGraph0   -- :753  ← CONSUMED
```

In `Compiler/GlobalOpt/MonoInlineSimplify.elm`:

- `optimize : MonoGraph -> (MonoGraph, Metrics)` (`:103`) becomes
  `optimize : InlineConfig -> MonoGraph -> (MonoGraph, Metrics)`.
- `inlineThreshold` (`:488`, currently `10`) → `config.threshold`, threaded into
  the cost comparison (`initRewriteCtx` / the `cost <= threshold` site).
- `maxInlinesPerFunction` (`:506`, currently `1000`) → `config.maxPerFunction`
  (consumed at `:1560`).
- `maxIterations` (`:801`, currently `4`) → `config.fixpointIterations`
  (consumed in `iterate`).
- `defaultWhitelist` (`:222`) → effective whitelist set built as
  `(defaultWhitelist ++ config.whitelist) − config.blacklist`.

`buildBodyLookup` (`:67`, called from the backend) is threshold-independent —
leave it unchanged.

## Propagation B → MLIR codegen (`Context`)

Add an `ecoConfig` field to the codegen `Context`, mirroring `inlineBodies`
exactly (`Context.elm:159` field, `:204` `initContext`, `:231` `withInlineBodies`).

```elm
-- Context.elm record (:144):   , ecoConfig : Config.EcoConfig
-- initContext (:204):          , ecoConfig = Config.default
-- new helper beside withInlineBodies (:231):
withEcoConfig : Config.EcoConfig -> Context -> Context
withEcoConfig cfg ctx = { ctx | ecoConfig = cfg }
```

The backend entry functions take `cfg` and install it at each `initContext`
site (`Backend.elm:55/138/274`, installs at `:68/153/289`):

```elm
ctx =
    Ctx.initContext mode registry signatures ctorShapes
        |> Ctx.withEcoConfig cfg
        |> Ctx.withInlineBodies (MonoInlineSimplify.buildBodyLookup monoGraph0)
```

`cfg` reaches the backend straight from the `writeMonoMlirStreaming*` param (it
already calls the backend at `Generate.elm:806/829`), so `MonoBuildResult`
does **not** need a new field.

Then gate the bytes-fusion entry at the three sites in
`Compiler/Generate/MLIR/Expr.elm` (`:2412`, `:2609`, `:3119`):

```elm
if ctx.ecoConfig.bytesFusion.enabled then
    BFReify.reifyEncoderWith ctx.inlineBodies ctx.registry localCache encoderExpr
else
    Nothing          -- clean fall-through to the existing kernel-call path
```

`logicalTypes.customMaxFields`: `LogicalTypes.customMaxFields` (`:66`) is a
top-level constant consumed at `:158`. Thread `ctx.ecoConfig.logicalTypes.customMaxFields`
to that comparison (it is reached during codegen via the Context).

## Cache invalidation

**Key finding (must be understood before wiring a hash):** the config affects
only **monomorphization → inline/simplify → global-opt → MLIR codegen**, and
*none of that is cached*. `buildMonoGraph` recomputes it on every `eco make`,
and the `--output` MLIR is written **unconditionally** (`Generate.elm:800`, no
"skip if up-to-date"). Everything in `d.dat` / `.eci` / `.ecot` / typed-artifacts
is **upstream** of mono and **config-independent**. So:

- A config change already takes effect on the next `eco make` — *provided
  `eco make` is actually re-invoked*.
- The real gap is one level up: a ninja/CMake rule won't re-run `eco make` when
  only `eco-config.json` changed unless it is a declared input.

`d.dat` is the `Details` cache (`Stuff.detailsWithBuildDir`,
`…/eco-stuff/<compilerVersion>/d.dat`, `Stuff.elm:91`; read `Details.elm:468`,
written `:795`). Its only staleness test today is `detailsData.time /= newTime`
(the `elm.json` mtime) plus a typed-opt mismatch (`Details.elm:479-486`). Global
format invalidation is the `compilerVersion` path segment (`Stuff.elm:124`).

**Two-part fix:**

1. **Build-graph dependency (the actual fix).** Declare `eco-config.json` (and
   any `--config` path) as an input to the `eco make` step in CMake/ninja.
   Because `eco make` regenerates MLIR unconditionally and reuses the *valid*,
   config-independent typecheck caches, this gives correct output at minimum
   cost — no wasted re-typecheck.

2. **`configHash` in `Details` (in-compiler guarantee + future-proofing).**
   Add `configHash : String` to `DetailsData` (`Details.elm:189`); thread it
   through `detailsEncoder` (`:1914`) / `detailsDecoder` (`:1928`); compare it
   in `handleCachedDetails` (`:479`, beside the `time` check) → mismatch ⇒
   `generate`; store it in `writeVerifiedArtifacts` (`:785`). This is the
   canonical "are the caches valid for these inputs?" home and mirrors the
   existing `time` pattern. It triggers a full rebuild on config change — coarse
   (config only affects downstream stages), but config edits are rare and there
   is no finer-grained cache to key today. **Where it truly earns its keep is
   when a mono/MLIR-stage cache is later introduced** (cf. `streaming-bytecode-encoder.md`):
   that cache *must* be keyed by `configHash`.

Hash hygiene: use `Config.hash` over the normalized, defaults-merged record so
absent-file ≡ explicit-defaults and formatting changes don't invalidate.

## Signature-change checklist (full blast radius)

| File | Change |
|---|---|
| `Compiler/Eco/Config.elm` | **new** — record, `default`, `decoder`, `hash` |
| `Compiler/Json/Decode.elm` | add `bool` + `optionalField` |
| `Builder/Eco/Config.elm` | **new** — `loadEcoConfig` (IO), clamp+warn |
| `Terminal/Make.elm` | `FlagsData.configPath` (`:82`); flag parser (`~:708`); call `loadEcoConfig` after `findRoot` (`:134`); pass `cfg` into `Generate.*` entries |
| `Builder/Reporting/Exit.elm` | `MakeConfigNotFound`, `MakeBadConfig` + renderers |
| `Builder/Generate.elm` | `cfg` param on `writeMonoMlirStreaming`/`…Bytecode` (`:790/815`), `buildMonoGraph` (`:665`), `buildMonoGraphFromMerged` (`:701`), `runMonoOptPipeline` (`:723`), `runInlineSimplifyPhase` (`:746`); pass `cfg` to backend calls (`:806/829`) |
| `Compiler/GlobalOpt/MonoInlineSimplify.elm` | `optimize` takes `InlineConfig`; threshold/whitelist/maxPerFunction/fixpoint from it |
| `Compiler/Generate/MLIR/Context.elm` | `ecoConfig` field + `withEcoConfig` |
| `Compiler/Generate/MLIR/Backend.elm` | 3 entries take `cfg`, install via `withEcoConfig` |
| `Compiler/Generate/MLIR/Expr.elm` | gate the 3 `reifyEncoderWith` sites on `bytesFusion.enabled` |
| `Compiler/Generate/MLIR/LogicalTypes.elm` | read `customMaxFields` from ctx config at `:158` |
| `Builder/Elm/Details.elm` | `configHash` field, encoder/decoder, staleness check, store on write |
| CMake/ninja | `eco-config.json` as an input to the `eco make` rule |

`Builder.Build` is otherwise untouched — config affects only mono-opt + codegen.

## Tunable parameters reference

### Table A — exposed this pass (verified)

| Config key | File:line | Default | Controls |
|---|---|---|---|
| `inline.threshold` | `MonoInlineSimplify.elm:488` | `10` | Cost budget; `computeCost ≤ threshold` ⇒ inline. Primary knob. |
| `inline.whitelist` | `MonoInlineSimplify.elm:222` | `[]` | Extra qualified names bypassing the cost gate (additive). |
| `inline.blacklist` | (applied to whitelist) | `[]` | Names removed from the effective whitelist. |
| `inline.maxPerFunction` | `MonoInlineSimplify.elm:506` | `1000` | Per-function inline cap (code-explosion valve). |
| `inline.fixpointIterations` | `MonoInlineSimplify.elm:801` | `4` | Rewrite/simplify fixpoint cap. |
| `bytesFusion.enabled` | gate at `Expr.elm:2412/2609/3119` | `true` | Bytes-fusion master switch. |
| `logicalTypes.customMaxFields` | `LogicalTypes.elm:66` | `8` | Unboxed-aggregate eligibility for single-ctor customs; clamp `[1,24]`. |

Future candidates (need code changes to parameterize, not just a config field):
the fusion constant-width-loop requirement (`hasConstantWidth`, `Reify.elm:733`),
an "inline recursive shells" toggle, and exposing `Mode` (already driven by
`--optimize`/`--debug`).

### Table B — DO NOT EXPOSE (hard ABI/representation invariants)

| Constant | Invariant | Reason |
|---|---|---|
| 2-bit-per-slot unboxed bitmap | `REP_HEAP_002`, `MONO_006` | GC + C++ walker decode kinds from exactly 2 bits/slot. |
| Custom ctor ≤ 24 typed fields | `CGEN_020`, `MONO_013` | 48-bit bitmap; `EcoOps.cpp` asserts `size ≤ 24`. |
| Record ≤ 32 fields | `MONO_006` | 64-bit bitmap (32 × 2 bits). |
| Closure ≤ 26 typed captures | `CGEN_049`, `REP_CLOSURE_001` | 52-bit bitmap in `papCreate`/`papExtend`. |
| Tuple arity ≤ 3 | `MONO_006` | Enforced structurally by `MonoType`. |
| Bool not unboxable (only Int/Float/Char) | `REP_CLOSURE_001` | Bool is `!eco.value` at heap/closure/ABI boundaries. |
| Logical-type wire alphabet `i/f/c/v` | `CGEN_065` | Cross-spec C++ parser is hard-wired to it. |
| Polymorphic-kernel all-boxed ABI + suffix registry | `KernelAbi.elm` | Symbol-table consistency with declared C++ kernels. |

Note: `logicalTypes.customMaxFields` (default 8) is an Elm-side throttle *under*
the 24-field heap cap — tunable within `[1,24]`; the 24 itself is the invariant.

## Implementation steps

1. `Compiler/Json/Decode.elm`: add `bool` + `optionalField`.
2. `Compiler/Eco/Config.elm`: record, `default`, `decoder`, `hash`. Unit-test
   the decoder (partial JSON merges over defaults; malformed ⇒ error; clamp).
3. `Builder/Reporting/Exit.elm`: `MakeConfigNotFound` / `MakeBadConfig` + renderers.
4. `Builder/Eco/Config.elm`: `loadEcoConfig` + clamp/warn.
5. `Terminal/Make.elm`: `--config` flag, load after `findRoot`, thread `cfg`.
6. Propagation A: thread `cfg` through `Builder/Generate.elm` to
   `MonoInlineSimplify.optimize`; consume threshold/whitelist/maxPerFunction/
   fixpoint.
7. Propagation B: `Context.ecoConfig` + `withEcoConfig`; `Backend.elm` installs;
   gate fusion in `Expr.elm`; `LogicalTypes` reads `customMaxFields`.
8. Cache: `configHash` in `Details` (field + enc/dec + staleness + store);
   add `eco-config.json` to the CMake `eco make` rule inputs.
9. Verify defaults reproduce today's behaviour (Stage 7 bootstrap green).

## Testing

- Decoder unit tests (defaults merge, error, clamp).
- E2E with `bytesFusion.enabled = false` on a fixture that otherwise fuses:
  assert `-- CHECK-MLIR-NOT: bf.write` (the `-- CHECK-MLIR` harness exists from
  the bytes-fusion work).
- E2E with `inline.threshold` bumped: assert a previously-un-inlined helper
  disappears from the MLIR.
- Cache: edit `eco-config.json`, re-run `make`, confirm regeneration (and that
  the CMake input edge re-invokes `eco make`).
- Gates: `cmake --build build --target full`, stress, Stage 7 bootstrap
  (`eco-compiler-boot`); defaults must keep all green and within ±5% wall/RSS.

## Open decisions

1. **`whitelist` semantics** — additive to built-ins (assumed here) vs. full
   replacement. Additive is safer: the built-in elm/bytes entries are
   load-bearing for bytes-fusion.
2. **Cache depth** — ship `configHash` in `d.dat` now (full rebuild on change)
   *and* the CMake input edge, vs. defer the hash until a mono/MLIR-stage cache
   exists and rely on the build-graph edge for now. This plan includes both.

## Risks

- **Over-invalidation:** the `d.dat` `configHash` forces a full re-typecheck on
  any config change even though typecheck is config-independent. Acceptable
  because config edits are rare; revisit if iteration speed matters.
- **Signature churn:** threading `cfg` widens several `Builder/Generate.elm`
  signatures. Use partial application at the phase boundaries to preserve the
  existing JS-closure scope-separation (don't capture the big graphs).
- **Bootstrap fragility:** `Compiler.Json.Decode`/`Details` format changes touch
  the self-host path. Wipe `eco-stuff/` after the `Details` format change
  (stale caches surface as `CORRUPT CACHE`/`lookupVar` rather than honest
  failures). `compilerVersion` bump may be warranted alongside the `d.dat`
  format change.
