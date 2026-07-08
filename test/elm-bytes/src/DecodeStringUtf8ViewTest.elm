module DecodeStringUtf8ViewTest exposing (main)

{-| Decode a long ASCII string (>= 32 bytes, forcing a zero-copy UTF-8 view)
and exercise the String API on the decoded value, comparing every result to the
same operation on the literal-built twin. This validates end-to-end that a
UTF-8 view behaves identically to a UTF-16 string, including as a Dict key
(equal/compare across encodings).
-}

-- CHECK: DecodeStringUtf8ViewTest: True

import Bytes.Decode as D
import Bytes.Encode as E
import Dict
import Html exposing (text)


source : String
source =
    "the quick brown fox jumps over the lazy dog 0123456789"


decodeIt : String -> Maybe String
decodeIt s =
    D.decode (D.string (String.length s)) (E.encode (E.string s))


checks : Bool
checks =
    case decodeIt source of
        Nothing ->
            False

        Just d ->
            List.all identity
                [ d == source
                , String.length d == String.length source
                , String.left 9 d == "the quick"
                , String.right 3 d == "789"
                , String.dropLeft 4 d == String.dropLeft 4 source
                , String.dropRight 3 d == String.dropRight 3 source
                , String.slice 4 9 d == "quick"
                , String.toUpper d == String.toUpper source
                , String.contains "brown" d
                , String.startsWith "the" d
                , String.endsWith "789" d
                , (d ++ "!") == (source ++ "!")
                , String.reverse d == String.reverse source
                , String.split " " d == String.split " " source
                , Dict.get d (Dict.singleton source 42) == Just 42
                ]


main =
    let
        _ =
            Debug.log "DecodeStringUtf8ViewTest" checks
    in
    text
        (if checks then
            "True"

         else
            "False"
        )
