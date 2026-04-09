module JsonDecoderSelfRecursiveTest exposing (main)

{-| Self-recursive Json.Decode.Decoder using Json.Decode.lazy.

    Tests whether Json.Decode.lazy correctly defers the recursive reference.
    If this passes but BytesDecoderSelfRecursiveMinimalTest crashes, the
    bug is specific to how Bytes.Decode handles recursion (no built-in lazy).

    Input: {"val": null, "kids": [{"val": null, "kids": []}]}

    Expected: prints the decoded tree without crashing.
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
