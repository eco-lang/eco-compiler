module JsonDecoderSelfRecursiveNoLazyTest exposing (main)

{-| A `Json.Decode` decoder that refers to itself without `Json.Decode.lazy` decodes a nested value correctly.

`tDecoder` reads a `"tag"` field and, through `andThen`, decodes `"kids"` with
`Json.Decode.list tDecoder` only for the tag `"node"`. Because the self-reference sits inside
the `andThen` callback, no `lazy` is needed. The input is a node holding one leaf.
-}

-- CHECK: decoded: Ok (TNode [TLeaf])

import Html exposing (text)
import Json.Decode as D


type T
    = TLeaf
    | TNode (List T)


tDecoder : D.Decoder T
tDecoder =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "leaf" ->
                        D.succeed TLeaf

                    "node" ->
                        D.map TNode (D.field "kids" (D.list tDecoder))

                    _ ->
                        D.fail "unknown tag"
            )


main =
    let
        json =
            """{"tag": "node", "kids": [{"tag": "leaf"}]}"""

        result =
            D.decodeString tDecoder json

        _ =
            Debug.log "decoded" result
    in
    text "done"
