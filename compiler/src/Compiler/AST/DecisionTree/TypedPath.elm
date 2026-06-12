module Compiler.AST.DecisionTree.TypedPath exposing
    ( Path(..), ContainerHint(..)
    , collectStringsFromPath
    , pathDecoderS, pathEncoderS
    )

{-| Path type for typed decision trees with container hints.

This module defines the `Path` type used by typed decision trees, including
`ContainerHint` information for type-aware backends (MLIR/native).

@docs Path, ContainerHint
@docs collectStringsFromPath
@docs pathDecoderS, pathEncoderS

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.StringTable as StringTable exposing (StringTable)
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Set exposing (Set)


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
containerHintEncoder : StringTable -> ContainerHint -> Bytes.Encode.Encoder
containerHintEncoder st hint =
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
                , StringTable.string st ctorName
                ]

        HintUnknown ->
            Bytes.Encode.unsignedInt8 4


{-| Decode a ContainerHint from bytes.
-}
containerHintDecoder : StringTable -> Bytes.Decode.Decoder ContainerHint
containerHintDecoder st =
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
                        Bytes.Decode.map HintCustom (StringTable.stringDec st)

                    _ ->
                        Bytes.Decode.succeed HintUnknown
            )


{-| String-interned variant of `pathEncoder`.
-}
pathEncoderS : StringTable -> Path -> Bytes.Encode.Encoder
pathEncoderS st path_ =
    case path_ of
        Index index hint subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , Index.zeroBasedEncoder index
                , containerHintEncoder st hint
                , pathEncoderS st subPath
                ]

        Unbox subPath ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , pathEncoderS st subPath
                ]

        Empty ->
            Bytes.Encode.unsignedInt8 2


{-| String-interned variant of `pathDecoder`.
-}
pathDecoderS : StringTable -> Bytes.Decode.Decoder Path
pathDecoderS st =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map3 Index
                            Index.zeroBasedDecoder
                            (containerHintDecoder st)
                            (pathDecoderS st)

                    1 ->
                        Bytes.Decode.map Unbox (pathDecoderS st)

                    2 ->
                        Bytes.Decode.succeed Empty

                    _ ->
                        Bytes.Decode.fail
            )


{-| Add string components of a Path to a collection set.
-}
collectStringsFromPath : Path -> Set String -> Set String
collectStringsFromPath path_ acc =
    case path_ of
        Index _ hint subPath ->
            acc
                |> collectStringsFromHint hint
                |> collectStringsFromPath subPath

        Unbox subPath ->
            collectStringsFromPath subPath acc

        Empty ->
            acc


collectStringsFromHint : ContainerHint -> Set String -> Set String
collectStringsFromHint hint acc =
    case hint of
        HintCustom ctorName ->
            Set.insert ctorName acc

        _ ->
            acc
