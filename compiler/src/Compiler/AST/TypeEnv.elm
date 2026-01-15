module Compiler.AST.TypeEnv exposing
    ( ModuleTypeEnv, GlobalTypeEnv
    , fromCanonical, fromInterface, fromInterfaces, emptyGlobal, emptyGlobalTypeEnv, mergeGlobalTypeEnv
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

@docs fromCanonical, emptyGlobal, emptyGlobalTypeEnv, mergeGlobalTypeEnv


# Serialization

@docs moduleTypeEnvEncoder, moduleTypeEnvDecoder
@docs globalTypeEnvEncoder, globalTypeEnvDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- TYPES


{-| Per-module type environment containing union and alias definitions.
-}
type alias ModuleTypeEnv =
    { home : IO.Canonical
    , unions : Dict String Name Can.Union
    , aliases : Dict String Name Can.Alias
    }


{-| Global type environment mapping canonical module names to their type environments.
Uses `List String` as the comparable key for `IO.Canonical`.
-}
type alias GlobalTypeEnv =
    Dict (List String) IO.Canonical ModuleTypeEnv



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
fromInterfaces : Dict String ModuleName.Raw I.Interface -> GlobalTypeEnv
fromInterfaces ifaces =
    Dict.foldl compare
        (\moduleName iface acc ->
            let
                moduleTypeEnv =
                    fromInterface moduleName iface
            in
            Dict.insert ModuleName.toComparableCanonical moduleTypeEnv.home moduleTypeEnv acc
        )
        Dict.empty
        ifaces


{-| Empty global type environment.
-}
emptyGlobal : GlobalTypeEnv
emptyGlobal =
    Dict.empty


{-| Empty global type environment (alias for emptyGlobal).
-}
emptyGlobalTypeEnv : GlobalTypeEnv
emptyGlobalTypeEnv =
    Dict.empty


{-| Merge two global type environments.

Module type environments from the second argument take precedence in case of conflicts.

-}
mergeGlobalTypeEnv : GlobalTypeEnv -> GlobalTypeEnv -> GlobalTypeEnv
mergeGlobalTypeEnv env1 env2 =
    Dict.union env1 env2



-- ENCODERS


{-| Encode a module type environment.
-}
moduleTypeEnvEncoder : ModuleTypeEnv -> Bytes.Encode.Encoder
moduleTypeEnvEncoder env =
    Bytes.Encode.sequence
        [ ModuleName.canonicalEncoder env.home
        , BE.assocListDict compare BE.string Can.unionEncoder env.unions
        , BE.assocListDict compare BE.string Can.aliasEncoder env.aliases
        ]


{-| Decode a module type environment.
-}
moduleTypeEnvDecoder : Bytes.Decode.Decoder ModuleTypeEnv
moduleTypeEnvDecoder =
    Bytes.Decode.map3 ModuleTypeEnv
        ModuleName.canonicalDecoder
        (BD.assocListDict identity BD.string Can.unionDecoder)
        (BD.assocListDict identity BD.string Can.aliasDecoder)


{-| Encode a global type environment.
-}
globalTypeEnvEncoder : GlobalTypeEnv -> Bytes.Encode.Encoder
globalTypeEnvEncoder env =
    BE.assocListDict ModuleName.compareCanonical ModuleName.canonicalEncoder moduleTypeEnvEncoder env


{-| Decode a global type environment.
-}
globalTypeEnvDecoder : Bytes.Decode.Decoder GlobalTypeEnv
globalTypeEnvDecoder =
    BD.assocListDict ModuleName.toComparableCanonical ModuleName.canonicalDecoder moduleTypeEnvDecoder
