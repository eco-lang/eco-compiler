module Compiler.Eco.Config exposing
    ( EcoConfig, InlineConfig, BytesFusionConfig, LogicalTypesConfig
    , MonoEngine(..), MonoConfig, LssConfig
    , default, defaultLss, decoder, hash, clamp
    , monoEngineFromString
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
    , mono : MonoConfig
    }


{-| Which monomorphizer engine to run.

  - `EngineSubst` (default): the original Dict-substitution engine
    (`Compiler.Monomorphize.Monomorphize`). Reproduces today's behaviour.
  - `EngineSolver`: the solver-based engine (`Compiler.MonoSolver.Monomorphize`).
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
  - `keyed`: lambda sets participate in specialization keys (M4+).
  - `maxSetSize`: a zonked set larger than this widens to `LTop`.
  - `maxSpecsPerGlobal`: registry budget; past it, NEW demands key set-widened.
  - `report`: render an LSS census to stderr after mono (excluded from `hash`,
    like `diffDump` — output-only).

-}
type alias LssConfig =
    { enabled : Bool
    , keyed : Bool
    , maxSetSize : Int
    , maxSpecsPerGlobal : Int
    , report : Bool
    }


{-| The built-in LSS defaults (everything off; budgets per the design doc).
-}
defaultLss : LssConfig
defaultLss =
    { enabled = False
    , keyed = False
    , maxSetSize = 8
    , maxSpecsPerGlobal = 64
    , report = False
    }


{-| Inliner / simplifier knobs (consumed by `Compiler.GlobalOpt.MonoInlineSimplify`).

  - `whitelist` is **additive**: appended to the built-in `defaultWhitelist`.
  - `blacklist` is subtracted from the effective whitelist afterward.
  - `hofThreshold` is the cost budget for candidates with a CALLED
    function-typed parameter (HOFs whose lambda argument beta-reduces away
    at the call site — plan H2). The effective budget is
    `max threshold hofThreshold`, so it can only widen eligibility.
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
    , report : Bool
    }


{-| Bytes-fusion master switch (consumed by MLIR codegen).
-}
type alias BytesFusionConfig =
    { enabled : Bool }


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
        , report = False
        }
    , bytesFusion = { enabled = True }
    , logicalTypes = { customMaxFields = 8 }
    , mono = { engine = EngineSubst, diffDump = False, validate = False, lss = defaultLss }
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
        |> D.apply (D.optionalField "mono" monoDecoder default.mono)


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
        |> D.apply (D.optionalField "report" D.bool default.inline.report)


bytesFusionDecoder : D.Decoder x BytesFusionConfig
bytesFusionDecoder =
    D.pure BytesFusionConfig
        |> D.apply (D.optionalField "enabled" D.bool default.bytesFusion.enabled)


logicalTypesDecoder : D.Decoder x LogicalTypesConfig
logicalTypesDecoder =
    D.pure LogicalTypesConfig
        |> D.apply (D.optionalField "customMaxFields" D.int default.logicalTypes.customMaxFields)


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
         , "bf="
            ++ (if cfg.bytesFusion.enabled then
                    "1"

                else
                    "0"
               )
         , "cmf=" ++ String.fromInt cfg.logicalTypes.customMaxFields
         ]
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
        )
