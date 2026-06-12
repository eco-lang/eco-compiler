module Compiler.AST.TypeEnv exposing
    ( ModuleTypeEnv, GlobalTypeEnv
    , fromCanonical, fromInterfaces, emptyGlobal, emptyGlobalTypeEnv, mergeGlobalTypeEnv
    , moduleTypeEnvEncoder, moduleTypeEnvDecoder
    , globalTypeEnvEncoder, globalTypeEnvDecoder
    )

{-| Type Environment for monomorphization.

This module defines per-module and global type environments that store
union and alias type definitions. These are extracted from canonical modules
during compilation and stored alongside typed IR artifacts.

The monomorphization phase uses these type environments to look up type
definitions when specializing polymorphic code.


# Types

@docs ModuleTypeEnv, GlobalTypeEnv


# Builders

@docs fromCanonical, fromInterfaces, emptyGlobal, emptyGlobalTypeEnv, mergeGlobalTypeEnv


# Serialization

@docs moduleTypeEnvEncoder, moduleTypeEnvDecoder
@docs globalTypeEnvEncoder, globalTypeEnvDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.AST.StringTable as StringTable exposing (StringTable)
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Data.Map
import Dict exposing (Dict)
import Set exposing (Set)
import System.TypeCheck.IO as IO
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- TYPES


{-| Per-module type environment containing union and alias definitions.
-}
type alias ModuleTypeEnv =
    { home : IO.Canonical
    , unions : Dict Name Can.Union
    , aliases : Dict Name Can.Alias
    }


{-| Global type environment mapping canonical module names to their type environments.
Uses `List String` as the comparable key for `IO.Canonical`.
-}
type alias GlobalTypeEnv =
    Data.Map.Dict String IO.Canonical ModuleTypeEnv



-- BUILDERS


{-| Extract a type environment from a canonical module.
-}
fromCanonical : Can.Module -> ModuleTypeEnv
fromCanonical (Can.Module moduleData) =
    { home = moduleData.name
    , unions = moduleData.unions
    , aliases = moduleData.aliases
    }


{-| Extract a type environment from an interface.

Takes the module name (e.g., "Elm.JsArray") and the interface, and produces
a ModuleTypeEnv suitable for monomorphization lookups.

-}
fromInterface : ModuleName.Raw -> I.Interface -> ModuleTypeEnv
fromInterface moduleName (I.Interface data) =
    { home = IO.Canonical data.home moduleName
    , unions = Dict.map (\_ iUnion -> I.extractUnion iUnion) data.unions
    , aliases = Dict.map (\_ iAlias -> I.extractAlias iAlias) data.aliases
    }


{-| Build a GlobalTypeEnv from a dictionary of interfaces.

This is useful for test infrastructure where interfaces define the types
available for monomorphization (e.g., JsArray, List, Maybe).

-}
fromInterfaces : Dict ModuleName.Raw I.Interface -> GlobalTypeEnv
fromInterfaces ifaces =
    Dict.foldl
        (\moduleName iface acc ->
            let
                moduleTypeEnv =
                    fromInterface moduleName iface
            in
            Data.Map.insert ModuleName.toComparableCanonical moduleTypeEnv.home moduleTypeEnv acc
        )
        Data.Map.empty
        ifaces


{-| Empty global type environment.
-}
emptyGlobal : GlobalTypeEnv
emptyGlobal =
    Data.Map.empty


{-| Empty global type environment (alias for emptyGlobal).
-}
emptyGlobalTypeEnv : GlobalTypeEnv
emptyGlobalTypeEnv =
    Data.Map.empty


{-| Merge two global type environments.

Module type environments from the second argument take precedence in case of conflicts.

-}
mergeGlobalTypeEnv : GlobalTypeEnv -> GlobalTypeEnv -> GlobalTypeEnv
mergeGlobalTypeEnv env1 env2 =
    Data.Map.union env1 env2



-- ENCODERS


{-| Encode a module type environment.

Per ECOT\_001 in design\_docs/invariants.csv, the `aliases` field is NOT
serialized; it is reconstructed as `Dict.empty` on decode. Aliases are
expanded during canonicalization / typed optimization, which run before
.ecot is written, so no post-deserialization consumer reads them.

Per ECOT\_002, this encoder emits a per-call string-table preamble; every
string field in the body is encoded as an index into the table.

-}
moduleTypeEnvEncoder : ModuleTypeEnv -> Bytes.Encode.Encoder
moduleTypeEnvEncoder env =
    let
        st : StringTable
        st =
            StringTable.build (collectStringsFromModuleTypeEnv env Set.empty)
    in
    Bytes.Encode.sequence
        [ StringTable.tableEncoder st
        , ModuleName.canonicalEncoderS st env.home
        , BE.stdDict (StringTable.string st) (Can.unionEncoderS st) env.unions
        ]


{-| Decode a module type environment.
-}
moduleTypeEnvDecoder : Bytes.Decode.Decoder ModuleTypeEnv
moduleTypeEnvDecoder =
    StringTable.tableDecoder
        |> Bytes.Decode.andThen
            (\st ->
                Bytes.Decode.map2
                    (\home unions ->
                        { home = home, unions = unions, aliases = Dict.empty }
                    )
                    (ModuleName.canonicalDecoderS st)
                    (BD.stdDict (StringTable.stringDec st) (Can.unionDecoderS st))
            )


{-| Encode a global type environment.
-}
globalTypeEnvEncoder : GlobalTypeEnv -> Bytes.Encode.Encoder
globalTypeEnvEncoder env =
    let
        st : StringTable
        st =
            StringTable.build (collectStringsFromGlobalTypeEnv env Set.empty)
    in
    Bytes.Encode.sequence
        [ StringTable.tableEncoder st
        , BE.assocListDict ModuleName.compareCanonical
            (ModuleName.canonicalEncoderS st)
            (moduleTypeEnvBodyEncoderS st)
            env
        ]


{-| Decode a global type environment.
-}
globalTypeEnvDecoder : Bytes.Decode.Decoder GlobalTypeEnv
globalTypeEnvDecoder =
    StringTable.tableDecoder
        |> Bytes.Decode.andThen
            (\st ->
                BD.assocListDict ModuleName.toComparableCanonical
                    (ModuleName.canonicalDecoderS st)
                    (moduleTypeEnvBodyDecoderS st)
            )


moduleTypeEnvBodyEncoderS : StringTable -> ModuleTypeEnv -> Bytes.Encode.Encoder
moduleTypeEnvBodyEncoderS st env =
    Bytes.Encode.sequence
        [ ModuleName.canonicalEncoderS st env.home
        , BE.stdDict (StringTable.string st) (Can.unionEncoderS st) env.unions
        ]


moduleTypeEnvBodyDecoderS : StringTable -> Bytes.Decode.Decoder ModuleTypeEnv
moduleTypeEnvBodyDecoderS st =
    Bytes.Decode.map2
        (\home unions ->
            { home = home, unions = unions, aliases = Dict.empty }
        )
        (ModuleName.canonicalDecoderS st)
        (BD.stdDict (StringTable.stringDec st) (Can.unionDecoderS st))



-- ====== STRING COLLECTORS (ECOT_002) ======


{-| Collect strings emitted by `moduleTypeEnvEncoder`'s body.
-}
collectStringsFromModuleTypeEnv : ModuleTypeEnv -> Set String -> Set String
collectStringsFromModuleTypeEnv env acc =
    acc
        |> ModuleName.collectStringsFromCanonical env.home
        |> (\a ->
                Dict.foldl
                    (\name union a2 ->
                        a2 |> Set.insert name |> Can.collectStringsFromUnion union
                    )
                    a
                    env.unions
           )


{-| Collect strings emitted by `globalTypeEnvEncoder`'s body.
-}
collectStringsFromGlobalTypeEnv : GlobalTypeEnv -> Set String -> Set String
collectStringsFromGlobalTypeEnv env acc =
    Data.Map.foldl ModuleName.compareCanonical
        (\home modEnv a ->
            a
                |> ModuleName.collectStringsFromCanonical home
                |> collectStringsFromModuleTypeEnv modEnv
        )
        acc
        env
