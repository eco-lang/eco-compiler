module IntegrationLengthPrefixedStringTest exposing (main)

{-| Test length-prefixed string encoding/decoding pattern.
-}

-- CHECK: IntegrationLengthPrefixedStringTest: "hello"

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


encodeString : String -> E.Encoder
encodeString s =
    let
        len =
            String.length s
    in
    E.sequence
        [ E.unsignedInt16 BE len
        , E.string s
        ]


decodeString : D.Decoder String
decodeString =
    D.unsignedInt16 BE
        |> D.andThen D.string


main =
    let
        original =
            "hello"

        encoded =
            E.encode (encodeString original)

        decoded =
            D.decode decodeString encoded
                |> Maybe.withDefault "FAIL"

        _ =
            Debug.log "IntegrationLengthPrefixedStringTest" decoded
    in
    text decoded
