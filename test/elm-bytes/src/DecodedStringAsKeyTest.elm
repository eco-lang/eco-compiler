module DecodedStringAsKeyTest exposing (main)

{-| Strings produced by Bytes.Decode.string work as Dict keys that are found by
equal strings built without decoding.

A Dict is built from four keys: a decoded string of 40 `k` characters, the
literal `"literal"`, `String.fromInt 99`, and a decoded `"abc"`. The test logs
`True` when each key is found, with the value it was stored under, by looking
up a string with the same contents built by a literal or `String.repeat`, and the Dict has size 4.

-}

-- CHECK: AsKey.ok: True

import Bytes
import Bytes.Decode as D
import Bytes.Encode as E
import Dict
import Html exposing (text)


roundTrip : String -> String
roundTrip s =
    let
        b =
            E.encode (E.string s)
    in
    D.decode (D.string (Bytes.width b)) b
        |> Maybe.withDefault "FAIL"


main : Html.Html msg
main =
    let
        viewKey =
            roundTrip (String.repeat 40 "k")

        leafKey =
            roundTrip "abc"

        d =
            Dict.fromList
                [ ( viewKey, 1 )
                , ( "literal", 2 )
                , ( String.fromInt 99, 3 )
                , ( leafKey, 4 )
                ]

        ok =
            (Dict.get (String.repeat 40 "k") d == Just 1)
                && (Dict.get "literal" d == Just 2)
                && (Dict.get "99" d == Just 3)
                && (Dict.get "abc" d == Just 4)
                && (Dict.size d == 4)

        _ =
            Debug.log "AsKey.ok" ok
    in
    text ""
