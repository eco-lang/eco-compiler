module DecodeValueEncodeNullTest exposing (main)

{-| Decoders given `Json.Encode.null` through `Json.Decode.decodeValue` treat it as JSON `null`.

`Decode.null 0` gives `Ok 0`, `Decode.nullable Decode.int` gives `Ok Nothing`, and
`Decode.string` fails. Inside a list built with `Json.Encode.list`, a `null` element decodes
to `Nothing` next to `Just 1`. Decoding it with `Decode.value` and decoding that `Value` again
with `Decode.null 7` gives `Ok 7`, and `Json.Encode.encode 0 Json.Encode.null` is the text
`null`.
-}

-- CHECK: null: Ok 0
-- CHECK: nullable: Ok Nothing
-- CHECK: string: False
-- CHECK: in_list: Ok [Nothing,Just 1]
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
