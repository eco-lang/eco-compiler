module CharLocaleCaseTest exposing (main)

{-| Char.toLocaleUpper/toLocaleLower. On node with the default locale they equal
toUpper/toLower (no Turkish or Lithuanian rules), so no i, I or dotted/dotless i inputs. The
inputs whose full mapping is several code points are in CaseMappingDivergenceTest
(plans/char-simple-case-mapping.md). Expectations recorded from Elm (run-js-e2e.js --record).
-}

-- CHECK: E9 locUp: "C9"
-- CHECK: E9 locLo: "E9"
-- CHECK: 3A3 locUp: "3A3"
-- CHECK: 3A3 locLo: "3C3"
-- CHECK: 1C5 locUp: "1C4"
-- CHECK: 1C5 locLo: "1C6"
-- CHECK: 10428 locUp: "10400"
-- CHECK: 10428 locLo: "10428"
-- CHECK: 61 locUp: "41"
-- CHECK: 61 locLo: "61"
-- CHECK: 5A locUp: "5A"
-- CHECK: 5A locLo: "7A"

import ConformanceHelp exposing (charCps, logAll, worker)


inputs : List Char
inputs =
    [ '\u{00E9}', '\u{03A3}', '\u{01C5}', '\u{10428}', 'a', 'Z' ]


entries : Char -> List ( String, String )
entries c =
    let
        name =
            charCps c
    in
    [ ( name ++ " locUp", charCps (Char.toLocaleUpper c) )
    , ( name ++ " locLo", charCps (Char.toLocaleLower c) )
    ]


report : ()
report =
    logAll (List.concatMap entries inputs)


main : Program () () ()
main =
    worker report
