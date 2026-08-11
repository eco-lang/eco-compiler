module Compiler.Eco.Config exposing
    ( EcoConfig, InlineConfig, BytesFusionConfig, LogicalTypesConfig, CafMemoConfig, CafHoistConfig
    , MonoEngine(..), MonoConfig, LssConfig
    , BorrowConfig, BorrowReify(..)
    , ListConfig
    , default, defaultLss, decoder, hash, clamp
    , monoEngineFromString, borrowReifyFromString
    )

{-| Project-level tunable compiler settings, read from `eco-config.json`
beside `elm.json`. Pure data + decoder + a stable cache key; the IO that
reads the file lives in `Builder.Eco.Config`.

All fields are optional in the JSON and merge over `default`, so a partial
or absent config reproduces the built-in behaviour exactly.


# Types

@docs EcoConfig, InlineConfig, BytesFusionConfig, LogicalTypesConfig


# Values

@docs default, decoder, hash, clamp

-}

import Compiler.Json.Decode as D


{-| The full effective configuration.
-}
type alias EcoConfig =
    { inline : InlineConfig
    , bytesFusion : BytesFusionConfig
    , logicalTypes : LogicalTypesConfig
    , cafMemo : CafMemoConfig
    , mono : MonoConfig
    , borrow : BorrowConfig
    , list : ListConfig
    , aggPromote : Bool -- U-T1.3.1 (plans/opt-tier1-aggregate-promotion.md): emit eco.make.tuple2/3 for let-bound tuples proven non-escaping by the per-def use walk; DEFAULT-ON since 2026-08-04 (ship config); env ECO_AGG_PROMOTE=0 disables; artifact-affecting (hash token "aggp")
    , ctorInline : Bool -- U-T1.3.2c (plans/opt-tier1-aggregate-promotion.md): saturated direct ctor calls emit eco.construct.custom inline in the caller (call overhead erased; nullary excluded — CAF-memoized singletons); DEFAULT-ON since 2026-08-04 (ship config); env ECO_CTOR_INLINE=0 disables; artifact-affecting (hash token "ctori")
    , sretResults : Bool -- U-T1.3.3 (plans/opt-tier1-aggregate-promotion.md): result promotion via the sret ABI — functions returning a locally-constructed tuple2/3 gain a multi-result $sret worker (caller-slot ABI, CGEN_067); destructuring call sites migrate per-site; DEFAULT-ON since 2026-08-04 (ship config); env ECO_SRET_RESULTS=0 disables; artifact-affecting (hash token "sretr")
    , psplitParams : Bool -- U-T1.3.5 (plans/opt-tier1-aggregate-promotion.md): param-side promotion — projection-only tuple2/3 / single-ctor-custom params gain a $psplit worker taking the fields as scalars; call sites with free-slot args migrate per-site; DEFAULT-ON since 2026-08-04 (ship config); env ECO_PSPLIT_PARAMS=0 disables; artifact-affecting (hash token "psplit")
    , sretFresh : Bool -- U-T1.3.8: widen sretResults selection to helper-mediated results — a result leaf that IS a direct call to an already-promoted callee with identical slots is admissible (selection fixpoint); emission feeds the multi-result $sret call through. DEFAULT-ON since 2026-08-04 (user decision; measured neutral, Run M); env ECO_SRET_FRESH=0 disables; artifact-affecting when enabled (hash token "sretf=1"); no-op unless sretResults
    , sretTailFuncs : Bool -- U-T1.3.6: widen sretResults selection to tail funcs (result columns through the while loop). DEFAULT-ON since 2026-08-04 (user decision, ACCEPTING the measured ~+4% wall self-compile regression — 2026-08-03 isolation A/B: it cancelled T1.3.3's −4% exactly; per-iteration slot-column carry in hot loops); env ECO_SRET_TAILFUNC=0 disables; artifact-affecting when enabled (hash token "srtf=1"); no-op unless sretResults
    , stringLengthOp : Bool -- kernel-opt-04: emit eco.string.length (an inline header-size load) instead of the Elm_Kernel_String_length call. DEFAULT-ON since 2026-08-11 (all 101 self-compile call sites convert; wall FLAT at -0.12%, so it ships for the deleted calls and statepoints, not a measured win); env kill switch ECO_STRING_LENGTH_OP=0; artifact-affecting (hash token "strlen=1" when enabled). The BACKEND knob ECO_STRING_LEN_INLINE=0 separately chooses a plain kernel call as the lowering, needing no compiler rebuild
    , appendSplit : Bool -- kernel-opt-05: split Elm_Kernel_Utils_append into typed eco.string.append / eco.list.append at mono sites that statically know the operand type. DEFAULT-ON since 2026-08-11 (3,468 self-compile sites -> 67; 2,695 string + 706 list; wall FLAT at +0.80%, so it ships for the typed boundary and the deleted runtime dispatch, not a measured win); env kill switch ECO_APPEND_SPLIT=0; artifact-affecting (hash token "apsplit=1" when enabled). Polymorphic residue (any MVar operand) keeps the kernel call
    , stringOrderIntrinsic : Bool -- kernel-opt-06: lower Utils.lt/le/gt/ge on [MString,MString] to eco.string.cmp3 + a SIGNED sign test against 0, instead of the boxed kernel call + eco.unbox. DEFAULT-ON since 2026-08-11 (95 of 121 sites convert: lt 79->14, gt 40->10, ge 2->2; wall FLAT at -0.34%); env kill switch ECO_STRING_ORDER_INTRINSIC=0; artifact-affecting (hash token "strord=1")
    }


{-| Chunked-list knobs (plans/chunked-list-representation.md §6).
`chunks = True` (the default since the quiet-window wall verdict, Aug 3
2026: parity wall, lower minor-GC time and RSS, −4.28% objects) enables
hybrid chunk spines; `chunks = False` (JSON `"chunks": false` or env
`ECO_LIST_CHUNKS=0`) reproduces the pre-chunk pipeline byte-for-byte.
`chunks` is artifact-affecting (hash token `lchunks=1` when enabled; L1.2+
codegen consults it). `consIntrinsic` (kernel-opt-01, DEFAULT TRUE since 2026-08-10) lowers saturated
`x :: xs` to `eco.construct.list` instead of `Elm_Kernel_List_cons*`, so each
cons pays the HEAP_034 inline nursery bump instead of a statepointed runtime
call; env kill switch `ECO_LIST_CONS_INTRINSIC=0`, artifact-affecting (hash
token `lcons=1` when enabled). Measured on the self-compile: all 4,304 kernel
cons call sites convert, EcoListTemplate chunk parity is exact, and wall is
FLAT (+0.36%, inside the noise band) — it ships for the deleted call sites and
statepoints, not for a measured wall win. `report` (env `ECO_LIST_REPORT=1`, never from JSON)
renders the combinator-recognition census to stderr — output-only,
excluded from `hash`.
-}
type alias ListConfig =
    { chunks : Bool
    , consIntrinsic : Bool
    , report : Bool
    }


{-| Borrow-inference (GlobalOpt Phase 6) knobs (design §6, D2: top-level,
engine-agnostic). `enabled = False` reproduces today's pipeline byte-for-byte
(the pass is not run). `reify = ROff` runs the analysis as an inert census
oracle (graph returned unchanged); `RRc` (unused until B4) emits RC ops.
`report`/`validate` are output-only and excluded from `hash`.

`oracleOpt` (OC0.1, plans/borrow-oracle-consumers.md; env `ECO_BORROW_OPT=1`)
opts a build into the oracle-coupled transforms (OC1+): the distilled facts
are derived at MLIR-emission time (`Borrow.deriveFacts`) and consumed by
codegen. ARTIFACT-AFFECTING — the only borrow knob in `hash` (token
`bopt=1`); default off preserves T1-R1 for default builds.
-}
type alias BorrowConfig =
    { enabled : Bool
    , reify : BorrowReify
    , report : Bool
    , validate : Bool
    , oracleOpt : Bool
    }


type BorrowReify
    = ROff
    | RRc


{-| Which monomorphizer engine to run.

  - `EngineSubst`: the original Dict-substitution engine
    (`Compiler.Monomorphize.Monomorphize`). Reproduces the legacy behaviour.
  - `EngineSolver` (default): the solver-based engine (`Compiler.MonoSolver.Monomorphize`).
  - `EngineDiff`: run both and assert their MonoGraph output matches — the A/B
    gate. Emits the original engine's graph so the build still succeeds.

-}
type MonoEngine
    = EngineSubst
    | EngineSolver
    | EngineDiff


{-| Monomorphizer selection + debug knobs.

`diffDump` (env `ECO_MONO_DIFF_DUMP=1`, never from JSON) makes `EngineDiff`
embed both `Debug.toString` renderings in the mismatch error for offline diff.

-}
type alias MonoConfig =
    { engine : MonoEngine
    , diffDump : Bool
    , validate : Bool -- env ECO_MONO_VALIDATE=1, never from JSON: run the MONO_029 layout-agreement validator after mono and FAIL the compile on violations (output-only, excluded from hash — a failed compile is never cached)
    , lss : LssConfig
    }


{-| Lambda-set specialization knobs (design_docs/monomorphization/
lambda-set-specialization-design.md §10). `enabled = False` must reproduce
today's pipeline byte-for-byte: every arrow annotation is `LTop` and no set
slots are minted in solver stores. Only meaningful under `EngineSolver`;
`EngineDiff` always forces it off (the subst engine cannot produce sets).

  - `enabled`: master switch (M2+).
  - `keyed`: lambda sets participate in specialization keys (M4+) — ALL
    globals.
  - `keyedGlobals`: E5 selective keying — key ONLY these globals (user format
    `author/project:Module.Name.value`, e.g. `elm/core:List.foldl`); the
    engine converts to comparable gkeys at init. Irrelevant when `keyed` is
    already True.
  - `maxSetSize`: a zonked set larger than this widens to `LTop`.
  - `maxSpecsPerGlobal`: registry budget; past it, NEW demands key set-widened.
  - `report`: render an LSS census to stderr after mono (excluded from `hash`,
    like `diffDump` — output-only).

-}
type alias LssConfig =
    { enabled : Bool
    , keyed : Bool
    , keyedGlobals : List String
    , devirtFnGlobals : Bool
    , maxSetSize : Int
    , maxSpecsPerGlobal : Int
    , report : Bool
    }


{-| The built-in LSS defaults (budgets per the design doc).

`enabled = True` means **solver implies LSS** (H3, 2026-07-14): the solver
engine — now the `mono.engine` default (2026-07-22) — consults this block, so
default builds get lambda-set specialization without extra flags. The subst
engine never consults this block, so `ECO_MONO_ENGINE=subst` builds are
unaffected.

`keyed = True` (2026-07-20, post-Fix-B): ALL-GLOBALS keying is the default.
Sound since LSS_017 fork-qualified members (`plans/lss-fork-qualified-members.md`
— the singleton-representative hijack is fixed by construction) and measured
free at run time (Run M, `benchmarks/runtime-calls.md`: coverage 6.81 % →
13.22 %, identical total events, wall parity). `ECO_MONO_LSS=unkeyed` restores
the selective-whitelist mode (`keyedGlobals`); `ECO_MONO_LSS=0` disables LSS
entirely. Watch item: the elm-aws-codegen pathological-workload class (§11.7
census note) — the M4 `maxSpecsPerGlobal` budget is the backstop.
-}
defaultLss : LssConfig
defaultLss =
    { enabled = True
    , keyed = True
    , keyedGlobals = defaultKeyedGlobals
    , devirtFnGlobals = True
    , maxSetSize = 8
    , maxSpecsPerGlobal = 64
    , report = False
    }


{-| The default selective-keying set (Tier 1, 2026-07-20): the elm/core List
fold chain. E5 shipped keying default-empty because Run F measured zero
payoff; E9.2's kernel devirt is what unlocked it — the hot cons dispatches
live inside these SHARED fold specs, and per-set keyed fan-out is what
mints their `{k|List.cons}` singletons. Measured: −143.7 M dispatch
events/run (Run J) at zero wall cost (Run J + the Tier-1 A/B: keyed ≈
unkeyed, equal major-GC counts). Chain-keyed per the Run-F selection rule
(an unkeyed middle like `foldrHelper` re-joins the sets).
`ECO_MONO_LSS_KEYED_GLOBALS` REPLACES this list — set it empty to unkey.
-}
defaultKeyedGlobals : List String
defaultKeyedGlobals =
    [ "elm/core:List.foldl"
    , "elm/core:List.foldr"
    , "elm/core:List.foldrHelper"
    , "elm/core:List.map"
    ]


{-| Inliner / simplifier knobs (consumed by `Compiler.GlobalOpt.MonoInlineSimplify`).

  - `whitelist` is **additive**: appended to the built-in `defaultWhitelist`.
  - `blacklist` is subtracted from the effective whitelist afterward.
  - `hofThreshold` is the cost budget for candidates with a CALLED
    function-typed parameter (HOFs whose lambda argument beta-reduces away
    at the call site — plan H2). The effective budget is
    `max threshold hofThreshold`, so it can only widen eligibility.
  - `loopify` enables recursive-HOF loopification (plan H5): a saturated
    call of a tail-recursive function passing a lambda LITERAL is rewritten
    to a local specialized loop with the lambda beta-inlined — the closure
    allocation disappears (and EcoPAPSimplify elides the loop shell).
  - `raiseAppliedShareMin` (H6.2.5 Lever 2, percent 0–100): raise a staged
    spec only when at least this share of its saturated-call results are
    APPLIED (callee position, per the U0 site census). Escaping results
    (returned / let-bound / arg / stored) pay a PAP-extend per stage when
    raised, so escape-dominated specs are better left staged. `0` (the
    default) raises every qualifying spec — exactly the pre-H6.2.5
    behaviour. Only meaningful when `arityRaise` is on.
  - `report` renders the inline census to stderr after the pass
    (`ECO_INLINE_REPORT=1`); output-only, never affects `hash`.

-}
type alias InlineConfig =
    { threshold : Int
    , whitelist : List String
    , blacklist : List String
    , maxPerFunction : Int
    , fixpointIterations : Int
    , hofThreshold : Int
    , loopify : Bool
    , arityRaise : Bool
    , raiseAppliedShareMin : Int
    , report : Bool
    }


{-| Bytes-fusion master switch (consumed by MLIR codegen).
-}
type alias BytesFusionConfig =
    { enabled : Bool }


{-| CAF-memoization master switch (consumed by MLIR codegen —
plans/caf-memoization-implementation.md, design_docs/caf-memoization-design.md).
`enabled = True` gives every qualifying nullary value thunk (`MonoDefine`
non-closure, `!eco.value` ABI result, non-trivial body) a lazy once-init
`eco.global` slot: the thunk body runs at most once per process and every
later reference returns the cached value. `ECO_CAF_MEMO=0` is the env escape.
Compile-time only: the guard is baked into generated code, so there is no
runtime toggle.
-}
type alias CafMemoConfig =
    { enabled : Bool
    , census : Bool -- env ECO_CAF_CENSUS=1: inner-CAF opportunity census over the final MonoGraph (CafCensus.elm); output-only, excluded from hash
    , dedupe : Bool -- env ECO_CAF_DEDUPE=1: merge structurally identical nullary specs onto one canonical spec (CafDedupe.elm); artifact-affecting → hash token cafd=1 when on
    , hoist : CafHoistConfig
    }


{-| CAF hoisting knobs (plans/caf-hoist-closed-expressions.md): closed
expressions inside function bodies are hoisted to fresh nullary specs and
memoized by the CGEN_068 slot machinery.

  - `enabled`: master switch (env `ECO_CAF_HOIST=1|0`); artifact-affecting →
    hash token `cafh=1` when on.
  - `minNodes`: original-subtree size floor (DQ1; env
    `ECO_CAF_HOIST_MIN_NODES`); token `cafhN=` when non-default and on.
  - `maxHoists`: global mint budget safety valve (DQ1; env
    `ECO_CAF_HOIST_MAX`); token `cafhM=` when non-default and on.

-}
type alias CafHoistConfig =
    { enabled : Bool
    , minNodes : Int
    , maxHoists : Int
    }


{-| Logical-type codegen knobs.

  - `customMaxFields`: max fields a single-ctor custom may have to be eligible
    for unboxed-aggregate cross-spec. Clamped to `[1,24]` (24 is the heap ABI
    hard cap) by `clamp`.

-}
type alias LogicalTypesConfig =
    { customMaxFields : Int }


{-| The built-in defaults. These reproduce today's hardcoded behaviour.
-}
default : EcoConfig
default =
    { inline =
        { threshold = 10
        , whitelist = []
        , blacklist = []
        , maxPerFunction = 1000
        , fixpointIterations = 4

        -- H2 matrix (2026-07-13, self-compile workload): 25 gives +35%
        -- betaForwards over 10 at +2.7% code size and no measurable
        -- compile-time cost; 40 costs +9.6% size for the next step.
        , hofThreshold = 25
        , loopify = True

        -- H6.2 U2b (EXPERIMENTAL, ECO_ARITY_RAISE=1): uncurry staged
        -- specs whose stage-1 work is trivial/cheap so monadic-bind
        -- chains merge and beta away. Default OFF: delaying a cheap pure
        -- stage-1 body to application time is unobservable in Elm modulo
        -- ⊥-timing and Debug.log ordering.
        , arityRaise = False

        -- H6.2.5 Lever 2: 0 = raise everything (pre-Lever-2 behaviour).
        -- The M3 census sweep picks any nonzero default.
        , raiseAppliedShareMin = 0
        , report = False
        }
    , bytesFusion = { enabled = True }
    , logicalTypes = { customMaxFields = 8 }
    , cafMemo = { enabled = True, census = False, dedupe = False, hoist = { enabled = False, minNodes = 3, maxHoists = 8192 } }
    , mono = { engine = EngineSolver, diffDump = False, validate = False, lss = defaultLss }
    , borrow = { enabled = False, reify = ROff, report = False, validate = False, oracleOpt = False }
    , list = { chunks = True, consIntrinsic = True, report = False }

    -- The ENTIRE tier-1 family DEFAULT-ON since 2026-08-04 (user
    -- decision, reversing the same-day default-off verdict). Ship config
    -- (aggp+ctori+sretr+psplit) measured −3.2/−3.3% wall same-day
    -- interleaved (Runs J/K); sretFresh measured neutral (Run M);
    -- sretTailFuncs carries a measured ~+4% wall self-compile regression
    -- (Runs J/K isolation A/B) — accepted by the same decision. Each
    -- flag's env var =0 disables individually.
    , aggPromote = True
    , ctorInline = True
    , sretResults = True
    , psplitParams = True
    , sretFresh = True
    , sretTailFuncs = True
    , stringLengthOp = True
    , appendSplit = True
    , stringOrderIntrinsic = True
    }


{-| Decode an `eco-config.json` document. Every field is optional and merges
over `default`; unknown fields (including `version`) are ignored. Never emits
a custom failure, so the problem type is left polymorphic.
-}
decoder : D.Decoder x EcoConfig
decoder =
    D.pure EcoConfig
        |> D.apply (D.optionalField "inline" inlineDecoder default.inline)
        |> D.apply (D.optionalField "bytesFusion" bytesFusionDecoder default.bytesFusion)
        |> D.apply (D.optionalField "logicalTypes" logicalTypesDecoder default.logicalTypes)
        |> D.apply (D.optionalField "cafMemo" cafMemoDecoder default.cafMemo)
        |> D.apply (D.optionalField "mono" monoDecoder default.mono)
        |> D.apply (D.optionalField "borrow" borrowDecoder default.borrow)
        |> D.apply (D.optionalField "list" listDecoder default.list)
        |> D.apply (D.optionalField "aggPromote" D.bool default.aggPromote)
        |> D.apply (D.optionalField "ctorInline" D.bool default.ctorInline)
        |> D.apply (D.optionalField "sretResults" D.bool default.sretResults)
        |> D.apply (D.optionalField "psplitParams" D.bool default.psplitParams)
        |> D.apply (D.optionalField "sretFresh" D.bool default.sretFresh)
        |> D.apply (D.optionalField "sretTailFuncs" D.bool default.sretTailFuncs)
        |> D.apply (D.optionalField "stringLengthOp" D.bool default.stringLengthOp)
        |> D.apply (D.optionalField "appendSplit" D.bool default.appendSplit)
        |> D.apply (D.optionalField "stringOrderIntrinsic" D.bool default.stringOrderIntrinsic)


{-| Decode the `list` block. Only `chunks` is JSON-configurable; `report`
is env-only (`ECO_LIST_REPORT=1`).
-}
listDecoder : D.Decoder x ListConfig
listDecoder =
    D.pure (\chunks consIntrinsic -> { chunks = chunks, consIntrinsic = consIntrinsic, report = default.list.report })
        |> D.apply (D.optionalField "chunks" D.bool default.list.chunks)
        |> D.apply (D.optionalField "consIntrinsic" D.bool default.list.consIntrinsic)


{-| Decode the `inline` block. `report` is env-only in spirit but accepted
from JSON for convenience; it never affects `hash`.
-}
inlineDecoder : D.Decoder x InlineConfig
inlineDecoder =
    D.pure InlineConfig
        |> D.apply (D.optionalField "threshold" D.int default.inline.threshold)
        |> D.apply (D.optionalField "whitelist" (D.list D.string) default.inline.whitelist)
        |> D.apply (D.optionalField "blacklist" (D.list D.string) default.inline.blacklist)
        |> D.apply (D.optionalField "maxPerFunction" D.int default.inline.maxPerFunction)
        |> D.apply (D.optionalField "fixpointIterations" D.int default.inline.fixpointIterations)
        |> D.apply (D.optionalField "hofThreshold" D.int default.inline.hofThreshold)
        |> D.apply (D.optionalField "loopify" D.bool default.inline.loopify)
        |> D.apply (D.optionalField "arityRaise" D.bool default.inline.arityRaise)
        |> D.apply (D.optionalField "raiseAppliedShareMin" D.int default.inline.raiseAppliedShareMin)
        |> D.apply (D.optionalField "report" D.bool default.inline.report)


bytesFusionDecoder : D.Decoder x BytesFusionConfig
bytesFusionDecoder =
    D.pure BytesFusionConfig
        |> D.apply (D.optionalField "enabled" D.bool default.bytesFusion.enabled)


cafMemoDecoder : D.Decoder x CafMemoConfig
cafMemoDecoder =
    D.pure CafMemoConfig
        |> D.apply (D.optionalField "enabled" D.bool default.cafMemo.enabled)
        |> D.apply (D.optionalField "census" D.bool default.cafMemo.census)
        |> D.apply (D.optionalField "dedupe" D.bool default.cafMemo.dedupe)
        |> D.apply (D.optionalField "hoist" cafHoistDecoder default.cafMemo.hoist)


cafHoistDecoder : D.Decoder x CafHoistConfig
cafHoistDecoder =
    D.pure CafHoistConfig
        |> D.apply (D.optionalField "enabled" D.bool default.cafMemo.hoist.enabled)
        |> D.apply (D.optionalField "minNodes" D.int default.cafMemo.hoist.minNodes)
        |> D.apply (D.optionalField "maxHoists" D.int default.cafMemo.hoist.maxHoists)


logicalTypesDecoder : D.Decoder x LogicalTypesConfig
logicalTypesDecoder =
    D.pure LogicalTypesConfig
        |> D.apply (D.optionalField "customMaxFields" D.int default.logicalTypes.customMaxFields)


{-| Decode the `borrow` block. `reify` is a string `"off"|"rc"`; `report`/
`validate` are accepted from JSON for convenience but never affect `hash`.
`oracleOpt` (OC0.1) is artifact-affecting (hash token `bopt=1`).
-}
borrowDecoder : D.Decoder x BorrowConfig
borrowDecoder =
    D.pure
        (\enabled reifyStr report validate oracleOpt ->
            { enabled = enabled
            , reify = Maybe.withDefault default.borrow.reify (borrowReifyFromString reifyStr)
            , report = report
            , validate = validate
            , oracleOpt = oracleOpt
            }
        )
        |> D.apply (D.optionalField "enabled" D.bool default.borrow.enabled)
        |> D.apply (D.optionalField "reify" D.string "off")
        |> D.apply (D.optionalField "report" D.bool default.borrow.report)
        |> D.apply (D.optionalField "validate" D.bool default.borrow.validate)
        |> D.apply (D.optionalField "oracleOpt" D.bool default.borrow.oracleOpt)


{-| Parse a borrow-reify mode name (case-insensitive). `Nothing` on unknown.
-}
borrowReifyFromString : String -> Maybe BorrowReify
borrowReifyFromString s =
    case String.toLower (String.trim s) of
        "off" ->
            Just ROff

        "rc" ->
            Just RRc

        _ ->
            Nothing


{-| Decode the `mono` block. Only `engine` is JSON-configurable; an unrecognized
string falls back to the default. `diffDump` is env-only (never from JSON).
-}
monoDecoder : D.Decoder x MonoConfig
monoDecoder =
    D.pure
        (\s lss ->
            { engine = Maybe.withDefault default.mono.engine (monoEngineFromString s)
            , diffDump = default.mono.diffDump
            , validate = default.mono.validate
            , lss = lss
            }
        )
        |> D.apply (D.optionalField "engine" D.string "subst")
        |> D.apply (D.optionalField "lss" lssDecoder defaultLss)


{-| Decode the `mono.lss` block. `report` is env-only in spirit but accepted
from JSON for convenience; it never affects `hash`.
-}
lssDecoder : D.Decoder x LssConfig
lssDecoder =
    D.pure LssConfig
        |> D.apply (D.optionalField "enabled" D.bool defaultLss.enabled)
        |> D.apply (D.optionalField "keyed" D.bool defaultLss.keyed)
        |> D.apply (D.optionalField "keyedGlobals" (D.list D.string) defaultLss.keyedGlobals)
        |> D.apply (D.optionalField "devirtFnGlobals" D.bool defaultLss.devirtFnGlobals)
        |> D.apply (D.optionalField "maxSetSize" D.int defaultLss.maxSetSize)
        |> D.apply (D.optionalField "maxSpecsPerGlobal" D.int defaultLss.maxSpecsPerGlobal)
        |> D.apply (D.optionalField "report" D.bool defaultLss.report)


{-| Parse a monomorphizer-engine name (case-insensitive), used by both the JSON
decoder and the `ECO_MONO_ENGINE` env override. `Nothing` on an unknown value.
-}
monoEngineFromString : String -> Maybe MonoEngine
monoEngineFromString s =
    case String.toLower (String.trim s) of
        "subst" ->
            Just EngineSubst

        "solver" ->
            Just EngineSolver

        "diff" ->
            Just EngineDiff

        _ ->
            Nothing


{-| Clamp values that have hard bounds, returning the corrected config plus any
warning messages to surface to the user. Currently guards
`logicalTypes.customMaxFields` against the `[1,24]` heap ABI range.
-}
clamp : EcoConfig -> ( EcoConfig, List String )
clamp cfg =
    let
        cmf =
            cfg.logicalTypes.customMaxFields
    in
    if cmf < 1 || cmf > 24 then
        let
            clamped =
                Basics.clamp 1 24 cmf
        in
        ( { cfg | logicalTypes = { customMaxFields = clamped } }
        , [ "eco-config.json: logicalTypes.customMaxFields "
                ++ String.fromInt cmf
                ++ " is out of range [1,24]; clamped to "
                ++ String.fromInt clamped
                ++ "."
          ]
        )

    else
        ( cfg, [] )


{-| A stable, canonical key for the effective config, used to invalidate caches
when the config changes. Comparison is plain string equality; an absent file
(decoded as `default`) hashes identically to an explicit defaults file.
-}
hash : EcoConfig -> String
hash cfg =
    String.join "|"
        ([ "v1"
         , "thr=" ++ String.fromInt cfg.inline.threshold
         , "wl=" ++ String.join "," cfg.inline.whitelist
         , "bl=" ++ String.join "," cfg.inline.blacklist
         , "mpf=" ++ String.fromInt cfg.inline.maxPerFunction
         , "fpi=" ++ String.fromInt cfg.inline.fixpointIterations
         , "hthr=" ++ String.fromInt cfg.inline.hofThreshold
         , "loop="
            ++ (if cfg.inline.loopify then
                    "1"

                else
                    "0"
               )
         , "bf="
            ++ (if cfg.bytesFusion.enabled then
                    "1"

                else
                    "0"
               )
         , "cmf=" ++ String.fromInt cfg.logicalTypes.customMaxFields
         ]
            -- CAF-memoization token appears when ENABLED (the default):
            -- enabling changes generated MLIR, so the new default must
            -- invalidate every pre-feature cache once. ECO_CAF_MEMO=0
            -- hashes like the pre-feature world and can share its caches.
            ++ (if cfg.cafMemo.enabled then
                    [ "cafm=1" ]

                else
                    []
               )
            -- CAF-dedupe token appears ONLY when enabled (default-off), so
            -- default configs hash exactly as before. Artifact-affecting:
            -- deduping rewrites spec references in generated MLIR.
            ++ (if cfg.cafMemo.dedupe then
                    [ "cafd=1" ]

                else
                    []
               )
            -- CAF-hoist tokens (plans/caf-hoist-closed-expressions.md DQ9):
            -- artifact-affecting, so they key caches when the pass is on;
            -- knob tokens only when non-default so default-on configs share.
            ++ (if cfg.cafMemo.hoist.enabled then
                    "cafh=1"
                        :: ((if cfg.cafMemo.hoist.minNodes /= default.cafMemo.hoist.minNodes then
                                [ "cafhN=" ++ String.fromInt cfg.cafMemo.hoist.minNodes ]

                             else
                                []
                            )
                                ++ (if cfg.cafMemo.hoist.maxHoists /= default.cafMemo.hoist.maxHoists then
                                        [ "cafhM=" ++ String.fromInt cfg.cafMemo.hoist.maxHoists ]

                                    else
                                        []
                                   )
                           )

                else
                    []
               )
            -- Arity-raise token appears ONLY when enabled, so default
            -- configs hash exactly as before (no global cache invalidation).
            -- The applied-share threshold (H6.2.5 Lever 2) joins only when
            -- nonzero AND raising is on — it changes which specs raise, so
            -- it must invalidate flag-on caches, and only those.
            ++ (if cfg.inline.arityRaise then
                    "ar=1"
                        :: (if cfg.inline.raiseAppliedShareMin > 0 then
                                [ "arm=" ++ String.fromInt cfg.inline.raiseAppliedShareMin ]

                            else
                                []
                           )

                else
                    []
               )
            -- Engine token appears ONLY for non-default engines, so a default
            -- config (or any absent eco-config.json) hashes exactly as before.
            ++ (case cfg.mono.engine of
                    EngineSubst ->
                        []

                    EngineSolver ->
                        [ "mono=solver" ]

                    EngineDiff ->
                        [ "mono=diff" ]
               )
            -- LSS tokens appear ONLY for non-default values (report excluded:
            -- output-only, never affects artifacts).
            ++ (let
                    lss =
                        cfg.mono.lss
                in
                List.concat
                    [ if lss.enabled then
                        [ "lss=1" ]

                      else
                        []
                    , if lss.keyed then
                        [ "lssK=1" ]

                      else
                        []
                    , if List.isEmpty lss.keyedGlobals then
                        []

                      else
                        -- E5 selective keying: sorted so equivalent configs
                        -- share artifacts regardless of listing order.
                        [ "lssKG=" ++ String.join "," (List.sort lss.keyedGlobals) ]
                    , if lss.devirtFnGlobals then
                        [ "lssDF=1" ]

                      else
                        []
                    , if lss.maxSetSize /= defaultLss.maxSetSize then
                        [ "lssS=" ++ String.fromInt lss.maxSetSize ]

                      else
                        []
                    , if lss.maxSpecsPerGlobal /= defaultLss.maxSpecsPerGlobal then
                        [ "lssB=" ++ String.fromInt lss.maxSpecsPerGlobal ]

                      else
                        []
                    ]
               )
            -- Chunked-list token appears ONLY when enabled (the default since
            -- Aug 3 2026), so chunked and non-chunked artifacts key separate
            -- cache entries. Artifact-affecting: L1.2+ codegen consults it
            -- (plans/chunked-list-representation.md).
            ++ (if cfg.list.chunks then
                    [ "lchunks=1" ]

                else
                    []
               )
            -- kernel-opt-01: the cons intrinsic changes emitted code, so the
            -- token appears ONLY when enabled and flag-off builds keep every
            -- existing cache entry.
            ++ (if cfg.list.consIntrinsic then
                    [ "lcons=1" ]

                else
                    []
               )
            -- Aggregate-promotion token appears ONLY when enabled (the default
            -- since 2026-08-04, U-T1.3.1): promoting rewrites tuple constructs
            -- to eco.make.* in generated MLIR, so flag-on artifacts must never
            -- share flag-off caches; explicitly-disabled configs hash exactly
            -- like the historical default-off caches.
            ++ (if cfg.aggPromote then
                    [ "aggp=1" ]

                else
                    []
               )
            -- Ctor-inlining token, same posture as aggp: appears only when
            -- enabled (the default since 2026-08-04, U-T1.3.2c) — flag-on
            -- artifacts must never share flag-off caches; explicitly-disabled
            -- configs hash exactly like the historical default-off caches.
            ++ (if cfg.ctorInline then
                    [ "ctori=1" ]

                else
                    []
               )
            ++ (if cfg.sretResults then
                    [ "sretr=1" ]

                else
                    []
               )
            ++ (if cfg.psplitParams then
                    [ "psplit=1" ]

                else
                    []
               )
            ++ (if cfg.sretFresh then
                    [ "sretf=1" ]

                else
                    []
               )
            ++ (if cfg.sretTailFuncs then
                    [ "srtf=1" ]

                else
                    []
               )
            -- kernel-opt-04: eco.string.length emission rewrites the generated
            -- MLIR, so flag-on artifacts must never share flag-off caches;
            -- explicitly-disabled configs hash exactly like today's defaults.
            ++ (if cfg.stringLengthOp then
                    [ "strlen=1" ]

                else
                    []
               )
            -- kernel-opt-05: the typed append ops rewrite emitted MLIR, so
            -- flag-on artifacts must never share flag-off caches.
            ++ (if cfg.appendSplit then
                    [ "apsplit=1" ]

                else
                    []
               )
            -- kernel-opt-06: String ordering rewrites emitted MLIR.
            ++ (if cfg.stringOrderIntrinsic then
                    [ "strord=1" ]

                else
                    []
               )
            -- Borrow-oracle opt-in token (OC0.1, plans/borrow-oracle-
            -- consumers.md): the FIRST artifact-affecting borrow knob — the
            -- rest of the borrow block (enabled/reify/report/validate) stays
            -- hash-inert. Appears ONLY when enabled (default-off), so every
            -- existing config hashes exactly as before; opt builds must never
            -- share caches with default builds.
            ++ (if cfg.borrow.oracleOpt then
                    [ "bopt=1" ]

                else
                    []
               )
        )
