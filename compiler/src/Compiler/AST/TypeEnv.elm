module Compiler.AST.TypeEnv exposing
    ( ModuleTypeEnv, GlobalTypeEnv
    , fromCanonical, fromInterfaces, emptyGlobal, emptyGlobalTypeEnv, mergeGlobalTypeEnv
    , moduleTypeEnvEncoder, moduleTypeEnvDecoder
    , globalTypeEnvEncoder, globalTypeEnvDecoder
    )

{-| Monomorphization specializes polymorphic code, and to do that it looks up
the declarations of the custom types the code uses. Typed code is written to
disk and read back by later builds, so those declarations are written
alongside it. This module holds them.

A _type environment_ is the type declarations of one module, keyed by type
name: its custom types, which the compiler calls _unions_, and its type
aliases. `ModuleTypeEnv` is the environment of one module, taken from a
canonical module by `fromCanonical`. `GlobalTypeEnv` holds the environments of
many modules, each under its module's canonical name, and `fromInterfaces`
builds one from module interfaces.

The binary codecs intern their strings through a string table, as
`Compiler.AST.StringTable` describes, and each encoding begins with its own
preamble. `moduleTypeEnvEncoder` writes a preamble for its one module;
`globalTypeEnvEncoder` writes one preamble for all of its modules. Neither
writes the aliases, so every decoded environment has an empty `aliases`, and
only an environment built in memory has any.


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
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- TYPES


{-| The type environment of one module: the custom types and type aliases it
declares, keyed by name, and `home`, the module that declares them.

`aliases` is empty in an environment read back by `moduleTypeEnvDecoder` or
`globalTypeEnvDecoder`, because the encoders do not write it.

-}
type alias ModuleTypeEnv =
    { home : ModuleName.Canonical
    , unions : Dict Name Can.Union
    , aliases : Dict Name Can.Alias
    }


{-| The type environments of many modules, keyed by canonical module name.

By convention each entry is filed under its own `home`, with
`ModuleName.toComparableCanonical` as the key projection; the type does not
enforce either.

-}
type alias GlobalTypeEnv =
    Data.Map.Dict String ModuleName.Canonical ModuleTypeEnv



-- BUILDERS


{-| Returns the type environment of a canonical module: every custom type and
type alias it declares, with the module's name as `home`.
-}
fromCanonical : Can.Module -> ModuleTypeEnv
fromCanonical (Can.Module moduleData) =
    { home = moduleData.name
    , unions = moduleData.unions
    , aliases = moduleData.aliases
    }


{-| Returns the type environment recorded in the interface of the module named
`moduleName`.

An interface records its module's package but not the module's name, so the
name is supplied, and `home` combines the two. Every custom type and alias the
interface holds is taken, whatever its visibility, as
`Compiler.Elm.Interface.extractUnion` and `extractAlias` return it.

-}
fromInterface : ModuleName.Raw -> I.Interface -> ModuleTypeEnv
fromInterface moduleName (I.Interface data) =
    { home = ModuleName.Canonical data.home moduleName
    , unions = Dict.map (\_ iUnion -> I.extractUnion iUnion) data.unions
    , aliases = Dict.map (\_ iAlias -> I.extractAlias iAlias) data.aliases
    }


{-| Returns the global type environment of the interfaces in `ifaces`, each
module named by its key in `ifaces` together with the package its interface
records.
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


{-| A global type environment holding no modules, the same value as
`emptyGlobalTypeEnv`.
-}
emptyGlobal : GlobalTypeEnv
emptyGlobal =
    Data.Map.empty


{-| A global type environment holding no modules, the same value as
`emptyGlobal`.
-}
emptyGlobalTypeEnv : GlobalTypeEnv
emptyGlobalTypeEnv =
    Data.Map.empty


{-| Returns every module's type environment from `env1` and `env2`. Where both
hold one for the same module, the one from `env1`, the first argument, is kept.
-}
mergeGlobalTypeEnv : GlobalTypeEnv -> GlobalTypeEnv -> GlobalTypeEnv
mergeGlobalTypeEnv env1 env2 =
    Data.Map.union env1 env2



-- ENCODERS


{-| Encodes a module type environment as a string-table preamble followed by
`home` and the custom types, each string written as its index in that table.

The table is built from the strings the body writes. The `aliases` are not
written, so `moduleTypeEnvDecoder` reads them back as empty.

-}
moduleTypeEnvEncoder : ModuleTypeEnv -> Bytes.Encode.Encoder
moduleTypeEnvEncoder env =
    let
        st : StringTable
        st =
            StringTable.build (StringTable.collected (collectStringsFromModuleTypeEnv env StringTable.collectAll))
    in
    Bytes.Encode.sequence
        [ StringTable.tableEncoder st
        , ModuleName.canonicalEncoderS st env.home
        , BE.stdDict (StringTable.string st) (Can.unionEncoderS st) env.unions
        ]


{-| A decoder for a module type environment written by `moduleTypeEnvEncoder`,
giving it an empty `aliases`.
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


{-| Encodes a global type environment as one string-table preamble, built from
the strings of every module, followed by each module's canonical name and its
type environment, without the aliases.

The modules are written in descending order of their
`ModuleName.toComparableCanonical` strings, as
`Utils.Bytes.Encode.assocListDict` writes a `Data.Map`; the
`ModuleName.compareCanonical` passed to it has no effect.

-}
globalTypeEnvEncoder : GlobalTypeEnv -> Bytes.Encode.Encoder
globalTypeEnvEncoder env =
    let
        st : StringTable
        st =
            StringTable.build (StringTable.collected (collectStringsFromGlobalTypeEnv env StringTable.collectAll))
    in
    Bytes.Encode.sequence
        [ StringTable.tableEncoder st
        , BE.assocListDict ModuleName.compareCanonical
            (ModuleName.canonicalEncoderS st)
            (moduleTypeEnvBodyEncoderS st)
            env
        ]


{-| A decoder for a global type environment written by `globalTypeEnvEncoder`,
in which every module's `aliases` is empty.
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


{-| Encodes a module type environment's `home` and custom types, each string
written through `st`, with no preamble and without the aliases.

In `globalTypeEnvEncoder` each module's canonical name is written twice, once as
the map key and once here as `home`.

-}
moduleTypeEnvBodyEncoderS : StringTable -> ModuleTypeEnv -> Bytes.Encode.Encoder
moduleTypeEnvBodyEncoderS st env =
    Bytes.Encode.sequence
        [ ModuleName.canonicalEncoderS st env.home
        , BE.stdDict (StringTable.string st) (Can.unionEncoderS st) env.unions
        ]


{-| Produces a decoder for a module type environment written by
`moduleTypeEnvBodyEncoderS` with the same table, giving it an empty `aliases`.
-}
moduleTypeEnvBodyDecoderS : StringTable -> Bytes.Decode.Decoder ModuleTypeEnv
moduleTypeEnvBodyDecoderS st =
    Bytes.Decode.map2
        (\home unions ->
            { home = home, unions = unions, aliases = Dict.empty }
        )
        (ModuleName.canonicalDecoderS st)
        (BD.stdDict (StringTable.stringDec st) (Can.unionDecoderS st))



-- STRING COLLECTORS


{-| Returns the collector `acc` after giving it every string
`moduleTypeEnvEncoder` writes after its preamble: the parts of `home`, and each
custom type's name and the strings of its declaration. It keeps each as its own
rule decides.
-}
collectStringsFromModuleTypeEnv : ModuleTypeEnv -> StringTable.Collector -> StringTable.Collector
collectStringsFromModuleTypeEnv env acc =
    acc
        |> ModuleName.collectStringsFromCanonical env.home
        |> (\a ->
                Dict.foldl
                    (\name union a2 ->
                        a2 |> StringTable.add name |> Can.collectStringsFromUnion union
                    )
                    a
                    env.unions
           )


{-| Returns the collector `acc` after giving it every string
`globalTypeEnvEncoder` writes after its preamble: for each module, the parts of
its canonical name and the strings of its type environment. It keeps each as
its own rule decides.
-}
collectStringsFromGlobalTypeEnv : GlobalTypeEnv -> StringTable.Collector -> StringTable.Collector
collectStringsFromGlobalTypeEnv env acc =
    Data.Map.foldl ModuleName.compareCanonical
        (\home modEnv a ->
            a
                |> ModuleName.collectStringsFromCanonical home
                |> collectStringsFromModuleTypeEnv modEnv
        )
        acc
        env
