module CharCaseSpecialTest exposing (main)

{-| Char.toUpper/toLower of special characters on which eco and Elm on JS agree. The
characters whose full case mapping is more than one code point, where eco's simple case mapping
differs on purpose, are recorded in CaseMappingDivergenceTest (plans/char-simple-case-mapping.md).
Expectations recorded from Elm (run-js-e2e.js --record).
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
