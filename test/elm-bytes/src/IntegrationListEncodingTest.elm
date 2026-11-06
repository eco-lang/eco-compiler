module IntegrationListEncodingTest exposing (main)

{-| A list of integers encoded as a one-byte count followed by one byte per element round-trips through elm/bytes.

The decoder reads the count and then uses `Bytes.Decode.loop` to read that many
bytes, reversing the accumulated list at the end. The list `[ 1, 2, 3, 4, 5 ]` is
encoded and decoded, and the program logs `True` only if the result equals the
original.
-}

-- CHECK: IntegrationListEncodingTest: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


encodeList : List Int -> E.Encoder
encodeList items =
    E.sequence
        [ E.unsignedInt8 (List.length items)
        , E.sequence (List.map E.unsignedInt8 items)
        ]


decodeList : D.Decoder (List Int)
decodeList =
    D.unsignedInt8
        |> D.andThen
            (\len ->
                D.loop ( len, [] )
                    (\( remaining, acc ) ->
                        if remaining <= 0 then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            D.unsignedInt8
                                |> D.map (\n -> D.Loop ( remaining - 1, n :: acc ))
                    )
            )


main =
    let
        original =
            [ 1, 2, 3, 4, 5 ]

        encoded =
            E.encode (encodeList original)

        decoded =
            D.decode decodeList encoded
                |> Maybe.withDefault []

        result =
            decoded == original

        _ =
            Debug.log "IntegrationListEncodingTest" result
    in
    text (if result then "True" else "False")
