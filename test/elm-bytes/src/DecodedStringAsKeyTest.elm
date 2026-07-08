module DecodedStringAsKeyTest exposing (main)

{-| W1: a decoded UTF-8 view/leaf must compare/hash-equal to a literal-built
twin of the same content (equal/compare have both-UTF-8 and mixed-encoding
fast paths). Uses a decoded string as a Dict key and looks it up with a
literal, and mixes in a String.fromInt key.
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
