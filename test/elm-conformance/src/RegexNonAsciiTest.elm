module RegexNonAsciiTest exposing (main)

{-| REGEX-06 (plans/kernel-lib-bug-fixes.md): elm/regex on non-ASCII text, recorded from Elm on
node (run-js-e2e.js --record). JavaScript regexes without the `u` flag, which elm/regex never
passes, work on UTF-16 code units: `.` is one unit, so U+00E9 is one match and U+1F600 two (one
per surrogate). Before the fix the native kernel compiled patterns with `srell::regex`, the `char`
instantiation, over a UTF-8 copy of the subject, so it matched bytes: `.` takes one byte of a
multi-byte sequence, a character class or escape naming a non-ASCII character did not match
it, and case-insensitive matching did not fold it. Matches are shown as their lengths and code
points (`cps`) or lengths only, so a lone surrogate or a broken byte sequence prints in ASCII. (`Regex.split` with
an empty pattern is not used: elm/regex's JS kernel loops forever on it.)

-}

-- CHECK: dot on e-acute: "1 [1] [E9]"
-- CHECK: dot on emoji: "2 [1,1]"
-- CHECK: class e-acute/u-umlaut: "True"
-- CHECK: escape u00e9: "True"
-- CHECK: icase e-acute: "True"
-- CHECK: three dots: "True"
-- CHECK: replace dots: "xx"
-- CHECK: split cjk: "2 [E9] [62]"
-- CHECK: split e-acute: "2 [61] [62]"

import ConformanceHelp exposing (cps, logAll, worker)
import Regex exposing (Regex)


re : String -> Regex
re pattern =
    Maybe.withDefault Regex.never (Regex.fromString pattern)


emoji : String
emoji =
    String.fromChar (Char.fromCode 0x0001F600)


eAcute : String
eAcute =
    "\u{00E9}"


{-| "<count> [<lengths>] [<code points of each>]" for a list of strings.
-}
parts : List String -> String
parts strs =
    String.fromInt (List.length strs)
        ++ " ["
        ++ String.join "," (List.map (String.fromInt << String.length) strs)
        ++ "] ["
        ++ String.join "," (List.map cps strs)
        ++ "]"


{-| "<count> [<lengths>]". For matches that may be lone surrogates, whose code point Elm's JS
`Char.toCode` gives as NaN (`cps` would then never finish).
-}
lengths : List String -> String
lengths strs =
    String.fromInt (List.length strs)
        ++ " ["
        ++ String.join "," (List.map (String.fromInt << String.length) strs)
        ++ "]"


{-| "<count> [<code points of each>]", for parts whose lengths are not interesting.
-}
partsCps : List String -> String
partsCps strs =
    String.fromInt (List.length strs) ++ " [" ++ String.join "] [" (List.map cps strs) ++ "]"


report : ()
report =
    let
        icase =
            Maybe.withDefault Regex.never
                (Regex.fromStringWith { caseInsensitive = True, multiline = False } eAcute)
    in
    logAll
        [ ( "dot on e-acute", parts (List.map .match (Regex.find (re ".") eAcute)) )
        , ( "dot on emoji", lengths (List.map .match (Regex.find (re ".") emoji)) )
        , ( "class e-acute/u-umlaut", Debug.toString (Regex.contains (re "^[\u{00E9}\u{00FC}]$") "\u{00FC}") )
        , ( "escape u00e9", Debug.toString (Regex.contains (re "\\u00e9") eAcute) )
        , ( "icase e-acute", Debug.toString (Regex.contains icase "\u{00C9}") )
        , ( "three dots", Debug.toString (Regex.contains (re "^.{3}$") ("a" ++ eAcute ++ "b")) )
        , ( "replace dots", Regex.replace (re ".") (\_ -> "x") (eAcute ++ "\u{4E2D}") )
        , ( "split cjk", partsCps (Regex.split (re "\u{4E2D}") (eAcute ++ "\u{4E2D}b")) )
        , ( "split e-acute", partsCps (Regex.split (re eAcute) ("a" ++ eAcute ++ "b")) )
        ]


main : Program () () ()
main =
    worker report
