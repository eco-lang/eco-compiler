module Compiler.AST.TypedModuleArtifact exposing
    ( TypedModuleArtifact
    , typedModuleArtifactEncoder, typedModuleArtifactDecoder
    )

{-| Monomorphization needs, for each module, both its typed optimized code and
the definitions of the custom types that code names, and this module bundles
the two into the one value that a module's `.ecot` file holds. An `.ecot` file
is the per-module typed artifact, written when the module is compiled and read
back when code is generated.

The file is the local graph, as `Compiler.AST.TypedOptimized.localGraphEncoder`
writes it, followed by the module type environment, as
`Compiler.AST.TypeEnv.moduleTypeEnvEncoder` writes it. Each carries its own
string-table preamble.

Decoding is not a round trip. Some parts of the graph and the type environment
are not written and come back as empty or placeholder values; the docstrings of
`Compiler.AST.TypedOptimized` and `Compiler.AST.TypeEnv` list them. Code that
reads one of those parts from a decoded artifact needs it to be written first.


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


{-| One module's typed artifact: its typed local graph and its type environment.
-}
type alias TypedModuleArtifact =
    { typedGraph : TOpt.LocalGraph Name
    , typeEnv : TypeEnv.ModuleTypeEnv
    }



-- SERIALIZATION


{-| Produces an encoder writing `artifact` in the `.ecot` layout: the graph,
then the type environment.
-}
typedModuleArtifactEncoder : TypedModuleArtifact -> Bytes.Encode.Encoder
typedModuleArtifactEncoder artifact =
    Bytes.Encode.sequence
        [ TOpt.localGraphEncoder artifact.typedGraph
        , TypeEnv.moduleTypeEnvEncoder artifact.typeEnv
        ]


{-| A decoder for an artifact as `typedModuleArtifactEncoder` writes it. It
fails when the graph's format-version byte is not the current one.
-}
typedModuleArtifactDecoder : Bytes.Decode.Decoder TypedModuleArtifact
typedModuleArtifactDecoder =
    Bytes.Decode.map2 TypedModuleArtifact
        TOpt.localGraphDecoder
        TypeEnv.moduleTypeEnvDecoder
