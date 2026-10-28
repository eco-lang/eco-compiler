module CharCaseSpecialTest exposing (main)

{-| Char.toUpper/toLower of the characters whose full case mapping is more than one code
point, as Elm on JS gives them (`_Utils_chr(c.toUpperCase())`): the Char holds the whole
expansion, `Char.toCode` is its first code point, and `String.fromChar` writes all of it.
Expectations recorded from Elm (plans/char-case-mapping-elm-exact.md Step 0.6).
-}

-- CHECK: DF up: "53 53"
-- CHECK: DF lo: "DF"
-- CHECK: DF upCode: "83"
-- CHECK: DF upLen: "2"
-- CHECK: FB01 up: "46 49"
-- CHECK: FB01 lo: "FB01"
-- CHECK: FB01 upCode: "70"
-- CHECK: FB01 upLen: "2"
-- CHECK: FB02 up: "46 4C"
-- CHECK: FB02 lo: "FB02"
-- CHECK: FB02 upCode: "70"
-- CHECK: FB02 upLen: "2"
-- CHECK: FB00 up: "46 46"
-- CHECK: FB00 lo: "FB00"
-- CHECK: FB00 upCode: "70"
-- CHECK: FB00 upLen: "2"
-- CHECK: 1F0 up: "4A 30C"
-- CHECK: 1F0 lo: "1F0"
-- CHECK: 1F0 upCode: "74"
-- CHECK: 1F0 upLen: "2"
-- CHECK: 149 up: "2BC 4E"
-- CHECK: 149 lo: "149"
-- CHECK: 149 upCode: "700"
-- CHECK: 149 upLen: "2"
-- CHECK: 390 up: "399 308 301"
-- CHECK: 390 lo: "390"
-- CHECK: 390 upCode: "921"
-- CHECK: 390 upLen: "3"
-- CHECK: 3B0 up: "3A5 308 301"
-- CHECK: 3B0 lo: "3B0"
-- CHECK: 3B0 upCode: "933"
-- CHECK: 3B0 upLen: "3"
-- CHECK: 1FB3 up: "391 399"
-- CHECK: 1FB3 lo: "1FB3"
-- CHECK: 1FB3 upCode: "913"
-- CHECK: 1FB3 upLen: "2"
-- CHECK: 1FBC up: "391 399"
-- CHECK: 1FBC lo: "1FB3"
-- CHECK: 1FBC upCode: "913"
-- CHECK: 1FBC upLen: "2"
-- CHECK: 130 up: "130"
-- CHECK: 130 lo: "69 307"
-- CHECK: 130 upCode: "304"
-- CHECK: 130 upLen: "1"
-- CHECK: 1E9E up: "1E9E"
-- CHECK: 1E9E lo: "DF"
-- CHECK: 1E9E upCode: "7838"
-- CHECK: 1E9E upLen: "1"

import ConformanceHelp exposing (charCps, logAll, worker)


inputs : List ( String, Char )
inputs =
    [ ( "DF", '\u{00DF}' ) -- sharp s
    , ( "FB01", '\u{FB01}' ) -- fi ligature
    , ( "FB02", '\u{FB02}' ) -- fl ligature
    , ( "FB00", '\u{FB00}' ) -- ff ligature
    , ( "1F0", '\u{01F0}' ) -- j with caron
    , ( "149", '\u{0149}' ) -- n preceded by apostrophe
    , ( "390", '\u{0390}' ) -- iota with dialytika and tonos
    , ( "3B0", '\u{03B0}' ) -- upsilon with dialytika and tonos
    , ( "1FB3", '\u{1FB3}' ) -- alpha with ypogegrammeni
    , ( "1FBC", '\u{1FBC}' ) -- capital alpha with prosgegrammeni
    , ( "130", '\u{0130}' ) -- capital I with dot above
    , ( "1E9E", '\u{1E9E}' ) -- capital sharp s
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
