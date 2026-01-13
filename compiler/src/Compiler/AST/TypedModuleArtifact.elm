module Compiler.AST.TypedModuleArtifact exposing
    ( TypedModuleArtifact
    , typedModuleArtifactEncoder, typedModuleArtifactDecoder
    )

{-| TypedModuleArtifact represents the data stored in `.guidato` files.

This combines the typed optimization IR (LocalGraph) with the module's
type environment, allowing the monomorphization phase to access both
the optimized code and the type definitions it needs.


# Types

@docs TypedModuleArtifact


# Serialization

@docs typedModuleArtifactEncoder, typedModuleArtifactDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt



-- TYPES


{-| Combined artifact for a single module containing typed IR and type definitions.
-}
type alias TypedModuleArtifact =
    { typedGraph : TOpt.LocalGraph
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
