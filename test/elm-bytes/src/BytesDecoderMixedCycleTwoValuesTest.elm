module BytesDecoderMixedCycleTwoValuesTest exposing (main)

{-| A recursive cycle of two top-level decoder values and one top-level decoder function decodes a tagged tree correctly.

`treeDecoder` uses the function `tagDispatch`, which uses `nestedDecoder`, which
is defined as `treeDecoder` itself.

The encoding is `0` for `Empty`, `1 x` for `Leaf x`, and `2 left right` for
`Node left right`. The input `2 1 4 2 0 1 9` decodes to
`Just (Node (Leaf 4) (Node Empty (Leaf 9)))`.

-}

-- CHECK: decoded: Just (Node (Leaf 4) (Node Empty (Leaf 9)))

import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type Tree
    = Empty
    | Leaf Int
    | Node Tree Tree


{-| A decoder that reads a tag byte and continues with `tagDispatch`.
-}
treeDecoder : D.Decoder Tree
treeDecoder =
    D.unsignedInt8
        |> D.andThen tagDispatch


{-| A second name for `treeDecoder`, used by `tagDispatch` for the subtrees of a
`Node`, so that the cycle passes through two values.
-}
nestedDecoder : D.Decoder Tree
nestedDecoder =
    treeDecoder


{-| Produces the decoder for the rest of a tree whose tag byte is `tag`, failing
on an unknown tag.
-}
tagDispatch : Int -> D.Decoder Tree
tagDispatch tag =
    case tag of
        0 ->
            D.succeed Empty

        1 ->
            D.map Leaf D.unsignedInt8

        2 ->
            D.map2 Node nestedDecoder nestedDecoder

        _ ->
            D.fail


main =
    let
        bytes =
            E.encode
                (E.sequence
                    [ E.unsignedInt8 2
                    , E.unsignedInt8 1
                    , E.unsignedInt8 4
                    , E.unsignedInt8 2
                    , E.unsignedInt8 0
                    , E.unsignedInt8 1
                    , E.unsignedInt8 9
                    ]
                )

        result =
            D.decode treeDecoder bytes

        _ =
            Debug.log "decoded" result
    in
    text "done"
