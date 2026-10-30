module CaseMappingDivergenceTest exposing (main)

{-| Case-mapping cases where eco differs from Elm ON PURPOSE (design\_docs/char-case-mapping.md,
plans/char-simple-case-mapping.md). Elm on JS uses full case mapping, so `Char.toUpper 'ß'` is the
two-letter Char "SS" and `String.toLower` makes a word-final Σ into ς; eco uses the Unicode simple
case mapping, one code point to one code point, and has no Final\_Sigma rule. The expectations are
Elm's own results, recorded from Elm on node (run-js-e2e.js --record), so the test passes on node
and is an expected failure natively for good: it keeps each difference visible. eco's own results
are checked by test/elm/src/CharSimpleCaseTest.elm.

The inputs are the diverging ones of CharCaseSpecialTest, CharLocaleCaseTest and StringCaseTest,
moved here whole with the same labels, plus one row with Elm's toUpper and toLower of every code
point whose full mapping has several code points (the 103 that `gen-casemap-tables.mjs
--list-divergent` prints), which CharCaseFullRangeTest skips.

-}

-- XFAIL-NATIVE: deliberate divergence from Elm: eco uses Unicode simple case mapping and no Final_Sigma (design_docs/char-case-mapping.md); these rows are Elm's full mapping
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
-- CHECK: DF locUp: "53 53"
-- CHECK: DF locLo: "DF"
-- CHECK: FB01 locUp: "46 49"
-- CHECK: FB01 locLo: "FB01"
-- CHECK: strasse up: "53 54 52 41 53 53 45"
-- CHECK: strasse lo: "73 74 72 61 DF 65"
-- CHECK: final up: "46 49 4E 41 4C"
-- CHECK: final lo: "FB01 6E 61 6C"
-- CHECK: j caron up: "4A 30C"
-- CHECK: j caron lo: "1F0"
-- CHECK: iota dt up: "399 308 301"
-- CHECK: iota dt lo: "390"
-- CHECK: alpha ypo up: "391 399 20 391 399"
-- CHECK: alpha ypo lo: "1FB3 20 1FB3"
-- CHECK: istanbul up: "130 53 54 41 4E 42 55 4C"
-- CHECK: istanbul lo: "69 307 73 74 61 6E 62 75 6C"
-- CHECK: athens up: "1F08 398 397 342 39D 391 399"
-- CHECK: athens lo: "1F00 3B8 1FC6 3BD 3B1 3B9"
-- CHECK: mixed case up: "53 54 52 41 53 53 45 20 53 54 52 41 53 53 45"
-- CHECK: mixed case lo: "73 74 72 61 73 73 65 20 73 74 72 61 DF 65"
-- CHECK: s1 AS up: "391 3A3"
-- CHECK: s1 AS lo: "3B1 3C2"
-- CHECK: s4 A.S up: "391 2E 3A3"
-- CHECK: s4 A.S lo: "3B1 2E 3C2"
-- CHECK: s5 AS. up: "391 3A3 2E"
-- CHECK: s5 AS. lo: "3B1 3C2 2E"
-- CHECK: s6 AS diaeresis up: "391 3A3 308"
-- CHECK: s6 AS diaeresis lo: "3B1 3C2 308"
-- CHECK: s7 AS A up: "391 3A3 20 391"
-- CHECK: s7 AS A lo: "3B1 3C2 20 3B1"
-- CHECK: s10 ODOS ODOS up: "39F 394 39F 3A3 20 39F 394 39F 3A3"
-- CHECK: s10 ODOS ODOS lo: "3BF 3B4 3BF 3C2 20 3BF 3B4 3BF 3C2"
-- CHECK: s12 ASh up: "391 3A3 2B0"
-- CHECK: s12 ASh lo: "3B1 3C2 2B0"
-- CHECK: s13 A'S up: "391 27 3A3"
-- CHECK: s13 A'S lo: "3B1 27 3C2"
-- CHECK: s14 A'S' up: "391 27 3A3 27"
-- CHECK: s14 A'S' lo: "3B1 27 3C2 27"
-- CHECK: strasse equivUp: "True"
-- CHECK: strasse equivLo: "True"
-- CHECK: final equivUp: "True"
-- CHECK: final equivLo: "True"
-- CHECK: j caron equivUp: "True"
-- CHECK: j caron equivLo: "True"
-- CHECK: iota dt equivUp: "True"
-- CHECK: iota dt equivLo: "True"
-- CHECK: alpha ypo equivUp: "True"
-- CHECK: alpha ypo equivLo: "True"
-- CHECK: istanbul equivUp: "True"
-- CHECK: istanbul equivLo: "True"
-- CHECK: athens equivUp: "True"
-- CHECK: athens equivLo: "True"
-- CHECK: mixed case equivUp: "True"
-- CHECK: mixed case equivLo: "True"
-- CHECK: expanding count: "103"
-- CHECK: expanding: "DF>53 53/DF,130>130/69 307,149>2BC 4E/149,1F0>4A 30C/1F0,390>399 308 301/390,3B0>3A5 308 301/3B0,587>535 552/587,1E96>48 331/1E96,1E97>54 308/1E97,1E98>57 30A/1E98,1E99>59 30A/1E99,1E9A>41 2BE/1E9A,1F50>3A5 313/1F50,1F52>3A5 313 300/1F52,1F54>3A5 313 301/1F54,1F56>3A5 313 342/1F56,1F80>1F08 399/1F80,1F81>1F09 399/1F81,1F82>1F0A 399/1F82,1F83>1F0B 399/1F83,1F84>1F0C 399/1F84,1F85>1F0D 399/1F85,1F86>1F0E 399/1F86,1F87>1F0F 399/1F87,1F88>1F08 399/1F80,1F89>1F09 399/1F81,1F8A>1F0A 399/1F82,1F8B>1F0B 399/1F83,1F8C>1F0C 399/1F84,1F8D>1F0D 399/1F85,1F8E>1F0E 399/1F86,1F8F>1F0F 399/1F87,1F90>1F28 399/1F90,1F91>1F29 399/1F91,1F92>1F2A 399/1F92,1F93>1F2B 399/1F93,1F94>1F2C 399/1F94,1F95>1F2D 399/1F95,1F96>1F2E 399/1F96,1F97>1F2F 399/1F97,1F98>1F28 399/1F90,1F99>1F29 399/1F91,1F9A>1F2A 399/1F92,1F9B>1F2B 399/1F93,1F9C>1F2C 399/1F94,1F9D>1F2D 399/1F95,1F9E>1F2E 399/1F96,1F9F>1F2F 399/1F97,1FA0>1F68 399/1FA0,1FA1>1F69 399/1FA1,1FA2>1F6A 399/1FA2,1FA3>1F6B 399/1FA3,1FA4>1F6C 399/1FA4,1FA5>1F6D 399/1FA5,1FA6>1F6E 399/1FA6,1FA7>1F6F 399/1FA7,1FA8>1F68 399/1FA0,1FA9>1F69 399/1FA1,1FAA>1F6A 399/1FA2,1FAB>1F6B 399/1FA3,1FAC>1F6C 399/1FA4,1FAD>1F6D 399/1FA5,1FAE>1F6E 399/1FA6,1FAF>1F6F 399/1FA7,1FB2>1FBA 399/1FB2,1FB3>391 399/1FB3,1FB4>386 399/1FB4,1FB6>391 342/1FB6,1FB7>391 342 399/1FB7,1FBC>391 399/1FB3,1FC2>1FCA 399/1FC2,1FC3>397 399/1FC3,1FC4>389 399/1FC4,1FC6>397 342/1FC6,1FC7>397 342 399/1FC7,1FCC>397 399/1FC3,1FD2>399 308 300/1FD2,1FD3>399 308 301/1FD3,1FD6>399 342/1FD6,1FD7>399 308 342/1FD7,1FE2>3A5 308 300/1FE2,1FE3>3A5 308 301/1FE3,1FE4>3A1 313/1FE4,1FE6>3A5 342/1FE6,1FE7>3A5 308 342/1FE7,1FF2>1FFA 399/1FF2,1FF3>3A9 399/1FF3,1FF4>38F 399/1FF4,1FF6>3A9 342/1FF6,1FF7>3A9 342 399/1FF7,1FFC>3A9 399/1FF3,FB00>46 46/FB00,FB01>46 49/FB01,FB02>46 4C/FB02,FB03>46 46 49/FB03,FB04>46 46 4C/FB04,FB05>53 54/FB05,FB06>53 54/FB06,FB13>544 546/FB13,FB14>544 535/FB14,FB15>544 53B/FB15,FB16>54E 546/FB16,FB17>544 53D/FB17"

import ConformanceHelp exposing (charCps, cps, logAll, worker)


bool : Bool -> String
bool b =
    if b then
        "True"

    else
        "False"



-- From CharCaseSpecialTest.


specialInputs : List ( String, Char )
specialInputs =
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
    ]


specialEntries : ( String, Char ) -> List ( String, String )
specialEntries ( name, c ) =
    [ ( name ++ " up", charCps (Char.toUpper c) )
    , ( name ++ " lo", charCps (Char.toLower c) )
    , ( name ++ " upCode", String.fromInt (Char.toCode (Char.toUpper c)) )
    , ( name ++ " upLen", String.fromInt (String.length (String.fromChar (Char.toUpper c))) )
    ]



-- From CharLocaleCaseTest.


localeInputs : List Char
localeInputs =
    [ '\u{00DF}', '\u{FB01}' ]


localeEntries : Char -> List ( String, String )
localeEntries c =
    let
        name =
            charCps c
    in
    [ ( name ++ " locUp", charCps (Char.toLocaleUpper c) )
    , ( name ++ " locLo", charCps (Char.toLocaleLower c) )
    ]



-- From StringCaseTest.


strings : List ( String, String )
strings =
    [ ( "strasse", "stra\u{00DF}e" )
    , ( "final", "\u{FB01}nal" )
    , ( "j caron", "\u{01F0}" )
    , ( "iota dt", "\u{0390}" )
    , ( "alpha ypo", "\u{1FB3} \u{1FBC}" )
    , ( "istanbul", "\u{0130}stanbul" )
    , ( "athens", "\u{1F08}\u{03B8}\u{1FC6}\u{03BD}\u{03B1}\u{03B9}" )
    , ( "mixed case", "STRASSE stra\u{00DF}e" )
    ]


sigmas : List ( String, String )
sigmas =
    [ ( "s1 AS", "\u{0391}\u{03A3}" )
    , ( "s4 A.S", "\u{0391}.\u{03A3}" )
    , ( "s5 AS.", "\u{0391}\u{03A3}." )
    , ( "s6 AS diaeresis", "\u{0391}\u{03A3}\u{0308}" )
    , ( "s7 AS A", "\u{0391}\u{03A3} \u{0391}" )
    , ( "s10 ODOS ODOS", "\u{039F}\u{0394}\u{039F}\u{03A3} \u{039F}\u{0394}\u{039F}\u{03A3}" )
    , ( "s12 ASh", "\u{0391}\u{03A3}\u{02B0}" )
    , ( "s13 A'S", "\u{0391}'\u{03A3}" )
    , ( "s14 A'S'", "\u{0391}'\u{03A3}'" )
    ]


caseEntries : ( String, String ) -> List ( String, String )
caseEntries ( name, s ) =
    [ ( name ++ " up", cps (String.toUpper s) )
    , ( name ++ " lo", cps (String.toLower s) )
    ]


viaChars : (Char -> Char) -> String -> String
viaChars f s =
    String.fromList (List.map f (String.toList s))


equivEntries : ( String, String ) -> List ( String, String )
equivEntries ( name, s ) =
    ( name ++ " equivUp", bool (viaChars Char.toUpper s == String.toUpper s) )
        :: (if String.contains "\u{03A3}" s then
                []

            else
                [ ( name ++ " equivLo", bool (viaChars Char.toLower s == String.toLower s) ) ]
           )



-- Every code point whose full mapping has several code points.


expanding : List Int
expanding =
    [ 0x00DF, 0x0130, 0x0149, 0x01F0, 0x0390, 0x03B0, 0x0587, 0x1E96, 0x1E97, 0x1E98
    , 0x1E99, 0x1E9A, 0x1F50, 0x1F52, 0x1F54, 0x1F56, 0x1F80, 0x1F81, 0x1F82, 0x1F83
    , 0x1F84, 0x1F85, 0x1F86, 0x1F87, 0x1F88, 0x1F89, 0x1F8A, 0x1F8B, 0x1F8C, 0x1F8D
    , 0x1F8E, 0x1F8F, 0x1F90, 0x1F91, 0x1F92, 0x1F93, 0x1F94, 0x1F95, 0x1F96, 0x1F97
    , 0x1F98, 0x1F99, 0x1F9A, 0x1F9B, 0x1F9C, 0x1F9D, 0x1F9E, 0x1F9F, 0x1FA0, 0x1FA1
    , 0x1FA2, 0x1FA3, 0x1FA4, 0x1FA5, 0x1FA6, 0x1FA7, 0x1FA8, 0x1FA9, 0x1FAA, 0x1FAB
    , 0x1FAC, 0x1FAD, 0x1FAE, 0x1FAF, 0x1FB2, 0x1FB3, 0x1FB4, 0x1FB6, 0x1FB7, 0x1FBC
    , 0x1FC2, 0x1FC3, 0x1FC4, 0x1FC6, 0x1FC7, 0x1FCC, 0x1FD2, 0x1FD3, 0x1FD6, 0x1FD7
    , 0x1FE2, 0x1FE3, 0x1FE4, 0x1FE6, 0x1FE7, 0x1FF2, 0x1FF3, 0x1FF4, 0x1FF6, 0x1FF7
    , 0x1FFC, 0xFB00, 0xFB01, 0xFB02, 0xFB03, 0xFB04, 0xFB05, 0xFB06, 0xFB13, 0xFB14
    , 0xFB15, 0xFB16, 0xFB17
    ]


expandingRow : ( String, String )
expandingRow =
    ( "expanding"
    , expanding
        |> List.map
            (\n ->
                let
                    c =
                        Char.fromCode n
                in
                charCps c ++ ">" ++ charCps (Char.toUpper c) ++ "/" ++ charCps (Char.toLower c)
            )
        |> String.join ","
    )


report : ()
report =
    logAll
        (List.concatMap specialEntries specialInputs
            ++ List.concatMap localeEntries localeInputs
            ++ List.concatMap caseEntries (strings ++ sigmas)
            ++ List.concatMap equivEntries strings
            ++ [ ( "expanding count", String.fromInt (List.length expanding) ), expandingRow ]
        )


main : Program () () ()
main =
    worker report
