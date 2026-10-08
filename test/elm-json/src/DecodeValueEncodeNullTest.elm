module DecodeValueEncodeNullTest exposing (main)

{-| `Json.Decode.decodeValue` over `Json.Encode.null` (plans/elm-html-native-kernel.md
§14 I2): `Encode.null` is the encoder family's embedded null constant, and
`Json.run` maps it to the decoder family's null, so `Decode.null`,
`Decode.nullable` and `Decode.value` treat it exactly like a parsed `null`.
-}

-- CHECK: null: Ok 0
-- CHECK: nullable: Ok Nothing
-- CHECK: string: False
-- CHECK: in_list: Ok [Nothing, Just 1]
-- CHECK: value_null: Ok 7
-- CHECK: encode: "null"

import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode


main =
    let
        _ =
            Debug.log "null" (Decode.decodeValue (Decode.null 0) Encode.null)

        _ =
            Debug.log "nullable" (Decode.decodeValue (Decode.nullable Decode.int) Encode.null)

        _ =
            Debug.log "string"
                (case Decode.decodeValue Decode.string Encode.null of
                    Ok _ ->
                        True

                    Err _ ->
                        False
                )

        _ =
            Debug.log "in_list"
                (Decode.decodeValue (Decode.list (Decode.nullable Decode.int))
                    (Encode.list identity [ Encode.null, Encode.int 1 ])
                )

        _ =
            Debug.log "value_null"
                (Decode.decodeValue Decode.value Encode.null
                    |> Result.andThen (Decode.decodeValue (Decode.null 7))
                    |> Result.mapError Decode.errorToString
                )

        _ =
            Debug.log "encode" (Encode.encode 0 Encode.null)
    in
    text "done"
