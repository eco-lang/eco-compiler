module Compiler.AST.DecisionTree.TypedPath exposing
    ( Path(..), ContainerHint(..)
    , pathEncoder, pathDecoder
    , containerHintEncoder, containerHintDecoder
    )

{-| Path type for typed decision trees with container hints.

This module defines the `Path` type used by typed decision trees, including
`ContainerHint` information for type-aware backends (MLIR/native).

@docs Path, ContainerHint
@docs pathEncoder, pathDecoder
@docs containerHintEncoder, containerHintDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE


{-| Indicates what kind of container an Index navigates into.
This is used by typed/monomorphized backends to pick the right projection op.
-}
type ContainerHint
    = HintList
    | HintTuple2
    | HintTuple3
    | HintCustom Name.Name -- Constructor name for layout lookup
    | HintUnknown


{-| A path describing how to access a value within a matched pattern.

  - `Index`: Access the nth field of a container with a hint about container type
  - `Unbox`: Unwrap a single-constructor custom type to access its contents
  - `Empty`: The root path (the matched value itself)

-}
type Path
    = Index Index.ZeroBased ContainerHint Path
    | Unbox Path
    | Empty


{-| Encode a ContainerHint to bytes for serialization.
-}
containerHintEncoder : ContainerHint -> Bytes.Encode.Encoder
containerHintEncoder hint =
    case hint of
        HintList ->
            Bytes.Encode.unsignedInt8 0

        HintTuple2 ->
            Bytes.Encode.unsignedInt8 1

        HintTuple3 ->
            Bytes.Encode.unsignedInt8 2

        HintCustom ctorName ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.string ctorName
                ]

        HintUnknown ->
            Bytes.Encode.unsignedInt8 4


{-| Decode a ContainerHint from bytes.
-}
containerHintDecoder : Bytes.Decode.Decoder ContainerHint
containerHintDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\n ->
                case n of
                    0 ->
                        Bytes.Decode.succeed HintList

                    1 ->
                        Bytes.Decode.succeed HintTuple2

                    2 ->
                        Bytes.Decode.succeed HintTuple3

                    3 ->
                        Bytes.Decode.map HintCustom BD.string

                    _ ->
                        Bytes.Decode.succeed HintUnknown
            )


{-| Encode a Path to bytes for serialization.
-}
pathEncoder : Path -> Bytes.Encode.Encoder
pathEncoder path_ =
    case path_ of
        Index index hint subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Index.zeroBasedEncoder index
                , containerHintEncoder hint
                , pathEncoder subPath
                ]

        Unbox subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , pathEncoder subPath
                ]

        Empty ->
            Bytes.Encode.unsignedInt8 2


{-| Decode a Path from bytes.
-}
pathDecoder : Bytes.Decode.Decoder Path
pathDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Index
                            Index.zeroBasedDecoder
                            containerHintDecoder
                            pathDecoder

                    1 ->
                        Bytes.Decode.map Unbox pathDecoder

                    2 ->
                        Bytes.Decode.succeed Empty

                    _ ->
                        Bytes.Decode.fail
            )
