module IntegrationConditionalDecodingTest exposing (main)

{-| Test conditional decoding based on tag byte.
-}

-- CHECK: IntegrationConditionalDecodingTest: True

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type Value
    = IntVal Int
    | FloatVal Float


encodeValue : Value -> E.Encoder
encodeValue v =
    case v of
        IntVal n ->
            E.sequence [ E.unsignedInt8 1, E.signedInt32 BE n ]

        FloatVal f ->
            E.sequence [ E.unsignedInt8 2, E.float64 BE f ]


decodeValue : D.Decoder Value
decodeValue =
    D.unsignedInt8
        |> D.andThen
            (\tag ->
                case tag of
                    1 ->
                        D.map IntVal (D.signedInt32 BE)

                    2 ->
                        D.map FloatVal (D.float64 BE)

                    _ ->
                        D.fail
            )


main =
    let
        intVal =
            IntVal 42

        floatVal =
            FloatVal 3.14

        decodedInt =
            D.decode decodeValue (E.encode (encodeValue intVal))

        decodedFloat =
            D.decode decodeValue (E.encode (encodeValue floatVal))

        result =
            (decodedInt == Just (IntVal 42))
                && (decodedFloat == Just (FloatVal 3.14))

        _ =
            Debug.log "IntegrationConditionalDecodingTest" result
    in
    text (if result then "True" else "False")
