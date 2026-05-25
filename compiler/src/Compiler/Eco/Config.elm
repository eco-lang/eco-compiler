module Compiler.Eco.Config exposing
    ( EcoConfig, InlineConfig, BytesFusionConfig, LogicalTypesConfig
    , default, decoder, hash, clamp
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
    }


{-| Inliner / simplifier knobs (consumed by `Compiler.GlobalOpt.MonoInlineSimplify`).

  - `whitelist` is **additive**: appended to the built-in `defaultWhitelist`.
  - `blacklist` is subtracted from the effective whitelist afterward.

-}
type alias InlineConfig =
    { threshold : Int
    , whitelist : List String
    , blacklist : List String
    , maxPerFunction : Int
    , fixpointIterations : Int
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
        }
    , bytesFusion = { enabled = True }
    , logicalTypes = { customMaxFields = 8 }
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


inlineDecoder : D.Decoder x InlineConfig
inlineDecoder =
    D.pure InlineConfig
        |> D.apply (D.optionalField "threshold" D.int default.inline.threshold)
        |> D.apply (D.optionalField "whitelist" (D.list D.string) default.inline.whitelist)
        |> D.apply (D.optionalField "blacklist" (D.list D.string) default.inline.blacklist)
        |> D.apply (D.optionalField "maxPerFunction" D.int default.inline.maxPerFunction)
        |> D.apply (D.optionalField "fixpointIterations" D.int default.inline.fixpointIterations)


bytesFusionDecoder : D.Decoder x BytesFusionConfig
bytesFusionDecoder =
    D.pure BytesFusionConfig
        |> D.apply (D.optionalField "enabled" D.bool default.bytesFusion.enabled)


logicalTypesDecoder : D.Decoder x LogicalTypesConfig
logicalTypesDecoder =
    D.pure LogicalTypesConfig
        |> D.apply (D.optionalField "customMaxFields" D.int default.logicalTypes.customMaxFields)


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
        [ "v1"
        , "thr=" ++ String.fromInt cfg.inline.threshold
        , "wl=" ++ String.join "," cfg.inline.whitelist
        , "bl=" ++ String.join "," cfg.inline.blacklist
        , "mpf=" ++ String.fromInt cfg.inline.maxPerFunction
        , "fpi=" ++ String.fromInt cfg.inline.fixpointIterations
        , "bf="
            ++ (if cfg.bytesFusion.enabled then
                    "1"

                else
                    "0"
               )
        , "cmf=" ++ String.fromInt cfg.logicalTypes.customMaxFields
        ]
