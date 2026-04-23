module BytesDecoderMixedCycleTwoValuesTest exposing (main)

{-| Recursive cycle with two top-level VALUE decoders and one top-level
    FUNCTION decoder. Both values belong to the same SCC as the function
    and are expected to be miscompiled to Unit stubs by the current
    `specializeFunctionCycle` behaviour.

    Input: a small tagged tree.

    The encoding is: `0` -> `Empty`, `1 x` -> `Leaf x`,
    `2 left right` -> `Node left right`.
-}

-- CHECK: decoded: Just (Node (Leaf 4) (Node Empty (Leaf 9)))

import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type Tree
    = Empty
    | Leaf Int
    | Node Tree Tree


{-| Value 1: dispatches on the top tag.
-}
treeDecoder : D.Decoder Tree
treeDecoder =
    D.unsignedInt8
        |> D.andThen tagDispatch


{-| Value 2: zero-arg wrapper that reads an inner subtree.

Referenced from `tagDispatch` to pull both values into the mixed cycle.

-}
nestedDecoder : D.Decoder Tree
nestedDecoder =
    treeDecoder


{-| Function: resolves a tag byte into the correct sub-decoder.
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
