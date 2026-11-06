module IntegrationBinaryProtocolTest exposing (main)

{-| A small binary message format round-trips through elm/bytes: a version byte, a type byte, a big-endian 16-bit payload length, then the payload bytes.

The decoder reads the length and then uses `Bytes.Decode.loop` to read exactly
that many bytes, reversing the accumulated list at the end. A message with
version 1, type 42 and payload `[ 0xDE, 0xAD, 0xBE, 0xEF ]` is encoded and
decoded, and the program logs `True` only if all three fields come back equal.
-}

-- CHECK: IntegrationBinaryProtocolTest: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type alias Message =
    { version : Int
    , msgType : Int
    , payload : List Int
    }


encodeMessage : Message -> E.Encoder
encodeMessage msg =
    let
        len =
            List.length msg.payload
    in
    E.sequence
        [ E.unsignedInt8 msg.version
        , E.unsignedInt8 msg.msgType
        , E.unsignedInt16 BE len
        , E.sequence (List.map E.unsignedInt8 msg.payload)
        ]


decodeMessage : D.Decoder Message
decodeMessage =
    D.map3 Message
        D.unsignedInt8
        D.unsignedInt8
        (D.unsignedInt16 BE
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
        )


main =
    let
        original =
            { version = 1
            , msgType = 42
            , payload = [ 0xDE, 0xAD, 0xBE, 0xEF ]
            }

        encoded =
            E.encode (encodeMessage original)

        decoded =
            D.decode decodeMessage encoded

        result =
            case decoded of
                Just msg ->
                    (msg.version == 1)
                        && (msg.msgType == 42)
                        && (msg.payload == [ 0xDE, 0xAD, 0xBE, 0xEF ])

                Nothing ->
                    False

        _ =
            Debug.log "IntegrationBinaryProtocolTest" result
    in
    text (if result then "True" else "False")
