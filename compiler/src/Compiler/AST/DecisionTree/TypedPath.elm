module Compiler.AST.DecisionTree.TypedPath exposing
    ( Path(..), ContainerHint(..)
    , collectStringsFromPath
    , pathDecoderS, pathEncoderS
    )

{-| A decision tree for the typed pipeline must say, at each step into the value
being matched, what kind of container the step looks into, and this module
names those steps.

The value a `case` matches on is its _scrutinee_. A test in a decision tree
looks at one sub-value of the scrutinee, and a `Path` says which one. A path is
a chain of steps ending at `Empty`, the scrutinee itself, and each other step
applies to the value the rest of the chain reaches, so a path is read from the
inside out. The shape is that of `Compiler.AST.DecisionTree.Path`, the path of
the decision trees that carry no types, with one addition: each `Index` step
also carries a _container hint_, a `ContainerHint` saying whether the step
takes a field of a list cell, a tuple of two or three, or a constructor or a
larger tuple, or that the kind is not known. The hint lets a back end that lays
out lists, tuples and constructors differently choose how to take the field.
The two path types are not interchangeable.

The module also gives a path a binary encoding, whose constructor names go
through a string table as `Compiler.AST.StringTable` describes.
`collectStringsFromPath` gathers those names, so that the table can be built
to hold them before `pathEncoderS` writes the path.

@docs Path, ContainerHint
@docs collectStringsFromPath
@docs pathDecoderS, pathEncoderS

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.StringTable as StringTable exposing (StringTable)
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name


{-| The kind of container an `Index` step takes a field from.

`HintList` is a non-empty list, whose head is at position 0 and whose tail is
at position 1.

`HintTuple2` and `HintTuple3` are tuples of two and of three elements.

`HintCustom` carries the name of the constructor whose arguments the step
numbers, or the empty string where the container is a tuple of more than three
elements.

`HintUnknown` says nothing about the container. Decoding gives it for every
hint tag above 3, not only for the tag it is written with.

-}
type ContainerHint
    = HintList
    | HintTuple2
    | HintTuple3
    | HintCustom Name.Name
    | HintUnknown


{-| A sub-value of a `case` scrutinee, given as the steps that reach it from the
scrutinee, read from the inside out.

`Index` takes the field at the given position, counted from zero, of the value
its inner path reaches, from a container of the kind its hint names.

`Unbox` takes the one argument of the value its inner path reaches, where that
value's type has a single constructor and that constructor a single argument.

`Empty` is the scrutinee itself, where every path ends.

-}
type Path
    = Index Index.ZeroBased ContainerHint Path
    | Unbox Path
    | Empty


{-| Encodes a hint as a tag byte, 0 for `HintList`, 1 for `HintTuple2`, 2 for
`HintTuple3`, 3 for `HintCustom` and 4 for `HintUnknown`, followed, for
`HintCustom`, by the constructor name as `st` writes it.
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


{-| Produces a decoder for a hint written by `containerHintEncoder` with a table
holding the same strings. A tag byte above 3 decodes as `HintUnknown` rather
than failing.
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


{-| Encodes a path as a tag byte for its outermost step, 0 for `Index`, 1 for
`Unbox` and 2 for `Empty`, followed, for `Index`, by its position and its
container hint, and then by the encoding of its inner path. `Empty` is the tag
byte alone.

The position is written by `Compiler.Data.Index.zeroBasedEncoder`. The hint is
a tag byte, 0 for `HintList`, 1 for `HintTuple2`, 2 for `HintTuple3`, 3 for
`HintCustom` and 4 for `HintUnknown`, and a `HintCustom` tag is followed by the
constructor name as `st` writes it. Unless `st` writes names inline, as
`StringTable.disabled` does, a name missing from `st` is written without error
and reads back as another string or as the empty string, so `st` must hold
every name `collectStringsFromPath` gathers from the path.

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


{-| Produces a decoder for a path written by `pathEncoderS` with a table holding
the same strings.

A step tag byte other than 0, 1 or 2 makes it fail, but a hint tag byte above 3
decodes as `HintUnknown`.

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


{-| Returns `acc` after giving it, by `StringTable.add`, every constructor name
the path's `HintCustom` hints carry. `acc` keeps a name only if its rule does.
These are the only strings `pathEncoderS` writes through the table.
-}
collectStringsFromPath : Path -> StringTable.Collector -> StringTable.Collector
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


{-| Returns `acc` after giving it the constructor name of a `HintCustom` hint
by `StringTable.add`, and `acc` unchanged for any other hint.
-}
collectStringsFromHint : ContainerHint -> StringTable.Collector -> StringTable.Collector
collectStringsFromHint hint acc =
    case hint of
        HintCustom ctorName ->
            StringTable.add ctorName acc

        _ ->
            acc
