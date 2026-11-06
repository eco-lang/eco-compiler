module CharCaseSpecialTest exposing (main)

{-| `Char.toUpper` and `Char.toLower` of U+1E9E (capital sharp s): the upper case is the character
itself and the lower case is U+00DF.

For each input the test logs the upper case and the lower case as code points (`charCps` from
`ConformanceHelp`), the upper case's `Char.toCode` (7838, that is U+1E9E), and the
`String.length` of the upper case as a one-character string, which is 1.
-}

-- CHECK: 1E9E up: "1E9E"
-- CHECK: 1E9E lo: "DF"
-- CHECK: 1E9E upCode: "7838"
-- CHECK: 1E9E upLen: "1"

import ConformanceHelp exposing (charCps, logAll, worker)


inputs : List ( String, Char )
inputs =
    [ ( "1E9E", '\u{1E9E}' ) -- capital sharp s
    ]


entries : ( String, Char ) -> List ( String, String )
entries ( name, c ) =
    [ ( name ++ " up", charCps (Char.toUpper c) )
    , ( name ++ " lo", charCps (Char.toLower c) )
    , ( name ++ " upCode", String.fromInt (Char.toCode (Char.toUpper c)) )
    , ( name ++ " upLen", String.fromInt (String.length (String.fromChar (Char.toUpper c))) )
    ]


report : ()
report =
    logAll (List.concatMap entries inputs)


main : Program () () ()
main =
    worker report
