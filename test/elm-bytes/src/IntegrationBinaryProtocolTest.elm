module IntegrationBinaryProtocolTest exposing (main)

{-| Test a complete binary protocol roundtrip.
    Protocol: [version:u8] [type:u8] [length:u16BE] [payload:bytes]
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
