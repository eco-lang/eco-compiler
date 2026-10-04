module Compiler.AST.DecisionTree.Path exposing
    ( Path(..)
    , pathEncoder, pathDecoder
    )

{-| A decision tree tests parts of the value a `case` expression matches on, and
this module names those parts for the decision trees that carry no types.

The value a `case` matches on is its _scrutinee_. A test in a decision tree
looks at one sub-value of the scrutinee, such as the second element of a tuple
or an argument of a constructor, and a `Path` says which one. A path is a chain
of steps that ends at `Empty`, the scrutinee itself. Each other step applies to
the value that the rest of the chain reaches, so a path is read from the inside
out: `Index Index.second (Unbox Empty)` unwraps the scrutinee first and then
takes the second field of what that gives.

The typed pipeline has its own `Compiler.AST.DecisionTree.TypedPath`, whose
index step also records what kind of container it looks into. The two types
are not interchangeable. Neither is `Compiler.AST.Optimized.Path`, which names
the sub-values a destructuring pattern binds.

The module also gives a path a binary encoding.

@docs Path
@docs pathEncoder, pathDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Data.Index as Index


{-| A sub-value of a `case` scrutinee, given as the steps that reach it.

`Index` takes the field at the given position, counted from zero, of the value
its inner path reaches. That value is a tuple, or a constructor whose arguments
are numbered in order.

`Unbox` takes the one argument of a value whose type has a single constructor
and that constructor a single argument. It is a step of its own, not `Index`
at the first position, because a back end may represent such a value as its
argument alone.

`Empty` is the scrutinee itself, where every path ends.

-}
type Path
    = Index Index.ZeroBased Path
    | Unbox Path
    | Empty


{-| Encodes a path as a tag byte for its outermost step, 0 for `Index`, 1 for
`Unbox` and 2 for `Empty`, followed by that step's position, if any, and then
the encoding of its inner path, if any. `Empty` is the tag byte alone.
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


{-| A decoder for a path written by `pathEncoder`. A tag byte other than 0, 1
or 2 makes it fail.
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
