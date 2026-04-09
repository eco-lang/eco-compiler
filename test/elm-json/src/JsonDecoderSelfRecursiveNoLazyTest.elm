module JsonDecoderSelfRecursiveNoLazyTest exposing (main)

{-| Self-recursive Json.Decode.Decoder WITHOUT Json.Decode.lazy.

    Same pattern as the Bytes decoder: andThen with a direct self-reference,
    no lazy wrapper. If this crashes while JsonDecoderSelfRecursiveTest
    (which uses lazy) passes, it confirms that lazy is the key differentiator.

    Input: {"tag": "node", "kids": [{"tag": "leaf"}]}

    Expected: prints the decoded tree without crashing.
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
