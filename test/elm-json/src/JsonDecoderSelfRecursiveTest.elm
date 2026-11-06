module JsonDecoderSelfRecursiveTest exposing (main)

{-| A `Json.Decode` decoder that refers to itself through `Json.Decode.lazy` decodes a nested value correctly.

`treeDecoder` decodes the `"kids"` field as a list of trees, using `lazy` to defer the
reference to itself. The input `{"kids": [{"kids": []}]}` is a node holding one empty node.
-}

-- CHECK: decoded: Ok (Node [Node []])

import Html exposing (text)
import Json.Decode as D


type Tree
    = Node (List Tree)


treeDecoder : D.Decoder Tree
treeDecoder =
    D.map Node
        (D.field "kids"
            (D.list (D.lazy (\_ -> treeDecoder)))
        )


main =
    let
        json =
            """{"kids": [{"kids": []}]}"""

        result =
            D.decodeString treeDecoder json

        _ =
            Debug.log "decoded" result
    in
    text "done"
