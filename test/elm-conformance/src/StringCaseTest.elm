module StringCaseTest exposing (main)

{-| String.toUpper/toLower with full Unicode case mapping, including expansions (sharp s,
ligatures, Greek with iota subscript, dotted capital I), titlecase, astral letters, and the
Final_Sigma rule of toLower. Also Elm's equivalence
`String.fromList (List.map Char.toUpper (String.toList s)) == String.toUpper s`, and the same
for toLower when `s` has no capital sigma. Expectations recorded from Elm
(plans/char-case-mapping-elm-exact.md Step 0.6).
-}

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
-- CHECK: dz emal up: "1C4 45 4D 41 4C"
-- CHECK: dz emal lo: "1C6 65 6D 61 6C"
-- CHECK: athens up: "1F08 398 397 342 39D 391 399"
-- CHECK: athens lo: "1F00 3B8 1FC6 3BD 3B1 3B9"
-- CHECK: deseret up: "10400 10400"
-- CHECK: deseret lo: "10428 10428"
-- CHECK: mixed case up: "53 54 52 41 53 53 45 20 53 54 52 41 53 53 45"
-- CHECK: mixed case lo: "73 74 72 61 73 73 65 20 73 74 72 61 DF 65"
-- CHECK: mixed scripts up: "41 5A 20 C9 C9 20 416 416 20 4E2D 20 1F600 21"
-- CHECK: mixed scripts lo: "61 7A 20 E9 E9 20 436 436 20 4E2D 20 1F600 21"
-- CHECK: s1 AS up: "391 3A3"
-- CHECK: s1 AS lo: "3B1 3C2"
-- CHECK: s2 S up: "3A3"
-- CHECK: s2 S lo: "3C3"
-- CHECK: s3 ASA up: "391 3A3 391"
-- CHECK: s3 ASA lo: "3B1 3C3 3B1"
-- CHECK: s4 A.S up: "391 2E 3A3"
-- CHECK: s4 A.S lo: "3B1 2E 3C2"
-- CHECK: s5 AS. up: "391 3A3 2E"
-- CHECK: s5 AS. lo: "3B1 3C2 2E"
-- CHECK: s6 AS diaeresis up: "391 3A3 308"
-- CHECK: s6 AS diaeresis lo: "3B1 3C2 308"
-- CHECK: s7 AS A up: "391 3A3 20 391"
-- CHECK: s7 AS A lo: "3B1 3C2 20 3B1"
-- CHECK: s8 AS.A up: "391 3A3 2E 391"
-- CHECK: s8 AS.A lo: "3B1 3C3 2E 3B1"
-- CHECK: s9 1S up: "31 3A3"
-- CHECK: s9 1S lo: "31 3C3"
-- CHECK: s10 ODOS ODOS up: "39F 394 39F 3A3 20 39F 394 39F 3A3"
-- CHECK: s10 ODOS ODOS lo: "3BF 3B4 3BF 3C2 20 3BF 3B4 3BF 3C2"
-- CHECK: s11 hS up: "2B0 3A3"
-- CHECK: s11 hS lo: "2B0 3C3"
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
-- CHECK: dz emal equivUp: "True"
-- CHECK: dz emal equivLo: "True"
-- CHECK: athens equivUp: "True"
-- CHECK: athens equivLo: "True"
-- CHECK: deseret equivUp: "True"
-- CHECK: deseret equivLo: "True"
-- CHECK: mixed case equivUp: "True"
-- CHECK: mixed case equivLo: "True"
-- CHECK: mixed scripts equivUp: "True"
-- CHECK: mixed scripts equivLo: "True"

import ConformanceHelp exposing (cps, logAll, worker)


bool : Bool -> String
bool b =
    if b then
        "True"

    else
        "False"


strings : List ( String, String )
strings =
    [ ( "strasse", "stra\u{00DF}e" )
    , ( "final", "\u{FB01}nal" )
    , ( "j caron", "\u{01F0}" )
    , ( "iota dt", "\u{0390}" )
    , ( "alpha ypo", "\u{1FB3} \u{1FBC}" )
    , ( "istanbul", "\u{0130}stanbul" )
    , ( "dz emal", "\u{01C5}emal" )
    , ( "athens", "\u{1F08}\u{03B8}\u{1FC6}\u{03BD}\u{03B1}\u{03B9}" )
    , ( "deseret", "\u{10428}\u{10400}" )
    , ( "mixed case", "STRASSE stra\u{00DF}e" )
    , ( "mixed scripts", "aZ \u{00E9}\u{00C9} \u{0436}\u{0416} \u{4E2D} \u{1F600}!" )
    ]


sigmas : List ( String, String )
sigmas =
    [ ( "s1 AS", "\u{0391}\u{03A3}" )
    , ( "s2 S", "\u{03A3}" )
    , ( "s3 ASA", "\u{0391}\u{03A3}\u{0391}" )
    , ( "s4 A.S", "\u{0391}.\u{03A3}" )
    , ( "s5 AS.", "\u{0391}\u{03A3}." )
    , ( "s6 AS diaeresis", "\u{0391}\u{03A3}\u{0308}" )
    , ( "s7 AS A", "\u{0391}\u{03A3} \u{0391}" )
    , ( "s8 AS.A", "\u{0391}\u{03A3}.\u{0391}" )
    , ( "s9 1S", "1\u{03A3}" )
    , ( "s10 ODOS ODOS", "\u{039F}\u{0394}\u{039F}\u{03A3} \u{039F}\u{0394}\u{039F}\u{03A3}" )
    , ( "s11 hS", "\u{02B0}\u{03A3}" )
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


report : ()
report =
    logAll
        (List.concatMap caseEntries (strings ++ sigmas)
            ++ List.concatMap equivEntries strings
        )


main : Program () () ()
main =
    worker report
