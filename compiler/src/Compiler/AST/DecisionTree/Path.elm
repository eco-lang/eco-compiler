module Compiler.AST.DecisionTree.Path exposing
    ( Path(..)
    , pathEncoder, pathDecoder
    )

{-| Path type for erased (untyped) decision trees.

This module defines the `Path` type used by erased decision trees, without
container type hints. It is placed in the AST layer to avoid circular
dependencies.

@docs Path
@docs pathEncoder, pathDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Data.Index as Index


{-| A path describing how to access a value within a matched pattern.

  - `Index`: Access the nth field of a tuple or constructor arguments
  - `Unbox`: Unwrap a single-constructor custom type to access its contents
  - `Empty`: The root path (the matched value itself)

-}
type Path
    = Index Index.ZeroBased Path
    | Unbox Path
    | Empty


{-| Encode a Path to bytes for serialization.
-}
pathEncoder : Path -> Bytes.Encode.Encoder
pathEncoder path_ =
    case path_ of
        Index index subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Index.zeroBasedEncoder index
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
                        Bytes.Decode.map2 Index
                            Index.zeroBasedDecoder
                            pathDecoder

                    1 ->
                        Bytes.Decode.map Unbox pathDecoder

                    2 ->
                        Bytes.Decode.succeed Empty

                    _ ->
                        Bytes.Decode.fail
            )
