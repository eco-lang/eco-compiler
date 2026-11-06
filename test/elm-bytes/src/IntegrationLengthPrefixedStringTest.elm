module IntegrationLengthPrefixedStringTest exposing (main)

{-| A string prefixed by its length as a big-endian 16-bit integer round-trips through elm/bytes, with `Bytes.Decode.andThen` passing the decoded length to `Bytes.Decode.string`.

The string `"hello"` is encoded and decoded, and the program logs the decoded
string. The length is taken from `String.length`, which equals the UTF-8 byte
count only for ASCII text such as this.
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
