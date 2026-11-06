module DecodeListMaybeTest exposing (main)

{-| A list of `Maybe` records, mixing `Just` and `Nothing`, survives encoding to bytes and decoding back unchanged.

The list holds six entries, three `Just { tag, value }` and three `Nothing`. It is written as a 16-bit big-endian count followed by one entry each: a byte `0` for `Nothing`, or a byte `1` followed by the tag as one byte and the value as a 16-bit big-endian integer. The decoder reads the count, then uses `Bytes.Decode.loop` to read that many entries, choosing with `andThen` on the leading byte between `succeed Nothing` and decoding a record wrapped in `Just`. The test prints `True` when the decoded list equals the original.
-}

-- CHECK: DecodeListMaybeTest: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type alias Item =
    { tag : Int, value : Int }


original : List (Maybe Item)
original =
    [ Just { tag = 1, value = 10 }
    , Nothing
    , Just { tag = 2, value = 20 }
    , Nothing
    , Nothing
    , Just { tag = 3, value = 30 }
    ]


encodeItem : Item -> E.Encoder
encodeItem it =
    E.sequence [ E.unsignedInt8 it.tag, E.unsignedInt16 BE it.value ]


encodeMaybe : Maybe Item -> E.Encoder
encodeMaybe m =
    case m of
        Nothing ->
            E.unsignedInt8 0

        Just it ->
            E.sequence [ E.unsignedInt8 1, encodeItem it ]


encoder : List (Maybe Item) -> E.Encoder
encoder xs =
    E.sequence
        [ E.unsignedInt16 BE (List.length xs)
        , E.sequence (List.map encodeMaybe xs)
        ]


decodeItem : D.Decoder Item
decodeItem =
    D.map2 Item D.unsignedInt8 (D.unsignedInt16 BE)


decodeMaybe : D.Decoder (Maybe Item)
decodeMaybe =
    D.unsignedInt8
        |> D.andThen
            (\tag ->
                if tag == 0 then
                    D.succeed Nothing

                else
                    D.map Just decodeItem
            )


decoder : D.Decoder (List (Maybe Item))
decoder =
    D.unsignedInt16 BE
        |> D.andThen
            (\len ->
                D.loop ( len, [] )
                    (\( remaining, acc ) ->
                        if remaining <= 0 then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            decodeMaybe |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
                    )
            )


main =
    let
        decoded =
            D.decode decoder (E.encode (encoder original))

        ok =
            case decoded of
                Just v ->
                    v == original

                Nothing ->
                    False

        _ =
            Debug.log "DecodeListMaybeTest" ok
    in
    text
        (if ok then
            "True"

         else
            "False"
        )
