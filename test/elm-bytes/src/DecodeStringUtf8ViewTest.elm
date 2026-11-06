module DecodeStringUtf8ViewTest exposing (main)

{-| A string produced by Bytes.Decode.string behaves like a string literal with the
same contents under the String API and as a Dict key.

The fixture is a 54-character ASCII sentence, encoded and decoded back. The
test logs `True` when the decode succeeds and every one of these holds for the
decoded string: it equals the original and has the same length; `left`,
`right` and `slice` give the expected substrings; `dropLeft`, `dropRight`,
`toUpper`, `reverse`, `split " "` and appending `"!"` give the same results as
on the original; `contains "brown"`, `startsWith "the"` and `endsWith "789"`
hold; and looking it up in a Dict whose key is the original finds the value.

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
