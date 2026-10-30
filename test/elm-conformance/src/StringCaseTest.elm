module StringCaseTest exposing (main)

{-| String.toUpper/toLower where eco and Elm on JS agree: titlecase, astral letters, mixed
scripts, and capital sigmas that are not word-final. Also Elm's equivalence
`String.fromList (List.map Char.toUpper (String.toList s)) == String.toUpper s`, and the same
for toLower when `s` has no capital sigma. The inputs with a multi-code-point full mapping or a
word-final sigma (Final_Sigma), where eco's simple case mapping differs on purpose, are in
CaseMappingDivergenceTest (plans/char-simple-case-mapping.md). Expectations recorded from Elm
(run-js-e2e.js --record).
-}

-- CHECK: dz emal up: "1C4 45 4D 41 4C"
-- CHECK: dz emal lo: "1C6 65 6D 61 6C"
-- CHECK: deseret up: "10400 10400"
-- CHECK: deseret lo: "10428 10428"
-- CHECK: mixed scripts up: "41 5A 20 C9 C9 20 416 416 20 4E2D 20 1F600 21"
-- CHECK: mixed scripts lo: "61 7A 20 E9 E9 20 436 436 20 4E2D 20 1F600 21"
-- CHECK: s2 S up: "3A3"
-- CHECK: s2 S lo: "3C3"
-- CHECK: s3 ASA up: "391 3A3 391"
-- CHECK: s3 ASA lo: "3B1 3C3 3B1"
-- CHECK: s8 AS.A up: "391 3A3 2E 391"
-- CHECK: s8 AS.A lo: "3B1 3C3 2E 3B1"
-- CHECK: s9 1S up: "31 3A3"
-- CHECK: s9 1S lo: "31 3C3"
-- CHECK: s11 hS up: "2B0 3A3"
-- CHECK: s11 hS lo: "2B0 3C3"
-- CHECK: dz emal equivUp: "True"
-- CHECK: dz emal equivLo: "True"
-- CHECK: deseret equivUp: "True"
-- CHECK: deseret equivLo: "True"
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
    [ ( "dz emal", "\u{01C5}emal" )
    , ( "deseret", "\u{10428}\u{10400}" )
    , ( "mixed scripts", "aZ \u{00E9}\u{00C9} \u{0436}\u{0416} \u{4E2D} \u{1F600}!" )
    ]


sigmas : List ( String, String )
sigmas =
    [ ( "s2 S", "\u{03A3}" )
    , ( "s3 ASA", "\u{0391}\u{03A3}\u{0391}" )
    , ( "s8 AS.A", "\u{0391}\u{03A3}.\u{0391}" )
    , ( "s9 1S", "1\u{03A3}" )
    , ( "s11 hS", "\u{02B0}\u{03A3}" )
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
