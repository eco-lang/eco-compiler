module Compiler.AST.TypedModuleArtifact exposing
    ( TypedModuleArtifact
    , typedModuleArtifactEncoder, typedModuleArtifactDecoder
    )

{-| TypedModuleArtifact represents the data stored in `.ecot` files.

This combines the typed optimization IR (LocalGraph) with the module's
type environment, allowing the monomorphization phase to access both
the optimized code and the type definitions it needs.


## Wire-format skip list (ECOT\_001)

The following fields are present in the in-memory `LocalGraph` /
`ModuleTypeEnv` types but are NOT serialized to `.ecot`. They are
reconstructed as inert defaults on decode because no consumer
downstream of deserialization reads them. Do not add a reader without
first re-adding the corresponding wire slot.

  - `LocalGraph.main` → `Nothing` on decode
  - `LocalGraph.fields` → `Dict.empty` on decode
  - `ModuleTypeEnv.aliases` → `Dict.empty` on decode
  - Per-`Node` deps sets on Define, TrackedDefine, Cycle, Kernel,
    PortIncoming, PortOutgoing → `EverySet.empty` on decode
  - `Manager`'s `EffectsType` → `Cmd` placeholder on decode
  - `Kernel`'s `chunks` and `deps` → `[]` and `EverySet.empty` on decode
  - `Expr.VarDebug`'s `home` and `unhandledValueName`
    → `IO.Canonical Pkg.core Name.debug` and `Nothing` on decode


# Types

@docs TypedModuleArtifact


# Serialization

@docs typedModuleArtifactEncoder, typedModuleArtifactDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)



-- TYPES


{-| Combined artifact for a single module containing typed IR and type definitions.
-}
type alias TypedModuleArtifact =
    { typedGraph : TOpt.LocalGraph Name
    , typeEnv : TypeEnv.ModuleTypeEnv
    }



-- SERIALIZATION


{-| Encode a typed module artifact.
-}
typedModuleArtifactEncoder : TypedModuleArtifact -> Bytes.Encode.Encoder
typedModuleArtifactEncoder artifact =
    Bytes.Encode.sequence
        [ TOpt.localGraphEncoder artifact.typedGraph
        , TypeEnv.moduleTypeEnvEncoder artifact.typeEnv
        ]


{-| Decode a typed module artifact.
-}
typedModuleArtifactDecoder : Bytes.Decode.Decoder TypedModuleArtifact
typedModuleArtifactDecoder =
    Bytes.Decode.map2 TypedModuleArtifact
        TOpt.localGraphDecoder
        TypeEnv.moduleTypeEnvDecoder
